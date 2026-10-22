// Accounts, roles and login sessions for the dashboard. No dependencies.
//
// Users live in .kx-users.json (owner-only, gitignored): passwords are stored only as salted scrypt hashes. The file is
// re-read whenever it changes on disk, so `node auth-cli.js reset <user>` takes effect on a running server.
//
// Rights are a short list of permissions (admin has all of them). Everybody signed in can see the host list and power state.
//   console    open console sessions, and end other clients' console sessions to take the KX's single channel
//   power      switch outlets (on / off / cycle) for hosts that are not locked
//   sessions   disconnect or log off other sessions on the KX
//   configure  edit PDU devices, outlet mappings and per-host settings
//   users      add, change and remove users
import { scryptSync, randomBytes, timingSafeEqual } from 'node:crypto';
import { readFileSync, writeFileSync, renameSync, statSync, chmodSync, appendFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const USERS_PATH = process.env.KX_USERS_PATH ?? fileURLToPath(new URL('./.kx-users.json', import.meta.url));
const AUDIT_PATH = process.env.KX_AUDIT_LOG ?? fileURLToPath(new URL('./.kx-audit.log', import.meta.url));

export const PERMISSIONS = {
  console: 'Open consoles',
  power: 'Switch power',
  sessions: 'End other sessions',
  configure: 'Edit PDUs, mappings, hosts',
  users: 'Manage users',
};
export const ROLES = {
  admin: { label: 'Administrator', permissions: Object.keys(PERMISSIONS) },
  operator: { label: 'Operator', permissions: ['console', 'power'] },
  console: { label: 'Console only', permissions: ['console'] },
  viewer: { label: 'Viewer', permissions: [] },
};

export const MIN_PASSWORD = 10;
const fail = (status, message) => Object.assign(new Error(message), { status });

// --- storage -----------------------------------------------------------------------------------------------------------

let store = { users: [] };
let loadedMtime = -1;

function load() {
  let mtime;
  try { mtime = statSync(USERS_PATH).mtimeMs; } catch { store = { users: [] }; loadedMtime = -1; return; }
  if (mtime === loadedMtime) return;
  try { store = { users: [], ...JSON.parse(readFileSync(USERS_PATH, 'utf8')) }; } catch { store = { users: [] }; }
  loadedMtime = mtime;
}

function save() {
  const tmp = `${USERS_PATH}.tmp`;
  writeFileSync(tmp, JSON.stringify(store, null, 2), { mode: 0o600 });
  renameSync(tmp, USERS_PATH);
  try { chmodSync(USERS_PATH, 0o600); } catch { /* best effort */ }
  loadedMtime = statSync(USERS_PATH).mtimeMs;
}

export function audit(event) {
  try { appendFileSync(AUDIT_PATH, JSON.stringify({ at: new Date().toISOString(), ...event }) + '\n', { mode: 0o600 }); } catch { /* never block on logging */ }
}

// --- passwords -----------------------------------------------------------------------------------------------------------

const SCRYPT = { N: 16384, r: 8, p: 1, maxmem: 64 * 1024 * 1024 };

function hashPassword(password) {
  const salt = randomBytes(16);
  const key = scryptSync(password, salt, 64, SCRYPT);
  return `scrypt$${SCRYPT.N}$${SCRYPT.r}$${SCRYPT.p}$${salt.toString('hex')}$${key.toString('hex')}`;
}

function checkPassword(password, stored) {
  const [scheme, N, r, p, salt, key] = String(stored ?? '').split('$');
  if (scheme !== 'scrypt' || !key) return false;
  const want = Buffer.from(key, 'hex');
  const got = scryptSync(password, Buffer.from(salt, 'hex'), want.length, { N: Number(N), r: Number(r), p: Number(p), maxmem: SCRYPT.maxmem });
  return got.length === want.length && timingSafeEqual(got, want);
}

const DUMMY_HASH = hashPassword('not-a-real-password'); // so an unknown user costs the same time as a wrong password

export function checkNewPassword(password) {
  if (typeof password !== 'string' || password.length < MIN_PASSWORD) throw fail(400, `The password must be at least ${MIN_PASSWORD} characters`);
  if (password.length > 200) throw fail(400, 'The password is too long');
}

export function randomPassword() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
  const bytes = randomBytes(16);
  return [...bytes].map((b) => alphabet[b % alphabet.length]).join('');
}

// --- users -----------------------------------------------------------------------------------------------------------------

const USERNAME_RE = /^[A-Za-z0-9._-]{2,32}$/;
const find = (username) => store.users.find((u) => u.username.toLowerCase() === String(username).toLowerCase());
const byId = (id) => store.users.find((u) => u.id === id);

export function hasUsers() { load(); return store.users.length > 0; }

/** Effective permissions of a user (an administrator has them all). */
export function permissionsOf(user) {
  return user.role === 'admin' ? Object.keys(PERMISSIONS) : (user.permissions ?? []).filter((p) => p in PERMISSIONS);
}
export const can = (user, permission) => Boolean(user) && !user.disabled && permissionsOf(user).includes(permission);
export const isAdmin = (user) => Boolean(user) && !user.disabled && user.role === 'admin';

/** What the UI may see about a user: never the hash. */
export function describe(user) {
  return {
    id: user.id, username: user.username, role: user.role, roleLabel: ROLES[user.role]?.label ?? 'Custom',
    permissions: permissionsOf(user), disabled: Boolean(user.disabled), mustChange: Boolean(user.mustChange),
    createdAt: user.createdAt, lastLogin: user.lastLogin ?? null,
  };
}

