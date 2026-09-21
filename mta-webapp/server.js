// --- VERSION 3.3.0 ---
// Optimized with: Server-side caching, Async GPIO, Error handling, Service alerts, Enhanced weather
console.log("Starting MTA Dashboard v3.3.0...");

import express from "express";
import fetch from "node-fetch";
import gtfs from "gtfs-realtime-bindings";
import { exec } from "child_process";
import { promisify } from "util";
import dotenv from "dotenv";
import path from "path";
import { fileURLToPath } from "url";
import fs from "fs";

// ES6 module compatibility
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Load environment variables
dotenv.config();

// Promisify exec for async GPIO
const execAsync = promisify(exec);

const { transit_realtime } = gtfs;
const app = express();

// Set proper MIME types
express.static.mime.define({ 'application/javascript': ['js'] });

// Configuration from .env
const PORT = parseInt(process.env.PORT) || 4000;
const DISCOVERED_IP = process.env.DISCOVERED_IP || "10.0.0.31";
const STOP_M = process.env.STOP_M || "M12";
const STOP_L = process.env.STOP_L || "L16";
const WALK_M = parseInt(process.env.WALK_M) || 6;
const WALK_L = parseInt(process.env.WALK_L) || 8;
// 55 Wall St routing — stop IDs configurable via .env (check server logs to verify)
const STOP_BROADWAY    = process.env.STOP_BROADWAY    || "J27";  // Broadway (J/M/Z), Brooklyn
const STOP_BROADST     = process.env.STOP_BROADST     || "J31";  // Broad St (J), Manhattan
const STOP_UNION_SQ_L  = process.env.STOP_UNION_SQ_L  || "L03";  // 14 St-Union Sq (L)
const STOP_UNION_SQ_45 = process.env.STOP_UNION_SQ_45 || "635";  // 14 St-Union Sq (4/5)
const STOP_WALL_ST_45  = process.env.STOP_WALL_ST_45  || "418";  // Wall St (4/5)
const WEATHER_LAT = parseFloat(process.env.WEATHER_LAT) || 40.70;
const WEATHER_LON = parseFloat(process.env.WEATHER_LON) || -73.92;
const OPENWEATHER_API_KEY = process.env.OPENWEATHER_API_KEY || '';
const CACHE_DURATION = parseInt(process.env.CACHE_DURATION) || 20000;
const MOTION_GPIO_PIN = parseInt(process.env.MOTION_GPIO_PIN) || 17;

// Server-side cache
let cachedData = null;
let lastFetch = 0;

// Serve static files with explicit options
app.use(express.static(path.join(__dirname, 'public'), {
  setHeaders: (res, filepath) => {
    if (filepath.endsWith('.js')) {
      res.setHeader('Content-Type', 'application/javascript');
    } else if (filepath.endsWith('.css')) {
      res.setHeader('Content-Type', 'text/css');
    } else if (filepath.endsWith('.html')) {
      res.setHeader('Content-Type', 'text/html');
    }
  }
}));

// Log static file requests (for debugging)
app.use((req, res, next) => {
  if (req.url.startsWith('/css/') || req.url.startsWith('/js/')) {
    console.log(`Static file request: ${req.url}`);
  }
  next();
});

// Configuration endpoint
app.get("/api/config", (req, res) => {
  res.json({
    WALK_M,
    WALK_L,
    IP: DISCOVERED_IP,
    PORT
  });
});

