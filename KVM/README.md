# KX Console

A clean web front end for a Raritan Dominion KX III KVM-over-IP switch (developed against firmware 3.10).
It lists targets with live status, embeds Raritan's own HTML KVM client in the page, and shows who else is
connected to the switch.

## How it works

- **Port list:** one SNMP bulk walk of the KX's port table (name, type, status). Status `3` means a port is in use.
- **Console:** the backend reverse-proxies the KX under `http://127.0.0.1:3000` (the KX blocks framing, and its client
  opens `wss://<host>/rfb`). It logs in once with `KX_USER` / `KX_PASSWORD`, keeps the session cookies (also saved to
  `.kx-session.json`), and the browser never sees the password. The default console is our **native client**
  (`public/native/`: the KX's `e-RIC RFB` protocol drawn on a canvas, reusing only Raritan's video decoder loaded from
  the KX). Raritan's own client (`/jsclient/Client.asp` in an iframe, themed to match) is the classic fallback in the selector.
- **Power mapping:** the settings dialog manages Synaccess netBooter PDUs. The backend reads each over Telnet
  (`pshow`) and maps outlets to hosts by name (`XAG01`, `CTL-MAC01` and `NAS01-02` all match their KX host). It only reads;
  no outlet is ever switched. Device logins live in `.kx-config.json` (owner-only, gitignored). Per-host settings (the
  gear on each host) edit the outlet mapping and an optional console client override.
- **Sessions panel:** the KX's own *Users By Port* page (per-session Disconnect / Log off, and Disconnect all); falls back to the CLI's `userlist` over SSH key login when no web login is configured (read-only then).
- **Keep-alive / auto-reconnect:** the session is re-checked every minute while the page is open; if the console
  socket drops, the page reconnects (up to 3 times in 2 minutes).
- **Safety:** the server holds a logged-in KX admin session, so it only answers `localhost` / `127.0.0.1` Hosts and
  same-origin requests, and listens on loopback by default. To use it from another machine set `BIND=0.0.0.0`,
  `ALLOWED_HOSTS=<the name you browse to>` and a `DASH_PASSWORD` (required for any non-loopback `BIND`); put it behind
  HTTPS (a reverse proxy) when it leaves your machine, since the login cookie is not marked `Secure` over plain HTTP.

The KX allows **one remote KVM channel at a time**, so clicking a target drops the current one first.

## Setup

On the KX (Device Settings > Device Services): enable SSH, SNMP (set your own community), and Direct Port Access via URL.
Add your public SSH key to your user (User Management > Users).

On your machine (Node 20+ and net-snmp's `snmpbulkwalk` / `snmpget`, preinstalled on macOS):

```bash
cp .env.example .env   # then fill in KX_USER and KX_PASSWORD
npm start              # http://127.0.0.1:3000
npm run mock           # fake data, no KX needed
npm test               # unit tests and the native-client self-test (no hardware)
```

| Variable | Default | Purpose |
| --- | --- | --- |
| `KX_HOST` | `172.16.0.3` | KX address |
| `KX_SNMP_COMMUNITY` | `public` | SNMP v2c community |
| `KX_USER`, `KX_PASSWORD` | | Web login used by the proxy (never sent to the browser) |
| `KX_DEVICE_ID` | `000d5d11da6a` | The `<id>` in HKC's `P_<id>_<n>` port ids; copy it from a console URL on your unit |
| `KX_SSH_USER`, `KX_SSH_KEY` | `KX_USER`, `~/.ssh/kx3_rsa` | SSH key login for the sessions panel |
| `PORT` | `3000` | Dashboard port |
| `KX_CONFIG_PATH` | `.kx-config.json` | Where PDU devices, outlet mappings and per-host settings are stored |
| `BIND` | `127.0.0.1` | Address to listen on (non-loopback requires `DASH_PASSWORD`) |
| `DASH_PASSWORD` | unset | Turns on the dashboard login |
| `ALLOWED_HOSTS` | | Extra Host names (comma separated) accepted besides localhost |

**Harden the KX too:** the SNMP community defaults to `public`. Change it in the KX (Device Settings > Device Services),
then set the same value as `KX_SNMP_COMMUNITY`; the app does not change KX settings itself.

## Versioning

[Semantic Versioning](https://semver.org/) (`MAJOR.MINOR.PATCH`): breaking changes to config or behavior bump MAJOR,
new features MINOR, fixes PATCH. `package.json` is the single source of truth (shown in the sidebar and returned by
`/api/ports`). To release: bump `version`, add a section to [CHANGELOG.md](CHANGELOG.md), commit, then tag it:

```bash
git tag -a vX.Y.Z -m "KX Console vX.Y.Z"
```

## Known limits

- The native client reuses Raritan's WASM video decoder (loaded from your KX at runtime); the protocol around it is ours.
- Native client: wheel, Ctrl-Alt-Del, Refresh video and resolution changes are not yet verified live.
- Power is read-only: outlets are shown and mapped, never switched. PDU logins are stored in plain text in `.kx-config.json` and sent over unencrypted Telnet.
