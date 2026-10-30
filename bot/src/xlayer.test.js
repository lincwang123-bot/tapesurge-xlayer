import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { chainLagBlocksDraw, staleRigIds } from './tasks/boards.js';

const abi = (name) => JSON.parse(readFileSync(new URL(`../abi/xlayer/${name}.json`, import.meta.url), 'utf8'));
const has = (a, type, name) => a.some((f) => f.type === type && f.name === name);

test('draw waits while X Layer chain time lags the wall clock', () => {
  assert.equal(chainLagBlocksDraw(1_000, 1_060, 60), false, 'exactly 60 s behind is fine');
  assert.equal(chainLagBlocksDraw(1_000, 1_061, 60), true);
  assert.equal(chainLagBlocksDraw(1_000, 990, 60), false, 'chain ahead of wall clock');
  assert.equal(chainLagBlocksDraw(1_000, 999_999, 0), false, '0 = check disabled (local anvil)');
});

test('only RIGs whose sync is too old get a claim before relaying', () => {
  assert.deepEqual(staleRigIds([{ id: 1n, fresh: true }, { id: 2n, fresh: false }, { id: 3n, fresh: false }]), [2n, 3n]);
  assert.deepEqual(staleRigIds([]), []);
});

test('X Layer ABI matches the contracts after the audit fixes and BSC alignment', () => {
  const sales = abi('XMonthMachineSales');
  assert.ok(has(sales, 'function', 'syncFresh'));
  assert.ok(has(sales, 'function', 'SALE_SYNC_AGE'));
  assert.ok(!has(sales, 'function', 'setListing'), 'listing rule removed: same sell formula as BSC');
  assert.ok(!has(sales, 'function', 'priceLocked'));
  const feed = abi('XMarketPriceFeed');
  assert.ok(has(feed, 'function', 'buyQuote') && has(feed, 'function', 'sellQuote'));
  assert.ok(!has(feed, 'function', 'minLiveBid'), 'minLiveBid removed to match BSC');
  assert.ok(has(abi('XHub'), 'error', 'FeedNotPosted'));
  assert.ok(has(abi('XPositionExchange'), 'function', 'bidEpoch'));
  assert.ok(has(abi('XMonthFactory'), 'function', 'roundCap'));
});
