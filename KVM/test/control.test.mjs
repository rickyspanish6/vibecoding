// node --test test/   Power control against a fake netBooter (no hardware): exact commands, refusals, audit log.
import test from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { mkdtempSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// --- a fake Synaccess NPB telnet server ------------------------------------------------------------------------------
function startFakePdu() {
  const outlets = Array.from({ length: 20 }, (_, i) => ({ n: i + 1, name: i === 1 ? 'CTL-MAC01' : `Outlet${i + 1}`, on: true }));
  const received = [];
  const table = () => 'Port|           Name |status|    Reservation |RB Timer\r\n----+----------------+------+----------------+--------\r\n' +
    outlets.map((o) => `${String(o.n).padStart(4)}|${o.name.padStart(16)}|${o.on ? '  ON ' : ' OFF '}|                |     OFF`).join('\r\n') + '\r\n\r\nEnvironment Temperature: 25C. 77F.\r\n>\r\nAC current draw 1: 1.48. Max detected 2.00 Amps.\r\n';
  const server = net.createServer((sock) => {
    let stage = 'user', buf = '';
    sock.write('\x1b[2J\x1b[32m\x1b[1mSynaccess Telnet V7.1\x1b[0m\r\n>Login: ');
    const handle = (line) => {
      if (stage === 'user') { stage = 'pass'; return sock.write('Password: '); }
      if (stage === 'pass') {
        if (line !== 'secret') { stage = 'user'; return sock.write('\r\nLogin incorrect\r\n>Login: '); }
        stage = 'cmd'; return sock.write('\r\n>');
      }
      received.push(line);
      const [cmd, a, b] = line.split(/\s+/);
      if (cmd === 'pshow') return sock.write(`\r\n>\r\n${table()}>`);
      if (cmd === 'pset') { outlets[Number(a) - 1].on = b === '1'; return sock.write('\r\n>'); }
      if (cmd === 'rb') { const o = outlets[Number(a) - 1]; o.on = false; setTimeout(() => { o.on = true; }, 200); return sock.write('\r\n>'); }
      sock.write('\r\nInvalid command\r\n>');
    };
    sock.on('data', (d) => { buf += d.toString('latin1'); let i; while ((i = buf.indexOf('\r\n')) >= 0) { const line = buf.slice(0, i); buf = buf.slice(i + 2); handle(line); } });
    sock.on('error', () => {});
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ server, outlets, received, port: server.address().port })));
}

const pdu = await startFakePdu();
const dir = mkdtempSync(join(tmpdir(), 'kx-control-'));
const audit = join(dir, 'power.log');
writeFileSync(join(dir, 'config.json'), JSON.stringify({
  devices: [{ id: 'pdn04', name: 'B25-CTL-PDN04', host: '127.0.0.1', port: pdu.port, user: 'mofa', password: 'secret' }],
  mappings: { 10: [{ device: 'pdn04', outlet: 2 }], 9: [{ device: 'pdn04', outlet: 5 }], 6: [{ device: 'pdn04', outlet: 6 }, { device: 'pdn04', outlet: 7 }] },
  hosts: { 9: { locked: true } },
}));
process.env.KX_CONFIG_PATH = join(dir, 'config.json');
process.env.KX_POWER_LOG = audit;
process.env.KX_POWER_COOLDOWN_MS = '400';
const { controlHost } = await import('../power.js');
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const MAC = { port: 10, hostName: 'B25-CTL-MAC01', confirm: 'B25-CTL-MAC01' };

test.after(() => pdu.server.close());

test('refuses without the exact host name, and sends nothing', async () => {
  for (const confirm of ['', 'MAC01', 'b25-ctl-mac01', undefined]) {
    await assert.rejects(() => controlHost({ ...MAC, action: 'off', confirm }), (e) => e.status === 400);
  }
  assert.equal(pdu.received.length, 0, 'no command may reach the PDU');
});

