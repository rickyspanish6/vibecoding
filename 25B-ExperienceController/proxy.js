// proxy.js — 25 Broadway Dashboard Server
// ─────────────────────────────────────────
// Serves the dashboard HTML over HTTP  AND
// bridges WebSocket ↔ Barco TCP (port 9090)
//
// Setup (one time):
//   npm install ws
//
// Run:
//   node proxy.js
//
// Open:
//   http://localhost:8080

const http  = require('http');
const https = require('https');
const net   = require('net');
const fs    = require('fs');
const path  = require('path');

let WebSocketServer;
try {
  WebSocketServer = require('ws').WebSocketServer;
} catch (e) {
  console.error('\n  ERROR: "ws" package not found.');
  console.error('  Run:  npm install ws\n');
  process.exit(1);
}

const HTTP_PORT = 8080;
const DIR       = __dirname;

// ── Matrox ConvertIP HTTPS proxy (cookie-based auth) ─────────────────────────
const matroxSessions = new Map(); // ip → 'session_token=VALUE'

function matroxRequest(ip, method, apiPath, cookie, body) {
  return new Promise((resolve, reject) => {
    const bodyBuf = body ? Buffer.from(body) : null;
    const timer   = setTimeout(() => reject(new Error('timeout')), 6000);
    const req = https.request({
      hostname: ip, port: 443, path: apiPath, method,
      rejectUnauthorized: false,
      headers: {
        'Accept': 'application/json',
        ...(bodyBuf ? { 'Content-Type': 'application/json', 'Content-Length': bodyBuf.length } : {}),
        ...(cookie  ? { Cookie: cookie } : {}),
      },
    }, res => {
      clearTimeout(timer);
      const sc = res.headers['set-cookie'];
      let data = '';
      res.on('data', c => { data += c; });
      res.on('end',  () => resolve({
        status: res.statusCode,
        body:   data,
        // Extract "session_token=VALUE" from Set-Cookie (before first semicolon)
        cookie: sc ? [].concat(sc).map(c => c.split(';')[0]).join('; ') : null,
      }));
    });
    req.on('error', e => { clearTimeout(timer); reject(e); });
    if (bodyBuf) req.write(bodyBuf);
    req.end();
  });
}

async function matroxLogin(ip) {
  const r = await matroxRequest(ip, 'POST', '/user/login', null,
    JSON.stringify({ username: 'mofa-admin', password: '25B_m0f4_2443' }));
  console.log(`[Matrox] login ${ip} → HTTP ${r.status}${r.cookie ? ' ✓ cookie' : ' ✗ no cookie'}`);
  if (r.cookie) matroxSessions.set(ip, r.cookie);
  return r;
}

function isNotLoggedIn(res) {
  return res.status === 401 || res.status === 403 ||
    (res.status === 200 && res.body.includes('"Not logged in"'));
}

async function matroxGet(ip, apiPath) {
  if (!matroxSessions.has(ip)) await matroxLogin(ip);
  let res = await matroxRequest(ip, 'GET', apiPath, matroxSessions.get(ip));
  if (isNotLoggedIn(res)) {
    matroxSessions.delete(ip);
    await matroxLogin(ip);
    res = await matroxRequest(ip, 'GET', apiPath, matroxSessions.get(ip));
    console.log(`[Matrox] reauth ${ip} → HTTP ${res.status}`);
  }
  return res;
}

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js':   'application/javascript',
  '.css':  'text/css',
  '.json': 'application/json',
  '.png':  'image/png',
  '.jpg':  'image/jpeg',
  '.svg':  'image/svg+xml',
  '.ico':  'image/x-icon',
};

// ── HTTP file server + Matrox API proxy ──────────────────────────────────────
const httpServer = http.createServer(async (req, res) => {
  // Matrox ConvertIP pass-through: GET|POST /api/matrox/172.16.201.141/device/status
  if ((req.url || '').startsWith('/api/matrox/')) {
    const rest     = (req.url.split('?')[0]).slice('/api/matrox/'.length);
    const slash    = rest.indexOf('/');
    const ip       = slash === -1 ? rest : rest.slice(0, slash);
    const apiPath  = slash === -1 ? '/device/status' : rest.slice(slash);
    console.log(`[Matrox] ${req.method} ${ip}${apiPath}`);
    if (!ip) { res.writeHead(400); res.end('Missing IP in path'); return; }
    try {
      let r;
      if (req.method === 'POST') {
        // Read request body (may be empty for reboot etc.)
        const body = await new Promise(resolve => {
          let buf = '';
          req.on('data', c => { buf += c; });
          req.on('end',  () => resolve(buf));
        });
        if (!matroxSessions.has(ip)) await matroxLogin(ip);
        r = await matroxRequest(ip, 'POST', apiPath, matroxSessions.get(ip), body || null);
        if (r.status === 401 || r.status === 403) {
          matroxSessions.delete(ip);
          await matroxLogin(ip);
          r = await matroxRequest(ip, 'POST', apiPath, matroxSessions.get(ip), body || null);
        }
        console.log(`[Matrox] POST ${ip}${apiPath} → HTTP ${r.status} body=${r.body.slice(0,200)}`);
      } else {
        r = await matroxGet(ip, apiPath);
      }
      console.log(`[Matrox] ${ip} → HTTP ${r.status}`);
      res.writeHead(r.status, {
        'Content-Type':                'application/json',
        'Access-Control-Allow-Origin': '*',
      });
      res.end(r.body || '{}');
    } catch (e) {
      console.log(`[Matrox] ${ip} → ERROR ${e.message}`);
      res.writeHead(502, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
      res.end(JSON.stringify({ error: e.message }));
    }
    return;
  }

  let urlPath = (req.url || '/').split('?')[0];
  if (urlPath === '/') urlPath = '/25broadway_dashboard.html';

  const filePath = path.resolve(DIR, '.' + urlPath);
  if (!filePath.startsWith(DIR)) {
    res.writeHead(403); res.end('Forbidden'); return;
  }

  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end(`Not found: ${urlPath}`);
      return;
    }
    const ext  = path.extname(filePath).toLowerCase();
    const mime = MIME[ext] || 'application/octet-stream';
    res.writeHead(200, {
      'Content-Type': mime,
      'Cache-Control': 'no-cache',
      'Access-Control-Allow-Origin': '*',
    });
    res.end(data);
  });
});

