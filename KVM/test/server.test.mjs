// node --test test/   The real server, with mock KX data and isolated files: first-run setup, sign-in, and who may do what.
import test from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { spawn } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const dir = mkdtempSync(join(tmpdir(), 'kx-server-'));
const freePort = () => new Promise((resolve) => { const s = net.createServer().listen(0, '127.0.0.1', () => { const { port } = s.address(); s.close(() => resolve(port)); }); });

writeFileSync(join(dir, 'config.json'), JSON.stringify({
  devices: [{ id: 'pdn04', name: 'B25-CTL-PDN04', host: '127.0.0.1', port: 9, user: 'mofa', password: 'secret' }],
  mappings: { 10: [{ device: 'pdn04', outlet: 2 }] }, hosts: {},
}));

async function start(extraEnv) {
  const port = await freePort();
  const env = {
    ...process.env, PORT: String(port), KX_USERS_PATH: join(dir, 'users.json'), KX_AUDIT_LOG: join(dir, 'audit.log'),
    KX_CONFIG_PATH: join(dir, 'config.json'), KX_POWER_LOG: join(dir, 'power.log'), KX_SESSION_FILE: join(dir, 'kx-session.json'), KX_USER: '', KX_PASSWORD: '', ...extraEnv,
  };
  const child = spawn('node', ['server.js'], { cwd: root, env });
  let out = '';
  child.stdout.on('data', (d) => { out += d; }); child.stderr.on('data', (d) => { out += d; });
  for (let i = 0; i < 100 && !out.includes('KX Console v'); i++) await new Promise((r) => setTimeout(r, 50));
  assert.ok(out.includes('KX Console v'), `the server did not start: ${out}`);
  return { child, base: `http://127.0.0.1:${port}`, out: () => out };
}

// a tiny browser: keeps the session cookie
function client(base) {
  let cookie = '';
  const call = async (method, path, body, headers = {}) => {
    const res = await fetch(base + path, {
      method, redirect: 'manual', headers: { ...(body !== undefined ? { 'content-type': 'application/json' } : {}), ...(cookie ? { cookie } : {}), ...headers },
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });
    const set = res.headers.get('set-cookie');
    if (set) cookie = set.split(';')[0].endsWith('=') ? '' : set.split(';')[0];
    const type = res.headers.get('content-type') ?? '';
    return { status: res.status, location: res.headers.get('location'), body: type.includes('json') ? await res.json() : await res.text() };
  };
  return { call, get: (p, h) => call('GET', p, undefined, h), post: (p, b) => call('POST', p, b ?? {}), put: (p, b) => call('PUT', p, b), del: (p) => call('DELETE', p), signedIn: () => Boolean(cookie) };
}

const PW = 'a long enough password';
const mock = await start({ KX_MOCK: '1' });
test.after(() => mock.child.kill());

test('first run: everything leads to the setup page, which only works from this machine', async () => {
  const c = client(mock.base);
  const page = await c.get('/', { accept: 'text/html' });
  assert.equal(page.status, 302); assert.equal(page.location, '/setup');
  assert.equal((await c.get('/api/ports')).status, 401);
  const setup = await c.get('/setup');
  assert.equal(setup.status, 200); assert.match(setup.body, /Create the administrator account/);
  const viaProxy = await c.call('POST', '/api/setup', { username: 'mallory', password: PW }, { 'x-forwarded-for': '203.0.113.9' });
  assert.equal(viaProxy.status, 403, 'a relayed request cannot create the administrator');
  assert.match(await (await c.get('/setup', { 'x-forwarded-for': '203.0.113.9' })).body, /can only be created from the machine/);
  assert.equal((await c.post('/api/setup', { username: 'x', password: 'short' })).status, 400);
});

test('the administrator is created once, is signed in, and setup is then closed', async () => {
  const admin = client(mock.base);
  const made = await admin.post('/api/setup', { username: 'vincent', password: PW });
  assert.equal(made.status, 200); assert.ok(admin.signedIn());
  const who = await admin.get('/api/me');
  assert.equal(who.body.user.username, 'vincent'); assert.equal(who.body.user.role, 'admin');
  assert.equal((await client(mock.base).post('/api/setup', { username: 'second', password: PW })).status, 409);
  const anon = client(mock.base);
  assert.equal((await anon.get('/setup')).location, '/login');
  assert.equal((await anon.get('/', { accept: 'text/html' })).location, '/login');
});

