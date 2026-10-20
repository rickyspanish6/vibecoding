# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/) (`MAJOR.MINOR.PATCH`).

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
