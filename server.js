// server.js — hardened HTTP server for hao-backprop-test.
// Built on the Node.js built-in `http` module only (zero third-party dependencies).
// Preserves the original "Hello, World!" behavior on GET / while adding error
// handling, input validation, graceful shutdown, resource cleanup, and robust
// HTTP request processing. Compatible with Node.js >= 18 LTS (installed: v22).
const http = require('http');

// RC5: env-overridable config, preserving original defaults (127.0.0.1:3000).
// RC5: `HOST` and `PORT` are the only untrusted input read at startup, so each is
// resolved and validated here — before `createServer()` and `listen()` — and a
// malformed value fails fast with a named configuration error. Truthiness alone
// cannot do this job: it turns a present-but-empty, whitespace-only or
// non-numeric `PORT` into the default, so a supplied value silently loses
// precedence, while a fractional, negative, hexadecimal or out-of-range value
// stays truthy and reaches `listen()`, where Node core throws
// `ERR_SOCKET_BAD_PORT` synchronously at module scope — before any server or
// process handler exists to report it.
const DEFAULT_HOST = '127.0.0.1';
const DEFAULT_PORT = 3000;
const MIN_PORT = 1;
const MAX_PORT = 65535;
const MAX_HOSTNAME_LENGTH = 253;
const IPV6_GROUP_COUNT = 8;
const MAX_ECHOED_VALUE_LENGTH = 64;

// RFC 1123 host name: dot-separated labels of 1-63 alphanumerics and hyphens,
// never leading or trailing a label, with an optional root dot.
const HOSTNAME_PATTERN = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\.?$/;

// Every control character is rejected in a host value and escaped in any echoed
// value: C0 (`\u0000`-`\u001f`), DEL, the C1 block (`\u0080`-`\u009f`, which
// includes NEL and the CSI terminal introducer) and the Unicode line and
// paragraph separators. All of them can alter log or terminal rendering.
const CONTROL_CHARACTER_PATTERN = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/;
const CONTROL_CHARACTER_PATTERN_GLOBAL = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g;

// RC1: a bad configuration value is unrecoverable and is detected before any
// listener exists, so it is reported on stderr and the process exits non-zero
// instead of throwing an uncaught stack trace. This never returns to its caller.
function exitWithConfigurationError(message) {
  console.error(`Invalid configuration: ${message}`);
  process.exit(1);
}

// Environment values are untrusted text: echo them quoted, escaped and
// length-capped so a malformed value cannot inject control characters into logs.
function describeValue(value) {
  const text = String(value);
  const clipped = text.length > MAX_ECHOED_VALUE_LENGTH
    ? `${text.slice(0, MAX_ECHOED_VALUE_LENGTH)}...`
    : text;
  // JSON quoting handles the surrounding quotes, backslashes and C0 controls;
  // every control character it leaves verbatim — DEL, the C1 block and the
  // line/paragraph separators — is then rendered as a visible `\uXXXX` escape,
  // so no echoed value can emit an invisible control into the log.
  return JSON.stringify(clipped).replace(CONTROL_CHARACTER_PATTERN_GLOBAL, (character) =>
    `\\u${character.codePointAt(0).toString(16).padStart(4, '0')}`);
}

// Dotted-quad IPv4 literal. Leading zeros are rejected because a zero-padded
// octet is ambiguous (decimal here, octal to some resolvers).
function isIpv4Address(value) {
  const octets = value.split('.');
  return octets.length === 4 && octets.every((octet) =>
    /^(?:0|[1-9][0-9]{0,2})$/.test(octet) && Number(octet) <= 255);
}

// IPv6 literal, allowing one `::` compression marker, an optional `%zone`
// suffix, and a trailing IPv4 form (`::ffff:127.0.0.1`) that occupies two of
// the eight 16-bit groups.
function isIpv6Address(value) {
  const [address, zoneId, ...extraZones] = value.split('%');
  if (extraZones.length > 0) return false;
  if (zoneId !== undefined && !/^[0-9A-Za-z._~-]+$/.test(zoneId)) return false;
  const halves = address.split('::');
  if (halves.length > 2) return false;
  const compressed = halves.length === 2;
  const groups = (halves[0] === '' ? [] : halves[0].split(':'))
    .concat(compressed && halves[1] !== '' ? halves[1].split(':') : []);
  let groupCount = groups.length;
  if (groups.length > 0 && groups[groups.length - 1].includes('.')) {
    if (!isIpv4Address(groups.pop())) return false;
    groupCount += 1;
  }
  if (!groups.every((group) => /^[0-9A-Fa-f]{1,4}$/.test(group))) return false;
  return compressed ? groupCount < IPV6_GROUP_COUNT : groupCount === IPV6_GROUP_COUNT;
}

