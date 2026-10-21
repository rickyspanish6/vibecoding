# Native console client

Our own client for the KX III console, to replace the embedded Raritan HKC iframe. No Raritan UI code runs; only
the video **decoder** is Raritan's, loaded from the KX at runtime through the dashboard's proxy.

| File | What it is |
|------|-----------|
| `rfbproto.js` | The e-RIC RFB protocol: byte stream, message parsing, frame builders, login proof, key table. No DOM, runs in Node too |
| `kxclient.js` | `KxClient`: WebSocket + decoder worker + canvas + keyboard/mouse. `new KxClient({ canvas, portNo }).connect()` |
| `keyboard.js` | Browser key events → KX key events with HKC's behaviour (no repeat, stuck-modifier repair, AltGr, macOS quirks, release-all). DOM-free |
| `ycbcr.js` | YCbCr → RGB conversion of the decoder's output (port of HKC's renderer) |
| `index.html` | Dev page at `/native/index.html` (target picker, connect, Ctrl-Alt-Del, log) |
| `probe.mjs` | Node tool: handshake against the live KX, prints what it sends (`KX_PROBE_TRACE=1` for every message), never decodes |
| `input-check.html` | Dev tool: `/native/input-check.html?port=10`. MAC01 only (the target approved for real input): Spotlight, typing with Shift/punctuation, blur-release check, clicks, wheel |
| `pointer-check.html` | Dev tool: `/native/pointer-check.html?port=10`. Moves the pointer (never clicks) to known spots at several CSS sizes and finds the remote cursor in the decoded frame |
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
- Absolute mouse accuracy: the KX reports `current_mouse_mode = absolute`, but one early sweep to canvas (1000, 800)
  put the remote cursor near (881, 676) on a Windows target. HKC maps coordinates exactly as the client does
  (canvas pixels via the CSS scale), so the cause is not the mapping; the follow-up measurement
  (`pointer-check.html`, several CSS sizes, MAC01) could not be run: see "Pending live checks".
- Keyboard on a real target (see "Pending live checks").
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

## Pending live checks (not run: the KX had two idle console sessions open on B25-CTL-XAG00 for 15+ minutes)

Offline, with fake timers and byte fixtures, these pass (`node public/native/selftest.mjs`, 16 tests): the key
table against all 119 codes in HKC's own table, press/release, no auto-repeat, stuck-modifier repair, release on
blur, AltGr, macOS CapsLock/Cmd, Safari swap, pointer math at 5 CSS sizes (corners, centre, clamping), and the
relative-pointer / mouse-sync / mouse-mode frames.

What still needs the real KX (close every console, make sure no port is busy; `GET /api/ports` → `rfbOpen` 0):

1. `/native/pointer-check.html?port=10` : cursor accuracy at three CSS widths. Result is in `window.__result`
   (`fitX`/`fitY` should be a≈1, b≈0). If it is off, try `kx.setMouseMode('direct')` / `'auto'` (what HKC's Mouse menu
   writes) and `kx.syncMouse()`, then restore `'absolute'`.
2. `/native/input-check.html?port=10` : typing in Spotlight (capitals, punctuation), Shift not stuck after a blur,
   left/right click, wheel.
3. `/native/hkc-capture.html?port=10&drive=mac` then `__capture()` : HKC's own key/pointer frames for the same
   sequence, to turn into fixtures in `selftest.mjs`.
