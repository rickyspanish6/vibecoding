<img src="images/icons/icon-192.png" width="96" alt="App icon">

# 25 Broadway — Experience Controller · v1.12.0

A web dashboard for running the AV system at 25 Broadway, NYC. From any browser or iPad on the network, operators can play scenes, power and shutter the projectors, and monitor the video-over-network devices.

**Contents**

1. [How the system fits together](#1-how-the-system-fits-together)
2. [Setup](#2-setup)
3. [Using the dashboard](#3-using-the-dashboard)
4. [Site equipment](#4-site-equipment)
5. [Running and maintaining it](#5-running-and-maintaining-it)
6. [Technical reference](#6-technical-reference)
7. [Versioning](#7-versioning)
8. [Changelog](#changelog)

---

## 1. How the system fits together

```
 Screens (browser / iPad)
          │  http://<server>:8080  — the only address a screen ever needs
          ▼
 ┌──────────────────────────┐
 │  Dashboard server        │  Docker container running proxy.js
 │  • serves the dashboard  │  • stores the settings (settings.json)
 └──────────────────────────┘
     │            │                │
     ▼            ▼                ▼
 Control Center   Projectors       Matrox ConvertIP
 (software on a   (19 × Barco)     (38 video encoders/decoders)
  Synology)       TCP 9090         HTTPS 443, signed in with the Matrox account
 HTTP 3030
```

| Component | What it is | Used for |
|---|---|---|
| **Dashboard server** | The computer running this app, in one Docker container | Serves the dashboard to every screen and relays every command |
| **Control Center** | Show-control **software**, running on a Synology | Plays the scene timelines when a scene is tapped |
| **Projectors** | 19 Barco laser projectors (**hardware**) | Power, shutter and health monitoring |
| **Matrox ConvertIP** | 38 video-over-network devices (**hardware**): 21 encoders (VEN) and 17 decoders (VDE) | Monitoring and reboots; each decoder feeds one projector |

Screens never talk to the equipment directly. The dashboard server does it for them, so a screen only needs to reach the server.

---

## 2. Setup

### Requirements

- A computer that stays on, with **Docker** installed (Docker Engine on Linux, or Docker Desktop on macOS/Windows).
- That computer must be able to reach the AV networks:

  | Network | Used by | Port |
  |---|---|---|
  | `172.16.0.x` | Control Center | 3030 |
  | `172.16.202.x` | Projectors | 9090 |
  | `172.16.201.x` | Matrox ConvertIP | 443 |

### Install

```bash
git clone https://github.com/rickyspanish6/vibecoding.git
```
```bash
cd vibecoding/25B-ExperienceController
```
```bash
docker compose up -d --build
```

Open **http://localhost:8080** on that computer, or **http://&lt;server-ip&gt;:8080** from any other screen on the network. On an iPad, use Safari's **Share → Add to Home Screen** to get an app icon.

### First-time configuration

Open **Settings** (the status/gear button, top right):

1. **Control Center**: enter the IP address of the Synology running Control Center, then press **Test connection**.
2. **Matrox ConvertIP**: enter the Matrox username and password, then press **Test connection**.
3. **Scene buttons**: enter the timeline key and value for each scene (see [Scene Library](#scene-library)).
4. Press **Save Changes**.

Settings are saved on the server, so every screen shares them. The one exception is the dashboard server address, which is saved per screen.

---

## 3. Using the dashboard

The top bar has three tabs, **Scene Library**, **Projectors** and **Signal** (the Matrox ConvertIP devices), plus one status/Settings button.

### Connection status

The button at the top right shows the overall state of the system. Tap it to open Settings, where each connection's own status appears in its section header.

| Status | Meaning |
|---|---|
| 🟢 **All connected** | Server, Control Center, projectors and Matrox are all answering |
| 🟠 **Partly connected** | Everything is reachable, but some projectors or Matrox devices aren't answering |
| 🔴 **Connection problem** | The server or Control Center is unreachable, no projectors or Matrox devices answer, or the Matrox sign-in failed |

On a desktop, hovering the button lists what's wrong. On narrow screens (iPad portrait) it shows only the dot and the gear.

The status is checked every 20 s and whenever the tab comes back into focus. The two optional South Window projectors never count as a problem.

### Scene Library

Each button plays a scene through Control Center. The playing scene is highlighted, and it's shown in the top bar and at the bottom of the sidebar.

| Section | Scenes |
|---|---|
| Tech Looks | 4 |
| Demos | 6 |
| New Looks 2026 | 12 |
| Alpha Overlay | 9 |
| Multimedia | 11 |

A scene shows **Not configured** until its timeline is set in **Settings → Scene buttons**.

**Tags** help you find scenes:

- **Filter**: tap a tag (on a card or in the filter bar) to show only scenes with that tag. You can combine tags; **Clear** resets.
- **Sort**: Default (by section), A → Z, or **By Tag**.
- **Edit**: use the tag edit button on a card (it appears when you hover, on desktop) to add or remove that scene's tags.
- **More**: the tag manager creates, renames or deletes a tag across all scenes.

### Projectors

Projectors are grouped by zone (North, South, Dome, West, East, South Window). The sidebar jumps to each zone.

**Simple / Advanced** (on the filter row) switches every projector at once. The page always opens in **Simple**, and switching never sends anything to the projectors.

**Simple mode** gives each projector two buttons. Each shows the current state, and pressing it does the opposite:

| Button | Shows | Pressing it |
|---|---|---|
| **⏻ Power** | `ON` (green) | Asks **"Power off …?"** and only powers off if you confirm. It asks every time, for every projector |
| | `OFF` | Powers on, with no confirmation |
| | `Warming up…` / `Cooling down…` / `Booting…` / `Error` / `—` | Disabled: wait, or use Advanced |
| **Shutter** | `OPEN` (blue) | Closes the shutter |
| | `CLOSED` (red) | Opens the shutter |
| | `—` | Disabled: the shutter only works while the projector is on |

**Advanced mode** is the full technical view:

- Power and shutter status badges.
- Separate **⏻ On**, **⏻ Off** and **Shutter** buttons. These have no confirmation.
- Details for each projector. Colour is used only for status: a **green dot** means OK, and the text turns **amber** or **red** only when something needs attention. Everything else is plain grey.

| Detail | Meaning |
|---|---|
| Model | `UDM-4K30` or `F80-4K12` |
| Zone / IP address | Where it is and its network address. The IP address (underlined) is a link to the projector's own web interface (port 80, opens in a new tab) |
| Connection | Whether the dashboard's link to the projector is up |
| Video feed | `Receiving` / `No stream` from its Matrox decoder (hover for the decoder's name) |
| Laser hours | Laser runtime |
| Mainboard temp | Coloured against the projector's own warning and error limits |
| Serial no. | Serial number |

**Toolbar**

| Button | Action |
|---|---|
| Power On All / Power Off All | PRJ01–PRJ17 only (South Window excluded). No confirmation |
| Toast Only | Powers on A05-PRJ11 and powers off PRJ01–PRJ17 except PRJ11. No confirmation |
| Open All / Close All Shutters | Every projector that is on or ready |
| Start / Stop Polling | Refreshes every projector every 5 s |
| Refresh All | Refreshes every projector once |

The filter row also has a **Zone** / **State** filter, a **Sort** (IP, State, Zone, Name) and **Tile / List** view.

### Signal

The Signal tab monitors the Matrox ConvertIP devices, grouped by zone. Each zone holds the **decoders (VDE)** at its projectors, and **Control Room** holds all 21 **encoders (VEN)**.

Each card shows:

| Item | Meaning |
|---|---|
| Online / Offline | Whether the device answers |
| Stream / No Stream | Whether a video stream is active |
| PTP | Shown when the device is locked to network timing |
| Temp | Green below 60 %, amber from 60 %, red from 80 % of the device's limit |
| Resolution | Configured output resolution |
| HDMI | Signal / No Signal: for an encoder, a source is connected; for a decoder, a display is connected |
| **+** | Network ports (management / media link state) and stream bitrate |

**Toolbar**

- **Reboot Selected**: tap cards to select them first.
- **Reboot All**: reboots all 38 devices.
- Both actions ask for confirmation. Devices are offline for about 30 s.
- **Start / Stop Polling** refreshes every 10 s, and **Refresh All** refreshes once. Polling starts when the dashboard loads, so each projector's Video feed is live on every tab.

Filters: **TX / RX** (encoders / decoders), **Zone** and **Status**. Sort: Name, IP, Zone or Status. Views: **Tile / List**.

### Settings

Settings is organized by what each part of the system does. Each section explains itself and shows its live status. Where there's something to verify, it has a **Test connection** button that reports **✓ Success** or **✕ Failed** with the reason.

| Section | What you set | Test connection checks | Saved |
|---|---|---|---|
| **Dashboard server** | Server address (leave blank = automatic) | This screen reaches the server, and the projector link opens | On this screen only |
| **Control Center** | IP address of the Synology running Control Center | Control Center answers on port 3030 | Server |
| **Scene buttons** | Timeline key and value per scene, plus a JSON import | (tap a scene to try it) | Server |
| **Projectors** | Nothing: the addresses are built in | Every projector answers | — |
| **Matrox ConvertIP** | Username and password | Signs in to a Matrox device with the account entered | Server |

The Matrox password is never shown again once saved. Leave the field blank to keep it.

---

## 4. Site equipment

### Projectors

| Zone | Projector | Model | IP | Notes |
|---|---|---|---|---|
| **North** | A07-PRJ01 | UDM-4K30 | 172.16.202.11 | |
| | S01-PRJ02 | UDM-4K30 | 172.16.202.12 | |
| | A06-PRJ03 | UDM-4K30 | 172.16.202.13 | |
| **South** | A02-PRJ04 | UDM-4K30 | 172.16.202.14 | |
| | N01-PRJ05 | UDM-4K30 | 172.16.202.15 | |
| | A03-PRJ06 | UDM-4K30 | 172.16.202.16 | |
| **Dome** | A06-PRJ07 | UDM-4K30 | 172.16.202.17 | |
| | A03-PRJ08 | UDM-4K30 | 172.16.202.18 | |
| **West** | A01-PRJ09 | UDM-4K30 | 172.16.202.19 | |
| | A01-PRJ10 | UDM-4K30 | 172.16.202.20 | |
| | A05-PRJ11 | UDM-4K30 | 172.16.202.21 | Kept on by **Toast Only** |
| | A05-PRJ12 | UDM-4K30 | 172.16.202.22 | |
| | A05-PRJ13 | UDM-4K30 | 172.16.202.23 | |
| **East** | A04-PRJ14 | UDM-4K30 | 172.16.202.24 | |
| | A04-PRJ15 | UDM-4K30 | 172.16.202.25 | |
| | A08-PRJ16 | UDM-4K30 | 172.16.202.26 | |
| | A08-PRJ17 | UDM-4K30 | 172.16.202.27 | |
| **South Window** | S01-PRJ18 | F80-4K12 | 172.16.202.28 | Optional: only installed sometimes |
| | S01-PRJ19 | F80-4K12 | 172.16.202.29 | Optional: only installed sometimes |

### Matrox ConvertIP

All 38 devices are SMPTE ST 2110 over 10/25 GbE SFP. Decoder *n* feeds projector PRJ*n* and sits in the same zone.

| Zone | Decoders (VDE, RX) — `172.16.201.171`–`.187` |
|---|---|
| **North** | A07-VDE01 · S01-VDE02 · A06-VDE03 |
| **South** | A02-VDE04 · N01-VDE05 · A03-VDE06 |
| **Dome** | A06-VDE07 · A03-VDE08 |
| **West** | A01-VDE09 · A01-VDE10 · A05-VDE11 · A05-VDE12 · A05-VDE13 |
| **East** | A04-VDE14 · A04-VDE15 · A08-VDE16 · A08-VDE17 |

| Zone | Encoders (VEN, TX) — `172.16.201.141`–`.161` |
|---|---|
| **Control Room** | CTL-VEN01 – CTL-VEN21 |

To change equipment or zones, edit the `PROJECTORS` / `PROJ_ZONES` and `CIP_DEVICES` / `CIP_ZONES` lists in `25broadway_dashboard.html`.

---

## 5. Running and maintaining it

### Everyday commands

Run these from the `25B-ExperienceController` folder:

| Task | Command |
|---|---|
| Start, or update after `git pull` | `docker compose up -d --build` |
| See whether it's running and healthy | `docker compose ps` |
| View logs | `docker compose logs -f` |
| Stop | `docker compose down` |
| Back up settings | `docker compose cp experience-controller:/data/settings.json ./settings.backup.json` |
| Restore settings | `docker compose cp ./settings.backup.json experience-controller:/data/settings.json` then `docker compose restart` |

- The container restarts automatically after a crash or a reboot.
- After an update, **reload every screen** that has the dashboard open, so it picks up the new version.

### Settings file

All shared settings live in a single file, `settings.json`: the Control Center address, scene timelines, tags, sort order and the Matrox account.

- **With Docker**, it's stored in the `settings` Docker volume (`/data/settings.json`), so it survives rebuilds and updates. **`docker compose down -v` deletes it.**
- It's excluded from git and is never served over the web. Back it up before moving the dashboard to another machine.

### Options

| Setting | Where | Default |
|---|---|---|
| Web port | Left side of `ports:` in `docker-compose.yml` (e.g. `"80:8080"`) | 8080 |
| `PORT` | Environment variable: the port inside the container | 8080 |
| `DATA_DIR` | Environment variable: the folder holding `settings.json` | `/data` (Docker), the app folder otherwise |

If Docker's internal network ever overlaps a site network, pin it to a free range. There's a ready-made example at the bottom of `docker-compose.yml`.

### Running without Docker

You need Node.js (any recent LTS):

```bash
npm install
```
```bash
npm start
```

`settings.json` is then created next to `proxy.js`.

---

## 6. Technical reference

### Files

```
25B-ExperienceController/
├── 25broadway_dashboard.html   Dashboard UI: HTML + CSS + JS in one file, no build step
├── proxy.js                    Server: web, WebSocket→TCP bridge, Matrox proxy, settings, status checks
├── Dockerfile                  Image (node:22-alpine, runs as non-root, health check)
├── docker-compose.yml          Service, port, restart policy, settings volume
├── manifest.webmanifest        Home-screen name and icons
├── images/                     Scene thumbnails
│   └── icons/                  App icon: source + favicon, apple-touch, 192/512, top-bar mark
├── package.json                Version (source of truth), `npm start`, dependency: ws
└── settings.json               Created on first save (git-ignored)
```

### Server API (`proxy.js`)

| Method | Path | Purpose |
|---|---|---|
| GET | `/` | The dashboard |
| GET | `/api/health` | `{ ok, version }`. CORS enabled, for the Settings server test |
| GET | `/api/settings` | Shared settings; Matrox is returned as `{ username, hasPassword }` only |
| PUT | `/api/settings` | Merges the top-level keys given: `ccIp`, `sceneMap`, `sceneTags`, `knownTags`, `sceneSortOrder`, `matrox` |
| POST | `/api/status[?fresh=1]` | Body `{ projectors: [ip…], matrox: [ip…] }` → `{ controlCenter, projectors: {ip: bool}, matrox: { devices: {ip: bool}, login } }`. Results are cached 10 s; `fresh=1` bypasses the cache |
| GET | `/api/cc/status[?ip=…]` | Control Center reachability, `{ ip, port, reachable, latencyMs, error }`. `?ip=` tests an unsaved address |
| POST | `/api/cc/trigger` | Forwards a `Task.Execute` body to Control Center. Returns `502` if unreachable |
| POST | `/api/matrox-test` | Body `{ ip, username, password }` (blank password = the saved one) → `{ reachable, signedIn, error }`. No session is kept |
| GET/POST | `/api/matrox/<ip>/<path>` | Pass-through to the device's REST API, signed in with the saved account |
| WebSocket | `/?host=<ip>&port=9090` | Bridge to a projector's TCP control port |

`settings.json` and dotfiles are never served.

### Control Center

- A scene trigger is a JSON-RPC `Task.Execute` request with `taskInternalName: "playTimeline"`, `taskCatalogName: "25b"` and the scene's `{ Key: tlKey, Value: tlValue }`.
- It's posted to `http://<Control Center>:3030/sc-datastore/projectData/taskFlow`.
- Status is a TCP connection test on port 3030.

### Projectors: Barco Pulse API

JSON-RPC 2.0 over TCP 9090 (Barco ref. TDE9629). The browser opens one WebSocket per projector at page load, and `proxy.js` bridges each one to the projector's TCP port.

**Connection lifecycle**

- Connections open at page load, staggered 150 ms apart.
- On connect, the dashboard reads the state and subscribes to changes (`property.subscribe`, **once per connection**). After that the projector pushes `property.changed` updates.
- Polling (every 5 s) only starts once the Projectors tab is opened. Laser hours and temperature are refreshed at most every 2 minutes; serial number and temperature limits are read once.
- Reconnect uses exponential backoff: 1 s → 2 s → … → 60 s.
- The optional PRJ18/19 retry every 30 s and never raise errors.

**Methods:** `property.get`, `property.set` (shutter), `property.subscribe`, `system.poweron`, `system.poweroff`.

**Properties**

| Property | Notes |
|---|---|
| `system.state` | `on` · `ready` · `standby` · `eco` · `boot` · `conditioning` · `deconditioning` · `error`. Simple mode treats `standby` / `eco` / `ready` as **Off** |
| `optics.shutter.position` / `.target` | `Open` / `Closed` (read / write) |
| `system.serialnumber` | Read once per connection |

Some properties differ by model. The dashboard maps them in `MODEL_PROPS`; each was verified with `introspect` on the real projectors:

| Metric | UDM-4K30 (PRJ01–17) | F80-4K12 (PRJ18–19) |
|---|---|---|
| Laser runtime | `statistics.laserruntime.value` (seconds) | `statistics.operating.laseron.value` (minutes) |
| Mainboard temperature | `environment.temperature.mainboard.cpu.value` | `environment.temperature.mainboard.value` |
| Temperature limits | `…mainboard.cpu.threshold.highwarning` / `.higherror` (90 / 100 °C) | `…mainboard.threshold.highwarning` / `.higherror` (80 / 83 °C) |

**Push notifications** use full property names: `{"method":"property.changed","params":{"property":[{"system.state":"on"}]}}`. As a fallback, the flat names `state`, `position` and `serialnumber` are also accepted. `value` is not accepted, because laser runtime and temperature both end in `.value` and it would be ambiguous.

**TCP framing:** `proxy.js` splits projector responses on newlines. When no newline arrives, it extracts complete JSON objects by brace depth after 10 ms of silence. This handles large responses split across TCP packets.

### Matrox ConvertIP

- REST API over HTTPS 443, with cookie authentication (`session_token`).
- `proxy.js` keeps one session per device and signs in again automatically on 401, 403, or a 200 response containing `"Not logged in"`. Changing the account in Settings drops all sessions.
- Devices are polled every 10 s from page load, staggered 150 ms apart, using `GET /device/status`.
- A reboot is `POST /device/reboot` with `Content-Type: application/json` and a `{}` body; the device returns 400 without them.
- Each decoder is linked to its projector by number (VDE*n* ↔ PRJ*n*), which drives the projector's **Video feed** detail.

### Connection status checks

| Connection | Check |
|---|---|
| Dashboard server | This screen → `GET /api/health` |
| Control Center | Server → TCP connect to port 3030 |
| Projectors | Server → TCP connect to each projector on port 9090. Projectors with a live bridge connection are counted without a new one |
| Matrox | Server → TCP connect to each device on port 443, plus a sign-in check on the first reachable device (cached 30 s) |

If the dashboard server is unreachable, the other three show **Unknown**.

---

## 7. Versioning

This project follows [Semantic Versioning 2.0.0](https://semver.org), `MAJOR.MINOR.PATCH`. Each number is a separate counter, so after 1.9.0 the next feature release is **1.10.0**.

| Part | Bumped for |
|---|---|
| **MAJOR** | Incompatible changes to the server API (`/api/*`) or the `settings.json` format, i.e. existing settings or tools would stop working |
| **MINOR** | New functionality that stays backward compatible |
| **PATCH** | Backward-compatible bug fixes only |

The version appears in four places, bumped together:
- `package.json` (the source of truth)
- the dashboard header
- the title of this README
- the changelog

---

## Changelog

### v1.12.0 — 2026-09-23
- **Change:** Clearer colours in Advanced mode — plain facts are grey, the IP address is an underlined link, and status values (Connection, Video feed, Mainboard temp) show a green dot when OK and only turn amber/red when something is wrong
- **Change:** Shutter **Open** is now **blue** everywhere (badge, Simple toggle, Open All Shutters) so it's no longer confused with power **On** (green)
- **Change:** Video feed **No stream** is shown in amber
- **Fix:** The IP address link no longer gets cut off (removed the ↗ arrow)

### v1.11.0 — 2026-09-23
- **Feature:** Advanced mode projector **IP address** is a link to the projector's web interface (`http://<ip>/`, port 80), opening in a new tab

### v1.10.0 — 2026-09-23
- **Feature:** Matrox devices are polled from page load, so each projector's **Video feed** is live without opening the Signal tab
- **Change:** The **ConvertIP** tab is renamed **Signal**
- **Fix:** Advanced mode **Video feed** no longer gets cut off — shows just `Receiving` / `No stream`; the decoder's name moved to the tooltip

### v1.9.0 — 2026-09-23
- **Feature:** ConvertIP devices grouped into sections — North, South, Dome, West, East (decoders, sorted by number) and **Control Room** (all 21 encoders) — with a sidebar link per section; replaces Senders / Receivers
- **Change:** Decoder 03 renamed `A03-VDE03` → **`A06-VDE03`** (same location as A06-PRJ03, which it feeds); A03-VDE06 moved from North to **South**; encoders' zone renamed Server Room → **Control Room**
- **Change:** Wording uses encoders (VEN) / decoders (VDE) instead of senders / receivers
- **Fix:** Removed a garbled comment left in the sidebar markup by the v1.8.0 change (no visible effect)
- **Docs:** ConvertIP inventory by section (the previous text also named the decoders `CTL-VDE…`)

### v1.8.0 — 2026-09-23
- **Feature:** Projectors grouped into six zone sections — North, South, Dome, West, East, South Window — each sorted by PRJ number, with a sidebar link per zone (replaces Multimedia / North Show)
- **Change:** A03-PRJ06 moved from North to **South**; PRJ18/19 renamed from North Show to **South Window**; zone filter includes South Window
- **Change:** Advanced mode **Model** shows the model only (e.g. `UDM-4K30`), without the manufacturer
- **Docs:** Projector inventory regrouped by zone (the previous table also listed A03-PRJ08 as North; it is Dome)

### v1.7.0 — 2026-09-23
- **Feature:** Simple mode reduced to two state toggles per projector — **Power** (ON/OFF) and **Shutter** (OPEN/CLOSED). The label shows the current feedback state; pressing sends the opposite command
- **Feature:** Power-off confirmation popup for the Simple mode Power toggle — shown every time, for every projector; powering on needs no confirmation
- **Feature:** Power toggle is disabled (with a clear label) while booting, warming up, cooling down, in error or with no feedback; Shutter toggle only works while the projector is on
- **Unchanged:** Advanced mode — status badges, discrete ⏻ On / ⏻ Off / Shutter buttons, details and command functions are identical to v1.6.0

### v1.6.0 — 2026-09-23
- **Feature:** Global **Simple / Advanced** toggle for the Projectors tab — applies to all projectors at once; defaults to Simple on every page load
- **Feature:** Advanced mode shows Model, Zone, IP address, Connection, Video feed, Laser hours, Mainboard temp and Serial no. on every card — in Tile **and** List view (List view previously had no way to see them)
- **Feature:** New **Connection** detail per projector (dashboard ↔ projector link state)
- **Change:** Removed the per-projector **+** details menu; its contents moved into Advanced mode
- **Change:** Simple mode is trimmed to operation essentials — the IP address and the Stream badge moved into Advanced (as **IP address** and **Video feed**)
- **Change:** Simple / Advanced and Tile / List moved to the right end of the filter row

### v1.5.1 — 2026-09-23
- **Fix:** Projector temperature never showed — the dashboard requested `environment.temperature.mainboard`, which doesn't exist. Now reads the mainboard sensor per model (UDM-4K30: `…mainboard.cpu.value`, F80-4K12: `…mainboard.value`)
- **Fix:** Laser hours never showed on the F80-4K12 (PRJ18/19) — it has no `statistics.laserruntime`; now reads `statistics.operating.laseron.value` (minutes)
- **Fix:** Temperature colour uses each projector's own warning/error limits (was fixed at 55/70 °C, which marked normal UDM mainboard temperatures of 55–57 °C as amber)
- **Fix:** `property.subscribe` was re-sent on every refresh (4 per projector every 5 s on the Projectors tab); now sent once per connection
- **Fix:** Removed the ambiguous flat `value` / `mainboard` push fallbacks — a temperature update could have been shown as laser hours
- **Change:** Metrics label "Temp" → "Mainboard temp"

### v1.5.0 — 2026-09-23
- **Feature:** Combined connection status merged with the Settings button (All connected / Partly connected / Connection problem)
- **Feature:** Projector connections open at page load — projector status is live without visiting the Projectors tab
- **Change:** Page tabs (Scene Library / Projectors / ConvertIP) are centered in the top bar
- **Feature:** Settings reorganised into purpose-based sections — Dashboard server, Control Center, Scene buttons, Projectors, Matrox ConvertIP — each with a plain-language description and its own live connection status
- **Feature:** **Test connection** buttons for Dashboard server, Control Center, Projectors and Matrox (sign-in test with the entered account), reporting Success / Failed with the reason
- **Feature:** App icon (Cipriani × Moment Factory) — favicon, top-bar logo, iPad/iPhone home-screen icon and `manifest.webmanifest`
- **Feature:** Server endpoints `/api/health`, `/api/status`, `/api/matrox-test`
- **Change:** Control Center address is edited in Settings only (removed from the top bar; no addresses on the main screens)
- **Change:** Scene triggers are routed through `proxy.js` (`POST /api/cc/trigger`) instead of browser → Control Center directly — consistent with the status check and no CORS dependency
- **Change:** "Proxy Host" is now **Dashboard server → Server address**; blank means automatic
- **Fix:** Terminology — Control Center (software) is no longer described as "Barco" (projector hardware)
- **Fix:** Projector connections use the port the dashboard was opened on (was hard-coded to 8080, which broke a remapped port such as `80:8080`)
- **Fix:** `.jpeg`, `.webp` and `.webmanifest` files are served with the correct content type (were `application/octet-stream`)

### v1.4.0 — 2026-09-23
- **Feature:** Settings are stored on the server (`settings.json`) and shared by every browser — scene mappings, tags, sort order, CC IP. Existing browser settings are migrated automatically on first load
- **Feature:** Matrox ConvertIP login is configurable from **Settings** (was hardcoded in `proxy.js`); password is write-only and never returned to the browser
- **Feature:** Single-container Docker deployment (`Dockerfile`, `docker-compose.yml`) with settings on a persistent volume and a health check
- **Feature:** `PORT` and `DATA_DIR` environment variables in `proxy.js`
- **Security:** `proxy.js` refuses to serve `settings.json` and dotfiles
- **Chore:** Removed the outdated "Running the Dashboard" snippet from the Settings modal
- **Chore:** Added `.gitignore` (`node_modules/`, `.DS_Store`, `settings.json`); `node_modules` no longer committed
- **Chore:** `package.json` now carries the app name/version and an `npm start` script
- **Docs:** Documented tags, Docker deployment, settings storage and API; corrected Tech Looks count

### v1.3.0 — 2026-05-08
- **Feature:** Tile / List view toggle on both Projectors and ConvertIP tabs — preference persists in `localStorage`
- **Feature:** Projector cards show a teal **Stream** badge (or grey **No Stream**) sourced from the associated Matrox RX device; association derived automatically by matching VDE number to PRJ number
- **Fix:** All Matrox ConvertIP devices showing offline after proxy restart — duplicate `const dev` declaration inside `cipPoll` caused a `SyntaxError` that silently prevented the script from loading
- **Fix:** Reboot returning HTTP 400 — Matrox devices require `Content-Type: application/json` + `{}` body on POST `/device/reboot`; both are now sent
- **Fix:** Removed per-card reboot button on ConvertIP cards; toolbar Reboot Selected / Reboot All is the single reboot path

### v1.2.0 — 2026-05-08
- **Feature:** ConvertIP tab — monitors 38 Matrox ConvertIP ST 2110 encoders/decoders (21 TX + 17 RX)
- **Feature:** Per-device cards showing Online/Offline, Stream active, PTP locked, temperature (colour-coded), configured resolution, input signal presence, and stream bitrate
- **Feature:** Reboot button per ConvertIP device (`POST /device/reboot`)
- **Feature:** `proxy.js` Matrox HTTPS proxy — cookie-based auth with automatic re-login on session expiry (handles both HTTP 401/403 and 200 "Not logged in" responses)
- **Fix:** `Content-Type: application/json` no longer sent on GET requests (caused HTTP 400 from Matrox devices)
- **Fix:** PRJ18 and PRJ19 (North Show F80-4K12) marked `optional` — disconnection is silently ignored, reconnect retried every 30 s
- **Fix:** Barco WebSocket bridge log prefix changed from `[Proxy]` to `[Barco]`

### v1.1.0 — 2026-05-07
- **Fix:** Bulk Power On / Off now targets Multimedia projectors 1–17 only; North Show (18–19) excluded
- **Fix:** `statistics.laserruntime.value` is in seconds — divide by 3600 for hours display
- **Fix:** Correct property names from Barco Pulse API ref (TDE9629): `statistics.laserruntime.value`, `environment.temperature.mainboard`, `system.serialnumber`
- **Fix:** Projector models corrected — 1–17: UDM-4K30, 18–19: F80-4K12
- **Feature:** Expandable `+` metrics panel per card (Model · Laser Hrs · Temp · S/N); values persist across power state changes
- **Feature:** Metrics panel layout changed to vertical rows (label / value)
- **Feature:** Serial number (`system.serialnumber`) fetched once per connection and displayed in metrics panel
- **Perf:** Shutter, laser runtime, and temperature fetched in parallel via `Promise.all`
- **Perf:** Laser runtime and temperature throttled to every 2 minutes (`METRICS_POLL_MS`); shutter polls every 5 s
- **Perf:** WebSocket reconnect uses exponential backoff (1 s → 2 s → … → 60 s cap)

### v1.0.0 — initial
- Scene Library: 5 sections (Tech Looks, Demos, New Looks 2026, Alpha Overlay, Multimedia) triggering Control Center via `Task.Execute` JSON-RPC
- Projectors tab: 19 projectors, power / shutter control, filter / sort, bulk actions, 5 s auto-poll
- `proxy.js`: HTTP file server + WebSocket → Barco TCP bridge with JSON boundary detection
