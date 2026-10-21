// node --test test/   Update pacing and automatic quality (pure logic, no hardware).
import test from 'node:test';
import assert from 'node:assert/strict';
import { UpdatePacer, QualityGovernor, averageDelay } from '../public/native/pacing.js';

test('the pacer requests as soon as an update arrives, not after it is decoded', () => {
  const p = new UpdatePacer();
  p.markRequested();                     // the initial request is out
  assert.equal(p.onReceived(), 1);       // update 1 arrives: ask for the next one at once
  assert.equal(p.onDecoded(), 0);        // decoding finishing adds nothing: a request is already out
});

test('the pacer never lets more than `undecoded` updates wait for the decoder', () => {
  const p = new UpdatePacer({ undecoded: 2 });
  p.markRequested();
  assert.equal(p.onReceived(), 1);       // 1 undecoded, next request sent
  assert.equal(p.onReceived(), 0);       // 2 undecoded: held back
  assert.equal(p.onReceived(), 0);       // 3 undecoded: still held back
  assert.equal(p.onDecoded(), 0);        // 2 left: at the limit
  assert.equal(p.onDecoded(), 1);        // 1 left: the held-back request goes out
  assert.equal(p.onDecoded(), 0);        // one is already outstanding
});

test('a depth of two keeps two requests in flight, and never more', () => {
  const p = new UpdatePacer({ requests: 2, undecoded: 4 });
  p.markRequested();
  assert.equal(p.onReceived(), 2, 'top up to two outstanding');
  assert.equal(p.onReceived(), 1);
  assert.equal(p.onDecoded(), 0);
  assert.ok(p.outstanding <= 2);
});

test('the governor ignores idle screens and short blips', () => {
  const g = new QualityGovernor();
  for (let i = 0; i < 20; i++) assert.equal(g.update({ fps: 0, kbps: 0, delay: null }), null);
  const starved = { fps: 3, kbps: 9000, delay: 150 };
  assert.equal(g.update(starved), null);
  assert.equal(g.update(starved), null);
  assert.equal(g.update({ fps: 12, kbps: 2000, delay: 90 }), null, 'a good second resets the streak');
  assert.equal(g.quality, 13);
});

test('a slow-to-answer link alone does not lower quality (it is latency-bound, quality would not help)', () => {
  const g = new QualityGovernor();
  for (let i = 0; i < 60; i++) assert.equal(g.update({ fps: 2, kbps: 150, delay: 900 }), null);
  assert.equal(g.quality, 13);
});

test('the governor steps down after three bandwidth-starved seconds, down to its floor', () => {
  const g = new QualityGovernor({ start: 13, min: 5 });
  const starved = { fps: 2, kbps: 9000, delay: 450 };
  assert.equal(g.update(starved), null); assert.equal(g.update(starved), null);
  assert.equal(g.update(starved), 11);
  for (let i = 0; i < 3; i++) g.update(starved);
  assert.equal(g.quality, 9);
  for (let i = 0; i < 30; i++) g.update(starved);
  assert.equal(g.quality, 5, 'never below the floor');
});

test('the governor recovers one step after ten good seconds, up to its ceiling', () => {
  const g = new QualityGovernor({ start: 9, max: 13 });
  const good = { fps: 15, kbps: 2000, delay: 60 };
  for (let i = 0; i < 9; i++) assert.equal(g.update(good), null);
  assert.equal(g.update(good), 10);
  for (let i = 0; i < 100; i++) g.update(good);
  assert.equal(g.quality, 13);
  g.reset(7);
  assert.equal(g.quality, 7);
});

test('averageDelay', () => {
  assert.equal(averageDelay([]), null);
  assert.equal(averageDelay([100, 200, 300]), 200);
});
