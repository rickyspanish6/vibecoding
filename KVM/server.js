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
import { powerRoutes } from './power.js';
import * as auth from './auth.js';
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
// Test aid, off unless KX_SIM_LATENCY_MS is set: delay /rfb traffic by this much each way (RTT = 2x). POST /api/dev/latency {ms} changes it live.
const SIM_ENABLED = process.env.KX_SIM_LATENCY_MS !== undefined;
let simLatency = Number(process.env.KX_SIM_LATENCY_MS ?? 0);

// Where the dashboard listens, and which Host names it answers to (DNS-rebinding protection). Accounts are always required
// (see auth.js); to serve other machines set BIND=0.0.0.0 and ALLOWED_HOSTS to the name you browse to, and put HTTPS in front.
const BIND = process.env.BIND ?? '127.0.0.1';
const ALLOWED_HOSTS = (process.env.ALLOWED_HOSTS ?? '').split(',').map((h) => h.trim().toLowerCase()).filter(Boolean);
const LOOPBACK = ['127.0.0.1', 'localhost', '::1'];

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
const SESSION_FILE = process.env.KX_SESSION_FILE ?? fileURLToPath(new URL('./.kx-session.json', import.meta.url));
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

// A dead session isn't always bounced to auth.asp: the KX also redirects to its client-check page (/akc...).
// So only a plain 200 that isn't the login form counts as signed in; any redirect means "not authenticated".
const authedPage = (res, body) => res.statusCode === 200 && !body.includes('action_login');
const toLogin = (res) => res.statusCode >= 300 && res.statusCode < 400;

