// Power mapping for Synaccess netBooter PDUs: device config, outlet reading (read-only, via netbooter.js) and the
// matching of outlets to KX hosts. Nothing here switches an outlet.
//
// Config lives in .kx-config.json (owner-only, gitignored, plain text: it holds the PDU logins):
//   { devices: [{ id, name, host, port, user, password }],
//     mappings: { "<KX port number>": [{ device, outlet }] },     // a host can draw power from several outlets
//     hosts:    { "<KX port number>": { client: "native" | "raritan" } } }   // per-host settings
import { readFileSync } from 'node:fs';
import { writeFile, chmod } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { netbooterRun } from './netbooter.js';

const CONFIG_PATH = process.env.KX_CONFIG_PATH ?? fileURLToPath(new URL('./.kx-config.json', import.meta.url));

let config = { devices: [], mappings: {}, hosts: {} };
try { config = { ...config, ...JSON.parse(readFileSync(CONFIG_PATH, 'utf8')) }; } catch { /* first run */ }

async function save() {
  await writeFile(CONFIG_PATH, JSON.stringify(config, null, 2), { mode: 0o600 });
  await chmod(CONFIG_PATH, 0o600).catch(() => {});
}

const publicDevice = ({ password, ...d }) => ({ ...d, hasPassword: Boolean(password) });
const fail = (status, message) => Object.assign(new Error(message), { status });

// --- outlet text parsing and name matching (pure, unit-tested) ----------------------------------------------------

export function parsePshow(text) {
  const outlets = [...text.matchAll(/^\s*(\d+)\|\s*([^|]*?)\s*\|\s*(ON|OFF)\s*\|/gm)]
    .map(([, n, name, state]) => ({ n: Number(n), name, on: state === 'ON' }));
  const temp = text.match(/Environment Temperature:\s*(\d+(?:\.\d+)?)\s*C/i)?.[1];
  const amps = text.match(/AC current draw\s*\d*:\s*(\d+(?:\.\d+)?)/i)?.[1];
  return { outlets, tempC: temp ? Number(temp) : null, amps: amps ? Number(amps) : null };
}

const tokens = (s) => s.toUpperCase().split(/[\s_\-.]+/).filter(Boolean);

/**
 * Does outlet name `outlet` (as typed on the PDU: "XAG01", "CTL-MAC01", "OPC01-02") belong to KX host `host`
 * ("B25-CTL-XAG01")? The host's last token is its short name. The outlet may carry a leading part that is the tail of
 * the host name (the site/area prefix) and one trailing PSU index ("-01", "-B").
 */
export function outletMatchesHost(outlet, host) {
  const h = tokens(host), o = tokens(outlet);
  if (!h.length || !o.length) return false;
  const short = h[h.length - 1];
  const at = o.indexOf(short);
  if (at === -1) return false;
  const lead = o.slice(0, at), tail = o.slice(at + 1);
  const leadOk = lead.every((t, i) => h[h.length - 1 - lead.length + i] === t);
  const tailOk = tail.length === 0 || (tail.length === 1 && /^(\d{1,2}|[A-Z])$/.test(tail[0]));
  return leadOk && tailOk;
}

/** Proposed mapping { "<port>": [{device, outlet}] } for the hosts, from the outlets read off every device. */
export function matchOutlets(hosts, devices) {
  const found = {};
  for (const host of hosts) {
    if (!host.configured) continue;
    for (const dev of devices) {
      for (const o of dev.outlets ?? []) {
        if (outletMatchesHost(o.name, host.name)) (found[host.id] ??= []).push({ device: dev.id, outlet: o.n });
      }
    }
  }
  return found;
}

// --- reading the PDUs ----------------------------------------------------------------------------------------------

const TTL = 30_000;
const cache = new Map();   // device id -> { at, value }
const queues = new Map();  // device id -> promise chain, so one login runs at a time per PDU

function serial(id, task) {
  const next = (queues.get(id) ?? Promise.resolve()).then(task, task);
  queues.set(id, next.catch(() => {}));
  return next;
}

async function readDevice(dev, { refresh = false } = {}) {
  const hit = cache.get(dev.id);
  if (!refresh && hit && Date.now() - hit.at < TTL) return hit.value;
  return serial(dev.id, async () => {
    const again = cache.get(dev.id);
    if (!refresh && again && Date.now() - again.at < 2000) return again.value; // a queued caller just refreshed it
    let value;
    try {
      const r = await netbooterRun(dev, ['pshow'], { timeout: 20000, idle: 900 });
      value = { ok: true, ...parsePshow(r.results[0]) };
    } catch (e) { value = { ok: false, error: e.message.replace(dev.host + ': ', ''), outlets: [] }; }
    cache.set(dev.id, { at: Date.now(), value });
    return value;
  });
}

async function powerState({ refresh = false } = {}) {
  const devices = await Promise.all(config.devices.map(async (d) => ({ id: d.id, name: d.name, host: d.host, ...(await readDevice(d, { refresh })) })));
  const byPort = {};
  for (const [port, list] of Object.entries(config.mappings)) {
    byPort[port] = list.map(({ device, outlet }) => {
      const dev = devices.find((d) => d.id === device);
      const o = dev?.outlets.find((x) => x.n === outlet);
      return { device, deviceName: dev?.name ?? device, outlet, name: o?.name ?? null, on: dev?.ok ? (o?.on ?? null) : null, reachable: Boolean(dev?.ok) };
    });
  }
  return { devices, byPort };
}

// --- validation ------------------------------------------------------------------------------------------------------

