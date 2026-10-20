// KX III dashboard backend. Zero dependencies: needs Node and net-snmp's snmpbulkwalk/snmpget on PATH.
// Config comes from environment variables (see .env.example); run with: node --env-file=.env server.js
//
// Besides the port list (SNMP), it reverse-proxies the KX under our own origin so Raritan's HTML KVM
// client (/jsclient/Client.asp) can be embedded in the dashboard: the KX sends X-Frame-Options and its
// client opens wss://<host>/rfb, so both have to be same-origin. The backend logs in once with KX_USER /
// KX_PASSWORD and keeps the session cookies; the browser never sees the password.
import { createServer } from 'node:http';
import { request as httpsRequest, Agent } from 'node:https';
import { connect as tlsConnect } from 'node:tls';
import { readFileSync } from 'node:fs';
import { readFile, stat, writeFile } from 'node:fs/promises';
import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { homedir } from 'node:os';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const run = promisify(execFile);
const root = fileURLToPath(new URL('./public/', import.meta.url));
// Single source of truth for the app version (SemVer): package.json.
const VERSION = JSON.parse(readFileSync(new URL('./package.json', import.meta.url), 'utf8')).version;

const HOST = process.env.KX_HOST ?? '172.16.0.3';
const COMMUNITY = process.env.KX_SNMP_COMMUNITY ?? 'public';
const USER = process.env.KX_USER;
const PASSWORD = process.env.KX_PASSWORD;
const DEVICE_ID = process.env.KX_DEVICE_ID ?? '000d5d11da6a'; // the P_<id>_<n> in HKC's portId (the KX's MAC)
const SSH_USER = process.env.KX_SSH_USER ?? USER ?? 'mofa';
const SSH_KEY = process.env.KX_SSH_KEY ?? join(homedir(), '.ssh', 'kx3_rsa');
const PORT = Number(process.env.PORT ?? 3000);
const MOCK = process.env.KX_MOCK === '1';

// --- SNMP port list --------------------------------------------------------------------------

// Raritan KX III port table: 1.3.6.1.4.1.13742.3.1.4.1.<column>.<port>
const PORT_TABLE = '1.3.6.1.4.1.13742.3.1.4.1';
const COLUMNS = { name: 3, type: 4, status: 5 }; // status: 1 = down, 2 = up and idle, 3 = up and in use

// The agent is slow per request (~3s per column with snmpwalk), so fetch the table in one bulk walk.
async function walkTable() {
  const { stdout } = await run('snmpbulkwalk', ['-On', '-v2c', '-c', COMMUNITY, '-Cr32', '-t3', '-r1', HOST, PORT_TABLE]);
  const cols = { [COLUMNS.name]: new Map(), [COLUMNS.type]: new Map(), [COLUMNS.status]: new Map() };
  for (const line of stdout.split('\n')) {
    const m = line.match(/\.4\.1\.(\d+)\.(\d+) = (?:STRING|INTEGER): "?(.*?)"?$/);
    if (m && cols[m[1]]) cols[m[1]].set(Number(m[2]), m[3]);
  }
  return [cols[COLUMNS.name], cols[COLUMNS.type], cols[COLUMNS.status]];
}

let portsCache = { at: 0, value: null };

async function readPorts() {
  if (MOCK) return mockPorts();
  if (portsCache.value && Date.now() - portsCache.at < 3000) return portsCache.value;
  const [names, types, statuses] = await walkTable();
  const value = [...names.keys()].map((id) => {
    const name = names.get(id);
    return {
      id,
      name,
      type: types.get(id) ?? 'Unknown',
      up: statuses.get(id) !== '1',
      busy: statuses.get(id) === '3',
      configured: name !== 'N/C' && !/^Dominion_KX3_Port\d+$/.test(name),
    };
  });
  portsCache = { at: Date.now(), value };
  return value;
}

