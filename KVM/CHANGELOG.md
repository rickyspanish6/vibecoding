# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/) (`MAJOR.MINOR.PATCH`).

## [1.9.0-rc.1] - 2026-10-21

Release candidate: written and tested against a fake netBooter, **not yet run against a real unit** (1.9.0 follows
once it has been).

### Added
- **Power control per host: Power on, Power off and Cycle** (host gear, "Power control"). Commands use the saved outlet
  mapping and go to every mapped outlet, or just the ticked ones for hosts with redundant supplies (`pset n 1|0`,
  `rb n`), then read the state back.
- Safeguards: the request must carry the host's **exact name** (the dialog makes you type it, and the server checks
  it again); a **per-host lock** refuses all commands (HTTP 423); a second command is refused while one runs and for
  5 s afterwards; commands need the saved mapping; every accepted request is appended to `.kx-power.log`
  (time, host, outlets, action, result; never a password); the dashboard login and Origin checks apply as before.
- Unknown `/api/...` paths now return 404 instead of being forwarded to the KX.
- Tests with a fake Synaccess Telnet server (exact commands, refusals, cooldown, redundant outlets, audit log).

### Fixed
- A cooldown that started when a request began could be bypassed by a slow PDU; it now starts when the request ends.

## [1.8.0] - 2026-10-21

### Added
- **Power mapping for Synaccess netBooter PDUs (read-only).** The backend reads each unit over Telnet (`pshow`: outlet
  names and state, plus current draw and temperature) and maps outlets to KX hosts. It never switches an outlet.
- **Settings dialog** (gear at the top of the sidebar): add, edit, test and remove PDUs (name, IP, port, user,
  password), and "Auto-match outlets to hosts". Device logins are stored in `.kx-config.json` (owner-only, gitignored)
  and are never sent to the browser.
- **Per-host settings** (gear on every host row): the outlets that feed the host (several for redundant supplies),
  and an optional console client override for that host.
- Power indicators: a coloured bolt on each mapped host (green on, red off, amber partly on) and a header chip with the
  outlets and their state.
- Outlet-name matching handles short names (`XAG01`), area prefixes (`CTL-MAC01`) and PSU suffixes (`NAS01-02`).
- Unit tests for the matching and parsing (`npm test`).

### Fixed
- Switching console client, or reconnecting, now closes the previous native console first; before, it could keep
  holding the KX's single channel and leave stale native buttons showing.
- The native client no longer throws when its socket closes after `disconnect()`.

### Verified live (firmware 3.10.0.5.4237; four NPB20DU units running Synaccess Telnet V7.1)
- All four units read over Telnet (20 outlets each); auto-match mapped all 12 named hosts correctly.
- Native client on B25-CTL-MAC01: left click (opened a System Settings page), Refresh video (full-frame resend),
  Spotlight and Cmd+W shortcuts, switching to and from the Raritan client.
- Per-host client override opened the Raritan client for one host while the global choice was Native.

### Not verified
- Mouse wheel: frames are byte-identical to Raritan's client and reach the target, but no scrolling was observed with
  the native or the Raritan client in these tests, so it is unconfirmed on this Mac and CIM.
- Ctrl-Alt-Del (no effect on a Mac), resolution changes and 4K.
- Telnet is not encrypted: keep the PDUs on a trusted network.

## [1.7.0] - 2026-10-21

### Changed
- **The native client is now the default console.** Raritan's embedded client remains available as "Raritan client
  (classic)" in the selector, and a saved choice in the browser is kept. A failed native connect suggests switching.

### Verified live through the dashboard (B25-CTL-MAC01 and B25-CTL-OPC02, firmware 3.10.0.5.4237)
- Click a target and the native console connects: 1920x1080, scaled to fit the window, about 20 fps, blue LED,
  Connected chip, Ctrl-Alt-Del and Refresh video buttons, sessions panel entry.
- Typing on the Mac: Cmd+Space opened Spotlight and "Hello, World! 123" appeared exactly (capitals, comma,
  exclamation mark, digits) using real key sequences with Shift; the field was cleared and Spotlight closed.
- Pointer: a real right-click on the desktop opened the Mac's context menu with its corner on the click point.
- Switching MAC01 to OPC02 connected in about 5 s; Disconnect closed the console and the proxy showed no open socket.

### Not verified
- Wheel, left click effects, Ctrl-Alt-Del, Refresh video, resolution changes, 4K, and keyboard on the Windows targets.
- Keys sent as a shifted press without a separate Shift key event (some automation tools) arrive unshifted; real
  keyboards always send the Shift event, and this matches Raritan's client.

## [1.6.1] - 2026-10-21

### Fixed
- Console sessions that use this app's own web login can now be disconnected from their ports (Disconnect, Disconnect
  all). They were skipped because they share the login's session id; the login itself is still never logged off.
  Port-mode disconnect now takes every console row of a login, not just the first.

### Verified live on B25-CTL-MAC01 (native client, firmware 3.10.0.5.4237)
- Pointer: 24 of 24 positions found at three display sizes (800, 560 and 400 px wide); fit slope 0.994 (x) and
  1.004 (y); a constant offset of about 8 px across and 12 px down, within one video tile. The earlier miss was
  specific to the Windows target it was measured on.
- Keyboard: Cmd+Space opened Spotlight on the target; a held Shift is released on blur (held 1 before, 0 after); no
  keys held at the end; Escape, Cmd+A and Backspace sequences ran without errors.
- Clicks, right click and wheel were sent without errors.

### Not verified
- The typed text itself was not captured on screen, and the effect of clicks and wheel was not inspected.
- The dashboard's Native (beta) mode has not been run against a live console. Raritan's client stays the default.
- Auto-reconnect can fight another dashboard tab for the KX's single channel (each reconnect first ends other
  consoles); it gives up after 3 tries in 2 minutes.

