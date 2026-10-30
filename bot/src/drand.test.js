import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fetchSignature, parseBeacon } from './drand.js';

const sig = 'ab'.repeat(64);

test('parseBeacon accepts a 64-byte signature for the requested round', () => {
  assert.equal(parseBeacon({ round: 7, signature: sig }, 7), `0x${sig}`);
  assert.equal(parseBeacon({ round: '7', signature: `0x${sig.toUpperCase()}` }, 7n), `0x${sig}`);
});

test('parseBeacon rejects a wrong round or a malformed signature', () => {
  assert.throws(() => parseBeacon({ round: 8, signature: sig }, 7), /轮次/);
  assert.throws(() => parseBeacon({ round: 7, signature: 'abcd' }, 7), /格式/);
});

test('fetchSignature falls back to the next relay', async () => {
  const calls = [];
  const fake = async (url) => {
    calls.push(url);
    if (calls.length === 1) return { ok: false, status: 425 };
    return { ok: true, json: async () => ({ round: 42, signature: sig }) };
  };
  assert.equal(await fetchSignature(42, { fetchImpl: fake }), `0x${sig}`);
  assert.equal(calls.length, 2);
  assert.match(calls[1], /api2\.drand\.sh/);
});