// ── 55 Wall St routing helpers ──
function getWallStViaM(combined) {
  const now = Date.now();
  const TRANSFER_MS = 2 * 60 * 1000;
  const WALK_TO_55  = 3 * 60 * 1000; // Broad St → 55 Wall St

  const mLegs = combined
    .filter(e => e.tripUpdate?.trip.routeId === "M")
    .flatMap(e => {
      const stops   = e.tripUpdate.stopTimeUpdate || [];
      const knick   = stops.find(u => u.stopId?.startsWith(STOP_M));
      const bway    = stops.find(u => u.stopId?.startsWith(STOP_BROADWAY));
      if (!knick || !bway) return [];
      const mDep    = parseInt(knick.departure?.time || knick.arrival?.time)  * 1000;
      const bwayArr = parseInt(bway.arrival?.time    || bway.departure?.time) * 1000;
      if (!mDep || !bwayArr || mDep < now + WALK_M * 60 * 1000) return [];
      return [{ mDep, bwayArr }];
    })
    .sort((a, b) => a.mDep - b.mDep);

  const jLegs = combined
    .filter(e => e.tripUpdate?.trip.routeId === "J")
    .flatMap(e => {
      const stops    = e.tripUpdate.stopTimeUpdate || [];
      const bway     = stops.find(u => u.stopId?.startsWith(STOP_BROADWAY));
      const broad    = stops.find(u => u.stopId?.startsWith(STOP_BROADST));
      if (!bway || !broad) return [];
      const bwayDep  = parseInt(bway.departure?.time  || bway.arrival?.time)   * 1000;
      const broadArr = parseInt(broad.arrival?.time   || broad.departure?.time) * 1000;
      if (!bwayDep || !broadArr || bwayDep < now) return [];
      return [{ bwayDep, broadArr }];
    })
    .sort((a, b) => a.bwayDep - b.bwayDep);

  // Log full stop sequence of first M trip containing Knickerbocker
  const firstMTrip = combined.filter(e => e.tripUpdate?.trip.routeId === "M")
    .find(e => e.tripUpdate.stopTimeUpdate?.some(u => u.stopId?.startsWith(STOP_M)));
  if (firstMTrip) {
    console.log('[55Wall/M] M trip stops: ' + firstMTrip.tripUpdate.stopTimeUpdate.map(u => u.stopId).join(', '));
  } else {
    console.log('[55Wall/M] No M trip found containing ' + STOP_M);
  }
  // Log ALL J stop IDs on one line
  const jStops = [...new Set(combined.filter(e => e.tripUpdate?.trip.routeId === "J")
    .flatMap(e => e.tripUpdate.stopTimeUpdate || []).map(u => u.stopId).filter(Boolean))].sort();
  console.log('[55Wall/M] ALL J stops: ' + jStops.join(', '));
  console.log(`[55Wall/M] M legs: ${mLegs.length}, J legs: ${jLegs.length}`);

  for (const m of mLegs) {
    const j = jLegs.find(j => j.bwayDep >= m.bwayArr + TRANSFER_MS);
    if (j) {
      const eta = j.broadArr + WALK_TO_55;
      console.log(`[55Wall/M] M ${new Date(m.mDep).toLocaleTimeString()} → J ${new Date(j.bwayDep).toLocaleTimeString()} → ETA ${new Date(eta).toLocaleTimeString()}`);
      return eta;
    }
  }
  return null;
}

function getWallStViaL(combined) {
  const now = Date.now();
  const TRANSFER_MS = 2 * 60 * 1000;
  const WALK_TO_55  = 2 * 60 * 1000; // Wall St (4/5) → 55 Wall St

  const lLegs = combined
    .filter(e => e.tripUpdate?.trip.routeId === "L")
    .flatMap(e => {
      const stops  = e.tripUpdate.stopTimeUpdate || [];
      const dekalb = stops.find(u => u.stopId?.startsWith(STOP_L));
      const uSq    = stops.find(u => u.stopId?.startsWith(STOP_UNION_SQ_L));
      if (!dekalb || !uSq) return [];
      const lDep   = parseInt(dekalb.departure?.time || dekalb.arrival?.time) * 1000;
      const uSqArr = parseInt(uSq.arrival?.time      || uSq.departure?.time)  * 1000;
      if (!lDep || !uSqArr || lDep < now + WALK_L * 60 * 1000) return [];
      return [{ lDep, uSqArr }];
    })
    .sort((a, b) => a.lDep - b.lDep);

  const t45Legs = combined
    .filter(e => ['4', '5'].includes(e.tripUpdate?.trip.routeId))
    .flatMap(e => {
      const stops   = e.tripUpdate.stopTimeUpdate || [];
      const uSq     = stops.find(u => u.stopId?.startsWith(STOP_UNION_SQ_45));
      const wall    = stops.find(u => u.stopId?.startsWith(STOP_WALL_ST_45));
      if (!uSq || !wall) return [];
      const uSqDep  = parseInt(uSq.departure?.time  || uSq.arrival?.time)   * 1000;
      const wallArr = parseInt(wall.arrival?.time    || wall.departure?.time) * 1000;
      // wallArr must be AFTER uSqDep — filters out northbound trips where Wall St precedes Union Sq
      if (!uSqDep || !wallArr || uSqDep < now || wallArr <= uSqDep) return [];
      return [{ uSqDep, wallArr }];
    })
    .sort((a, b) => a.uSqDep - b.uSqDep);

  // Log ALL 4/5 stops on one line + longest southbound trip to find Union Sq & Wall St IDs
  const t45Stops = [...new Set(combined.filter(e => ['4','5'].includes(e.tripUpdate?.trip.routeId))
    .flatMap(e => e.tripUpdate.stopTimeUpdate || []).map(u => u.stopId).filter(Boolean))].sort();
  console.log('[55Wall/L] ALL 4/5 stops: ' + t45Stops.join(', '));
  const longest4Trip = combined.filter(e => e.tripUpdate?.trip.routeId === "4")
    .sort((a, b) => (b.tripUpdate.stopTimeUpdate?.length || 0) - (a.tripUpdate.stopTimeUpdate?.length || 0))[0];
  if (longest4Trip) console.log('[55Wall/L] Longest 4-train trip: ' + longest4Trip.tripUpdate.stopTimeUpdate.map(u => u.stopId).join(', '));
  console.log(`[55Wall/L] L legs: ${lLegs.length}, 4/5 legs: ${t45Legs.length}`);

  for (const l of lLegs) {
    const t = t45Legs.find(t => t.uSqDep >= l.uSqArr + TRANSFER_MS);
    if (t) {
      const eta = t.wallArr + WALK_TO_55;
      console.log(`[55Wall/L] L ${new Date(l.lDep).toLocaleTimeString()} → 4/5 ${new Date(t.uSqDep).toLocaleTimeString()} → ETA ${new Date(eta).toLocaleTimeString()}`);
      return eta;
    }
  }
  return null;
}