function mockPorts() {
  const names = ['XAG00', 'XAG01', 'XAG02', 'OPC01', 'MAC01'];
  return names.map((n, i) => ({
    id: i + 1, name: `B25-CTL-${n}`, type: n === 'MAC01' ? 'DVM-HDMI' : 'DVM-DP', up: i !== 2, configured: true,
  }));
}

let deviceCache = null;

async function readDevice() {
  if (MOCK) return { name: 'B25-CTL-KVM01', model: 'DKX3-132', host: HOST, deviceId: DEVICE_ID };
  return (deviceCache ??= await fetchDevice());
}

async function fetchDevice() {
  const { stdout } = await run('snmpget', ['-Oqv', '-v2c', '-c', COMMUNITY, '-t2', '-r1', HOST, '1.3.6.1.2.1.1.5.0', '1.3.6.1.2.1.1.1.0']);
  const [name, model] = stdout.trim().split('\n');
  // sysDescr repeats the port count ("DKX3-132-132"); show the model once.
  return {
    name: name.replaceAll('"', ''),
    model: model.replaceAll('"', '').replace(/(-\d+)\1$/, '$1'),
    host: HOST,
    deviceId: DEVICE_ID,
  };
}

// --- Who is connected (KX CLI over SSH key) ------------------------------------------------------

// The CLI's `userlist` is the only place the KX shows who holds which port. Port "RC" is a plain web
// login; a number is a console session on that port. The row starting with "*" is our own SSH session.
function parseSessions(text) {
  return text.replace(/\x1b\[[0-9;?]*[a-zA-Z]/g, '').split(/\r?\n/)
    .map((line) => line.split('|').map((s) => s.trim()))
    .filter((cols) => cols.length === 5 && /^s_\d+$/.test(cols[2]))
    .filter(([status]) => !status.startsWith('*'))
    .map(([status, user, id, port, from]) => ({ status, user, id, port: port === 'RC' ? null : Number(port), from }));
}

let sessionsCache = { at: 0, value: [] };

function readSessions() {
  if (MOCK) return Promise.resolve([{ status: '3 min idle', user: 'mofa', id: 's_1', port: 4, from: '10.0.0.5' }]);
  if (Date.now() - sessionsCache.at < 4000) return Promise.resolve(sessionsCache.value);
  return new Promise((resolve, reject) => {
    const ssh = spawn('ssh', ['-tt', '-i', SSH_KEY, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8',
      '-o', 'StrictHostKeyChecking=accept-new', `${SSH_USER}@${HOST}`]);
    let out = '';
    ssh.stdout.on('data', (d) => { out += d; });
    const timer = setTimeout(() => { ssh.kill(); reject(new Error('SSH to the KX timed out')); }, 15000);
    ssh.on('error', (e) => { clearTimeout(timer); reject(e); });
    ssh.on('close', () => {
      clearTimeout(timer);
      if (!out.includes('Active user')) return reject(new Error(`SSH login to the KX failed (key ${SSH_KEY})`));
      sessionsCache = { at: Date.now(), value: parseSessions(out) };
      resolve(sessionsCache.value);
    });
    ssh.stdin.write('userlist\r\nlogout\r\n');
  });
}

// --- KX session (HTTPS login, cookie jar) ---------------------------------------------------------

const agent = new Agent({ rejectUnauthorized: false, keepAlive: true }); // the KX serves a self-signed cert
const jar = new Map();
let loginInFlight = null;
let lastActivity = 0; // last time the dashboard polled; keep-alive only runs while someone is looking
let rfbOpen = 0;      // console WebSockets currently open through the proxy

// Reuse the session across restarts: every fresh login leaves another web session on the KX.
const SESSION_FILE = fileURLToPath(new URL('./.kx-session.json', import.meta.url));
try { for (const [k, v] of Object.entries(JSON.parse(readFileSync(SESSION_FILE, 'utf8')))) jar.set(k, v); } catch { /* no saved session */ }
const saveJar = () => writeFile(SESSION_FILE, JSON.stringify(Object.fromEntries(jar)), { mode: 0o600 }).catch(() => {});

const cookieHeader = () => [...jar].map(([k, v]) => `${k}=${v}`).join('; ');

function absorbCookies(setCookie = []) {
  for (const c of setCookie) {
    const pair = c.split(';')[0];
    const i = pair.indexOf('=');
    if (i > 0) jar.set(pair.slice(0, i).trim(), pair.slice(i + 1).trim());
  }
}

function upstream({ method = 'GET', path, headers = {} }, body) {
  return new Promise((resolve, reject) => {
    const req = httpsRequest({ host: HOST, port: 443, method, path, headers, agent }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ res, body: Buffer.concat(chunks) }));
    });
    req.setTimeout(10000, () => req.destroy(new Error('KX timed out')));
    req.on('error', reject);
    req.end(body);
  });
}

