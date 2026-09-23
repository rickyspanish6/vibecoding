# 25 Broadway — Experience Controller · v1.4

Local web dashboard for AV control at 25 Broadway, NYC.  
Three tabs: **Scene Library** (triggers Barco Control Center timelines), **Projectors** (monitors and controls 19 Barco laser projectors over TCP), and **ConvertIP** (monitors 38 Matrox ConvertIP ST 2110 encoders/decoders).

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
├── images/                     # Scene thumbnails
├── package.json
└── node_modules/ws/            # Only dependency (git-ignored — run npm install)
```

The dashboard is intentionally a **single HTML file**. There is no bundler, no framework, no build step. This keeps deployment simple — copy the folder, run one command.

---

## Requirements

- **Docker** (recommended) — Docker Engine on Linux, or Docker Desktop on macOS/Windows
- or **Node.js** (any recent LTS) to run without Docker
- Network access to the Barco subnet (`172.16.202.x`) and Control Center (`172.16.0.20`)
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

On a fresh install, open **Settings** and enter the **Matrox login** — the ConvertIP tab shows every device offline until it is set.

---

## Settings

All settings are edited from **Settings** (top-right) and saved on the server in `settings.json`, next to `proxy.js`. Every browser and device that opens the dashboard sees the same setup.

| Setting | Stored | Notes |
|---|---|---|
| CC IP | Server | Control Center IP for scene triggers (also editable in the top bar) |
| Matrox username / password | Server | Used by `proxy.js` to log in to all ConvertIP devices |
| Scene timeline mappings | Server | Timeline key/value per scene |
| Scene tags, custom tags, sort order | Server | |
| Proxy Host | This browser | Only needed if the page can't auto-detect the server address |
| Tile / List view | This browser | Per-device display preference |

- **Matrox password** is write-only: it is never sent back to the browser. Leave the field blank to keep the current one. Changing the login drops all Matrox sessions so the next poll logs in with the new credentials.
- **`settings.json` is git-ignored** and never served over HTTP. Back it up when moving the dashboard to a new machine — it's the whole configuration.
- **Migration:** the first time a browser with older `localStorage` settings opens a server that has no scene data yet, its settings are copied to the server automatically.
- If the page is opened without `proxy.js` running, the dashboard falls back to the last settings cached in that browser.

### Settings API

| Method | Path | Notes |
|---|---|---|
| GET | `/api/settings` | Returns all shared settings; Matrox returned as `{ username, hasPassword }` |
| PUT | `/api/settings` | Merges the top-level keys given (`ccIp`, `sceneMap`, `sceneTags`, `knownTags`, `sceneSortOrder`, `matrox`) |

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
│  HTTP POST → http://172.16.0.20:3030/sc-datastore/projectData/taskFlow
│              method: Task.Execute  (Barco Control Center JSON-RPC)
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

### Reconnect behaviour

Each projector WebSocket uses **exponential backoff**: 1 s → 2 s → 4 s → … → 60 s cap. Resets to 1 s on successful connection.

PRJ18 and PRJ19 are marked **optional** — they are only installed sometimes. When unplugged they are silently ignored (no error toast, no offline flash) and reconnect is retried every 30 s.

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

### Control Center IP

The CC IP field (top bar, labelled **CC**) defaults to `172.16.0.20`. Changes are saved on the server.

---

## Projectors

### Inventory

| # | Name | Model | IP | Zone |
|---|---|---|---|---|
| 1 | A01-PRJ09 | UDM-4K30 | 172.16.202.19 | West |
| 2 | A01-PRJ10 | UDM-4K30 | 172.16.202.20 | West |
| 3 | A02-PRJ04 | UDM-4K30 | 172.16.202.14 | South |
| 4 | A03-PRJ06 | UDM-4K30 | 172.16.202.16 | North |
| 5 | A03-PRJ08 | UDM-4K30 | 172.16.202.18 | North |
| 6 | A04-PRJ14 | UDM-4K30 | 172.16.202.24 | East |
| 7 | A04-PRJ15 | UDM-4K30 | 172.16.202.25 | East |
| 8 | A05-PRJ11 | UDM-4K30 | 172.16.202.21 | West |
| 9 | A05-PRJ12 | UDM-4K30 | 172.16.202.22 | West |
| 10 | A05-PRJ13 | UDM-4K30 | 172.16.202.23 | West |
| 11 | A06-PRJ03 | UDM-4K30 | 172.16.202.13 | North |
| 12 | A06-PRJ07 | UDM-4K30 | 172.16.202.17 | Dome |
| 13 | A07-PRJ01 | UDM-4K30 | 172.16.202.11 | North |
| 14 | A08-PRJ16 | UDM-4K30 | 172.16.202.26 | East |
| 15 | A08-PRJ17 | UDM-4K30 | 172.16.202.27 | East |
| 16 | N01-PRJ05 | UDM-4K30 | 172.16.202.15 | South |
| 17 | S01-PRJ02 | UDM-4K30 | 172.16.202.12 | North |
| 18 | S01-PRJ18 | F80-4K12 | 172.16.202.28 | North Show | optional |
| 19 | S01-PRJ19 | F80-4K12 | 172.16.202.29 | North Show | optional |

### Per-card controls

- **⏻ green** — Power On (`system.poweron`)
- **⏻ red** — Power Off (`system.poweroff`)
- **Shutter** — Toggle shutter Open/Closed (`optics.shutter.target`)
- **+** — Expand metrics panel (Laser Hrs · Temp · S/N). Values persist from last poll even when the projector is off.

### Bulk actions (toolbar)

| Button | Action |
|---|---|
| Power On All | Powers on Multimedia projectors 1–17 only |
| Power Off All | Powers off Multimedia projectors 1–17 only |
| Open All Shutters | Opens shutters on all projectors currently On or Ready |
| Close All Shutters | Closes shutters on all projectors currently On or Ready |
| Refresh All | One-shot poll of all projectors (staggered 200 ms apart) |
| Start / Stop Polling | Toggles 5-second auto-poll |

### Filters & sort

Filter by **Zone** (North / South / East / West / Dome) and **State** (On / Ready / Standby / Error).  
Sort by IP, State, Zone, or Name. Active filters are highlighted gold.

---

---

## ConvertIP

### Inventory

21 TX encoders (`CTL-VEN01`–`CTL-VEN21`, `172.16.201.141`–`.161`) and 17 RX decoders (`CTL-VDE01`–`CTL-VDE17`, `172.16.201.171`–`.187`). All SMPTE ST 2110 over 10/25 GbE SFP.

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
| `statistics.laserruntime.value` | int | Laser runtime in **seconds** — divide by 3600 for hours |
| `environment.temperature.mainboard` | float | Mainboard temperature in °C |
| `system.serialnumber` | string | Read-only, fetched once per connection |

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

The dashboard handles both the full dotted-key form and the flat last-segment form as a fallback.

---

## Proxy internals

`proxy.js` handles partial TCP frames via two strategies:

1. **Newline-delimited** — splits on `\n` immediately
2. **JSON boundary detection** — walks `{}` depth to extract complete objects when no newline arrives (10 ms debounce)

This makes it robust against TCP segmentation of large Barco responses.

---

## Changelog

### v1.4 — 2026-09-23
- **Feature:** Settings are stored on the server (`settings.json`) and shared by every browser — scene mappings, tags, sort order, CC IP. Existing browser settings are migrated automatically on first load
- **Feature:** Matrox ConvertIP login is configurable from **Settings** (was hardcoded in `proxy.js`); password is write-only and never returned to the browser
- **Feature:** Single-container Docker deployment (`Dockerfile`, `docker-compose.yml`) with settings on a persistent volume and a health check
- **Feature:** `PORT` and `DATA_DIR` environment variables in `proxy.js`
- **Security:** `proxy.js` refuses to serve `settings.json` and dotfiles
- **Chore:** Removed the outdated "Running the Dashboard" snippet from the Settings modal
- **Chore:** Added `.gitignore` (`node_modules/`, `.DS_Store`, `settings.json`); `node_modules` no longer committed
- **Chore:** `package.json` now carries the app name/version and an `npm start` script
- **Docs:** Documented tags, Docker deployment, settings storage and API; corrected Tech Looks count

### v1.3 — 2026-05-08
- **Feature:** Tile / List view toggle on both Projectors and ConvertIP tabs — preference persists in `localStorage`
- **Feature:** Projector cards show a teal **Stream** badge (or grey **No Stream**) sourced from the associated Matrox RX device; association derived automatically by matching VDE number to PRJ number
- **Fix:** All Matrox ConvertIP devices showing offline after proxy restart — duplicate `const dev` declaration inside `cipPoll` caused a `SyntaxError` that silently prevented the script from loading
- **Fix:** Reboot returning HTTP 400 — Matrox devices require `Content-Type: application/json` + `{}` body on POST `/device/reboot`; both are now sent
- **Fix:** Removed per-card reboot button on ConvertIP cards; toolbar Reboot Selected / Reboot All is the single reboot path

### v1.2 — 2026-05-08
- **Feature:** ConvertIP tab — monitors 38 Matrox ConvertIP ST 2110 encoders/decoders (21 TX + 17 RX)
- **Feature:** Per-device cards showing Online/Offline, Stream active, PTP locked, temperature (colour-coded), configured resolution, input signal presence, and stream bitrate
- **Feature:** Reboot button per ConvertIP device (`POST /device/reboot`)
- **Feature:** `proxy.js` Matrox HTTPS proxy — cookie-based auth with automatic re-login on session expiry (handles both HTTP 401/403 and 200 "Not logged in" responses)
- **Fix:** `Content-Type: application/json` no longer sent on GET requests (caused HTTP 400 from Matrox devices)
- **Fix:** PRJ18 and PRJ19 (North Show F80-4K12) marked `optional` — disconnection is silently ignored, reconnect retried every 30 s
- **Fix:** Barco WebSocket bridge log prefix changed from `[Proxy]` to `[Barco]`

### v1.1 — 2026-05-07
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

### v1.0 — initial
- Scene Library: 5 sections (Tech Looks, Demos, New Looks 2026, Alpha Overlay, Multimedia) triggering Barco Control Center via `Task.Execute` JSON-RPC
- Projectors tab: 19 projectors, power / shutter control, filter / sort, bulk actions, 5 s auto-poll
- `proxy.js`: HTTP file server + WebSocket → Barco TCP bridge with JSON boundary detection
