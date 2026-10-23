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
  the settings dialog never switches anything. Device logins live in `.kx-config.json` (owner-only, gitignored). Per-host settings (the
  gear on each host) edit the outlet mapping and an optional console client override.
- **Power control:** each host's gear has Power on / off / cycle for its mapped outlets. They act on real power: every
  command asks you to confirm in a short dialog (the warning is shown, and Cancel is the default button), a per-host lock
  refuses all commands, there is a cooldown, and every accepted request is appended to `.kx-power.log` with who sent it
  (gitignored). Off and cycle are hard power cuts, not clean shutdowns.
- **Speed:** over a high-latency link the console is latency-bound, so the native client asks for the next update as soon as one
  arrives (two requests in flight), and has a quality selector (Auto / High / Medium / Low). The readout shows fps, bitrate,
  update delay and quality. A still screen shows 0-1 fps because the KX only sends changes.
- **Sessions panel:** the KX's own *Users By Port* page (per-session Disconnect / Log off, and Disconnect all); falls back to the CLI's `userlist` over SSH key login when no web login is configured (read-only then).
- **Keep-alive / auto-reconnect:** the session is re-checked every minute while the page is open; if the console
  socket drops, the page reconnects (up to 3 times in 2 minutes).
- **Accounts:** see [Accounts and rights](#accounts-and-rights). The server holds a logged-in KX admin session, so nobody
  gets in without an account, it only answers `localhost` / `127.0.0.1` Host names and same-origin requests, and it listens on
  loopback by default.

The KX allows **one remote KVM channel at a time**, so clicking a target drops the current one first.

## Setup

On the KX (Device Settings > Device Services): enable SSH, SNMP (set your own community), and Direct Port Access via URL.
Add your public SSH key to your user (User Management > Users).

On your machine (Node 20+ and net-snmp's `snmpbulkwalk` / `snmpget`, preinstalled on macOS):

```bash
cp .env.example .env   # then fill in KX_USER and KX_PASSWORD
npm start              # http://127.0.0.1:3000
npm run mock           # fake data, no KX needed
npm test               # unit and integration tests and the native-client self-test (no hardware)
```

Or in Docker: see [Docker](#docker).

**First launch:** open http://127.0.0.1:3000 **on the machine that runs the server**. With no accounts yet it opens a setup
page where you create the administrator (user name and a password of at least 10 characters). That page only works from
the machine itself, never through a reverse proxy.

| Variable | Default | Purpose |
| --- | --- | --- |
| `KX_HOST` | `172.16.0.3` | KX address |
| `KX_SNMP_COMMUNITY` | `public` | SNMP v2c community |
| `KX_USER`, `KX_PASSWORD` | | Web login used by the proxy (never sent to the browser) |
| `KX_DEVICE_ID` | `000d5d11da6a` | The `<id>` in HKC's `P_<id>_<n>` port ids; copy it from a console URL on your unit |
| `KX_SSH_USER`, `KX_SSH_KEY` | `KX_USER`, `~/.ssh/kx3_rsa` | SSH key login for the sessions panel |
| `PORT` | `3000` | Dashboard port |
| `KX_CONFIG_PATH` | `.kx-config.json` | Where PDU devices, outlet mappings and per-host settings are stored |
| `BIND` | `127.0.0.1` | Address to listen on. Beyond this machine, put HTTPS in front and set `ALLOWED_HOSTS` |
| `ALLOWED_HOSTS` | | Extra Host names (comma separated) accepted besides localhost |
| `KX_SETUP_TOKEN` | unset | A code that lets the first administrator be created from another machine (used for Docker; see below) |
| `KX_USERS_PATH` | `.kx-users.json` | Accounts (salted password hashes, owner-only) |
| `KX_AUDIT_LOG` | `.kx-audit.log` | Sign-ins, user changes, KX session actions (never passwords) |

**Harden the KX too:** the SNMP community defaults to `public`. Change it in the KX (Device Settings > Device Services),
then set the same value as `KX_SNMP_COMMUNITY`; the app does not change KX settings itself.

## Docker

The image is small (about 175 MB: Node 22 on Alpine, plus `net-snmp-tools`, `openssh-client` and `tini`), runs as an
unprivileged user, has no npm dependencies, and keeps everything it writes in one volume, `/data`.

```bash
cp .env.example .env     # set KX_HOST, KX_USER, KX_PASSWORD, KX_SNMP_COMMUNITY, KX_DEVICE_ID and KX_SETUP_TOKEN
docker compose up -d --build
```

Then open http://localhost:3000. With no accounts yet it shows the setup page; in a container every request arrives from Docker's
gateway, so it asks for the **setup code** (`KX_SETUP_TOKEN`) before creating the administrator. Once you have signed in, remove
`KX_SETUP_TOKEN` from `.env` and run `docker compose up -d` again. Without a setup code, create the first administrator from the
command line instead:

```bash
docker exec -it kx-console node auth-cli.js create-admin admin
```

- **Lost password:** `docker exec -it kx-console node auth-cli.js reset <user>`.
- **Your data** (accounts, PDU config, the KX session, audit and power logs) is in the `kx-data` volume. Back it up with
  `docker run --rm -v kx-data:/data -v "$PWD":/backup alpine tar czf /backup/kx-data.tgz -C /data .`
- **Upgrade:** `git pull && docker compose up -d --build`. **Logs:** `docker logs kx-console`.
- **Serving other machines:** the compose file publishes the port on this machine only (`127.0.0.1:3000`). To serve others change it
  to `3000:3000`, set `ALLOWED_HOSTS` to the name people browse to, and put HTTPS in front.
- **Network:** the container must reach the KX (SNMP on UDP 161, HTTPS on 443) and any PDUs (Telnet on 23). Docker Desktop on a Mac or
  Windows machine runs containers in a VM, so a KX reachable only through a VPN may not be reachable from the container. Check from
  inside: `docker exec kx-console sh -c 'snmpget -v2c -c "$KX_SNMP_COMMUNITY" -t3 -r1 "$KX_HOST" 1.3.6.1.2.1.1.5.0'`. (Do not trust `nc`
  there: Docker Desktop can report a port "open" while the destination is unreachable.) If it times out, run the container on a host
  that is on the KX network, or run the dashboard directly with `npm start`.
- **Slow console over a VPN:** set `KX_MTU` in `.env` to your tunnel's MTU (often `1280`; on a Mac check `ifconfig` for the VPN's `utun`),
  then `docker compose down && docker compose up -d`. Docker Desktop adds its own network hop, so expect a console somewhat slower than
  `npm start` on the same machine; a host on the KX network has no such limit.
- **SSH key** (only for the sessions list when no KX web login is set): uncomment the key mount in `docker-compose.yml` and set `KX_SSH_KEY`.
- `npm run docker:smoke` builds the image and checks it (health, unprivileged user, setup code, persistence, recovery CLI, clean stop) with no KX needed.

## Accounts and rights

Everyone signs in with their own account. Everyone signed in can see the hosts and their power state; **rights** decide the rest:

| Right | Lets the user |
| --- | --- |
| Open consoles (`console`) | open consoles, and end other clients' console sessions to take the KX's single channel |
| Switch power (`power`) | power on, off and cycle the outlets of hosts that are not locked |
| End other sessions (`sessions`) | disconnect or log off other sessions on the KX |
| Edit PDUs, mappings, hosts (`configure`) | add and edit PDUs, outlet mappings, per-host settings and the lock |
| Manage users (`users`) | add, edit, disable and remove users, and reset their passwords |

Roles are presets: **Administrator** (everything, and the only role that can use the KX's own admin pages through the proxy),
**Operator** (console + power), **Console only**, **Viewer** (see only), or **Custom** to tick rights one by one. Manage users in
Settings > Users. A password set by an administrator is temporary: the user must choose their own at the next sign-in. There is always at
least one active administrator, and you cannot demote, disable or remove yourself.

Passwords are stored only as salted scrypt hashes in `.kx-users.json`. Five wrong passwords lock an account and the sender for a
minute. Sessions end after 8 idle hours, or at once when the password changes or the account is disabled or removed.

**Lost your password?** Anyone who can run commands on the server can get back in:

```bash
node auth-cli.js list                  # who exists
node auth-cli.js reset <username>      # new random password, shown once; must be changed at next sign-in
node auth-cli.js create-admin <name>   # create an administrator, or promote and reset an existing user
```

A running server picks the change up immediately and signs the account out everywhere.

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
- PDU logins are stored in plain text in `.kx-config.json` and sent over unencrypted Telnet. Power off and cycle are hard cuts.
- Every user shares the dashboard's one KX login, so the KX's own session list shows the dashboard, not the person; the dashboard's audit logs (`.kx-audit.log`, `.kx-power.log`) are where individual actions are recorded.
- Without HTTPS in front, the session cookie is not marked `Secure`.
