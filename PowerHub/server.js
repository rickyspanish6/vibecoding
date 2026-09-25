// server.js — PowerHub
// ─────────────────────
// Serves the PowerHub dashboard and talks to the power equipment for it:
//   • CyberPower UPS through its RMCARD205 network card (SNMP v1/v2c, CyberPower MIB)
//   • Synaccess netBooter NP-1601DU PDU (HTTP/HTTPS cmd.cgi "$A" commands)
//   • a telnet console to the netBooter's own command line (WebSocket ↔ TCP 23)
// The server polls both devices, keeps an event log (events.json) and stores the
// settings (settings.json). Browsers only ever talk to this server.
//
// Run with Docker (recommended):
//   docker compose up -d --build
//
// Or directly:
//   npm install   (one time)
//   npm start     (= node server.js)
//
// Open:
//   http://localhost:8090
//
// Env: PORT (default 8090), DATA_DIR (folder for settings.json / events.json, default: this folder),
//      MOCK=1 (simulated UPS and PDU — for trying the dashboard without hardware)

const http  = require('http');
const https = require('https');
const net   = require('net');
const fs    = require('fs');
const path  = require('path');

let snmp, WebSocketServer;
try {
  snmp = require('net-snmp');
  WebSocketServer = require('ws').WebSocketServer;
} catch (e) {
  console.error(`\n  ERROR: package not found (${e.message.split('\n')[0]}).`);
  console.error('  Run:  npm install\n');
  process.exit(1);
}

const VERSION       = require('./package.json').version;
const HTTP_PORT     = parseInt(process.env.PORT || '8090', 10);
const DIR           = __dirname;
const DATA_DIR      = process.env.DATA_DIR || DIR;
const SETTINGS_FILE = path.join(DATA_DIR, 'settings.json');
const EVENTS_FILE   = path.join(DATA_DIR, 'events.json');
const MOCK          = process.env.MOCK === '1';
const MAX_EVENTS    = 500;

// ── Settings (settings.json) ─────────────────────────────────────────────────
// Passwords and SNMP write community are never sent back to the browser.
const SETTINGS_DEFAULTS = {
  pollSeconds: 5,
  ups: {
    enabled:        true,
    name:           'UPS',
    host:           '',
    port:           161,
    snmpVersion:    '1',        // '1' or '2c'
    readCommunity:  'public',
    writeCommunity: 'private',
  },
  pdu: {
    enabled:  true,
    name:     'netBooter',
    host:     '',
    protocol: 'http',            // 'http' or 'https' (HTTPS is only on DU models)
    port:     0,                 // 0 = protocol default
    telnetPort: 23,              // for the Console
    username: 'admin',
    password: 'admin',
    outlets:  [],                // [{ name, locked }] by outlet number - 1
  },
};
const SECRET_KEYS = { ups: ['writeCommunity'], pdu: ['password'] };

let settings = loadSettings();

function loadSettings() {
  try {
    const s = JSON.parse(fs.readFileSync(SETTINGS_FILE, 'utf8'));
    return {
      ...SETTINGS_DEFAULTS, ...s,
      ups: { ...SETTINGS_DEFAULTS.ups, ...s.ups },
      pdu: { ...SETTINGS_DEFAULTS.pdu, ...s.pdu },
    };
  } catch (e) {
    if (e.code !== 'ENOENT') console.error(`[Settings] Could not read settings.json: ${e.message}`);
    return JSON.parse(JSON.stringify(SETTINGS_DEFAULTS));
  }
}

function saveSettings() {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  fs.writeFileSync(SETTINGS_FILE, JSON.stringify(settings, null, 2));
}

// What the browser sees: secrets replaced by "is it set?" flags
function publicSettings() {
  const out = JSON.parse(JSON.stringify(settings));
  for (const [dev, keys] of Object.entries(SECRET_KEYS)) {
    for (const k of keys) { out[dev][k + 'Set'] = !!out[dev][k]; delete out[dev][k]; }
  }
  return out;
}

// Merges a device section from the browser; an absent/empty secret keeps the stored one
function mergeDevice(dev, current, incoming) {
  if (!incoming || typeof incoming !== 'object') return current;
  const next = { ...current };
  for (const k of Object.keys(SETTINGS_DEFAULTS[dev])) {
    if (!(k in incoming)) continue;
    if (SECRET_KEYS[dev].includes(k) && (incoming[k] === '' || incoming[k] == null)) continue;
    next[k] = incoming[k];
  }
  next.enabled  = !!next.enabled;
  next.port     = Math.max(0, Math.min(65535, parseInt(next.port, 10) || 0));
  next.host     = String(next.host || '').trim();
  next.name     = String(next.name || SETTINGS_DEFAULTS[dev].name).slice(0, 40);
  if (dev === 'ups') {
    next.snmpVersion = next.snmpVersion === '2c' ? '2c' : '1';
    if (!next.port) next.port = 161;
  }
  if (dev === 'pdu') {
    next.protocol = next.protocol === 'https' ? 'https' : 'http';
    next.telnetPort = Math.max(1, Math.min(65535, parseInt(next.telnetPort, 10) || 23));
    next.outlets  = (Array.isArray(next.outlets) ? next.outlets : []).slice(0, 32).map(o => ({
      name:   String((o && o.name) || '').slice(0, 40),
      locked: !!(o && o.locked),
    }));
  }
  return next;
}

