// MTA Dashboard v3.3.0 - Client Application
// Enhanced with error handling, better weather, and service alerts

let CONFIG = {};

let lastUpdate = new Date();
let retryCount = 0;
const MAX_RETRIES = 3;

// Initialize
async function init() {
  try {
    // Fetch config from server
    const configRes = await fetch('/api/config');
    CONFIG = await configRes.json();

    // Update UI with config
    document.getElementById('m-walk').innerText = CONFIG.WALK_M + 'm';
    document.getElementById('l-walk').innerText = CONFIG.WALK_L + 'm';
    document.getElementById('ip-display').innerText = 'IP: ' + CONFIG.IP;

    // Start clock
    updateClock();
    setInterval(updateClock, 1000);

    // First data fetch
    await tick();

    // Regular updates every 15 seconds
    setInterval(tick, 15000);
  } catch (error) {
    console.error('Initialization error:', error);
    showError('Failed to start dashboard');
  }
}

function updateClock() {
  const now = new Date();
  document.getElementById('clock').innerText = now.toLocaleTimeString('en-GB', { hour12: false });

  // Trash reminder: show Mon/Wed/Fri after 6pm for next day's collection
  // Tue: Trash + Recycling + Composting | Thu/Sat: Large Items + Trash
  // Collection schedule: Tue=🗑️♻️🌱, Thu=🛋️🗑️, Sat=🛋️🗑️
  // Always show next pickup day; go urgent (after 6pm) the evening before
  const day = now.getDay(); // 0=Sun,1=Mon,2=Tue,3=Wed,4=Thu,5=Fri,6=Sat
  const hour = now.getHours();
  const collections = [
    { day: 2, icons: '🗑️ ♻️ 🌱', name: 'Tue' },
    { day: 4, icons: '🛋️ 🗑️',    name: 'Thu' },
    { day: 6, icons: '🛋️ 🗑️',    name: 'Sat' },
  ];
  let next;
  for (let offset = 1; offset <= 7; offset++) {
    next = collections.find(c => c.day === (day + offset) % 7);
    if (next) { next = { ...next, daysUntil: offset }; break; }
  }
  const trashIndicator = document.getElementById('trash-indicator');
  if (next.daysUntil === 1 && hour >= 18) {
    trashIndicator.innerText = `${next.icons} Tonight!`;
    trashIndicator.classList.add('urgent');
  } else if (next.daysUntil === 1) {
    trashIndicator.innerText = `${next.icons} Tomorrow`;
    trashIndicator.classList.remove('urgent');
  } else {
    trashIndicator.innerText = `${next.icons} ${next.name}`;
    trashIndicator.classList.remove('urgent');
  }
  trashIndicator.style.display = 'flex';
}

function get24hTime(date) {
  return date.toLocaleTimeString('en-GB', { hour12: false });
}

async function tick() {
  const statusEl = document.getElementById('mta-status');
  const pulseEl = document.getElementById('sync-pulse');

  try {
    const res = await fetch('/api');

    if (!res.ok) {
      throw new Error(`HTTP ${res.status}: ${res.statusText}`);
    }

    const data = await res.json();

    // Reset error state
    retryCount = 0;
    pulseEl.classList.remove('error');
    statusEl.classList.remove('error');

    // Update timestamp
    lastUpdate = new Date();
    statusEl.innerText = 'NOMINAL • ' + get24hTime(lastUpdate);

    // Update trains
    updateUI('m', data.m, CONFIG.WALK_M);
    updateUI('l', data.l, CONFIG.WALK_L);

    // Update weather (enhanced)
    updateWeather(data.weather);

    // Update motion LED
    document.getElementById('motion-led').className = data.motion ? 'motion-dot active' : 'motion-dot';

    // Update alerts
    updateAlerts(data.alerts);

    // Update 55 Wall St ETAs
    updateWallStEta('m', data.wallStM);
    updateWallStEta('l', data.wallStL);

  } catch (error) {
    console.error('Data fetch error:', error);
    retryCount++;

    // Update UI to show error state
    pulseEl.classList.add('error');
    statusEl.classList.add('error');

    if (retryCount >= MAX_RETRIES) {
      statusEl.innerText = 'ERROR • No Connection';
      showError('Unable to reach MTA servers');
    } else {
      statusEl.innerText = `RETRYING (${retryCount}/${MAX_RETRIES}) • ${get24hTime(new Date())}`;
    }
  }
}

function updateWeather(weather) {
  if (!weather) return;

  document.getElementById('w-temp-c').innerText = weather.tempC + '°C';
  document.getElementById('w-temp-f').innerText = weather.tempF + '°F';
  document.getElementById('w-icon').innerText = weather.icon;
  document.getElementById('w-condition').innerText = weather.condition || '--';
  document.getElementById('w-wind').innerText = weather.wind ? weather.wind + ' km/h' : '--';
}

// Official MTA line colours
const LINE_COLORS = {
  m: '#FF6319',  // Orange
  l: '#A7A9AC',  // Grey
  j: '#996633'   // Brown
};

