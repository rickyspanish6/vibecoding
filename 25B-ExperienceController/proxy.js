// proxy.js — 25 Broadway Dashboard Server
// ─────────────────────────────────────────
// Serves the dashboard HTML over HTTP, bridges WebSocket ↔ Barco TCP (port 9090),
// forwards scene triggers to Control Center (show-control software), reports
// connection status for Control Center / projectors / Matrox,
// proxies Matrox ConvertIP HTTPS, and stores shared settings (settings.json)
//
// Run with Docker (recommended):
//   docker compose up -d --build
//
// Or directly:
//   npm install   (one time)
//   npm start     (= node proxy.js)
//
// Open:
//   http://localhost:8080
//
// Env: PORT (default 8080), DATA_DIR (folder for settings.json, default: this folder)

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

const VERSION       = require('./package.json').version;
const HTTP_PORT     = parseInt(process.env.PORT || '8080', 10);
const DIR           = __dirname;
// DATA_DIR lets Docker keep settings.json on a volume, outside the app folder
const DATA_DIR      = process.env.DATA_DIR || DIR;
const SETTINGS_FILE = path.join(DATA_DIR, 'settings.json');

// ── Shared settings (settings.json) ──────────────────────────────────────────
// Single source of truth for every browser that opens the dashboard.
// Holds scene mappings, tags, the Control Center address and the Matrox login. The Matrox password
// is never sent back to the browser.
const SETTINGS_DEFAULTS = {
  ccIp:           '172.16.0.20',
  sceneMap:       {},
  sceneTags:      {},
  knownTags:      [],
  sceneSortOrder: 'default',
  projectorConfig: null,   // null = use the list built into the dashboard
  cipConfig:       null,   // null = use the list built into the dashboard
  matrox:         { username: '', password: '' },
};
const SHARED_KEYS = ['ccIp', 'sceneMap', 'sceneTags', 'knownTags', 'sceneSortOrder', 'projectorConfig', 'cipConfig'];

// Device lists: the dashboard validates imports in detail; the server only makes
// sure it stores a well-formed list (or null to restore the built-in one).
function validDeviceConfig(cfg, listKey) {
  if (cfg === null) return true;
  return !!cfg && typeof cfg === 'object' && Array.isArray(cfg[listKey]) && cfg[listKey].length > 0 &&
    cfg[listKey].length <= 256 && cfg[listKey].every(d => d && typeof d.name === 'string' && typeof d.ip === 'string');
}

// The dashboard page gets the device lists inline, so they exist before its script runs
function injectServerConfig(html) {
  const cfg = JSON.stringify({ projectorConfig: settings.projectorConfig, cipConfig: settings.cipConfig })
    .replace(/</g, '\\u003c').replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029');
  return html.replace('window.SERVER_CONFIG = null;', `window.SERVER_CONFIG = ${cfg};`);
}

let settings = loadSettings();

function loadSettings() {
  try {
    const s = JSON.parse(fs.readFileSync(SETTINGS_FILE, 'utf8'));
    return { ...SETTINGS_DEFAULTS, ...s, matrox: { ...SETTINGS_DEFAULTS.matrox, ...s.matrox } };
  } catch (e) {
    if (e.code !== 'ENOENT') console.error(`[Settings] Could not read settings.json: ${e.message}`);
    return { ...SETTINGS_DEFAULTS, matrox: { ...SETTINGS_DEFAULTS.matrox } };
  }
}

function saveSettings() {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  const tmp = SETTINGS_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(settings, null, 2));
  fs.renameSync(tmp, SETTINGS_FILE);
}

function publicSettings() {
  const out = {};
  SHARED_KEYS.forEach(k => { out[k] = settings[k]; });
  out.matrox = { username: settings.matrox.username, hasPassword: !!settings.matrox.password };
  return out;
}

function readBody(req) {
  return new Promise(resolve => {
    let buf = '';
    req.on('data', c => { buf += c; });
    req.on('end',  () => resolve(buf));
  });
}

function sendJson(res, status, obj) {
  res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-cache' });
  res.end(JSON.stringify(obj));
}

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
  const { username, password } = settings.matrox;
  if (!username || !password) throw new Error('Matrox login not set — open Settings');
  const r = await matroxRequest(ip, 'POST', '/user/login', null,
    JSON.stringify({ username, password }));
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

// ── Reachability checks ──────────────────────────────────────────────────────
const HOST_RE = /^[A-Za-z0-9.\-]{1,253}$/;

// Open a TCP connection to ip:port and time it
function tcpCheck(ip, port, timeoutMs = 3000) {
  return new Promise(resolve => {
    const t0   = Date.now();
    const sock = net.createConnection({ host: ip, port });
    const done = (reachable, error) => {
      sock.destroy();
      resolve({ ip, port, reachable, latencyMs: reachable ? Date.now() - t0 : null, error: error || null });
    };
    sock.setTimeout(timeoutMs, () => done(false, 'No answer (timeout)'));
    sock.once('connect', () => done(true));
    sock.once('error', e => done(false, friendlyNetError(e)));
  });
}