// ── WebSocket → Barco TCP bridge ──────────────────────────────────────────────
const wss = new WebSocketServer({ server: httpServer });

wss.on('connection', (ws, req) => {
  const params = new URLSearchParams((req.url || '').split('?')[1] || '');
  const host   = params.get('host');
  const port   = parseInt(params.get('port') || '9090', 10);

  if (!host) {
    ws.close(1008, 'Missing ?host=');
    return;
  }

  console.log(`[Barco] Connecting → ${host}:${port}`);

  const tcp   = net.createConnection({ host, port });
  let tcpBuf  = '';
  let ready   = false;

  tcp.on('connect', () => {
    ready = true;
    console.log(`[Barco] ✓ Connected  ${host}:${port}`);
  });

  let flushTimer = null;

  function flushTcpBuf() {
    flushTimer = null;
    // Try newline-delimited first
    let nl;
    while ((nl = tcpBuf.indexOf('\n')) !== -1) {
      const line = tcpBuf.slice(0, nl).trim();
      tcpBuf = tcpBuf.slice(nl + 1);
      if (!line) continue;
      console.log(`[Barco] ← ${host}  ${line.slice(0, 120)}`);
      if (ws.readyState === ws.OPEN) ws.send(line);
    }
    // If buffer still has data with no newline, try to parse as complete JSON
    if (tcpBuf.trim()) {
      // Try each } boundary in case multiple objects arrived without newlines
      let remaining = tcpBuf.trim();
      let depth = 0, start = 0;
      for (let i = 0; i < remaining.length; i++) {
        if (remaining[i] === '{') depth++;
        else if (remaining[i] === '}') {
          depth--;
          if (depth === 0) {
            const candidate = remaining.slice(start, i + 1).trim();
            try {
              JSON.parse(candidate); // validate
              console.log(`[Barco] ← ${host}  ${candidate.slice(0, 120)}`);
              if (ws.readyState === ws.OPEN) ws.send(candidate);
              start = i + 1;
            } catch (_) {}
          }
        }
      }
      // Keep only unparsed remainder
      tcpBuf = remaining.slice(start);
    }
  }

  tcp.on('data', chunk => {
    tcpBuf += chunk.toString();
    // Debounce: flush after 10ms of silence so partial TCP segments can arrive
    if (flushTimer) clearTimeout(flushTimer);
    flushTimer = setTimeout(flushTcpBuf, 10);
    // Also flush immediately if we have a complete newline-terminated message
    if (tcpBuf.includes('\n')) flushTcpBuf();
  });

  tcp.on('error', err => {
    console.error(`[Barco] TCP error ${host}: ${err.message}`);
    ws.close(1011, err.message);
  });

  tcp.on('close', () => {
    console.log(`[Barco] TCP closed ${host}`);
    if (ws.readyState === ws.OPEN) ws.close();
  });

  ws.on('message', data => {
    const msg = data.toString();
    console.log(`[Barco] → ${host}  ${msg.slice(0, 100)}`);
    if (ready) {
      tcp.write(msg + '\n');
    } else {
      tcp.once('connect', () => tcp.write(msg + '\n'));
    }
  });

  ws.on('close', () => {
    console.log(`[Barco] WS closed  ${host}`);
    tcp.destroy();
  });

  ws.on('error', err => {
    console.error(`[Barco] WS error: ${err.message}`);
    tcp.destroy();
  });
});

// ── Start ─────────────────────────────────────────────────────────────────────
httpServer.listen(HTTP_PORT, () => {
  console.log('');
  console.log('  ┌──────────────────────────────────────────────┐');
  console.log('  │     25 Broadway — Experience Control          │');
  console.log('  ├──────────────────────────────────────────────┤');
  console.log(`  │  Open  →  http://localhost:${HTTP_PORT}               │`);
  console.log('  └──────────────────────────────────────────────┘');
  console.log('');
  console.log('  Press Ctrl+C to stop.\n');
});
