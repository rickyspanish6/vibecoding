<img src="images/icons/icon-192.png" width="96" alt="App icon">

# 25 Broadway — Experience Controller · v1.9.0

Local web dashboard for AV control at 25 Broadway, NYC.  
Three tabs: **Scene Library** (plays scenes through **Control Center**, the show-control software), **Projectors** (monitors and controls the 19 **Barco** laser projectors), and **ConvertIP** (monitors the 38 **Matrox** ConvertIP video encoders/decoders).

### System at a glance

| Component | What it is | Who talks to it |
|---|---|---|
| **Dashboard server** | The computer running this app (Docker / `proxy.js`) | Every screen (browser, iPad) |
| **Control Center** | Show-control **software** (runs on a Synology) that plays the scene timelines | Dashboard server → port 3030 |
| **Projectors** | Barco projector **hardware**, controlled over the Barco Pulse API | Dashboard server → port 9090 |
| **Matrox ConvertIP** | Video-over-network **hardware** (encoders/decoders) | Dashboard server → HTTPS, signed in with the Matrox account |

Screens only ever talk to the dashboard server; it relays everything else.

---

## Files

```
25B-ExperienceController/
├── 25broadway_dashboard.html   # Full dashboard UI — HTML + CSS + JS, no build step
├── proxy.js                    # Node.js server: serves HTML on :8080, bridges WS → Barco TCP :9090,
│                               #   proxies HTTPS → Matrox ConvertIP REST API, stores shared settings
├── settings.json               # Created on first save — shared settings + Matrox login (git-ignored)
├── Dockerfile                  # Single-container image (node:22-alpine)
├── docker-compose.yml          # One-command deploy, settings on a named volume
├── manifest.webmanifest        # Home-screen app name + icons (iPad "Add to Home Screen")
├── images/                     # Scene thumbnails
│   └── icons/                  # App icon: source + favicon, apple-touch, 192/512, top-bar mark
├── package.json
└── node_modules/ws/            # Only dependency (git-ignored — run npm install)
```

The dashboard is intentionally a **single HTML file**. There is no bundler, no framework, no build step. This keeps deployment simple — copy the folder, run one command.

---

## Requirements

- **Docker** (recommended) — Docker Engine on Linux, or Docker Desktop on macOS/Windows
- or **Node.js** (any recent LTS) to run without Docker
- The **server** (the machine running Docker / `proxy.js`) needs network access to the Barco subnet (`172.16.202.x`) and Control Center (`172.16.0.x`, port 3030)
- Network access to the Matrox ConvertIP subnet (`172.16.201.x`)

---

## Deploy with Docker (recommended)

The whole stack is one container: dashboard, Barco WebSocket → TCP bridge, Matrox proxy and settings store.

```bash
docker compose up -d --build
```

That's it — the container restarts automatically after reboots/crashes (`restart: unless-stopped`) and reports its health in `docker compose ps`.

| Task | Command |
|---|---|
| Update after `git pull` | `docker compose up -d --build` |
| View logs | `docker compose logs -f` |
| Stop | `docker compose down` |
| Back up settings | `docker compose cp experience-controller:/data/settings.json ./settings.backup.json` |
| Restore / import settings | `docker compose cp ./settings.json experience-controller:/data/settings.json` then `docker compose restart` |

- **Settings persist** in the `settings` Docker volume (`/data/settings.json` inside the container), so rebuilding or updating the container keeps them. `docker compose down -v` **deletes** them.
- **Moving from a plain `node proxy.js` install:** start the container, then import your existing `settings.json` with the restore command above.
- **Network:** the container reaches the AV subnets through the host. The host running Docker needs the same network access listed in Requirements. If Docker's internal subnet ever clashes with a site network, pin it — see the comment at the bottom of `docker-compose.yml`.
- **Environment variables:** `PORT` (default `8080`) and `DATA_DIR` (default `/data` in Docker, the app folder otherwise). To use a different host port, change the left side of `ports:` in `docker-compose.yml` (e.g. `"80:8080"`).

## Run without Docker

```bash
npm install        # installs the ws package (one-time)
npm start          # starts the server (same as: node proxy.js)
```

`settings.json` is created next to `proxy.js`.

Open **http://localhost:8080** in a browser on the same machine, or **http://&lt;server-ip&gt;:8080** from another device on the network.

On a fresh install, open **Settings**, enter the **Control Center address** and the **Matrox account**, and use each section's **Test connection** button to confirm.

---

## Settings

