// server.js — hardened HTTP server for hao-backprop-test.
// Built on the Node.js built-in `http` module only (zero third-party dependencies).
// Preserves the original "Hello, World!" behavior on GET / while adding error
// handling, input validation, graceful shutdown, resource cleanup, and robust
// HTTP request processing. Compatible with Node.js >= 18 LTS.
const http = require('http');

// RC5: env-overridable config, preserving original defaults (127.0.0.1:3000).
// An unset or empty `HOST`, and an unset, empty or non-numeric `PORT`, each keep
// that default, so the bind is configurable without ever losing a valid address.
const hostname = process.env.HOST || '127.0.0.1';
const port = Number(process.env.PORT) || 3000;

// RC5: explicit timeouts (ms) for deterministic behavior across Node versions.
const REQUEST_TIMEOUT_MS = 30000;
const HEADERS_TIMEOUT_MS = 20000;
const KEEP_ALIVE_TIMEOUT_MS = 5000;
const SHUTDOWN_TIMEOUT_MS = 10000;

// RC5: how often the header and request deadlines above are actually enforced.
// Node does not arm a per-socket timer for them; it scans the incomplete
// connections periodically and reaps whatever has expired since the last pass, so
// this interval is the whole of the enforcement error and each deadline is really
// its configured value plus up to one interval. Left at Node's 30000 ms default
// that made the 20 s header deadline anything from 20 s to 50 s, and the 30 s
// request deadline anything from 30 s to 60 s, decided only by where a connection
// happened to fall in the scan grid — the opposite of the deterministic behavior
// the deadlines are declared for. Setting it explicitly bounds them at 25 s and
// 35 s and pins the granularity to this file rather than to the runtime's default,
// for the same reason the deadlines themselves are set here.
const CONNECTIONS_CHECK_INTERVAL_MS = 5000;

// RC1: no thrown value or rejection reason is ever handed to `console.*`, which
// would render its message, stack, `cause` chain and every enumerable property —
// any of which can carry a credential or personal data — and would consult a
// custom inspection hook on the value, running caller-supplied code inside
// handlers that include the fatal ones. Of its fields only these three are read
// as identifier tokens, and only when the value already has the short plain
// shape Node's own `name`, `code` and `syscall` carry, which admits no control
// character, quote or newline that could forge a second log record.
const MAX_ERROR_TOKEN_LENGTH = 48;
const ERROR_TOKEN_PATTERN = /^[A-Za-z_][A-Za-z0-9_.-]*$/;
const ALLOWLISTED_ERROR_FIELDS = ['name', 'code', 'syscall'];

// RC1: the failure's own description is rendered as well, because without it a
// record names a category and nothing else — `Uncaught exception: name=Error` is
// then the whole of what an operator is paged on, and two unrelated faults that
// share a `name` are indistinguishable. A message is free-form text rather than
// an identifier, so it cannot pass the token shape above and is admitted under
// its own discipline instead: it is rendered only when it already is a string,
// so a value that supplies something else is never coerced and no `toString` or
// inspection hook of its own ever runs; every run of control characters, line
// separators and whitespace collapses to a single space, so no fragment of it
// can begin a second log record; it is capped, so one record stays bounded
// whatever the value carries; and it is emitted inside double quotes with any
// quote of its own replaced, so it cannot close its field early and forge a
// `name=` or `code=` token beside the genuine ones. `stack` and `cause` stay
// unrendered: a stack exposes internal paths, and a `cause` is another arbitrary
// value with its own message, stack and enumerable properties.
const MAX_ERROR_MESSAGE_LENGTH = 200;
const ERROR_MESSAGE_UNSAFE_PATTERN = /[\s\u0000-\u001F\u007F-\u009F\u2028\u2029]+/g;
const ERROR_MESSAGE_QUOTE_PATTERN = /"/g;
const ERROR_MESSAGE_TRUNCATION_MARK = ' (truncated)';

// RC1: reads one allowlisted field — the token itself, a fixed marker when the
// field is present in some other shape, `undefined` when absent. Guarded because
// on a hostile value the field can be a getter that throws, and a log path must
// not be the thing that raises an error.
function readErrorToken(value, field) {
  try {
    const token = value[field];
    if (token === undefined || token === null) return undefined;
    if (typeof token !== 'string') return 'non-string';
    if (token.length > MAX_ERROR_TOKEN_LENGTH || !ERROR_TOKEN_PATTERN.test(token)) return 'unloggable';
    return token;
  } catch {
    return 'unreadable';
  }
}