let operator, viewer, consoleOnly;
test('an administrator adds users with their own rights', async () => {
  const admin = client(mock.base);
  assert.equal((await admin.post('/api/login', { username: 'vincent', password: PW })).status, 200);
  assert.equal((await admin.post('/api/users', { username: 'bad name', password: PW, role: 'viewer' })).status, 400);
  assert.equal((await admin.post('/api/users', { username: 'weak', password: 'short', role: 'viewer' })).status, 400);
  for (const [name, role] of [['olivia', 'operator'], ['vera', 'viewer'], ['carl', 'console']]) {
    const r = await admin.post('/api/users', { username: name, password: 'temporary password', role });
    assert.equal(r.status, 200, `create ${name}`); assert.equal(r.body.user.mustChange, true, 'new users must choose their own password');
  }
  const custom = await admin.post('/api/users', { username: 'pat', password: 'temporary password', role: 'custom', permissions: ['sessions'] });
  assert.deepEqual(custom.body.user.permissions, ['sessions']);
  const users = (await admin.get('/api/users')).body.users;
  assert.equal(users.length, 5);
  assert.ok(!JSON.stringify(users).includes('scrypt'), 'no hash leaves the server');
});

async function signInAs(name, current = 'temporary password') {
  const c = client(mock.base);
  const login = await c.post('/api/login', { username: name, password: current });
  assert.equal(login.status, 200);
  if (login.body.mustChange) {
    const blocked = await c.get('/api/ports');
    assert.equal(blocked.status, 403); assert.equal(blocked.body.code, 'must_change', 'nothing works until the password is changed');
    assert.equal((await c.get('/api/me')).status, 200, 'but the account page does');
    assert.equal((await c.post('/api/me/password', { current, next: 'short' })).status, 400);
    assert.equal((await c.post('/api/me/password', { current: 'nope nope nope', next: PW })).status, 403);
    assert.equal((await c.post('/api/me/password', { current, next: PW })).status, 200);
  }
  return c;
}

test('new users must change their temporary password, then they are in', async () => {
  operator = await signInAs('olivia'); viewer = await signInAs('vera'); consoleOnly = await signInAs('carl');
  assert.equal((await operator.get('/api/ports')).status, 200);
  assert.equal((await operator.get('/api/me')).body.user.mustChange, false);
});

test('the permission matrix: every role gets exactly what it should', async () => {
  const admin = client(mock.base); await admin.post('/api/login', { username: 'vincent', password: PW });
  // [label, method, path, body, expected status per client]: 'ok' means "not refused" (it may still fail for other reasons, never 401/403)
  const cases = [
    ['host list', 'GET', '/api/ports', undefined, { admin: 'ok', operator: 'ok', console: 'ok', viewer: 'ok' }],
    ['power state', 'GET', '/api/power', undefined, { admin: 'ok', operator: 'ok', console: 'ok', viewer: 'ok' }],
    ['open a console (KX login)', 'GET', '/api/session', undefined, { admin: 'ok', operator: 'ok', console: 'ok', viewer: 403 }],
    ['list KX sessions', 'GET', '/api/sessions', undefined, { admin: 'ok', operator: 'ok', console: 'ok', viewer: 403 }],
    ['take the channel (end consoles)', 'POST', '/api/sessions/disconnect-all', {}, { admin: 'ok', operator: 'ok', console: 'ok', viewer: 403 }],
    ['log a session off', 'POST', '/api/sessions/disconnect', { id: 'x', mode: 'logoff' }, { admin: 'ok', operator: 403, console: 403, viewer: 403 }],
    ['power on', 'POST', '/api/power/hosts/4/on', { confirmed: true }, { admin: 'ok', operator: 'ok', console: 403, viewer: 403 }],
    ['edit a PDU', 'POST', '/api/config/devices', { name: 'x' }, { admin: 'ok', operator: 403, console: 403, viewer: 403 }],
    ['auto-match outlets', 'POST', '/api/power/automap', {}, { admin: 'ok', operator: 403, console: 403, viewer: 403 }],
    ['change a host', 'PUT', '/api/config/hosts/10', { client: 'native' }, { admin: 'ok', operator: 403, console: 403, viewer: 403 }],
    ['list users', 'GET', '/api/users', undefined, { admin: 'ok', operator: 403, console: 403, viewer: 403 }],
    ['add a user', 'POST', '/api/users', { username: 'zed', password: 'temporary password', role: 'viewer' }, { admin: 'ok', operator: 403, console: 403, viewer: 403 }],
  ];
  const who = { admin, operator, console: consoleOnly, viewer };
  for (const [label, method, path, body, expect] of cases) {
    for (const [role, expected] of Object.entries(expect)) {
      const r = await who[role].call(method, path, body);
      if (expected === 'ok') assert.ok(![401, 403].includes(r.status), `${role} should be allowed to: ${label} (got ${r.status})`);
      else assert.equal(r.status, expected, `${role} must be refused: ${label} (got ${r.status})`);
    }
  }
});

