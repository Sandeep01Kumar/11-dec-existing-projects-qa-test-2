// Zero-dependency HTTP server built on Node's core `http` module.
// Serves the GET / greeting contract — 200 `text/plain` with the body
// `Hello, World!\n` — behind request validation, standardized error responses,
// explicit request-processing ceilings, graceful shutdown and connection cleanup.
// Supported runtimes are the approved Node LTS lines the startup guard below
// enforces; no behavior of this file is claimed on a release outside that range,
// including behavior that Node does not document.
const http = require('http');

// RC5: the Node release is the only dependency a zero-dependency server has, and
// the timeout, parser and shutdown semantics this file configures are decided by
// that release, so the supported range is enforced here rather than asserted in a
// comment: `package.json` declares no `engines` field and is out of scope for this
// change, which leaves this the only place an unapproved runtime can be refused.
// Each entry is an LTS line still supported upstream, floored at or above the
// release that promoted that line to LTS. Reconciled with the Node.js release
// schedule and security-release history on 2026-09-08: 18.x and 20.x ended
// support on 2025-04-30 and 2026-04-30, and the newest security releases were
// 22.23.2 and 24.18.1, published 2026-07-29 and carrying CVE-2026-56846 to
// CVE-2026-56848, CVE-2026-56850, CVE-2026-58039 to CVE-2026-58045 and
// CVE-2026-48934, per
// https://nodejs.org/en/blog/vulnerability/july-2026-security-releases.
// This table gates the release line; running at or above the newest security
// release within that line is a deployment control, not a startup gate.
// Revisit the table whenever a listed line ends support or a new line enters LTS.
const APPROVED_NODE_LINES = [
  { major: 22, minimum: [22, 12, 0], supportEnds: '2027-04-30' },
  { major: 24, minimum: [24, 11, 0], supportEnds: '2028-04-30' },
];

// RC5: fail closed on a runtime outside that range, before the server object, the
// request handler and the signal handlers exist, so an unapproved release stops at
// startup instead of serving traffic under semantics it was never validated for.
// All three ways out of the range are refused: a line past end of life receives no
// further security fixes, an odd-numbered line never enters LTS, and a line newer
// than the table has not been validated against this file. Only a bare
// `major.minor.patch` version is accepted, so a nightly, release-candidate or
// otherwise unparsable build is refused rather than assumed current, and nothing
// but the parsed numbers reaches the diagnostic.
function requireApprovedRuntime(version) {
  const parsed = /^(\d+)\.(\d+)\.(\d+)$/.exec(String(version));
  const running = parsed ? parsed.slice(1, 4).map(Number) : null;
  const line = running ? APPROVED_NODE_LINES.find((entry) => entry.major === running[0]) : undefined;
  // The major already matches the entry, so the floor is decided by minor, then patch.
  if (line && (running[1] > line.minimum[1]
    || (running[1] === line.minimum[1] && running[2] >= line.minimum[2]))) {
    return;
  }
  const approved = APPROVED_NODE_LINES
    .map((entry) => `${entry.major}.x >= ${entry.minimum.join('.')} (supported through ${entry.supportEnds})`)
    .join(', ');
  const reported = running ? running.join('.') : 'with an unrecognized version';
  console.error(`Unapproved Node.js runtime ${reported}: this server runs only on ${approved}.`);
  process.exit(1);
}

requireApprovedRuntime(process.versions.node);

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

// RC5: granularity of the header and request deadlines. Node enforces them from
// an interval scan over the tracked connections rather than a per-socket timer,
// so an expired connection is only reaped at the next scan and the effective
// ceiling is the configured deadline plus up to one whole interval. The 30-second
// default interval therefore lets a connection that never completes its headers
// outlive the 20-second ceiling by tens of seconds; a one-second interval keeps
// both effective ceilings within a second of their configured values, at the cost
// of one unref'd tick per second across at most MAX_CONNECTIONS entries. A
// runtime without the setting keeps its own scan granularity.
const CONNECTIONS_CHECKING_INTERVAL_MS = 1000;

