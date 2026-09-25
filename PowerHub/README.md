<img src="images/icons/icon-192.png" width="96" alt="App icon">

# PowerHub · v3.0.1

A web dashboard for a **CyberPower UPS** (through its **RMCARD205** network card) and a **Synaccess netBooter NP-1601DU** switched PDU. Open it from any browser, iPad or iPhone on the network to:

- see whether the building has power, the UPS battery level, the remaining runtime and the load
- run a UPS self-test, and reboot or turn the UPS output off and on
- switch each of the 16 netBooter outlets on or off, power-cycle them, or switch them all at once
- name the outlets and **lock** the critical ones (modem, router, network switch, the server running PowerHub, …) so nobody can turn them off from the dashboard — they can still be power-cycled
- open the netBooter's own command line (telnet) in a **Console** window, right in the dashboard
- give each person their own **username and password** (everyone has the same rights; the event log shows who did what), and stay signed in for 30 days on each device
- keep an event log of power failures, restorations, low battery, and every command with the address it came from

```
 Screens (browser / iPad / iPhone)
          │  http://<server>:8090
          ▼
 ┌──────────────────────────┐
 │  PowerHub server         │  Docker container running server.js
 │  • serves the dashboard  │  • polls both devices, stores settings + event log
 └──────────────────────────┘
        │                         │
        ▼                         ▼
 CyberPower UPS              Synaccess netBooter NP-1601DU
 RMCARD205 · SNMP v1/v2c     HTTP or HTTPS · cmd.cgi (TCP 80 / 443)
 UDP 161                     telnet console (TCP 23)
```

Screens never talk to the equipment directly, so only the PowerHub server needs to reach the devices.

---

## Setup

### Requirements

- A computer that stays on, with **Docker** installed (or Node.js 18+).
- It needs to reach the RMCARD205 on UDP 161 and the netBooter on TCP 80 (or 443).
- **Plug that computer into a netBooter outlet you lock**, or into the UPS directly, so the dashboard can't turn itself off.

### Install

```bash
cd vibecoding/PowerHub
```
```bash
docker compose up -d --build
```

Open **http://localhost:8090**, or **http://&lt;server-ip&gt;:8090** from another device. On iPad/iPhone, use Safari's **Share → Add to Home Screen** to get an app icon.

Without Docker: `npm install`, then `npm start`.

**Try it without hardware:** `npm run mock` (or uncomment `MOCK=1` in `docker-compose.yml`) runs a simulated UPS and netBooter.

### Prepare the devices