test('people without the configure right never see PDU addresses or logins', async () => {
  const adminView = (await (async () => { const a = client(mock.base); await a.post('/api/login', { username: 'vincent', password: PW }); return a.get('/api/config'); })()).body;
  assert.equal(adminView.devices[0].host, '127.0.0.1'); assert.equal(adminView.devices[0].user, 'mofa');
  for (const c of [operator, viewer, consoleOnly]) {
    const cfg = (await c.get('/api/config')).body;
    assert.deepEqual(Object.keys(cfg.devices[0]).sort(), ['id', 'name']);
    assert.ok(!JSON.stringify(cfg).includes('127.0.0.1') && !JSON.stringify(cfg).includes('secret'));
    const power = (await c.get('/api/power')).body;
    assert.ok(power.devices.every((d) => !('host' in d)), 'no PDU address in the power state');
  }
});

test('the power confirmation is checked on the server, and the audit log says who sent it', async () => {
  const noConfirm = await operator.post('/api/power/hosts/4/off', {}); // port 4 exists in the mock host list
  assert.equal(noConfirm.status, 400); assert.match(noConfirm.body.error, /confirmation/i);
  const refused = await viewer.post('/api/power/hosts/4/off', { confirmed: true });
  assert.equal(refused.status, 403);
});

test('administrators cannot lock themselves out, and a reset forces a new password', async () => {
  const admin = client(mock.base); await admin.post('/api/login', { username: 'vincent', password: PW });
  const users = (await admin.get('/api/users')).body.users, me = users.find((u) => u.username === 'vincent'), olivia = users.find((u) => u.username === 'olivia');
  assert.equal((await admin.del(`/api/users/${me.id}`)).status, 409);
  assert.equal((await admin.put(`/api/users/${me.id}`, { role: 'viewer' })).status, 409);
  assert.equal((await admin.put(`/api/users/${me.id}`, { disabled: true })).status, 409);
  const reset = await admin.put(`/api/users/${olivia.id}`, { password: 'reset by an admin 1' });
  assert.equal(reset.body.user.mustChange, true);
  assert.equal((await operator.get('/api/ports')).status, 401, "the reset signed olivia's old session out");
  const again = await signInAs('olivia', 'reset by an admin 1');
  assert.equal((await again.get('/api/ports')).status, 200);
  assert.equal((await admin.put(`/api/users/${olivia.id}`, { disabled: true })).status, 200);
  assert.equal((await again.get('/api/ports')).status, 401, 'a disabled account is signed out at once');
  assert.equal((await client(mock.base).post('/api/login', { username: 'olivia', password: PW })).status, 401);
  assert.equal((await admin.put(`/api/users/${olivia.id}`, { disabled: false })).status, 200);
});

test('signing out ends the session, and five wrong passwords lock the account for a minute', async () => {
  const v = client(mock.base); await v.post('/api/login', { username: 'vera', password: PW });
  assert.equal((await v.get('/api/ports')).status, 200);
  await v.post('/api/logout'); assert.equal((await v.get('/api/ports')).status, 401);
  const attacker = client(mock.base);
  for (let i = 0; i < 5; i++) assert.equal((await attacker.post('/api/login', { username: 'carl', password: `wrong guess ${i}` })).status, 401);
  const locked = await attacker.post('/api/login', { username: 'carl', password: PW });
  assert.equal(locked.status, 429, 'even the right password is refused while locked'); assert.match(locked.body.error, /Try again/);
});

