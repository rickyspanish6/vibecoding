# e-RIC RFB, as spoken by the KX III's HTML client

What the HKC (`/jsclient/Client.asp`, `js_kvm_client.*.min.js`) does on firmware 3.10.0.5.4237, reconstructed by
reading its source. Implemented in [`rfbproto.js`](rfbproto.js). Status of each part is marked:

- **[src]** read from the HKC source only, not yet seen on the wire
- **[live]** confirmed against a real KX (firmware 3.10.0.5.4237, 2026-10-20) with `probe.mjs`, or by capturing real HKC with `hkc-capture.html`
- **[capture]** bytes copied from a capture of real HKC talking to this KX (these are also fixtures in `selftest.mjs`)

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
| 10 | C→S | on receiving type `7` during init, **in this order**: client init (`07 00 00 0c`: flags `4` if appId, `\|8` extended port list), associated tag (`08 00 <u16 len> <appId>`), KVM switch (`89 00 <u16 len> <portId>`). **[capture]** |
| 11 | S→C | `5` server init (8 bytes), `16` OSD, `9` keyboard layout, `132` commands, then the first `128` framebuffer format (22 bytes) **[live]** |
| 12 | C→S | on the first `128`, about 340 ms after the switch **[capture]**: set encodings (`02 00 00 04 00 00 d0 81` + 12 zero bytes, i.e. ICT with quality 13), set pixel format (`00 00 00 00 10 10 01 01 00 1f 00 3f 00 1f 0b 05 00 00 00 00`), update request non-incremental (`03 00 00 00 00 00 07 80 04 38`), **video settings request, exactly 2 bytes: `91 01`**. Then a ping every 20 s (`94 00 00 00 00 00 00 <n>`) |
| 13 | S→C | more `132` commands, a second `128`, `167`, `168`, `170` (about 10 KB of USB profiles), notification `0x1202000b` "port switch completed", then `19` (ack of the pixel format) **[live]** |
| 14 | C→S | **500 ms after "port switch completed": video refresh, 1 byte `92`** **[capture]**. HKC then sends a non-incremental update request on the second `128`, and an incremental one (`03 01 …`) after every decoded frame |
| 15 | S→C | OSD (`16`) and `132` status messages while the target's video locks; then framebuffer updates (about 1.4–2 s after connecting on a target with a signal) **[live]** |

