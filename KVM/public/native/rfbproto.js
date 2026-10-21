// e-RIC RFB protocol layer for the Raritan Dominion KX III (see PROTOCOL.md).
// Transport-agnostic and DOM-free so it runs in the browser and in Node (native/probe.mjs):
// feed() it bytes from the WebSocket, and it calls `send` with the bytes to reply with.

const te = new TextEncoder();
const latin1 = (u8) => String.fromCharCode(...u8);

export const MSG = {
  FRAMEBUFFER_UPDATE: 0, USER_NOTIFICATION: 3, PORT_LIST: 4, SERVER_INIT: 5, UTF8_STRING: 7, VIDEO_SETTINGS: 8,
  KEYBOARD_LAYOUT: 9, OSD_STATE: 16, CONNECTION_PARAMETERS: 18, ACK_PIXEL_FORMAT: 19, AUTH_CAPS: 32,
  SESSION_CHALLENGE: 33, AUTH_SUCCESSFUL: 34, VERSION_INIT: 101, SERVER_FB_FORMAT: 128, SERVER_RC_MESSAGE: 131,
  SERVER_COMMAND: 132, PING_REPLY: 149, VM_MOUNTS_RESPONSE: 166, VM_SHARE_TABLE: 167, VIRTUAL_MEDIA_CONFIG: 168,
  USB_PROFILE_LIST: 170, PORT_LIST_EXT: 172, TERMINAL_CONFIG: 173, TERMINAL_INPUT: 174,
};

// Client -> server message types.
const C2S = {
  SET_PIXEL_FORMAT: 0, SET_ENCODINGS: 2, FB_UPDATE_REQUEST: 3, KEY_EVENT: 4, POINTER_EVENT: 5, CLIENT_INIT: 7,
  ASSOCIATED_TAG: 8, LOGIN: 32, CHALLENGE_RESPONSE: 33, VIDEO_SETTINGS_REQUEST: 145, VIDEO_REFRESH: 146,
  KVM_SWITCH: 137, PING_REQUEST: 148, POWER_SWITCH: 156, POINTER_RELATIVE: 147, MOUSE_SYNC: 134, SET_CONNECTION_PARAMETER: 155,
};

// HKC's wire value on this KX is 0xd081 = ICT | 13 << 12 (not the 9 in its source defaults).
export const DEFAULT_QUALITY = 13;
export const ENCODING = { LRLE_HARD: 128, ICT: 129, ICT_4K_420: 131 };
export const MOUSE = { LEFT: 1, MIDDLE: 2, RIGHT: 4 };
export const AUTH_HTTP_SESSION_ID = 1;

// Physical-key positions the KX expects in key events (HKC's rfb.Key enum).
export const KEY = {
  BACKQUOTE: 0, DIGIT1: 1, DIGIT2: 2, DIGIT3: 3, DIGIT4: 4, DIGIT5: 5, DIGIT6: 6, DIGIT7: 7, DIGIT8: 8, DIGIT9: 9,
  DIGIT0: 10, MINUS: 11, EQUALS: 12, BACKSPACE: 13, TAB: 14, Q: 15, W: 16, E: 17, R: 18, T: 19, Y: 20, U: 21, I: 22,
  O: 23, P: 24, BRACKETOPEN: 25, BRACKETCLOSE: 26, ENTER: 27, CAPSLOCK: 28, A: 29, S: 30, D: 31, F: 32, G: 33, H: 34,
  J: 35, K: 36, L: 37, SEMICOLON: 38, QUOTE: 39, BACKSLASH: 40, SHIFTLEFT: 41, INTLBACKSLASH: 42, Z: 43, X: 44,
  C: 45, V: 46, B: 47, N: 48, M: 49, COMMA: 50, PERIOD: 51, SLASH: 52, SHIFTRIGHT: 53, CONTROLLEFT: 54, ALTLEFT: 55,
  SPACE: 56, ALTRIGHT: 57, CONTROLRIGHT: 58, ESCAPE: 59, F1: 60, F2: 61, F3: 62, F4: 63, F5: 64, F6: 65, F7: 66,
  F8: 67, F9: 68, F10: 69, F11: 70, F12: 71, PRINTSCREEN: 72, SCROLLLOCK: 73, PAUSE: 74, INSERT: 75, HELP: 75,
  HOME: 76, PAGEUP: 77, DELETE: 78, END: 79, PAGEDOWN: 80, ARROWUP: 81, ARROWLEFT: 82, ARROWDOWN: 83,
  ARROWRIGHT: 84, NUMLOCK: 85, NUM7: 86, NUM8: 87, NUM9: 88, NUMADD: 89, NUMDIVIDE: 90, NUM4: 91, NUM5: 92,
  NUM6: 93, NUMMULTIPLY: 94, NUM1: 95, NUM2: 96, NUM3: 97, NUMENTER: 98, NUMSUBTRACT: 99, NUM0: 100,
  NUMDECIMAL: 101, NUMEQUAL: 132, METALEFT: 105, CONTEXTMENU: 106, METARIGHT: 107, F13: 134, F14: 135, F15: 136,
  F16: 137, F17: 138, F18: 139, F19: 140, F20: 141, F21: 142, F22: 143, F23: 144, F24: 145, NONCONVERT: 108,
  CONVERT: 109, KANAMODE: 110, INTLYEN: 112, INTLRO: 114,
};