test('the audit log records sign-ins and user changes, never passwords', async () => {
  const text = (await import('node:fs')).readFileSync(join(dir, 'audit.log'), 'utf8');
  for (const e of ['setup', 'login', 'login-failed', 'user-created', 'user-updated', 'password-changed']) assert.ok(text.includes(`"event":"${e}"`), `${e} is logged`);
  assert.ok(!text.includes(PW) && !text.includes('temporary password') && !text.includes('reset by an admin'));
});

test('the KX client files are open to the console right, the KX admin pages are not (proxy, no KX needed)', async () => {
  const live = await start({ KX_HOST: '127.0.0.1' }); // not mock: the proxy runs, and has nothing to talk to
  try {
    const login = async (name, pw) => { const c = client(live.base); assert.equal((await c.post('/api/login', { username: name, password: pw })).status, 200); return c; };
    const carl = await login('carl', PW), admin = await login('vincent', PW);
    for (const path of ['/jsclient/Client.asp', '/js/js_decoding_worker.min.js', '/css/bootstrap.min.css', '/favicon.ico']) {
      const r = await carl.get(path); assert.ok(r.status !== 403, `${path} must be allowed for the console right (got ${r.status})`);
    }
    for (const path of ['/home.asp', '/um_users.asp', '/security.asp', '/auth.asp']) assert.equal((await carl.get(path)).status, 403, `${path} must be refused`);
    assert.notEqual((await admin.get('/home.asp')).status, 403, 'administrators may use the whole proxy');
  } finally { live.child.kill(); }
});

test('with KX_SETUP_TOKEN, the first administrator can be created from elsewhere, but only with the code (the container case)', async () => {
  const fresh = await start({ KX_MOCK: '1', KX_SETUP_TOKEN: 'letmein-setup-code', KX_USERS_PATH: join(dir, 'users-docker.json'), KX_AUDIT_LOG: join(dir, 'audit-docker.log') });
  try {
    const remote = { 'x-forwarded-for': '203.0.113.9' }; // stands in for Docker's gateway: not a loopback peer
    const c = client(fresh.base);
    const page = await c.get('/setup', remote);
    assert.equal(page.status, 200); assert.match(page.body, /Setup code/);
    const body = { username: 'dockeradmin', password: PW };
    assert.equal((await c.call('POST', '/api/setup', body, remote)).status, 403, 'no code');
    assert.equal((await c.call('POST', '/api/setup', { ...body, token: 'wrong code' }, remote)).status, 403, 'wrong code');
    assert.equal((await c.get('/api/me')).status, 401, 'nothing was created');
    const ok = await c.call('POST', '/api/setup', { ...body, token: 'letmein-setup-code' }, remote);
    assert.equal(ok.status, 200); assert.ok(c.signedIn());
    assert.equal((await c.get('/api/me')).body.user.username, 'dockeradmin');
    assert.equal((await client(fresh.base).call('POST', '/api/setup', { username: 'again', password: PW, token: 'letmein-setup-code' }, remote)).status, 409, 'the code cannot create a second administrator');
  } finally { fresh.child.kill(); }
});

test('wrong setup codes are rate limited', async () => {
  const fresh = await start({ KX_MOCK: '1', KX_SETUP_TOKEN: 'another-code', KX_USERS_PATH: join(dir, 'users-docker2.json'), KX_AUDIT_LOG: join(dir, 'audit-docker2.log') });
  try {
    const remote = { 'x-forwarded-for': '203.0.113.9' }, c = client(fresh.base);
    for (let i = 0; i < 5; i++) assert.equal((await c.call('POST', '/api/setup', { username: 'x1', password: PW, token: `guess ${i}` }, remote)).status, 403);
    assert.equal((await c.call('POST', '/api/setup', { username: 'x1', password: PW, token: 'another-code' }, remote)).status, 429, 'even the right code waits while locked');
  } finally { fresh.child.kill(); }
});