// ── Event log (events.json) ──────────────────────────────────────────────────
let events = [];
try { events = JSON.parse(fs.readFileSync(EVENTS_FILE, 'utf8')); } catch (e) { events = []; }
let eventsDirty = false;

// level: 'info' | 'warn' | 'alarm' | 'action'
function logEvent(level, source, message) {
  events.unshift({ t: Date.now(), level, source, message });
  if (events.length > MAX_EVENTS) events.length = MAX_EVENTS;
  eventsDirty = true;
  console.log(`[${source}] ${message}`);
}

setInterval(() => {
  if (!eventsDirty) return;
  eventsDirty = false;
  try {
    fs.mkdirSync(DATA_DIR, { recursive: true });
    fs.writeFileSync(EVENTS_FILE, JSON.stringify(events));
  } catch (e) { console.error(`[Events] Could not write events.json: ${e.message}`); }
}, 5000);

// ── CyberPower UPS over SNMP (RMCARD205, CPS-MIB 1.3.6.1.4.1.3808) ───────────
const U = '1.3.6.1.4.1.3808.1.1.1';
const UPS_OIDS = {
  model:           `${U}.1.1.1.0`,
  upsName:         `${U}.1.1.2.0`,
  firmware:        `${U}.1.2.1.0`,
  serial:          `${U}.1.2.3.0`,
  cardFirmware:    `${U}.1.2.4.0`,
  ratingVA:        `${U}.1.2.6.0`,
  ratingW:         `${U}.1.2.7.0`,
  batteryStatus:   `${U}.2.1.1.0`,   // 1 unknown, 2 normal, 3 low, 4 not present
  timeOnBattery:   `${U}.2.1.2.0`,   // TimeTicks
  batteryReplaced: `${U}.2.1.3.0`,
  batteryCapacity: `${U}.2.2.1.0`,   // %
  batteryVoltage:  `${U}.2.2.2.0`,   // 0.1 V
  batteryTemp:     `${U}.2.2.3.0`,   // °C
  runtime:         `${U}.2.2.4.0`,   // TimeTicks
  replaceBattery:  `${U}.2.2.5.0`,   // 1 no, 2 needs replacing
  inputVoltage:    `${U}.3.2.1.0`,   // 0.1 V
  inputFrequency:  `${U}.3.2.4.0`,   // 0.1 Hz
  lineFailCause:   `${U}.3.2.5.0`,
  outputStatus:    `${U}.4.1.1.0`,
  outputVoltage:   `${U}.4.2.1.0`,   // 0.1 V
  outputFrequency: `${U}.4.2.2.0`,   // 0.1 Hz
  load:            `${U}.4.2.3.0`,   // %
  outputCurrent:   `${U}.4.2.4.0`,   // 0.1 A
  outputPower:     `${U}.4.2.5.0`,   // W
  testResult:      `${U}.7.2.3.0`,
  lastTestDate:    `${U}.7.2.4.0`,
};

const OUTPUT_STATUS = {
  1: 'unknown', 2: 'online', 3: 'onBattery', 4: 'boost', 5: 'sleeping', 6: 'off',
  7: 'rebooting', 8: 'eco', 9: 'bypass', 10: 'buck', 11: 'overload',
};
const BATTERY_STATUS = { 1: 'unknown', 2: 'normal', 3: 'low', 4: 'notPresent' };
const TEST_RESULT    = { 1: 'passed', 2: 'failed', 3: 'invalid', 4: 'inProgress' };
const LINE_FAIL      = { 1: null, 2: 'High line voltage', 3: 'Brownout', 4: 'Self-test' };

// Commands the dashboard may send, as SNMP SETs (CPS-MIB upsAdvanceControl / upsAdvanceTest)
const UPS_ACTIONS = {
  selfTest:    { oid: `${U}.7.2.2.0`, value: 2, label: 'Battery self-test started' },
  calibrate:   { oid: `${U}.7.2.6.0`, value: 2, label: 'Runtime calibration started' },
  cancelCalib: { oid: `${U}.7.2.6.0`, value: 3, label: 'Runtime calibration cancelled' },
  beep:        { oid: `${U}.6.2.5.0`, value: 2, label: 'Flash & beep (locate UPS)' },
  reboot:      { oid: `${U}.6.2.2.0`, value: 2, label: 'UPS reboot (output power cycled)' },
  turnOff:     { oid: `${U}.6.2.1.0`, value: 2, label: 'UPS output turned OFF' },
  turnOn:      { oid: `${U}.6.2.6.0`, value: 2, label: 'UPS output turned ON' },
};

function snmpSession(cfg, write) {
  return snmp.createSession(cfg.host, write ? cfg.writeCommunity : cfg.readCommunity, {
    port:    cfg.port || 161,
    version: cfg.snmpVersion === '2c' ? snmp.Version2c : snmp.Version1,
    timeout: 2500,
    retries: 1,
  });
}