// Main API endpoint with caching
app.get("/api", async (req, res) => {
  const now = Date.now();

  // Return cached data if still fresh
  if (cachedData && (now - lastFetch) < CACHE_DURATION) {
    console.log(`[${new Date().toISOString()}] Serving cached data`);
    return res.json(cachedData);
  }

  console.log(`[${new Date().toISOString()}] Fetching fresh data from MTA...`);

  try {
    const fetchOptions = {
      headers: { 'User-Agent': 'MTA-Dashboard/3.3.0' },
      timeout: 10000
    };

    // MTA GTFS feeds URLs
    const gtfsUrls = [
      "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs-l",
      "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs-bdfm",
      "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs-jz",
      "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs"     // 1-7 (for 4/5 → Wall St)
    ];

    // Service alerts feed
    const alertsUrl = "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/camsys%2Fsubway-alerts";

    // Weather API URLs - OpenWeather primary, Open-Meteo fallback
    const openWeatherUrl = OPENWEATHER_API_KEY
      ? `https://api.openweathermap.org/data/2.5/weather?lat=${WEATHER_LAT}&lon=${WEATHER_LON}&appid=${OPENWEATHER_API_KEY}&units=metric`
      : null;
    const openMeteoUrl = `https://api.open-meteo.com/v1/forecast?latitude=${WEATHER_LAT}&longitude=${WEATHER_LON}&current_weather=true&current=temperature_2m,weathercode,windspeed_10m&temperature_unit=celsius&windspeed_unit=kmh`;

    // Fetch all data in parallel
    const fetchPromises = [
      fetch(gtfsUrls[0], fetchOptions),
      fetch(gtfsUrls[1], fetchOptions),
      fetch(gtfsUrls[2], fetchOptions),
      fetch(gtfsUrls[3], fetchOptions),
      fetch(alertsUrl, fetchOptions)
    ];

    // Try OpenWeather first, fallback to Open-Meteo
    let weatherData = null;
    let weatherSource = 'none';

    if (openWeatherUrl) {
      try {
        const resWeather = await fetch(openWeatherUrl, fetchOptions);
        if (resWeather.ok) {
          weatherData = await resWeather.json();
          weatherSource = 'openweather';
          console.log('[Weather] Using OpenWeather');
        }
      } catch (error) {
        console.log('[Weather] OpenWeather failed, trying Open-Meteo:', error.message);
      }
    }

    // Fallback to Open-Meteo if OpenWeather failed or no API key
    if (!weatherData) {
      try {
        const resWeather = await fetch(openMeteoUrl, fetchOptions);
        if (resWeather.ok) {
          weatherData = await resWeather.json();
          weatherSource = 'openmeteo';
          console.log('[Weather] Using Open-Meteo');
        }
      } catch (error) {
        console.log('[Weather] Both weather services failed:', error.message);
      }
    }

    const [resL, resM, resJZ, res456, resAlerts] = await Promise.all(fetchPromises);

    // Process GTFS feeds
    const buffers = await Promise.all([
      resL.arrayBuffer(),
      resM.arrayBuffer(),
      resJZ.arrayBuffer(),
      res456.arrayBuffer()
    ]);

    const combined = [];
    buffers.forEach(buffer => {
      const feed = transit_realtime.FeedMessage.decode(new Uint8Array(buffer));
      const obj = transit_realtime.FeedMessage.toObject(feed, { defaults: true });
      if (obj.entity) {
        combined.push(...obj.entity);
      }
    });

    // Process alerts
    const alertsBuffer = await resAlerts.arrayBuffer();
    const alertsFeed = transit_realtime.FeedMessage.decode(new Uint8Array(alertsBuffer));
    const alertsObj = transit_realtime.FeedMessage.toObject(alertsFeed, { defaults: true });
    const relevantAlerts = processAlerts(alertsObj.entity);

    // Process weather based on source
    const weather = weatherData ? processWeather(weatherData, weatherSource) : getDefaultWeather();

    // Check motion sensor (async)
    const motionDetected = await checkMotionSensor();

    // Filter train data with direction awareness
    const filter = (id, route) => {
      // For M at Knickerbocker and L at DeKalb, we want Manhattan-bound only
      // Try both the base ID and the N (northbound) suffix
      const stopIds = [id, id + 'N'];

      // DEBUG: Log all stop IDs for this route to find the correct one
      const allStopsForRoute = combined
        .filter(e => e.tripUpdate?.trip.routeId === route)
        .flatMap(e => e.tripUpdate.stopTimeUpdate || [])
        .map(u => u.stopId)
        .filter(Boolean);

      const uniqueStops = [...new Set(allStopsForRoute)].sort();
      console.log(`[DEBUG] All stop IDs for route ${route}:`, uniqueStops.slice(0, 20)); // First 20

      const trains = combined
        .filter(e => e.tripUpdate?.trip.routeId === route)
        .flatMap(e => e.tripUpdate.stopTimeUpdate || [])
        .filter(u => {
          if (!u.stopId) return false;
          // Match if stopId starts with any of our target IDs
          return stopIds.some(targetId => u.stopId.startsWith(targetId));
        })
        .map(u => {
          const time = u.arrival?.time || u.departure?.time;
          return time ? parseInt(time) * 1000 : null;
        })
        .filter(t => t && t > Date.now())
        .sort((a, b) => a - b)
        .filter((t, i, arr) => i === 0 || t - arr[i - 1] > 60000); // dedupe: drop any within 60s of the previous

      // Debug logging
      console.log(`[DEBUG] Route ${route} at stop ${id}: Found ${trains.length} upcoming trains`);
      if (trains.length > 0) {
        const firstTrain = new Date(trains[0]);
        const minsAway = Math.floor((trains[0] - Date.now()) / 60000);
        console.log(`  First train: ${firstTrain.toLocaleTimeString()} (${minsAway} mins away)`);
      }

      return trains;
    };

    // Build response
    const result = {
      m: filter(STOP_M, "M"),
      l: filter(STOP_L, "L"),
      wallStM: getWallStViaM(combined),
      wallStL: getWallStViaL(combined),
      motion: motionDetected,
      weather: weather,
      alerts: relevantAlerts
    };

    // Update cache
    cachedData = result;
    lastFetch = now;

    res.json(result);

  } catch (error) {
    console.error(`[${new Date().toISOString()}] API Error:`, error.message);

    // Return cached data if available, even if stale
    if (cachedData) {
      console.log('Returning stale cached data due to error');
      return res.json(cachedData);
    }

    res.status(500).json({
      error: error.message,
      timestamp: new Date().toISOString()
    });
  }
});