const CODE_ALIASES = { Equal: 'EQUALS', BracketLeft: 'BRACKETOPEN', BracketRight: 'BRACKETCLOSE', OSLeft: 'METALEFT', OSRight: 'METARIGHT' };

/** KeyboardEvent.code -> the KX key number, or undefined if the key has no equivalent. */
export function keyFromCode(code) {
  const name = CODE_ALIASES[code]
    ?? code.replace(/^Key([A-Z])$/, '$1').replace(/^Digit(\d)$/, 'DIGIT$1').replace(/^Numpad/, 'NUM').toUpperCase();
  return KEY[name];
}

// What the KX says in user notifications (code >> 24 & 15 is the severity: 0 error, 1 warn, 2 info).
export const NOTIFICATIONS = {
  0x10000003: 'Authentication failed',
  0x10020001: 'Another client has exclusive access to this port',
  0x10020002: 'KVM access to this port is denied',
  0x10020003: 'Too many clients',
  0x10020004: 'Could not connect to the port',
  0x10020005: 'Maximum number of KVM connections has exceeded. Please try again later.',
  0x1002000d: 'Remote access denied',
  0x12060002: 'Disconnected',
  0x12060003: 'Disconnected by an administrator',
  0x1202000b: 'Port switch completed',
};

/** Byte queue that readers can await. Chunk boundaries of the transport are irrelevant to the protocol. */
export class ByteStream {
  constructor() { this.chunks = []; this.length = 0; this.waiters = []; this.failure = null; this.received = 0; this.consumed = 0; }

  push(data) {
    const u8 = data instanceof Uint8Array ? data : new Uint8Array(data);
    if (!u8.length) return;
    this.chunks.push(u8); this.length += u8.length; this.received += u8.length; this.#wake();
  }