// RC1: renders one free-form message as a bounded, single-line, self-terminating
// quoted field, or `undefined` when sanitising leaves nothing for a field to
// carry. The cap is applied to the raw text before the rewriting, so a value
// that arrives arbitrarily long cannot make the log path itself expensive, and a
// raw length past the cap is exactly what marks the rendered field truncated.
function renderErrorMessage(message) {
  const truncated = message.length > MAX_ERROR_MESSAGE_LENGTH;
  let head = message.slice(0, MAX_ERROR_MESSAGE_LENGTH);
  // A cut must not land inside a surrogate pair, whose remaining half would
  // render as a replacement character instead of the text it came from.
  const lastUnit = head.charCodeAt(head.length - 1);
  if (lastUnit >= 0xd800 && lastUnit <= 0xdbff) head = head.slice(0, -1);
  const text = head
    .replace(ERROR_MESSAGE_UNSAFE_PATTERN, ' ')
    .replace(ERROR_MESSAGE_QUOTE_PATTERN, "'")
    .trim();
  if (text.length === 0) return undefined;
  return `"${truncated ? text + ERROR_MESSAGE_TRUNCATION_MARK : text}"`;
}

// RC1: reads the message the way readErrorToken reads a token, carrying the same
// fixed markers — one present in some other shape, or unreadable because a
// hostile value made it a getter that throws — and `undefined` when it is absent
// or sanitises away. A marker is emitted bare while real content is always
// quoted, so a message whose text is literally `unreadable` cannot be mistaken
// for the marker of one.
function readErrorMessage(value) {
  try {
    const message = value.message;
    if (message === undefined || message === null) return undefined;
    if (typeof message !== 'string') return 'non-string';
    return renderErrorMessage(message);
  } catch {
    return 'unreadable';
  }
}

// RC1: the shared log-safe rendering of any thrown value — a bounded summary of
// the allowlisted tokens and the sanitised message alone, with no stack, `cause`
// or other free-form property content. The message is rendered last, so its own
// text can never be read as the key of a field following it. A primitive is
// reduced to its type, because the value itself is exactly what may be
// sensitive; a thrown or rejected string is the one exception, since there the
// value IS the failure's description, and it is rendered under the same
// discipline as an error's own message.
function describeError(value) {
  if (value === null) return 'type=null';
  if (typeof value === 'string') {
    const message = renderErrorMessage(value);
    return message === undefined ? 'type=string' : `type=string message=${message}`;
  }
  if (typeof value !== 'object') return `type=${typeof value}`;
  const fields = [];
  for (const field of ALLOWLISTED_ERROR_FIELDS) {
    const token = readErrorToken(value, field);
    if (token !== undefined) fields.push(`${field}=${token}`);
  }
  const message = readErrorMessage(value);
  if (message !== undefined) fields.push(`message=${message}`);
  return fields.length > 0 ? fields.join(' ') : 'type=object';
}

// RC1/RC4: a socket fault is remotely triggerable and costs an unauthenticated
// peer almost nothing, so an unbounded record per event would let that peer spend
// the server's stderr buffer, log storage and event-loop budget at will. Each
// fault is recorded per event while the window's quota lasts; the records past it
// are counted, and that count is reported when the window rolls and again on
// every terminal path, so a suppressed fault is still accounted for by number
// even though its own record was dropped, and the cost per window stays fixed.
const FAULT_LOG_WINDOW_MS = 60000;
const FAULT_LOG_WINDOW_LIMIT = 10;
const faultLog = { windowStart: Date.now(), logged: 0, suppressed: 0 };

// RC1/RC4: reports whatever the quota suppressed, as one bounded line holding one
// integer. Called when a window rolls and from every terminal path — the start of
// shutdown, the drain's completion, and the forced stop — because a fault
// suppressed after one report would otherwise be lost at exit, including one a
// peer provokes during the drain itself. The write is contained because those
// callers are terminal: a throw here must not displace the exit that follows it.
function reportSuppressedFaults() {
  if (faultLog.suppressed === 0) return;
  const suppressed = faultLog.suppressed;
  faultLog.suppressed = 0;
  try {
    console.error(`Client fault records suppressed: ${suppressed}.`);
  } catch {
    // The counter is already cleared, so the exit status the caller is about to
    // set is the only signal left; re-reporting a failed report cannot help.
  }
}

