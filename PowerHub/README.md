<img src="images/icons/icon-192.png" width="96" alt="App icon">

# PowerHub · v1.0.0

A web dashboard for a **CyberPower UPS** (through its **RMCARD205** network card) and a **Synaccess netBooter NP-1601DU** switched PDU. Open it from any browser, iPad or iPhone on the network to:

- see whether the building has power, the UPS battery level, the remaining runtime and the load
- run a UPS self-test, make the UPS beep so you can find it, and reboot or turn the UPS output off and on
- switch each of the 16 netBooter outlets on or off, power-cycle them, or switch them all at once
- name the outlets and **lock** the critical ones (network switch, the server running PowerHub, …) so nobody can turn them off from the dashboard
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
 RMCARD205 · SNMP v1/v2c     HTTP or HTTPS · cmd.cgi
 UDP 161                     TCP 80 / 443
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

### Configure PowerHub

Open **Settings** (gear icon, top right):

| Tab | What to enter |
|---|---|
| **UPS** | Card address, SNMP version (v1 unless you've enabled v2c), read and write communities → **Test connection** |
| **netBooter** | Address, HTTP/HTTPS, username and password → **Test connection** |
| **Outlets** | A name for each outlet, and **Locked** for anything that must stay on |
| **General** | How often the devices are read (default every 5 s) |

The UPS write community and the netBooter password are stored on the server and are never sent back to a browser.

---

## Using the dashboard

- **Top right**: one overall status: *All good*, *Check UPS* (e.g. battery needs replacing), *On battery* or *Needs attention*. A red banner appears across the top during a power failure.
- **UPS card**: battery %, runtime, load, input/output voltage, temperature. **Self-test** and **Locate (beep)** are always there. Reboot/off/on and runtime calibration are under **Power controls & details**, together with model, serial and firmware.
- **netBooter card**: current draw (per bank on DU models), temperature, **All on / All off**, and one tile per outlet with a switch and a power-cycle button.
- Anything that cuts power asks for confirmation first. Locked outlets can be turned on but not off or power-cycled; **All off** skips them.

---

## Technical reference

### Files

| File | Purpose |
|---|---|
| `server.js` | HTTP server, device drivers, polling, event log, settings |
| `powerhub.html` | The dashboard (single page, no build step) |
| `settings.json` | Saved settings (created on first save; in the Docker volume at `/data`) |
| `events.json` | Last 500 events (same place) |

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

| Method | Path | Body |
|---|---|---|
| GET | `/api/status` | — |
| GET / POST | `/api/settings` | settings object |
| POST | `/api/test` | `{ device: 'ups'\|'pdu', config }` |
| POST | `/api/ups/action` | `{ action: 'selfTest'\|'calibrate'\|'cancelCalib'\|'beep'\|'reboot'\|'turnOff'\|'turnOn' }` |
| POST | `/api/pdu/outlet` | `{ outlet: 1-16, action: 'on'\|'off'\|'reboot' }` |
| POST | `/api/pdu/all` | `{ state: 'on'\|'off' }` |
| GET / DELETE | `/api/events` | — |

**Security:** like the other dashboards in this repo, PowerHub has no login of its own. Anyone who can open the page can switch outlets, so keep it on a trusted network.

---

## Versioning

[Semantic Versioning 2.0.0](https://semver.org): MAJOR.MINOR.PATCH. The version lives in `package.json` (shown in the top bar) and in this README's title and changelog.

## Changelog

### 1.0.0 — 2026-09-24
- First release: CyberPower UPS monitoring and control over SNMP (RMCARD205), Synaccess netBooter NP-1601DU outlet control over HTTP/HTTPS, outlet names and locks, event log, demo mode, Docker packaging, iPhone/iPad layout.
