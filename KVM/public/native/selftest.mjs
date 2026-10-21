// Offline self-test (no KX needed):  node public/native/selftest.mjs
// Plays a scripted server (built from PROTOCOL.md) into RfbSession with hostile chunking, checks every byte the
// client answers with, and checks the YCbCr renderer. It proves the code matches the written protocol, not that
// the protocol description matches a real KX (that needs probe.mjs against the switch).

import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { RfbSession, ByteStream, write, keyFromCode, KEY } from './rfbproto.js';
import { renderYCbCr, layoutFor } from './ycbcr.js';
import { KeyboardTranslator } from './keyboard.js';
import { pointerPosition } from './kxclient.js';

const enc = new TextEncoder();
const cat = (...parts) => { const u = new Uint8Array(parts.reduce((n, p) => n + p.length, 0)); let o = 0; for (const p of parts) { u.set(p, o); o += p.length; } return u; };
const u16 = (n) => Uint8Array.of(n >> 8, n & 255);
const u32 = (n) => Uint8Array.of(n >>> 24, (n >> 16) & 255, (n >> 8) & 255, n & 255);
const str = (s) => enc.encode(s);
const z = (n) => new Uint8Array(n);
let passed = 0;
const test = async (name, fn) => { await fn(); passed++; console.log(`ok  ${name}`); };

await test('ByteStream joins arbitrary chunks and reports buffered bytes', async () => {
  const s = new ByteStream();
  const p = s.read(5);
  s.push(Uint8Array.of(1)); s.push(Uint8Array.of(2, 3)); s.push(Uint8Array.of(4, 5, 6));
  assert.deepEqual([...await p], [1, 2, 3, 4, 5]);
  assert.equal(s.length, 1);
  assert.deepEqual([...s.takeAvailable()], [6]);
});

await test('key mapping: KeyboardEvent.code -> KX key number', () => {
  assert.equal(keyFromCode('KeyA'), KEY.A);
  assert.equal(keyFromCode('Digit0'), KEY.DIGIT0);
  assert.equal(keyFromCode('Numpad7'), KEY.NUM7);
  assert.equal(keyFromCode('NumpadAdd'), KEY.NUMADD);
  assert.equal(keyFromCode('Equal'), KEY.EQUALS);
  assert.equal(keyFromCode('BracketLeft'), KEY.BRACKETOPEN);
  assert.equal(keyFromCode('ControlRight'), KEY.CONTROLRIGHT);
  assert.equal(keyFromCode('NotAKey'), undefined);
});