**Settings** (the status/gear button, top-right) is organised by what each part of the system does. Every section says what it is and what it connects to, shows that connection's **live status** in its header, and — where there is something to check — has a **Test connection** button that reports **✓ Success** or **✕ Failed** with the reason.

| Section | Purpose | Settings | Test connection checks | Stored |
|---|---|---|---|---|
| **Dashboard server** | The computer running the dashboard; relays every command | Server address (blank = automatic) | This screen can reach the server, and the projector link (WebSocket) opens | This screen only |
| **Control Center** | Show-control software that plays scenes | Control Center address (IP of the Synology running it) | The server gets an answer from Control Center on port 3030 | Server |
| **Scene buttons** | Which Control Center timeline each scene plays | Timeline key + value per scene, JSON import | — (play a scene) | Server |
| **Projectors** | The 19 Barco projectors; addresses are built in | None | The server gets an answer from each projector on port 9090 | — |
| **Matrox ConvertIP** | The 38 video encoders/decoders | Username, password | The server signs in to a Matrox device with the entered account (tries up to 3 devices) | Server |

Other preferences — scene tags, sort order (server) and Tile/List view (this screen) — are set where they are used.

- **Matrox password** is write-only: it is never sent back to the browser. Leave the field blank to keep the current one; **Test connection** then uses the saved password. Changing the account drops all Matrox sessions so the next poll signs in with the new one.
- **`settings.json` is git-ignored** and never served over HTTP. Back it up when moving the dashboard to a new machine — it's the whole configuration.
- **Migration:** the first time a browser with older `localStorage` settings opens a server that has no scene data yet, its settings are copied to the server automatically.
- If the page is opened without `proxy.js` running, the dashboard falls back to the last settings cached in that browser.

## Connection status

The top-right button combines the **overall status** and **Settings** (gear). Tap it to open Settings, where each connection's own status is shown in its section header.

| Top bar | Meaning |
|---|---|
| 🟢 All connected | Server, Control Center, projectors and Matrox all OK |
| 🟠 Partly connected | Everything reachable, but some projectors or Matrox devices aren't answering |
| 🔴 Connection problem | Server or Control Center disconnected, no projectors/Matrox answering, or Matrox sign-in failed |

Hover (desktop) lists what's wrong. On narrow screens (iPad portrait) it shows the dot and gear only.

Individual connections (shown in Settings):

| Connection | Checks |
|---|---|
| **Dashboard server** | This screen → dashboard server |
| **Control Center** | Dashboard server → Control Center, port 3030 |
| **Projectors** | Dashboard server → each Barco projector, port 9090 (the 2 optional South Window units never count as a problem) |
| **Matrox** | Dashboard server → each Matrox device + sign-in with the saved account |

- Checked every 20 s, when the tab comes back into focus, and after a failed scene.
- If the dashboard server is unreachable, the other connections show **Unknown** — they can't be verified without it.
- Checks are cached for 10 s on the server so several open screens don't multiply them; projectors that already have a live connection are counted without opening a new one.

### Server API

| Method | Path | Notes |
|---|---|---|
| GET | `/api/settings` | Returns all shared settings; Matrox returned as `{ username, hasPassword }` |
| PUT | `/api/settings` | Merges the top-level keys given (`ccIp`, `sceneMap`, `sceneTags`, `knownTags`, `sceneSortOrder`, `matrox`) |
| GET | `/api/health` | `{ ok, version }` — dashboard server is up (CORS enabled for the Settings test) |
| POST | `/api/status[?fresh=1]` | Body `{ projectors: [ip…], matrox: [ip…] }` → `{ controlCenter, projectors: {ip: bool}, matrox: { devices: {ip: bool}, login } }`. `fresh=1` skips the 10 s cache |
| GET | `/api/cc/status[?ip=…]` | Control Center reachability for the saved address, or `?ip=` to test another: `{ ip, port, reachable, latencyMs, error }` |
| POST | `/api/matrox-test` | Body `{ ip, username, password }` (blank password = saved) → `{ reachable, signedIn, error }`; session is not kept |
| POST | `/api/cc/trigger` | Forwards a `Task.Execute` JSON-RPC body to the saved Control Center address; `502` if unreachable |

---

## Architecture

