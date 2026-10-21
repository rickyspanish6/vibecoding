# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/) (`MAJOR.MINOR.PATCH`).

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
