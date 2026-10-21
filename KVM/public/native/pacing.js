// Pure scheduling logic for the native client (no DOM, runs in Node for tests).
//
// Raritan's client asks for the next framebuffer update only after the previous one has been received AND decoded. Over
// a link with a 130 ms round trip that caps the frame rate at a few fps. UpdatePacer asks as soon as an update arrives
// (optionally keeping two requests in flight to hide a round trip), but never lets more than `undecoded` updates sit
// waiting for the decoder, so a slow decoder cannot build up a backlog (and lag).

export class UpdatePacer {
  /**
   * @param {{requests?: number, undecoded?: number}} o
   *   requests:  update requests kept in flight at the server (1 = ask as soon as one arrives; 2 = hide a round trip)
   *   undecoded: updates allowed to wait for the decoder before we stop asking
   */
  constructor({ requests = 1, undecoded = 2 } = {}) { Object.assign(this, { requests, undecoded }); this.outstanding = 0; this.inflight = 0; }

  /** A request was sent by someone else (the initial or a refresh request). */
  markRequested(n = 1) { this.outstanding += n; }

  /** An update arrived and is queued for decoding. Returns how many requests to send now. */
  onReceived() { this.outstanding = Math.max(0, this.outstanding - 1); this.inflight++; return this.#take(); }

  /** An update finished decoding. Returns how many held-back requests to send now. */
  onDecoded() { this.inflight = Math.max(0, this.inflight - 1); return this.#take(); }

  #take() {
    if (this.inflight >= this.undecoded) return 0;
    const n = Math.max(0, this.requests - this.outstanding);
    this.outstanding += n;
    return n;
  }
}

/**
 * Lowers the video quality only when the link is short of bandwidth: lots of data but few frames. Measured on this KX over a
 * VPN, quality barely changes the frame rate when the link is merely slow to answer (latency-bound), so a high delay alone
 * does NOT lower it: that would cost picture quality for nothing. Fed once a second; returns the new quality when it should
 * change, otherwise null. An idle screen says nothing about the link. Steps down after 3 starved seconds, up after 10 good
 * ones, within [min, max].
 */
export class QualityGovernor {
  constructor({ start = 13, min = 5, max = 13 } = {}) { Object.assign(this, { quality: start, min, max }); this.slow = 0; this.good = 0; }

  /** @param {{fps: number, kbps: number, delay: number|null}} s */
  update({ fps, kbps, delay }) {
    const busy = fps > 0 && delay !== null;
    const starved = busy && kbps > 6000 && fps < 5; // bandwidth-bound: heavy traffic, few frames
    const good = busy && kbps < 3000 && fps >= 8;
    this.slow = starved ? this.slow + 1 : 0;
    this.good = good ? this.good + 1 : 0;
    if (this.slow >= 3 && this.quality > this.min) { this.slow = 0; return (this.quality = Math.max(this.min, this.quality - 2)); }
    if (this.good >= 10 && this.quality < this.max) { this.good = 0; return (this.quality = Math.min(this.max, this.quality + 1)); }
    return null;
  }

  /** The user picked a quality by hand: follow it, and restart the evidence. */
  reset(quality) { this.quality = quality; this.slow = this.good = 0; }
}

/** Average of the delays measured while updates were flowing, or null when there were none. */
export const averageDelay = (delays) => (delays.length ? Math.round(delays.reduce((a, b) => a + b, 0) / delays.length) : null);
