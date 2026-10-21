# Native console client

Our own client for the KX III console, to replace the embedded Raritan HKC iframe. No Raritan UI code runs; only
the video **decoder** is Raritan's, loaded from the KX at runtime through the dashboard's proxy.

| File | What it is |
|------|-----------|
| `rfbproto.js` | The e-RIC RFB protocol: byte stream, message parsing, frame builders, login proof, key table. No DOM, runs in Node too |
| `kxclient.js` | `KxClient`: WebSocket + decoder worker + canvas + keyboard/mouse. `new KxClient({ canvas, portNo }).connect()` |
| `ycbcr.js` | YCbCr → RGB conversion of the decoder's output (port of HKC's renderer) |
| `index.html` | Dev page at `/native/index.html` (target picker, connect, Ctrl-Alt-Del, log) |
| `probe.mjs` | Node tool: handshake against the live KX, prints what it sends (`KX_PROBE_TRACE=1` for every message), never decodes |
| `hkc-capture.html` | Dev tool: runs Raritan's real HKC with a logging WebSocket so its exact bytes can be read (`/native/hkc-capture.html?port=9`, then `__capture()` in the console). Opens a real console |
| `selftest.mjs` | Offline tests against a scripted server and the renderer: `node public/native/selftest.mjs` |
| `PROTOCOL.md` | The wire format, with each part marked verified-live or read-from-source |

## Files loaded from the KX at runtime

Through the dashboard proxy (same origin), all fetched by the decoder worker itself:

- `/js/js_decoding_worker.min.js` (the worker)
- `/js/wasm/wasm_decoder.js` and `/js/wasm/wasm_decoder_bg.wasm` (the WASM decoder; the worker falls back to a JS decoder)

## Verification (2026-10-20, firmware 3.10.0.5.4237)

**Verified live**
- Handshake through the proxy: version `01.31`, session-id login and challenge proof, parameters, port list, init.
- **Video**: `/native/index.html` streams port 9 (B25-CTL-OPC02, DVM-DP) at 1920×1080, 11–13 fps, about 6 Mbit/s,
  decoded by the KX's own WASM worker and drawn with `ycbcr.js`: the canvas shows the correct Windows desktop
  (readable text, right colours). `probe.mjs` gets 5 frames in 0.3 s and the connection stays up.
- The client's frames equal the bytes captured from real HKC (fixtures in `selftest.mjs`).
- Pointer events are accepted and the remote cursor follows.
- Clean disconnect (the KX lists the port as busy for about 30 s afterwards).

**Not fully verified**
- Absolute mouse accuracy: the KX reports `current_mouse_mode = absolute`, but a sweep to canvas (1000, 800) put the
  remote cursor near (881, 676). HKC's mouse-mode parameter and mouse sync are not implemented yet.
- Keyboard: key frames are built and sent, but no key was typed on the real target in testing (only mouse moves).
- Mouse buttons and wheel, Ctrl-Alt-Del, video refresh button, resolution changes, the non-ICT (LRLE) path,
  4K targets, reconnect behaviour.
- Port 1 (B25-CTL-XAG00) has no video signal; the KX sends `video = no` and no frames, so the canvas stays black
  (the client reports "no video signal"; that status text was added after the live runs, so it is only covered by the protocol trace).

The earlier "black canvas, 0 fps" on port 1 was two things: no signal on that target, and a client bug that
desynced the KX's parser (the video settings request was 5 bytes instead of HKC's 2; see `PROTOCOL.md`).

To re-verify after a firmware update: close every console, run `node public/native/probe.mjs <port>`, then
connect from `/native/index.html`. `node public/native/selftest.mjs` runs the offline tests.

## Server changes needed to ship it in the dashboard

None to run the dev page: it uses `/api/ports`, `/api/session`, and the existing `/rfb` upgrade proxy.
