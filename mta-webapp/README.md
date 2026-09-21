# MTA Dashboard v3.4.0

A real-time NYC subway departure dashboard for Raspberry Pi, optimized for 800x480 touchscreen displays.

![Version](https://img.shields.io/badge/version-3.4.0-blue)
![Node](https://img.shields.io/badge/node-20.x-green)
![License](https://img.shields.io/badge/license-MIT-brightgreen)

## Overview

Personalized morning commute dashboard tracking:
- **M Train** from Knickerbocker Ave (Manhattan-bound)
- **L Train** from DeKalb Ave (Manhattan-bound)

Features smart departure timing, service alerts, weather, and trash day reminders.

---

## Features

### Core Functionality
- ✅ Real-time train arrivals from MTA GTFS feeds
- ✅ Smart departure timing with walk time calculations
- ✅ Visual cues: "Leave now" (green), "Hurry up!" (orange)
- ✅ Next 2 upcoming trains always visible
- ✅ Automatic train deduplication (prevents double-counting)
- ✅ Server-side caching (20s) to prevent API rate limiting

### Service Alerts
- ✅ Two-layer alert system:
  - **Glance badges**: Pulsing indicators in header ([M] DISRUPTED, [L] DISRUPTED)
  - **Scrolling ticker**: Full alert details at bottom
- ✅ Manhattan-bound route filtering only
- ✅ Financial District commute focus
- ✅ Auto-filters irrelevant alerts (wrong direction, other boroughs)

### Weather Integration
- ✅ Dual weather system:
  - **Primary**: OpenWeather API (requires key)
  - **Fallback**: Open-Meteo (free, no key)
- ✅ Current conditions, temperature (C°/F°), wind speed
- ✅ Brooklyn coordinates (40.70°N, -73.92°W)

### Smart Features
- ✅ Trash day reminders (Mon/Wed/Fri 6pm+)
- ✅ Motion sensor support (GPIO pin 17)
- ✅ PM2 process management with auto-restart
- ✅ Optimized for 800x480 displays

---

## Quick Start

### Prerequisites
```bash
# Node.js 20.x
node --version  # Should be v20.x

# PM2 (optional but recommended)
npm install -g pm2
```

### Installation

1. **Clone/Download** the project files to your Raspberry Pi

2. **Install dependencies**
```bash
cd ~/mta-webapp
npm install
```

3. **Configure environment**
```bash
nano .env
```

Required settings:
```bash
PORT=4000
STOP_M=M09N          # Knickerbocker Ave (Manhattan-bound)
STOP_L=L16S          # DeKalb Ave (westbound to Manhattan)
WALK_M=5             # Walk time in minutes
WALK_L=7
WEATHER_LAT=40.70
WEATHER_LON=-73.92
OPENWEATHER_API_KEY=your_key_here  # Get free key from openweathermap.org
```

4. **Start with PM2**
```bash
pm2 start server.js --name mta-dashboard
pm2 save
pm2 startup  # Follow the command it outputs
```

5. **Access dashboard**
```
http://localhost:4000
http://YOUR_PI_IP:4000
```

---

## Changelog

### v3.4.0 (2026-02-04)
**Added:**
- Smart alert filtering for Manhattan-bound Financial District commute
- Trash day reminders (glowing indicator Mon/Wed/Fri evenings)
- Automatic train deduplication (fixes duplicate timestamps from multiple feeds)
- Next Trains now shows trains #2 and #3 (not just catchable trains)
- Correct stop ID detection (M09N for Knickerbocker, L16S for DeKalb)

**Fixed:**
- M train not appearing (wrong stop ID M12 → M09N)
- L train direction (L16N → L16S for westbound)
- Duplicate train times from overlapping GTFS feeds
- "Next Trains" showing same train as "Departure"
- Alert filtering rejecting L train suspensions incorrectly

**Improved:**
- Alert noise reduction (filters Brooklyn-bound, wrong boroughs, irrelevant segments)
- Two-layer alert system (glance badges + scrolling ticker)
- Official MTA line colors for badges (M=#FF6319, L=#A7A9AC, J=#996633)
- Service alert gap detection (L train Myrtle-Wyckoff ↔ Lorimer affects DeKalb)

### v3.3.0 (Previous)
- Initial release with M/L train tracking
- Weather integration
- Motion sensor support
- PM2 process management

---

## PM2 Commands

```bash
# Status
pm2 status
pm2 list

# Logs
pm2 logs mta-dashboard
pm2 logs mta-dashboard --lines 100

# Control
pm2 restart mta-dashboard
pm2 stop mta-dashboard
pm2 start mta-dashboard

# Monitoring
pm2 monit

# Remove
pm2 delete mta-dashboard
```

---

## Troubleshooting

### No trains showing
1. Check logs: `pm2 logs mta-dashboard --lines 50`
2. Look for: `[DEBUG] Route M at stop M09N: Found X upcoming trains`
3. Verify stop IDs in `.env` (M09N, L16S)
4. Check MTA service at https://www.mta.info/

### Alerts not showing
1. Check logs for `[ALERTS] Processing X alert entities`
2. Look for ✅ ACCEPTED or ❌ Rejected messages
3. Alerts are filtered for Manhattan-bound commutes only

### Weather not loading
1. Verify `OPENWEATHER_API_KEY` in `.env`
2. Get free key: https://openweathermap.org/api
3. Fallback: Open-Meteo (automatic, no key needed)

---

## License

MIT License - Free to use and modify

---

**Current Status**: Production-ready  
**Last Updated**: February 4, 2026  
**Tested On**: Raspberry Pi 4B with 800x480 touchscreen