function snmpGet(session, oids) {
  return new Promise((resolve, reject) => {
    session.get(oids, (err, varbinds) => err ? reject(err) : resolve(varbinds));
  });
}

function varbindValue(vb) {
  if (!vb || snmp.isVarbindError(vb)) return null;
  return Buffer.isBuffer(vb.value) ? vb.value.toString('utf8').replace(/\0/g, '').trim() : vb.value;
}

// SNMPv1 fails a whole GET if any one object is missing on this UPS model, so on
// failure fall back to asking for each object on its own.
async function readUpsRaw(cfg) {
  const names = Object.keys(UPS_OIDS);
  const oids  = names.map(n => UPS_OIDS[n]);
  const session = snmpSession(cfg, false);
  try {
    let values;
    try {
      values = (await snmpGet(session, oids)).map(varbindValue);
    } catch (e) {
      if (e instanceof snmp.RequestTimedOutError) throw e;
      values = await Promise.all(oids.map(o => snmpGet(session, [o]).then(v => varbindValue(v[0]), () => null)));
      if (values.every(v => v === null)) throw e;
    }
    return Object.fromEntries(names.map((n, i) => [n, values[i]]));
  } finally {
    session.close();
  }
}

const tenth  = v => (typeof v === 'number' ? Math.round(v) / 10 : null);
const num    = v => (typeof v === 'number' ? v : null);
const ticksToSec = v => (typeof v === 'number' ? Math.round(v / 100) : null);

function normalizeUps(r) {
  // Some models (e.g. OR1500LCDRM1U) answer 0 A for output current whatever the load,
  // and repeat the firmware string as the serial number — hide those rather than show nonsense
  const noCurrent = r.outputCurrent === 0 && r.outputPower > 0;
  return {
    model:           r.model || null,
    upsName:         r.upsName || null,
    firmware:        r.firmware || null,
    serial:          r.serial && r.serial !== r.firmware ? r.serial : null,
    cardFirmware:    r.cardFirmware || null,
    ratingVA:        num(r.ratingVA),
    ratingW:         num(r.ratingW),
    outputStatus:    OUTPUT_STATUS[r.outputStatus] || 'unknown',
    batteryStatus:   BATTERY_STATUS[r.batteryStatus] || 'unknown',
    batteryCapacity: num(r.batteryCapacity),
    batteryVoltage:  tenth(r.batteryVoltage),
    batteryTemp:     num(r.batteryTemp),
    runtimeSec:      ticksToSec(r.runtime),
    onBatterySec:    ticksToSec(r.timeOnBattery),
    replaceBattery:  r.replaceBattery === 2,
    batteryReplaced: r.batteryReplaced || null,
    inputVoltage:    tenth(r.inputVoltage),
    inputFrequency:  tenth(r.inputFrequency),
    lineFailCause:   LINE_FAIL[r.lineFailCause] || null,
    outputVoltage:   tenth(r.outputVoltage),
    outputFrequency: tenth(r.outputFrequency),
    load:            num(r.load),
    outputCurrent:   noCurrent ? null : tenth(r.outputCurrent),
    outputPower:     num(r.outputPower),
    testResult:      TEST_RESULT[r.testResult] || null,
    lastTestDate:    r.lastTestDate || null,
  };
}

function upsAction(cfg, action) {
  const a = UPS_ACTIONS[action];
  if (!a) return Promise.reject(new Error('Unknown UPS action'));
  const session = snmpSession(cfg, true);
  return new Promise((resolve, reject) => {
    session.set([{ oid: a.oid, type: snmp.ObjectType.Integer, value: a.value }], (err, varbinds) => {
      session.close();
      if (err) return reject(err);
      if (snmp.isVarbindError(varbinds[0])) return reject(new Error(snmp.varbindError(varbinds[0])));
      resolve();
    });
  });
}

// ── Synaccess netBooter over HTTP (cmd.cgi "$A" commands) ────────────────────
//   $A5          → status: "bits,current[,current],temp"  (rightmost bit = outlet 1)
//   $A3 n 0|1    → set outlet n off/on
//   $A4 n        → reboot outlet n (off, delay, on — delay set on the netBooter)
//   $A7 0|1      → all outlets off/on
// Replies start with $A0 (OK) or $AF (failed). One request at a time: the
// embedded web server does not cope well with concurrent requests.
let pduQueue = Promise.resolve();