## [1.6.0] - 2026-10-21

### Added
- **Console client selector** in the dashboard: Raritan client (default) or **Native (beta)**, remembered per browser,
  with Ctrl-Alt-Del, Refresh video and an fps / bitrate readout for the native client.
- **Scale Video on by default** in the embedded Raritan client (seeds `scaleMode` once; a choice made in Raritan's
  Client Settings is kept).
- Native client: keyboard translator (`keyboard.js`, reproduces HKC's key handling: repeat filtering, stuck-modifier
  release, AltGr, macOS quirks, release on blur and disconnect), optional mouse modes and sync, relative-mouse
  fallback, and input check pages (`pointer-check.html`, `input-check.html`).

### Fixed
- `/` search shortcut no longer steals keys typed into the remote console.

### Verification status
- Offline: 16 self-tests pass (key table vs HKC's, keyboard behaviours, pointer math at 5 sizes, new frames).
- **Not yet verified live:** pointer accuracy (an earlier test landed the cursor off target; HKC maps coordinates the
  same way, so the cause is still unknown), typing, clicks and wheel, and the dashboard's native mode. Raritan's client
  stays the default until these are checked on a real target (B25-CTL-MAC01 is the approved test target).

## [1.5.0] - 2026-10-20

### Fixed (native client, experimental)
- The video-settings request was 5 bytes where Raritan's client sends 2 (`91 01`); the KX read the extra bytes as the
  start of another message and ignored the following frame requests. The client now matches the captured traffic,
  uses the same encoding word (`0xd081`) and sends the video refresh 500 ms after the port switch.

### Added
- `public/native/hkc-capture.html`: dev tool that runs the real Raritan client with a logging WebSocket, so traffic can
  be compared byte for byte. Captured bytes are now fixtures in the self-test (7 tests).

### Verified live
- The native dev page streams decoded 1920x1080 video (about 12 fps, 6 Mbit/s) from a target with a signal.

### Known limits
- Mouse position is off (the KX reports absolute mode; HKC's mouse-mode handling and sync are not implemented yet).
- Keyboard, buttons, wheel, Ctrl-Alt-Del, resolution changes and 4K are untested on a real target.
- The KX keeps a port marked busy for about 30 s after a disconnect, so an immediate reconnect can be refused.
- Still not wired into the dashboard: the embedded Raritan client remains the way to open a console.

## [1.4.0] - 2026-10-20

### Added
- **Experimental** native console client (`public/native/`, dev page at `/native/index.html`): our own implementation of
  the KX's `e-RIC RFB` protocol (handshake, session-id login, input frames) that renders to a canvas. Only Raritan's
  video decoder is reused, loaded from the KX at runtime. It is not wired into the dashboard yet.
- `PROTOCOL.md` documenting the wire format, and an offline self-test (`node public/native/selftest.mjs`).

### Known limits
- Verified live: handshake, login proof, parameters and decoder start. **Not yet seen live: video frames, rendering,
  keyboard and mouse.** The embedded Raritan client remains the way to open a console.

## [1.3.1] - 2026-10-20

### Fixed
- A dead KX web session was mistaken for a live one: the KX redirects an unauthenticated request to its client-check
  page (`/akc...`), not only to `auth.asp`, and the session check accepted any redirect. The app then kept using an
  expired cookie, so the sessions panel was empty and console logins could be refused. Only a plain 200 page that
  is not the login form now counts as signed in.
- A redirect after the Disconnect / Log off submit is no longer reported as a failure.
- `/api/session` reports the session cookie correctly (`pp_session_id` on firmware 3.10).

## [1.3.0] - 2026-10-20

### Added
- Optional dashboard login: set `DASH_PASSWORD` and every page, API call and console WebSocket requires signing in
  (HttpOnly, SameSite=Strict session cookie, 12 h; 5 wrong passwords lock the client out for 60 s). Sign out link in the sidebar.
- `BIND` and `ALLOWED_HOSTS` to serve the dashboard beyond localhost.

### Security
- The server refuses to start on a non-loopback `BIND` without `DASH_PASSWORD`.
- Host and Origin checks now honor `ALLOWED_HOSTS`; the dashboard cookie is never forwarded to the KX.

## [1.2.0] - 2026-10-20

### Added
- Themed console frame: the embedded Raritan client's menu bar, toolbar, menus and dialogs now follow the dashboard's
  light and dark colours (`public/hkc-theme.css`, injected into the same-origin iframe).

## [1.1.0] - 2026-10-20

### Added
- Session management from the KX's own Users By Port page: the sessions panel now shows each session with its port,
  and has per-session **Disconnect** (end a console) and **Log off** (force a web login off the KX) buttons.
- **Disconnect all** now also ends every other client's console session on the KX (never this app's own login).
- Connecting to a target first ends other clients' console sessions, so the KX's single remote channel is free.

### Changed
- `/api/sessions` reads the KX web page when `KX_USER` / `KX_PASSWORD` are set (SSH `userlist` remains the fallback).

## [1.0.0] - 2026-10-20

First release.

### Added
- Live target list from the KX's SNMP port table, with online / in use / offline status.
- Embedded Raritan HTML KVM client through a same-origin reverse proxy (HTTP and `/rfb` WebSocket).
- One-click connect that drops the previous session and retries while the KX frees its single channel.
- LED states: green (online), pulsing blue (your session), amber (in use elsewhere), grey (offline).
- Disconnect all button.
- Sessions panel from the KX CLI's `userlist` over SSH key login.
- Session reuse across restarts, keep-alive, and auto-reconnect when the console socket drops.
- Host and Origin checks, because the server holds a logged-in KX admin session.
- Version shown in the sidebar and returned by `/api/ports`.