// RC5: buffer added to the idle keep-alive deadline. Supported runtimes arm the
// idle socket timer three different ways: from `keepAliveTimeout` alone; from
// `keepAliveTimeout` plus a buffer fixed at one second in the runtime itself; or
// from `keepAliveTimeout` plus the buffer this server supplies, which the runtime
// otherwise defaults to one second. Only the third reads the value below, so it
// is assigned only where the runtime already defines the property rather than
// left as an inert one that would misstate the ceiling. Pinning it to zero makes
// the `timeout` the response's own `Keep-Alive` header advertises the real idle
// ceiling there, matching the runtimes that add no buffer; the ones with a fixed
// internal buffer keep their extra second and hold an idle socket that much
// longer. Closing at the advertised deadline is safe here because GET and HEAD
// are idempotent: a client that races the deadline can retry on a new connection.
const KEEP_ALIVE_TIMEOUT_BUFFER_MS = 0;

// RC4/RC5: finite active-resource ceilings. The deadlines above bound how long
// one socket may stay idle or incomplete, but not how many sockets a peer may
// hold or how many exchanges it may run through one of them: Node leaves
// `maxConnections` unset and `maxRequestsPerSocket` at 0, both unlimited, so a
// peer answering inside every deadline can pin descriptors, parser state and
// event-loop time without ever timing out. MAX_CONNECTIONS caps accepted sockets
// far enough below a 1024-descriptor soft limit to leave room for stdio and the
// listening socket; Node closes anything beyond it at accept time, before request
// state exists and without a log line per rejected connection.
// MAX_REQUESTS_PER_SOCKET recycles a kept-alive HTTP/1.1 connection after a
// bounded number of exchanges: the last permitted response carries
// `Connection: close` and a further request on that socket is answered 503, so no
// single connection accumulates state indefinitely. Node also advertises the
// ceiling to the client as the `max` parameter of the `Keep-Alive` response
// header, so a well-behaved client reconnects before reaching it.
const MAX_CONNECTIONS = 512;
const MAX_REQUESTS_PER_SOCKET = 1000;

// RC1: operator diagnostics are themselves a security surface, so no thrown value
// or rejection reason is ever handed to `console.*`. Console formatting would
// render that value's message, stack, file paths, `cause` chain and every
// enumerable property — any of which can carry a credential, a token or personal
// data — and it consults a custom inspection hook found on the value, which runs
// caller-supplied code inside handlers that include the fatal ones, where it can
// throw again or consume unbounded time. Only the three allowlisted fields below
// are read, and a field's value is emitted only when it already has the short
// plain-identifier shape that Node's own `name`, `code` and `syscall` carry.
// Every other property is excluded, and so is any value of those three that is
// not such a token, so no free-form content from the value reaches the log.
const MAX_ERROR_TOKEN_LENGTH = 48;
// RC1: a plain identifier token: no whitespace, no punctuation beyond `_`, `.`
// and `-`, and therefore no control character, quote or newline that could forge
// a second log record. Anything else is replaced by a fixed marker, not escaped.
const ERROR_TOKEN_PATTERN = /^[A-Za-z_][A-Za-z0-9_.-]*$/;
const ALLOWLISTED_ERROR_FIELDS = ['name', 'code', 'syscall'];

// RC1: reads one allowlisted field: the token itself when it is a plain bounded
// identifier, a fixed marker when the field is present in some other shape, and
// `undefined` when it is absent. The read is guarded because on a hostile value
// the field can be a getter that throws or returns anything at all, and a log
// path must not be the thing that raises an error.
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

// RC1: the shared log-safe rendering of any thrown value or rejection reason — a
// bounded summary built only from the three allowlisted token fields, carrying no
// message, no stack, no `cause` and no free-form property content. A primitive is
// reduced to its type alone, because the value itself is exactly what may be
// sensitive.
function describeError(value) {
  if (value === null) return 'type=null';
  if (typeof value !== 'object') return `type=${typeof value}`;
  const fields = [];
  for (const field of ALLOWLISTED_ERROR_FIELDS) {
    const token = readErrorToken(value, field);
    if (token !== undefined) fields.push(`${field}=${token}`);
  }
  return fields.length > 0 ? fields.join(' ') : 'type=object';
}

