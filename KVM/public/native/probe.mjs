// Node dev tool: runs the e-RIC RFB handshake against a running dashboard server and prints what the KX sends,
// without decoding video. Use it to check protocol changes after a KX firmware update:
//
//   node public/native/probe.mjs 8        # KX port number as in the KX UI (1-based)
//
// It only connects if nothing is using a console (no proxied console socket, no busy port), and disconnects
// after a few frames. The session id comes from the dashboard server's own login (/api/session) and is never printed.

import { RfbSession } from './rfbproto.js';

const base = process.env.KX_DASHBOARD ?? 'http://127.0.0.1:3000';
const port = Number(process.argv[2]);
if (!port) { console.error('usage: node probe.mjs <port number, 1-based>'); process.exit(2); }

const state = await (await fetch(`${base}/api/ports`)).json();
if (state.rfbOpen) { console.log(`Not connecting: ${state.rfbOpen} console socket(s) already open through the dashboard.`); process.exit(3); }
const busy = state.ports.filter((p) => p.busy);
if (busy.length && !process.env.KX_PROBE_FORCE) { console.log(`Not connecting: in use right now: ${busy.map((p) => p.name).join(', ')} (set KX_PROBE_FORCE=1 to override)`); process.exit(3); }

const r = await fetch(`${base}/api/session`);
if (!r.ok) { console.log(`/api/session ${r.status}: ${(await r.json()).error}`); process.exit(4); }
const cookies = Object.fromEntries(r.headers.getSetCookie().map((c) => c.split(';')[0]).map((c) => [c.slice(0, c.indexOf('=')), c.slice(c.indexOf('=') + 1)]));
const sessionId = cookies.kvm_session_id ?? cookies.pp_session_id; // HKC's lookup order
if (!sessionId) { console.log(`No KX session cookie from /api/session (got: ${Object.keys(cookies).join(', ') || 'none'})`); process.exit(4); }

const t0 = Date.now();
const log = (...a) => console.log(`+${((Date.now() - t0) / 1000).toFixed(2)}s`, ...a);
const ws = new WebSocket(`${base.replace(/^http/, 'ws')}/rfb`);
ws.binaryType = 'arraybuffer';
let frames = 0, bytes = 0, finished = false;

const finish = (code) => {
  if (finished) return; finished = true;
  session.close(new Error('probe done'));
  if (ws.readyState < 2) ws.close(1000);
  setTimeout(() => process.exit(code), 300);
};

const session = new RfbSession({
  send: (b) => ws.readyState === 1 && ws.send(b),
  sessionId, portNo: port, appId: `probe_${Date.now()}`,
  on: (event, data) => {
    if (event === 'frame') {
      frames++;
      log(`frame #${frames}: ${data.w}x${data.h} at ${data.x},${data.y}, encoding 0x${(data.encoding >>> 0).toString(16)} (quality ${(data.encoding >> 12) & 15}), ${data.data.length} bytes`);
      session.requestUpdate(true);
      if (frames >= 5) finish(0);
    } else if (event === 'closed') { log('closed:', data?.message); finish(frames ? 0 : 1); }
    else if (event === 'ports') log('ports:', data.map((p) => `${p.portNo}=${p.portName}`).join(', '));
    else if (event === 'params') log('params:', JSON.stringify(data));
    else log(event, typeof data === 'object' ? JSON.stringify(data) : data);
  },
});

ws.onopen = () => { log('websocket open'); session.start(); };
ws.onmessage = (e) => { bytes += e.data.byteLength; session.feed(e.data); };
ws.onclose = (e) => { log(`socket closed (${e.code}); received ${bytes} bytes`); session.close(new Error('socket closed')); };
ws.onerror = () => log('websocket error');
setTimeout(() => { log('timeout'); finish(frames ? 0 : 1); }, 25000);
