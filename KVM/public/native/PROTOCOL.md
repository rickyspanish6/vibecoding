# e-RIC RFB, as spoken by the KX III's HTML client

What the HKC (`/jsclient/Client.asp`, `js_kvm_client.*.min.js`) does on firmware 3.10.0.5.4237, reconstructed by
reading its source. Implemented in [`rfbproto.js`](rfbproto.js). Status of each part is marked:

- **[src]** read from the HKC source only, not yet seen on the wire
- **[live]** confirmed against a real KX (firmware 3.10.0.5.4237, 2026-10-20) with `probe.mjs`

## Transport

- `wss://<kx>/rfb` (port 443, same TLS as the web UI), binary frames. **[live]** The dashboard server proxies it
  at `/rfb` and attaches the KX web session cookie.
- The protocol is a plain byte stream: WebSocket message boundaries carry no meaning (HKC pushes every message
  into one buffer and reads exact lengths). One exception: the session challenge has no stated length and HKC
  takes "whatever is buffered", relying on the server sending it as one message.
- All integers are big-endian. Server messages start with a 1-byte type; client messages too. `skip(n)` below
  means n bytes that HKC reads and ignores.
- After the web login, the **session id** used for the RFB login is the web session cookie. HKC looks for the URL
  hash `sessionId`, then the cookie `kvm_session_id`, then `pp_session_id`. A KX III web login sets
  **`pp_session_id`** **[live]**.

## Handshake

| # | Direction | Bytes |
|---|-----------|-------|
| 1 | C→S | the 11 ASCII bytes `e-RIC AUTH=` (sent when the socket opens) **[live]** |
| 2 | S→C | type `101` then 15 bytes: with the leading `e` this is `e-RIC RFB 01.<minor>\n`. HKC accepts minor 29–34 (this KX: **31**, **[live]**). Minor > 32 switches the video bitstream version to 2. |
| 3 | C→S | the 16-byte version string echoed back **[live]** |
| 4 | S→C | type `32` (auth caps), u8 bitmask: `1` HTTP session id, `2` plain password, `4` MD5, `8` none, `16` CSC session |
| 5 | C→S | login: `32`, auth method u8 (`1`), nameLen+1 u8, `0`, u32 `0`, name bytes, `0`. With session-id auth the name is empty: `20 01 01 00 00 00 00 00 00` (hex) **[live]** |
| 6 | S→C | type `33` (challenge) + body. Body byte 0 is skipped; bytes 1..64 are 64 hex characters; the literal `{SHA256}` appears in the body when SHA-256 is wanted (MD5 otherwise; HKC does not even load MD5) |
| 7 | C→S | `33`, length u8 (=65), 64 lowercase hex chars of `SHA256(utf8(body[1..65]) + utf8(sessionId))`, `0`. **[live]** The KX accepted this proof, so the "take what is buffered" challenge handling worked |
| 8 | S→C | type `34` + 7 bytes (auth successful) **[live]** |
| 9 | S→C | type `18` connection parameters (see below), then the port list (type `4`, or `172` extended), then type `7` (the user name). **[live]** all three parsed; which port-list type 3.10 sends was not recorded |
| 10 | C→S | on receiving type `7` during init, **in this order**: client init (`7`, `0`, u16 flags: `4` if appId, `\|8` extended port list), associated tag (`8`, `0`, u16 len, appId), KVM switch (`137`, `0`, u16 len, portId). **[live]** Sending the tag *before* the client init made the KX stay silent for 25 s (no server init, no error). The corrected order is **[src]** only: the follow-up probes were refused (see below) |
| 11 | S→C | `5` server init (7 bytes), `128` framebuffer format |
| 12 | C→S | on the first `128`: set encodings, set pixel format, update request (non-incremental), then video-settings request; ping every 20 s |