// RC1/RC4: both fault kinds below are remotely triggerable and cost an
// unauthenticated peer almost nothing — a reset connection, a socket dropped
// mid-exchange. One stderr record per event would let that peer spend the
// server's formatting time, stderr buffer memory, log storage and event-loop
// budget at will, so these faults are accounted for in fixed memory instead: the
// kind set is closed and pre-created so no traffic can grow it, the counters
// saturate, each kind announces itself once, and the running totals are reported
// at most once per interval and once more at shutdown. The log therefore records
// aggregate state changes rather than individual client faults.
const CLIENT_FAULT_REPORT_INTERVAL_MS = 60000;
const CLIENT_FAULT_KINDS = [
  'request-stream',              // socket fault while a request was being read
  'response-stream',             // socket fault while a response was being written
];
const clientFaultTotals = Object.create(null);
const clientFaultAnnounced = Object.create(null);
for (const kind of CLIENT_FAULT_KINDS) {
  clientFaultTotals[kind] = 0;
  clientFaultAnnounced[kind] = false;
}
let unreportedClientFaults = 0;
let lastClientFaultReport = Date.now();

// RC1/RC4: emits the running totals — every field a fixed kind name and an
// integer, so the line's length and cardinality are bounded — but only when
// something has happened since the last report, and only once per interval
// unless `force` asks for the final tally. Rate limiting is a timestamp
// comparison rather than a timer, so no handle is created that could hold the
// event loop open or fire during a shutdown.
function reportClientFaults(force) {
  if (unreportedClientFaults === 0) return;
  const now = Date.now();
  if (!force && now - lastClientFaultReport < CLIENT_FAULT_REPORT_INTERVAL_MS) return;
  lastClientFaultReport = now;
  unreportedClientFaults = 0;
  const totals = CLIENT_FAULT_KINDS
    .filter((kind) => clientFaultTotals[kind] > 0)
    .map((kind) => `${kind}=${clientFaultTotals[kind]}`)
    .join(' ');
  console.error(`Client fault totals: ${totals}`);
}

// RC1/RC4: records one occurrence of a known fault kind. An unknown kind is
// ignored rather than added, so the key set stays exactly as declared above.
// `detail` is an already-validated token — a Node error code, or a code and the
// status it was answered with — and appears only in that kind's single
// announcement. Whatever a peer provokes therefore costs at most one
// detail-bearing record per kind for the process lifetime, plus the
// interval-limited totals above and the final tally at shutdown.
function recordClientFault(kind, detail) {
  if (clientFaultTotals[kind] === undefined) return;
  if (clientFaultTotals[kind] < Number.MAX_SAFE_INTEGER) clientFaultTotals[kind] += 1;
  unreportedClientFaults += 1;
  if (!clientFaultAnnounced[kind]) {
    clientFaultAnnounced[kind] = true;
    const qualifier = detail === undefined ? '' : ` (${detail})`;
    console.error(`Client fault ${kind}${qualifier}: counted from here on, not logged per event.`);
  }
  reportClientFaults(false);
}

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
      return;
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
      // socket failed mid-write, there is nothing left to send. The failure is
      // reported by its allowlisted fields alone, never by handing the thrown
      // value to the log.
      console.error(`Failed to write response: ${describeError(writeErr)}`);
      if (!res.destroyed) res.destroy();
    }
  };

  // RC1: handling the request stream's errors here is what keeps a socket fault
  // from being emitted as an unhandled 'error' event on `req`. The 400 is
  // attempted only while the response can still carry it, and the one-shot
  // responder — not a single-fire listener — is what keeps it terminal, so a
  // repeated stream error on the same request stays handled. The fault is counted
  // rather than logged per event, because a peer can cause it cheaply and at will.
  req.on('error', (err) => {
    recordClientFault('request-stream', readErrorToken(err, 'code'));
    respond(400, { 'Content-Type': 'text/plain' }, 'Bad Request\n');
  });
  // RC1: a failed response stream can no longer carry any status, so this listener
  // records the fault and writes nothing, and marks the response spent so no later
  // path attempts a write on it either.
  res.on('error', (err) => {
    recordClientFault('response-stream', readErrorToken(err, 'code'));
    responded = true;
  });

  try {
    // RC3: enforce the public method contract — GET and HEAD are the only methods
    // this endpoint serves, and a rejection advertises them in `Allow` so a client
    // can correct the request rather than guess at what is supported.
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
    // can still carry one, instead of crashing the process. After the status is
    // committed, or once the response has ended or been destroyed, the responder
    // writes nothing rather than appending this body under the previous status.
    console.error(`Unhandled request error: ${describeError(err)}`);
    respond(500, { 'Content-Type': 'text/plain' }, 'Internal Server Error\n');
  }
});