```
Browser (localhost:8080)
│
│  HTTP GET /                     → proxy.js serves 25broadway_dashboard.html
│
│  Settings (all tabs)
│  HTTP GET|PUT /api/settings     → proxy.js reads/writes settings.json (DATA_DIR)
│
│  Scene trigger (Scene Library tab)
│  HTTP POST /api/cc/trigger
│      │
│      └─► proxy.js forwards to http://<Control Center address>:3030/sc-datastore/projectData/taskFlow
│              method: Task.Execute  (Control Center JSON-RPC)
│
│  Connection status (top bar, every 20 s)
│  HTTP GET  /api/health           → dashboard server is reachable from this screen
│  HTTP POST /api/status           → proxy.js checks Control Center :3030, each projector :9090,
│                                    each Matrox device :443 + sign-in with the saved account
│
│  Projector control (Projectors tab)
│  WebSocket ws://localhost:8080?host=172.16.202.xx&port=9090
│      │
│      └─► proxy.js opens TCP socket → 172.16.202.xx:9090
│              Barco Pulse API (JSON-RPC 2.0 over raw TCP)
│              One persistent connection per projector (19 total)
│
│  ConvertIP monitor (ConvertIP tab)
│  HTTP GET /api/matrox/172.16.201.xxx/device/status
│  HTTP POST /api/matrox/172.16.201.xxx/device/reboot
│      │
│      └─► proxy.js proxies to HTTPS → 172.16.201.xxx:443
│              Matrox ConvertIP REST API (cookie-based auth)
│              Polled every 10 s, 38 devices (21 TX + 17 RX)
```

### Connections at page load

All 19 projector connections open as soon as the dashboard loads (staggered 150 ms apart), so projector status is live on every tab — the Scene Library status strip shows it immediately. Each connection reads the projector's state once, then the projector pushes changes (`property.subscribe`); the 5-second polling only starts when the Projectors tab is opened.

### Reconnect behaviour

Each projector WebSocket uses **exponential backoff**: 1 s → 2 s → 4 s → … → 60 s cap. Resets to 1 s on successful connection.

PRJ18 and PRJ19 (South Window) are marked **optional** — they are only installed sometimes. When unplugged they are silently ignored (no error toast, no offline flash) and reconnect is retried every 30 s.

---

## Scene Library

Scenes are grouped into five sections:

| Section | Count | Card style |
|---|---|---|
| Tech Looks | 4 | Thumbnail card |
| Demos | 6 | Demo button |
| New Looks 2026 | 12 | Thumbnail card |
| Alpha Overlay | 9 | Text list + thumbnail |
| Multimedia | 11 | Thumbnail card |

### Configuring scenes

Each scene must be mapped to a **Control Center timeline key/value** before it can be triggered.

1. Click **Settings** (top-right)
2. Enter the Timeline Key and Value for each scene
3. Click **Save Changes**

Or use **Bulk Import** — paste a JSON object:

```json
{
  "artnyc":         { "tlKey": "Timeline 03", "tlValue": 210 },
  "campfire":       { "tlKey": "Timeline 03", "tlValue": 215 },
  "demo-corporate": { "tlKey": "Timeline 01", "tlValue": 100 }
}
```