function friendlyNetError(e) {
  return ({
    ECONNREFUSED: 'Device answered but the service is not running',
    EHOSTUNREACH: 'No network route to this address',
    ENETUNREACH:  'No network route to this address',
    ENOTFOUND:    'Address not found',
    ETIMEDOUT:    'No answer (timeout)',
  })[e.code] || e.message;
}

// Short cache so several open browsers don't multiply the checks
const checkCache = new Map(); // key → { at, promise }
function cached(key, ttlMs, fn) {
  const hit = checkCache.get(key);
  if (hit && Date.now() - hit.at < ttlMs) return hit.promise;
  const promise = fn();
  checkCache.set(key, { at: Date.now(), promise });
  return promise;
}

// ── Control Center (show-control software — scene triggers on port 3030) ─────
const CC_PORT = 3030;
const CC_TASK = '/sc-datastore/projectData/taskFlow';

const ccCheck = ip => tcpCheck(ip, CC_PORT);

// Forward a Task.Execute JSON-RPC body to Control Center
function ccTrigger(ip, body) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      hostname: ip, port: CC_PORT, path: CC_TASK, method: 'POST', timeout: 5000,
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, res => {
      let data = '';
      res.on('data', c => { data += c; });
      res.on('end',  () => resolve({ status: res.statusCode, body: data }));
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
    req.end(body);
  });
}

// Sign-in check with the saved account, reusing the normal session logic
async function matroxLoginStatus(ip) {
  const { username, password } = settings.matrox;
  if (!username || !password) return { ok: false, device: ip, error: 'Sign-in not set — enter the Matrox account in Settings' };
  try {
    const r = await matroxGet(ip, '/device/status');
    if (isNotLoggedIn(r)) return { ok: false, device: ip, error: 'Sign-in rejected — check username and password' };
    if (r.status >= 400)  return { ok: false, device: ip, error: `Device error (HTTP ${r.status})` };
    return { ok: true, device: ip, error: null };
  } catch (e) {
    return { ok: false, device: ip, error: e.message };
  }
}

// One-off sign-in with the given (possibly unsaved) account; does not keep the session
async function matroxTestLogin(ip, username, password) {
  if (!username || !password) return { reachable: null, signedIn: false, error: 'Enter a username and password' };
  try {
    const r = await matroxRequest(ip, 'POST', '/user/login', null, JSON.stringify({ username, password }));
    const signedIn = r.status < 400 && !!r.cookie && !r.body.includes('"Not logged in"');
    return { reachable: true, signedIn, error: signedIn ? null : `Sign-in rejected (HTTP ${r.status}) — check username and password` };
  } catch (e) {
    return { reachable: false, signedIn: false, error: e.message === 'timeout' ? 'No answer (timeout)' : friendlyNetError(e) };
  }
}

// ── Projectors (Barco) — bridge sockets currently connected ─────────────────
const liveBarco = new Map(); // ip → open TCP socket count

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js':   'application/javascript',
  '.css':  'text/css',
  '.json': 'application/json',
  '.png':  'image/png',
  '.jpg':  'image/jpeg',
  '.svg':  'image/svg+xml',
  '.ico':  'image/x-icon',
  '.webp': 'image/webp',
  '.jpeg': 'image/jpeg',
  '.webmanifest': 'application/manifest+json',
};

