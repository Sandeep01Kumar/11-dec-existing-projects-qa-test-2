// server.js — hardened HTTP server for hao-backprop-test.
// Built on the Node.js built-in `http` module only (zero third-party dependencies).
// Preserves the original "Hello, World!" behavior on GET / while adding error
// handling, input validation, graceful shutdown, resource cleanup, and robust
// HTTP request processing. Compatible with Node.js >= 18 LTS (installed: v22).
const http = require('http');

// RC5: env-overridable config, preserving original defaults (127.0.0.1:3000).
const hostname = process.env.HOST || '127.0.0.1';
const port = Number(process.env.PORT) || 3000;

// RC5: explicit timeouts (ms) for deterministic behavior across Node versions.
const REQUEST_TIMEOUT_MS = 30000;
const HEADERS_TIMEOUT_MS = 20000;
const KEEP_ALIVE_TIMEOUT_MS = 5000;
const SHUTDOWN_TIMEOUT_MS = 10000;

const server = http.createServer((req, res) => {
  // RC1: per-request stream error handling (never crash the process on socket errors).
  req.on('error', (err) => {
    console.error('Request stream error:', err.message);
    if (!res.headersSent) { res.statusCode = 400; res.setHeader('Content-Type', 'text/plain'); }
    res.end('Bad Request\n');
  });
  res.on('error', (err) => { console.error('Response stream error:', err.message); });

  try {
    // RC3: input validation — only GET/HEAD are supported; reject others with 405.
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.statusCode = 405;
      res.setHeader('Allow', 'GET, HEAD');
      res.setHeader('Content-Type', 'text/plain');
      res.end('Method Not Allowed\n');
      return;
    }
    // Preserve original behavior: 200 text/plain "Hello, World!".
    res.statusCode = 200;
    res.setHeader('Content-Type', 'text/plain');
    if (req.method === 'HEAD') { res.end(); return; }
    res.end('Hello, World!\n');
  } catch (err) {
    // RC1: catch-all so an unexpected handler error returns 500 instead of crashing.
    console.error('Unhandled request error:', err);
    if (!res.headersSent) { res.statusCode = 500; res.setHeader('Content-Type', 'text/plain'); }
    res.end('Internal Server Error\n');
  }
});

// RC5: apply explicit timeouts.
server.requestTimeout = REQUEST_TIMEOUT_MS;
server.headersTimeout = HEADERS_TIMEOUT_MS;
server.keepAliveTimeout = KEEP_ALIVE_TIMEOUT_MS;

// RC1: handle listen errors (EADDRINUSE/EACCES) cleanly instead of an unhandled 'error'.
server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') console.error(`Port ${port} is already in use on ${hostname}.`);
  else if (err.code === 'EACCES') console.error(`Insufficient privileges to bind ${hostname}:${port}.`);
  else console.error('Server error:', err);
  process.exit(1);
});

server.listen(port, hostname, () => {
  console.log(`Server running at http://${hostname}:${port}/`);
});

// RC2/RC4: graceful shutdown + resource cleanup.
let shuttingDown = false;
function shutdown(signal) {
  if (shuttingDown) return;                 // guard against double invocation
  shuttingDown = true;
  console.log(`${signal} received: closing server gracefully...`);
  server.close((err) => {                   // stop accepting new connections, drain in-flight
    if (err) { console.error('Error during server close:', err); process.exit(1); }
    console.log('Server closed. Exiting.');
    process.exit(0);
  });
  if (typeof server.closeIdleConnections === 'function') server.closeIdleConnections(); // Node >= 18.2
  setTimeout(() => {                         // force exit if draining exceeds the timeout
    console.error('Forced shutdown after timeout.');
    if (typeof server.closeAllConnections === 'function') server.closeAllConnections();
    process.exit(1);
  }, SHUTDOWN_TIMEOUT_MS).unref();
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

// RC1: process-level safety nets for otherwise-uncaught errors.
process.on('uncaughtException', (err) => { console.error('Uncaught exception:', err); shutdown('uncaughtException'); });
process.on('unhandledRejection', (reason) => { console.error('Unhandled promise rejection:', reason); shutdown('unhandledRejection'); });
