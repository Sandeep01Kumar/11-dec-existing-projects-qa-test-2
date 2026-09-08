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

// RC5: the headers every response carries whatever its status. They are applied
// by the responder below rather than repeated in each call site's header map, so
// the set is stated once and a response class added later cannot silently omit
// it. `nosniff` is the whole of that set: it holds a browser to the declared
// Content-Type instead of letting it infer a type from the body, and a response
// declaring `text/plain` is still one a browser may otherwise decide to treat as
// something else. A call site that needs its own value for one of these headers
// still wins, because its map is applied after this one.
const BASE_RESPONSE_HEADERS = { 'X-Content-Type-Options': 'nosniff' };

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

// RC3: RFC 7230 §5.4 defines a `Host` field-value as `uri-host [ ":" port ]`, over
// the host grammar of RFC 3986 §3.2.2 — a bracketed IP-literal, an IPv4 address,
// or a reg-name of unreserved characters, sub-delims and percent-encoded octets.
// This pattern is that grammar and nothing wider, so the values the check below
// refuses are the ones the specification itself calls invalid rather than a house
// preference: an empty value, one carrying an inner space, a port with no host
// before it, userinfo or a path appended to the authority, and a value outside the
// grammar the parser passed through, such as one bearing a non-ASCII byte. Each
// branch is length-bounded rather than open-ended — 45 characters is the longest
// IPv6 literal text and 255 the longest DNS name — so an arbitrarily long value is
// refused on its length instead of being scanned in full, and no branch shares a
// leading character with another, so no value can make the match backtrack.
const HOST_PATTERN = /^(?:\[[0-9A-Fa-f:.]{2,45}\]|(?:[A-Za-z0-9._~!$&'()*+,;=-]|%[0-9A-Fa-f]{2}){1,255})(?::[0-9]{1,5})?$/;

// RC3: whether the request carries exactly one `Host` field with a valid value.
// Occurrences are counted in `req.rawHeaders`, which keeps every field line as it
// arrived, because `req.headers.host` collapses several of them to the FIRST one:
// answering a request that carried two conflicting `Host` fields would mean
// answering on a value that need not be the one anything in front of this server
// read, which is the disagreement RFC 7230 §5.4 requires a server to refuse rather
// than resolve on the sender's behalf. An absent field is a defect only from
// HTTP/1.1, the version that made it mandatory, so it is refused for that version
// and tolerated for HTTP/1.0; Node's own parser already rejects the HTTP/1.1 case
// ahead of this handler, and stating the rule here makes the handler's answer
// correct on its own terms rather than by inheritance from the runtime.
function hasValidHostField(req) {
  const raw = req.rawHeaders;
  let occurrences = 0;
  for (let i = 0; i < raw.length; i += 2) {
    // The length is tested first because only a four-character field name can be
    // `host`, so a peer sending many long header names cannot make this loop spend
    // a lowercased copy of each one to find that out.
    if (raw[i].length === 4 && raw[i].toLowerCase() === 'host') {
      occurrences += 1;
      if (occurrences > 1) return false;  // more than one Host field
    }
  }
  const host = req.headers.host;
  if (host === undefined) return req.httpVersionMajor === 1 && req.httpVersionMinor === 0;
  return HOST_PATTERN.test(host);
}

// RC3: RFC 7230 §5.3 admits exactly four request-target forms, and only two of them
// can reach a GET or HEAD here: origin-form, which always begins with `/`, and
// absolute-form, a scheme followed by `://` and an authority. Authority-form is
// refused by Node's own parser before this handler, and asterisk-form is defined
// only for a server-wide OPTIONS. This pattern tests which form a target is in and
// nothing whatever about its content — no path is inspected, compared or routed on
// — so a target belonging to no form is refused as the malformed request line it
// is, while every well-formed path keeps answering identically. Matching only the
// start is the whole of the test: the characters a target may contain are the
// parser's business, and it has already rejected the ones HTTP forbids. The scheme
// is left unconstrained beyond its own grammar because an origin server ignores
// the authority of an absolute-form target rather than acting on it.
const REQUEST_TARGET_PATTERN = /^(?:\/|[A-Za-z][A-Za-z0-9+.-]*:\/\/)/;

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
      // RC5: the baseline first and the caller's map second, so setHeader's
      // overwrite leaves a call site holding whatever value it passed for a
      // header the baseline also names. Both loops sit inside this try, so a
      // failure to set either kind stays on the escalation path below instead of
      // bypassing it.
      for (const [name, value] of Object.entries(BASE_RESPONSE_HEADERS)) {
        res.setHeader(name, value);
      }
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
    // RC3: input validation of the request line and of the `Host` field, ahead of
    // the dispatch below, because a message that is not a well-formed HTTP/1.x
    // request has no method or target worth dispatching on — answering it at all,
    // even with the 405 the allow-list would give it, treats malformed input as a
    // well-formed request for something. Node's own parser refuses most malformed
    // forms before this handler is reached; these two are the ones it accepts and
    // hands over, so they are refused here, through the same bounded, generic 400
    // every other client-fault path in this file returns.
    //
    // An HTTP/0.9 simple request carries no version and no header section, so it is
    // not a valid HTTP/1.1 message and cannot be answered as one: its client reads
    // no status line and no header block, and would render the ones written back to
    // it as body text. Refusing it also keeps this server from being the lenient
    // end of a chain that disagrees with a proxy about where one message ends.
    if (req.httpVersionMajor < 1) {
      respond(400, { 'Content-Type': 'text/plain' }, 'Bad Request\n');
      return;
    }
    // A duplicate, empty or out-of-grammar `Host` is what RFC 7230 §5.4 requires a
    // 400 for, and it is required whatever this endpoint itself reads: the field
    // names the authority a request was addressed to, so accepting a value this
    // server would resolve differently from whatever sits in front of it is the
    // standing precondition for Host-header poisoning and for a front-end and a
    // back-end disagreeing about which request they are handling. It is refused
    // here rather than left to the deployment, so the guarantee belongs to the
    // server itself and not to the fact that nothing currently routes on the value.
    if (!hasValidHostField(req)) {
      respond(400, { 'Content-Type': 'text/plain' }, 'Bad Request\n');
      return;
    }
    // RC3: input validation — GET and HEAD are the only methods this endpoint
    // serves, and a rejection advertises them in `Allow` so a client can correct
    // the request rather than guess at what is supported. This covers every method
    // the Node HTTP layer delivers to a request listener, which is not quite every
    // method a client can send: an unrecognised method token is rejected by Node's
    // request parser before the request reaches here, and CONNECT is routed to the
    // server's 'connect' event rather than to a request listener. Both are refused
    // with this same 405, byte for byte, by the protocol-layer listeners registered
    // near the end of this file — so the contract holds for every request form the
    // server can observe, not only for the subset that arrives here. A method token
    // that is genuinely malformed rather than merely unsupported still earns the
    // parser's 400 there; that distinction is drawn where those listeners are.
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      respond(405, { 'Allow': 'GET, HEAD', 'Content-Type': 'text/plain' }, 'Method Not Allowed\n');
      return;
    }
    // RC3: the request target is checked for its form before a greeting is written.
    // Dispatch here is method-only by contract, so without this check a target that
    // is no valid request target at all would be answered as though it were an
    // ordinary path: the asterisk-form `*`, which RFC 7230 §5.3.4 reserves for a
    // server-wide OPTIONS, and equally a variant such as `*?x=1` that belongs to no
    // form the specification defines and that a check for the single character `*`
    // would wave through. What is refused is the form and not any path — `/`,
    // `/anything`, a deep or percent-encoded path, a scheme-relative `//host` and a
    // path that merely contains an asterisk all keep answering with the same
    // greeting, and no path routing is introduced. The check sits below the
    // allow-list because `OPTIONS *`, the one request line the asterisk-form is
    // defined for, asks for a method this endpoint does not serve, and the 405 the
    // allow-list already gives it, naming what is served in `Allow`, is the more
    // specific of the two answers.
    if (!REQUEST_TARGET_PATTERN.test(req.url)) {
      respond(400, { 'Content-Type': 'text/plain' }, 'Bad Request\n');
      return;
    }
    // RC3/RC5: dispatch is otherwise method-only by contract; no path is a dispatch
    // input, so GET and HEAD answer every path with the same greeting.
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

// RC1/RC3: the protocol layer's share of the method contract. Two request forms
// never reach the request listener above, so the 405 it writes cannot cover
// them, and each was answered in a way the contract does not describe: a method
// token Node's request parser does not recognise is rejected before any
// application code runs, which sent a bare 400 carrying no `Allow` and naming
// nothing the endpoint accepts, and CONNECT is routed to the server's 'connect'
// event, which with no listener registered destroyed the socket without sending
// a single byte. Both are answered here with the same 405 the handler writes, so
// "every method other than GET and HEAD is refused with 405 and an `Allow`
// header" holds for every request form this server can observe rather than only
// for the subset the parser hands upward.
//
// Neither path has a ServerResponse to write through — the parser has rejected
// the message, or the connection was claimed for a tunnel — so both responses
// are assembled as raw bytes here. That is why the status line and every header
// are spelled out in full instead of being set through the response helpers
// above, and why the byte sequence is kept identical to the handler's 405 down
// to the header order: which layer refused a request is this server's business,
// not something a client should be able to read off the response.
//
// Deliberately not registered: an 'upgrade' listener. With none, Node delivers a
// request carrying `Upgrade` to the request listener as the ordinary GET it also
// is and never switches protocols, which RFC 7230 §6.7 explicitly permits and
// which is the behavior this endpoint wants; claiming those sockets here would
// replace a correct 200 with a refusal.
const PROTOCOL_405_BODY = 'Method Not Allowed\n';

// RC3: the method tokens this refusal applies to. The parser raises the same
// invalid-method error for a legitimate extension method it happens not to know
// and for a request line that is not HTTP at all, so the two are separated on
// the shape of what arrived rather than on the error code: the whole request
// line must be well-formed, and its method must be a bounded, uppercase RFC 7230
// token. A lowercase `get`, a 200-character token, `GE T`, an absent method and
// binary noise therefore keep the 400 they earn — they are malformed, not merely
// unsupported — and nothing is answered 405 on the strength of its first few
// bytes alone. The scan window bounds the work done on a rejected packet, which
// may be as large as the runtime's whole header ceiling.
const PROTOCOL_REQUEST_LINE_SCAN_BYTES = 8192;
const UNSUPPORTED_METHOD_REQUEST_LINE = /^[A-Z][A-Z0-9!#$%&'*+.^_`|~-]{0,19} [\x21-\x7e]{1,4096} HTTP\/1\.[01]\r\n/;

// RC1: Node's own client-error replies, reproduced verbatim because registering
// a 'clientError' listener suppresses the whole of its default handling — the
// listener below is then answerable for every request the parser rejects, not
// just the one case it changes. Each of these is the exact byte sequence this
// runtime sends for that error: a malformed message, a header block past the
// size ceiling, oversized chunk extensions, and a request that never completed
// inside its deadline. Verbatim is the whole of the intent, so the baseline
// response headers are deliberately not added to these four: each carries no body
// and declares no Content-Type, which is the only thing the baseline's `nosniff`
// acts on, and altering the bytes this runtime already sends for a parser
// rejection would change cases this listener exists to leave alone.
const PROTOCOL_400_RESPONSE = 'HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n';
const PROTOCOL_431_RESPONSE = 'HTTP/1.1 431 Request Header Fields Too Large\r\nConnection: close\r\n\r\n';
const PROTOCOL_413_RESPONSE = 'HTTP/1.1 413 Payload Too Large\r\nConnection: close\r\n\r\n';
const PROTOCOL_408_RESPONSE = 'HTTP/1.1 408 Request Timeout\r\nConnection: close\r\n\r\n';

// RC1: selects the reply for one parser error code. A switch rather than a
// lookup table, so a code that happens to name an inherited object property
// cannot resolve to anything other than the generic rejection.
function protocolErrorResponse(code) {
  switch (code) {
    case 'HPE_HEADER_OVERFLOW': return PROTOCOL_431_RESPONSE;
    case 'HPE_CHUNK_EXTENSIONS_OVERFLOW': return PROTOCOL_413_RESPONSE;
    case 'ERR_HTTP_REQUEST_TIMEOUT': return PROTOCOL_408_RESPONSE;
    default: return PROTOCOL_400_RESPONSE;
  }
}

// RC5: the responder's baseline headers, rendered as raw header lines for the
// responses this layer has to assemble by hand. The set itself is declared once,
// in BASE_RESPONSE_HEADERS, and the responder applies it ahead of each call
// site's own map, so it precedes those headers on the wire; emitting it in that
// same position here is what keeps this layer's 405 byte-identical to the
// handler's rather than merely similar to it. The lines are derived from that one
// constant rather than restated, because a second literal copy is exactly what
// would silently miss a header added to the baseline later.
function baseResponseHeaderLines() {
  let lines = '';
  for (const [name, value] of Object.entries(BASE_RESPONSE_HEADERS)) {
    lines += `${name}: ${value}\r\n`;
  }
  return lines;
}

// RC3/RC5: the 405 as a complete, self-terminating HTTP/1.1 message, carrying
// the same headers in the same order and the same body as the handler's 405, so
// the two differ only in the instant each was generated at. That identity is the
// point rather than a nicety: which layer refused a request is this server's
// business, and a header present on one of the two 405s and absent from the other
// is enough to read it off the response, so the baseline headers every response
// carries are emitted here too, in the position the responder puts them in.
// `Content-Length` and `Connection: close` are what make it unambiguous on a
// socket that is about to be released, and `Date` is what every other response
// from this server carries.
function protocol405Response() {
  return 'HTTP/1.1 405 Method Not Allowed\r\n' +
    baseResponseHeaderLines() +
    'Allow: GET, HEAD\r\n' +
    'Content-Type: text/plain\r\n' +
    `Date: ${new Date().toUTCString()}\r\n` +
    'Connection: close\r\n' +
    `Content-Length: ${Buffer.byteLength(PROTOCOL_405_BODY)}\r\n` +
    '\r\n' +
    PROTOCOL_405_BODY;
}

// RC1: a socket answered at this layer carries no ServerResponse, and on the
// 'connect' path it arrives with no 'error' listener of Node's own either, so
// one is supplied: a reset from a peer that has already gone would otherwise be
// emitted as an unhandled 'error' event and reach the process-level net, taking
// a healthy server down over one refused probe. It is attached only when the
// socket has none, so the client-error path — where Node has already attached
// its own — keeps behaving exactly as it did, and the fault is recorded through
// the rate-limited client-fault path because it is remotely triggerable.
function guardSocketErrors(socket) {
  if (socket.listenerCount('error') === 0) {
    socket.on('error', (err) => logClientFault('Protocol socket error', err));
  }
}

// RC1/RC4: whether a raw response may still be put on this socket. One that is
// no longer writable is out of the question, and a response must never be
// appended to a message that is part-way through transmission — that would
// corrupt what its client is mid-way through reading. A message whose end() has
// already been called is complete, so a response after it is an ordinary
// pipelined response rather than corruption, which is what lets a refusal still
// reach a client that pipelined the refused request behind a served one.
// `_httpMessage` is the same state the runtime's own client-error default
// consults to make this decision.
function canWriteRawResponse(socket) {
  if (!socket.writable) return false;
  const inFlight = socket._httpMessage;
  return !(inFlight && inFlight.headersSent && !inFlight.writableEnded);
}

// RC4: writes one terminal raw response and releases the socket. The FIN travels
// with the bytes and the handle is destroyed as soon as they are flushed, so a
// refused connection is never left half-open waiting on a peer that may never
// close its own end, and nothing about it survives the exchange.
function endWithRawResponse(socket, response) {
  guardSocketErrors(socket);
  try {
    if (!canWriteRawResponse(socket)) {
      socket.destroy();                     // nothing can be delivered; just release it
      return;
    }
    socket.end(response, () => { if (!socket.destroyed) socket.destroy(); });
  } catch (err) {
    // RC1: the refusal itself failing is still only one connection's problem.
    logClientFault('Protocol response write error', err);
    if (!socket.destroyed) socket.destroy();
  }
}

// RC3: true only for the one client error the 405 applies to — the parser
// rejected the method token, and what it rejected is otherwise a well-formed
// request line.
//
// The packet handed over is the whole segment the parser was reading, which may
// carry earlier complete messages ahead of the one that failed, so the request
// line is located rather than assumed: parsing stopped inside the offending
// method token, and the line that token belongs to begins after the last CRLF at
// or before that point. Testing the packet's first bytes instead would test the
// wrong request — a valid GET pipelined ahead of binary noise reads as a
// well-formed request line and would earn the noise a 405.
//
// The packet is read defensively besides: it is raw bytes a peer sent, so it is
// examined only as a bounded prefix, only when it really is a buffer, and never
// in a way that can raise a second failure out of this path.
function isUnsupportedMethodToken(err) {
  if (readErrorToken(err, 'code') !== 'HPE_INVALID_METHOD') return false;
  try {
    const packet = err.rawPacket;
    if (!Buffer.isBuffer(packet)) return false;
    const head = packet.subarray(0, PROTOCOL_REQUEST_LINE_SCAN_BYTES).toString('latin1');
    const stopped = Number.isInteger(err.bytesParsed) && err.bytesParsed > 0
      ? Math.min(err.bytesParsed, head.length)
      : 0;
    const boundary = head.lastIndexOf('\r\n', stopped);
    return UNSUPPORTED_METHOD_REQUEST_LINE.test(boundary === -1 ? head : head.slice(boundary + 2));
  } catch {
    return false;                           // an unreadable packet names no method
  }
}

// RC3: CONNECT asks this server to become a tunnel, which it does not offer, so
// the request is refused with the ordinary 405 and the connection is closed
// without ever being upgraded. The bytes the peer sent after the request line
// are handed to this listener as a third argument and are deliberately left
// unread, so nothing a peer sends is relayed anywhere and no tunnel exists at
// any point — the refusal is now observable where previously the peer received
// nothing at all.
server.on('connect', (req, socket) => {
  endWithRawResponse(socket, protocol405Response());
});

// RC1/RC3: every request the parser rejects arrives here, and registering this
// listener means Node no longer answers any of them itself. One case is answered
// differently from its default and every other exactly as before: a well-formed
// request line whose method is an unrecognised token now gets the 405 its
// unsupported method earns, with the `Allow` header that tells the client what
// this endpoint does accept, instead of a bare 400 that told it nothing. The
// parser is left strict — nothing here relaxes what it accepts — so every
// malformed message it refuses stays refused, on the same bytes as before.
server.on('clientError', (err, socket) => {
  try {
    if (isUnsupportedMethodToken(err)) {
      endWithRawResponse(socket, protocol405Response());
      return;
    }
    guardSocketErrors(socket);
    // Node's default, reproduced: reply only while no response is in flight with
    // its header block already on the wire — appending to one would corrupt the
    // message its client is part-way through reading — and then release the
    // socket. `_httpMessage` is the same state the runtime's own default handler
    // consults for that decision. The failure is not re-emitted onto the socket
    // by destroy(): it is already in hand here, and re-emitting it is the one way
    // this path could raise an 'error' event with nothing left to handle it.
    const inFlight = socket._httpMessage;
    if (socket.writable && !(inFlight && inFlight.headersSent)) {
      socket.write(protocolErrorResponse(readErrorToken(err, 'code')));
    }
    socket.destroy();
  } catch (responseErr) {
    logClientFault('Client error response failed', responseErr);
    if (!socket.destroyed) socket.destroy();
  }
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
