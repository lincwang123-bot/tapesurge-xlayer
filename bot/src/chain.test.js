import { test } from 'node:test';
import assert from 'node:assert/strict';
import { XLAYER_GAS_BUFFER, gasWithBuffer, nextNonce } from './chain.js';

test('chain: gas limit = estimate × 1.25, at least +30k (fork rehearsal 2026-10-26: exact estimate ran out of gas)', () => {
  assert.equal(gasWithBuffer(798_837n), 998_546n);
  assert.equal(gasWithBuffer(50_000n), 80_000n);
  assert.equal(gasWithBuffer(1_000_000n), 1_250_000n);
});

test('nonce: the larger of pending and latest (X Layer testnet RPC sometimes reports pending = 0)', () => {
  assert.equal(nextNonce(0, 195), 195);
  assert.equal(nextNonce(196, 195), 196);
  assert.equal(nextNonce(195, 195), 195);
});

test('X Layer gas limit: estimate × 2, at least +100k (testnet RPC state lags a few blocks)', () => {
  assert.equal(gasWithBuffer(69_857n, XLAYER_GAS_BUFFER), 169_857n);
  assert.equal(gasWithBuffer(400_000n, XLAYER_GAS_BUFFER), 800_000n);
});