  fail(err) { this.failure = err; this.#wake(); }

  #wake() { const w = this.waiters; this.waiters = []; for (const f of w) f(); }

  async read(n) {
    while (this.length < n) {
      if (this.failure) throw this.failure;
      await new Promise((r) => this.waiters.push(r));
    }
    const out = new Uint8Array(n);
    let o = 0;
    while (o < n) {
      const c = this.chunks[0], k = Math.min(c.length, n - o);
      out.set(c.subarray(0, k), o); o += k;
      if (k === c.length) this.chunks.shift(); else this.chunks[0] = c.subarray(k);
    }
    this.length -= n; this.consumed += n;
    return out;
  }

  /** Wait until n bytes are buffered without consuming them. */
  async wait(n) {
    while (this.length < n) {
      if (this.failure) throw this.failure;
      await new Promise((r) => this.waiters.push(r));
    }
  }

  /** Everything buffered right now (used by the challenge, whose length the protocol does not state). */
  takeAvailable() {
    const n = this.length, out = new Uint8Array(n);
    let o = 0;
    for (const c of this.chunks) { out.set(c, o); o += c.length; }
    this.chunks = []; this.length = 0; this.consumed += n;
    return out;
  }

  async u8() { return (await this.read(1))[0]; }
  async view(n) { const b = await this.read(n); return new DataView(b.buffer, b.byteOffset, n); }
  async u16() { return (await this.view(2)).getUint16(0); }
  async s16() { return (await this.view(2)).getInt16(0); }
  async u32() { return (await this.view(4)).getUint32(0); }
  async s32() { return (await this.view(4)).getInt32(0); }
  async str(n) { return latin1(await this.read(n)); }
}

const be16 = (v, n, o) => { v.setUint16(o, n); };

/** Frame builders (client -> server). All multi-byte fields are big-endian. */
export const write = {
  login: (auth, name = '') => {
    const nameBytes = te.encode(name), b = new Uint8Array(9 + nameBytes.length), v = new DataView(b.buffer);
    b[0] = C2S.LOGIN; b[1] = auth; b[2] = nameBytes.length + 1; v.setUint32(4, 0); b.set(nameBytes, 8);
    return b;
  },
  challengeResponse: (hex) => {
    const digest = te.encode(hex), b = new Uint8Array(2 + digest.length + 1);
    b[0] = C2S.CHALLENGE_RESPONSE; b[1] = digest.length + 1; b.set(digest, 2);
    return b;
  },
  associatedTag: (tag) => { const t = te.encode(tag), b = new Uint8Array(4 + t.length); b[0] = C2S.ASSOCIATED_TAG; be16(new DataView(b.buffer), t.length, 2); b.set(t, 4); return b; },
  clientInit: (hasTag) => { const b = new Uint8Array(4); b[0] = C2S.CLIENT_INIT; new DataView(b.buffer).setUint16(2, (hasTag ? 4 : 0) | 8); return b; },
  kvmSwitch: (portId) => { const t = te.encode(portId), b = new Uint8Array(4 + t.length); b[0] = C2S.KVM_SWITCH; be16(new DataView(b.buffer), t.length, 2); b.set(t, 4); return b; },
  // HKC always sends four encoding slots, of which only the first is set.
  setEncodings: (encoding) => { const b = new Uint8Array(20), v = new DataView(b.buffer); b[0] = C2S.SET_ENCODINGS; v.setUint16(2, 4); v.setUint32(4, encoding); return b; },
  setPixelFormat: (f) => {
    const b = new Uint8Array(20), v = new DataView(b.buffer);
    b[0] = C2S.SET_PIXEL_FORMAT; b[4] = f.bitsPerPixel; b[5] = f.depth; b[6] = f.bigEndian ? 1 : 0; b[7] = f.trueColor ? 1 : 0;
    v.setUint16(8, f.redMax); v.setUint16(10, f.greenMax); v.setUint16(12, f.blueMax);
    b[14] = f.redShift; b[15] = f.greenShift; b[16] = f.blueShift;
    return b;
  },
  fbUpdateRequest: (incremental, w, h) => { const b = new Uint8Array(10), v = new DataView(b.buffer); b[0] = C2S.FB_UPDATE_REQUEST; b[1] = incremental ? 1 : 0; v.setUint16(6, w); v.setUint16(8, h); return b; },
  key: (key, down) => { const b = new Uint8Array(4); b[0] = C2S.KEY_EVENT; new DataView(b.buffer).setUint16(2, (key & 0x7fff) | (down ? 0x8000 : 0)); return b; },
  // Absolute pointer: buttons bitmask, x/y in framebuffer pixels, wheel -1/0/1.
  pointer: (x, y, wheel, buttons) => {
    const b = new Uint8Array(8), v = new DataView(b.buffer);
    b[0] = C2S.POINTER_EVENT; b[1] = buttons; v.setUint16(2, Math.max(0, Math.floor(x))); v.setUint16(4, Math.max(0, Math.floor(y))); v.setUint16(6, wheel & 0xffff);
    return b;
  },
  // Relative pointer (HKC's "single mouse" mode): signed deltas wrap into u16, wheel -1/0/1.
  pointerRelative: (dx, dy, wheel, buttons) => {
    const b = new Uint8Array(8), v = new DataView(b.buffer);
    b[0] = C2S.POINTER_RELATIVE; b[1] = buttons; v.setUint16(2, Math.floor(dx) & 0xffff); v.setUint16(4, Math.floor(dy) & 0xffff); v.setUint16(6, wheel & 0xffff);
    return b;
  },
  // "Synchronize mouse": type 134, mode 1 (hard). HKC then re-sends the last pointer event.
  mouseSync: () => Uint8Array.of(C2S.MOUSE_SYNC, 1),
  // Session parameter, e.g. ('current_mouse_mode', 'absolute'): type 155, u8 keyLen, u8 valueLen, key, value.
  connectionParameter: (key, value) => { const k = te.encode(key), v = te.encode(value), b = new Uint8Array(3 + k.length + v.length); b[0] = C2S.SET_CONNECTION_PARAMETER; b[1] = k.length; b[2] = v.length; b.set(k, 3); b.set(v, 3 + k.length); return b; },
  ping: (n) => { const b = new Uint8Array(8); b[0] = C2S.PING_REQUEST; new DataView(b.buffer).setInt32(4, n); return b; },
  // 2 bytes, as captured from HKC. (A 5-byte version desyncs the KX's parser: it reads the extra bytes as a new message.)
  videoSettingsRequest: () => Uint8Array.of(C2S.VIDEO_SETTINGS_REQUEST, 1),
  videoRefresh: () => Uint8Array.of(C2S.VIDEO_REFRESH),
};

const hex = (buf) => [...new Uint8Array(buf)].map((x) => x.toString(16).padStart(2, '0')).join('');

/** The login proof: SHA-256 of the challenge's 64 hex characters followed by the web session id. */
export async function challengeProof(challenge, sessionId) {
  const text = latin1(challenge);
  if (!text.includes('{SHA256}')) throw new Error('KX asked for a non-SHA256 challenge (MD5 is not implemented)');
  return hex(await crypto.subtle.digest('SHA-256', te.encode(text.substring(1, 65) + sessionId)));
}

const PORT_SWITCH_COMPLETED = 0x1202000b;
const VERSION_RE = /^e-RIC RFB 01\.(\d\d)\n?$/;
const SUPPORTED_MINOR = new Set([29, 30, 31, 32, 33, 34]);

/**
 * One RFB connection. Drive it with feed(bytes) and run(); it emits via `on(event, data)`:
 *   status, version, params, ports, fbformat, frame, notification, ready, message, closed.
 */
export class RfbSession {
  constructor({ send, sessionId, portNo, portId, appId, quality = DEFAULT_QUALITY, on = () => {} }) {
    Object.assign(this, { send, sessionId, portNo, portId, appId, quality, on });
    this.stream = new ByteStream();
    this.inInit = true;
    this.ict = false; this.is4k = false; this.minor = 0; this.bitstreamVersion = 0;
    this.params = {}; this.ports = [];
    this.fb = { bitsPerPixel: 16, depth: 16, bigEndian: true, trueColor: true, redMax: 31, greenMax: 63, blueMax: 31, redShift: 11, greenShift: 5, blueShift: 0, frameBufferWidth: 0, frameBufferHeight: 0 };
    this.pingTimer = null; this.pings = 0;
  }

