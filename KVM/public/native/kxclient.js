// Native console client for the Raritan Dominion KX III: opens wss://<this origin>/rfb (the dashboard's server
// proxies it to the KX and attaches the KX session), speaks the e-RIC RFB protocol (rfbproto.js), decodes video
// with the KX's own decoder worker and draws it on a <canvas>, and forwards keyboard and mouse.
//
//   const kx = new KxClient({ canvas, portNo: 8, onstatus: console.log, onerror: console.error });
//   await kx.connect();   ...   kx.disconnect();

import { RfbSession, write, keyFromCode, MOUSE, DEFAULT_QUALITY } from './rfbproto.js';
import { renderYCbCr } from './ycbcr.js';
import { UpdatePacer, QualityGovernor, averageDelay } from './pacing.js';
import { KeyboardTranslator, detectPlatform } from './keyboard.js';

const WORKER_URL = '/js/js_decoding_worker.min.js'; // served by the KX through the proxy

/**
 * Pointer position in framebuffer pixels for a mouse event over a canvas drawn at any CSS size.
 * This is HKC's mapping ((clientX - rect.left) / scale, floored) with scale = rect.width / canvas.width.
 */
export function pointerPosition({ clientX, clientY }, rect, width, height) {
  const x = Math.floor((clientX - rect.left) * width / rect.width);
  const y = Math.floor((clientY - rect.top) * height / rect.height);
  return { x: Math.min(width - 1, Math.max(0, x)), y: Math.min(height - 1, Math.max(0, y)) };
}

const cookie = (name) => document.cookie.match(new RegExp(`(?:^|; )${name}=([^;]+)`))?.[1];

export class KxClient {
  /**
   * @param {object} o
   * @param {HTMLCanvasElement} o.canvas
   * @param {number} [o.portNo]     KX port number as shown in the KX UI (1-based, as in the port list)
   * @param {string} [o.portId]     or the KX's unique port id (P_<device>_<n>); resolved from the port list if omitted
   * @param {string} [o.sessionId]  KX web session id; defaults to the kvm_session_id cookie (set by /api/session)
   * @param {number|'auto'} [o.quality]  ICT quality 1-15 (default 13, what HKC sends on this KX), or 'auto': start at 13 and step down only when bandwidth-starved
   * @param {'fast'|'classic'} [o.pacing]  'fast' (default) asks for the next update as soon as one arrives; 'classic' waits for it to be decoded, like HKC
   * @param {number} [o.depth]      update requests kept in flight in 'fast' mode (default 2: measured 2-3x the frame rate of 'classic' over a ~130 ms VPN)
   * @param {boolean} [o.input]     attach keyboard/mouse handlers to the canvas (default true)
   */
  constructor({ canvas, portNo, portId, sessionId, appId, quality = DEFAULT_QUALITY, pacing = 'fast', depth = 2, input = true, onstatus = () => {}, onerror = () => {}, onresolution = () => {}, onstats = () => {}, onmouse = () => {} }) {
    Object.assign(this, { canvas, portNo, portId, sessionId, quality, input, onstatus, onerror, onresolution, onstats, onmouse, pacing, depth });
    this.auto = quality === 'auto';
    if (this.auto) this.quality = DEFAULT_QUALITY;
    this.delays = []; this.lastRequestAt = 0; this.lastFrameAt = 0;
    this.appId = appId ?? `${Date.now()}_${Math.floor(Math.random() * 1e15)}`;
    this.ctx = canvas.getContext('2d');
    this.image = null; this.session = null; this.ws = null; this.worker = null;
    this.keysDown = new Set(); this.buttons = 0; this.frames = 0; this.bytes = 0;
    this.listeners = [];
    // What the KX says about mouse modes (support_mouse_* / current_mouse_mode) and whether we are in relative mode.
    this.mouse = { current: null, supported: {}, relative: false };
    this.lastPointer = null; this.keyboard = null;
  }