async function isAuthed() {
  if (!jar.size) return false;
  const { res, body } = await upstream({ path: '/home.asp', headers: { cookie: cookieHeader() } });
  return authedPage(res, body.toString('utf8'));
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
    if (authedPage(res, body.toString('utf8'))) return body.toString('utf8');
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
  // Never log this app's own web login off, but its console sessions (they share that login's id) can be
  // disconnected from their ports like anyone else's.
  // Port mode takes every console row of the named logins (one login can hold several); logoff takes one row per login.
  const rows = sessions.filter((s) => ids.includes(s.id) && (mode === 'logoff' ? !s.self : s.portId));
  const targets = mode === 'logoff' ? rows.filter((s, i) => rows.findIndex((r) => r.id === s.id) === i) : rows;
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
  if (res.statusCode >= 400) throw new Error(`The KX refused the request (${res.statusCode})`); // a redirect after submit is normal
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
  if (!req.url.startsWith('/rfb') || !sameOrigin(req) || !auth.can(currentUser(req), 'console')) return socket.destroy();
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
    if (SIM_ENABLED) { // test aid: delay each direction through an ordered line, so a changing delay never reorders bytes
      const line = (write) => { let last = 0; return (chunk) => { const due = Math.max(Date.now() + simLatency, last); last = due; setTimeout(() => write(chunk), due - Date.now()); }; };
      const toClient = line((d) => socket.writable && socket.write(d)), toKx = line((d) => up.writable && up.write(d));
      up.on('data', toClient);
      socket.on('data', toKx);
    } else {
      up.pipe(socket);
      socket.pipe(up);
    }
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

// This server holds a logged-in KX admin session, so refuse anything that isn't the dashboard talking to itself:
// a wrong Host (DNS rebinding) or a cross-site Origin.
function sameOrigin(req) {
  const host = req.headers.host ?? '';
  const name = host.replace(/:\d+$/, '').replace(/^\[|\]$/g, '').toLowerCase();
  if (!LOOPBACK.includes(name) && !ALLOWED_HOSTS.includes(name)) return false;
  const origin = req.headers.origin;
  if (!origin) return true;
  try { return new URL(origin).host === host; } catch { return false; }
}

// --- Accounts and rights (see auth.js) ------------------------------------------------------------------------------

const SESSION_COOKIE = 'kxc_session';
const SESSION_MAX_AGE = 8 * 3600;
const attempts = new Map(); // "ip:<addr>" / "user:<name>" -> { n, until }: five wrong passwords lock that key for a minute

const cookieOf = (req, name) => req.headers.cookie?.split(';').map((c) => c.trim()).find((c) => c.startsWith(`${name}=`))?.slice(name.length + 1);
const currentUser = (req) => auth.sessionUser(cookieOf(req, SESSION_COOKIE));
const clientIp = (req) => req.socket.remoteAddress ?? '';
// First-run setup only from the machine itself; a request relayed by a reverse proxy (X-Forwarded-For) is not local.
const isLocal = (req) => !req.headers['x-forwarded-for'] && ['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(clientIp(req));
const setSessionCookie = (res, token) => res.setHeader('set-cookie', `${SESSION_COOKIE}=${token}; HttpOnly; SameSite=Strict; Path=/; Max-Age=${token ? SESSION_MAX_AGE : 0}`);

function lockedFor(keys) {
  const now = Date.now();
  return Math.ceil(Math.max(0, ...keys.map((k) => (attempts.get(k)?.until ?? 0) - now)) / 1000);
}
function noteFailure(keys) {
  for (const k of keys) {
    const a = attempts.get(k) ?? { n: 0, until: 0 };
    if (++a.n >= 5) { a.until = Date.now() + 60_000; a.n = 0; }
    attempts.set(k, a);
  }
}

async function handleLogin(req, res) {
  const { username = '', password = '' } = await readJson(req);
  const keys = [`ip:${clientIp(req)}`, `user:${String(username).toLowerCase()}`];
  const wait = lockedFor(keys);
  if (wait) return json(res, 429, { error: `Too many attempts. Try again in ${wait}s.` });
  let user;
  try { user = auth.verifyLogin(username, password); }
  catch (e) { noteFailure(keys); auth.audit({ event: 'login-failed', user: String(username).slice(0, 40), ip: clientIp(req) }); throw e; }
  keys.forEach((k) => attempts.delete(k));
  setSessionCookie(res, auth.startSession(user));
  auth.audit({ event: 'login', user: user.username, ip: clientIp(req) });
  json(res, 200, { ok: true, mustChange: Boolean(user.mustChange) });
}

/** What a route needs: null (any signed-in user), a permission, a list of permissions (any of them) or 'admin'. */
function needs(method, pathname) {
  const write = method !== 'GET';
  if (/^\/api\/(me|logout|ports)(\/password)?$/.test(pathname)) return null;
  if (pathname === '/api/session') return 'console';
  if (/^\/api\/ports\/\d+\/console$/.test(pathname)) return 'console';
  if (pathname === '/api/sessions') return ['console', 'sessions'];
  if (pathname === '/api/sessions/disconnect-all') return ['console', 'sessions'];
  if (pathname.startsWith('/api/sessions/')) return 'sessions';
  if (/^\/api\/power\/hosts\//.test(pathname)) return 'power';
  if (pathname === '/api/power' && !write) return null;
  if (pathname.startsWith('/api/power/')) return 'configure';
  if (pathname === '/api/config' && !write) return null;
  if (pathname.startsWith('/api/config')) return 'configure';
  if (pathname.startsWith('/api/users')) return 'users';
  if (pathname.startsWith('/api/dev/')) return 'admin';
  return null;
}
const allowed = (user, need) => need === null || (need === 'admin' ? auth.isAdmin(user) : Array.isArray(need) ? need.some((p) => auth.can(user, p)) : auth.can(user, need));

// What the embedded Raritan client needs from the KX. Anyone with the console right may fetch these; the rest of the KX's
// web interface (its own user and device administration) is reachable through this proxy by administrators only.
const KX_CLIENT_PATHS = /^\/(jsclient|js|css|fonts?|images?|img|lang|locales?|assets)\/|^\/favicon\.ico$/;

const roleTable = () => Object.fromEntries(Object.entries(auth.ROLES).map(([k, v]) => [k, { label: v.label, permissions: v.permissions }]));
const me = (user) => ({ user: auth.describe(user), roles: roleTable(), permissionLabels: auth.PERMISSIONS });

async function usersRoutes(req, res, pathname, actor) {
  const m = pathname.match(/^\/api\/users(?:\/([0-9a-f]+))?$/);
  if (!m) return json(res, 404, { error: 'not found' });
  const id = m[1];
  const self = (target) => target === actor.id;
  if (!id && req.method === 'GET') return json(res, 200, { users: auth.listUsers(), roles: roleTable(), permissionLabels: auth.PERMISSIONS });
  if (!id && req.method === 'POST') {
    const b = await readJson(req);
    const u = auth.createUser({ username: b.username, password: b.password, role: b.role, permissions: b.permissions, mustChange: true });
    auth.audit({ event: 'user-created', by: actor.username, user: u.username, role: u.role, permissions: u.permissions });
    return json(res, 200, { user: u });
  }
  if (id && req.method === 'PUT') {
    const b = await readJson(req);
    if (self(id) && (b.role !== undefined || b.permissions !== undefined || b.disabled !== undefined)) throw Object.assign(new Error('You cannot change your own role or disable yourself; ask another administrator.'), { status: 409 });
    const u = auth.updateUser(id, { role: b.role, permissions: b.permissions, disabled: b.disabled, password: b.password, mustChange: b.password !== undefined ? true : undefined });
    auth.audit({ event: 'user-updated', by: actor.username, user: u.username, role: u.role, permissions: u.permissions, disabled: u.disabled, passwordReset: b.password !== undefined });
    return json(res, 200, { user: u });
  }
  if (id && req.method === 'DELETE') {
    if (self(id)) throw Object.assign(new Error('You cannot remove your own account.'), { status: 409 });
    const name = auth.listUsers().find((u) => u.id === id)?.username;
    auth.deleteUser(id);
    auth.audit({ event: 'user-deleted', by: actor.username, user: name });
    return json(res, 200, { ok: true });
  }
  return json(res, 405, { error: 'method not allowed' });
}

// --- Sign-in and first-run pages ------------------------------------------------------------------------------------------

const authPage = ({ intro, fields, button, endpoint, script = '', extra = '' }) => `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>KX Console</title><style>
:root{--bg:#f6f7f9;--panel:#fff;--line:#e3e6eb;--text:#14181f;--muted:#667085;--accent:#2563eb;--accent-text:#fff}
@media (prefers-color-scheme:dark){:root{--bg:#0d1016;--panel:#151921;--line:#252b36;--text:#e8ebf0;--muted:#8b95a7;--accent:#5b8cff;--accent-text:#0b1020}}
*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--bg);color:var(--text);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Inter,system-ui,sans-serif}
form{width:min(360px,calc(100vw - 32px));background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:24px;display:grid;gap:12px}
h1{margin:0;font-size:18px}p{margin:0;color:var(--muted);font-size:12px}code{background:var(--bg);padding:1px 5px;border-radius:5px;font-size:11px}
input{padding:10px;border:1px solid var(--line);border-radius:8px;background:var(--bg);color:var(--text);font:inherit}input:focus{outline:2px solid var(--accent);outline-offset:-1px}
button{padding:10px;border:0;border-radius:8px;background:var(--accent);color:var(--accent-text);font:inherit;font-weight:600;cursor:pointer}button:disabled{opacity:.5}
#e{color:#b42318;min-height:1.2em;font-size:13px}</style></head><body>
<form id="f"><h1>KX Console</h1><p>${intro}</p>${fields}<div id="e" role="alert"></div><button id="b">${button}</button>${extra}</form>
<script>f.onsubmit=async(ev)=>{ev.preventDefault();b.disabled=true;e.textContent='';try{${script}
const r=await fetch('${endpoint}',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)});
const d=await r.json();if(!r.ok)throw new Error(d.error);location.href='/'}catch(x){e.textContent=x.message;b.disabled=false}};</script></body></html>`;

const loginPage = authPage({
  intro: 'Sign in to continue.', button: 'Sign in', endpoint: '/api/login',
  fields: '<input id="u" placeholder="User name" autocomplete="username" autofocus required><input id="p" type="password" placeholder="Password" autocomplete="current-password" required>',
  script: 'const body={username:u.value,password:p.value};',
  extra: '<p>Forgot your password? On the machine running this server, run <code>node auth-cli.js reset &lt;user&gt;</code>.</p>',
});
const setupPage = authPage({
  intro: 'Welcome. Create the administrator account for this dashboard. You can add other users, with their own rights, afterwards.',
  button: 'Create account', endpoint: '/api/setup',
  fields: `<input id="u" placeholder="User name" autocomplete="username" autofocus required><input id="p" type="password" placeholder="Password (at least ${auth.MIN_PASSWORD} characters)" autocomplete="new-password" minlength="${auth.MIN_PASSWORD}" required><input id="c" type="password" placeholder="Repeat the password" autocomplete="new-password" required>`,
  script: "if(p.value!==c.value)throw new Error('The passwords do not match');const body={username:u.value,password:p.value};",
});
const setupElsewhere = authPage({
  intro: 'This dashboard has no account yet. The first administrator can only be created from the machine it runs on: open it there, or run <code>node auth-cli.js create-admin &lt;user&gt;</code> in the project folder.',
  button: 'Check again', endpoint: '/api/login', fields: '', script: "location.reload();return;const body={};",
});

const server = createServer(async (req, res) => {
  if (!sameOrigin(req)) return json(res, 403, { error: 'forbidden' });
  const { pathname } = new URL(req.url, 'http://localhost');
  const wantsHtml = req.method === 'GET' && (req.headers.accept ?? '').includes('text/html');
  const html = (body) => { res.writeHead(200, { 'content-type': 'text/html', 'cache-control': 'no-store' }); res.end(body); };
  const redirect = (to) => { res.writeHead(302, { location: to }); res.end(); };
  try {
    // Reachable without an account: first-run setup (from this machine only) and sign-in.
    if (pathname === '/setup' && req.method === 'GET') {
      if (auth.hasUsers()) return redirect('/login');
      return html(isLocal(req) ? setupPage : setupElsewhere);
    }
    if (pathname === '/api/setup' && req.method === 'POST') {
      if (auth.hasUsers()) return json(res, 409, { error: 'Setup is already done' });
      if (!isLocal(req)) return json(res, 403, { error: 'The first administrator can only be created from the machine the dashboard runs on' });
      const { username, password } = await readJson(req);
      const user = auth.createFirstAdmin(username, password);
      auth.audit({ event: 'setup', user: user.username, ip: clientIp(req) });
      setSessionCookie(res, auth.startSession(auth.verifyLogin(username, password)));
      return json(res, 200, { ok: true });
    }
    if (pathname === '/login' && req.method === 'GET') {
      if (!auth.hasUsers()) return redirect('/setup');
      if (currentUser(req)) return redirect('/');
      return html(loginPage);
    }
    if (pathname === '/api/login' && req.method === 'POST') return await handleLogin(req, res); // await: a rejection must land in the catch below, not crash the process

    const user = currentUser(req);
    if (!user) {
      if (wantsHtml) return redirect(auth.hasUsers() ? '/login' : '/setup');
      return json(res, 401, { error: 'Sign in required' });
    }
    if (pathname === '/api/logout' && req.method === 'POST') {
      auth.endSession(cookieOf(req, SESSION_COOKIE));
      setSessionCookie(res, '');
      return json(res, 200, { ok: true });
    }
    // A user whose password was reset must choose a new one before anything else.
    if (user.mustChange && pathname.startsWith('/api/') && pathname !== '/api/me' && pathname !== '/api/me/password') {
      return json(res, 403, { error: 'Choose a new password first', code: 'must_change' });
    }
    if (!allowed(user, needs(req.method, pathname))) return json(res, 403, { error: 'You do not have permission to do that' });

    if (pathname === '/api/me' && req.method === 'GET') return json(res, 200, me(user));
    if (pathname === '/api/me/password' && req.method === 'POST') {
      const { current, next } = await readJson(req);
      const changed = auth.changeOwnPassword(user.id, current, next);
      auth.audit({ event: 'password-changed', user: user.username, ip: clientIp(req) });
      setSessionCookie(res, auth.startSession(changed)); // the old session ended with the old password
      return json(res, 200, { ok: true });
    }
    if (pathname.startsWith('/api/users')) return await usersRoutes(req, res, pathname, user);

    if (pathname === '/api/ports') {
      lastActivity = Date.now();
      return json(res, 200, { version: VERSION, device: await readDevice(), ports: await readPorts(), rfbOpen });
    }
    // PDU config, outlet status, host-to-outlet mappings and power control
    if ((pathname.startsWith('/api/config') || pathname.startsWith('/api/power')) && await powerRoutes(req, res, pathname, { readJson, json, readPorts, canConfigure: auth.can(user, 'configure'), by: user.username })) return;
    if (SIM_ENABLED && pathname === '/api/dev/latency' && req.method === 'POST') {
      const { ms } = await readJson(req);
      if (!Number.isFinite(ms) || ms < 0 || ms > 2000) return json(res, 400, { error: 'ms must be 0-2000' });
      simLatency = ms;
      return json(res, 200, { latencyEachWayMs: simLatency });
    }
    if (pathname === '/api/sessions' && req.method === 'GET') return json(res, 200, { sessions: await readSessions() });
    if (pathname === '/api/sessions/disconnect' && req.method === 'POST') {
      const { id, mode } = await readJson(req);
      if (typeof id !== 'string' || !['port', 'logoff'].includes(mode)) return json(res, 400, { error: 'id and mode (port|logoff) required' });
      auth.audit({ event: 'kx-session-ended', by: user.username, mode });
      return json(res, 200, { sessions: await kick([id], mode) });
    }
    // Everyone else's console sessions, so the single remote channel is free. Never this app's own session.
    if (pathname === '/api/sessions/disconnect-all' && req.method === 'POST') {
      await readJson(req);
      const others = [...new Set((await readSessions()).filter((s) => s.portId).map((s) => s.id))];
      return json(res, 200, { disconnected: others.length, sessions: others.length ? await kick(others, 'port') : await readSessions() });
    }

    // Logs in to the KX if needed and gives the browser the session cookies HKC reads (kvm_session_id).
    // Only cookie names are returned, never values.
    if (pathname === '/api/session') {
      if (!MOCK) await ensureSession();
      res.setHeader('set-cookie', [...jar].map(([k, v]) => `${k}=${v}; Path=/; SameSite=Lax`));
      return json(res, 200, { ok: true, cookies: [...jar.keys()], hasKvmSessionId: jar.has('kvm_session_id') || jar.has('pp_session_id') }); // firmware 3.10 names the cookie pp_session_id
    }

    // Fallback if the embedded client misbehaves: Raritan's own client via Direct Port Access.
    const m = pathname.match(/^\/api\/ports\/(\d+)\/console$/);
    if (m) {
      res.writeHead(302, { location: `https://${HOST}/dpa.asp?port=${m[1]}` });
      return res.end();
    }

    if (pathname.startsWith('/api/')) return json(res, 404, { error: 'not found' }); // never forward our own API namespace to the KX
    const file = req.method === 'GET' ? await publicFile(pathname) : null;
    if (file) {
      res.writeHead(200, { 'content-type': mime[extname(file)] ?? 'application/octet-stream' });
      return res.end(await readFile(file));
    }
    if (MOCK) return json(res, 404, { error: 'not found' });
    // The rest of the KX web interface: the client's own files for the console right, anything else for administrators.
    if (!auth.isAdmin(user) && !(auth.can(user, 'console') && KX_CLIENT_PATHS.test(pathname))) return json(res, 403, { error: 'You do not have permission to open that part of the KX' });
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
server.listen(PORT, BIND, () => {
  console.log(`KX Console v${VERSION} on http://${BIND}:${PORT}${MOCK ? ' (mock data)' : ''}`);
  if (!auth.hasUsers()) console.log(`No accounts yet: open http://127.0.0.1:${PORT}/setup on this machine to create the administrator (or run: node auth-cli.js create-admin <user>).`);
  if (!LOOPBACK.includes(BIND)) console.log(`Listening beyond this machine (${BIND}): put HTTPS in front, and set ALLOWED_HOSTS to the name people browse to.`);
});