  start() { this.send(te.encode('e-RIC AUTH=')); return this.run(); }
  feed(data) { this.stream.push(data); }
  close(err) { this.closed = true; clearInterval(this.pingTimer); this.stream.fail(err ?? new Error('closed')); }

  async run() {
    try {
      for (;;) {
        const type = await this.stream.u8(), before = this.stream.consumed - 1;
        await this.#dispatch(type);
        this.on('trace', { type, bytes: this.stream.consumed - before });
      }
    } catch (err) {
      clearInterval(this.pingTimer);
      this.on('closed', err);
    }
  }

  requestUpdate(incremental) {
    if (this.fb.frameBufferWidth && this.fb.frameBufferHeight) this.send(write.fbUpdateRequest(incremental, this.fb.frameBufferWidth, this.fb.frameBufferHeight));
  }

  encoding() {
    if (this.ict && this.is4k) return ENCODING.ICT_4K_420 | (this.quality << 12);
    if (this.ict) return ENCODING.ICT | (this.quality << 12);
    const q = this.quality > 13 ? 1 : this.quality ? 13 - this.quality : 13;
    return ENCODING.LRLE_HARD | (q << 12);
  }

  async #dispatch(type) {
    const s = this.stream;
    switch (type) {
      case MSG.VERSION_INIT: {
        const version = `e${await s.str(15)}`;
        const m = VERSION_RE.exec(version);
        if (!m || !SUPPORTED_MINOR.has(Number(m[1]))) throw new Error(`Unsupported protocol version ${JSON.stringify(version)}`);
        this.minor = Number(m[1]);
        if (this.minor > 32) this.bitstreamVersion = 2;
        this.send(te.encode(version));
        return this.on('version', version.trim());
      }
      case MSG.AUTH_CAPS: {
        const caps = await s.u8();
        if (!(caps & AUTH_HTTP_SESSION_ID) || !this.sessionId) throw new Error(`KX does not offer session-id login (caps ${caps}) or no session id`);
        this.send(write.login(AUTH_HTTP_SESSION_ID));
        return this.on('status', 'authenticating');
      }
      case MSG.SESSION_CHALLENGE: {
        // HKC reads "whatever is buffered": the challenge arrives in one WebSocket message and its
        // length is not stated. Byte 0 is skipped by the hash; the next 64 characters are the nonce.
        await s.wait(1);
        this.send(write.challengeResponse(await challengeProof(s.takeAvailable(), this.sessionId)));
        return;
      }
      case MSG.AUTH_SUCCESSFUL: await s.read(7); return this.on('status', 'authenticated');
      case MSG.CONNECTION_PARAMETERS: {
        const n = await s.u8();
        for (let i = 0; i < n; i++) {
          const kl = await s.u8(), vl = await s.u8();
          const key = await s.str(kl), value = await s.str(vl);
          this.params[key] = value;
          if (key === 'ict_enc' && value !== 'no') { this.ict = true; this.is4k = value === '4k'; }
        }
        return this.on('params', this.params);
      }
      case MSG.PORT_LIST: return this.#ports(await this.#readPorts(this.minor > 31));
      case MSG.PORT_LIST_EXT: return this.#ports(await this.#readPorts(true));
      case MSG.UTF8_STRING: {
        await s.read(1);
        const text = await s.str(await s.u16());
        this.on('message', text);
        if (this.inInit) this.#clientInit();
        return;
      }
      case MSG.SERVER_INIT: await s.read(7); return;
      case MSG.SERVER_FB_FORMAT: {
        const v = await s.view(21);
        const f = this.fb;
        f.frameBufferWidth = v.getUint16(1); f.frameBufferHeight = v.getUint16(3);
        this.on('fbformat', { width: f.frameBufferWidth, height: f.frameBufferHeight });
        if (this.inInit) this.#serverInit(); else this.requestUpdate(false);
        return;
      }
      case MSG.ACK_PIXEL_FORMAT: await s.read(19); return;
      case MSG.FRAMEBUFFER_UPDATE: return this.#framebufferUpdate();
      case MSG.USER_NOTIFICATION: {
        const v = await s.view(7);
        const code = v.getUint32(3), flags = v.getInt8(0);
        if (code === PORT_SWITCH_COMPLETED) setTimeout(() => { if (!this.inInit && !this.closed) this.send(write.videoRefresh()); }, 500);
        return this.on('notification', { code, flags, quit: !!(flags & 1), severity: (code >> 24) & 15, text: NOTIFICATIONS[code] ?? `KX notification 0x${code.toString(16)}` });
      }
      case MSG.VIDEO_SETTINGS: await s.read(27); return;
      case MSG.OSD_STATE: { await s.read(1); await s.u16(); await s.read(await s.u16()); return; }
      case MSG.KEYBOARD_LAYOUT: { await s.read(1); await s.read(await s.s16()); return; }
      case MSG.SERVER_COMMAND: { await s.read(1); const kl = await s.u16(), vl = await s.u16(); const key = await s.str(kl), value = await s.str(vl); return this.on('command', { key, value }); }
      case MSG.SERVER_RC_MESSAGE: { await s.read(3); const n = await s.s32(); const text = await s.str(n); return this.on('message', text); }
      case MSG.PING_REPLY: await s.read(7); return;
      case MSG.VM_MOUNTS_RESPONSE: await s.read(7); return;
      case MSG.VM_SHARE_TABLE: {
        const n = await s.u8();
        for (let i = 0; i < n; i++) { const hl = (await s.read(1))[0], il = (await s.read(1))[0]; await s.read(hl + il); }
        return;
      }
      case MSG.VIRTUAL_MEDIA_CONFIG: await s.read(await s.u8()); return;
      case MSG.USB_PROFILE_LIST: {
        const n = await s.u16();
        for (let i = 0; i < n; i++) { const nl = await s.u8(), dl = await s.u16(); await s.read(3); await s.read(nl + dl); }
        return;
      }
      case MSG.TERMINAL_CONFIG: await s.read(3); return;
      case MSG.TERMINAL_INPUT: await s.read(4); return;
      default: throw new Error(`Unknown message type ${type} (protocol desync)`);
    }
  }