// RC1/RC4: records one socket fault. `label` is a fixed string and the error is
// rendered by its allowlisted tokens alone, so the line is bounded whatever the
// peer provoked. Rate limiting is a timestamp comparison rather than a timer, so
// no handle is created that could hold the event loop open during a shutdown.
function logClientFault(label, err) {
  const now = Date.now();
  if (now - faultLog.windowStart >= FAULT_LOG_WINDOW_MS) {
    reportSuppressedFaults();
    faultLog.windowStart = now;
    faultLog.logged = 0;
  }
  if (faultLog.logged >= FAULT_LOG_WINDOW_LIMIT) {
    if (faultLog.suppressed < Number.MAX_SAFE_INTEGER) faultLog.suppressed += 1;
    return;
  }
  faultLog.logged += 1;
  console.error(`${label}: ${describeError(err)}`);
}

const server = http.createServer({ connectionsCheckingInterval: CONNECTIONS_CHECK_INTERVAL_MS }, (req, res) => {
  // RC1: every response this handler produces — success or failure — is written by
  // this one-shot, state-aware responder, so each request yields exactly one
  // terminal response. Guarding only the status/header mutation is not enough: an
  // unconditional res.end() from a later failure path would append its body under
  // an already-committed status, call end() on a finished response and schedule
  // ERR_STREAM_WRITE_AFTER_END, or write to a destroyed response.
  //
  // What makes a response terminal is the state of the response itself, not a flag
  // set on the intent to write one: Node marks `writableEnded` (and `headersSent`)
  // the moment end() succeeds, so that state is an exact record of what the client
  // was actually sent. A flag set before the write also silenced the paths that had
  // sent nothing — which left the 400 below unreachable, because every synchronous
  // path here writes before an asynchronous stream error can arrive, and turned a
  // write that failed having sent nothing into no response at all. Reading the state
  // keeps the response open to a terminal status for exactly as long as one can
  // still be delivered, and closed the moment one has been.
  let responseSpent = false;
  const canRespond = () => !responseSpent && !res.destroyed && !res.writableEnded && !res.headersSent;
  // RC1: true only while the handler's own try/catch below is still on the stack
  // beneath this responder. A write failure is escalated to that catch and nowhere
  // else, so a failure raised from the catch itself, or from an asynchronous stream
  // listener, is reported here rather than re-thrown past the handler — where it
  // would reach the process-level uncaughtException net and stop a healthy server
  // over a single request.
  let writeFailureEscalates = true;
  const respond = (statusCode, headers, body) => {
    if (responseSpent || res.destroyed || res.writableEnded) {
      return;                               // a terminal response is already spent
    }
    if (res.headersSent) {
      // The status line is already on the wire, so this status can no longer be
      // signalled and appending the body would misrepresent it. Abort the message
      // instead, leaving the client a detectably truncated response.
      res.destroy();
      return;
    }
    try {
      res.statusCode = statusCode;
      for (const [name, value] of Object.entries(headers)) {
        res.setHeader(name, value);
      }
      res.end(body);                        // body is omitted for HEAD: headers only
    } catch (writeErr) {
      // RC1: a write that failed having sent nothing leaves the response still able
      // to carry a status, so the failure is escalated to the handler's catch — the
      // one place that maps an unexpected failure onto 500 — instead of ending here
      // with nothing on the wire. The escalated 500 is written by the next respond()
      // call, which proceeds because the state checked above is still writable.
      if (writeFailureEscalates && canRespond()) throw writeErr;
      // Otherwise the socket itself failed mid-write and no status can be delivered,
      // so the responder reports the failure and never raises a secondary one.
      console.error(`Failed to write response: ${describeError(writeErr)}`);
      if (!res.destroyed) res.destroy();
    }
  };

  // RC1: handling the request stream's errors here is what keeps a socket fault
  // from being emitted as an unhandled 'error' event on `req`. The fault arrives
  // asynchronously, so this 400 is delivered only while nothing has been sent on the
  // response yet; a fault on a request whose answer already reached the wire leaves
  // that answer intact and is recorded on its own. The state gate in the responder is
  // what keeps the 400 terminal, so a repeated stream error on the same request
  // stays handled.
  req.on('error', (err) => {
    logClientFault('Request stream error', err);
    respond(400, { 'Content-Type': 'text/plain' }, 'Bad Request\n');
  });
  // RC1: a failed response stream can no longer carry any status, so this listener
  // records the fault and writes nothing, and marks the response spent so no later
  // path attempts a write on it either.
  res.on('error', (err) => {
    logClientFault('Response stream error', err);
    responseSpent = true;
  });

  try {
    // RC3: input validation — GET and HEAD are the only methods this endpoint
    // serves, and a rejection advertises them in `Allow` so a client can correct
    // the request rather than guess at what is supported. The rejection covers every
    // method the Node HTTP layer delivers to this listener, which is the whole of
    // what this handler is able to answer: a malformed method token is answered 400
    // by Node's own request parser before the request reaches here, and CONNECT is
    // routed to the server's 'connect' event rather than to a request listener, so
    // with no listener for it Node closes the tunnel attempt itself. Both of those
    // stay with the protocol layer, because answering them with this 405 would mean
    // adding a connect responder — surface beyond the specified change.
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      respond(405, { 'Allow': 'GET, HEAD', 'Content-Type': 'text/plain' }, 'Method Not Allowed\n');
      return;
    }
    // RC3/RC5: dispatch is method-only by contract; the request target is not a
    // dispatch input, so GET and HEAD answer every path with the same greeting.
    // Preserve original behavior: 200 text/plain "Hello, World!".
    if (req.method === 'HEAD') {
      respond(200, { 'Content-Type': 'text/plain' });
      return;
    }
    respond(200, { 'Content-Type': 'text/plain' }, 'Hello, World!\n');
  } catch (err) {
    // RC1: catch-all so an unexpected handler error returns 500 while the response
    // can still carry one, instead of crashing the process. Once the status is
    // committed the responder writes nothing rather than appending this body. A
    // failure raised while writing a response that had sent nothing arrives here as
    // well, escalated by the responder, so that class is answered with the same 500
    // instead of leaving the client with nothing on the wire.
    writeFailureEscalates = false;          // this write is the last attempt made
    console.error(`Unhandled request error: ${describeError(err)}`);
    respond(500, { 'Content-Type': 'text/plain' }, 'Internal Server Error\n');
  } finally {
    // RC1: the handler's synchronous body has returned, so there is no catch left
    // beneath an asynchronous stream listener for a write failure to escalate to.
    writeFailureEscalates = false;
  }
});