Keys match the `key` field in the `SCENES` object in the HTML source. Mappings are saved on the server (see [Settings](#settings)).

### Tags

Every scene carries tags (defaults in the `SCENES` object). Use them to find scenes quickly:

- **Filter** — click any tag pill (on a card or in the filter bar) to show only scenes with that tag; combine several, **Clear** to reset
- **Sort** — Default (sections), A → Z, or **By Tag** (flat view grouped by tag)
- **Edit** — hover a card and click the tag edit button to add/remove tags on that scene
- **More** — tag manager: create, rename or delete a tag across all scenes

Tag edits and sort order are saved on the server.

### Control Center

Control Center is the show-control **software** that plays the scenes (it is not part of the Barco projectors). Its address is set in **Settings → Control Center** (default `172.16.0.20`) and saved on the server; **Test connection** checks an address before saving. The address is intentionally not shown on the main screens — the top-bar **Control Center** indicator shows whether it's connected.

Scene triggers are sent **through the dashboard server**, so the indicator and the triggers always use the same network path — a screen only needs to reach the dashboard server.

---

## Projectors

### Inventory

The Projectors tab shows one section per zone, in this order (cards sorted by PRJ number). The sidebar links jump to each zone.

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
| | A05-PRJ11 | UDM-4K30 | 172.16.202.21 | "Toast Only" keeps this one on |
| | A05-PRJ12 | UDM-4K30 | 172.16.202.22 | |
| | A05-PRJ13 | UDM-4K30 | 172.16.202.23 | |
| **East** | A04-PRJ14 | UDM-4K30 | 172.16.202.24 | |
| | A04-PRJ15 | UDM-4K30 | 172.16.202.25 | |
| | A08-PRJ16 | UDM-4K30 | 172.16.202.26 | |
| | A08-PRJ17 | UDM-4K30 | 172.16.202.27 | |
| **South Window** | S01-PRJ18 | F80-4K12 | 172.16.202.28 | optional |
| | S01-PRJ19 | F80-4K12 | 172.16.202.29 | optional |

Zones and order are defined by `zone` in the `PROJECTORS` list and `PROJ_ZONES` in the HTML.

### Simple / Advanced

One toggle on the filter row switches **every projector at once** — there is no per-projector details menu.

| Mode | Each projector shows |
|---|---|
| **Simple** (default) | Name · **[⏻ Power: ON/OFF]** · **[Shutter: OPEN/CLOSED]** — two state toggles, nothing else |
| **Advanced** | Power and shutter status badges · discrete **⏻ On**, **⏻ Off** and **Shutter** buttons · Model · Zone · IP address · Connection · Video feed · Laser hours · Mainboard temp · Serial no. |

**Simple mode toggles** always show the projector's current feedback state; pressing one sends the opposite command (using the same commands as Advanced):

| Toggle | Shows | Press |
|---|---|---|
| **Power** | `ON` (green) | Asks **"Power off …?"** — only powers off after **Power off** is confirmed (Cancel / Esc / tapping outside does nothing). Asked every time, for every projector |
| | `OFF` (standby / eco / ready) | Powers on — no confirmation |
| | `Booting…` / `Warming up…` / `Cooling down…` / `Error` / `—` | Disabled — wait, or use Advanced |
| **Shutter** | `OPEN` (teal) | Closes the shutter |
| | `CLOSED` (red) | Opens the shutter |
| | `—` | Disabled — the shutter only works while the projector is on |

After a shutter press the toggle shows `Working…` until the projector confirms the new position.

**Advanced mode** is the full technical interface and is unchanged by Simple mode: the discrete On / Off commands, the Shutter command, the status badges and all details work exactly as before.

- Every page load starts in **Simple**, so the next operator isn't left in Advanced.
- Switching only changes what is shown — it never sends anything to the projectors.
- Works in both **Tile** and **List** view (in List view the details appear as a row under each projector).
- **Connection** — whether the dashboard's link to that projector is up (`Connected` / `Not connected — retrying`).
- **Video feed** — from the matching Matrox receiver (`Receiving · VDE09` / `No stream · VDE09`); shows `—` until the ConvertIP tab has polled the receivers.
- **Mainboard temp** is coloured against the projector's own warning/error limits. Values persist from the last poll even when the projector is off.

### Per-card controls

- **⏻ green** — Power On (`system.poweron`)
- **⏻ red** — Power Off (`system.poweroff`)
- **Shutter** — Toggle shutter Open/Closed (`optics.shutter.target`)

### Bulk actions (toolbar)

| Button | Action |
|---|---|
| Power On All | Powers on PRJ01–PRJ17 only (South Window excluded) |
| Power Off All | Powers off PRJ01–PRJ17 only (South Window excluded) |
| Open All Shutters | Opens shutters on all projectors currently On or Ready |
| Close All Shutters | Closes shutters on all projectors currently On or Ready |
| Refresh All | One-shot poll of all projectors (staggered 200 ms apart) |
| Start / Stop Polling | Toggles 5-second auto-poll |

### Filters & sort

Filter by **Zone** (North / South / Dome / West / East / South Window) and **State** (On / Ready / Standby / Error).  
Sort by IP, State, Zone, or Name. Active filters are highlighted gold. The display options — **Simple / Advanced** and **Tile / List** — are at the right end of the same row.

---

---

## ConvertIP

### Inventory

38 Matrox ConvertIP devices, SMPTE ST 2110 over 10/25 GbE SFP:

- **VEN — video encoders (TX):** 21 units, `CTL-VEN01`–`CTL-VEN21`, `172.16.201.141`–`.161`, all in the Control Room
- **VDE — video decoders (RX):** 17 units, `172.16.201.171`–`.187`, one per projector — decoder *n* feeds PRJ*n* and sits in the same zone

The ConvertIP tab shows one section per zone, in this order (cards sorted by device number); the sidebar links jump to each:

| Section | Devices |
|---|---|
| **North** | A07-VDE01 · S01-VDE02 · A06-VDE03 |
| **South** | A02-VDE04 · N01-VDE05 · A03-VDE06 |
| **Dome** | A06-VDE07 · A03-VDE08 |
| **West** | A01-VDE09 · A01-VDE10 · A05-VDE11 · A05-VDE12 · A05-VDE13 |
| **East** | A04-VDE14 · A04-VDE15 · A08-VDE16 · A08-VDE17 |
| **Control Room** | CTL-VEN01 – CTL-VEN21 |

The **TX / RX** filter still narrows to encoders or decoders. Zones and order are defined by `zone` in `CIP_DEVICES` and `CIP_ZONES` in the HTML.

### Per-card display

| Field | Source | Notes |
|---|---|---|
| Online / Offline | HTTP reachability | Green / red border |
| Stream | `videoStreams[].state` | Teal badge when any stream active |
| PTP | `ptpState` | Gold badge when Follower or Master |
| Temp | `temperature` / `temperatureLimit` | Green < 60 % · Amber 60–80 % · Red > 80 % of limit |
| Resolution | `frameBuffer.resolution` | Configured output resolution |
| Input | `videos[0].isPresent` | Live signal presence on HDMI/SDI input |
| Bitrate | `videoStreams[0].bitrateKbits` | Active stream bitrate in Gbps / Mbps |

### Per-card actions

- **↺ Reboot** — confirms then `POST /device/reboot`; card immediately shows offline until next poll recovers it

### Authentication

Cookie-based (`session_token`). The login is set in **Settings → ConvertIP — Matrox Login** and stored in `settings.json`. `proxy.js` maintains one session per device IP and auto-re-logs in when the device returns 401, 403, or `"Not logged in"` in a 200 response.

### Polling

All 38 devices polled every **10 seconds**, staggered 150 ms apart to avoid flooding the network. A manual **Refresh** button is available in the toolbar.

---

## Barco Pulse API reference

All projector communication uses **JSON-RPC 2.0 over TCP port 9090** (Barco Pulse API, ref. TDE9629).

### Properties used

| Property | Type | Notes |
|---|---|---|
| `system.state` | enum | `on` · `ready` · `standby` · `eco` · `boot` · `conditioning` · `deconditioning` · `error` |
| `optics.shutter.position` | enum | `Open` · `Closed` |
| `optics.shutter.target` | enum | Write `Open` or `Closed` to toggle |
| `system.serialnumber` | string | Read-only, fetched once per connection |

Model-specific properties (the two models name these differently — verified with `introspect` on each; mapped in `MODEL_PROPS` in the HTML):

| Metric | UDM-4K30 (PRJ 1–17) | F80-4K12 (PRJ 18–19) |
|---|---|---|
| Laser runtime | `statistics.laserruntime.value` — **seconds** | `statistics.operating.laseron.value` — **minutes** (`getunit` → `minutes`) |
| Mainboard temperature (°C) | `environment.temperature.mainboard.cpu.value` | `environment.temperature.mainboard.value` |
| Temperature limits | `….mainboard.cpu.threshold.highwarning` / `.higherror` (90 / 100 °C) | `….mainboard.threshold.highwarning` / `.higherror` (80 / 83 °C) |

`environment.temperature.mainboard` (without `.value`) does not exist on either model, and the F80 has no `statistics.laserruntime`. Temperature limits are read once per projector.

### Methods used

| Method | Notes |
|---|---|
| `property.get` | Read a single property |
| `property.set` | Write a property (shutter target) |
| `property.subscribe` | Subscribe to push notifications on value change |
| `system.poweron` | Power on |
| `system.poweroff` | Power off |

### Push notifications

After subscribing, the projector sends unsolicited `property.changed` notifications:

```json
{
  "method": "property.changed",
  "params": {
    "property": [{ "system.state": "on" }]
  }
}
```

Projectors send the full dotted property name. The dashboard also accepts the flat last-segment form (`state`, `position`, `serialnumber`) as a fallback — but not for laser runtime or temperature, which both end in `.value` and would be ambiguous.

Subscriptions last for the whole connection, so each `property.subscribe` is sent **once per connection** (tracked per projector, reset on reconnect) rather than on every refresh.

---

## Proxy internals

`proxy.js` handles partial TCP frames via two strategies:

1. **Newline-delimited** — splits on `\n` immediately
2. **JSON boundary detection** — walks `{}` depth to extract complete objects when no newline arrives (10 ms debounce)

This makes it robust against TCP segmentation of large Barco responses.

---

## Versioning

This project follows [Semantic Versioning 2.0.0](https://semver.org) — `MAJOR.MINOR.PATCH`:

- **MAJOR** — incompatible changes to the HTTP API (`/api/*`) or the `settings.json` format (existing settings/clients would stop working)
- **MINOR** — new functionality that stays backward compatible
- **PATCH** — backward-compatible bug fixes only

The version lives in `package.json` (source of truth), the dashboard header (`brand-sub`), the README title and the changelog below — bump all four together.

## Changelog

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