await test('full handshake against a scripted KX, fed in 1-byte and random chunks', async () => {
  for (const chunking of ['bytes', 'random', 'whole']) {
    const sent = [], events = [];
    const sessionId = 'abc123SESSION';
    const nonce = 'f'.repeat(32) + '0'.repeat(32);
    const challenge = cat(Uint8Array.of(0x40), str(nonce), str('{SHA256}'));
    const rectData = Uint8Array.from({ length: 40 }, (_, i) => i);

    const session = new RfbSession({ send: (b) => sent.push(Uint8Array.from(b)), sessionId, portNo: 7, appId: 'app1', on: (e, d) => events.push([e, d]) });
    session.start();
    assert.equal(new TextDecoder().decode(sent[0]), 'e-RIC AUTH=');

    // The challenge is the one message the real client relies on arriving by itself, so deliver it separately.
    const stage = async (bytes) => {
      if (chunking === 'bytes') for (const b of bytes) session.feed(Uint8Array.of(b));
      else if (chunking === 'random') for (let i = 0; i < bytes.length;) { const n = 1 + Math.floor(Math.random() * 7); session.feed(bytes.subarray(i, i + n)); i += n; }
      else session.feed(bytes);
      await new Promise((r) => setTimeout(r, 5));
    };

    await stage(cat(Uint8Array.of(101), str('-RIC RFB 01.31\n')));
    assert.equal(new TextDecoder().decode(sent[1]), 'e-RIC RFB 01.31\n');
    await stage(Uint8Array.of(32, 1));
    assert.deepEqual([...sent[2]], [32, 1, 1, 0, 0, 0, 0, 0, 0]);
    await stage(cat(Uint8Array.of(33), challenge));
    const proof = createHash('sha256').update(nonce + sessionId).digest('hex');
    assert.deepEqual([...sent[3]], [33, 65, ...str(proof), 0]);
    await stage(cat(Uint8Array.of(34), z(7)));
    await stage(cat(Uint8Array.of(18, 2, 7, 3), str('ict_enc'), str('yes'), Uint8Array.of(10, 2), str('devicename'), str('KX')));
    const id = 'P_000d5d11da6a_7', name = 'B25-CTL-OPC01';
    await stage(cat(Uint8Array.of(4, 0), u16(2), Uint8Array.of(2, 0), u16(3), u16(id.length), u16(name.length), str(id), str(name),
      Uint8Array.of(2, 0), u16(7), u16(id.length), u16(name.length), str(id), str(name)));
    assert.equal(session.portId, id, 'port id resolved from the port list by portNo');
    await stage(cat(Uint8Array.of(7, 0), u16(4), str('mofa')));
    // client init (flags 4|8), associated tag, KVM switch with the port id (HKC's order)
    assert.deepEqual([...sent[4]], [7, 0, 0, 12]);
    assert.deepEqual([...sent[5]], [8, 0, 0, 4, ...str('app1')]);
    assert.deepEqual([...sent[6]], [137, 0, 0, id.length, ...str(id)]);
    await stage(cat(Uint8Array.of(5), z(7)));
    // 128: supported=1, width 1920, height 1080, pixel format, 3 pad
    await stage(cat(Uint8Array.of(128, 1), u16(1920), u16(1080), Uint8Array.of(16, 16, 1, 1), u16(31), u16(63), u16(31), Uint8Array.of(11, 5, 0), z(3)));
    assert.deepEqual([...sent[7]], [2, 0, 0, 4, 0, 0, 0xd0, 0x81, ...z(12)], 'ICT quality 13, as HKC sends (0xd081)');
    assert.deepEqual([...sent[8]], [0, 0, 0, 0, 16, 16, 1, 1, 0, 31, 0, 63, 0, 31, 11, 5, 0, 0, 0, 0]);
    assert.deepEqual([...sent[9]], [3, 0, 0, 0, 0, 0, 7, 128, 4, 56]);
    assert.deepEqual([...sent[10]], [145, 1], 'video settings request is 2 bytes (5 bytes desyncs the KX)');
    assert.ok(events.some(([e, d]) => e === 'ready' && d.ict && !d.is4k));
    // one ICT chunk: flags 2, 1 rect, size; [pad][u24 total][x y w h enc][data]
    const total = 12 + rectData.length;
    await stage(cat(Uint8Array.of(0, 2), u16(1), u32(4 + total), Uint8Array.of(0), Uint8Array.of(0, total >> 8, total & 255),
      u16(16), u16(32), u16(64), u16(48), u32(0x9081), rectData));
    const frame = events.find(([e]) => e === 'frame')[1];
    assert.deepEqual([frame.x, frame.y, frame.w, frame.h, frame.encoding], [16, 32, 64, 48, 0x9081]);
    assert.deepEqual([...frame.data], [...rectData]);
    // notification: quit flag + all links busy
    await stage(cat(Uint8Array.of(3, 1, 0, 0), u32(0x10020005)));
    const note = events.find(([e]) => e === 'notification')[1];
    assert.equal(note.quit, true); assert.equal(note.severity, 0); assert.match(note.text, /Maximum number of KVM connections/);
    // a few messages the client must consume without desync
    await stage(cat(Uint8Array.of(8, 0), z(26)));                      // video settings: 27 bytes
    await stage(cat(Uint8Array.of(132, 0), u16(3), u16(2), str('abc'), str('de'))); // server command
    await stage(cat(Uint8Array.of(170), u16(1), Uint8Array.of(2), u16(3), Uint8Array.of(0), u16(9), str('ab'), str('xyz'))); // usb profiles
    const before = sent.length;
    await stage(cat(Uint8Array.of(3, 0, 0, 0), u32(0x1202000b)));
    assert.equal(events.filter(([e]) => e === 'notification').length, 2, 'stream still in sync after skipped messages');
    assert.equal(sent.length, before, 'no refresh before the 500 ms delay');
    await new Promise((r) => setTimeout(r, 600));
    assert.deepEqual([...sent[before]], [146], 'video refresh 500 ms after "port switch completed", as HKC does');
    session.close();
    await new Promise((r) => setTimeout(r, 5));
  }
});

await test('unsupported protocol versions and unknown messages fail loudly', async () => {
  for (const feed of [(s) => s.feed(cat(Uint8Array.of(101), str('-RIC RFB 01.99\n'))), (s) => s.feed(Uint8Array.of(250))]) {
    let closed;
    const s = new RfbSession({ send() {}, sessionId: 'x', portNo: 0, on: (e, d) => { if (e === 'closed') closed = d; } });
    s.start(); feed(s);
    await new Promise((r) => setTimeout(r, 5));
    assert.ok(closed instanceof Error, 'expected an error');
  }
});