// RC5: `HOST` resolution — the configurable-bind root cause; RC3 covers inbound
// request validation, in the handler below. An absent key keeps the original
// default; a present value is trimmed and must be a syntactically valid IPv4
// address, IPv6 literal (bare or bracketed) or host name. Only this normalized,
// validated value is used by `listen()` and by the diagnostics below.
function resolveHost(rawHost) {
  if (rawHost === undefined) return DEFAULT_HOST;
  const value = String(rawHost).trim();
  if (value === '') {
    exitWithConfigurationError(`HOST is set but empty; unset it to use the default ${DEFAULT_HOST}, or supply a host name or IP address.`);
  }
  if (CONTROL_CHARACTER_PATTERN.test(value)) {
    exitWithConfigurationError(`HOST ${describeValue(value)} contains control characters; supply a plain host name or IP address.`);
  }
  // Brackets are valid only around an IPv6 literal, so they are stripped to the
  // bare address `listen()` expects and any other bracketed text is rejected
  // rather than silently unwrapped into a different host.
  const bracketed = value.length > 1 && value.startsWith('[') && value.endsWith(']');
  const candidate = bracketed ? value.slice(1, -1) : value;
  if (bracketed && !isIpv6Address(candidate)) {
    exitWithConfigurationError(`HOST ${describeValue(value)} is bracketed, which is valid only for an IPv6 literal.`);
  }
  if (isIpv4Address(candidate) || isIpv6Address(candidate)) return candidate;
  // An all-numeric dotted value is a malformed IPv4 literal rather than a host
  // name, so reject it here instead of deferring to a lookup that cannot resolve.
  if (/^[0-9.]+$/.test(candidate)) {
    exitWithConfigurationError(`HOST ${describeValue(value)} is a malformed IPv4 address.`);
  }
  if (candidate.length > MAX_HOSTNAME_LENGTH || !HOSTNAME_PATTERN.test(candidate)) {
    exitWithConfigurationError(`HOST ${describeValue(value)} is not a valid host name or IP address.`);
  }
  return candidate;
}

// RC5: `PORT` resolution — the same configurable-bind root cause. An absent key
// keeps the original default; a present value must be a plain decimal integer
// inside the listenable range. The digits-only test is the explicit
// textual-form policy `Number()` lacks: it
// rejects hexadecimal (`0x1f` would otherwise become 31), scientific,
// fractional, signed and `Infinity` spellings instead of silently converting
// them or collapsing them into the default.
function resolvePort(rawPort) {
  if (rawPort === undefined) return DEFAULT_PORT;
  const value = String(rawPort).trim();
  if (value === '') {
    exitWithConfigurationError(`PORT is set but empty; unset it to use the default ${DEFAULT_PORT}, or supply an integer between ${MIN_PORT} and ${MAX_PORT}.`);
  }
  if (!/^[0-9]+$/.test(value)) {
    exitWithConfigurationError(`PORT ${describeValue(value)} is not a decimal integer between ${MIN_PORT} and ${MAX_PORT}.`);
  }
  const parsed = Number(value);
  // Port 0 is rejected deliberately: it asks the OS for an ephemeral port, but
  // the startup log reports the configured port, so the advertised address would
  // not be the bound one. Callers must name a fixed port.
  if (parsed === 0) {
    exitWithConfigurationError(`PORT 0 requests an OS-assigned ephemeral port, which is not supported; supply a fixed port between ${MIN_PORT} and ${MAX_PORT}.`);
  }
  if (!Number.isInteger(parsed) || parsed < MIN_PORT || parsed > MAX_PORT) {
    exitWithConfigurationError(`PORT ${describeValue(value)} is outside the supported range ${MIN_PORT}-${MAX_PORT}.`);
  }
  return parsed;
}