function pduCommand(cfg, cmd, timeoutMs) {
  const run = () => new Promise((resolve, reject) => {
    const mod  = cfg.protocol === 'https' ? https : http;
    const req  = mod.request({
      host:     cfg.host,
      port:     cfg.port || (cfg.protocol === 'https' ? 443 : 80),
      path:     '/cmd.cgi?' + cmd.replace(/ /g, '+'),
      method:   'GET',
      auth:     `${cfg.username}:${cfg.password}`,
      timeout:  timeoutMs,
      rejectUnauthorized: false,   // netBooters ship with a self-signed certificate
      headers:  { Connection: 'close' },
    }, res => {
      let body = '';
      res.setEncoding('latin1');
      res.on('data', c => { body += c; if (body.length > 65536) req.destroy(); });
      res.on('end', () => {
        if (res.statusCode === 401) return reject(new Error('Wrong username or password'));
        if (res.statusCode !== 200) return reject(new Error(`HTTP ${res.statusCode}`));
        resolve(body.replace(/<[^>]*>/g, '').trim());
      });
    });
    req.on('timeout', () => req.destroy(new Error('No response — timed out')));
    req.on('error', reject);
    req.end();
  });
  const p = pduQueue.then(run, run);
  pduQueue = p.catch(() => {});
  return p;
}

// Reading status changes nothing, so a dropped connection is retried once straight away.
// Commands are never retried: a repeated power-cycle would cycle the outlet twice.
async function pduStatus(cfg) {
  try {
    return await pduCommand(cfg, '$A5', 4000);
  } catch (e) {
    if (!['ECONNRESET', 'EPIPE'].includes(e.code) && !/socket hang up/i.test(e.message)) throw e;
    await new Promise(r => setTimeout(r, 300));
    return pduCommand(cfg, '$A5', 4000);
  }
}

function checkPduReply(body) {
  if (/\$AF/.test(body)) throw new Error('The netBooter refused the command');
  if (!/\$A0/.test(body)) throw new Error(`Unexpected reply: ${body.slice(0, 60)}`);
}

function parsePduStatus(body) {
  checkPduReply(body);
  const parts = body.slice(body.indexOf('$A0') + 3).split(',').map(s => s.trim()).filter(Boolean);
  const bits  = parts.shift() || '';
  if (!/^[01]+$/.test(bits)) throw new Error(`Unexpected status: ${body.slice(0, 60)}`);
  const temp  = parts.length > 1 ? parts.pop() : null;
  const currents = parts.map(c => parseFloat(c)).filter(c => !isNaN(c));
  const tempC = temp !== null && /^-?\d+(\.\d+)?$/.test(temp) ? parseFloat(temp) : null;
  return {
    outletStates: bits.split('').reverse().map(b => b === '1'),
    currents,
    tempC,
  };
}

// ── Mock devices (MOCK=1) ────────────────────────────────────────────────────
const mock = {
  outlets:    Array.from({ length: 16 }, (_, i) => i !== 11),
  onBattery:  false,
  capacity:   100,
  upsOn:      true,
  testUntil:  0,
};

function mockUps() {
  const t = Date.now() / 1000;
  if (mock.onBattery) mock.capacity = Math.max(5, mock.capacity - 0.4);
  else mock.capacity = Math.min(100, mock.capacity + 0.2);
  const load = mock.upsOn ? 34 + Math.round(3 * Math.sin(t / 20)) : 0;
  return normalizeUps({
    model: 'PR1500RTXL2UN', upsName: 'Rack UPS', firmware: 'PRMJ104', serial: 'MOCK12345678',
    cardFirmware: '1.4.3', ratingVA: 1500, ratingW: 1500,
    batteryStatus: mock.capacity < 20 ? 3 : 2, timeOnBattery: mock.onBattery ? 4200 : 0,
    batteryReplaced: '03/14/2025', batteryCapacity: Math.round(mock.capacity), batteryVoltage: 546,
    batteryTemp: 27, runtime: Math.round(mock.capacity * 0.42 * 6000), replaceBattery: 1,
    inputVoltage: mock.onBattery ? 0 : 1203 + Math.round(4 * Math.sin(t / 7)), inputFrequency: mock.onBattery ? 0 : 600,
    lineFailCause: mock.onBattery ? 3 : 1,
    outputStatus: !mock.upsOn ? 6 : mock.onBattery ? 3 : 2,
    outputVoltage: mock.upsOn ? 1200 : 0, outputFrequency: mock.upsOn ? 600 : 0,
    load, outputCurrent: Math.round(load * 1.25), outputPower: load * 15,
    testResult: Date.now() < mock.testUntil ? 4 : 1, lastTestDate: '09/20/2026',
  });
}

function mockPdu() {
  const on = mock.outlets.filter(Boolean).length;
  const bits = mock.outlets.slice().reverse().map(b => (b ? '1' : '0')).join('');
  return parsePduStatus(`$A0,${bits},${(on * 0.31).toFixed(2)},${(on * 0.12).toFixed(2)},29`);
}

// ── Polling & state ──────────────────────────────────────────────────────────
const state = {
  ups: { online: null, error: null, updatedAt: null, data: null },
  pdu: { online: null, error: null, updatedAt: null, outletStates: [], currents: [], tempC: null },
  pendingReboots: {},   // outlet number → time the reboot was requested
};

const configured = dev => MOCK || (settings[dev].enabled && !!settings[dev].host);

// A device only counts as offline after two failed polls in a row, so one dropped
// request (the netBooter's web server does that now and then) isn't reported as an outage
const failures = { ups: 0, pdu: 0 };