await test('client frames equal the bytes captured from HKC (hkc-capture.html, 2026-10-20)', () => {
  const hex = (u8) => [...u8].map((b) => b.toString(16).padStart(2, '0')).join(' ');
  assert.equal(hex(write.login(1)), '20 01 01 00 00 00 00 00 00');
  assert.equal(hex(write.clientInit(true)), '07 00 00 0c');
  assert.equal(hex(write.kvmSwitch('P_000d5d11da6a_8')), '89 00 00 10 50 5f 30 30 30 64 35 64 31 31 64 61 36 61 5f 38');
  assert.equal(hex(write.setEncodings(0xd081)), '02 00 00 04 00 00 d0 81 00 00 00 00 00 00 00 00 00 00 00 00');
  assert.equal(hex(write.setPixelFormat({ bitsPerPixel: 16, depth: 16, bigEndian: true, trueColor: true, redMax: 31, greenMax: 63, blueMax: 31, redShift: 11, greenShift: 5, blueShift: 0 })),
    '00 00 00 00 10 10 01 01 00 1f 00 3f 00 1f 0b 05 00 00 00 00');
  assert.equal(hex(write.fbUpdateRequest(false, 1920, 1080)), '03 00 00 00 00 00 07 80 04 38');
  assert.equal(hex(write.fbUpdateRequest(true, 1920, 1080)), '03 01 00 00 00 00 07 80 04 38');
  assert.equal(hex(write.videoSettingsRequest()), '91 01');
  assert.equal(hex(write.videoRefresh()), '92');
  assert.equal(hex(write.ping(0)), '94 00 00 00 00 00 00 00');
  assert.equal(hex(write.ping(2)), '94 00 00 00 00 00 00 02');
});


// --- keyboard ---------------------------------------------------------------------------------------------

const fakeClock = () => {
  let now = 0, id = 0; const timers = new Map();
  return {
    setTimeout: (fn, ms) => { timers.set(++id, { at: now + ms, fn }); return id; },
    clearTimeout: (t) => timers.delete(t),
    advance(ms) { now += ms; for (const [t, x] of [...timers]) if (x.at <= now) { timers.delete(t); x.fn(); } },
  };
};
const keyboard = (opts = {}) => {
  const clock = fakeClock(), out = [];
  const kb = new KeyboardTranslator({ send: (k, d) => out.push(`${k}${d ? '↓' : '↑'}`), setTimeout: clock.setTimeout, clearTimeout: clock.clearTimeout, ...opts });
  const ev = (type, code, mods = []) => ({ type, code, getModifierState: (m) => mods.includes(m) });
  return { kb, out, clock, ev };
};

await test('keyboard: press and release, auto-repeat is ignored, unknown keys are not ours', () => {
  const { kb, out, ev } = keyboard();
  assert.equal(kb.handle(ev('keydown', 'ShiftLeft', ['Shift'])), true);
  assert.equal(kb.handle(ev('keydown', 'ShiftLeft', ['Shift'])), true); // repeat: handled but not re-sent
  assert.equal(kb.handle(ev('keydown', 'ShiftLeft', ['Shift'])), true);
  assert.deepEqual(out, [`${KEY.SHIFTLEFT}↓`]);
  assert.equal(kb.handle(ev('keyup', 'ShiftLeft')), true);
  assert.deepEqual(out, [`${KEY.SHIFTLEFT}↓`, `${KEY.SHIFTLEFT}↑`]);
  assert.equal(kb.handle(ev('keydown', 'MediaPlayPause')), false);
  assert.equal(kb.handle(ev('keydown', '')), false);
});

await test('keyboard: a lost modifier keyup is repaired on the next key press', () => {
  const { kb, out, ev } = keyboard();
  kb.handle(ev('keydown', 'ShiftLeft', ['Shift']));
  out.length = 0;
  kb.handle(ev('keydown', 'KeyA', [])); // browser says Shift is up, but we still hold it
  assert.deepEqual(out, [`${KEY.SHIFTLEFT}↑`, `${KEY.A}↓`]);
});