function updateAlerts(alerts) {
  // ── 1. GLANCE BAR: show/hide a badge per affected line ──
  const lines = { m: false, l: false, j: false };
  if (alerts) {
    alerts.forEach(a => {
      a.routes.forEach(r => {
        if (lines.hasOwnProperty(r.toLowerCase())) lines[r.toLowerCase()] = true;
      });
    });
  }

  ['m', 'l', 'j'].forEach(line => {
    const el = document.getElementById('glance-' + line);
    if (lines[line]) {
      el.className = 'glance-item visible';
      el.innerHTML = `<span class="glance-route" style="background:${LINE_COLORS[line]}">${line.toUpperCase()}</span><span class="glance-label">Disrupted</span>`;
    } else {
      el.className = 'glance-item';
      el.innerHTML = '';
    }
  });

  // ── 2. TICKER: single scrolling strip with all alert details ──
  const tickerWrap = document.getElementById('ticker-wrap');
  const ticker = document.getElementById('ticker');

  if (!alerts || alerts.length === 0) {
    tickerWrap.classList.remove('active');
    ticker.innerHTML = '';
    return;
  }

  tickerWrap.classList.add('active');

  // Build one segment per alert
  const segments = alerts.map(a => {
    const text = a.text
      .replace(/In Brooklyn, /gi, '')
      .replace(/In Manhattan, /gi, '')
      .replace(/Manhattan-bound/gi, '→Manh.')
      .replace(/Brooklyn-bound/gi, '→BK')
      .replace(/Jamaica Center-bound/gi, '→Jamaica')
      .replace(/Middle Village-bound/gi, '→Mid Vill.');

    const badges = a.routes.map(r =>
      `<span class="ticker-badge" style="background:${LINE_COLORS[r.toLowerCase()] || '#999'}">${r}</span>`
    ).join('');
    return `<span class="ticker-seg">${badges} ${text}</span>`;
  }).join('<span class="ticker-seg ticker-dot">•</span>');

  // Single alert = always static, Multiple alerts = always scroll
  if (alerts.length === 1) {
    // Static - no duplication, add static class to disable animation
    ticker.innerHTML = `<span class="ticker-scroll static">${segments}</span>`;
  } else {
    // Multiple alerts - duplicate and scroll
    ticker.innerHTML = `<span class="ticker-scroll">${segments}${segments}</span>`;
    const scrollEl = ticker.querySelector('.ticker-scroll');
    const totalWidth = scrollEl.scrollWidth / 2;
    const duration = Math.max(totalWidth / 60, 8);
    scrollEl.style.animationDuration = duration + 's';
  }
}

function updateUI(prefix, times, walk) {
  const action = document.getElementById(prefix + '-action');
  const etaValue = document.getElementById(prefix + '-eta');
  const next = document.getElementById(prefix + '-next');
  const card = document.getElementById('card-' + prefix);
  const now = Date.now();

  // ALL upcoming trains sorted earliest first
  const all = times
    .map(t => new Date(t))
    .filter(t => t > now)
    .sort((a, b) => a - b);

  // Catchable = you can still make it after walking
  const catchable = all.filter(t => (Math.floor((t - now) / 60000) - walk) > 0);

  // Reset states
  card.classList.remove('solid-green', 'flash-orange', 'error-state');
  action.classList.remove('green-text', 'orange-text', 'red-text');

  if (catchable.length === 0) {
    action.innerText = 'No Trains';
    action.classList.add('red-text');
    etaValue.innerText = '—';
    card.classList.add('error-state');

    // Still show upcoming times even if uncatchable
    if (all.length > 0) {
      next.innerHTML = all.slice(0, 2).map(t => {
        const timeStr = t.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
        const minsAway = Math.floor((t - now) / 60000);
        return `${timeStr} (${minsAway}m)`;
      }).join('<br>');
    } else {
      next.innerHTML = 'Check MTA.info';
    }
    return;
  }

  const t1 = catchable[0];
  const wait = Math.floor((t1 - now) / 60000);
  const leaveIn = wait - walk;

  // Update ETA
  etaValue.innerText = wait + 'm (' + t1.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' }) + ')';

  // Update action text and visual state
  if (leaveIn === 1) {
    action.innerText = 'Hurry up!';
    action.classList.add('orange-text');
    card.classList.add('flash-orange');
  } else if (leaveIn <= 3) {
    action.innerText = 'Leave now';
    action.classList.add('green-text');
    card.classList.add('solid-green');
  } else {
    action.innerText = 'In ' + leaveIn + ' mins';
  }

  // Next Trains: find t1 in the full list, then show the two trains after it
  const t1index = all.findIndex(t => t.getTime() === t1.getTime());
  const after = all.slice(t1index + 1, t1index + 3);

  if (after.length > 0) {
    next.innerHTML = after.map(t => {
      const timeStr = t.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
      const minsAway = Math.floor((t - now) / 60000);
      return `${timeStr} (${minsAway}m)`;
    }).join('<br>');
  } else {
    next.innerHTML = 'No additional trains';
  }
}

function updateWallStEta(prefix, ts) {
  const el = document.getElementById(prefix + '-wall-eta');
  if (!ts) { el.innerText = '—'; return; }
  const now = Date.now();
  const mins = Math.round((ts - now) / 60000);
  const timeStr = new Date(ts).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' });
  el.innerText = `${mins}m (${timeStr})`;
}

function showError(message) {
  // Could add a toast notification or modal here
  console.error('Dashboard Error:', message);
}

// Weather icon mapping (more detailed)
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
    77: '❄️',   // Snow grains
    80: '🌦️',  // Slight rain showers
    81: '🌧️',  // Moderate rain showers
    82: '⛈️',   // Violent rain showers
    85: '🌨️',  // Slight snow showers
    86: '🌨️',  // Heavy snow showers
    95: '⛈️',   // Thunderstorm
    96: '⛈️',   // Thunderstorm with hail
    99: '⛈️'    // Thunderstorm with heavy hail
  };

  return icons[code] || '☁️';
}

// Start the app when DOM is ready
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init);
} else {
  init();
}