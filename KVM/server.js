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
    .map(([status, user, id, port, from]) => ({
      id, user, from, status, self: false, port: port === 'RC' ? null : Number(port), portName: null, portId: null,
    }));
}

let sessionsCache = { at: 0, value: [] };

function readSessionsSsh() {
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

// --- Users by Port: the KX's own session list and disconnect actions -----------------------------------
// um_users_port.asp lists every session (with the ids the SSH userlist lacks) and posts the same form the
// KX's "Disconnect User From Port" / "Force User Logoff" buttons submit. Everything about a session is taken
// from that page, never from the browser, and this app's own session ("*this session") is never touched.

async function kxPage(path) {
  for (let i = 0; i < 2; i++) {
    const { res, body } = await upstream({ path, headers: jar.size ? { cookie: cookieHeader() } : {} });
    if (res.statusCode < 400 && !toLogin(res)) return body.toString('utf8');
    await ensureSession();
  }
  throw new Error('The KX session could not be refreshed');
}

async function readUsersByPort() {
  const html = await kxPage('/um_users_port.asp');
  const nonce = html.match(/name="one_time_nonce" value="([^"]*)"/)?.[1];
  const row = /new PortUser\("([^"]*)", "([^"]*)", "([^"]*)", "([^"]*)", "([^"]*)", "([^"]*)", "([^"]*)"\)/g;
  const sessions = [...html.matchAll(row)].map(([, portNo, portName, user, from, status, id, portId]) => ({
    id, user, from, status: status.replace('*this session', '').trim(), self: status.includes('*this session'),
    port: Number.isInteger(Number(portNo)) && portNo !== '' ? Number(portNo) : null,
    portName: portId ? portName : null, portId: portId || null,
  }));
  return { nonce, sessions };
}

async function readSessions() {
  if (MOCK) return [{ id: '1', user: 'mofa', from: '10.0.0.5', status: '3 min idle', self: false, port: 4, portName: 'B25-CTL-OPC01', portId: 'P_x_3' }];
  if (USER && PASSWORD) return (await readUsersByPort()).sessions;
  return readSessionsSsh();
}

// mode "port": disconnect the sessions from their ports; "logoff": force them off the KX entirely.
async function kick(ids, mode) {
  if (MOCK) return [];
  const { nonce, sessions } = await readUsersByPort();
  const targets = ids.map((id) => sessions.find((s) => s.id === id)).filter((s) => s && !s.self && (mode === 'logoff' || s.portId));
  if (!targets.length) return sessions;
  const form = new URLSearchParams({ one_time_nonce: nonce, __templates__: ' umusersport', selected_num: String(targets.length) });
  form.set(mode === 'port' ? 'action_disconnect_multiple_ports' : 'action_logoff_multiple_users', '1');
  targets.forEach((s, i) => {
    form.set(`userport_sid_${i}`, s.id);
    if (mode === 'port') { form.set(`userport_portid_${i}`, s.portId); form.set(`userport_portname_${i}`, s.portName); }
    else form.set(`userport_username_${i}`, s.user);
  });
  const body = form.toString();
  const { res } = await upstream({
    method: 'POST',
    path: '/um_users_port.asp',
    headers: { 'content-type': 'application/x-www-form-urlencoded', 'content-length': Buffer.byteLength(body), cookie: cookieHeader() },
  }, body);
  if (res.statusCode >= 400 || toLogin(res)) throw new Error(`The KX refused the request (${res.statusCode})`);
  sessionsCache.at = 0;
  portsCache.at = 0;
  return (await readUsersByPort()).sessions;
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    if (!/^application\/json/.test(req.headers['content-type'] ?? '')) return reject(Object.assign(new Error('JSON body required'), { status: 415 }));
    let raw = '';
    req.on('data', (c) => { raw += c; if (raw.length > 10_000) req.destroy(); });
    req.on('end', () => { try { resolve(JSON.parse(raw || '{}')); } catch { reject(Object.assign(new Error('Bad JSON'), { status: 400 })); } });
    req.on('error', reject);
  });
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
    if (pathname === '/api/sessions' && req.method === 'GET') return json(res, 200, { sessions: await readSessions() });
    if (pathname === '/api/sessions/disconnect' && req.method === 'POST') {
      const { id, mode } = await readJson(req);
      if (typeof id !== 'string' || !['port', 'logoff'].includes(mode)) return json(res, 400, { error: 'id and mode (port|logoff) required' });
      return json(res, 200, { sessions: await kick([id], mode) });
    }
    // Everyone else's console sessions, so the single remote channel is free. Never this app's own session.
    if (pathname === '/api/sessions/disconnect-all' && req.method === 'POST') {
      await readJson(req);
      const others = (await readSessions()).filter((s) => !s.self && s.portId).map((s) => s.id);
      return json(res, 200, { disconnected: others.length, sessions: others.length ? await kick(others, 'port') : await readSessions() });
    }

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