const hostname = resolveHost(process.env.HOST);
const port = resolvePort(process.env.PORT);

// RC5: explicit timeouts (ms) for deterministic behavior across Node versions.
const REQUEST_TIMEOUT_MS = 30000;
const HEADERS_TIMEOUT_MS = 20000;
const KEEP_ALIVE_TIMEOUT_MS = 5000;
// RC4/RC5: general per-socket inactivity ceiling. Node leaves `server.timeout`
// at 0 — no inactivity guard at all — unless it is assigned, and re-applies
// `server.timeout || 0` to a socket after each keep-alive idle period. It is
// deliberately the outermost ceiling (5s keep-alive idle < 20s headers < 30s
// whole request < 60s socket inactivity) so the HTTP-level deadlines, which can
// answer with a status code, always act first and this one only reaps sockets
// they do not cover, such as connections making no parser progress. No
// `'timeout'` listener is registered, so Node destroys the socket when it fires.
const SOCKET_TIMEOUT_MS = 60000;
const SHUTDOWN_TIMEOUT_MS = 10000;

const server = http.createServer((req, res) => {
  // RC1: every response this handler produces — success or failure — is written by
  // this one-shot, state-aware responder, so each request yields exactly one
  // terminal response. Guarding only the status/header mutation is not enough: an
  // unconditional res.end() from a later failure path would append its body under
  // an already-committed status, call end() on a finished response and schedule
  // ERR_STREAM_WRITE_AFTER_END (a second response error in the error handler
  // itself), or write to a destroyed response.
  let responded = false;
  const respond = (statusCode, headers, body) => {
    if (responded) return;                  // first writer wins; later paths are no-ops
    responded = true;
    if (res.destroyed || res.writableEnded) {
      return;                               // nothing can be delivered: write nothing
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
      // The responder must never throw or emit a secondary response error: if the
      // socket failed mid-write, there is nothing left to send.
      console.error('Failed to write response:', writeErr);
      if (!res.destroyed) res.destroy();
    }
  };

  // RC1: per-request stream error handling (never crash the process on socket
  // errors). The 400 is delivered only while the response can still carry it; once
  // a response has been issued the listener writes nothing at all, and the one-shot
  // responder — not a single-fire listener — is what keeps the 400 terminal, so a
  // repeat stream error stays handled here instead of escalating to an unhandled
  // 'error' event. The whole error value is logged, because reading only
  // err.message blanks the line for an Error without a message, prints undefined
  // for a non-Error value, and throws — losing the diagnostic entirely — when
  // message is a throwing getter.
  req.on('error', (err) => {
    console.error('Request stream error:', err);
    respond(400, { 'Content-Type': 'text/plain' }, 'Bad Request\n');
  });
  // RC1: a failed response stream can no longer carry any status, so this listener
  // reports the failure and writes nothing, and marks the response spent so no
  // later path attempts a write on it either.
  res.on('error', (err) => {
    console.error('Response stream error:', err);
    responded = true;
  });

  try {
    // RC3: input validation — only GET/HEAD are supported; reject others with 405.
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      respond(405, { 'Allow': 'GET, HEAD', 'Content-Type': 'text/plain' }, 'Method Not Allowed\n');
      return;
    }
    // RC3/RC5: the binding path contract is method-only dispatch, deliberately
    // path-independent. req.url is not a dispatch input and there is no 404 branch,
    // so GET/HEAD on any request target receive the same greeting. AAP §0.5.1's
    // validated target implementation, §0.5.2's change instructions and §0.6.1's
    // exhaustive change list all map RC3 to this method allow-list alone, §0.6.2
    // and §0.8 forbid adding routing or any behavior beyond the five named concern
    // areas, and this file's processed schema states the same rule explicitly. The
    // §0.2 RC3/RC5 diagnosis also mentions path/URL and 404 gaps; the specification
    // that supersedes it does not adopt them, so path routing is out of contract
    // here rather than merely unimplemented.
    //
    // Preserve original behavior: 200 text/plain "Hello, World!".
    if (req.method === 'HEAD') {
      respond(200, { 'Content-Type': 'text/plain' });
      return;
    }
    respond(200, { 'Content-Type': 'text/plain' }, 'Hello, World!\n');
  } catch (err) {
    // RC1: catch-all so an unexpected handler error returns 500 while the response
    // can still carry one, instead of crashing the process. After the status is
    // committed, or once the response has ended or been destroyed, the responder
    // writes nothing rather than appending this body under the previous status.
    console.error('Unhandled request error:', err);
    respond(500, { 'Content-Type': 'text/plain' }, 'Internal Server Error\n');
  }
});

