// Browser keyboard events -> KX key events, following what Raritan's HKC does (KeyHandler in js_kvm_client):
//
//  * physical keys: KeyboardEvent.code -> the KX's key number (HKC's EN table; layout is the target's business)
//  * no auto-repeat: a key already held is ignored (the target's own repeat takes over)
//  * stuck-modifier repair: every new key press compares the browser's modifier state with what we hold
//  * AltGr: Windows browsers send ControlLeft then AltRight; ControlLeft is held back 30 ms so AltGr can swallow it
//  * macOS: CapsLock produces one event per toggle (press+release each time), and keys pressed while Cmd is
//    down never get a keyup, so they are released immediately
//  * Safari on macOS reports Backquote / IntlBackslash swapped
//  * releaseAll() on blur so no modifier stays down on the target
//
// DOM-free: feed it events shaped like KeyboardEvent ({ type, code, getModifierState }) and it calls
// `send(key, down)`. handle() returns true when the event was ours (the caller should preventDefault it).

import { KEY, keyFromCode } from './rfbproto.js';

const ALTGR_WINDOW_MS = 30;

export class KeyboardTranslator {
  constructor({ send, isMac = false, safariMac = false, setTimeout: st = globalThis.setTimeout, clearTimeout: ct = globalThis.clearTimeout } = {}) {
    Object.assign(this, { sendKey: send, isMac, safariMac, setTimeout: st, clearTimeout: ct });
    this.down = [];            // keys currently held on the target, in press order
    this.altGrDown = false;    // AltRight is the AltGr half of an AltGr chord
    this.ctrlDown = false;     // ControlLeft is genuinely held (not the AltGr companion)
    this.ctrlPending = false;  // ControlLeft is waiting 30 ms to see whether AltRight follows
    this.timer = null;
    this.queue = [];      // [key, released] pairs waiting to be sent, in order
  }

  /** @returns {boolean} true if the event maps to a KX key (preventDefault it) */
  handle(e) {
    const key = this.#keyFor(e.code);
    if (key === undefined) return false;
    if (e.type === 'keydown') this.#keydown(e, key);
    else if (e.type === 'keyup') this.#keyup(key);
    else return false;
    this.#flush();
    return true;
  }

  /** Release everything that is held (window blur, disconnect). */
  releaseAll() {
    clearTimeoutSafe(this);
    this.ctrlPending = false; this.ctrlDown = false; this.altGrDown = false;
    for (const key of this.down.splice(0)) this.queue.push([key, true]);
    this.#flush();
  }

  held() { return [...this.down]; }

  // --- internals -----------------------------------------------------------------------------

  #keyFor(code) {
    if (!code) return undefined;
    if (this.safariMac && code === 'Backquote') return KEY.INTLBACKSLASH;
    if (this.safariMac && code === 'IntlBackslash') return KEY.BACKQUOTE;
    return keyFromCode(code);
  }

  #keydown(e, key) {
    if (this.down.includes(key) || (key === KEY.CONTROLLEFT && this.ctrlPending)) return; // auto-repeat
    this.#syncModifiers(e);
    this.#press(key);
    if (this.isMac) this.#macQuirks(key);
  }

  #keyup(key) {
    if (this.isMac && key === KEY.CAPSLOCK) { this.#press(key); this.#release(key); return; } // one event per toggle
    if (key === KEY.CONTROLLEFT && this.ctrlPending) {
      // A Ctrl tap shorter than the AltGr window: deliver it as press + release.
      clearTimeoutSafe(this); this.ctrlPending = false;
      this.queue.push([key, false], [key, true]);
      return;
    }
    if (this.down.includes(key)) this.#release(key);
    else if (key === KEY.CONTROLLEFT && this.altGrDown && !this.ctrlDown) this.#releaseAltGr();
  }

  #press(key) {
    if (key === KEY.CONTROLLEFT && !this.timer) { // maybe the first half of AltGr: wait and see
      this.ctrlPending = true;
      this.timer = this.setTimeout(() => {
        this.timer = null;
        if (!this.ctrlPending) return;
        this.ctrlPending = false; this.ctrlDown = true;
        this.down.push(KEY.CONTROLLEFT); this.queue.push([KEY.CONTROLLEFT, false]);
        this.#flush();
      }, ALTGR_WINDOW_MS);
      return;
    }
    if (key === KEY.ALTRIGHT) {
      if (this.ctrlPending) { clearTimeoutSafe(this); this.ctrlPending = false; this.altGrDown = true; } // swallow the Ctrl
      else if (this.altGrDown) return;
    }
    this.down.push(key);
    this.queue.push([key, false]);
    if (this.isMac && key === KEY.CAPSLOCK) this.#release(key);
  }

  #release(key) {
    const i = this.down.indexOf(key);
    if (i < 0) return;
    if (key === KEY.CONTROLLEFT) this.ctrlDown = false;
    if (key === KEY.ALTRIGHT) this.altGrDown = false;
    this.down.splice(i, 1);
    this.queue.push([key, true]);
  }

  #releaseAltGr() {
    this.altGrDown = false;
    this.#release(KEY.ALTRIGHT);
  }

  // macOS delivers no keyup for keys pressed while Cmd is held: release them straight away.
  #macQuirks(key) {
    const i = this.down.indexOf(key);
    if (i > 0 && (this.down[i - 1] === KEY.METALEFT || this.down[i - 1] === KEY.METARIGHT) && key !== KEY.METALEFT && key !== KEY.METARIGHT) this.#release(key);
  }

  // If the browser says a modifier is up but we still hold it, the keyup was lost: let go.
  #syncModifiers(e) {
    const state = (name) => (e.getModifierState ? e.getModifierState(name) : true);
    if (!state('Shift')) { this.#release(KEY.SHIFTLEFT); this.#release(KEY.SHIFTRIGHT); }
    if (!state('Control')) { this.#release(KEY.CONTROLLEFT); this.#release(KEY.CONTROLRIGHT); }
    if (!state('Meta')) { this.#release(KEY.METALEFT); this.#release(KEY.METARIGHT); }
    if (!state('Alt')) {
      this.#release(KEY.ALTLEFT);
      if (!state('AltGraph')) this.#release(KEY.ALTRIGHT);
    }
  }

  #flush() {
    const q = this.queue; this.queue = [];
    for (const [key, released] of q) this.sendKey(key, !released);
  }
}

function clearTimeoutSafe(t) { if (t.timer) { t.clearTimeout(t.timer); t.timer = null; } }

/** Heuristics HKC uses, from the browser's own identification. */
export function detectPlatform(nav = globalThis.navigator) {
  const isMac = /Mac/i.test(nav?.platform ?? '');
  const safari = /Safari/i.test(nav?.userAgent ?? '') && !/Chrome|Chromium|Android|Edg|OPR/i.test(nav?.userAgent ?? '');
  return { isMac, safariMac: isMac && safari };
}