  async connect() {
    if (this.ws) throw new Error('Already connected');
    this.onstatus('connecting');
    this.sessionId ??= await this.#sessionId();
    this.worker = await this.#startWorker();
    this.ws = new WebSocket(`${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/rfb`);
    this.ws.binaryType = 'arraybuffer';
    this.session = new RfbSession({
      send: (bytes) => this.ws?.readyState === 1 && this.ws.send(bytes),
      sessionId: this.sessionId, portNo: this.portNo, portId: this.portId, appId: this.appId, quality: this.quality,
      on: (event, data) => this.#onSession(event, data),
    });
    this.ws.onmessage = (e) => { this.bytes += e.data.byteLength; this.session.feed(e.data); };
    this.ws.onclose = (e) => { this.session?.close(new Error(`socket closed (${e.code})`)); }; // disconnect() may have cleared it already
    this.ws.onerror = () => this.onerror(new Error('WebSocket error'));
    await new Promise((resolve, reject) => { this.ws.onopen = resolve; this.ws.addEventListener('error', () => reject(new Error('Could not open /rfb')), { once: true }); });
    this.#resetPacer();
    this.governor = new QualityGovernor({ start: this.quality });
    this.session.start();
    this.statsTimer = setInterval(() => {
      // Watchdog: if nothing was asked or received for 5 s, our idea of what is outstanding may be wrong (a lost request, a stuck
      // decode). Start over with a fresh request; an idle screen simply makes the KX hold it, which costs nothing.
      if (this.session && !this.session.inInit && performance.now() - Math.max(this.lastFrameAt, this.lastRequestAt) > 5000) { this.#resetPacer(); this.#request(); }
      const s = { fps: this.frames, kbps: Math.round(this.bytes * 8 / 1000), delay: averageDelay(this.delays) };
      this.frames = 0; this.bytes = 0; this.delays = [];
      if (this.auto) { const q = this.governor.update(s); if (q !== null) this.#applyQuality(q); }
      this.onstats({ ...s, quality: this.quality, auto: this.auto });
    }, 1000);
    if (this.input) this.#attachInput();
  }

  disconnect() {
    clearInterval(this.statsTimer);
    this.#releaseAll(); // never leave a modifier or button held on the target
    this.#detachInput();
    this.session?.close(new Error('disconnected'));
    if (this.ws && this.ws.readyState < 2) this.ws.close(1000);
    this.worker?.terminate();
    this.ws = this.worker = this.session = null;
    this.onstatus('closed');
  }

  sendKey(code, down) {
    const key = keyFromCode(code);
    if (key === undefined || !this.session || this.session.inInit) return false;
    this.session.send(write.key(key, down));
    down ? this.keysDown.add(code) : this.keysDown.delete(code);
    return true;
  }

  async sendCtrlAltDel() {
    for (const c of ['ControlLeft', 'AltLeft', 'Delete']) this.sendKey(c, true);
    for (const c of ['Delete', 'AltLeft', 'ControlLeft']) this.sendKey(c, false);
  }

  refreshVideo() { this.session?.send(write.videoRefresh()); }

  /** 'fast' asks for the next update as soon as one arrives (depth = requests kept in flight); 'classic' waits for decoding, like HKC. */
  setPacing(mode, depth = this.depth) {
    this.pacing = mode; this.depth = depth;
    this.#resetPacer();
    if (this.session && !this.session.inInit) this.#request();
  }

  #resetPacer() {
    this.pacer = new UpdatePacer({ requests: this.depth, undecoded: 2 });
    this.pacer.markRequested(); // the caller sends one request right after
  }

  /** A number 1-15 sets the video quality; 'auto' lets the client lower it on a slow link and raise it again. */
  setQuality(q) {
    if (q === 'auto') { this.auto = true; this.#applyQuality(DEFAULT_QUALITY); this.governor?.reset(this.quality); return; } // Auto starts from High
    this.auto = false;
    this.#applyQuality(q);
    this.governor?.reset(this.quality);
  }

  #applyQuality(q) {
    this.quality = Math.max(1, Math.min(15, Math.round(q)));
    if (!this.session || this.session.inInit) return;
    this.session.quality = this.quality;
    this.session.send(write.setEncodings(this.session.encoding())); // HKC then asks for a full refresh at the new quality
    this.session.requestUpdate(false);
    this.pacer?.markRequested();
  }

  #request() { this.lastRequestAt = performance.now(); this.session?.requestUpdate(true); }

  /** HKC's "Synchronize mouse": a hard sync message, then the last pointer position again. */
  syncMouse() {
    if (!this.session || this.session.inInit) return;
    this.session.send(write.mouseSync());
    if (this.lastPointer) this.session.send(write.pointer(this.lastPointer.x, this.lastPointer.y, 0, this.buttons));
  }

  /**
   * 'absolute' | 'auto' | 'direct': ask the KX to use that mouse mode (same parameter HKC's Mouse menu writes).
   * 'relative': HKC's "single mouse" mode: lock the pointer to the canvas and send movement deltas.
   */
  setMouseMode(mode) {
    if (mode === 'relative') { this.canvas.requestPointerLock?.(); return; }
    document.exitPointerLock?.();
    if (this.session && !this.session.inInit) this.session.send(write.connectionParameter('current_mouse_mode', mode));
  }

  async #sessionId() {
    // /api/session makes the server check (and if needed renew) its KX login and sets kvm_session_id for us.
    const r = await fetch('/api/session');
    if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error ?? `/api/session ${r.status}`);
    // Same lookup order as HKC: kvm_session_id, then pp_session_id (the one a KX III web login actually sets).
    const id = cookie('kvm_session_id') ?? cookie('pp_session_id');
    if (!id) throw new Error('No KX session cookie (pp_session_id): is the dashboard server logged in to the KX?');
    return id;
  }

  #startWorker() {
    return new Promise((resolve, reject) => {
      const worker = new Worker(WORKER_URL);
      worker.onerror = () => reject(new Error(`Could not start ${WORKER_URL}`));
      worker.onmessage = (e) => {
        if (!e.data.init) return;
        worker.onmessage = (m) => this.#onDecoded(m.data);
        worker.onerror = (err) => this.onerror(new Error(`decoder worker: ${err.message}`));
        resolve(worker);
      };
    });
  }

  #onSession(event, data) {
    switch (event) {
      case 'status': this.onstatus(data); break;
      case 'fbformat': {
        const { width, height } = data;
        this.canvas.width = width; this.canvas.height = height;
        this.image = this.ctx.createImageData(width, height);
        this.onresolution(data);
        break;
      }
      case 'ready': this.onstatus('streaming'); break;
      case 'command': // the KX reports the target's signal state: video = no | unstable | stable
        if (data.key === 'video') { this.video = data.value; this.onstatus(data.value === 'no' ? 'no video signal' : `video ${data.value}`); }
        else if (data.key.startsWith('support_mouse_')) { this.mouse.supported[data.key.slice('support_mouse_'.length)] = data.value === 'yes'; this.#mouseChanged(); }
        else if (data.key === 'current_mouse_mode') { this.mouse.current = data.value; this.#mouseChanged(); }
        break;
      case 'frame': this.#decode(data); break;
      case 'notification':
        if (data.severity === 0 || data.quit) { this.onerror(Object.assign(new Error(data.text), { code: data.code })); }
        else this.onstatus(data.text);
        break;
      case 'closed': if (this.ws) { this.onerror(data); this.disconnect(); } break;
      default: break;
    }
  }

  #decode(rect) {
    const now = performance.now();
    // Time from our request to its update, counted only while updates are flowing (an idle screen makes it meaningless).
    if (this.lastRequestAt && now - this.lastFrameAt < 500) this.delays.push(now - this.lastRequestAt);
    this.lastFrameAt = now;
    if (this.pacing === 'fast') for (let n = this.pacer.onReceived(); n > 0; n--) this.#request();
    const fb = this.session.fb;
    this.worker.postMessage({
      command: 'decode', isWebGL: false, data: rect.data.buffer, bitstreamVersion: this.session.bitstreamVersion,
      frameBufferWidth: fb.frameBufferWidth, frameBufferHeight: fb.frameBufferHeight,
      updateRectEncoding: rect.encoding, updateRectX: rect.x, updateRectY: rect.y, updateRectW: rect.w, updateRectH: rect.h,
    }, [rect.data.buffer]);
  }

  #onDecoded(u) {
    if (!this.session || !this.image) return;
    if (this.pacing === 'fast') { for (let n = this.pacer.onDecoded(); n > 0; n--) this.#request(); } // held-back requests
    else this.#request(); // classic: only now, like HKC
    renderYCbCr(this.image.data, this.image.width, u);
    this.ctx.putImageData(this.image, 0, 0, u.x, u.y, u.w, u.h);
    this.frames++;
  }

  // --- input -------------------------------------------------------------------------------------

  #on(target, type, fn, opts) { target.addEventListener(type, fn, opts); this.listeners.push(() => target.removeEventListener(type, fn, opts)); }

  #attachInput() {
    const c = this.canvas;
    c.tabIndex = 0;
    const { isMac, safariMac } = detectPlatform();
    this.keyboard = new KeyboardTranslator({ send: (key, down) => this.#sendKeyNumber(key, down), isMac, safariMac });
    this.#on(c, 'keydown', (e) => { if (this.keyboard.handle(e)) e.preventDefault(); });
    this.#on(c, 'keyup', (e) => { if (this.keyboard.handle(e)) e.preventDefault(); });
    this.#on(c, 'blur', () => this.#releaseAll());
    this.#on(window, 'blur', () => this.#releaseAll());
    this.#on(c, 'contextmenu', (e) => e.preventDefault());
    this.#on(c, 'mousemove', (e) => this.#pointer(e, 0));
    this.#on(c, 'mousedown', (e) => { c.focus(); this.buttons |= [MOUSE.LEFT, MOUSE.MIDDLE, MOUSE.RIGHT][e.button] ?? 0; this.#pointer(e, 0); e.preventDefault(); });
    this.#on(c, 'mouseup', (e) => { this.buttons &= ~([MOUSE.LEFT, MOUSE.MIDDLE, MOUSE.RIGHT][e.button] ?? 0); this.#pointer(e, 0); });
    this.#on(c, 'wheel', (e) => { this.#pointer(e, Math.sign(e.deltaY)); e.preventDefault(); }, { passive: false });
    this.#on(document, 'pointerlockchange', () => { this.mouse.relative = document.pointerLockElement === c; this.#mouseChanged(); });
  }

  #detachInput() { for (const off of this.listeners) off(); this.listeners = []; }

  #sendKeyNumber(key, down) {
    if (!this.session || this.session.inInit) return;
    this.session.send(write.key(key, down));
  }

  // Absolute: canvas pixels, which is also what HKC sends (its scale factor is the CSS scale of the canvas).
  // Relative (pointer lock): movement deltas.
  #pointer(e, wheel) {
    if (!this.session || this.session.inInit) return;
    if (this.mouse.relative) {
      this.session.send(write.pointerRelative(e.movementX ?? 0, e.movementY ?? 0, wheel, this.buttons));
      return;
    }
    const { x, y } = pointerPosition(e, this.canvas.getBoundingClientRect(), this.canvas.width, this.canvas.height);
    this.lastPointer = { x, y };
    this.session.send(write.pointer(x, y, wheel, this.buttons));
  }

  // If the KX reports that it supports none of its absolute-style modes, fall back to relative (pointer lock) on demand.
  #mouseChanged() {
    const sup = this.mouse.supported;
    const known = ['absolute', 'auto', 'direct'].filter((m) => m in sup);
    this.mouse.needsRelative = known.length === 3 && known.every((m) => !sup[m]);
    this.onmouse({ ...this.mouse });
  }

  #releaseAll() {
    this.keyboard?.releaseAll();
    for (const code of [...this.keysDown]) this.sendKey(code, false);
    if (this.buttons && this.session && !this.session.inInit) {
      this.buttons = 0;
      if (this.lastPointer) this.session.send(write.pointer(this.lastPointer.x, this.lastPointer.y, 0, 0));
    }
    this.buttons = 0;
  }
}