`portId` is the KX's unique port id, e.g. `P_<device mac>_<n>` where n is **0-based** (the KX UI's port 8 is `…_7`).
HKC takes it from its URL hash; otherwise it looks it up in the port list by `portNo`. The port list's `portNo` is
the KX UI's **1-based** number **[live]** (`8 = B25-CTL-OPC01`), unlike the `portNo=7` in HKC's URL, which HKC does
not use for matching when a portId is given.

## Server → client messages (after the type byte)

| Type | Name | Body |
|------|------|------|
| 0 | framebuffer update | s8 flags, u16 rectCount, u32 imageSize, +8 bytes timestamp if `flags & 1`; then the image data below |
| 3 | user notification | s8 flags (`&1` = the server is about to quit), skip 2, u32 code. Severity = `code >> 24 & 15` (0 error, 1 warn, 2 info) |
| 4 | port list | skip 1, u16 n; per port: u8 kvmPerm, u8 vmPerm, u16 portNo, u16 idLen, u16 nameLen, id, name. HKC uses this layout when minor ≤ 31 |
| 5 | server init | skip 3, s32 serverId |
| 7 | string | skip 1, u16 len, text (the user name during init) |
| 8 | video settings | skip 1, 8×s8, 9×s16 (27 bytes) |
| 9 | keyboard layout | skip 1, s16 len, text |
| 16 | OSD state | s8 blank, u16 timeout, u16 len, text |
| 18 | connection parameters | s8 n; per entry: u8 keyLen, u8 valLen, key, value. Notable: `ict_enc` (`no`/`yes`/`4k`), `devicename`, `color_calibration`, `video_settings` |
| 19 | ack pixel format | skip 3, 4×u8, 3×u16, 3×u8, skip 3 (19 bytes) |
| 128 | framebuffer format | s8 supported, u16 width, u16 height, then pixel format (bpp, depth, bigEndian, trueColor, r/g/b max u16, r/g/b shift u8), skip 3 (21 bytes) |
| 131 | server RC message | skip 3, s32 len, text |
| 132 | server command | skip 1, u16 keyLen, u16 valLen, key, value |
| 149 | ping reply | skip 3, s32 |
| 166 | VM mount response | u8, u8, skip 1, s32 (7 bytes) |
| 167 | VM share table | u8 n; per entry: s8 hostLen, s8 imageLen, host, image |
| 168 | virtual media config | u8 n, n×u8 |
| 170 | USB profile list | u16 n; per entry: u8 nameLen, u16 descLen, u8 flags, u16 id, name, desc |
| 172 | extended port list | skip 1, u16 n; per port: u8 kvmPerm, u8 vmPerm, u8 powerPerm, skip 1, 4×u16 lengths, then four strings (portNo as text, unique id, name, CIM type) |
| 173 | terminal config | 3×u8 |
| 174 | terminal input | s32 |

Notification codes seen/known: `0x10020005` all KVM links busy ("Maximum number of KVM connections has exceeded"),
`0x10000003` auth failed, `0x10020001` exclusive access, `0x10020002` port denied, `0x10020003` too many clients,
`0x10020004` connect failed, `0x1002000d` remote access denied, `0x12060002` / `0x12060003` disconnect (forced),
`0x1202000b` switch completed.

### Image data

With `ict_enc` ≠ `no` (the usual case for the DVM CIMs), each update carries **one chunk**:

```
skip 1 · u24 total (includes the 12-byte header) · x u16 · y u16 · w u16 · h u16 · encoding i32 · data (total-12 bytes)
```

Otherwise (`LRLE`), `rectCount` rects follow, each `x y w h (u16) · encoding i32 · dataLen u32 · data`, then HKC
skips 4 pad bytes **only when `dataLen % 4 == 0`** (as written; unverified, the non-ICT path is untested).

`encoding & 0xff` is the codec (129 ICT, 131/132/133 ICT 4K, 130 LBE, 128 LRLE), `(encoding >> 12) & 15` its
quality. The data is not interpretable on the main thread: HKC posts it to the decoder worker (below).

## Client → server messages