function processAlerts(entities) {
  if (!entities) return [];

  console.log(`[ALERTS] Processing ${entities.length} alert entities...`);

  const alerts = [];

  // Stations that sit on each Manhattan-bound leg of the commute
  const ROUTE_STATIONS = {
    M: ['knickerbocker', 'flushing', 'lorimer', 'hewes', 'marcy', 'essex', 'delancey', 'bowery', 'grand', 'canal', 'chambers', 'fulton', 'broad'],
    J: ['myrtle', 'broadway', 'chambers', 'fulton', 'broad'],
    L: ['dekalb', 'bedford', '1 av', '3 av', 'union sq', '6 av', '14 st', '8 av']
  };

  // Phrases that mean "not your problem" — instant discard
  const NOISE_PHRASES = [
    'brooklyn-bound',
    'jamaica center-bound',
    'middle village-bound',
    'queens-bound',
    'broadway junction',       // L, not on your route
    'atlantic av',             // L, south of DeKalb
    'atlantic-barclays',
    '8 av-bound',              // L westbound end — you're gone by then
    'broadway & 1',            // M northbound noise
    'astoria',
    'steinway',
    'forest hills',           // M northern terminus
    'metropolitan av',        // M northern section
    'runs between',           // "M runs between X and Delancey" = northern segment only
    'service to/from',        // Usually accompanies non-critical reroutings
  ];

  // Must contain at least ONE of these to be relevant (Manhattan-bound issues)
  const MUST_HAVE = [
    'suspended',
    'no service',
    'delays',
    'skip',
    'rerouted',
    'not stopping',
    'no '  // catches "no [L]" or "no L"
  ];

  entities.forEach((entity, idx) => {
    if (!entity.alert?.informedEntity) return;

    const routes = entity.alert.informedEntity
      .map(e => e.routeId)
      .filter(r => ['M', 'L', 'J'].includes(r));

    if (routes.length === 0) return;

    const header = entity.alert.headerText?.translation?.[0]?.text || '';
    const desc = entity.alert.descriptionText?.translation?.[0]?.text || '';
    const full = (header + ' ' + desc).toLowerCase();

    console.log(`[ALERT ${idx}] Routes: ${routes.join(',')} | "${header.substring(0, 60)}..."`);

    // ── TIME-BASED FILTERING: Only show alerts that are CURRENTLY ACTIVE ──
    const now = new Date();
    const activePeriod = entity.alert.activePeriod;

    if (activePeriod && activePeriod.length > 0) {
      let isActive = false;

      // Check all active periods (some alerts have multiple time windows)
      for (const period of activePeriod) {
        const startTime = period.start ? new Date(parseInt(period.start) * 1000) : null;
        const endTime = period.end ? new Date(parseInt(period.end) * 1000) : null;

        if (startTime && endTime) {
          // Check if alert crosses midnight (end time before start time = overnight alert)
          const crossesMidnight = endTime.getTime() < startTime.getTime();

          if (crossesMidnight) {
            // Overnight alert (e.g., 11:45 PM - 5:00 AM)
            // Active if we're AFTER start OR BEFORE end
            if (now.getTime() >= startTime.getTime() || now.getTime() <= endTime.getTime()) {
              isActive = true;
              break;
            }
          } else {
            // Normal same-day alert
            if (now.getTime() >= startTime.getTime() && now.getTime() <= endTime.getTime()) {
              isActive = true;
              break;
            }
          }
        } else if (startTime && !endTime) {
          // Only start time - active if we're past it
          if (now.getTime() >= startTime.getTime()) {
            isActive = true;
            break;
          }
        } else if (!startTime && endTime) {
          // Only end time - active if we're before it
          if (now.getTime() <= endTime.getTime()) {
            isActive = true;
            break;
          }
        } else {
          // No time bounds - always active
          isActive = true;
          break;
        }
      }

      if (!isActive) {
        console.log(`  ⏰ Not currently active`);
        return;
      }
      console.log(`  ✅ Currently active`);
    }

    // ── HARD REJECT: wrong direction or irrelevant segment ──
    const hasNoisePhrase = NOISE_PHRASES.some(p => full.includes(p));

    // Special exception: "runs between" rejection doesn't apply to L train if it mentions suspension/gap
    const isLSuspensionWithRunsBetween =
      routes.includes('L') &&
      full.includes('runs') &&
      (full.includes('myrtle') || full.includes('lorimer') || full.includes('two sections'));

    if (hasNoisePhrase && !isLSuspensionWithRunsBetween) {
      console.log(`  ❌ Rejected: matches noise phrase`);
      return;
    }

    // ── HARD REJECT: only Brooklyn/outbound directions mentioned ──
    if (full.includes('brooklyn') && !full.includes('manhattan')) {
      console.log(`  ❌ Rejected: Brooklyn-only`);
      return;
    }

    // ── MUST be a real service issue (not just informational) ──
    if (!MUST_HAVE.some(phrase => full.includes(phrase))) {
      console.log(`  ❌ Rejected: doesn't match MUST_HAVE keywords`);
      return;
    }

    // ── MUST mention at least one station on the actual commute ──
    let hitRoute = null;
    for (const r of routes) {
      const stationList = ROUTE_STATIONS[r];
      if (!stationList) continue;
      if (stationList.some(s => full.includes(s))) {
        hitRoute = r;
        console.log(`  ✅ Hit route ${r}: mentions relevant station`);
        break;
      }
    }

    // Special case: L line — only if fully suspended OR gap affects DeKalb
    if (!hitRoute && routes.includes('L')) {
      // Full line suspension
      const fullySuspended = full.includes('suspended') || (full.includes('no') && full.includes('service'));

      // Service gap that affects DeKalb (between Myrtle-Wyckoff and Lorimer creates gap at DeKalb)
      const gapAffectsDekalb =
        (full.includes('myrtle') && full.includes('lorimer')) ||
        (full.includes('runs in two sections') && full.includes('lorimer'));

      if (fullySuspended || gapAffectsDekalb) {
        hitRoute = 'L';
        console.log(`  ✅ L special case: suspended=${fullySuspended}, gap=${gapAffectsDekalb}`);
      }
    }

    if (!hitRoute) {
      console.log(`  ❌ Rejected: no relevant route match`);
      return;
    }

    // ── Only keep the route(s) that actually matter ──
    const keep = routes.filter(r => r === hitRoute || ROUTE_STATIONS[r]?.some(s => full.includes(s)));

    console.log(`  ✅ ACCEPTED: routes=${keep.join(',')}`);
    alerts.push({
      routes: keep,
      text: header.substring(0, 120),
      severity: entity.alert.severity || 'UNKNOWN'
    });
  });

  console.log(`[ALERTS] Returning ${alerts.length} relevant alerts`);
  return alerts.slice(0, 3);
}