function setOnline(dev, ok, err) {
  const s = state[dev];
  const name = settings[dev].name;
  failures[dev] = ok ? 0 : failures[dev] + 1;
  if (!ok && failures[dev] < 2 && s.online) return;
  if (ok && s.online === false) logEvent('info', name, 'Connection restored');
  if (!ok && s.online !== false) logEvent('alarm', name, `Not responding — ${err}`);
  s.online = ok;
  s.error  = ok ? null : err;
}

async function pollUps() {
  if (!configured('ups')) { state.ups = { online: null, error: null, updatedAt: null, data: null }; return; }
  try {
    const data = MOCK ? mockUps() : normalizeUps(await readUpsRaw(settings.ups));
    const prev = state.ups.data;
    const name = settings.ups.name;
    if (prev) {
      if (prev.outputStatus !== 'onBattery' && data.outputStatus === 'onBattery')
        logEvent('alarm', name, `Power failure — running on battery${data.lineFailCause ? ` (${data.lineFailCause})` : ''}`);
      if (prev.outputStatus === 'onBattery' && data.outputStatus !== 'onBattery')
        logEvent('info', name, 'Utility power restored');
      if (prev.batteryStatus !== 'low' && data.batteryStatus === 'low')
        logEvent('alarm', name, 'Battery LOW');
      if (!prev.replaceBattery && data.replaceBattery)
        logEvent('warn', name, 'Battery needs replacing');
      if (prev.outputStatus !== 'overload' && data.outputStatus === 'overload')
        logEvent('alarm', name, 'Output overload');
      if (prev.outputStatus !== 'off' && data.outputStatus === 'off')
        logEvent('warn', name, 'UPS output is OFF');
      if (prev.testResult === 'inProgress' && data.testResult && data.testResult !== 'inProgress')
        logEvent(data.testResult === 'passed' ? 'info' : 'warn', name, `Self-test result: ${data.testResult}`);
    }
    state.ups.data = data;
    state.ups.updatedAt = Date.now();
    setOnline('ups', true);
  } catch (e) {
    setOnline('ups', false, snmpErrorText(e));
  }
}

async function pollPdu() {
  if (!configured('pdu')) { state.pdu = { online: null, error: null, updatedAt: null, outletStates: [], currents: [], tempC: null }; return; }
  try {
    const s = MOCK ? mockPdu() : parsePduStatus(await pduStatus(settings.pdu));
    const prev = state.pdu.outletStates;
    if (prev.length === s.outletStates.length) {
      s.outletStates.forEach((on, i) => {
        if (on !== prev[i] && !state.pendingReboots[i + 1])
          logEvent('info', settings.pdu.name, `${outletLabel(i + 1)} is now ${on ? 'ON' : 'OFF'}`);
      });
    }
    Object.assign(state.pdu, s, { updatedAt: Date.now() });
    setOnline('pdu', true);
  } catch (e) {
    setOnline('pdu', false, netErrorText(e));
  }
}

function snmpErrorText(e) {
  if (e instanceof snmp.RequestTimedOutError) return 'No response (check address, SNMP enabled, community)';
  return netErrorText(e);
}

// Plain wording for network errors (shown on the dashboard and in the event log)
function netErrorText(e) {
  const codes = {
    EHOSTUNREACH: 'Address unreachable', ENETUNREACH: 'Network unreachable', ECONNREFUSED: 'Connection refused',
    ECONNRESET: 'Connection dropped', ETIMEDOUT: 'No response — timed out', ENOTFOUND: 'Unknown address',
  };
  return codes[e.code] || e.message || String(e);
}

function outletLabel(n) {
  const o = settings.pdu.outlets[n - 1];
  return o && o.name ? `Outlet ${n} “${o.name}”` : `Outlet ${n}`;
}

let pollTimer = null;
async function pollLoop() {
  await Promise.all([pollUps(), pollPdu()]);
  for (const [n, t] of Object.entries(state.pendingReboots)) if (Date.now() - t > 60000) delete state.pendingReboots[n];
  pollTimer = setTimeout(pollLoop, Math.max(2, Math.min(60, settings.pollSeconds || 5)) * 1000);
}

function pollSoon() {
  clearTimeout(pollTimer);
  pollTimer = setTimeout(pollLoop, 700);
}

// ── HTTP server ──────────────────────────────────────────────────────────────
const STATIC = {
  '/':                     ['powerhub.html', 'text/html; charset=utf-8'],
  '/manifest.webmanifest': ['manifest.webmanifest', 'application/manifest+json'],
};
const MIME = { '.png': 'image/png', '.svg': 'image/svg+xml', '.ico': 'image/x-icon' };
// Terminal emulator for the Console, served from node_modules so it works without internet
const VENDOR = {
  '/vendor/xterm.js':     ['@xterm/xterm/lib/xterm.js', 'text/javascript'],
  '/vendor/xterm.css':    ['@xterm/xterm/css/xterm.css', 'text/css'],
  '/vendor/addon-fit.js': ['@xterm/addon-fit/lib/addon-fit.js', 'text/javascript'],
};