**RMCARD205** (card's web page):
1. **Network Service › SNMPv1 Service**: enable SNMPv1.
2. Set a **read community** (default `public`) and a **write community** (default `private`), and allow the PowerHub server's IP address — or `0.0.0.0` for any — in the access list. Write access is only needed for self-test and power commands.

**netBooter NP-1601DU** (its web page):
1. Note its address (factory default `192.168.1.100`) and login (factory default `admin` / `admin` — change it).
2. Set the **reboot delay** there; PowerHub's power-cycle uses it.
3. DU models can also use HTTPS; PowerHub accepts the netBooter's self-signed certificate.
4. Avoid leaving the netBooter's own web page open: while it is, the netBooter barely answers PowerHub, and PowerHub may show it as not responding. Use PowerHub (or its Console) instead.

### Configure PowerHub

The first time you open PowerHub it asks you to **create the first user** (username, default `admin`, and a password of at least 8 characters). Do this straight away after installing: until a user exists, whoever opens the page first gets to create it. Add everyone else in **Settings › Users**.

Then open **Settings** (gear icon, top right):

| Tab | What to enter |
|---|---|
| **UPS** | Card address, SNMP version (v1 unless you've enabled v2c), read and write communities → **Test connection** |
| **netBooter** | Address, HTTP/HTTPS, username and password → **Test connection**; telnet port for the Console (default 23) |
| **Outlets** | A name for each outlet, and **Locked** for anything that must stay on (it can still be power-cycled) |
| **General** | How often the devices are read (default every 5 s) |
| **Users** | Change your own password or sign out your other devices; add users, set another user's password, or remove a user |

The UPS write community and the netBooter password are stored on the server and are never sent back to a browser.

---

## Using the dashboard

- **Top right**: one overall status: *All good*, *Check UPS* (e.g. battery needs replacing), *On battery* or *Needs attention*. A red banner appears across the top during a power failure.
- **UPS card**: battery %, runtime, load, input/output voltage, temperature. Self-test, reboot/off/on and runtime calibration are under **Power controls & details**, together with model, serial and firmware.
- **netBooter card**: total current draw and its approximate wattage, temperature, **All on / All off**, and one tile per outlet with a switch and a power-cycle button.
- **Top right**: who you're signed in as, and the sign-out button.
- **Console** (netBooter card header): the netBooter's telnet command line in a terminal window. Log in with the netBooter's username and password (PowerHub doesn't do it for you), then use e.g. `pshow`, `pset 3 1`, `rb 4`, `sysshow`, `ver`, `logout`. The buttons under the terminal send common commands. Only one console can be open at a time (opening one elsewhere closes the other), and it closes after 10 minutes without activity. **Local echo** and **Backspace = ^H** are there in case typing doesn't show or Backspace doesn't erase.
- Turning a single outlet off is immediate; power-cycling, **All off** and the UPS power controls ask for confirmation first. Locked outlets can be turned on and power-cycled, but not turned off; **All off** skips them.

---

## Technical reference

### Files

| File | Purpose |
|---|---|
| `server.js` | HTTP server, device drivers, polling, event log, settings |
| `powerhub.html` | The dashboard (single page, no build step) |
| `settings.json` | Saved settings (created on first save; in the Docker volume at `/data`) |
| `events.json` | Last 500 events (same place) |
| `sessions.json` | Signed-in devices (only a hash of each session token; same place) |

Environment: `PORT` (default 8090), `DATA_DIR` (default: app folder; `/data` in Docker), `MOCK=1`.

### CyberPower RMCARD205 — SNMP (CPS-MIB, `1.3.6.1.4.1.3808.1.1.1`)

| Read | OID suffix | | Command | OID suffix | Value |
|---|---|---|---|---|---|
| Model / name | `.1.1.1` / `.1.1.2` | | Self-test | `.7.2.2` | 2 |
| Battery status | `.2.1.1` | | Runtime calibration | `.7.2.6` | 2 (3 = cancel) |
| Capacity % | `.2.2.1` | | Flash & beep | `.6.2.5` | 2 |
| Runtime (TimeTicks) | `.2.2.4` | | Reboot UPS | `.6.2.2` | 2 |
| Replace battery | `.2.2.5` | | Output off | `.6.2.1` | 2 |
| Input V / Hz (×0.1) | `.3.2.1` / `.3.2.4` | | Output on | `.6.2.6` | 2 |
| Output status | `.4.1.1` | | | | |
| Output V / load % / A / W | `.4.2.1` / `.4.2.3` / `.4.2.4` / `.4.2.5` | | | | |

If the UPS model lacks some objects, PowerHub reads the rest one by one and shows "—" for the missing ones.

### Synaccess netBooter — HTTP

`GET /cmd.cgi?<command>` with HTTP Basic authentication, one request at a time:

| Command | Meaning | Reply |
|---|---|---|
| `$A5` | Status | `$A0,<bits>,<amps>[,<amps>],<temp>` — rightmost bit is outlet 1; temp is `XX` without a sensor |
| `$A3 n 0/1` | Outlet *n* off/on | `$A0` OK, `$AF` failed |
| `$A4 n` | Power-cycle outlet *n* | |
| `$A7 0/1` | All outlets off/on | |

### HTTP API (used by the dashboard)

Everything except `/api/health` and `/api/auth/*` needs a signed-in session (the `powerhub_session` cookie) and answers `401` otherwise. Requests that change something are refused if they come from another website.

| Method | Path | Body |
|---|---|---|
| GET | `/api/health` | — (no sign-in needed; used by the Docker health check) |
| GET | `/api/auth/status` | — → `{ usersExist, authenticated, user }` |
| POST | `/api/auth/setup` | `{ username, password }` — creates the first user, only while there are none |
| POST | `/api/auth/login` | `{ username, password }` |
| POST | `/api/auth/logout` | — |
| POST | `/api/auth/change` | `{ current, password }` — your own password; signs out your other devices |
| POST | `/api/auth/logout-others` | — signs out your other devices |
| GET | `/api/users` | — → `[{ username, created, lastSeen, devices, you }]` |
| POST | `/api/users` | `{ username, password }` — add a user |
| POST | `/api/users/<name>/password` | `{ password }` — set another user's password (signs them out) |
| DELETE | `/api/users/<name>` | — remove a user (not yourself) |
| GET | `/api/status` | — |
| GET / POST | `/api/settings` | settings object |
| POST | `/api/test` | `{ device: 'ups'\|'pdu', config }` |
| POST | `/api/ups/action` | `{ action: 'selfTest'\|'calibrate'\|'cancelCalib'\|'beep'\|'reboot'\|'turnOff'\|'turnOn' }` |
| POST | `/api/pdu/outlet` | `{ outlet: 1-16, action: 'on'\|'off'\|'reboot' }` |
| POST | `/api/pdu/all` | `{ state: 'on'\|'off' }` |
| GET / DELETE | `/api/events` | — |
| WebSocket | `/api/console` | JSON messages `{ type: 'data', data }` both ways; the server also sends `{ type: 'status', state, message }`. Same-origin and signed-in only |

The console is a plain relay to the netBooter's telnet port. PowerHub strips telnet control codes, never sends the saved password to it, and never records what is typed (the event log only notes when a console opens and closes). The terminal emulator is [xterm.js](https://xtermjs.org), served from the app itself.

### Security

- Every user has the same rights, including adding and removing users. Usernames aren't case-sensitive.
- Passwords are stored as salted scrypt hashes in `settings.json`; they are never stored or sent back in clear. A wrong username and a wrong password give the same answer and take the same time.
- Signing in sets an HttpOnly, SameSite=Strict cookie valid for 30 days after the last visit. Signing out, changing a password, removing a user or **Sign out my other devices** ends sessions immediately.
- Each wrong password waits 1 s; after 10 wrong passwords within 10 minutes, signing in is paused for 10 minutes (for everyone, since behind Docker all browsers share one address).
- PowerHub serves plain HTTP, so the password crosses your network unencrypted — keep it on a trusted network, or put it behind a reverse proxy with HTTPS.

**Forgot a password?** Another user can set a new one in **Settings › Users**. If nobody can sign in, on the server:

```bash
docker exec powerhub node server.js --reset-password admin
```
```bash
docker restart powerhub
```

The first command prints a new random password for that user (default `admin`) and signs them out everywhere; other users and device settings are untouched. Sign in with it, then change it in **Settings › Users**.

---

## Versioning

[Semantic Versioning 2.0.0](https://semver.org): MAJOR.MINOR.PATCH. The version lives in `package.json` (shown in the top bar) and in this README's title and changelog.

## Changelog

### 3.0.1 — 2026-09-25
- Settings keeps the same size on every tab: the tab bar stays put and only the content below it scrolls, with a visible scrollbar.

### 3.0.0 — 2026-09-25
- **Users**: each person signs in with their own username and password; all users have the same rights. Settings › Users (replaces Security) to change your password, sign out your other devices, and add users, set their passwords or remove them. The top bar shows who is signed in, and the event log records actions *by* user.
- The existing PowerHub password becomes the **admin** account automatically, and devices already signed in stay signed in as admin.
- `--reset-password [username]` now prints a new password for one user instead of removing all passwords.
- **Breaking (API):** `/api/auth/setup` and `/api/auth/login` take `{ username, password }`; `/api/auth/status` returns `{ usersExist, authenticated, user }` instead of `passwordSet`; new `/api/users` endpoints.

### 2.0.0 — 2026-09-25
- **Password protection**: PowerHub asks to create a password on first visit, then requires signing in (30-day sessions per device). Sign-out button in the top bar; Settings › Security to change the password or sign out other devices; `--reset-password` for a forgotten password.
- **Breaking (API):** every API endpoint and the console now need a signed-in session; new `/api/auth/*` endpoints and `/api/health` (the Docker health check now uses it).
- Requests that change something are refused when they come from another website.

### 1.3.1 — 2026-09-25
- netBooter status reads also retry after a timeout, and the netBooter is only reported as not responding after 3 failed polls in a row (about 15 s): its web server barely answers while its own web page is open.

### 1.3.0 — 2026-09-25
- Locked outlets can now be power-cycled; they still can't be turned off, and **All off** still skips them.

### 1.2.0 — 2026-09-25
- netBooter card: current draw shows the total only (no per-sensor breakdown).
- netBooter card: approximate power in watts next to the current draw, computed as amps × the mains voltage measured by the UPS (120 V if the UPS isn't available).

### 1.1.0 — 2026-09-24
- Console: the netBooter's telnet command line in a terminal window (xterm.js), with quick-command buttons, local-echo and Backspace options, one session at a time and a 10-minute idle timeout.
- Settings › netBooter: telnet port.
- Turning a single outlet off no longer asks for confirmation; the UPS **Locate (beep)** button is removed (the `beep` action remains in the API). **Self-test** moved under **Power controls & details**.
- UPS card only shows the readings the UPS model actually reports; clearer network error messages.

### 1.0.0 — 2026-09-24
- First release: CyberPower UPS monitoring and control over SNMP (RMCARD205), Synaccess netBooter NP-1601DU outlet control over HTTP/HTTPS, outlet names and locks, event log, demo mode, Docker packaging, iPhone/iPad layout.