// Process weather data with enhanced information (supports OpenWeather and Open-Meteo)
function processWeather(data, source = 'openmeteo') {
  if (!data) {
    return getDefaultWeather();
  }

  try {
    if (source === 'openweather') {
      // OpenWeather format
      const tempC = Math.round(data.main.temp);
      const tempF = Math.round((tempC * 9 / 5) + 32);
      const code = data.weather[0].id;
      const windspeed = data.wind.speed * 3.6; // Convert m/s to km/h

      return {
        tempC,
        tempF,
        icon: getWeatherIconFromOpenWeather(code),
        condition: data.weather[0].main,
        wind: Math.round(windspeed)
      };
    } else {
      // Open-Meteo format
      if (!data.current_weather) {
        return getDefaultWeather();
      }

      const tempC = Math.round(data.current_weather.temperature);
      const tempF = Math.round((tempC * 9 / 5) + 32);
      const code = data.current_weather.weathercode;
      const windspeed = data.current_weather.windspeed;

      return {
        tempC,
        tempF,
        icon: getWeatherIcon(code),
        condition: getWeatherCondition(code),
        wind: Math.round(windspeed)
      };
    }
  } catch (error) {
    console.error('[Weather] Processing error:', error.message);
    return getDefaultWeather();
  }
}

// Default weather when services fail
function getDefaultWeather() {
  return {
    tempC: '--',
    tempF: '--',
    icon: '☁️',
    condition: 'Unknown',
    wind: null
  };
}