function sendJson(res, code, obj) {
  res.writeHead(code, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(obj));
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', c => { body += c; if (body.length > 1e6) req.destroy(); });
    req.on('end', () => { try { resolve(body ? JSON.parse(body) : {}); } catch (e) { reject(new Error('Invalid JSON')); } });
    req.on('error', reject);
  });
}

function statusPayload() {
  return {
    version: VERSION,
    mock:    MOCK,
    ups: { configured: configured('ups'), name: settings.ups.name, ...state.ups },
    pdu: {
      configured: configured('pdu'), name: settings.pdu.name,
      online: state.pdu.online, error: state.pdu.error, updatedAt: state.pdu.updatedAt,
      currents: state.pdu.currents, tempC: state.pdu.tempC,
      outlets: state.pdu.outletStates.map((on, i) => ({
        n: i + 1, on,
        name:   (settings.pdu.outlets[i] && settings.pdu.outlets[i].name) || '',
        locked: !!(settings.pdu.outlets[i] && settings.pdu.outlets[i].locked),
        rebooting: !!state.pendingReboots[i + 1],
      })),
    },
    events: events.slice(0, 50),
  };
}

async function handleApi(req, res, url) {
  const who = (req.socket.remoteAddress || '').replace(/^::ffff:/, '');

  if (url === '/api/status' && req.method === 'GET') return sendJson(res, 200, statusPayload());
  if (url === '/api/events' && req.method === 'GET') return sendJson(res, 200, events);
  if (url === '/api/settings' && req.method === 'GET') return sendJson(res, 200, publicSettings());

  if (url === '/api/settings' && req.method === 'POST') {
    const body = await readBody(req);
    settings = {
      pollSeconds: Math.max(2, Math.min(60, parseInt(body.pollSeconds, 10) || settings.pollSeconds)),
      ups: mergeDevice('ups', settings.ups, body.ups),
      pdu: mergeDevice('pdu', settings.pdu, body.pdu),
    };
    saveSettings();
    logEvent('info', 'PowerHub', `Settings saved (from ${who})`);
    pollSoon();
    return sendJson(res, 200, publicSettings());
  }

  // Test a connection with the values currently typed in Settings (not yet saved)
  if (url === '/api/test' && req.method === 'POST') {
    const body = await readBody(req);
    const dev  = body.device === 'ups' ? 'ups' : 'pdu';
    const cfg  = mergeDevice(dev, settings[dev], body.config);
    if (!cfg.host) return sendJson(res, 200, { ok: false, message: 'Enter an address first' });
    try {
      if (dev === 'ups') {
        const d = normalizeUps(await readUpsRaw(cfg));
        return sendJson(res, 200, { ok: true, message: [d.model, d.upsName].filter(Boolean).join(' · ') || 'Connected' });
      }
      const s = parsePduStatus(await pduStatus(cfg));
      return sendJson(res, 200, { ok: true, message: `${s.outletStates.length} outlets` });
    } catch (e) {
      return sendJson(res, 200, { ok: false, message: dev === 'ups' ? snmpErrorText(e) : netErrorText(e) });
    }
  }

  if (url === '/api/ups/action' && req.method === 'POST') {
    const { action } = await readBody(req);
    if (!UPS_ACTIONS[action]) return sendJson(res, 400, { ok: false, message: 'Unknown action' });
    if (!configured('ups')) return sendJson(res, 400, { ok: false, message: 'UPS is not set up' });
    try {
      if (MOCK) {
        if (action === 'turnOff') mock.upsOn = false;
        if (action === 'turnOn' || action === 'reboot') mock.upsOn = true;
        if (action === 'selfTest') mock.testUntil = Date.now() + 10000;
      } else {
        await upsAction(settings.ups, action);
      }
      logEvent('action', settings.ups.name, `${UPS_ACTIONS[action].label} (from ${who})`);
      pollSoon();
      return sendJson(res, 200, { ok: true });
    } catch (e) {
      const msg = /noAccess|notWritable|NoSuchName|ReadOnly|authorization/i.test(e.message)
        ? 'The UPS refused the command — check the write community in Settings'
        : snmpErrorText(e);
      logEvent('warn', settings.ups.name, `${UPS_ACTIONS[action].label} failed — ${msg}`);
      return sendJson(res, 200, { ok: false, message: msg });
    }
  }

  if (url === '/api/pdu/outlet' && req.method === 'POST') {
    const { outlet, action } = await readBody(req);
    const n = parseInt(outlet, 10);
    const count = state.pdu.outletStates.length || 16;
    if (!(n >= 1 && n <= count) || !['on', 'off', 'reboot'].includes(action))
      return sendJson(res, 400, { ok: false, message: 'Bad request' });
    if (!configured('pdu')) return sendJson(res, 400, { ok: false, message: 'netBooter is not set up' });
    const o = settings.pdu.outlets[n - 1];
    if (o && o.locked && action !== 'on')
      return sendJson(res, 200, { ok: false, message: `${outletLabel(n)} is locked. Unlock it in Settings first.` });
    try {
      if (MOCK) {
        if (action === 'reboot') {
          mock.outlets[n - 1] = false;
          setTimeout(() => { mock.outlets[n - 1] = true; delete state.pendingReboots[n]; pollSoon(); }, 5000);
        } else mock.outlets[n - 1] = action === 'on';
      } else {
        const cmd = action === 'reboot' ? `$A4 ${n}` : `$A3 ${n} ${action === 'on' ? 1 : 0}`;
        checkPduReply(await pduCommand(settings.pdu, cmd, 20000));
      }
      if (action === 'reboot') state.pendingReboots[n] = Date.now();
      logEvent('action', settings.pdu.name, `${outletLabel(n)} ${action === 'reboot' ? 'power-cycled' : 'turned ' + action.toUpperCase()} (from ${who})`);
      if (action !== 'reboot' && state.pdu.outletStates.length >= n) state.pdu.outletStates[n - 1] = action === 'on';
      pollSoon();
      return sendJson(res, 200, { ok: true });
    } catch (e) {
      logEvent('warn', settings.pdu.name, `${outletLabel(n)} ${action} failed — ${netErrorText(e)}`);
      return sendJson(res, 200, { ok: false, message: netErrorText(e) });
    }
  }

  if (url === '/api/pdu/all' && req.method === 'POST') {
    const { state: want } = await readBody(req);
    if (!['on', 'off'].includes(want)) return sendJson(res, 400, { ok: false, message: 'Bad request' });
    if (!configured('pdu')) return sendJson(res, 400, { ok: false, message: 'netBooter is not set up' });
    const lockedOn = settings.pdu.outlets.map((o, i) => (o && o.locked ? i + 1 : 0)).filter(Boolean);
    try {
      if (want === 'off' && lockedOn.length) {
        // $A7 would also switch locked outlets, so turn the unlocked ones off one by one
        const count = state.pdu.outletStates.length || 16;
        for (let n = 1; n <= count; n++) {
          if (lockedOn.includes(n) || state.pdu.outletStates[n - 1] === false) continue;
          if (MOCK) mock.outlets[n - 1] = false;
          else checkPduReply(await pduCommand(settings.pdu, `$A3 ${n} 0`, 20000));
        }
      } else if (MOCK) {
        mock.outlets = mock.outlets.map(() => want === 'on');
      } else {
        checkPduReply(await pduCommand(settings.pdu, `$A7 ${want === 'on' ? 1 : 0}`, 30000));
      }
      logEvent('action', settings.pdu.name,
        `All outlets turned ${want.toUpperCase()}${want === 'off' && lockedOn.length ? ' (locked outlets left on)' : ''} (from ${who})`);
      // Record the expected states now, so the next poll doesn't log each outlet again
      state.pdu.outletStates = state.pdu.outletStates.map((on, i) =>
        want === 'off' && lockedOn.includes(i + 1) ? on : want === 'on');
      pollSoon();
      return sendJson(res, 200, { ok: true });
    } catch (e) {
      logEvent('warn', settings.pdu.name, `All outlets ${want} failed — ${netErrorText(e)}`);
      return sendJson(res, 200, { ok: false, message: netErrorText(e) });
    }
  }

  if (url === '/api/events' && req.method === 'DELETE') {
    events = [];
    eventsDirty = true;
    logEvent('info', 'PowerHub', `Event log cleared (from ${who})`);
    return sendJson(res, 200, { ok: true });
  }

  sendJson(res, 404, { ok: false, message: 'Not found' });
}