// RC4/RC5: replace Node's version-dependent defaults with the policy above, and
// do it here so the whole policy is in force before listen() accepts anything.
// Node reads the scan interval when the server starts listening, the keep-alive
// buffer when a response finishes and the two ceilings on each accepted socket
// and request, so assigning them to the server is what puts them into effect.
// The resulting effective ceilings are one second beyond each scanned deadline:
// no more than 21s to complete request headers and 31s to complete a request,
// and an idle kept-alive socket held for the advertised 5s, or a second longer
// on a runtime whose own fixed keep-alive buffer this server cannot override.
server.requestTimeout = REQUEST_TIMEOUT_MS;
server.headersTimeout = HEADERS_TIMEOUT_MS;
server.keepAliveTimeout = KEEP_ALIVE_TIMEOUT_MS;
server.connectionsCheckingInterval = CONNECTIONS_CHECKING_INTERVAL_MS;
server.maxConnections = MAX_CONNECTIONS;
server.maxRequestsPerSocket = MAX_REQUESTS_PER_SOCKET;
// RC5: the keep-alive buffer is configurable only on a runtime that defines the
// property itself, so it is read before it is written: assigning it anywhere else
// would add an inert property that claims a ceiling the runtime does not apply.
if (typeof server.keepAliveTimeoutBuffer === 'number') {
  server.keepAliveTimeoutBuffer = KEEP_ALIVE_TIMEOUT_BUFFER_MS;
}

// RC2/RC4: the ordering is the contract. The pending exit status is escalated and
// the hard deadline armed first, which is what makes every stage after them
// expendable; then admission stops, idle sockets go immediately, and in-flight
// requests are left to drain. The trade-off is deliberate: draining is bounded
// rather than unlimited, so a request that will not finish costs at most
// SHUTDOWN_TIMEOUT_MS and is then aborted with failure status instead of holding
// the process open.
let shuttingDown = false;
let shutdownExitCode = 0;

// RC1/RC4: runs one stage of the terminal path with its synchronous failure
// contained, so a failing stage can neither abort the stages after it nor escape
// into the fatal handlers, where it would re-enter shutdown() only to be discarded
// by the duplicate guard. The failure escalates the exit status and is named by
// stage alone: passing the thrown value to `console` would re-admit the hazard
// being contained, since formatting an arbitrary value can invoke a custom
// inspection hook that throws in turn.
function runCleanupStage(stage, run) {
  try {
    run();
  } catch {
    if (shutdownExitCode < 1) shutdownExitCode = 1;
    try {
      console.error(`Shutdown stage failed: ${stage}.`);
    } catch {
      // The report failed too; the escalated status is the only signal left.
    }
  }
}

// RC1/RC4: the hard stop is a single retained deadline, armed before any fallible
// stage runs and never cleared. Arming it first is what makes those stages
// expendable: whatever one of them throws, and however many later fatal events the
// duplicate guard discards, this timer remains the terminal path. It is unref'd so
// it cannot itself hold open a process whose draining finished early.
let forcedStopTimer = null;
function armForcedStop() {
  if (forcedStopTimer !== null) return;
  try {
    forcedStopTimer = setTimeout(forceStop, SHUTDOWN_TIMEOUT_MS);
    forcedStopTimer.unref();
  } catch {
    // Nothing would bound the cleanup that follows an unschedulable deadline, so
    // stop now with failure status rather than enter it unbounded.
    process.exit(1);
  }
}

// RC1/RC4: the forced stop cannot be defeated from inside itself — each stage is
// contained, and `finally` carries the sequence through to the exit so the
// non-bypassable process.exit(1) runs whatever the stages did.
function forceStop() {
  try {
    runCleanupStage('forced-stop report', () => {
      console.error('Forced shutdown after timeout.');
    });
    runCleanupStage('active-connection release', () => {
      if (typeof server.closeAllConnections === 'function') server.closeAllConnections();
    });
  } finally {
    process.exit(1);
  }
}

// RC2/RC4: completion of the drain, run as a contained stage because Node invokes
// it: a throw here would surface as an uncaughtException and re-enter shutdown()
// only to be discarded by the duplicate guard.
function onServerClosed(err) {
  runCleanupStage('close completion', () => {
    if (err) { console.error(`Error during server close: ${describeError(err)}`); process.exit(1); }
    console.log('Server closed. Exiting.');
    process.exit(shutdownExitCode);         // 0 for a normal signal, 1 for any fatal trigger
  });
}

