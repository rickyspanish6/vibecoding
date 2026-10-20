# KX Console

A clean web front end for a Raritan Dominion KX III KVM-over-IP switch (developed against firmware 3.10).
It lists targets with live status, embeds Raritan's own HTML KVM client in the page, and shows who else is
connected to the switch.

## How it works

- **Port list:** one SNMP bulk walk of the KX's port table (name, type, status). Status `3` means a port is in use.
- **Console:** the backend reverse-proxies the KX under `http://127.0.0.1:3000`, because the KX blocks framing and
  its client opens `wss://<host>/rfb`. It logs in once with `KX_USER` / `KX_PASSWORD`, keeps the session cookies
  (also saved to `.kx-session.json`), and the browser never sees the password. `/jsclient/Client.asp` is loaded in an iframe.
- **Sessions panel:** the KX CLI's `userlist` over SSH key login.
- **Keep-alive / auto-reconnect:** the session is re-checked every minute while the page is open; if the console
  socket drops, the page reconnects (up to 3 times in 2 minutes).
- **Safety:** the server only answers `localhost` / `127.0.0.1` Hosts and same-origin requests, because it holds a
  logged-in admin session. Do not expose it beyond localhost without adding authentication.

The KX allows **one remote KVM channel at a time**, so clicking a target drops the current one first.

## Setup

On the KX (Device Settings > Device Services): enable SSH, SNMP (set your own community), and Direct Port Access via URL.
Add your public SSH key to your user (User Management > Users).

On your machine (Node 20+ and net-snmp's `snmpbulkwalk` / `snmpget`, preinstalled on macOS):

```bash
cp .env.example .env   # then fill in KX_USER and KX_PASSWORD
npm start              # http://127.0.0.1:3000
npm run mock           # fake data, no KX needed
```

| Variable | Default | Purpose |
| --- | --- | --- |
| `KX_HOST` | `172.16.0.3` | KX address |
| `KX_SNMP_COMMUNITY` | `public` | SNMP v2c community |
| `KX_USER`, `KX_PASSWORD` | | Web login used by the proxy (never sent to the browser) |
| `KX_DEVICE_ID` | `000d5d11da6a` | The `<id>` in HKC's `P_<id>_<n>` port ids; copy it from a console URL on your unit |
| `KX_SSH_USER`, `KX_SSH_KEY` | `KX_USER`, `~/.ssh/kx3_rsa` | SSH key login for the sessions panel |
| `PORT` | `3000` | Dashboard port |

## Known limits

- Disconnect all closes this page's session only; other clients on the KX can't be kicked yet.
- The console is Raritan's client; the video protocol (`e-RIC RFB` over `wss://<host>/rfb`, WebGL/WASM decoder) is not reimplemented.
- No power control (the KX CLI has none).