test('refuses unknown actions, unmapped hosts, foreign outlets and locked hosts', async () => {
  await assert.rejects(() => controlHost({ ...MAC, action: 'explode' }), (e) => e.status === 400);
  await assert.rejects(() => controlHost({ port: 3, hostName: 'B25-CTL-XAG02', confirm: 'B25-CTL-XAG02', action: 'off' }), (e) => e.status === 400 && /no outlet mapped/.test(e.message));
  await assert.rejects(() => controlHost({ ...MAC, action: 'off', outlets: [{ device: 'pdn04', outlet: 5 }] }), (e) => e.status === 400 && /not mapped to this host/.test(e.message));
  await assert.rejects(() => controlHost({ port: 9, hostName: 'B25-CTL-OPC02', confirm: 'B25-CTL-OPC02', action: 'off' }), (e) => e.status === 423);
  assert.equal(pdu.received.length, 0);
});

test('on, off and cycle send the exact commands and read the state back', async () => {
  let r = await controlHost({ ...MAC, action: 'off' });
  assert.deepEqual(pdu.received, ['pset 2 0', 'pshow']);
  assert.equal(r.results[0].on, false); assert.equal(r.results[0].outlet, 2); assert.equal(r.results[0].name, 'CTL-MAC01');
  await wait(450);
  pdu.received.length = 0;
  r = await controlHost({ ...MAC, action: 'on' });
  assert.deepEqual(pdu.received, ['pset 2 1', 'pshow']);
  assert.equal(r.results[0].on, true);
  await wait(450);
  pdu.received.length = 0;
  r = await controlHost({ ...MAC, action: 'cycle' });
  assert.deepEqual(pdu.received, ['rb 2', 'pshow']);
  assert.equal(r.cycling, true);
  await wait(450);
  assert.equal(pdu.outlets[1].on, true, 'the outlet comes back on after the reboot delay');
});

test('a second command is refused while one is running and during the cooldown after it', async () => {
  await wait(450);
  const first = controlHost({ ...MAC, action: 'on' });
  await assert.rejects(() => controlHost({ ...MAC, action: 'off' }), (e) => e.status === 429 && /already running/.test(e.message));
  await first;
  await assert.rejects(() => controlHost({ ...MAC, action: 'off' }), (e) => e.status === 429 && /Wait/.test(e.message));
  assert.equal(pdu.outlets[1].on, true, 'the refused commands must not have switched anything');
});

test('a host with two outlets (redundant supplies) switches both, or just the one chosen', async () => {
  pdu.received.length = 0; await wait(450);
  const both = await controlHost({ port: 6, hostName: 'B25-CTL-XAG05', confirm: 'B25-CTL-XAG05', action: 'off' });
  assert.deepEqual(pdu.received, ['pset 6 0', 'pset 7 0', 'pshow']);
  assert.deepEqual(both.results.map((x) => [x.outlet, x.on]), [[6, false], [7, false]]);
  await wait(450); pdu.received.length = 0;
  await controlHost({ port: 6, hostName: 'B25-CTL-XAG05', confirm: 'B25-CTL-XAG05', action: 'on', outlets: [{ device: 'pdn04', outlet: 7 }] });
  assert.deepEqual(pdu.received, ['pset 7 1', 'pshow']);
  assert.equal(pdu.outlets[5].on, false, 'the other outlet is left alone');
});

test('a rejected login is reported and every accepted request is in the audit log', async () => {
  const lines = readFileSync(audit, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  assert.ok(lines.length >= 5);
  assert.ok(lines.every((l) => l.at && l.host && l.action && l.result));
  assert.ok(lines.some((l) => l.action === 'cycle' && l.host === 'B25-CTL-MAC01' && l.result === 'sent'));
  assert.ok(!lines.some((l) => l.host === 'B25-CTL-OPC02'), 'refused requests are not logged as sent');
  assert.ok(existsSync(audit));
  assert.ok(!JSON.stringify(lines).includes('secret'), 'the audit log never holds a password');
});
