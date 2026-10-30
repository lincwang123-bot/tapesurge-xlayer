import { test } from 'node:test';
import assert from 'node:assert/strict';
import { planRelay, relayDue, stepToward } from './tasks/xfeed.js';

const MAX = 500n; // XMarketPriceFeed.maxChangeBps：每次最多变 5%

// 合约的 _within：v × 10000 在 [last × 9500, last × 10500] 之内
const within = (v, last) => v * 10_000n >= last * 9_500n && v * 10_000n <= last * 10_500n;

test('first post relays BSC prices as they are', () => {
  const p = planRelay({ bid: 77_201_309n, ask: 142_769_954n, catchingUp: false }, { bid: 0n, ask: 0n, updatedAt: 0n }, MAX);
  assert.deepEqual(p, { bid: 77_201_309n, ask: 142_769_954n, catchUp: false, gapBps: 0n });
});

test('within 5% of the last post: plain post', () => {
  const last = { bid: 76_232_121n, ask: 141_661_450n, updatedAt: 1n };
  const p = planRelay({ bid: 77_201_309n, ask: 142_769_954n, catchingUp: false }, last, MAX);
  assert.equal(p.catchUp, false);
  assert.equal(p.bid, 77_201_309n);
  assert.equal(p.ask, 142_769_954n);
});

test('BSC catching up: postCatchUp even when the step fits', () => {
  const last = { bid: 76_232_121n, ask: 141_661_450n, updatedAt: 1n };
  const p = planRelay({ bid: 77_000_000n, ask: 142_000_000n, catchingUp: true }, last, MAX);
  assert.equal(p.catchUp, true);
  assert.equal(p.bid, 77_000_000n);
});

test('more than 5% behind BSC: one ±5% step, marked as catch-up, accepted by the contract bound', () => {
  const last = { bid: 70_000_000n, ask: 130_000_000n, updatedAt: 1n };
  const up = planRelay({ bid: 80_000_000n, ask: 131_000_000n, catchingUp: false }, last, MAX);
  assert.equal(up.catchUp, true);
  assert.equal(up.bid, 73_500_000n);
  assert.equal(up.ask, 131_000_000n);
  assert.ok(within(up.bid, last.bid) && within(up.ask, last.ask));
  assert.equal(up.gapBps, 1428n); // 买一差 14.28%
  const down = planRelay({ bid: 50_000_000n, ask: 90_000_000n, catchingUp: false }, last, MAX);
  assert.ok(within(down.bid, last.bid) && within(down.ask, last.ask));
  assert.equal(down.catchUp, true);
});

test('step down rounds up so the contract never sees more than 5%', () => {
  // 下限向上取整：last × 9500 / 10000 有余数时取上整
  const v = stepToward(1n, 1_000_001n, MAX);
  assert.equal(v, 950_001n);
  assert.ok(within(v, 1_000_001n));
});

test('ask is never stepped below bid', () => {
  const last = { bid: 100n * 10n ** 6n, ask: 101n * 10n ** 6n, updatedAt: 1n };
  const p = planRelay({ bid: 120n * 10n ** 6n, ask: 120n * 10n ** 6n, catchingUp: false }, last, MAX);
  assert.ok(p.ask >= p.bid);
  assert.ok(within(p.bid, last.bid) && within(p.ask, last.ask));
});

test('relay is due right away the first time, then every max(minInterval, everySec)', () => {
  assert.equal(relayDue(100, 0n, 3000n, 3600), true);
  assert.equal(relayDue(1000 + 3599, 1000n, 3000n, 3600), false);
  assert.equal(relayDue(1000 + 3600, 1000n, 3000n, 3600), true);
  // 配置的间隔比合约最短间隔短时，按合约的来，不然会 TooSoon
  assert.equal(relayDue(1000 + 2999, 1000n, 3000n, 60), false);
  assert.equal(relayDue(1000 + 3000, 1000n, 3000n, 60), true);
});
