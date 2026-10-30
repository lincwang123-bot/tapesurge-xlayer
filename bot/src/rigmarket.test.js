import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { bookFromPages, deadAsks, expiredBids, matchBids, pickAsksForBoard } from './rigmarket.js';

const ZERO = '0x0000000000000000000000000000000000000000';
const ask = (rigId, price, power, extra = {}) => ({ rigId, price, power, total: price * power, valid: true, boardEligible: true, ...extra });
const bid = (bidId, price, remaining, extra = {}) => ({ bidId, bidder: '0xb1d', price, remaining, minPower: 1n, maxPower: 300n, maxSyncAge: 0n, deadline: 10_000n, valid: true, ...extra });
const offer = (index, power, total, extra = {}) => ({ index, rigId: 100n + index, power, total, syncedAt: 1_000n, syncFresh: true, ...extra });

test('board buys the cheapest eligible asks at or below its buy price (BSC rule 6.37)', () => {
  const asks = [
    ask(1n, 90n, 10n),
    ask(2n, 50n, 10n),
    ask(3n, 70n, 10n, { boardEligible: false }), // 同步太久 / 算力不在范围：月局不收
    ask(4n, 60n, 10n, { valid: false }),
    ask(5n, 80n, 10n),
    ask(6n, 120n, 10n), // 高于收购价
  ];
  assert.deepEqual(pickAsksForBoard(asks, { buyPrice: 100n, budget: 10_000n, slots: 10 }), [2n, 5n, 1n]);
  assert.deepEqual(pickAsksForBoard(asks, { buyPrice: 85n, budget: 10_000n, slots: 10 }), [2n, 5n]);
  assert.deepEqual(pickAsksForBoard(asks, { buyPrice: 100n, budget: 1_300n, slots: 10 }), [2n, 5n], 'budget runs out');
  assert.deepEqual(pickAsksForBoard(asks, { buyPrice: 100n, budget: 10_000n, slots: 1 }), [2n], 'machine slots');
  assert.deepEqual(pickAsksForBoard(asks, { buyPrice: 100n, budget: 10_000n, slots: 10, taken: new Set([2n]) }), [5n, 1n]);
  assert.deepEqual(pickAsksForBoard(asks, { buyPrice: 100n, budget: 0n, slots: 10 }), []);
});

test('board machines go to the highest matching bid; the bid is charged the ask only', () => {
  const offers = [offer(0n, 30n, 3_000n), offer(1n, 20n, 2_000n), offer(2n, 50n, 5_000n)];
  const bids = [
    bid(1n, 90n, 100_000n), // 出价低于要价（90 × 30 < 3,000）
    bid(2n, 120n, 3_500n), // 最高价，但预算只够一台
    bid(3n, 110n, 100_000n, { maxPower: 40n }), // 算力上限 40
    bid(4n, 200n, 100_000n, { valid: false }),
  ];
  assert.deepEqual(matchBids(offers, bids, 2_000n), [
    { index: 0n, rigId: 100n, bidId: 2n, total: 3_000n, fresh: true },
    { index: 1n, rigId: 101n, bidId: 3n, total: 2_000n, fresh: true },
  ]);
});

test('bid sync-age limit, and planning a refresh for stale board machines', () => {
  const offers = [offer(0n, 30n, 3_000n, { syncedAt: 1_000n, syncFresh: false })];
  const bids = [bid(1n, 200n, 100_000n, { maxSyncAge: 3_600n })];
  assert.deepEqual(matchBids(offers, bids, 100_000n), [], 'synced too long ago for this bid');
  assert.deepEqual(matchBids(offers, bids, 100_000n, { assumeSynced: true }), [{ index: 0n, rigId: 100n, bidId: 1n, total: 3_000n, fresh: false }]);
  const justClaimed = [offer(0n, 30n, 3_000n, { syncedAt: 100_010n })];
  assert.equal(matchBids(justClaimed, bids, 100_000n).length, 1, 'sync time newer than ctx.now counts as fresh');
});

test('tidy: dead asks and expired bids', () => {
  assert.deepEqual(deadAsks([ask(1n, 1n, 1n), ask(2n, 1n, 1n, { valid: false })]), [2n]);
  const bids = [bid(1n, 1n, 1n, { deadline: 99n }), bid(2n, 1n, 1n, { deadline: 101n }), bid(3n, 1n, 1n, { deadline: 50n, bidder: ZERO })];
  assert.deepEqual(expiredBids(bids, 100n), [1n]);
});

test('X Layer ABI has the RIG market and the board market path', () => {
  const abi = (name) => JSON.parse(readFileSync(new URL(`../abi/xlayer/${name}.json`, import.meta.url), 'utf8'));
  const has = (a, name) => a.some((f) => f.type === 'function' && f.name === name);
  const m = abi('XRigMarket');
  for (const fn of ['book', 'boardOffers', 'sellAskToBoard', 'fillBidFromBoard', 'buyBoardMachine', 'asksPage', 'bidsPage', 'pruneAsks', 'refundBid', 'listAsk', 'placeBid', 'sellToBid', 'buyBest']) {
    assert.ok(has(m, fn), fn);
  }
  const offer = m.find((f) => f.name === 'boardOffers').outputs[0].components.map((c) => c.name);
  assert.deepEqual(offer, ['index', 'rigId', 'power', 'total', 'syncedAt', 'syncFresh']);
  assert.ok(has(abi('XMonthBoard'), 'MARKET'));
});

test('book from pages: valid orders only, deduped, same order as book() (audit 2026-10-29 #8)', () => {
  const asks = [ask(3n, 70n, 10n), ask(1n, 90n, 10n), ask(2n, 70n, 10n), ask(4n, 50n, 10n, { valid: false }), ask(3n, 70n, 10n)];
  const bids = [bid(5n, 40n, 1_000n), bid(2n, 60n, 1_000n), bid(7n, 60n, 1_000n), bid(9n, 80n, 1_000n, { valid: false }), bid(2n, 60n, 1_000n)];
  const [a, b] = bookFromPages(asks, bids);
  assert.deepEqual(a.map((x) => x.rigId), [2n, 3n, 1n], 'cheapest first, same price by id, invalid and duplicate dropped');
  assert.deepEqual(b.map((x) => x.bidId), [2n, 7n, 5n], 'highest first, same price by id');
  assert.deepEqual(bookFromPages([], []), [[], []]);
});