await test('keyboard: releaseAll lets go of everything held (blur) in press order, and is idempotent', () => {
  const { kb, out, ev } = keyboard();
  for (const c of ['ShiftLeft', 'AltLeft', 'F12']) kb.handle(ev('keydown', c, ['Shift', 'Alt']));
  out.length = 0;
  kb.releaseAll();
  assert.deepEqual(out, [`${KEY.SHIFTLEFT}↑`, `${KEY.ALTLEFT}↑`, `${KEY.F12}↑`]);
  assert.deepEqual(kb.held(), []);
  out.length = 0; kb.releaseAll();
  assert.deepEqual(out, []);
});

await test('keyboard: Alt+F12 is sent to the target as two plain keys (no local hotkey intercepts it)', () => {
  const { kb, out, ev } = keyboard();
  assert.equal(kb.handle(ev('keydown', 'AltLeft', ['Alt'])), true);
  assert.equal(kb.handle(ev('keydown', 'F12', ['Alt'])), true); // true = caller preventDefault()s, so devtools etc. do not see it
  assert.deepEqual(out, [`${KEY.ALTLEFT}↓`, `${KEY.F12}↓`]);
});

await test('keyboard: Ctrl is held back 30 ms; AltGr (Ctrl+AltRight) swallows it; a plain Ctrl still arrives', () => {
  { // plain Ctrl, held longer than the window
    const { kb, out, clock, ev } = keyboard();
    kb.handle(ev('keydown', 'ControlLeft', ['Control']));
    assert.deepEqual(out, []);
    clock.advance(30);
    assert.deepEqual(out, [`${KEY.CONTROLLEFT}↓`]);
    kb.handle(ev('keyup', 'ControlLeft'));
    assert.deepEqual(out, [`${KEY.CONTROLLEFT}↓`, `${KEY.CONTROLLEFT}↑`]);
  }
  { // AltGr chord as Windows browsers deliver it
    const { kb, out, clock, ev } = keyboard();
    kb.handle(ev('keydown', 'ControlLeft', ['Control', 'Alt', 'AltGraph']));
    kb.handle(ev('keydown', 'AltRight', ['Control', 'Alt', 'AltGraph']));
    clock.advance(100);
    assert.deepEqual(out, [`${KEY.ALTRIGHT}↓`], 'only AltRight reaches the target');
    kb.handle(ev('keyup', 'ControlLeft', ['AltGraph']));
    assert.deepEqual(out, [`${KEY.ALTRIGHT}↓`, `${KEY.ALTRIGHT}↑`], 'releasing the companion Ctrl releases AltGr');
    kb.handle(ev('keyup', 'AltRight'));
    assert.equal(out.length, 2, 'the later AltRight keyup is a no-op');
  }
  { // a Ctrl tap shorter than the window is delivered as press + release, never left pending
    const { kb, out, clock, ev } = keyboard();
    kb.handle(ev('keydown', 'ControlLeft', ['Control']));
    kb.handle(ev('keyup', 'ControlLeft'));
    clock.advance(100);
    assert.deepEqual(out, [`${KEY.CONTROLLEFT}↓`, `${KEY.CONTROLLEFT}↑`]);
    assert.deepEqual(kb.held(), []);
  }
});

await test('keyboard: macOS CapsLock is press+release per event; keys typed under Cmd are released at once', () => {
  const { kb, out, ev } = keyboard({ isMac: true });
  kb.handle(ev('keydown', 'CapsLock', []));
  assert.deepEqual(out, [`${KEY.CAPSLOCK}↓`, `${KEY.CAPSLOCK}↑`]);
  out.length = 0;
  kb.handle(ev('keyup', 'CapsLock', []));
  assert.deepEqual(out, [`${KEY.CAPSLOCK}↓`, `${KEY.CAPSLOCK}↑`]);
  out.length = 0;
  kb.handle(ev('keydown', 'MetaLeft', ['Meta']));
  kb.handle(ev('keydown', 'KeyC', ['Meta']));
  assert.deepEqual(out, [`${KEY.METALEFT}↓`, `${KEY.C}↓`, `${KEY.C}↑`]);
  assert.deepEqual(kb.held(), [KEY.METALEFT]);
});

await test('keyboard: Safari on macOS swaps Backquote and IntlBackslash, other browsers do not', () => {
  const safari = keyboard({ isMac: true, safariMac: true });
  safari.kb.handle(safari.ev('keydown', 'Backquote', []));
  assert.deepEqual(safari.out, [`${KEY.INTLBACKSLASH}↓`]);
  const other = keyboard();
  other.kb.handle(other.ev('keydown', 'Backquote', []));
  assert.deepEqual(other.out, [`${KEY.BACKQUOTE}↓`]);
});

