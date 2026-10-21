// Turns the decoder worker's YCbCr planes into RGBA pixels.
//
// The KX's decoder (Raritan's /js/js_decoding_worker.min.js, WASM or JS) outputs, per update rectangle, a
// luma plane plus two chroma planes and a per-16x16-tile "skip" map, and the HKC viewer converts them on
// the main thread. This is a straight CPU port of that conversion (same integer tables and the same
// luma-correction step) so that no Raritan UI code needs to load.

const TILE = 16;

const clamp = new Int16Array(768);
for (let i = 256; i < 512; i++) clamp[i] = i - 256;
for (let i = 512; i < 768; i++) clamp[i] = 255;

const gCb = new Int16Array(256), gCr = new Int16Array(256);
const rTab = new Int16Array(65536), bTab = new Int16Array(65536); // indexed (Y << 8) | chroma
for (let i = 0; i < 256; i++) {
  gCb[i] = (352 * (i - 128) + 512) >> 10;
  gCr[i] = (731 * (i - 128) + 512) >> 10;
}
for (let y = 0; y < 256; y++) {
  for (let c = 0; c < 256; c++) {
    rTab[(y << 8) | c] = clamp[y + ((1435 * (c - 128) + 512) >> 10) + 256];
    bTab[(y << 8) | c] = clamp[y + ((1814 * (c - 128) + 512) >> 10) + 256];
  }
}

/** Chroma layout from the decoder's sampling factors, exactly as HKC picks it. */
export function layoutFor(samplersRow, samplersCol) {
  if (samplersRow === 2 && samplersCol === 2) return '444';
  if ((samplersRow < 2 && samplersCol === 2) || (samplersRow === 2 && samplersCol < 2)) return '422';
  return '420';
}

/**
 * @param {Uint8ClampedArray} rgba  full-framebuffer RGBA pixels
 * @param {number} fbWidth          framebuffer width in pixels (row stride of rgba)
 * @param {object} u                the decoder's message: x, y, w, h, sourceWidth, pY/pCb/pCr (+ offsets), skipTiles, samplersRow/Col
 */
export function renderYCbCr(rgba, fbWidth, u) {
  const { x, y, w, h } = u;
  const Y = new Uint8Array(u.pY), Cb = new Uint8Array(u.pCb), Cr = new Uint8Array(u.pCr);
  const skip = u.skipTiles ? new Int8Array(u.skipTiles) : null;
  const layout = layoutFor(u.samplersRow, u.samplersCol);
  const stride = u.sourceWidth || w;
  const tilesPerRow = Math.ceil(w / TILE);

  for (let py = 0; py < h; py++) {
    const tileRow = (py / TILE | 0) * tilesPerRow;
    let dst = ((y + py) * fbWidth + x) * 4;
    const yRow = u.pYoff + py * stride;
    // Chroma row start for this layout (chroma planes are packed with their own width).
    const cRow = layout === '420' ? (py >> 1) * (w >> 1) : layout === '422' ? py * (w >> 1) : py * w;
    for (let px = 0; px < w; px++, dst += 4) {
      if (skip && skip[tileRow + (px / TILE | 0)]) continue;
      const luma = Y[yRow + px];
      const ci = layout === '444' ? cRow + px : cRow + (px >> 1);
      const cb = Cb[u.pCboff + ci], cr = Cr[u.pCroff + ci];
      let r = rTab[(luma << 8) | cr];
      let g = clamp[luma - (gCb[cb] + gCr[cr]) + 256];
      let b = bTab[(luma << 8) | cb];
      // Luma correction: pull the colour back toward the luma the decoder reported.
      const l = ((77 * r + 150 * g + 29 * b) / 256) | 0;
      if (l - luma > 1) {
        const s = luma / l;
        r = (r * s) | 0; g = (g * s) | 0; b = (b * s) | 0;
      } else if (luma - l > 1) {
        const s = (255 - luma) / (255 - l);
        r = (255 - (255 - r) * s) | 0; g = (255 - (255 - g) * s) | 0; b = (255 - (255 - b) * s) | 0;
      }
      rgba[dst] = r; rgba[dst + 1] = g; rgba[dst + 2] = b; rgba[dst + 3] = 255;
    }
  }
}
