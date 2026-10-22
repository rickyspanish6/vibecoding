// Settings UI: who you are (account, password), users and their rights, power devices (Synaccess netBooters), and per-host
// settings (outlet mapping, power control, preferred console client). A classic script loaded before the main page script; it
// uses the page's helpers (el, $, ports, selected, renderList, renderDetail) only inside functions, so load order does not matter.

let cfg = { devices: [], mappings: {}, hosts: {} };
let power = { devices: [], byPort: {} };

async function api(method, path, body) {
  const r = await fetch(path, {
    method,
    headers: body === undefined ? {} : { 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const data = await r.json().catch(() => ({}));
  if (r.status === 401) { location.href = '/login'; throw new Error('Signed out'); } // the session ended
  if (r.status === 403 && data.code === 'must_change') { openPasswordDialog({ forced: true }); throw new Error(data.error); }
  if (!r.ok) throw new Error(data.error ?? `${method} ${path}: ${r.status}`);
  return data;
}

// --- who is signed in, and what they may do ------------------------------------------------------------------------------

let me = null; // { user: { username, roleLabel, permissions, mustChange }, roles, permissionLabels } from /api/me
let passwordChangeRequired = false;
const can = (permission) => Boolean(me?.user.permissions.includes(permission));

/** Load the account. Returns false when the page must stop (a new password has to be chosen first). */
async function loadMe() {
  me = await api('GET', '/api/me');
  applyRights();
  if (me.user.mustChange) { openPasswordDialog({ forced: true }); return false; }
  return true;
}

function applyRights() {
  const acc = $('account'); acc.hidden = false; acc.textContent = `${me.user.username} · ${me.user.roleLabel}`; acc.title = 'Your account';
  $('who').hidden = false;
  $('cfgBtn').hidden = !(can('configure') || can('users'));
  for (const id of ['clientMode', 'disconnectAll']) $(id).hidden = !can('console');
  if (typeof renderList === 'function') renderList();
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
  on: ['Power on', 'This switches the outlets on.'],
  off: ['Power off', 'Cuts power at once. The host is NOT shut down cleanly and can lose unsaved work or corrupt data.'],
  cycle: ['Cycle power', 'Cuts power at once and turns it back on after the unit\'s reboot delay. The host is NOT shut down cleanly.'],
};

function confirmPower(p, action) {
  const mapped = (cfg.mappings[p.id] ?? []).map((m) => ({ ...m }));
  const [verb, warning] = ACTION_TEXT[action];
  const picked = new Set(mapped.map((m) => `${m.device}:${m.outlet}`));
  const body = el('div', 'dlg-body');
  body.append(el('p', `dlg-note ${action === 'on' ? '' : 'bad'}`, warning));
  if (mapped.length > 1) body.append(el('h3', null, 'Outlets'), el('p', 'dlg-help', 'Untick an outlet to leave it alone.'));
  const list = el('ul', 'devs');
  for (const m of mapped) {
    const dev = cfg.devices.find((d) => d.id === m.device), o = power.devices.find((d) => d.id === m.device)?.outlets.find((x) => x.n === m.outlet);
    const li = el('li'), cb = input('checkbox'); cb.checked = true; cb.disabled = mapped.length === 1;
    cb.onchange = () => { cb.checked ? picked.add(`${m.device}:${m.outlet}`) : picked.delete(`${m.device}:${m.outlet}`); sync(); };
    const info = el('div', 'dev-info'); info.append(el('strong', null, `${dev?.name ?? m.device} · outlet ${m.outlet}`), el('span', 'meta', o ? `${o.name} · currently ${o.on ? 'ON' : 'OFF'}` : 'state unavailable'));
    const lab = el('label', 'check'); lab.append(cb, info); li.append(lab); list.append(li);
  }
  body.append(list);
  const result = note(''); body.append(result);
  const go = button(verb, action === 'on' ? 'primary' : 'primary danger-fill', async () => {
    go.disabled = true; go.textContent = 'Sending…';
    try {
      const r = await api('POST', `/api/power/hosts/${p.id}/${action}`, { confirmed: true, outlets: mapped.filter((m) => picked.has(`${m.device}:${m.outlet}`)) });
      result.className = 'dlg-note ok';
      result.textContent = `${verb} sent. ` + r.results.map((x) => `${shortName(x.deviceName)} #${x.outlet}: ${x.on ? 'ON' : 'OFF'}`).join(', ') + (r.cycling ? '. Cycling: the outlet comes back on shortly.' : '');
      go.textContent = 'Sent'; cancel.textContent = 'Close';
      loadPower(true);
      if (r.cycling) setTimeout(async () => { // the outlet comes back on a few seconds later: replace the stale "OFF"
        await loadPower(true);
        const now = power.byPort?.[p.id];
        if (now && document.getElementById('pwrDlg').open) result.textContent = `Cycle finished. Now: ${now.map((x) => `${shortName(x.deviceName)} #${x.outlet}: ${x.on === null ? 'unknown' : x.on ? 'ON' : 'OFF'}`).join(', ')}. The host is starting up.`;
      }, 9000);
    } catch (e) { result.className = 'dlg-note bad'; result.textContent = e.message; go.textContent = verb; sync(); }
  });
  const cancel = button('Cancel', '', () => document.getElementById('pwrDlg').close());
  const sync = () => { go.disabled = picked.size === 0; };
  sync();
  dialogShell('pwrDlg', `${verb} ${p.name}?`, body, [cancel, go]);
  cancel.focus(); // Enter or a stray click must not trigger the dangerous button
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
function dialogShell(id, title, body, footer, { closable = true } = {}) {
  const dlg = document.getElementById(id);
  dlg.replaceChildren();
  // Esc must not dismiss a forced dialog. Browsers only let a page cancel Esc after some user interaction, so if it closes
  // anyway while the change is still required, put it straight back.
  dlg.oncancel = closable ? null : (e) => e.preventDefault();
  dlg.onclose = closable ? null : () => { if (passwordChangeRequired && !dlg.open) dlg.showModal(); };
  const head = el('header', 'dlg-head'); head.append(el('h2', null, title));
  if (closable) { const x = el('button', 'icon', '✕'); x.setAttribute('aria-label', 'Close'); x.onclick = () => dlg.close(); head.append(x); }
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

let settingsTab = 'devices';

function tabBar() {
  const bar = el('div', 'tabs');
  for (const [id, label, ok] of [['devices', 'Power devices', can('configure')], ['users', 'Users', can('users')]]) {
    if (ok) bar.append(button(label, id === settingsTab ? 'tab on' : 'tab', () => (id === 'users' ? renderUsers() : renderSettings())));
  }
  return bar;
}

async function openSettings() {
  if (!can('configure')) settingsTab = 'users'; else if (!can('users')) settingsTab = 'devices';
  if (settingsTab === 'users') { renderUsers(); return; }
  renderSettings(); // open at once from what we already have, then refresh quietly
  await Promise.all([loadConfig(), loadPower()]);
  if (document.getElementById('cfgDlg').open && !document.querySelector('#cfgDlg form') && settingsTab === 'devices') renderSettings();
}

function renderSettings(message = '', kind = '') {
  settingsView++; settingsTab = 'devices';
  const body = el('div', 'dlg-body');
  body.append(tabBar(), el('h3', null, 'Power devices'), el('p', 'dlg-help', 'Synaccess netBooter PDUs, read over Telnet. Outlets are switched from each host\'s own settings (the gear next to its name).'));

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

  dialogShell('cfgDlg', 'Settings', body, [...(can('configure') ? [button('Add device', 'primary', () => renderDeviceForm())] : []), button('Close', '', () => document.getElementById('cfgDlg').close())]);
}

// --- Users ---------------------------------------------------------------------------------------------------------------------

let usersData = { users: [], roles: {}, permissionLabels: {} };

function generatePassword() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
  return [...crypto.getRandomValues(new Uint8Array(14))].map((b) => alphabet[b % alphabet.length]).join('');
}

const rightsText = (u) => (u.role === 'admin' ? 'all rights' : u.permissions.length ? u.permissions.map((k) => usersData.permissionLabels[k] ?? k).join(', ') : 'can view hosts only');

async function renderUsers(message = '', kind = '') {
  settingsView++; settingsTab = 'users';
  try { usersData = await api('GET', '/api/users'); } catch (e) { message = e.message; kind = 'bad'; }
  const body = el('div', 'dlg-body');
  body.append(tabBar(), el('h3', null, 'Users'), el('p', 'dlg-help', 'Everyone signed in can see the hosts and their power state. Rights decide what else they can do. A user whose password was set by an administrator must choose their own at the next sign-in.'));
  const list = el('ul', 'devs');
  for (const u of usersData.users) {
    const mine = u.id === me.user.id;
    const li = el('li'), info = el('div', 'dev-info');
    info.append(el('strong', null, `${u.username}${mine ? ' (you)' : ''}`), el('span', 'meta', `${u.roleLabel} · ${rightsText(u)}`),
      el('span', `meta ${u.disabled ? 'bad' : ''}`, `${u.disabled ? 'Disabled' : 'Active'}${u.mustChange ? ' · must choose a new password' : ''} · last sign-in ${u.lastLogin ? new Date(u.lastLogin).toLocaleString() : 'never'}`));
    const actions = el('div', 'dev-actions');
    if (!mine) {
      actions.append(
        button('Edit', '', () => renderUserForm(u)),
        button('Reset password', '', () => renderPasswordReset(u)),
        button(u.disabled ? 'Enable' : 'Disable', '', async () => {
          try { await api('PUT', `/api/users/${u.id}`, { disabled: !u.disabled }); await renderUsers(`${u.username} ${u.disabled ? 'enabled' : 'disabled'}.`, 'ok'); } catch (e) { renderUsers(e.message, 'bad'); }
        }),
        button('Remove', 'danger', async () => {
          if (!confirm(`Remove ${u.username}? They are signed out at once.`)) return;
          try { await api('DELETE', `/api/users/${u.id}`); await renderUsers(`${u.username} removed.`, 'ok'); } catch (e) { renderUsers(e.message, 'bad'); }
        }),
      );
    } else actions.append(el('span', 'meta', 'Change your password under Account'));
    li.append(info, actions); list.append(li);
  }
  body.append(list);
  if (message) body.append(note(message, kind));
  dialogShell('cfgDlg', 'Settings', body, [button('Add user', 'primary', () => renderUserForm()), button('Close', '', () => document.getElementById('cfgDlg').close())]);
}

function renderUserForm(user) {
  settingsView++;
  const editing = Boolean(user);
  const name = input('text', user?.username ?? '', { placeholder: 'user name', maxLength: 32, required: true, disabled: editing, autocomplete: 'off' });
  const pw = input('text', '', { placeholder: 'Temporary password', autocomplete: 'off', spellcheck: false });
  const gen = button('Generate', '', () => { pw.value = generatePassword(); });
  const role = el('select');
  for (const [k, r] of Object.entries(usersData.roles)) role.append(Object.assign(el('option', null, r.label), { value: k }));
  role.append(Object.assign(el('option', null, 'Custom…'), { value: 'custom' }));
  role.value = user ? user.role : 'viewer';
  const grid = el('div', 'perm-grid'), boxes = {};
  for (const [k, label] of Object.entries(usersData.permissionLabels)) {
    const cb = input('checkbox'); cb.checked = user?.permissions.includes(k) ?? false; boxes[k] = cb;
    const lab = el('label', 'check'); lab.append(cb, document.createTextNode(` ${label}`)); grid.append(lab);
  }
  const syncRights = () => {
    const preset = usersData.roles[role.value];
    for (const [k, cb] of Object.entries(boxes)) { if (preset) cb.checked = preset.permissions.includes(k); cb.disabled = Boolean(preset); }
  };
  role.onchange = syncRights; syncRights();
  const form = el('form', 'dlg-body');
  form.append(el('h3', null, editing ? `Edit ${user.username}` : 'Add a user'), field('User name', name));
  if (!editing) {
    const row = el('div', 'add-row pw-row'); row.append(pw, gen);
    const f = el('label', 'fld'); f.append(el('span', null, 'Temporary password (at least 10 characters)'), row); form.append(f);
  }
  form.append(field('Role', role), el('p', 'dlg-help', 'Pick a role, or Custom to choose the rights one by one.'), grid);
  const err = note(''); form.append(err);
  const save = button(editing ? 'Save' : 'Add user', 'primary', () => form.requestSubmit());
  form.onsubmit = async (ev) => {
    ev.preventDefault();
    const rights = { role: role.value, ...(role.value === 'custom' ? { permissions: Object.keys(boxes).filter((k) => boxes[k].checked) } : {}) };
    save.disabled = true;
    try {
      if (editing) { await api('PUT', `/api/users/${user.id}`, rights); await renderUsers(`${user.username} updated.`, 'ok'); }
      else { await api('POST', '/api/users', { username: name.value, password: pw.value, ...rights }); await renderUsers(`${name.value} added. Give them the temporary password ${pw.value}: they choose their own at first sign-in.`, 'ok'); }
    } catch (e) { err.textContent = e.message; err.className = 'dlg-note bad'; save.disabled = false; }
  };
  dialogShell('cfgDlg', 'Settings', form, [save, button('Back', '', () => renderUsers())]);
  (editing ? role : name).focus();
}

function renderPasswordReset(user) {
  settingsView++;
  const pw = input('text', generatePassword(), { autocomplete: 'off', spellcheck: false });
  const form = el('form', 'dlg-body');
  const row = el('div', 'add-row pw-row'); row.append(pw, button('Generate', '', () => { pw.value = generatePassword(); }));
  const f = el('label', 'fld'); f.append(el('span', null, 'New temporary password'), row);
  form.append(el('h3', null, `Reset the password of ${user.username}`), f,
    el('p', 'dlg-help', 'They are signed out everywhere and must choose their own password at the next sign-in. Give them this one yourself.'));
  const err = note(''); form.append(err);
  const save = button('Reset password', 'primary', () => form.requestSubmit());
  form.onsubmit = async (ev) => {
    ev.preventDefault(); save.disabled = true;
    try { await api('PUT', `/api/users/${user.id}`, { password: pw.value }); await renderUsers(`Password reset for ${user.username}. Temporary password: ${pw.value}`, 'ok'); }
    catch (e) { err.textContent = e.message; err.className = 'dlg-note bad'; save.disabled = false; }
  };
  dialogShell('cfgDlg', 'Settings', form, [save, button('Back', '', () => renderUsers())]);
}

// --- Account and password ------------------------------------------------------------------------------------------------------

function openAccount() { openPasswordDialog({ forced: false }); }

/** forced: the account must choose a new password before anything else (the dialog cannot be dismissed). */
function openPasswordDialog({ forced }) {
  if (forced) passwordChangeRequired = true;
  const cur = input('password', '', { autocomplete: 'current-password', required: true });
  const next = input('password', '', { autocomplete: 'new-password', required: true, minLength: 10 });
  const again = input('password', '', { autocomplete: 'new-password', required: true });
  const form = el('form', 'dlg-body');
  if (forced) form.append(note('Your password was set by an administrator. Choose your own to continue.'));
  else if (me) form.append(el('h3', null, me.user.username), el('p', 'dlg-help', `${me.user.roleLabel}. ${me.user.role === 'admin' ? 'All rights.' : me.user.permissions.length ? me.user.permissions.map((k) => me.permissionLabels[k] ?? k).join(', ') + '.' : 'You can view hosts only.'}`));
  form.append(el('h3', null, 'Change password'), field(forced ? 'Temporary password' : 'Current password', cur), field('New password (at least 10 characters)', next), field('Repeat the new password', again));
  const status = note(''); form.append(status);
  const save = button('Change password', 'primary', () => form.requestSubmit());
  form.onsubmit = async (ev) => {
    ev.preventDefault();
    if (next.value !== again.value) { status.textContent = 'The new passwords do not match'; status.className = 'dlg-note bad'; return; }
    save.disabled = true;
    try {
      await api('POST', '/api/me/password', { current: cur.value, next: next.value });
      if (forced) { location.reload(); return; }
      status.textContent = 'Password changed.'; status.className = 'dlg-note ok'; cur.value = next.value = again.value = ''; save.disabled = false;
    } catch (e) { status.textContent = e.message; status.className = 'dlg-note bad'; save.disabled = false; }
  };
  dialogShell('accDlg', forced ? 'Choose a new password' : 'Account', form, forced ? [save] : [save, button('Close', '', () => document.getElementById('accDlg').close())], { closable: !forced });
  cur.focus();
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
    const canCfg = can('configure'), canPower = can('power');
    const body = el('div', 'dlg-body');
    body.append(el('h3', null, 'Power outlets'), el('p', 'dlg-help', 'The outlets that feed this host. Use several for redundant power supplies.'));
    const list = el('ul', 'devs');
    if (!draft.length) list.append(el('li', 'empty', 'No outlet mapped.'));
    draft.forEach((m, i) => {
      const dev = cfg.devices.find((d) => d.id === m.device), o = outletInfo(m.device, m.outlet);
      const li = el('li'), info = el('div', 'dev-info');
      info.append(el('strong', null, `${dev?.name ?? m.device} · outlet ${m.outlet}`),
        el('span', 'meta', o ? `${o.name} · ${o.on ? 'ON' : 'OFF'}` : 'state unavailable'));
      if (canCfg) li.append(info, button('Remove', 'danger', () => { draft.splice(i, 1); render(); })); else li.append(info);
      list.append(li);
    });
    body.append(list);

    if (canCfg && cfg.devices.length) {
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
    } else if (canCfg) {
      body.append(note('Add a power device in Settings first.'));
    }

    // Power control: acts on the SAVED mapping, only when it is not locked, and only for people with the power right
    const saved = cfg.mappings[p.id] ?? [], dirty = JSON.stringify(draft) !== JSON.stringify(saved), locked = Boolean(cfg.hosts?.[p.id]?.locked);
    if (canPower) {
      body.append(el('h3', null, 'Power control'));
      if (!saved.length) body.append(el('p', 'dlg-help', canCfg ? 'Map and save an outlet above to enable power control.' : 'No outlet is mapped to this host.'));
      else {
        body.append(el('p', 'dlg-help', locked ? (canCfg ? 'Locked: untick "Lock power controls" below and save to use these.' : 'Power control is locked for this host by an administrator.') : dirty ? 'Save the outlet mapping first; power commands use the saved mapping.' : 'Switches real power. You are asked to confirm, and every command is written to the audit log.'));
        const row = el('div', 'pwr-row');
        for (const [action, label, cls] of [['on', 'Power on', ''], ['off', 'Power off', 'danger'], ['cycle', 'Cycle', 'danger']]) {
          const b = button(label, cls, () => confirmPower(p, action));
          b.disabled = locked || dirty; row.append(b);
        }
        body.append(row);
      }
    }

    if (canCfg) {
      const csel = el('select');
      for (const [v, t] of [['', 'Use the global choice'], ['native', 'Native client'], ['raritan', 'Raritan client (classic)']]) csel.append(Object.assign(el('option', null, t), { value: v, selected: v === client }));
      csel.onchange = () => { client = csel.value; };
      body.append(el('h3', null, 'Console client'), el('p', 'dlg-help', 'Override the console client for this host only.'), csel);
      const lockBox = input('checkbox'); lockBox.checked = lockDraft; lockBox.onchange = () => { lockDraft = lockBox.checked; };
      const lockLab = el('label', 'check'); lockLab.append(lockBox, document.createTextNode(' Lock power controls for this host (on / off / cycle are refused until unlocked)'));
      body.append(lockLab);
    }
    if (message) body.append(note(message, kind));

    const save = button('Save', 'primary', async (e) => {
      e.target.disabled = true;
      try { await api('PUT', `/api/config/hosts/${p.id}`, { outlets: draft, client, locked: lockDraft }); await loadConfig(); document.getElementById('hostDlg').close(); loadPower(true); }
      catch (err) { render(err.message, 'bad'); }
    });
    dialogShell('hostDlg', `${p.name} settings`, body, canCfg ? [save, button('Cancel', '', () => document.getElementById('hostDlg').close())] : [button('Close', '', () => document.getElementById('hostDlg').close())]);
  };
  render(); // open at once from the cached state, then pick up any fresher PDU reading
  Promise.all([loadConfig(), loadPower()]).then(() => { if (document.getElementById('hostDlg').open) render(); });
}

// Start (called once the account is known): config and power state, refreshed every 30 s (each refresh logs in to every PDU
// once, so keep it slow).
let settingsStarted = false;
function startSettings() {
  if (settingsStarted) return;
  settingsStarted = true;
  loadConfig().then(() => loadPower());
  setInterval(() => loadPower(), 30000);
}