// RC5: apply explicit timeouts.
server.requestTimeout = REQUEST_TIMEOUT_MS;
server.headersTimeout = HEADERS_TIMEOUT_MS;
server.keepAliveTimeout = KEEP_ALIVE_TIMEOUT_MS;
server.timeout = SOCKET_TIMEOUT_MS;

// RC1/RC2/RC4: exit-status intent shared by every terminal path. A normal signal
// finishes with EXIT_SUCCESS; every fatal trigger (uncaught exception, unhandled
// rejection, an error on a live server, a close failure, the forced timeout)
// finishes with EXIT_FAILURE, so a supervisor can tell a crash from a clean stop.
const EXIT_SUCCESS = 0;
const EXIT_FAILURE = 1;

// RC1: upper bound on how long a hard stop waits for already-queued diagnostics
// to reach a redirected or piped stdout/stderr before terminating regardless.
const FLUSH_TIMEOUT_MS = 1000;

let exitIntent = EXIT_SUCCESS;

// RC1: escalate the intended exit status monotonically — failure never downgrades
// back to success — and publish it through `process.exitCode` so the status is
// already correct if the drained event loop ends the process on its own.
function recordExitIntent(code) {
  if (code > exitIntent) exitIntent = code;
  process.exitCode = exitIntent;
  return exitIntent;
}

// RC1/RC4: `process.exit()` calls `reallyExit()` synchronously, so bytes still
// queued on an asynchronous stdout/stderr (a pipe on POSIX, a TTY on Windows)
// are discarded and required lifecycle diagnostics go missing. Ordinary terminal
// paths therefore only record the status and let the drained event loop end the
// process; this is the single hard stop, reserved for the forced-shutdown timer,
// and it waits for queued writes to complete first — bounded by FLUSH_TIMEOUT_MS
// so a stalled reader can never keep the process alive.
function exitAfterFlush(code) {
  recordExitIntent(code);
  let exited = false;
  let pending = 0;
  const hardExit = () => {
    if (exited) return;                     // exactly one hard stop, whichever path arrives first
    exited = true;
    process.exit(exitIntent);
  };
  for (const stream of [process.stdout, process.stderr]) {
    // A synchronous stream has already written everything; only an async one buffers.
    if (stream && stream.writable && stream.writableLength > 0) {
      pending += 1;
      stream.write('', () => { pending -= 1; if (pending === 0) hardExit(); });
    }
  }
  if (pending === 0) { hardExit(); return; }
  setTimeout(hardExit, FLUSH_TIMEOUT_MS).unref();
}

// RC2/RC4: graceful shutdown + resource cleanup.
let shuttingDown = false;
function shutdown(signal, intendedExitCode = EXIT_FAILURE) {
  // RC1: record the outcome BEFORE the duplicate-shutdown guard, so a fatal
  // trigger arriving during an in-progress shutdown still upgrades the pending
  // result to failure instead of being swallowed by the guard. A caller that
  // names no status is treated as fatal.
  recordExitIntent(intendedExitCode);
  if (shuttingDown) return;                 // guard against double invocation
  shuttingDown = true;
  console.log(`${signal} received: closing server gracefully...`);
  server.close((err) => {                   // stop accepting new connections, drain in-flight
    if (err) { console.error('Error during server close:', err); recordExitIntent(EXIT_FAILURE); return; }
    console.log('Server closed. Exiting.');
    process.exitCode = exitIntent;          // 0 for a normal signal, 1 for any fatal trigger
  });
  if (typeof server.closeIdleConnections === 'function') server.closeIdleConnections(); // Node >= 18.2
  setTimeout(() => {                         // force exit if draining exceeds the timeout
    console.error('Forced shutdown after timeout.');
    if (typeof server.closeAllConnections === 'function') server.closeAllConnections();
    exitAfterFlush(EXIT_FAILURE);
  }, SHUTDOWN_TIMEOUT_MS).unref();
}