// RC5: apply the three explicit timeouts, replacing Node's version-dependent
// defaults, and assign them before listen() so the policy is in force before the
// first connection is accepted. The header and request deadlines are enforced on
// the scan cadence set at construction above, so each is a ceiling of its
// configured value plus at most one interval — 25 s and 35 s — rather than an
// exact wall-clock instant, and a runtime may hold an idle kept-alive socket a
// little past keepAliveTimeout, which it enforces per socket instead. Bounding
// how many sockets a peer may hold, or how many exchanges it may run through one,
// stays outside the specified change: a socket-count ceiling is a deployment
// control, and the default bind is loopback-only.
server.requestTimeout = REQUEST_TIMEOUT_MS;
server.headersTimeout = HEADERS_TIMEOUT_MS;
server.keepAliveTimeout = KEEP_ALIVE_TIMEOUT_MS;

// RC2/RC4: graceful shutdown + resource cleanup. The ordering below is the
// contract: the pending exit status is escalated and the hard deadline armed
// before the duplicate guard, so a fatal trigger arriving while a signal drain is
// still running exits non-zero instead of being reported as a clean stop, and no
// failure beneath the guard can leave the process running without a hard stop.
let shuttingDown = false;
let shutdownExitCode = 0;

// RC1/RC4: the hard stop is a single retained deadline, established by the first
// trigger to arm it and merely confirmed by any later one, so it stays the
// terminal path however the drain behaves. `finally` carries it through to the
// exit so the non-bypassable process.exit(1) runs whatever the steps above it
// did, and it is unref'd so it never holds open a process that drained early.
let forcedStopTimer = null;
function armForcedStop() {
  if (forcedStopTimer !== null) return;
  forcedStopTimer = setTimeout(() => {
    try {
      console.error('Forced shutdown after timeout.');
      reportSuppressedFaults();            // faults provoked during the drain, before this exit
      // Guarded because the API exists only from Node >= 18.2.
      if (typeof server.closeAllConnections === 'function') server.closeAllConnections();
    } finally {
      process.exit(1);
    }
  }, SHUTDOWN_TIMEOUT_MS);
  forcedStopTimer.unref();
}