await test('mouse: canvas position is right at any CSS size (corners, centre, off-edge clamp)', () => {
  const W = 1920, H = 1080;
  for (const [cssW, cssH] of [[1920, 1080], [872, 490.5], [640, 360], [2560, 1440], [960, 1080]]) {
    const rect = { left: 17, top: 107, width: cssW, height: cssH };
    const at = (fx, fy) => pointerPosition({ clientX: rect.left + fx * cssW, clientY: rect.top + fy * cssH }, rect, W, H);
    assert.deepEqual(at(0, 0), { x: 0, y: 0 });
    assert.deepEqual(at(0.5, 0.5), { x: 960, y: 540 });
    assert.deepEqual(at(0.999999, 0.999999), { x: 1919, y: 1079 });
    assert.deepEqual(at(1, 1), { x: 1919, y: 1079 }, 'right/bottom edge clamps into the framebuffer');
    assert.deepEqual(pointerPosition({ clientX: rect.left - 50, clientY: rect.top - 50 }, rect, W, H), { x: 0, y: 0 });
  }
});

await test('mouse frames: absolute, relative (negative deltas wrap), sync, mode parameter', () => {
  const hex = (u8) => [...u8].map((b) => b.toString(16).padStart(2, '0')).join(' ');
  assert.equal(hex(write.pointer(1000, 800, 0, 0)), '05 00 03 e8 03 20 00 00');
  assert.equal(hex(write.pointer(1000, 800, -1, 1)), '05 01 03 e8 03 20 ff ff');
  assert.equal(hex(write.pointerRelative(-3, 5, 0, 0)), '93 00 ff fd 00 05 00 00');
  assert.equal(hex(write.mouseSync()), '86 01');
  assert.equal(hex(write.connectionParameter('current_mouse_mode', 'absolute')), '9b 12 08 ' + [...'current_mouse_mode'].map((c) => c.charCodeAt(0).toString(16)).join(' ') + ' ' + [...'absolute'].map((c) => c.charCodeAt(0).toString(16)).join(' '));
});

await test('input frames match what HKC sends', () => {
  assert.deepEqual([...write.key(KEY.A, true)], [4, 0, 0x80, 29]);
  assert.deepEqual([...write.key(KEY.A, false)], [4, 0, 0x00, 29]);
  assert.deepEqual([...write.pointer(100.9, 50, -1, 5)], [5, 5, 0, 100, 0, 50, 255, 255]);
});

await test('YCbCr renderer: grey, colour, tile skipping, and all three chroma layouts', () => {
  assert.equal(layoutFor(2, 2), '444'); assert.equal(layoutFor(1, 2), '422'); assert.equal(layoutFor(2, 1), '422'); assert.equal(layoutFor(1, 1), '420');
  const W = 32, H = 16;
  const run = (layout, y, cb, cr, skip) => {
    const rgba = new Uint8ClampedArray(W * H * 4);
    const cw = layout === '444' ? W : W / 2, ch = layout === '420' ? H / 2 : H;
    renderYCbCr(rgba, W, {
      x: 0, y: 0, w: W, h: H, sourceWidth: W,
      pY: new Uint8Array(W * H).fill(y).buffer, pYoff: 0, pCb: new Uint8Array(cw * ch).fill(cb).buffer, pCboff: 0, pCr: new Uint8Array(cw * ch).fill(cr).buffer, pCroff: 0,
      skipTiles: Int8Array.from(skip ?? [0, 0]).buffer, samplersRow: layout === '444' ? 2 : layout === '422' ? 1 : 1, samplersCol: layout === '444' ? 2 : layout === '422' ? 2 : 1,
    });
    return rgba;
  };
  for (const layout of ['444', '422', '420']) {
    const grey = run(layout, 128, 128, 128);
    assert.deepEqual([...grey.subarray(0, 4)], [128, 128, 128, 255], `${layout} grey`);
    assert.deepEqual([...grey.subarray((W * 8 + 20) * 4, (W * 8 + 20) * 4 + 4)], [128, 128, 128, 255], `${layout} grey, second tile`);
    const red = run(layout, 76, 85, 255); // BT.601 red
    assert.ok(red[0] > 200 && red[1] < 60 && red[2] < 60, `${layout} red: ${[...red.subarray(0, 3)]}`);
    const skipped = run(layout, 128, 128, 128, [1, 0]);
    assert.deepEqual([...skipped.subarray(0, 4)], [0, 0, 0, 0], `${layout} skipped tile left untouched`);
    assert.equal(skipped[(20) * 4 + 3], 255, `${layout} drawn tile`);
  }
});

console.log(`\n${passed} tests passed`);