**Gotcha, found the hard way:** the video settings request is 2 bytes. Sending it as 5 bytes (`91 00 00 00 01`) makes the
KX's parser read the 3 extra bytes as the start of a new message (`00` = set pixel format, which wants 19 more
bytes), so it swallows the following requests. Symptoms: no frames at all, and the KX drops the socket as soon
as the next update request arrives. The KX parses the stream strictly by message type, so every client message
must have exactly the length HKC uses.

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
| 5 | server init | skip 3, s32 serverId (7 bytes after the type byte) |
| 7 | string | skip 1, u16 len, text (the user name during init) |
| 8 | video settings | skip 1, 8×s8, 9×s16 (27 bytes) |
| 9 | keyboard layout | skip 1, s16 len, text |
| 16 | OSD state | s8 blank, u16 timeout, u16 len, text |
| 18 | connection parameters | s8 n; per entry: u8 keyLen, u8 valLen, key, value. Notable: `ict_enc` (`no`/`yes`/`4k`), `devicename`, `color_calibration`, `video_settings` |
| 19 | ack pixel format | skip 3, 4×u8, 3×u16, 3×u8, skip 3 (19 bytes) |
| 128 | framebuffer format | s8 supported, u16 width, u16 height, then pixel format (bpp, depth, bigEndian, trueColor, r/g/b max u16, r/g/b shift u8), skip 3 (21 bytes) |
| 131 | server RC message | skip 3, s32 len, text |
| 132 | server command | skip 1, u16 keyLen, u16 valLen, key, value. Seen live: `video` = `no` / `unstable` / `stable` (the target's signal; `unstable` then `stable` about 1.1 s after connecting, frames follow), `current_mouse_mode` = `absolute`, `support_mouse_absolute` / `_auto` / `_direct` = `yes`, `rc_users`, `PowerCtrl` = `disable`, `CapsLockLED` / `NumLockLED` / `ScrollLockLED`, `HideToolMenuBar`, `audio` |
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

With `ict_enc` ≠ `no` (the usual case for the DVM CIMs), each update carries **one chunk** **[live]** (HKC receives the 8-byte update header and the chunk as two WebSocket messages; 1920×1080 arrives as a 1920×1088 rect, about 120 KB at quality 13, roughly 10 updates per second on a desktop):

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
| 2 | set encodings | type, pad, u16 `4`, then four u32 (only the first is used): ICT = `129 \| quality<<12`; 4K = `131 \| quality<<12`; non-ICT = `128 \| q<<12`. **[capture]** HKC sends `0xd081`, i.e. quality **13** (the 9 in its source is overridden), and the KX answers with frames whose encoding word is `0xd081` too |
| 3 | framebuffer update request | type, incremental u8, u32 `0` (x, y), u16 width, u16 height |
| 4 | key event | type, `0`, u16 `(key & 0x7fff) \| (down ? 0x8000 : 0)`. `key` is the physical-key number from the table in `rfbproto.js` (`KEY`), derived from `KeyboardEvent.code` |
| 5 | pointer event (absolute) | type, u8 buttons (1 left, 2 middle, 4 right), u16 x, u16 y, u16 wheel (-1/0/1). `147` is the relative variant |
| 6 | (scancode event) | defined in HKC's constants, never sent by it |
| 7 | client init | see handshake |
| 8 | associated tag | type, `0`, u16 len, bytes |
| 137 | KVM switch | type, `0`, u16 len, portId |
| 145 | video settings request | **2 bytes**: `91 01` **[capture]** (a 5-byte form exists in HKC's writer but is not what it sends) |
| 146 | video refresh | type only |
| 134 | mouse sync | type, u8 `1` (hard sync) **[src]**. HKC sends it only when the user picks "Synchronize mouse" (toolbar `syncMouse`), then re-sends the last pointer event. It is never automatic |
| 147 | relative pointer | type, u8 buttons, u16 dx, u16 dy (two's complement), u16 wheel **[src]**. Used only in HKC's "single mouse" mode (pointer lock on the canvas) |
| 148 | ping request | type, 3 pad, s32 counter |
| 155 | set connection parameter | type, u8 keyLen, u8 valueLen, key, value **[src]**; HKC writes `current_mouse_mode` = `absolute` / `auto` / `direct` when the user changes the mouse mode in its menu |
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

## Open questions

1. Is the port list sent as type `4` or `172` on 3.10? (Both parse paths exist; the data parsed correctly.)
2. The non-ICT (LRLE) path, including its padding rule, is untested.
3. Whether the KX needs the 500 ms refresh after the switch: it is sent (as HKC does), but frames also flowed
   without it in earlier probes once the desync was fixed.
4. A target with no video signal (port 1, B25-CTL-XAG00) sends no framebuffer update at all; the `video`
   server command (`no`) says so, and `kxclient.js` reports it as the status "no video signal".
   (The first server messages on a port with signal were `video = no`, `unstable`, `stable`.)
7. Mouse: the KX reports `current_mouse_mode = absolute`, and absolute pointer events move the remote cursor, but
   the final position was off (sent canvas 1000,800, remote cursor near 881,676). HKC also writes a
   `current_mouse_mode` connection parameter (type 155) and offers mouse sync (type 134); neither is implemented,
   and the coordinate mapping HKC uses in this mode has not been checked.
5. Earlier `0x10000001` (`PP_ERR_RFB_NO_PERM`) refusals were the dashboard reusing a dead KX web session, not a
   protocol issue (fixed in the dashboard).
6. The KX keeps a console session on its books for about 30 s after the socket closes, so the port shows as busy
   (SNMP status 3) and a quick reconnect can be refused. Plan reconnect delays accordingly.

## Mouse (how HKC maps it)

- HKC never negotiates a mouse mode by itself. It sends **absolute pointer events (type 5) in canvas pixels**:
  `x = floor((clientX - canvasRect.left) / scale)`, with `scale` the canvas's CSS scale, so the number is the
  framebuffer pixel under the cursor at any display size. The KX decides what that means for the target.
- The server announces `support_mouse_absolute|auto|direct` (yes/no) and `current_mouse_mode` (type 132). The user
  can change the mode (HKC menu → parameter `current_mouse_mode`), start "single mouse" mode (relative events with
  pointer lock), or press "Synchronize mouse" (type 134).
- Buttons are a bitmask (1 left, 2 middle, 4 right) sent with every pointer event; the wheel is -1/0/1 in the
  last field, with the cursor position.
- `kxclient.js` does the same: absolute by default, `setMouseMode('relative')` for pointer lock,
  `setMouseMode('absolute'|'auto'|'direct')` for the KX mode, `syncMouse()`.

## Keyboard (how HKC maps it)

Key events carry a **physical key number**, not a character (the target's layout does the rest). HKC's own EN
table maps all 119 modern `KeyboardEvent.code` values exactly as `keyFromCode()` does (checked entry by entry
against the source), except that **Safari on macOS** reports `Backquote` / `IntlBackslash` swapped, which HKC
swaps back. Behaviour that `keyboard.js` reproduces:

- a key that is already held is ignored (no auto-repeat events; the target repeats on its own);
- on every new key press, modifiers the browser reports as up but we still hold are released (lost keyups);
- AltGr: Windows browsers send ControlLeft then AltRight; ControlLeft is held back 30 ms so that AltRight can
  swallow it, and releasing the companion Ctrl releases AltGr. (HKC mishandles a Ctrl tap shorter than 30 ms and can
  leave Ctrl stuck; `keyboard.js` delivers it as press + release instead.)
- macOS: CapsLock yields one browser event per toggle, sent as press + release each time; a key pressed while Cmd
  is held never gets a keyup, so it is released at once;
- everything held is released on blur and on disconnect.

HKC has no client-side hotkeys: the `HOTKEY_*` / `MOUSESYNC_KEY` parameters (Alt+F12 and friends) are for Raritan's
other clients and are ignored, so Alt+F12 reaches the target as two ordinary keys.