  async #readPorts(ext) {
    const s = this.stream;
    await s.read(1);
    const n = await s.u16(), ports = [];
    for (let i = 0; i < n; i++) {
      if (ext) {
        const kvm = await s.u8(), vm = await s.u8(), power = await s.u8();
        await s.read(1);
        const lens = [await s.u16(), await s.u16(), await s.u16(), await s.u16()];
        const [no, id, name, cim] = [await s.str(lens[0]), await s.str(lens[1]), await s.str(lens[2]), await s.str(lens[3])];
        ports.push({ portNo: Number(no), uniquePortId: id, portName: name, cimType: cim, kvm, vm, power });
      } else {
        const kvm = await s.u8(), vm = await s.u8(), portNo = await s.u16(), il = await s.u16(), nl = await s.u16();
        ports.push({ portNo, uniquePortId: await s.str(il), portName: await s.str(nl), kvm, vm });
      }
    }
    return ports;
  }

  #ports(ports) {
    this.ports = ports;
    if (!this.portId) {
      const p = ports.find((x) => x.portNo === Number(this.portNo));
      if (!p) throw new Error(`Port ${this.portNo} is not in the KX port list`);
      this.portId = p.uniquePortId;
    }
    this.on('ports', ports);
  }

  #clientInit() { // HKC's order: client init, associated tag, KVM switch
    this.send(write.clientInit(!!this.appId));
    if (this.appId) this.send(write.associatedTag(this.appId));
    this.send(write.kvmSwitch(this.portId));
  }

  #serverInit() {
    this.send(write.setEncodings(this.encoding()));
    this.send(write.setPixelFormat(this.fb));
    this.requestUpdate(false);
    this.inInit = false;
    this.send(write.videoSettingsRequest());
    this.pingTimer = setInterval(() => this.send(write.ping(this.pings++)), 20000);
    this.on('ready', { ict: this.ict, is4k: this.is4k, minor: this.minor, params: this.params });
  }

  async #framebufferUpdate() {
    const s = this.stream;
    const head = await s.view(7);
    const flags = head.getInt8(0), rects = head.getUint16(1);
    if (flags & 1) await s.read(8);
    if (this.ict) {
      // One chunk per update: [1 pad][u24 length incl. 12-byte rect header][x y w h u16][encoding i32][data]
      await s.read(1);
      const l = await s.read(3);
      const total = (l[0] << 16) | (l[1] << 8) | l[2];
      const h = await s.view(12);
      const data = await s.read(total - 12);
      return this.on('frame', { x: h.getUint16(0), y: h.getUint16(2), w: h.getUint16(4), h: h.getUint16(6), encoding: h.getInt32(8), data });
    }
    for (let i = 0; i < rects; i++) {
      const h = await s.view(16);
      const len = h.getUint32(12);
      const data = await s.read(len);
      if (len % 4 === 0) await s.read(4); // sic: HKC skips 4 pad bytes exactly when the length is a multiple of 4
      this.on('frame', { x: h.getUint16(0), y: h.getUint16(2), w: h.getUint16(4), h: h.getUint16(6), encoding: h.getInt32(8), data });
    }
  }
}
