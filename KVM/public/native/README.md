# Native console client (work in progress)

Our own client for the KX III console, to replace the embedded Raritan HKC iframe. No Raritan UI code runs; only
the video **decoder** is Raritan's, loaded from the KX at runtime through the dashboard's proxy.

| File | What it is |
|------|-----------|
| `rfbproto.js` | The e-RIC RFB protocol: byte stream, message parsing, frame builders, login proof, key table. No DOM, runs in Node too |
| `kxclient.js` | `KxClient`: WebSocket + decoder worker + canvas + keyboard/mouse. `new KxClient({ canvas, portNo }).connect()` |
| `ycbcr.js` | YCbCr → RGB conversion of the decoder's output (port of HKC's renderer) |
| `index.html` | Dev page at `/native/index.html` (target picker, connect, Ctrl-Alt-Del, log) |
| `probe.mjs` | Node tool: handshake against the live KX, prints what it sends, never decodes |
| `selftest.mjs` | Offline tests against a scripted server and the renderer: `node public/native/selftest.mjs` |
| `PROTOCOL.md` | The wire format, with each part marked verified-live or read-from-source |

## Files loaded from the KX at runtime

Through the dashboard proxy (same origin), all fetched by the decoder worker itself:

- `/js/js_decoding_worker.min.js` (the worker)
- `/js/wasm/wasm_decoder.js` and `/js/wasm/wasm_decoder_bg.wasm` (the WASM decoder; the worker falls back to a JS decoder)

## Verification (2026-10-20, firmware 3.10.0.5.4237)

Verified live: WebSocket through the proxy, version `01.31`, session-id login and challenge proof (accepted by the
KX), connection parameters, port list, the user-name message, the decoder worker starting with WASM, the dev page
loading. **Not verified live: server init, framebuffer format, any video frame, decoding, rendering, input.**
After the first successful probes the KX answered every RFB login with `PP_ERR_RFB_NO_PERM` and the proxied web
pages timed out, so live testing was stopped (details at the end of `PROTOCOL.md`). **Likely cause, found afterwards:**
the dashboard was reusing a dead KX web session (its session check wrongly accepted the KX's `/akc` redirect, fixed
in v1.3.1), and a dead session cookie explains "no permission". The KX itself was healthy (login page in 0.25 s,
SNMP fine). Re-run the probe on v1.3.1 or later before concluding anything about the KX.

To pick this up: make sure no console is open, then run `node public/native/probe.mjs <port>` (it refuses to run
while a console socket or busy port exists), and once frames arrive open `/native/index.html` and connect.

## Server changes needed to ship it in the dashboard

None to run the dev page: it uses `/api/ports`, `/api/session`, and the existing `/rfb` upgrade proxy.