export function listUsers() { load(); return store.users.map(describe); }

function cleanRights({ role, permissions }, fallbackRole = 'viewer') {
  const r = role ?? fallbackRole;
  if (!(r in ROLES) && r !== 'custom') throw fail(400, 'Unknown role');
  if (r === 'custom') {
    if (!Array.isArray(permissions) || permissions.some((p) => !(p in PERMISSIONS))) throw fail(400, 'Unknown permission');
    return { role: 'custom', permissions: [...new Set(permissions)] };
  }
  return { role: r, permissions: [...ROLES[r].permissions] };
}

export function createUser({ username, password, role = 'viewer', permissions, mustChange = false }) {
  load();
  if (!USERNAME_RE.test(String(username ?? ''))) throw fail(400, 'The user name must be 2-32 letters, digits, dots, dashes or underscores');
  if (find(username)) throw fail(409, 'That user name is taken');
  checkNewPassword(password);
  const user = {
    id: randomBytes(8).toString('hex'), username, ...cleanRights({ role, permissions }), hash: hashPassword(password),
    pwdVersion: 1, mustChange, disabled: false, createdAt: new Date().toISOString(),
  };
  store.users.push(user);
  save();
  return describe(user);
}

const adminCount = (except) => store.users.filter((u) => u.role === 'admin' && !u.disabled && u.id !== except).length;

export function updateUser(id, { role, permissions, disabled, password, mustChange }) {
  load();
  const user = byId(id);
  if (!user) throw fail(404, 'Unknown user');
  const next = { ...user };
  if (role !== undefined || permissions !== undefined) Object.assign(next, cleanRights({ role: role ?? user.role, permissions }));
  if (disabled !== undefined) next.disabled = Boolean(disabled);
  if ((user.role === 'admin' && !user.disabled) && (next.role !== 'admin' || next.disabled) && adminCount(id) === 0) throw fail(409, 'There must be at least one active administrator');
  if (password !== undefined) {
    checkNewPassword(password);
    next.hash = hashPassword(password);
    next.pwdVersion = (user.pwdVersion ?? 1) + 1; // signs this user out everywhere
    next.mustChange = mustChange ?? false;
  } else if (mustChange !== undefined) next.mustChange = Boolean(mustChange);
  Object.assign(user, next);
  save();
  return describe(user);
}

export function deleteUser(id) {
  load();
  const user = byId(id);
  if (!user) throw fail(404, 'Unknown user');
  if (user.role === 'admin' && !user.disabled && adminCount(id) === 0) throw fail(409, 'There must be at least one active administrator');
  store.users = store.users.filter((u) => u.id !== id);
  save();
  endSessions(id);
}

/** Verify a login. Returns the user, or throws 401 with the same message for every failure. */
export function verifyLogin(username, password) {
  load();
  const user = find(username);
  const ok = checkPassword(String(password ?? ''), user?.hash ?? DUMMY_HASH);
  if (!user || !ok || user.disabled) throw fail(401, 'Wrong user name or password');
  user.lastLogin = new Date().toISOString();
  save();
  return user;
}

/** The user changes their own password (needs the current one). */
export function changeOwnPassword(id, current, next) {
  load();
  const user = byId(id);
  if (!user || !checkPassword(String(current ?? ''), user.hash)) throw fail(403, 'The current password is wrong');
  checkNewPassword(next);
  if (current === next) throw fail(400, 'Choose a different password');
  user.hash = hashPassword(next);
  user.pwdVersion = (user.pwdVersion ?? 1) + 1;
  user.mustChange = false;
  save();
  return user;
}

// --- login sessions (in memory: a restart signs everybody out) -------------------------------------------------------------

const IDLE_MS = 8 * 3600 * 1000;
const sessions = new Map(); // token -> { userId, pwdVersion, seen }

export function startSession(user) {
  const token = randomBytes(32).toString('hex');
  sessions.set(token, { userId: user.id, pwdVersion: user.pwdVersion ?? 1, seen: Date.now() });
  return token;
}

export function endSession(token) { sessions.delete(token); }

export function endSessions(userId) { for (const [t, s] of sessions) if (s.userId === userId) sessions.delete(t); }

/** The signed-in user for a token, or null. Expires after 8 idle hours, and when the password or account changes. */
export function sessionUser(token) {
  if (!token) return null;
  const s = sessions.get(token);
  if (!s) return null;
  load();
  const user = byId(s.userId);
  if (!user || user.disabled || (user.pwdVersion ?? 1) !== s.pwdVersion || Date.now() - s.seen > IDLE_MS) { sessions.delete(token); return null; }
  s.seen = Date.now();
  return user;
}

// --- first run and recovery (also used by auth-cli.js) -----------------------------------------------------------------------

/** Create the first administrator. Refuses once any user exists. */
export function createFirstAdmin(username, password) {
  load();
  if (store.users.length) throw fail(409, 'Setup is already done');
  return createUser({ username, password, role: 'admin' });
}

/** Recovery from the command line: set a new password (forcing a change at next login), re-enable the account. */
export function recoverUser(username, { admin = false } = {}) {
  load();
  const password = randomPassword();
  let user = find(username);
  if (!user) {
    if (!admin) throw fail(404, `No user called ${username}`);
    createUser({ username, password, role: 'admin', mustChange: true });
    return { created: true, password };
  }
  Object.assign(user, { hash: hashPassword(password), pwdVersion: (user.pwdVersion ?? 1) + 1, mustChange: true, disabled: false });
  if (admin) Object.assign(user, { role: 'admin', permissions: [...ROLES.admin.permissions] });
  save();
  return { created: false, password };
}