function shutdown(signal, exitCode = 1) {
  // RC1: escalate the pending status before the duplicate-shutdown guard, so a
  // fatal trigger that arrives while a signal shutdown is still draining exits
  // non-zero instead of being reported as a clean stop. Escalation is one-way
  // and is the only work a repeat call does, so the guard below still keeps the
  // close sequence, its logging and its cleanup single. A caller that names no
  // status is treated as fatal.
  if (exitCode > shutdownExitCode) shutdownExitCode = exitCode;
  // RC1/RC4: arm the hard deadline before the guard and before every fallible
  // stage below, so it is established by the first trigger to reach this line and
  // merely confirmed by any later one. No failure beneath it can leave the process
  // running without a hard stop.
  armForcedStop();
  if (shuttingDown) return;                 // guard against double invocation
  shuttingDown = true;
  try {
    runCleanupStage('shutdown announcement', () => {
      console.log(`${signal} received: closing server gracefully...`);
    });
    runCleanupStage('client-fault tally', () => {
      reportClientFaults(true);             // final tally, so counted faults are not lost at exit
    });
    runCleanupStage('server close', () => {
      server.close(onServerClosed);         // stop accepting new connections, drain in-flight
    });
  } finally {
    // Idle keep-alive sockets carry no request and would otherwise make the drain
    // wait out their keep-alive ceiling, so they are released even when an earlier
    // stage failed. Guarded because the API exists only from Node >= 18.2.
    runCleanupStage('idle-connection release', () => {
      if (typeof server.closeIdleConnections === 'function') server.closeIdleConnections();
    });
  }
}

// RC1/RC2: the signal and fatal-event handlers are registered before
// `server.listen()`, so a signal or a fatal error arriving while the bind is still
// in flight is already carried by them rather than by Node's default disposition,
// which would end the process before any controlled drain and without the
// lifecycle diagnostics and exit-status policy above.
process.on('SIGTERM', () => shutdown('SIGTERM', 0));
process.on('SIGINT', () => shutdown('SIGINT', 0));

// RC1: process-level safety nets for otherwise-uncaught errors. Both drain the
// server like a signal does, but terminate with failure status.
process.on('uncaughtException', (err) => { console.error(`Uncaught exception: ${describeError(err)}`); shutdown('uncaughtException', 1); });
process.on('unhandledRejection', (reason) => { console.error(`Unhandled promise rejection: ${describeError(reason)}`); shutdown('unhandledRejection', 1); });

// RC1: handle listen errors (EADDRINUSE/EACCES) cleanly instead of an unhandled 'error'.
server.on('error', (err) => {
  // RC1: the code that selects the message is read through the same guarded
  // accessor as the message itself, so nothing in this handler — the one that
  // reports a failure of the server object — can raise a second error of its own.
  const code = readErrorToken(err, 'code');
  if (code === 'EADDRINUSE') console.error(`Port ${port} is already in use on ${hostname}.`);
  else if (code === 'EACCES') console.error(`Insufficient privileges to bind ${hostname}:${port}.`);
  else console.error(`Server error: ${describeError(err)}`);
  // RC4: an error raised on a listening server (a failed accept, for example),
  // or one raised while a shutdown is already running, must stop acceptance and
  // drain through the guarded shutdown path rather than dropping in-flight
  // requests.
  if (server.listening || shuttingDown) { shutdown('server error', 1); return; }
  // RC1: a bind failure never accepted a connection, so there is nothing to
  // drain and the process ends immediately with a failure status.
  process.exit(1);
});

// RC1: a bind failure — the address already in use, insufficient privileges, an
// address that cannot be bound — is asynchronous and reaches the server 'error'
// listener above. listen() also validates its arguments and the server's own
// state synchronously, throwing instead of emitting: a value that survives
// `Number(process.env.PORT) || 3000` but is out of range or fractional is
// rejected by listen() itself, not before it. This try/catch keeps that
// synchronous failure on the startup reporting path: uncaught, it would reach the
// process-level `uncaughtException` net above, which drains a running server and
// would report a server that never began listening as a failed graceful shutdown.
try {
  server.listen(port, hostname, () => {
    console.log(`Server running at http://${hostname}:${port}/`);
  });
} catch (err) {
  console.error(`Server error: ${describeError(err)}`);
  process.exit(1);
}