const server = http.createServer(async (req, res) => {
  const url = decodeURIComponent((req.url || '/').split('?')[0]);
  try {
    if (url.startsWith('/api/')) return await handleApi(req, res, url);

    if (STATIC[url]) {
      const [file, type] = STATIC[url];
      res.writeHead(200, { 'Content-Type': type, 'Cache-Control': 'no-cache' });
      return fs.createReadStream(path.join(DIR, file)).pipe(res);
    }
    if (VENDOR[url]) {
      const [file, type] = VENDOR[url];
      res.writeHead(200, { 'Content-Type': type, 'Cache-Control': 'max-age=86400' });
      return fs.createReadStream(require.resolve(file)).pipe(res);
    }
    if (/^\/images\/icons\/[\w.-]+$/.test(url) && MIME[path.extname(url)]) {
      const file = path.join(DIR, url);
      if (fs.existsSync(file)) {
        res.writeHead(200, { 'Content-Type': MIME[path.extname(url)], 'Cache-Control': 'max-age=86400' });
        return fs.createReadStream(file).pipe(res);
      }
    }
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not found');
  } catch (e) {
    sendJson(res, 500, { ok: false, message: e.message });
  }
});

// ── netBooter telnet console (WebSocket /api/console ↔ TCP telnet) ───────────
// A plain relay: the person at the console logs in to the netBooter themselves —
// PowerHub never sends the saved password here, and never logs what is typed.
// Only one console at a time (the netBooter allows a single telnet session);
// opening a new one closes the previous one. Idle sessions close after 10 minutes.
const IAC = 255, DONT = 254, DO = 253, WONT = 252, WILL = 251, SB = 250, SE = 240;
const TELOPT_ECHO = 1, TELOPT_SGA = 3;
const CONSOLE_IDLE_MS = 10 * 60 * 1000;
const wss = new WebSocketServer({ noServer: true, maxPayload: 64 * 1024 });
let activeConsole = null;