const HOST_RE = /^(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$|^[0-9a-fA-F:]+$/;

function cleanDevice(input, existing) {
  const name = String(input.name ?? existing?.name ?? '').trim();
  const host = String(input.host ?? existing?.host ?? '').trim();
  const port = Number(input.port ?? existing?.port ?? 23);
  const user = String(input.user ?? existing?.user ?? '').trim();
  const password = input.password === undefined || input.password === '' ? existing?.password : String(input.password);
  if (!name || name.length > 60) throw fail(400, 'A name (up to 60 characters) is required');
  if (!HOST_RE.test(host)) throw fail(400, 'Enter an IP address or host name');
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw fail(400, 'Port must be 1-65535');
  if (!user || !password) throw fail(400, 'User and password are required');
  return { name, host, port, user, password };
}

const slug = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'pdu';
function uniqueId(name) {
  let id = slug(name), i = 2;
  while (config.devices.some((d) => d.id === id)) id = `${slug(name)}-${i++}`;
  return id;
}

const portKey = (v) => { const n = Number(v); if (!Number.isInteger(n) || n < 1 || n > 999) throw fail(400, 'Bad port'); return String(n); };

function cleanOutlets(list) {
  if (!Array.isArray(list)) throw fail(400, 'outlets must be a list');
  const seen = new Set();
  return list.map(({ device, outlet }) => {
    if (!config.devices.some((d) => d.id === device)) throw fail(400, `Unknown device ${device}`);
    const n = Number(outlet);
    if (!Number.isInteger(n) || n < 1 || n > 64) throw fail(400, 'Bad outlet number');
    const key = `${device}:${n}`;
    if (seen.has(key)) throw fail(400, 'Duplicate outlet');
    seen.add(key);
    return { device, outlet: n };
  });
}

// --- HTTP routes ---------------------------------------------------------------------------------------------------

/** Returns true if it handled the request. `readPorts()` supplies the KX host list for auto-matching. */
export async function powerRoutes(req, res, pathname, { readJson, json, readPorts }) {
  if (pathname === '/api/config' && req.method === 'GET') {
    json(res, 200, { devices: config.devices.map(publicDevice), mappings: config.mappings, hosts: config.hosts });
    return true;
  }
  if (pathname === '/api/power' && req.method === 'GET') {
    const refresh = new URL(req.url, 'http://x').searchParams.get('refresh') === '1';
    json(res, 200, await powerState({ refresh }));
    return true;
  }

  if (pathname === '/api/config/devices' && req.method === 'POST') {
    const d = cleanDevice(await readJson(req));
    const dev = { id: uniqueId(d.name), ...d };
    config.devices.push(dev);
    await save();
    json(res, 200, { device: publicDevice(dev) });
    return true;
  }

  let m = pathname.match(/^\/api\/config\/devices\/([a-z0-9-]+)(\/test)?$/);
  if (m) {
    const dev = config.devices.find((d) => d.id === m[1]);
    if (!dev) throw fail(404, 'Unknown device');
    if (m[2] && req.method === 'POST') { // test: read the outlets now
      await readJson(req);
      const v = await readDevice(dev, { refresh: true });
      json(res, v.ok ? 200 : 502, v.ok ? { ok: true, outlets: v.outlets.length, named: v.outlets.filter((o) => !/^Outlet\d+$/i.test(o.name)).length } : { error: v.error });
      return true;
    }
    if (req.method === 'PUT') {
      Object.assign(dev, cleanDevice(await readJson(req), dev));
      cache.delete(dev.id);
      await save();
      json(res, 200, { device: publicDevice(dev) });
      return true;
    }
    if (req.method === 'DELETE') {
      config.devices = config.devices.filter((d) => d !== dev);
      for (const [port, list] of Object.entries(config.mappings)) {
        const kept = list.filter((x) => x.device !== dev.id);
        if (kept.length) config.mappings[port] = kept; else delete config.mappings[port];
      }
      cache.delete(dev.id);
      await save();
      json(res, 200, { ok: true });
      return true;
    }
  }

  if (pathname === '/api/power/automap' && req.method === 'POST') {
    const { overwrite = false } = await readJson(req);
    const state = await powerState({ refresh: true });
    const proposal = matchOutlets(await readPorts(), state.devices);
    const changed = {};
    for (const [port, list] of Object.entries(proposal)) {
      if (!overwrite && config.mappings[port]?.length) continue; // keep what the user set by hand
      config.mappings[port] = list;
      changed[port] = list;
    }
    await save();
    json(res, 200, { matched: Object.keys(changed).length, mappings: config.mappings, unreachable: state.devices.filter((d) => !d.ok).map((d) => d.name) });
    return true;
  }

  m = pathname.match(/^\/api\/config\/hosts\/(\d+)$/);
  if (m) {
    const port = portKey(m[1]);
    if (req.method === 'PUT') { // { outlets?: [{device, outlet}], client?: 'native'|'raritan'|'' }
      const body = await readJson(req);
      if (body.outlets !== undefined) {
        const list = cleanOutlets(body.outlets);
        if (list.length) config.mappings[port] = list; else delete config.mappings[port];
      }
      if (body.client !== undefined) {
        if (!['native', 'raritan', ''].includes(body.client)) throw fail(400, 'client must be native, raritan or empty');
        if (body.client) config.hosts[port] = { ...config.hosts[port], client: body.client };
        else if (config.hosts[port]) { delete config.hosts[port].client; if (!Object.keys(config.hosts[port]).length) delete config.hosts[port]; }
      }
      await save();
      json(res, 200, { mappings: config.mappings, hosts: config.hosts });
      return true;
    }
  }
  return false;
}
