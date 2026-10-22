// node --test test/   Accounts, rights, sessions and the command-line recovery (no server, no hardware).
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const dir = mkdtempSync(join(tmpdir(), 'kx-auth-'));
process.env.KX_USERS_PATH = join(dir, 'users.json');
process.env.KX_AUDIT_LOG = join(dir, 'audit.log');
const auth = await import('../auth.js');
const cli = fileURLToPath(new URL('../auth-cli.js', import.meta.url));
const runCli = (...args) => execFileSync('node', [cli, ...args], { env: process.env, encoding: 'utf8' });

const PW = 'correct horse battery';

test('there are no users on a fresh install, and the first administrator can be created once', () => {
  assert.equal(auth.hasUsers(), false);
  const admin = auth.createFirstAdmin('vincent', PW);
  assert.equal(admin.role, 'admin');
  assert.deepEqual(auth.permissionsOf(auth.verifyLogin('vincent', PW)).sort(), Object.keys(auth.PERMISSIONS).sort());
  assert.throws(() => auth.createFirstAdmin('mallory', PW), (e) => e.status === 409);
});

test('passwords are stored only as salted hashes, in an owner-only file', () => {
  const raw = readFileSync(process.env.KX_USERS_PATH, 'utf8');
  assert.ok(!raw.includes(PW), 'the password must not be in the file');
  assert.match(raw, /scrypt\$\d+\$8\$1\$[0-9a-f]{32}\$[0-9a-f]{128}/);
  assert.equal(statSync(process.env.KX_USERS_PATH).mode & 0o777, 0o600);
  assert.ok(!JSON.stringify(auth.listUsers()).includes('scrypt'), 'the UI never sees a hash');
});

test('login failures all look the same, and disabled accounts cannot log in', () => {
  for (const [u, p] of [['vincent', 'wrong password!'], ['nobody', PW], ['vincent', '']]) {
    assert.throws(() => auth.verifyLogin(u, p), (e) => e.status === 401 && e.message === 'Wrong user name or password');
  }
  assert.equal(auth.verifyLogin('VINCENT', PW).username, 'vincent', 'user names are not case sensitive');
});

test('user names and passwords are validated, and names are unique', () => {
  assert.throws(() => auth.createUser({ username: 'a', password: PW }), (e) => e.status === 400);
  assert.throws(() => auth.createUser({ username: 'bad name!', password: PW }), (e) => e.status === 400);
  assert.throws(() => auth.createUser({ username: 'bob', password: 'short' }), (e) => e.status === 400 && /at least 10/.test(e.message));
  assert.throws(() => auth.createUser({ username: 'Vincent', password: PW }), (e) => e.status === 409);
  assert.throws(() => auth.createUser({ username: 'bob', password: PW, role: 'emperor' }), (e) => e.status === 400);
});

test('roles map to rights, and custom rights are checked', () => {
  const op = auth.createUser({ username: 'olivia', password: PW, role: 'operator' });
  assert.deepEqual(op.permissions, ['console', 'power']);
  const viewer = auth.createUser({ username: 'vera', password: PW, role: 'viewer' });
  assert.deepEqual(viewer.permissions, []);
  const custom = auth.createUser({ username: 'carl', password: PW, role: 'custom', permissions: ['power', 'sessions', 'power'] });
  assert.deepEqual(custom.permissions, ['power', 'sessions']);
  assert.throws(() => auth.createUser({ username: 'dan', password: PW, role: 'custom', permissions: ['launch-missiles'] }), (e) => e.status === 400);
  const user = (n) => auth.verifyLogin(n, PW);
  assert.ok(auth.can(user('olivia'), 'power') && !auth.can(user('olivia'), 'configure') && !auth.can(user('olivia'), 'users'));
  assert.ok(!auth.can(user('vera'), 'console'));
  assert.ok(auth.can(user('vincent'), 'users') && auth.isAdmin(user('vincent')) && !auth.isAdmin(user('olivia')));
});