| Type | Name | Layout |
|------|------|--------|
| 0 | set pixel format | 20 bytes: type, 3 pad, bpp, depth, bigEndian, trueColor, u16 r/g/b max, u8 r/g/b shift, 3 pad. HKC sends 16 bpp BE 565 |
| 2 | set encodings | type, pad, u16 `4`, then four u32 (only the first is used): ICT = `129 \| quality<<12` (HKC default quality 9); 4K = `131 \| quality<<12`; non-ICT = `128 \| q<<12` |
| 3 | framebuffer update request | type, incremental u8, u32 `0` (x, y), u16 width, u16 height |
| 4 | key event | type, `0`, u16 `(key & 0x7fff) \| (down ? 0x8000 : 0)`. `key` is the physical-key number from the table in `rfbproto.js` (`KEY`), derived from `KeyboardEvent.code` |
| 5 | pointer event (absolute) | type, u8 buttons (1 left, 2 middle, 4 right), u16 x, u16 y, u16 wheel (-1/0/1). `147` is the relative variant |
| 7 | client init | see handshake |
| 8 | associated tag | type, `0`, u16 len, bytes |
| 137 | KVM switch | type, `0`, u16 len, portId |
| 145 | video settings request | type, s32 `1` |
| 146 | video refresh | type only |
| 148 | ping request | type, 3 pad, s32 counter |
| 156 | power switch | type, u8 (0 on, 1 off, 2 cycle) (not wired up) |

## Video decoding

HKC does `new Worker('/js/js_decoding_worker.min.js')`. That worker does `importScripts('/js/wasm/wasm_decoder.js')`
and instantiates `/js/wasm/wasm_decoder_bg.wasm` (falling back to a JS decoder if WASM fails), then posts
`{ init: true }`. Per rectangle the client posts:

```js
{ command: 'decode', isWebGL, data /*ArrayBuffer, transferred*/, bitstreamVersion,
  frameBufferWidth, frameBufferHeight, updateRectEncoding, updateRectX, updateRectY, updateRectW, updateRectH }
```

and the worker answers with `{ fbImageWidth, fbImageHeight, x, y, w, h, sourceWidth, pY, pYoff, pCb, pCboff, pCr,
pCroff, skipTiles, samplersRow, samplersCol }`: YCbCr planes (row-major; chroma planes subsampled per the sampling
factors) and a per-16×16-tile skip flag. The client then asks for the next change (incremental update request)
and converts the planes to RGB. `ycbcr.js` reimplements that conversion; the decoder itself is Raritan's and is
loaded from the KX at runtime.

Files loaded from the KX through the proxy: `/js/js_decoding_worker.min.js`, `/js/wasm/wasm_decoder.js`,
`/js/wasm/wasm_decoder_bg.wasm`. Nothing else from Raritan is loaded.

## Open questions (resolve with a live capture)

1. Is the port list sent as type `4` or `172` on 3.10? (Both parse paths exist.)
2. Server init (`5`) and the first format (`128`) after the corrected client-init order: **never seen live**.
3. The framebuffer update chunk layout, the decoder worker round trip and `ycbcr.js` output: **never seen live**.
4. Non-ICT path padding rule.
5. After a few successful logins, the KX answered every further RFB login with notification `0x10000001`
   (`PP_ERR_RFB_NO_PERM`, quit flag) straight after the login message, even though the same dashboard session id
   was still valid for the web UI, and its web pages then became slow (`ETIMEDOUT` in the dashboard's keep-alive).
   Cause unknown: a session already bound to a console, a per-session limit, or the KX being stressed by repeated
   probe connections. Re-run `probe.mjs` once the switch is idle and settled.

## Addendum (parent session)

The `0x10000001` / `PP_ERR_RFB_NO_PERM` refusals above are most likely explained by the dashboard reusing an expired
KX web session, not by a KX limit or load problem: its session check accepted the `/akc` redirect the KX sends for a
dead session (fixed in v1.3.1). The KX web interface was responsive when checked afterwards. The cookie that carries
the session id on firmware 3.10 is `pp_session_id`.