// RC2/RC4: completion of the drain. `ERR_SERVER_NOT_RUNNING` means the bind never
// took effect — a signal arriving while an asynchronous address lookup is still in
// flight reaches close() with nothing listening — which is a clean stop rather
// than a close failure, so it exits with the pending status like any other.
function onServerClosed(err) {
  reportSuppressedFaults();                 // faults provoked during the drain, before either exit
  if (err && readErrorToken(err, 'code') !== 'ERR_SERVER_NOT_RUNNING') {
    console.error(`Error during server close: ${describeError(err)}`);
    process.exit(1);
  }
  console.log('Server closed. Exiting.');
  process.exit(shutdownExitCode);           // 0 for a normal signal, 1 for any fatal trigger
}

function shutdown(signal, exitCode = 1) {
  // RC1: escalation is one-way and is the only work a repeat call does, so the
  // guard below still keeps the close sequence, its logging and its cleanup
  // single. A caller that names no status is treated as fatal.
  if (exitCode > shutdownExitCode) shutdownExitCode = exitCode;
  armForcedStop();
  if (shuttingDown) return;                 // guard against double invocation
  shuttingDown = true;
  try {
    console.log(`${signal} received: closing server gracefully...`);
    reportSuppressedFaults();               // what is counted so far; the terminal paths report again
    server.close(onServerClosed);           // stop accepting new connections, drain in-flight
  } finally {
    // RC4: idle keep-alive sockets carry no request and would otherwise make the
    // drain wait out their keep-alive ceiling, so they are released even when a
    // step above threw. Guarded because the API exists only from Node >= 18.2.
    if (typeof server.closeIdleConnections === 'function') server.closeIdleConnections();
  }
}

// RC1/RC2: registered before server.listen(), so a signal or a fatal error
// arriving while the bind is still in flight is already carried by them rather
// than by Node's default disposition, which would end the process before any
// controlled drain.
process.on('SIGTERM', () => shutdown('SIGTERM', 0));
process.on('SIGINT', () => shutdown('SIGINT', 0));

// RC1: process-level safety nets for otherwise-uncaught errors. Both drain the
// server like a signal does, but terminate with failure status.
process.on('uncaughtException', (err) => { console.error(`Uncaught exception: ${describeError(err)}`); shutdown('uncaughtException', 1); });
process.on('unhandledRejection', (reason) => { console.error(`Unhandled promise rejection: ${describeError(reason)}`); shutdown('unhandledRejection', 1); });

// RC1: handle listen errors (EADDRINUSE/EACCES) cleanly instead of an unhandled 'error'.
server.on('error', (err) => {
  // The code selecting the message is read through the same guarded accessor as
  // the message itself, so the handler that reports a failure of the server
  // object cannot raise a second one.
  const code = readErrorToken(err, 'code');
  if (code === 'EADDRINUSE') console.error(`Port ${port} is already in use on ${hostname}.`);
  else if (code === 'EACCES') console.error(`Insufficient privileges to bind ${hostname}:${port}.`);
  else console.error(`Server error: ${describeError(err)}`);
  // RC4: an error that arrives once a shutdown is already running is incidental to
  // a terminal path already in progress, so it is reported without escalating the
  // exit status that trigger already fixed.
  if (shuttingDown) return;
  // RC4: an error raised on a listening server (a failed accept, for example) must
  // stop acceptance and drain through the guarded shutdown path rather than
  // dropping in-flight requests.
  if (server.listening) { shutdown('server error', 1); return; }
  // RC1: a bind failure never accepted a connection, so there is nothing to drain
  // and the process ends immediately with a failure status.
  process.exit(1);
});

// RC1: a bind failure is asynchronous and reaches the server 'error' listener
// above, but listen() also validates its arguments synchronously, throwing
// instead of emitting: a value that survives `Number(process.env.PORT) || 3000`
// but is out of range or fractional is rejected by listen() itself. This
// try/catch keeps that synchronous failure on the startup reporting path, where
// uncaught it would reach the `uncaughtException` net above and report a server
// that never began listening as a failed graceful shutdown.
try {
  server.listen(port, hostname, () => {
    console.log(`Server running at http://${hostname}:${port}/`);
  });
} catch (err) {
  console.error(`Server error: ${describeError(err)}`);
  process.exit(1);
}
