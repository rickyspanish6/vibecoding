// node --test test/   (no KX or PDU needed)
import test from 'node:test';
import assert from 'node:assert/strict';
import { outletMatchesHost, matchOutlets, parsePshow } from '../power.js';

test('outlet names match KX host names', () => {
  const yes = [
    ['XAG01', 'B25-CTL-XAG01'], ['xag01', 'B25-CTL-XAG01'], ['CTL-MAC01', 'B25-CTL-MAC01'], ['CTL-OPC02', 'B25-CTL-OPC02'],
    ['OPC01', 'B25-CTL-OPC01'], ['CTL-SYS01', 'B25-CTL-SYS01'], ['XAG00', 'B25-CTL-XAG00'], ['XAG01-02', 'B25-CTL-XAG01'], ['XAG01 B', 'B25-CTL-XAG01'],
    ['B25-CTL-XAG01', 'B25-CTL-XAG01'],
  ];
  for (const [o, h] of yes) assert.ok(outletMatchesHost(o, h), `${o} should match ${h}`);
  const no = [
    ['XAG01', 'B25-CTL-XAG02'], ['XAG1', 'B25-CTL-XAG01'], ['SWM01', 'B25-CTL-XAG01'], ['KVM01-01', 'B25-CTL-XAG01'], ['Outlet3', 'B25-CTL-MAC01'],
    ['Cisco 10G Switch', 'B25-CTL-MAC01'], ['RPS05-01', 'B25-CTL-XAG01'], ['CTL-INT00', 'B25-CTL-INT01'], ['XAG01-001', 'B25-CTL-XAG01'], ['', 'B25-CTL-XAG01'],
    ['NYC-MAC01', 'B25-CTL-MAC01'],
  ];
  for (const [o, h] of no) assert.ok(!outletMatchesHost(o, h), `${o} should not match ${h}`);
});

test('matchOutlets maps every host to its outlets across devices, skipping unconfigured ports', () => {
  const hosts = [
    { id: 1, name: 'B25-CTL-XAG00', configured: true }, { id: 7, name: 'N/C', configured: false },
    { id: 8, name: 'B25-CTL-OPC01', configured: true }, { id: 15, name: 'Dominion_KX3_Port15', configured: false },
  ];
  const devices = [
    { id: 'pdn02', outlets: [{ n: 14, name: 'OPC01' }, { n: 1, name: 'SWM02' }] },
    { id: 'pdn03', outlets: [{ n: 20, name: 'XAG00' }, { n: 3, name: 'Outlet3' }] },
    { id: 'pdn04', outlets: [{ n: 19, name: 'CTL-OPC02' }] },
  ];
  assert.deepEqual(matchOutlets(hosts, devices), { 1: [{ device: 'pdn03', outlet: 20 }], 8: [{ device: 'pdn02', outlet: 14 }] });
  const two = matchOutlets([{ id: 9, name: 'B25-CTL-NAS01', configured: true }], [{ id: 'a', outlets: [{ n: 15, name: 'NAS01-01' }, { n: 16, name: 'NAS01-02' }] }]);
  assert.deepEqual(two, { 9: [{ device: 'a', outlet: 15 }, { device: 'a', outlet: 16 }] }, 'redundant PSUs map to both outlets');
});

test('pshow output parses outlets, temperature and current', () => {
  const text = `pshow\n\n>\n\nPort|           Name |status|    Reservation |RB Timer\n----+----------------+------+----------------+--------\n   1|           SWM01|   ON |                |     OFF\n   5|  CTL-INT02|  OFF |                |     OFF\n  18|           XAG01|   ON |                |     OFF\n\nEnvironment Temperature: 25C. 77F.\n>\nAC current draw 1: 7.40. Max detected 9.63 Amps.\n`;
  const r = parsePshow(text);
  assert.deepEqual(r.outlets, [{ n: 1, name: 'SWM01', on: true }, { n: 5, name: 'CTL-INT02', on: false }, { n: 18, name: 'XAG01', on: true }]);
  assert.equal(r.tempC, 25);
  assert.equal(r.amps, 7.4);
});
