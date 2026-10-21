// Settings UI: power devices (Synaccess netBooters), per-host settings (power outlet mapping, preferred console client).
// A classic script loaded before the main page script; it uses the page's helpers (el, $, ports, selected, renderList,
// renderDetail) only inside functions, so load order does not matter. Everything here is read-only towards the PDUs.

let cfg = { devices: [], mappings: {}, hosts: {} };
let power = { devices: [], byPort: {} };

async function api(method, path, body) {
  const r = await fetch(path, {
    method,
    headers: body === undefined ? {} : { 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(data.error ?? `${method} ${path}: ${r.status}`);
  return data;
}

async function loadConfig() { try { cfg = await api('GET', '/api/config'); } catch { /* keep the last config */ } }

async function loadPower(refresh = false) {
  try { power = await api('GET', `/api/power${refresh ? '?refresh=1' : ''}`); } catch { /* keep the last reading */ }
  if (typeof renderList === 'function') renderList();
  updatePowerChip();
}

const shortName = (name) => String(name).replace(/^B25-CTL-/, '');
const hostName = (id) => (typeof ports !== 'undefined' ? ports.find((p) => p.id === Number(id))?.name : null) ?? `port ${id}`;

// --- indicators on the host list and the header ------------------------------------------------------------------

function powerState(portId) {
  const m = power.byPort?.[portId];
  if (!m?.length) return null;
  const known = m.filter((x) => x.on !== null);
  const state = !known.length ? 'unknown' : known.every((x) => x.on) ? 'on' : known.every((x) => !x.on) ? 'off' : 'partial';
  const text = m.map((x) => `${shortName(x.deviceName)} outlet ${x.outlet}${x.name ? ` (${x.name})` : ''}: ${x.on === null ? 'unknown' : x.on ? 'ON' : 'OFF'}`).join('\n');
  return { state, text, list: m };
}

function powerBadge(p) {
  const s = powerState(p.id);
  if (!s) return null;
  const b = el('span', `pw ${s.state}`, '⚡︎');
  b.title = `Power\n${s.text}`;
  return b;
}

function updatePowerChip() {
  const chip = document.getElementById('pwr');
  if (!chip) return;
  const s = typeof selected !== 'undefined' && selected != null ? powerState(selected) : null;
  chip.hidden = !s;
  if (!s) return;
  const label = s.list.length === 1 ? `${shortName(s.list[0].deviceName)} #${s.list[0].outlet}` : `${s.list.length} outlets`;
  chip.textContent = `⚡︎ ${label} · ${{ on: 'On', off: 'Off', partial: 'Partly on', unknown: 'Unknown' }[s.state]}`;
  chip.className = `chip pwr ${s.state}`;
  chip.title = s.text;
}

// --- Power command confirmation -----------------------------------------------------------------------------------------

const ACTION_TEXT = {
  on: ['Power on', 'Switches the outlets on.'],
  off: ['Power off', 'Cuts power at once. The host is NOT shut down cleanly and can lose unsaved work or corrupt data.'],
  cycle: ['Cycle power', 'Cuts power at once and turns it back on after the unit\'s reboot delay. The host is NOT shut down cleanly.'],
};

function confirmPower(p, action) {
  const mapped = (cfg.mappings[p.id] ?? []).map((m) => ({ ...m }));
  const [verb, warning] = ACTION_TEXT[action];
  const picked = new Set(mapped.map((m) => `${m.device}:${m.outlet}`));
  const typed = input('text', '', { placeholder: p.name, autocomplete: 'off', spellcheck: false });
  const body = el('div', 'dlg-body');
  body.append(el('p', `dlg-note ${action === 'on' ? '' : 'bad'}`, warning), el('h3', null, `Outlets for ${p.name}`));
  const list = el('ul', 'devs');
  for (const m of mapped) {
    const dev = cfg.devices.find((d) => d.id === m.device), o = power.devices.find((d) => d.id === m.device)?.outlets.find((x) => x.n === m.outlet);
    const li = el('li'), cb = input('checkbox'); cb.checked = true;
    cb.onchange = () => { cb.checked ? picked.add(`${m.device}:${m.outlet}`) : picked.delete(`${m.device}:${m.outlet}`); sync(); };
    const info = el('div', 'dev-info'); info.append(el('strong', null, `${dev?.name ?? m.device} · outlet ${m.outlet}`), el('span', 'meta', o ? `${o.name} · currently ${o.on ? 'ON' : 'OFF'}` : 'state unavailable'));
    const lab = el('label', 'check'); lab.append(cb, info); li.append(lab); list.append(li);
  }
  body.append(list, field(`Type ${p.name} to confirm`, typed));
  const result = note(''); body.append(result);
  const go = button(verb, 'primary danger-fill', async () => {
    go.disabled = true; typed.disabled = true; go.textContent = 'Sending…';
    try {
      const r = await api('POST', `/api/power/hosts/${p.id}/${action}`, { confirm: typed.value, outlets: mapped.filter((m) => picked.has(`${m.device}:${m.outlet}`)) });
      result.className = 'dlg-note ok';
      result.textContent = `${verb} sent. ` + r.results.map((x) => `${shortName(x.deviceName)} #${x.outlet}: ${x.on ? 'ON' : 'OFF'}`).join(', ') + (r.cycling ? '. Cycling: the outlet comes back on shortly.' : '');
      go.textContent = 'Sent'; cancel.textContent = 'Close';
      loadPower(true);
      if (r.cycling) setTimeout(async () => { // the outlet comes back on a few seconds later: replace the stale "OFF"
        await loadPower(true);
        const now = power.byPort?.[p.id];
        if (now && document.getElementById('pwrDlg').open) result.textContent = `Cycle finished. Now: ${now.map((x) => `${shortName(x.deviceName)} #${x.outlet}: ${x.on === null ? 'unknown' : x.on ? 'ON' : 'OFF'}`).join(', ')}. The host is starting up.`;
      }, 9000);
    } catch (e) { result.className = 'dlg-note bad'; result.textContent = e.message; go.textContent = verb; typed.disabled = false; sync(); }
  });
  const cancel = button('Cancel', '', () => document.getElementById('pwrDlg').close());
  const sync = () => { go.disabled = typed.value !== p.name || picked.size === 0; };
  typed.oninput = sync; sync();
  dialogShell('pwrDlg', `${verb}: ${p.name}?`, body, [go, cancel]);
  typed.focus();
}

// A host with its own client choice differs from the selector, so say so next to it.
function updateClientHint() {
  const hint = document.getElementById('chint'), c = typeof selected !== 'undefined' && selected != null ? cfg.hosts?.[selected]?.client : '';
  if (hint) hint.textContent = c ? `This host: ${c === 'native' ? 'native' : 'Raritan'} client` : '';
}

// --- dialog helpers -------------------------------------------------------------------------------------------------

function field(label, input) {
  const wrap = el('label', 'fld'); wrap.append(el('span', null, label), input); return wrap;
}
function input(type, value = '', attrs = {}) {
  const i = el('input'); i.type = type; i.value = value; Object.assign(i, attrs); return i;
}
function dialogShell(id, title, body, footer) {
  const dlg = document.getElementById(id);
  dlg.replaceChildren();
  const head = el('header', 'dlg-head'); head.append(el('h2', null, title));
  const x = el('button', 'icon', '✕'); x.setAttribute('aria-label', 'Close'); x.onclick = () => dlg.close(); head.append(x);
  const foot = el('footer', 'dlg-foot'); foot.append(...footer);
  dlg.append(head, body, foot);
  if (!dlg.open) dlg.showModal();
  return dlg;
}
function note(text, kind = '') { const n = el('p', `dlg-note ${kind}`, text); n.setAttribute('role', 'status'); return n; }
function button(label, cls, fn) { const b = el('button', `dbtn ${cls ?? ''}`, label); b.type = 'button'; b.onclick = fn; return b; }

// --- Settings dialog: power devices ---------------------------------------------------------------------------------

// Reading four PDUs takes a few seconds, so show the outcome straight away and redraw once the fresh reading is in.
let settingsView = 0; // bumped on every draw; a background redraw only happens if nothing else was drawn since

async function afterChange(message, kind = 'ok', refresh = true) {
  await loadConfig();
  renderSettings(message, kind);
  const mine = settingsView;
  loadPower(refresh).then(() => {
    const dlg = document.getElementById('cfgDlg');
    if (dlg.open && mine === settingsView) renderSettings(message, kind);
  });
}

function deviceStatus(d) {
  const r = power.devices?.find((x) => x.id === d.id);
  if (!r) return { text: 'not read yet', cls: '' };
  return r.ok ? { text: `${r.outlets.length} outlets · ${r.amps ?? '?'} A`, cls: 'ok' } : { text: r.error, cls: 'bad' };
}

async function openSettings() {
  renderSettings(); // open at once from what we already have, then refresh quietly
  await Promise.all([loadConfig(), loadPower()]);
  if (document.getElementById('cfgDlg').open && !document.querySelector('#cfgDlg form')) renderSettings();
}

function renderSettings(message = '', kind = '') {
  settingsView++;
  const body = el('div', 'dlg-body');
  body.append(el('h3', null, 'Power devices'), el('p', 'dlg-help', 'Synaccess netBooter PDUs, read over Telnet. The dashboard only reads outlet names and state; it never switches an outlet.'));

  const list = el('ul', 'devs');
  if (!cfg.devices.length) list.append(el('li', 'empty', 'No devices yet.'));
  for (const d of cfg.devices) {
    const st = deviceStatus(d);
    const li = el('li'), info = el('div', 'dev-info');
    info.append(el('strong', null, d.name), el('span', 'meta', `${d.host}:${d.port} · ${d.user}`), el('span', `meta ${st.cls}`, st.text));
    const actions = el('div', 'dev-actions');
    actions.append(
      button('Test', '', async (e) => {
        e.target.disabled = true; e.target.textContent = 'Testing…';
        try { const r = await api('POST', `/api/config/devices/${d.id}/test`, {}); await loadPower(); renderSettings(`${d.name}: connected, ${r.outlets} outlets (${r.named} named).`, 'ok'); }
        catch (err) { await loadPower(); renderSettings(`${d.name}: ${err.message}`, 'bad'); }
      }),
      button('Edit', '', () => renderDeviceForm(d)),
      button('Remove', 'danger', async () => {
        if (!confirm(`Remove ${d.name}? Outlet mappings that use it are removed too.`)) return;
        try { await api('DELETE', `/api/config/devices/${d.id}`); await afterChange(`${d.name} removed.`, 'ok', false); }
        catch (err) { renderSettings(err.message, 'bad'); }
      }),
    );
    li.append(info, actions); list.append(li);
  }
  body.append(list);

  const over = input('checkbox'); over.id = 'amOverwrite';
  const lab = el('label', 'check'); lab.append(over, document.createTextNode(' Replace mappings I set by hand'));
  const matchRow = el('div', 'match-row');
  matchRow.append(button('Auto-match outlets to hosts', '', async (e) => {
    e.target.disabled = true; e.target.textContent = 'Matching…';
    try {
      const r = await api('POST', '/api/power/automap', { overwrite: over.checked });
      await afterChange(`Matched ${r.matched} host${r.matched === 1 ? '' : 's'}.${r.unreachable.length ? ` Unreachable: ${r.unreachable.join(', ')}.` : ''}`, r.unreachable.length ? 'bad' : 'ok', false);
    } catch (err) { renderSettings(err.message, 'bad'); }
  }), lab);
  body.append(matchRow);
  if (message) body.append(note(message, kind));

  dialogShell('cfgDlg', 'Settings', body, [button('Add device', 'primary', () => renderDeviceForm()), button('Close', '', () => document.getElementById('cfgDlg').close())]);
}

function renderDeviceForm(dev) {
  settingsView++;
  const editing = Boolean(dev);
  const name = input('text', dev?.name ?? '', { placeholder: 'B25-CTL-PDN05', maxLength: 60, required: true });
  const host = input('text', dev?.host ?? '', { placeholder: '172.16.0.50', required: true });
  const port = input('number', String(dev?.port ?? 23), { min: 1, max: 65535 });
  const user = input('text', dev?.user ?? '', { autocomplete: 'off', required: true });
  const pass = input('password', '', { autocomplete: 'new-password', placeholder: editing ? 'Leave blank to keep the current password' : '' });
  const form = el('form', 'dlg-body');
  form.append(el('h3', null, editing ? `Edit ${dev.name}` : 'Add a power device'),
    field('Name', name), field('IP address or host name', host), field('Telnet port', port), field('User', user), field('Password', pass),
    el('p', 'dlg-help', 'Stored in .kx-config.json on this machine (owner-only, never sent to the browser). Telnet is not encrypted: keep these devices on a trusted network.'));
  const err = note('');
  form.append(err);
  const save = button(editing ? 'Save' : 'Add', 'primary', () => form.requestSubmit());
  form.onsubmit = async (ev) => {
    ev.preventDefault();
    const body = { name: name.value, host: host.value, port: Number(port.value), user: user.value, ...(pass.value ? { password: pass.value } : {}) };
    save.disabled = true; save.textContent = 'Saving…';
    try {
      if (editing) await api('PUT', `/api/config/devices/${dev.id}`, body); else await api('POST', '/api/config/devices', body);
      await afterChange(`${body.name} saved. Reading its outlets…`, 'ok');
    } catch (e) { err.textContent = e.message; err.className = 'dlg-note bad'; save.disabled = false; save.textContent = editing ? 'Save' : 'Add'; }
  };
  dialogShell('cfgDlg', 'Settings', form, [save, button('Back', '', () => renderSettings())]);
  name.focus();
}

// --- Host settings dialog (the cogwheel on each host) ----------------------------------------------------------------

async function openHostSettings(p) {
  let draft = (cfg.mappings[p.id] ?? []).map((x) => ({ ...x }));
  let client = cfg.hosts?.[p.id]?.client ?? '';
  let lockDraft = Boolean(cfg.hosts?.[p.id]?.locked);

  const usedBy = (device, outlet) => {
    for (const [port, list] of Object.entries(cfg.mappings)) {
      if (Number(port) !== p.id && list.some((x) => x.device === device && x.outlet === outlet)) return shortName(hostName(port));
    }
    return null;
  };
  const outletInfo = (device, n) => power.devices.find((d) => d.id === device)?.outlets.find((o) => o.n === n);

  const render = (message = '', kind = '') => {
    const body = el('div', 'dlg-body');
    body.append(el('h3', null, 'Power outlets'), el('p', 'dlg-help', 'The outlets that feed this host. Use several for redundant power supplies.'));
    const list = el('ul', 'devs');
    if (!draft.length) list.append(el('li', 'empty', 'No outlet mapped.'));
    draft.forEach((m, i) => {
      const dev = cfg.devices.find((d) => d.id === m.device), o = outletInfo(m.device, m.outlet);
      const li = el('li'), info = el('div', 'dev-info');
      info.append(el('strong', null, `${dev?.name ?? m.device} · outlet ${m.outlet}`),
        el('span', 'meta', o ? `${o.name} · ${o.on ? 'ON' : 'OFF'}` : 'state unavailable'));
      li.append(info, button('Remove', 'danger', () => { draft.splice(i, 1); render(); }));
      list.append(li);
    });
    body.append(list);

    if (cfg.devices.length) {
      const dsel = el('select'); for (const d of cfg.devices) dsel.append(Object.assign(el('option', null, d.name), { value: d.id }));
      const osel = el('select');
      const fill = () => {
        osel.replaceChildren();
        const outlets = power.devices.find((d) => d.id === dsel.value)?.outlets ?? [];
        if (!outlets.length) osel.append(Object.assign(el('option', null, 'Device unreachable: no outlet list'), { value: '' }));
        for (const o of outlets) {
          const u = usedBy(dsel.value, o.n), taken = draft.some((x) => x.device === dsel.value && x.outlet === o.n);
          osel.append(Object.assign(el('option', null, `${o.n} · ${o.name}${o.on ? '' : ' (OFF)'}${u ? ` · used by ${u}` : ''}`), { value: String(o.n), disabled: taken }));
        }
      };
      dsel.onchange = fill; fill();
      const add = el('div', 'add-row');
      add.append(dsel, osel, button('Add outlet', '', () => {
        if (!osel.value) return;
        draft.push({ device: dsel.value, outlet: Number(osel.value) }); render();
      }));
      body.append(add);
    } else {
      body.append(note('Add a power device in Settings first.'));
    }

    // Power control: acts on the SAVED mapping and only when it is not locked
    const saved = cfg.mappings[p.id] ?? [], dirty = JSON.stringify(draft) !== JSON.stringify(saved), locked = Boolean(cfg.hosts?.[p.id]?.locked);
    body.append(el('h3', null, 'Power control'));
    if (!saved.length) body.append(el('p', 'dlg-help', 'Map and save an outlet above to enable power control.'));
    else {
      body.append(el('p', 'dlg-help', locked ? 'Locked: untick "Lock power controls" below and save to use these.' : dirty ? 'Save the outlet mapping first; power commands use the saved mapping.' : 'Switches real power. Every command asks you to type this host\'s name first, and is written to the audit log.'));
      const row = el('div', 'pwr-row');
      for (const [action, label, cls] of [['on', 'Power on', ''], ['off', 'Power off', 'danger'], ['cycle', 'Cycle', 'danger']]) {
        const b = button(label, cls, () => confirmPower(p, action));
        b.disabled = locked || dirty; row.append(b);
      }
      body.append(row);
    }

    const csel = el('select');
    for (const [v, t] of [['', 'Use the global choice'], ['native', 'Native client'], ['raritan', 'Raritan client (classic)']]) csel.append(Object.assign(el('option', null, t), { value: v, selected: v === client }));
    csel.onchange = () => { client = csel.value; };
    body.append(el('h3', null, 'Console client'), el('p', 'dlg-help', 'Override the console client for this host only.'), csel);
    const lockBox = input('checkbox'); lockBox.checked = lockDraft; lockBox.onchange = () => { lockDraft = lockBox.checked; };
    const lockLab = el('label', 'check'); lockLab.append(lockBox, document.createTextNode(' Lock power controls for this host (on / off / cycle are refused until unlocked)'));
    body.append(lockLab);
    if (message) body.append(note(message, kind));

    const save = button('Save', 'primary', async (e) => {
      e.target.disabled = true;
      try { await api('PUT', `/api/config/hosts/${p.id}`, { outlets: draft, client, locked: lockDraft }); await loadConfig(); document.getElementById('hostDlg').close(); loadPower(true); }
      catch (err) { render(err.message, 'bad'); }
    });
    dialogShell('hostDlg', `${p.name} settings`, body, [save, button('Cancel', '', () => document.getElementById('hostDlg').close())]);
  };
  render(); // open at once from the cached state, then pick up any fresher PDU reading
  Promise.all([loadConfig(), loadPower()]).then(() => { if (document.getElementById('hostDlg').open) render(); });
}

// Start: config and power state, refreshed every 30 s (each refresh logs in to every PDU once, so keep it slow).
loadConfig().then(() => loadPower());
setInterval(() => loadPower(), 30000);
