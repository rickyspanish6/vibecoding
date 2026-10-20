# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/) (`MAJOR.MINOR.PATCH`).

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