// ── HTTP file server + Matrox API proxy ──────────────────────────────────────
const httpServer = http.createServer(async (req, res) => {
  // Shared settings: GET returns everything except the Matrox password,
  // PUT merges the given top-level keys and writes settings.json
  if ((req.url || '').split('?')[0] === '/api/settings') {
    if (req.method === 'GET') { sendJson(res, 200, publicSettings()); return; }
    if (req.method === 'PUT') {
      let patch;
      try { patch = JSON.parse(await readBody(req) || '{}'); }
      catch { sendJson(res, 400, { error: 'Invalid JSON' }); return; }
      if (patch.projectorConfig !== undefined && !validDeviceConfig(patch.projectorConfig, 'projectors')) {
        sendJson(res, 400, { error: 'Invalid projector list' }); return;
      }
      if (patch.cipConfig !== undefined && !validDeviceConfig(patch.cipConfig, 'devices')) {
        sendJson(res, 400, { error: 'Invalid Matrox device list' }); return;
      }
      SHARED_KEYS.forEach(k => { if (patch[k] !== undefined) settings[k] = patch[k]; });
      if (patch.matrox) {
        const m = settings.matrox;
        const before = m.username + '\n' + m.password;
        if (typeof patch.matrox.username === 'string') m.username = patch.matrox.username.trim();
        if (typeof patch.matrox.password === 'string' && patch.matrox.password) m.password = patch.matrox.password;
        if (before !== m.username + '\n' + m.password) {
          matroxSessions.clear(); // force re-login with the new credentials
          console.log(`[Settings] Matrox login updated (user: ${m.username})`);
        }
      }
      try { saveSettings(); }
      catch (e) { sendJson(res, 500, { error: e.message }); return; }
      sendJson(res, 200, publicSettings());
      return;
    }
    res.writeHead(405); res.end(); return;
  }

  const urlPath0 = (req.url || '').split('?')[0];

  // Health: lets a browser verify it can reach this dashboard server (CORS so the
  // Settings test works even when the page was opened through another address)
  if (urlPath0 === '/api/health') {
    res.writeHead(200, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*', 'Cache-Control': 'no-cache' });
    res.end(JSON.stringify({ ok: true, version: VERSION }));
    return;
  }

  // Connection status for the top bar: Control Center, projectors, Matrox.
  // Body: { projectors: [ip…], matrox: [ip…] } — device lists live in the dashboard.
  // ?fresh=1 bypasses the cache (used by the Settings "Test connection" buttons).
  if (urlPath0 === '/api/status' && req.method === 'POST') {
    let body;
    try { body = JSON.parse(await readBody(req) || '{}'); }
    catch { sendJson(res, 400, { error: 'Invalid JSON' }); return; }
    const fresh = /[?&]fresh=1/.test(req.url);
    const ttl   = fresh ? 0 : 10000;
    const ips   = list => (Array.isArray(list) ? list : []).filter(ip => HOST_RE.test(ip)).slice(0, 64);
    const out   = {};

    if (settings.ccIp && HOST_RE.test(settings.ccIp)) {
      out.controlCenter = await cached(`cc:${settings.ccIp}`, ttl, () => ccCheck(settings.ccIp));
    } else {
      out.controlCenter = { ip: settings.ccIp, reachable: false, error: 'Control Center address not set' };
    }

    if (body.projectors) {
      const results = await Promise.all(ips(body.projectors).map(ip =>
        liveBarco.get(ip) ? { ip, reachable: true } : cached(`prj:${ip}`, ttl, () => tcpCheck(ip, 9090))));
      out.projectors = Object.fromEntries(results.map(r => [r.ip, r.reachable]));
    }

    if (body.matrox) {
      const list    = ips(body.matrox);
      const results = await Promise.all(list.map(ip => cached(`mx:${ip}`, ttl, () => tcpCheck(ip, 443))));
      const first   = results.find(r => r.reachable);
      out.matrox = {
        devices: Object.fromEntries(results.map(r => [r.ip, r.reachable])),
        login:   first ? await cached(`mxlogin:${first.ip}`, fresh ? 0 : 30000, () => matroxLoginStatus(first.ip))
                       : { ok: false, device: null, error: 'No Matrox device reachable' },
      };
    }
    sendJson(res, 200, out);
    return;
  }

  // Matrox sign-in test from Settings: { ip, username, password } — blank password = saved one
  if (urlPath0 === '/api/matrox-test' && req.method === 'POST') {
    let b;
    try { b = JSON.parse(await readBody(req) || '{}'); }
    catch { sendJson(res, 400, { error: 'Invalid JSON' }); return; }
    if (!b.ip || !HOST_RE.test(b.ip)) { sendJson(res, 400, { error: 'Invalid device address' }); return; }
    const username = (b.username ?? settings.matrox.username).trim();
    const password = b.password || settings.matrox.password;
    sendJson(res, 200, { ip: b.ip, ...(await matroxTestLogin(b.ip, username, password)) });
    return;
  }

  // Control Center: status check (optionally for an unsaved ?ip=) and scene trigger
  if (urlPath0 === '/api/cc/status' && req.method === 'GET') {
    const ip = new URLSearchParams((req.url || '').split('?')[1] || '').get('ip') || settings.ccIp;
    if (!ip || !HOST_RE.test(ip)) { sendJson(res, 400, { error: 'Invalid Control Center IP' }); return; }
    sendJson(res, 200, await ccCheck(ip));
    return;
  }
  if (urlPath0 === '/api/cc/trigger' && req.method === 'POST') {
    const ip = settings.ccIp;
    if (!ip) { sendJson(res, 400, { error: 'Control Center IP not set' }); return; }
    const body = await readBody(req);
    try {
      const r = await ccTrigger(ip, body);
      console.log(`[CC] trigger ${ip} → HTTP ${r.status}`);
      res.writeHead(r.status, { 'Content-Type': 'application/json' });
      res.end(r.body || '{}');
    } catch (e) {
      console.log(`[CC] trigger ${ip} → ERROR ${e.message}`);
      sendJson(res, 502, { error: e.message, unreachable: true });
    }
    return;
  }

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
        const body = await readBody(req);
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
  // Never serve the settings file (contains the Matrox password) or dotfiles
  if (!filePath.startsWith(DIR + path.sep) ||
      path.basename(filePath).startsWith('settings.json') ||
      path.basename(filePath).startsWith('.')) {
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
    if (path.basename(filePath) === '25broadway_dashboard.html') data = injectServerConfig(data.toString());
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

  let counted = false;
  tcp.on('connect', () => {
    ready = true;
    counted = true;
    liveBarco.set(host, (liveBarco.get(host) || 0) + 1);
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
    if (counted) { counted = false; liveBarco.set(host, Math.max(0, (liveBarco.get(host) || 1) - 1)); }
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
  console.log(`  Settings → ${SETTINGS_FILE}`);
  console.log('  Press Ctrl+C to stop.\n');
});
