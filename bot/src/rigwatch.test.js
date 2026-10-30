import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EIP1967_IMPL_SLOT, RIG_IMPL_196, implFromSlot, rigStatus } from './rigwatch.js';
import { keccak256, toHex } from 'viem';

const A = '0x66fb7d52c4931b48776d9019f88f7f58fb0d85e1';
const B = '0x1111111111111111111111111111111111111111';

test('rig watch: EIP-1967 slot and the X Layer mainnet implementation', () => {
  assert.equal(EIP1967_IMPL_SLOT, toHex(BigInt(keccak256(toHex('eip1967.proxy.implementation'))) - 1n, { size: 32 }));
  assert.equal(RIG_IMPL_196, A);
});

test('rig watch: storage word to address', () => {
  assert.equal(implFromSlot(`0x000000000000000000000000${A.slice(2).toUpperCase()}`), A);
  assert.equal(implFromSlot('0x0'), '0x0000000000000000000000000000000000000000', 'not a proxy (testnet MockRig)');
  assert.equal(implFromSlot(undefined), '0x0000000000000000000000000000000000000000');
});

test('rig watch: compares with the expected implementation first, else the first one seen', () => {
  assert.deepEqual(rigStatus({ expected: A, baseline: B, current: A }), { ref: A, changed: false, newlySealed: false });
  assert.equal(rigStatus({ expected: A, baseline: A, current: B }).changed, true, 'upgraded away from the expected one');
  assert.equal(rigStatus({ expected: A.toUpperCase().replace('0X', '0x'), current: A }).changed, false, 'case-insensitive');
  assert.equal(rigStatus({ baseline: B, current: B }).changed, false);
  assert.equal(rigStatus({ baseline: B, current: A }).changed, true, 'no expected value: changed since first seen');
  assert.equal(rigStatus({ current: A }).changed, false, 'nothing to compare yet');
});

test('rig watch: sealing is reported once, unknown (null) never counts', () => {
  assert.equal(rigStatus({ current: A, sealed: true, wasSealed: false }).newlySealed, true);
  assert.equal(rigStatus({ current: A, sealed: true, wasSealed: true }).newlySealed, false);
  assert.equal(rigStatus({ current: A, sealed: true, wasSealed: null }).newlySealed, false, 'first read');
  assert.equal(rigStatus({ current: A, sealed: null, wasSealed: false }).newlySealed, false, 'MockRig has no isSealed');
});