// Weather icon mapping for OpenWeather codes
function getWeatherIconFromOpenWeather(code) {
  // OpenWeather uses different code system (200s = thunderstorm, 300s = drizzle, etc.)
  if (code >= 200 && code < 300) return '⛈️';  // Thunderstorm
  if (code >= 300 && code < 400) return '🌦️';  // Drizzle
  if (code >= 500 && code < 600) return '🌧️';  // Rain
  if (code >= 600 && code < 700) return '🌨️';  // Snow
  if (code >= 700 && code < 800) return '🌫️';  // Atmosphere (fog, mist, etc.)
  if (code === 800) return '☀️';              // Clear
  if (code === 801) return '🌤️';              // Few clouds
  if (code === 802) return '⛅';              // Scattered clouds
  if (code === 803 || code === 804) return '☁️'; // Broken/overcast clouds

  return '☁️'; // Default
}

// Weather icon mapping for Open-Meteo codes
function getWeatherIcon(code) {
  const icons = {
    0: '☀️',   // Clear sky
    1: '🌤️',   // Mainly clear
    2: '⛅',   // Partly cloudy
    3: '☁️',   // Overcast
    45: '🌫️',  // Fog
    48: '🌫️',  // Depositing rime fog
    51: '🌦️',  // Light drizzle
    53: '🌧️',  // Moderate drizzle
    55: '🌧️',  // Dense drizzle
    61: '🌧️',  // Slight rain
    63: '🌧️',  // Moderate rain
    65: '🌧️',  // Heavy rain
    71: '🌨️',  // Slight snow
    73: '🌨️',  // Moderate snow
    75: '🌨️',  // Heavy snow
    80: '🌦️',  // Slight rain showers
    81: '🌧️',  // Moderate rain showers
    82: '⛈️',   // Violent rain showers
    95: '⛈️'    // Thunderstorm
  };

  return icons[code] || '☁️';
}