// Strips telnet commands from the device's output and answers option requests:
// we let the device echo and suppress go-ahead, and refuse everything else.
function telnetFilter(sock) {
  let state = 0, cmd = 0;
  return chunk => {
    const out = [];
    for (const b of chunk) {
      if (state === 0) { if (b === IAC) state = 1; else out.push(b); }
      else if (state === 1) {
        if (b === IAC) { out.push(IAC); state = 0; }
        else if (b === SB) state = 3;
        else if (b >= WILL && b <= DONT) { cmd = b; state = 2; }
        else state = 0;
      } else if (state === 2) {
        const ok = b === TELOPT_ECHO || b === TELOPT_SGA;
        if (cmd === WILL) sock.write(Buffer.from([IAC, ok ? DO : DONT, b]));
        else if (cmd === DO) sock.write(Buffer.from([IAC, b === TELOPT_SGA ? WILL : WONT, b]));
        state = 0;
      } else if (state === 3) { if (b === IAC) state = 4; }
      else if (state === 4) state = b === SE ? 0 : 3;
    }
    return Buffer.from(out);
  };
}

function consoleSend(ws, obj) {
  if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(obj));
}

wss.on('connection', (ws, req) => {
  const who = (req.socket.remoteAddress || '').replace(/^::ffff:/, '');
  const cfg = settings.pdu;
  const label = settings.pdu.name;
  if (MOCK || !cfg.host) {
    consoleSend(ws, { type: 'status', state: 'closed', message: MOCK ? 'The console is not available in demo mode.' : 'Set up the netBooter address in Settings first.' });
    return ws.close();
  }
  if (activeConsole) {
    consoleSend(activeConsole, { type: 'status', state: 'closed', message: 'Console opened on another screen — this session was closed.' });
    activeConsole.close();
  }
  activeConsole = ws;

  const sock = net.connect({ host: cfg.host, port: cfg.telnetPort || 23 });
  const filter = telnetFilter(sock);
  let idle, opened = false;
  const bumpIdle = () => {
    clearTimeout(idle);
    idle = setTimeout(() => {
      consoleSend(ws, { type: 'status', state: 'closed', message: 'Closed after 10 minutes without activity.' });
      ws.close();
    }, CONSOLE_IDLE_MS);
  };
  const connectTimer = setTimeout(() => sock.destroy(new Error('No response — timed out')), 8000);

  consoleSend(ws, { type: 'status', state: 'connecting', message: `Connecting to ${label}…` });
  sock.on('connect', () => {
    clearTimeout(connectTimer);
    opened = true;
    bumpIdle();
    consoleSend(ws, { type: 'status', state: 'open', message: `Connected to ${label}` });
    logEvent('info', label, `Console opened (from ${who})`);
  });
  sock.on('data', chunk => {
    const data = filter(chunk);
    if (data.length) consoleSend(ws, { type: 'data', data: data.toString('latin1') });
  });
  sock.on('error', e => consoleSend(ws, { type: 'status', state: 'closed', message: `Could not connect: ${netErrorText(e)}` }));
  sock.on('close', () => {
    clearTimeout(connectTimer);
    clearTimeout(idle);
    consoleSend(ws, { type: 'status', state: 'closed', message: 'Connection closed by the netBooter.' });
    ws.close();
  });

  ws.on('message', raw => {
    let msg;
    try { msg = JSON.parse(raw); } catch (e) { return; }
    if (msg.type === 'data' && typeof msg.data === 'string' && opened) {
      bumpIdle();
      sock.write(Buffer.from(msg.data, 'latin1'));
    }
  });
  ws.on('close', () => {
    clearTimeout(idle);
    sock.destroy();
    if (activeConsole === ws) activeConsole = null;
    if (opened) logEvent('info', label, 'Console closed');
  });
});

server.on('upgrade', (req, socket, head) => {
  const url = (req.url || '').split('?')[0];
  // Same-origin only, so another web page can't open the console through someone's browser
  let sameOrigin = false;
  try { sameOrigin = new URL(req.headers.origin).host === req.headers.host; } catch (e) {}
  if (url !== '/api/console' || !sameOrigin) {
    socket.write('HTTP/1.1 403 Forbidden\r\n\r\n');
    return socket.destroy();
  }
  wss.handleUpgrade(req, socket, head, ws => wss.emit('connection', ws, req));
});

server.listen(HTTP_PORT, () => {
  console.log(`\n  PowerHub v${VERSION}${MOCK ? '  (MOCK devices)' : ''}`);
  console.log(`  Dashboard:  http://localhost:${HTTP_PORT}\n`);
  logEvent('info', 'PowerHub', `Server started (v${VERSION})`);
  pollLoop();
});