const toLogin = (res) => /auth\.asp/.test(res.headers.location ?? '');

async function isAuthed() {
  if (!jar.size) return false;
  const { res } = await upstream({ path: '/home.asp', headers: { cookie: cookieHeader() } });
  return res.statusCode < 400 && !toLogin(res);
}

async function login() {
  if (!USER || !PASSWORD) throw Object.assign(new Error('Set KX_USER and KX_PASSWORD in .env'), { status: 503 });
  jar.clear();
  // Visit the login page first in case the KX hands out a pre-login cookie.
  const first = await upstream({ path: '/auth.asp?client=javascript' });
  absorbCookies(first.res.headers['set-cookie']);
  const form = new URLSearchParams({
    is_dotnet: '0', is_javafree: '0', is_standalone_client: '0', is_javascript_kvm_client: '1', is_javascript_rsc_client: '1',
    login: USER, password: PASSWORD, PIN: '', action_login: 'Login',
  }).toString();
  const { res } = await upstream({
    method: 'POST',
    path: '/auth.asp?client=javascript',
    headers: {
      'content-type': 'application/x-www-form-urlencoded',
      'content-length': Buffer.byteLength(form),
      ...(jar.size && { cookie: cookieHeader() }),
    },
  }, form);
  absorbCookies(res.headers['set-cookie']);
  if (!(await isAuthed())) {
    jar.clear();
    throw Object.assign(new Error('The KX rejected the login (check KX_USER / KX_PASSWORD, or its session limit)'), { status: 401 });
  }
  saveJar();
}

async function ensureSession() {
  if (await isAuthed()) return;
  loginInFlight ??= login().finally(() => { loginInFlight = null; });
  await loginInFlight;
}

// --- HTTP proxy to the KX (anything that isn't ours) -----------------------------------------------

function proxy(req, res) {
  const headers = { ...req.headers, host: HOST, origin: `https://${HOST}` };
  if (headers.referer) headers.referer = headers.referer.replace(/^https?:\/\/[^/]+/, `https://${HOST}`);
  delete headers.cookie; // the browser's cookies are ours; the KX session lives in the jar
  if (jar.size) headers.cookie = cookieHeader();
  const up = httpsRequest({ host: HOST, port: 443, method: req.method, path: req.url, headers, agent }, (ur) => {
    const out = { ...ur.headers };
    if (out.location) out.location = out.location.replace(new RegExp(`^https?://${HOST.replaceAll('.', '\\.')}(:\\d+)?`), '');
    delete out['set-cookie'];
    res.writeHead(ur.statusCode, out);
    ur.pipe(res);
  });
  up.on('error', (err) => json(res, 502, { error: `KX unreachable: ${err.message}` }));
  req.pipe(up);
}