// RC1/RC2: register the signal and fatal-event handlers BEFORE `server.listen()`.
// Node validates the bind arguments synchronously inside listen(), so an invalid
// environment-derived port throws there — the safety nets must already exist.
process.on('SIGTERM', () => shutdown('SIGTERM', EXIT_SUCCESS));
process.on('SIGINT', () => shutdown('SIGINT', EXIT_SUCCESS));

// RC1: process-level safety nets for otherwise-uncaught errors. Both drain the
// server like a signal does, but terminate with failure status.
process.on('uncaughtException', (err) => { console.error('Uncaught exception:', err); shutdown('uncaughtException', EXIT_FAILURE); });
process.on('unhandledRejection', (reason) => { console.error('Unhandled promise rejection:', reason); shutdown('unhandledRejection', EXIT_FAILURE); });

// RC1: handle listen errors (EADDRINUSE/EACCES) cleanly instead of an unhandled 'error'.
server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') console.error(`Port ${port} is already in use on ${hostname}.`);
  else if (err.code === 'EACCES') console.error(`Insufficient privileges to bind ${hostname}:${port}.`);
  else console.error('Server error:', err);
  // RC4: an error raised on a listening server (a failed accept, for example),
  // or one raised while a shutdown is already running, must stop acceptance and
  // drain through the guarded shutdown path rather than dropping in-flight
  // requests; routing it through shutdown() also escalates the pending outcome
  // to failure when a shutdown is already under way.
  if (server.listening || shuttingDown) { shutdown('server error', EXIT_FAILURE); return; }
  // A bind failure never accepted a connection, so there is nothing to drain and
  // no handle is left open. Record the failure status and let the drained loop
  // end the process, which keeps this diagnostic from being truncated by an
  // immediate process.exit().
  recordExitIntent(EXIT_FAILURE);
});

// RC3/RC5: protocol-level rejection surface. Two classes of inbound request never reach
// the request callback above: Node dispatches CONNECT to the server-level 'connect' event
// and hands parser failures to 'clientError'. Both are answered here, on the bare socket,
// with the same standardized plain-text contract the request callback applies. Registering
// these listeners also takes ownership of the connection: once a listener exists Node
// neither writes its own default response nor destroys the socket.
const REJECTED_SOCKET_LINGER_MS = 1000;

// Builds a complete raw HTTP/1.1 response for sockets that have no `http.ServerResponse`
// attached. `extraHeaders` carries response-specific headers (for example `Allow`) and is
// emitted ahead of the fixed Content-Type/Content-Length/Connection headers.
function buildRawResponse(statusCode, statusMessage, body, extraHeaders) {
  const headerLines = [`HTTP/1.1 ${statusCode} ${statusMessage}`]
    .concat(extraHeaders || [])
    .concat([
      'Content-Type: text/plain',
      `Content-Length: ${Buffer.byteLength(body)}`,
      'Connection: close',
    ]);
  return `${headerLines.join('\r\n')}\r\n\r\n${body}`;
}

// RC1/RC4: reports whether a response for the socket's current exchange is still open, so
// a raw write can never be interleaved into one. Node attaches the in-progress
// `http.ServerResponse` to the socket for the duration of an exchange and detaches it once
// that response finishes, which is what distinguishes a response that is still being
// written from one that has already completed. A byte counter cannot make that distinction:
// `socket.bytesWritten` accumulates over the socket's whole lifetime, so it stays non-zero
// for every reused keep-alive connection and would silence the rejection for the rest of
// that connection's life. A response object without a readable ended state is treated as
// open, which is the conservative answer.
function responseInFlight(socket) {
  const openResponse = socket._httpMessage;
  return Boolean(openResponse) && openResponse.writableEnded !== true;
}

