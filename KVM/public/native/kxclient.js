// Native console client for the Raritan Dominion KX III: opens wss://<this origin>/rfb (the dashboard's server
// proxies it to the KX and attaches the KX session), speaks the e-RIC RFB protocol (rfbproto.js), decodes video
// with the KX's own decoder worker and draws it on a <canvas>, and forwards keyboard and mouse.
//
//   const kx = new KxClient({ canvas, portNo: 8, onstatus: console.log, onerror: console.error });
//   await kx.connect();   ...   kx.disconnect();

import { RfbSession, write, keyFromCode, MOUSE, DEFAULT_QUALITY } from './rfbproto.js';
import { renderYCbCr } from './ycbcr.js';

const WORKER_URL = '/js/js_decoding_worker.min.js'; // served by the KX through the proxy

const cookie = (name) => document.cookie.match(new RegExp(`(?:^|; )${name}=([^;]+)`))?.[1];

export class KxClient {
  /**
   * @param {object} o
   * @param {HTMLCanvasElement} o.canvas
   * @param {number} [o.portNo]     KX port number as shown in the KX UI (1-based, as in the port list)
   * @param {string} [o.portId]     or the KX's unique port id (P_<device>_<n>); resolved from the port list if omitted
   * @param {string} [o.sessionId]  KX web session id; defaults to the kvm_session_id cookie (set by /api/session)
   * @param {number} [o.quality]    ICT quality (default 13, what HKC sends on this KX)
   * @param {boolean} [o.input]     attach keyboard/mouse handlers to the canvas (default true)
   */
  constructor({ canvas, portNo, portId, sessionId, appId, quality = DEFAULT_QUALITY, input = true, onstatus = () => {}, onerror = () => {}, onresolution = () => {}, onstats = () => {} }) {
    Object.assign(this, { canvas, portNo, portId, sessionId, quality, input, onstatus, onerror, onresolution, onstats });
    this.appId = appId ?? `${Date.now()}_${Math.floor(Math.random() * 1e15)}`;
    this.ctx = canvas.getContext('2d');
    this.image = null; this.session = null; this.ws = null; this.worker = null;
    this.keysDown = new Set(); this.buttons = 0; this.frames = 0; this.bytes = 0;
    this.listeners = [];
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
    this.ws.onclose = (e) => { this.session.close(new Error(`socket closed (${e.code})`)); };
    this.ws.onerror = () => this.onerror(new Error('WebSocket error'));
    await new Promise((resolve, reject) => { this.ws.onopen = resolve; this.ws.addEventListener('error', () => reject(new Error('Could not open /rfb')), { once: true }); });
    this.session.start();
    this.statsTimer = setInterval(() => { this.onstats({ fps: this.frames, kbps: Math.round(this.bytes * 8 / 1000) }); this.frames = 0; this.bytes = 0; }, 1000);
    if (this.input) this.#attachInput();
  }

  disconnect() {
    clearInterval(this.statsTimer);
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
    const fb = this.session.fb;
    this.worker.postMessage({
      command: 'decode', isWebGL: false, data: rect.data.buffer, bitstreamVersion: this.session.bitstreamVersion,
      frameBufferWidth: fb.frameBufferWidth, frameBufferHeight: fb.frameBufferHeight,
      updateRectEncoding: rect.encoding, updateRectX: rect.x, updateRectY: rect.y, updateRectW: rect.w, updateRectH: rect.h,
    }, [rect.data.buffer]);
  }

  #onDecoded(u) {
    if (!this.session || !this.image) return;
    this.session.requestUpdate(true); // ask for the next change straight away, as HKC does
    renderYCbCr(this.image.data, this.image.width, u);
    this.ctx.putImageData(this.image, 0, 0, u.x, u.y, u.w, u.h);
    this.frames++;
  }

  // --- input -------------------------------------------------------------------------------------

  #on(target, type, fn, opts) { target.addEventListener(type, fn, opts); this.listeners.push(() => target.removeEventListener(type, fn, opts)); }

  #attachInput() {
    const c = this.canvas;
    c.tabIndex = 0;
    this.#on(c, 'keydown', (e) => { if (this.sendKey(e.code, true)) e.preventDefault(); });
    this.#on(c, 'keyup', (e) => { if (this.sendKey(e.code, false)) e.preventDefault(); });
    this.#on(c, 'blur', () => this.#releaseAll());
    this.#on(c, 'contextmenu', (e) => e.preventDefault());
    this.#on(c, 'mousemove', (e) => this.#pointer(e, 0));
    this.#on(c, 'mousedown', (e) => { c.focus(); this.buttons |= [MOUSE.LEFT, MOUSE.MIDDLE, MOUSE.RIGHT][e.button] ?? 0; this.#pointer(e, 0); e.preventDefault(); });
    this.#on(c, 'mouseup', (e) => { this.buttons &= ~([MOUSE.LEFT, MOUSE.MIDDLE, MOUSE.RIGHT][e.button] ?? 0); this.#pointer(e, 0); });
    this.#on(c, 'wheel', (e) => { this.#pointer(e, Math.sign(e.deltaY)); e.preventDefault(); }, { passive: false });
  }

  #detachInput() { for (const off of this.listeners) off(); this.listeners = []; }

  #pointer(e, wheel) {
    if (!this.session || this.session.inInit) return;
    const r = this.canvas.getBoundingClientRect();
    const x = (e.clientX - r.left) * this.canvas.width / r.width;
    const y = (e.clientY - r.top) * this.canvas.height / r.height;
    this.session.send(write.pointer(x, y, wheel, this.buttons));
  }

  #releaseAll() {
    for (const code of [...this.keysDown]) this.sendKey(code, false);
    if (this.buttons) { this.buttons = 0; }
  }
}
