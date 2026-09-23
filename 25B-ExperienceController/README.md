<img src="images/icons/icon-192.png" width="96" alt="App icon">

# 25 Broadway — Experience Controller · v1.20.0

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
3. **Scene buttons**: press **Export JSON**, fill in the timeline key and value for each scene, then **Import JSON** (see [Import and export](#import-and-export)).
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

A scene shows **Not configured** until it has a timeline, imported in **Settings → Scene buttons**.

**Tags** help you find scenes:

- **Filter**: tap a tag (on a card or in the filter bar) to show only scenes with that tag. You can combine tags; **Clear** resets.
- **Sort**: Default (by section), **Name**, or **By Tag**. The direction button next to it switches **↑ A** (A first) / **↓ Z** (Z first).
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
| | `Warming…` / `Cooling…` / `Booting…` / `Error` / `—` | Disabled: wait, or use Advanced |
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
| Illumination | Actual laser output in %, including any power limits |
| Video feed | `Receiving` / `No stream` from its Matrox decoder (hover for the decoder's name) |
| Ambient / Mainboard | Air-intake and mainboard temperatures, side by side. Each is coloured against the projector's own warning and error limits for that sensor (hover to see them) |
| Laser hours | Laser runtime |
| Serial no. | Serial number |

**Toolbar**

| Button | Action |
|---|---|
| Power On All / Power Off All | PRJ01–PRJ17 only (South Window excluded). No confirmation |
| Toast Only | Powers on A05-PRJ11 and powers off PRJ01–PRJ17 except PRJ11. No confirmation |
| Open All / Close All Shutters | Every projector that is on or ready |
| Start / Stop Polling | Refreshes every projector every 5 s |
| Refresh All | Refreshes every projector once |

The filter row also has a **Zone** / **State** filter, a **Sort** and **Tile / List** view. Choosing a sort (IP, State, Zone or Name) shows all projectors as **one list, without the zone sections**; **Default** brings the zone sections back. In **Advanced** mode you can also sort by **Ambient temp**, **Mainboard temp**, **Laser hours** or **Illumination**; these start highest first, projectors without a reading go last, and the list re-sorts as readings change. The direction button next to Sort shows which end comes first — **↑ Low** or **↓ High** (**↑ A** / **↓ Z** for names) — and flips it. These sorts disappear in Simple mode (switching back returns to Default). Filters still apply while sorted, and clicking a zone in the sidebar returns to Default.

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

Filters: **TX / RX** (encoders / decoders), **Zone** and **Status**. Sort: Name, IP, Zone or Status, with the same direction button. Views: **Tile / List**.

### Projector report

**Settings → Projector report** is a focused report on the projector fleet, taken fresh each time it's opened (**Refresh** takes a new one).

- **Header:** number of projectors, how many answer, the rated laser life (**20,000 h** — every projector here, UDM-4K30 and F80-4K12, is rated 20,000 h by Barco in normal mode) and the fleet's average use.
- **Summary:** "All projectors are healthy", or the projector issues that need attention — not reachable, a warning or error reported by the projector (with its own reason, e.g. *Pump fan RPM*), hot temperatures, aging or end-of-life lasers.
- **Aging:** for each projector — zone, model, install date, laser hours, % of rated life used (bar) and status:

  | Status | Rated life used |
  |---|---|
  | **Good** | below 70 % |
  | **Aging** (amber) | from 70 % |
  | **EOL** (red) | from 90 % — **flashes** from 100 % |

- **Health:** each projector's own self-check (**Normal** / **Warning** / **Error**, with the reason and since when), air-intake and mainboard temperatures against its limits, illumination, power and shutter. The F80-4K12 units don't report health.

**Export PDF** on each section (Aging, Health) opens a standalone, print-ready report and the print dialog — choose **Save as PDF** (on iPad: Share → Print, then share the preview as PDF). Each PDF has the logo, title, date and time of the readings, a summary, what needs attention, the full table and a short explanation, so it can be sent to someone without access to the dashboard. If nothing opens, allow pop-ups for the dashboard.

The report shows the current state only; readings are not recorded over time.

### Settings

Settings is organized by what each part of the system does. Each section shows what it is and its live status on the left, and its fields and buttons on the right. Where there's something to verify, it has a **Test connection** button that reports **✓ Success** or **✕ Failed** with the reason.

| Section | What you set | Test connection checks | Saved |
|---|---|---|---|
| **Dashboard server** | Server address (leave blank = automatic) | This screen reaches the server, and the projector link opens | On this screen only |
| **Control Center** | IP address of the Synology running Control Center | Control Center answers on port 3030 | Server |
| **Scene buttons** | The scene timelines (export / import JSON) | (tap a scene to try it) | Server |
| **Projectors** | The projector list (export / import JSON) | Every projector answers | Server |
| **Matrox ConvertIP** | Username and password; the device list (export / import JSON) | Signs in to a Matrox device with the account entered | Server |
| **Project backup** | Export / import everything above in one file | — | — |

The Matrox password is never shown again once saved. Leave the field blank to keep it.

### Import and export

Scene timelines, the projector list and the Matrox device list are all edited the same way: **Export JSON**, edit the file, **Import JSON**.

- **Scene buttons** shows how many scenes have a timeline. The export lists every scene (name, section, key) with its timeline key and value; blank ones are not configured. Importing replaces all timelines. The older `{ "artnyc": { "tlKey": …, "tlValue": … } }` format is also accepted.
- **Projectors** and **Matrox ConvertIP** each show which list is in use (built-in or imported), and offer **Restore built-in list** when an imported list is active.
- **Project backup → Export project** saves everything in Settings to one file: Control Center address, scene timelines, tags, sort order, both device lists and the Matrox username. **Import project** loads it back.
- **The Matrox password is never exported.** After importing a project on a new machine, enter it again in Settings.
- Every import is checked first: valid JSON, the right kind of file, and for scenes known scene keys and numeric values; for device lists valid IP addresses, known projector models, no duplicate names or addresses, and a number in every name. If anything is wrong, nothing is saved and the reason is shown.
- Before anything is replaced, a confirmation lists what the file contains. Scene timelines apply immediately; after a device-list import the screen reloads. Other open screens pick up changes when they reload.

The file formats are described under [File formats](#file-formats).

---

## 4. Site equipment

### Projectors

| Zone | Projector | Model | IP | Installed | Notes |
|---|---|---|---|---|---|
| **North** | A07-PRJ01 | UDM-4K30 | 172.16.202.11 | Jan 2025 | |
| | S01-PRJ02 | UDM-4K30 | 172.16.202.12 | Jan 2025 | |
| | A06-PRJ03 | UDM-4K30 | 172.16.202.13 | Jan 2025 | |
| **South** | A02-PRJ04 | UDM-4K30 | 172.16.202.14 | Jan 2025 | |
| | N01-PRJ05 | UDM-4K30 | 172.16.202.15 | Jan 2025 | |
| | A03-PRJ06 | UDM-4K30 | 172.16.202.16 | Jan 2025 | |
| **Dome** | A06-PRJ07 | UDM-4K30 | 172.16.202.17 | Jan 2025 | |
| | A03-PRJ08 | UDM-4K30 | 172.16.202.18 | Jan 2025 | |
| **West** | A01-PRJ09 | UDM-4K30 | 172.16.202.19 | Jan 2025 | |
| | A01-PRJ10 | UDM-4K30 | 172.16.202.20 | Jan 2025 | |
| | A05-PRJ11 | UDM-4K30 | 172.16.202.21 | Jan 2025 | Kept on by **Toast Only** |
| | A05-PRJ12 | UDM-4K30 | 172.16.202.22 | Jan 2025 | |
| | A05-PRJ13 | UDM-4K30 | 172.16.202.23 | Jan 2025 | |
| **East** | A04-PRJ14 | UDM-4K30 | 172.16.202.24 | Jan 2025 | |
| | A04-PRJ15 | UDM-4K30 | 172.16.202.25 | Jan 2025 | |
| | A08-PRJ16 | UDM-4K30 | 172.16.202.26 | Jan 2025 | |
| | A08-PRJ17 | UDM-4K30 | 172.16.202.27 | Jan 2025 | |
| **South Window** | S01-PRJ18 | F80-4K12 | 172.16.202.28 | Unknown | Optional: only installed sometimes |
| | S01-PRJ19 | F80-4K12 | 172.16.202.29 | Mar 2026 | Optional: only installed sometimes |

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

These are the **built-in lists**. To change equipment, names or zones, export the list from Settings, edit the JSON and import it back (see [Import and export](#import-and-export)). **Restore built-in list** returns to the tables above.

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

All shared settings live in a single file, `settings.json`: the Control Center address, scene timelines, tags, sort order, imported device lists and the Matrox account.

The easiest backup is **Settings → Project backup → Export project** (everything except the Matrox password). The commands above copy the raw file, password included.

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
| PUT | `/api/settings` | Merges the top-level keys given: `ccIp`, `sceneMap`, `sceneTags`, `knownTags`, `sceneSortOrder`, `projectorConfig`, `cipConfig` (`null` = built-in list), `matrox` |
| POST | `/api/status[?fresh=1]` | Body `{ projectors: [ip…], matrox: [ip…] }` → `{ controlCenter, projectors: {ip: bool}, matrox: { devices: {ip: bool}, login } }`. Results are cached 10 s; `fresh=1` bypasses the cache |
| GET | `/api/cc/status[?ip=…]` | Control Center reachability, `{ ip, port, reachable, latencyMs, error }`. `?ip=` tests an unsaved address |
| POST | `/api/cc/trigger` | Forwards a `Task.Execute` body to Control Center. Returns `502` if unreachable |
| POST | `/api/matrox-test` | Body `{ ip, username, password }` (blank password = the saved one) → `{ reachable, signedIn, error }`. No session is kept |
| GET/POST | `/api/matrox/<ip>/<path>` | Pass-through to the device's REST API, signed in with the saved account |
| WebSocket | `/?host=<ip>&port=9090` | Bridge to a projector's TCP control port |

`settings.json` and dotfiles are never served. When serving the dashboard page, `proxy.js` fills in `window.SERVER_CONFIG` with the saved device lists, so they're available before the page's script runs.

### File formats

All exports are JSON with a `type` field. A projector list (`25b-projectors`):

```json
{
  "type": "25b-projectors", "version": 1,
  "zones": ["North", "South", "Dome", "West", "East", "South Window"],
  "projectors": [
    { "name": "A07-PRJ01", "model": "UDM-4K30", "ip": "172.16.202.11", "zone": "North", "bulkPower": true },
    { "name": "A05-PRJ11", "model": "UDM-4K30", "ip": "172.16.202.21", "zone": "West",  "bulkPower": true, "toast": true },
    { "name": "S01-PRJ18", "model": "F80-4K12", "ip": "172.16.202.28", "zone": "South Window", "bulkPower": false, "optional": true }
  ]
}
```

| Projector field | Meaning |
|---|---|
| `name` | Shown on the card. Must contain a number; projector *n* is linked to Matrox decoder *n* |
| `model` | `UDM-4K30` or `F80-4K12` (decides which properties are read) |
| `ip`, `zone` | Control address and the section it appears in |
| `bulkPower` | Included in Power On All / Power Off All (default: `true` unless optional) |
| `optional` | Only installed sometimes: never raises errors, retries every 30 s |
| `toast` | The one projector **Toast Only** keeps on |
| `installed` | Install date as `"YYYY-MM"` (e.g. `"2025-01"`), shown in the Projector report; leave empty or `null` if unknown |

A scene list (`25b-scenes`) has `scenes: [{ "key": "artnyc", "label": "ArtNYC", "section": "New Looks 2026", "tlKey": "Timeline 03", "tlValue": 210 }, …]`. `key` must match a scene in the dashboard; `label` and `section` are only there to help you read the file. Leave `tlKey` empty and `tlValue` `null` for a scene with no timeline.

A Matrox list (`25b-convertip`) has `devices: [{ "name": "A07-VDE01", "ip": "172.16.201.171", "type": "rx", "zone": "North" }, …]`, with `type` `"tx"` (encoder) or `"rx"` (decoder).

A project file (`25b-project`) wraps `settings: { ccIp, sceneMap, sceneTags, knownTags, sceneSortOrder, matroxUsername, projectors, convertip }`, where each list also carries `"source": "built-in" | "imported"`. `zones` gives the section order; any zone used by a device but missing from `zones` is added at the end.

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

**Methods:** `property.get`, `property.set` (shutter), `property.subscribe`, `system.poweron`, `system.poweroff`, and — for the Projector report — `environment.getalarminfo` (read-only: severity, source, time and description of active alarms).

**Properties**

| Property | Notes |
|---|---|
| `system.state` | `on` · `ready` · `standby` · `eco` · `boot` · `conditioning` · `deconditioning` · `error`. Simple mode treats `standby` / `eco` / `ready` as **Off** |
| `optics.shutter.position` / `.target` | `Open` / `Closed` (read / write) |
| `system.serialnumber` | Read once per connection |
| `system.health` | `Normal` / `Warning` / `Error` self-check, read by the Projector report (UDM-4K30 only; the F80-4K12 doesn't have it) |
| `illumination.sources.laser.actualpower` | Actual laser output in % (with limits). Read each refresh while on, and subscribed |

Some properties differ by model. The dashboard maps them in `MODEL_PROPS`; each was verified with `introspect` on the real projectors:

| Metric | UDM-4K30 (PRJ01–17) | F80-4K12 (PRJ18–19) |
|---|---|---|
| Laser runtime | `statistics.laserruntime.value` (seconds) | `statistics.operating.laseron.value` (minutes) |
| Mainboard temperature | `environment.temperature.mainboard.cpu.value` | `environment.temperature.mainboard.value` |
| Mainboard limits | `…mainboard.cpu.threshold.highwarning` / `.higherror` (90 / 100 °C) | `…mainboard.threshold.highwarning` / `.higherror` (80 / 83 °C) |
| Ambient temperature | `environment.temperature.ambient_outside.value` | `environment.temperature.inlet.value` (the F80 has no `ambient_outside`; `inlet` is its air-intake sensor) |
| Ambient limits | `…ambient_outside.threshold.highwarning` / `.higherror` (43 / 58 °C) | `…inlet.threshold.highwarning` / `.higherror` (45 / 50 °C) |

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

### v1.20.0 — 2026-09-23
- **Feature:** **Projector report** page in Settings — fleet header (rated life 20,000 h, average use), summary of projector issues, **Aging** (install date, laser hours, % of rated life: Good < 70 %, **Aging** ≥ 70 %, **EOL** ≥ 90 % in red, flashing ≥ 100 %) and **Health** (each projector's own self-check via `system.health`, with the reason from `environment.getalarminfo`, temperatures, illumination, power). Fresh readings each time it's opened
- **Feature:** **Export PDF** for the Aging and Health sections — standalone, print-ready report with logo, title, timestamp, summary, issues, table and explanation, for sharing outside the team
- **Feature:** Projector install dates (`installed`, `YYYY-MM`) in the projector list and its JSON format — built-in: UDM-4K30 units Jan 2025, S01-PRJ18 unknown, S01-PRJ19 Mar 2026

### v1.19.1 — 2026-09-23
- **Change:** Sort direction button simplified to one word and a vertical arrow — **↑ Low** / **↓ High** (**↑ A** / **↓ Z** for names); the full meaning is in its tooltip

### v1.19.0 — 2026-09-23
- **Feature:** A sort direction button next to every Sort menu (Projectors, Signal, Scene Library) — shows **↑ Low → High** / **↓ High → Low** (or **A → Z** / **Z → A** for names) and flips the order; disabled on Default
- **Change:** Projector reading sorts (temperatures, laser hours, illumination) start highest first; other sorts start low → high. Scene Library's "A → Z" sort is now **Name**, with the direction on the button

### v1.18.0 — 2026-09-23
- **Feature:** Advanced mode sorts — **Ambient temp**, **Mainboard temp**, **Laser hours** and **Illumination**, highest first, re-sorting live as readings change. Only offered in Advanced; switching to Simple while one is active returns to Default

### v1.17.0 — 2026-09-23
- **Change:** Sorting projectors (IP, State, Zone, Name) shows one flat list, ignoring the zone sections; **Default** returns to the zone sections. Filters still apply while sorted
- **Change:** Sort by Zone follows the zone order (North, South, Dome, West, East, South Window) instead of alphabetical
- **Change:** Clicking a zone in the sidebar while sorted switches back to Default so the zone is visible

### v1.16.0 — 2026-09-23
- **Feature:** Advanced mode shows each projector's **Ambient** (air intake) temperature — `environment.temperature.ambient_outside.value` on the UDM-4K30, `environment.temperature.inlet.value` on the F80-4K12 (which has no `ambient_outside`) — coloured against that sensor's own limits
- **Change:** Removed the **Laser** (On / Off) detail; **Illumination** stays
- **Change:** "Mainboard temp" is now **Mainboard** (fits on one line) and sits on the same row as Ambient

### v1.15.2 — 2026-09-23
- **Fix:** Simple mode Power / Shutter buttons no longer overflow — in List view they have inner padding and a fixed, equal width; in Tile view the label sits above the state (e.g. ⏻ Power / WARMING…). Long states shortened to `Warming…` / `Cooling…`

### v1.15.1 — 2026-09-23
- **Change:** Wider, less cluttered Settings — each section shows what it is (and its live status) on the left and its fields and buttons on the right; **Test connection** sits next to its field; Matrox username and password side by side. Stacks to one column on narrow screens

### v1.15.0 — 2026-09-23
- **Feature:** Scene timelines use the same **Export JSON / Import JSON** as the device lists; the export lists every scene with its section, key and timeline, and imports are validated and confirmed
- **Change:** Removed the per-scene timeline key / value fields and the "Import many at once" box from Settings; **Scene buttons** now shows how many scenes have a timeline
- **Fix:** **Save Changes** no longer rewrites the scene timelines, so it can't undo a newer import made from another screen

### v1.14.0 — 2026-09-23
- **Feature:** Export / import the **projector list** and the **Matrox device list** as JSON from Settings, with **Restore built-in list**; the active list (built-in or imported) is shown in each section
- **Feature:** **Project backup** — export / import all settings in one file (Control Center address, scene timelines, tags, both device lists, Matrox username). The Matrox password is never exported
- **Feature:** Imports are validated (JSON, file type, IP addresses, models, duplicates) and confirmed before anything is replaced
- **Change:** Device lists are now settings (`projectorConfig`, `cipConfig` in `settings.json`); the lists built into the dashboard are the defaults, so existing installs are unchanged
- **Change:** "Toast Only" uses a `toast` flag on A05-PRJ11 instead of a fixed internal number; decoder ↔ projector links match by the number in the name

### v1.13.0 — 2026-09-23
- **Feature:** Advanced mode shows each projector's **Laser** status (`illumination.state`: On / Off, amber if the projector is on but the laser is off) and **Illumination** level (`illumination.sources.laser.actualpower`, actual output in %), updated live

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