// RC1/RC4: writes a raw response and then releases the socket, returning whether the
// response was actually sent so callers log what happened rather than what was intended.
// An error listener is attached first because a socket handed to these listeners carries
// none of its own, and without one a late ECONNRESET/EPIPE would surface as an uncaught
// exception. The write is made only while the socket is still writable and no response for
// the current exchange is still open, so a response mid-stream can never be corrupted
// while a connection that has merely completed earlier exchanges is still answered;
// passing a null response skips the write deliberately. Either way the socket is released:
// it is destroyed once the response flushes and, through an unref'd linger timer that
// cannot hold up a graceful shutdown, even if it never does.
function rejectSocket(socket, rawResponse) {
  if (!socket || socket.destroyed) {
    return false;
  }
  socket.on('error', (err) => { console.error('Rejected socket error:', err); });
  if (rawResponse && socket.writable && !responseInFlight(socket)) {
    socket.end(rawResponse, () => { socket.destroy(); });
    setTimeout(() => { socket.destroy(); }, REJECTED_SOCKET_LINGER_MS).unref();
    return true;
  }
  socket.destroy();
  return false;
}

// RC5: maps a parser or timeout failure code to the status it is answered with. Codes are
// the ones Node's HTTP parser emits (verified on Node v22): oversized headers, chunk
// extension overflow and the headers/request timeout each get their specific status, and
// every other malformed request gets 400 — the status Node itself would use, but with a
// Content-Type and a body.
function clientErrorResponse(code) {
  switch (code) {
    case 'HPE_HEADER_OVERFLOW':
      return { statusCode: 431, statusMessage: 'Request Header Fields Too Large' };
    case 'HPE_CHUNK_EXTENSIONS_OVERFLOW':
      return { statusCode: 413, statusMessage: 'Payload Too Large' };
    case 'ERR_HTTP_REQUEST_TIMEOUT':
      return { statusCode: 408, statusMessage: 'Request Timeout' };
    default:
      return { statusCode: 400, statusMessage: 'Bad Request' };
  }
}

// RC3: CONNECT is a valid HTTP method that Node routes to this event instead of the
// request callback, so without this listener it escapes the GET/HEAD allow-list entirely
// and the connection is closed with no response at all. Reject it with exactly the 405
// contract every other unsupported method receives.
server.on('connect', (req, socket) => {
  const allowHeader = 'Allow: GET, HEAD';
  const response = buildRawResponse(405, 'Method Not Allowed', 'Method Not Allowed\n', [allowHeader]);
  if (rejectSocket(socket, response)) {
    console.error('CONNECT is not supported: responded 405 and closed the socket.');
  } else {
    console.error('CONNECT is not supported: the socket could not take a response, released it.');
  }
});

// RC5: malformed HTTP — a bad request line, an invalid header token, oversized headers, a
// malformed chunk — and header/request timeouts all fail inside the parser, before the
// request callback, where Node's default answer is a bare status line with no Content-Type
// and no body. Answer each one deterministically instead. Only `err.code` is logged: the
// parser error also carries `rawPacket`, which must never reach the log or the client.
server.on('clientError', (err, socket) => {
  const code = (err && err.code) || 'UNKNOWN';
  if (code === 'ECONNRESET' || !socket || !socket.writable) {
    console.error(`Client protocol error (${code}): peer is gone, releasing the socket.`);
    rejectSocket(socket, null);
    return;
  }
  const { statusCode, statusMessage } = clientErrorResponse(code);
  const response = buildRawResponse(statusCode, statusMessage, `${statusMessage}\n`);
  // A parser failure can also arrive while a response is still mid-stream — a pipelined
  // request failing before the previous response has finished, for instance. Writing into
  // that response would corrupt it, so the socket can only be released, and the log records
  // which of the two happened. A failure on a connection whose earlier exchanges have all
  // completed is answered normally.
  if (rejectSocket(socket, response)) {
    console.error(`Client protocol error (${code}): responded ${statusCode} and closed the socket.`);
  } else {
    console.error(`Client protocol error (${code}): a response was mid-stream, released the socket without one.`);
  }
});

// RC1: listen() validates its arguments synchronously and throws — rather than
// emitting 'error' — for an out-of-range, fractional, negative or infinite port,
// so the call itself is guarded and the failure context is preserved.
try {
  server.listen(port, hostname, () => {
    console.log(`Server running at http://${hostname}:${port}/`);
  });
} catch (err) {
  console.error('Server error:', err);
  recordExitIntent(EXIT_FAILURE);
}