// HKC opens wss://<host>/rfb. Pipe the upgrade straight through to the KX with the session cookie attached.
function proxyUpgrade(req, socket, head) {
  if (!req.url.startsWith('/rfb') || !sameOrigin(req)) return socket.destroy();
  const up = tlsConnect({ host: HOST, port: 443, rejectUnauthorized: false });
  let counted = false;
  const close = () => { if (counted) { counted = false; rfbOpen--; } up.destroy(); socket.destroy(); };
  up.on('error', close); socket.on('error', close); up.on('close', close); socket.on('close', close);
  up.on('secureConnect', () => {
    counted = true; rfbOpen++;
    const lines = [`${req.method} ${req.url} HTTP/1.1`];
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      if (!['host', 'origin', 'cookie'].includes(req.rawHeaders[i].toLowerCase())) lines.push(`${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}`);
    }
    lines.push(`Host: ${HOST}`, `Origin: https://${HOST}`);
    if (jar.size) lines.push(`Cookie: ${cookieHeader()}`);
    up.write(`${lines.join('\r\n')}\r\n\r\n`);
    if (head.length) up.write(head);
    up.pipe(socket);
    socket.pipe(up);
  });
}

// --- HTTP server ----------------------------------------------------------------------------------

const mime = { '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript', '.svg': 'image/svg+xml' };

const json = (res, status, body) => {
  if (res.headersSent) return res.end();
  res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  res.end(JSON.stringify(body));
};

async function publicFile(pathname) {
  const file = normalize(join(root, pathname === '/' ? 'index.html' : pathname));
  if (!file.startsWith(root)) return null;
  try { return (await stat(file)).isFile() ? file : null; } catch { return null; }
}

// This server holds a logged-in KX admin session and proxies every path to it, so refuse anything that
// isn't the dashboard talking to itself: a wrong Host (DNS rebinding) or a cross-site Origin.
function sameOrigin(req) {
  const host = req.headers.host ?? '';
  if (!/^(127\.0\.0\.1|localhost|\[::1\])(:\d+)?$/.test(host)) return false;
  const origin = req.headers.origin;
  return !origin || origin === `http://${host}`;
}

const server = createServer(async (req, res) => {
  if (!sameOrigin(req)) return json(res, 403, { error: 'forbidden' });
  const { pathname } = new URL(req.url, 'http://localhost');
  try {
    if (pathname === '/api/ports') {
      lastActivity = Date.now();
      return json(res, 200, { version: VERSION, device: await readDevice(), ports: await readPorts(), rfbOpen });
    }
    if (pathname === '/api/sessions') return json(res, 200, { sessions: await readSessions() });

    // Logs in to the KX if needed and gives the browser the session cookies HKC reads (kvm_session_id).
    // Only cookie names are returned, never values.
    if (pathname === '/api/session') {
      if (!MOCK) await ensureSession();
      res.setHeader('set-cookie', [...jar].map(([k, v]) => `${k}=${v}; Path=/; SameSite=Lax`));
      return json(res, 200, { ok: true, cookies: [...jar.keys()], hasKvmSessionId: jar.has('kvm_session_id') });
    }

    // Fallback if the embedded client misbehaves: Raritan's own client via Direct Port Access.
    const m = pathname.match(/^\/api\/ports\/(\d+)\/console$/);
    if (m) {
      res.writeHead(302, { location: `https://${HOST}/dpa.asp?port=${m[1]}` });
      return res.end();
    }

    const file = req.method === 'GET' ? await publicFile(pathname) : null;
    if (file) {
      res.writeHead(200, { 'content-type': mime[extname(file)] ?? 'application/octet-stream' });
      return res.end(await readFile(file));
    }
    if (MOCK) return json(res, 404, { error: 'not found' });
    proxy(req, res);
  } catch (err) {
    json(res, err.status ?? 502, { error: err.status ? err.message : `KX unreachable: ${err.message.split('\n')[0]}` });
  }
});

// Keep the KX web session alive (and re-login if it expired) while the dashboard is open and we hold one.
setInterval(async () => {
  if (MOCK || !jar.size || Date.now() - lastActivity > 180_000) return;
  try { await ensureSession(); } catch (err) { console.error('keep-alive:', err.message); }
}, 60_000).unref();

server.on('upgrade', proxyUpgrade);
server.listen(PORT, '127.0.0.1', () => console.log(`KX Console v${VERSION} on http://127.0.0.1:${PORT}${MOCK ? ' (mock data)' : ''}`));
