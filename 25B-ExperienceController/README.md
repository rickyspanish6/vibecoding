# 25 Broadway — Experience Controller · v1.3

Local web dashboard for AV control at 25 Broadway, NYC.  
Three tabs: **Scene Library** (triggers Barco Control Center timelines), **Projectors** (monitors and controls 19 Barco laser projectors over TCP), and **ConvertIP** (monitors 38 Matrox ConvertIP ST 2110 encoders/decoders).

---

## Files

```
25B-ExperienceController/
├── 25broadway_dashboard.html   # Full dashboard UI — HTML + CSS + JS, no build step
├── proxy.js                    # Node.js server: serves HTML on :8080, bridges WS → Barco TCP :9090,
│                               #   and proxies HTTPS → Matrox ConvertIP REST API
├── package.json
└── node_modules/ws/            # Only dependency
```

The dashboard is intentionally a **single HTML file**. There is no bundler, no framework, no build step. This keeps deployment simple — copy two files, run one command.

---

## Requirements

- Node.js (any recent LTS)
- Network access to the Barco subnet (`172.16.202.x`) and Control Center (`172.16.0.20`)
- Network access to the Matrox ConvertIP subnet (`172.16.201.x`)

---

## Setup

```bash
npm install        # installs the ws package (one-time)
node proxy.js      # starts the server
```

Open **http://localhost:8080** in a browser on the same machine.

---

## Architecture

```
Browser (localhost:8080)
│
│  HTTP GET /                     → proxy.js serves 25broadway_dashboard.html
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
| Tech Looks | 6 | Thumbnail card |
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

Keys match the `key` field in the `SCENES` object in the HTML source. Settings persist in `localStorage`.

### Control Center IP

The CC IP field (top bar, labelled **CC**) defaults to `172.16.0.20`. Change it and it persists in `localStorage`.

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

Cookie-based (`session_token`). `proxy.js` maintains one session per device IP and auto-re-logs in when the device returns 401, 403, or `"Not logged in"` in a 200 response.

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