// Weather condition text
function getWeatherCondition(code) {
  const conditions = {
    0: 'Clear',
    1: 'Mostly Clear',
    2: 'Partly Cloudy',
    3: 'Cloudy',
    45: 'Foggy',
    48: 'Foggy',
    51: 'Light Rain',
    53: 'Rain',
    55: 'Heavy Rain',
    61: 'Light Rain',
    63: 'Rain',
    65: 'Heavy Rain',
    71: 'Light Snow',
    73: 'Snow',
    75: 'Heavy Snow',
    80: 'Showers',
    81: 'Rain Showers',
    82: 'Heavy Showers',
    95: 'Thunderstorm'
  };

  return conditions[code] || 'Cloudy';
}

// Check motion sensor (async with error handling)
async function checkMotionSensor() {
  try {
    const { stdout } = await execAsync(`raspi-gpio get ${MOTION_GPIO_PIN}`);
    return stdout.includes('level=1');
  } catch (error) {
    // GPIO not available (not on Raspberry Pi or raspi-gpio not installed)
    // Silently return false instead of logging error
    return false;
  }
}

// Start server
app.listen(PORT, () => {
  console.log(`\n${'='.repeat(60)}`);
  console.log(`🚇 MTA Dashboard v3.3.0`);
  console.log(`${'='.repeat(60)}`);
  console.log(`📍 Server running on http://localhost:${PORT}`);
  console.log(`🌐 Network access: http://${DISCOVERED_IP}:${PORT}`);
  console.log(`📊 Tracking: M (${STOP_M}) & L (${STOP_L})`);
  console.log(`⚡ Cache duration: ${CACHE_DURATION}ms`);
  console.log(`🌤️  Weather: ${WEATHER_LAT}°N, ${WEATHER_LON}°W`);
  console.log(`   Primary: ${OPENWEATHER_API_KEY ? 'OpenWeather' : 'Open-Meteo (no API key)'}`);
  console.log(`   Fallback: ${OPENWEATHER_API_KEY ? 'Open-Meteo' : 'None'}`);
  console.log(`${'-'.repeat(60)}`);

  // Verify public directory structure
  const publicPath = path.join(__dirname, 'public');
  const indexPath = path.join(publicPath, 'index.html');
  const cssPath = path.join(publicPath, 'css', 'styles.css');
  const jsPath = path.join(publicPath, 'js', 'app.js');

  console.log('\n📁 File structure check:');
  console.log(`   public/ directory: ${fs.existsSync(publicPath) ? '✅' : '❌ MISSING'}`);
  console.log(`   index.html: ${fs.existsSync(indexPath) ? '✅' : '❌ MISSING'}`);
  console.log(`   css/styles.css: ${fs.existsSync(cssPath) ? '✅' : '❌ MISSING'}`);
  console.log(`   js/app.js: ${fs.existsSync(jsPath) ? '✅' : '❌ MISSING'}`);

  if (!fs.existsSync(publicPath)) {
    console.log('\n⚠️  WARNING: public/ directory not found!');
    console.log('   Please ensure the following structure exists:');
    console.log('   public/');
    console.log('   ├── index.html');
    console.log('   ├── css/');
    console.log('   │   └── styles.css');
    console.log('   └── js/');
    console.log('       └── app.js');
  }
  console.log();
});

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('\n📴 Shutting down gracefully...');
  process.exit(0);
});

process.on('SIGINT', () => {
  console.log('\n📴 Shutting down gracefully...');
  process.exit(0);
});