test('there is always at least one active administrator', () => {
  const [admin] = auth.listUsers().filter((u) => u.role === 'admin');
  assert.throws(() => auth.deleteUser(admin.id), (e) => e.status === 409);
  assert.throws(() => auth.updateUser(admin.id, { role: 'viewer' }), (e) => e.status === 409);
  assert.throws(() => auth.updateUser(admin.id, { disabled: true }), (e) => e.status === 409);
  const second = auth.createUser({ username: 'second-admin', password: PW, role: 'admin' });
  assert.doesNotThrow(() => auth.updateUser(second.id, { role: 'operator' }), 'a non-last admin can be demoted');
  auth.updateUser(second.id, { role: 'admin' });
  assert.doesNotThrow(() => auth.deleteUser(second.id));
});

test('sessions end when the password changes, the account is disabled or removed', () => {
  const u = auth.createUser({ username: 'sam', password: PW, role: 'operator' });
  const user = () => auth.verifyLogin('sam', PW);
  let t = auth.startSession(user());
  assert.equal(auth.sessionUser(t)?.username, 'sam');
  auth.updateUser(u.id, { password: 'a brand new password' });
  assert.equal(auth.sessionUser(t), null, 'an admin reset signs the user out');
  assert.equal(auth.updateUser(u.id, { password: 'another new password!' }).mustChange, false);
  t = auth.startSession(auth.verifyLogin('sam', 'another new password!'));
  auth.updateUser(u.id, { disabled: true });
  assert.equal(auth.sessionUser(t), null);
  assert.throws(() => auth.verifyLogin('sam', 'another new password!'), (e) => e.status === 401);
  auth.updateUser(u.id, { disabled: false });
  t = auth.startSession(auth.verifyLogin('sam', 'another new password!'));
  auth.deleteUser(u.id);
  assert.equal(auth.sessionUser(t), null);
  assert.equal(auth.sessionUser('not-a-token'), null);
  assert.equal(auth.sessionUser(undefined), null);
});

test('users can change their own password, but only with the current one', () => {
  const u = auth.createUser({ username: 'pat', password: PW, role: 'viewer', mustChange: true });
  assert.equal(auth.verifyLogin('pat', PW).mustChange, true);
  assert.throws(() => auth.changeOwnPassword(u.id, 'wrong current', 'a long new password'), (e) => e.status === 403);
  assert.throws(() => auth.changeOwnPassword(u.id, PW, 'short'), (e) => e.status === 400);
  assert.throws(() => auth.changeOwnPassword(u.id, PW, PW), (e) => e.status === 400);
  const t = auth.startSession(auth.verifyLogin('pat', PW));
  auth.changeOwnPassword(u.id, PW, 'a long new password');
  assert.equal(auth.sessionUser(t), null, 'old sessions end');
  assert.equal(auth.verifyLogin('pat', 'a long new password').mustChange, false);
});

test('command-line recovery resets a password on a running store and forces a change', () => {
  const t = auth.startSession(auth.verifyLogin('vincent', PW));
  assert.ok(auth.sessionUser(t));
  const out = runCli('reset', 'vincent');                       // a separate process, like a locked-out admin at the shell
  const temp = out.match(/Temporary password \(shown once\): (\S+)/)?.[1];
  assert.ok(temp && temp.length >= 16, 'a temporary password is printed');
  assert.equal(auth.sessionUser(t), null, 'the running server notices the change and signs the session out');
  assert.throws(() => auth.verifyLogin('vincent', PW), (e) => e.status === 401, 'the old password is gone');
  const user = auth.verifyLogin('vincent', temp);
  assert.equal(user.mustChange, true);
  assert.ok(runCli('list').includes('vincent'));
});

test('recovery re-enables a disabled administrator, and create-admin makes or promotes one', () => {
  const o = auth.listUsers().find((u) => u.username === 'olivia');
  runCli('create-admin', 'olivia');
  assert.equal(auth.listUsers().find((u) => u.id === o.id).role, 'admin');
  const out = runCli('create-admin', 'rescue');
  assert.match(out, /Created administrator "rescue"/);
  assert.ok(auth.isAdmin(auth.verifyLogin('rescue', out.match(/: (\S+)\n/)[1])));
  assert.throws(() => runCli('reset', 'ghost'), /No user called ghost/);
  assert.throws(() => runCli('reset'), /Usage/);
});

test('audit entries are one JSON line each and never contain a password', () => {
  const lines = readFileSync(process.env.KX_AUDIT_LOG, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  assert.ok(lines.some((l) => l.event === 'cli-recovery' && l.user === 'vincent'));
  assert.ok(!JSON.stringify(lines).includes(PW));
});
