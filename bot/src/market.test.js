import { test } from 'node:test';
import assert from 'node:assert/strict';
import { firstoBid, firstoQuote } from './market.js';

// ---- Firsto 行情：日产能价 → 一台矿机的 BEM 市场价
const B = 10n ** 8n; // 1 BEM
const E18 = 10n ** 18n;
let makerSeq = 0;
const row = (weight, est24h, buyerCost, status = 'verified', bidNet = null, maker = `0x${(++makerSeq).toString(16).padStart(40, '0')}`) => ({
  mining: { status, weight: String(weight), estimated24hAtomic: String(est24h) },
  bestAsk: { buyerCostWei: String(buyerCost), execution: { maker } },
  maxBidSellerNetWei: bidNet == null ? null : String(bidNet),
  valuation: { bemPriceBnbWei: String(E18 / 25n) }, // 1 BEM = 0.04 BNB
});
// 每 H 每天 0.0045 BEM；日产能价分别为 9、10、11、50 BNB
const rows = [row(100, 45_000_000, 4_05n * E18 / 100n), row(100, 45_000_000, 45n * E18 / 10n), row(200, 90_000_000, 99n * E18 / 10n), row(100, 45_000_000, 225n * E18 / 10n)];

test('firsto: median of the three cheapest asks, scaled by machine weight', () => {
  const q = firstoQuote({ rows, sourceBlock: '1000' });
  assert.equal(q.dailyCapacityPrice, 10n * E18); // 9 / 10 / 11 → 中位数 10
  assert.equal(q.refCostWei, 45n * E18 / 10n); // 中位数那条的整台含费价（报价时按它估兑换成本）
  // 算力 1000 H：每天 4.5 BEM，市场价 4.5 × 10 ÷ 0.04 = 1125 BEM
  assert.equal(q.priceFor({ weight: 1000n }), 1125n * B);
  assert.equal(q.priceFor({ weight: 0n }), undefined);
});

test('firsto: one listing per seller, at least three sellers', () => {
  const same = '0x00000000000000000000000000000000000000aa';
  // 同一卖家挂了三条最便宜的（8、8.1、8.2 BNB），只算 8 那条；其余卖家 10、11 → 中位数 10
  const flood = [row(100, 45_000_000, 36n * E18 / 10n, 'verified', null, same), row(100, 45_000_000, 3645n * E18 / 1000n, 'verified', null, same), row(100, 45_000_000, 369n * E18 / 100n, 'verified', null, same), rows[1], rows[2]];
  assert.equal(firstoQuote({ rows: flood }).dailyCapacityPrice, 10n * E18);
  assert.throws(() => firstoQuote({ rows: flood.slice(0, 4) }), /卖家太少/); // 只有 2 个不同卖家
});

test('firsto: bid = median of the three highest shared bids with enough budget', () => {
  const bid = (dcp, budget = E18, state = 'active') => ({ state, dailyCapacityPriceWei: String(dcp), remainingBudgetWei: String(budget) });
  // 9.01、9.0、8.5、5、500（超范围）；另有一张 20 BNB 但只剩 0.01 BNB 预算、一张已关闭的，都不算
  const json = { sourceBlock: '1000', bids: [bid(901n * E18 / 100n), bid(9n * E18), bid(85n * E18 / 10n), bid(5n * E18), bid(500n * E18), bid(20n * E18, E18 / 100n), bid(30n * E18, E18, 'closed')] };
  const q = firstoBid(json);
  assert.equal(q.bidDailyCapacityPrice, 9n * E18);
  assert.equal(q.bidCount, 4);
  assert.equal(firstoBid({ bids: [bid(8n * E18)] }).bidDailyCapacityPrice, 8n * E18); // 只有一张取那一张
  assert.equal(firstoBid({ bids: [] }).bidDailyCapacityPrice, null);
  assert.throws(() => firstoBid(json, { latestBlock: 3000n }), /落后/);
});

test('firsto: refuse thin, stale or out-of-range data', () => {
  assert.throws(() => firstoQuote({ rows: rows.slice(0, 2) }), /太少/);
  assert.throws(() => firstoQuote({ rows: rows.map((r) => ({ ...r, mining: { ...r.mining, status: 'unverified' } })) }), /太少/);
  assert.throws(() => firstoQuote({ rows, sourceBlock: '1000' }, { latestBlock: 3000n }), /落后/);
  const cheap = [row(100, 45_000_000, E18 / 1000n), row(100, 45_000_000, E18 / 1000n), row(100, 45_000_000, E18 / 1000n)];
  assert.throws(() => firstoQuote({ rows: cheap }), /范围/);
});

import { bidCandidates, bidNeedWei } from './market.js';

// 2026-10-25 真实买单（区块约 129,709,275）的结构：两张 0.5 BNB 的小单在 8.51 / 8.5，大单在 5.52 / 5.5 / 4.0
const realBid = (dcp, budgetWei, maker, extra = {}) => ({ state: 'active', dailyCapacityPriceWei: String(dcp), remainingBudgetWei: String(budgetWei), maker, minCircuitH: '0', maxCircuitH: '0', ...extra });
const who = (n) => `0x${n.toString(16).padStart(40, '0')}`;
const realBids = [
  realBid(851n * E18 / 100n, E18 / 2n, who(1)),
  realBid(850n * E18 / 100n, E18 / 2n, who(2)),
  realBid(552n * E18 / 100n, 10n * E18, who(3)),
  realBid(550n * E18 / 100n, 10n * E18, who(4)),
  realBid(4n * E18, 20n * E18, who(5)),
];

test('firsto bid: only bids that can buy one reference machine count', () => {
  // 参考矿机 61 H，每天 0.27456985 BEM：8.51 的买单要 2.34 BNB 才吃得下，0.5 BNB 的两张不算
  const w61 = { refWeight: 61n, refDailyAtomic: 27_456_985n };
  assert.equal(bidNeedWei(851n * E18 / 100n, 27_456_985n), 27_456_985n * 851n * E18 / 100n / B);
  assert.equal(firstoBid({ bids: realBids }, w61).bidDailyCapacityPrice, 55n * E18 / 10n);
  // 参考矿机 10 H（每天 0.045 BEM，约 0.38 BNB）：两张 0.5 BNB 的小单都算 → 8.5
  const w10 = { refWeight: 10n, refDailyAtomic: 4_501_145n };
  assert.equal(firstoBid({ bids: realBids }, w10).bidDailyCapacityPrice, 85n * E18 / 10n);
  // 其中一张被吃掉一台、只剩 0.12 BNB：已经买不下 10 H 的矿机，不再算 → 8.5 / 5.52 / 5.5 → 5.52
  const eaten = realBids.map((b, i) => (i === 0 ? { ...b, remainingBudgetWei: String(12n * E18 / 100n) } : b));
  assert.equal(firstoBid({ bids: eaten }, w10).bidDailyCapacityPrice, 552n * E18 / 100n);
  // 没有参考矿机时只用 0.1 BNB 的绝对下限（旧行为）
  assert.equal(bidNeedWei(9n * E18, undefined), E18 / 10n);
});

test('firsto bid: one bid per bidder, and the bid must accept the reference machine weight', () => {
  const w10 = { refWeight: 10n, refDailyAtomic: 4_501_145n };
  // 同一个出价人挂了三张高价单：只算最高的一张
  const flood = [realBid(9n * E18, E18, who(9)), realBid(89n * E18 / 10n, E18, who(9)), realBid(88n * E18 / 10n, E18, who(9)), ...realBids.slice(2)];
  assert.equal(firstoBid({ bids: flood }, w10).bidDailyCapacityPrice, 552n * E18 / 100n); // 9 / 5.52 / 5.5 → 5.52
  assert.equal(firstoBid({ bids: flood }, w10).bidCount, 4);
  // 只收 50–300 H 的买单不能吃下 10 H 的参考矿机；只收到 8 H 的也不行；0 / 0 = 不限
  const ranged = [realBid(9n * E18, 5n * E18, who(7), { minCircuitH: '50' }), realBid(9n * E18, 5n * E18, who(8), { maxCircuitH: '8' })];
  assert.equal(bidCandidates({ bids: ranged }, w10).length, 0);
  assert.equal(bidCandidates({ bids: ranged }, { refWeight: 60n, refDailyAtomic: 27_000_000n }).length, 1);
});

test('firsto ask: candidates follow the board purchase rules', () => {
  const NOW = 1_790_000_000;
  const exp = (r, expiry) => ({ ...r, bestAsk: { ...r.bestAsk, execution: { ...r.bestAsk.execution, expiry: String(expiry) } } });
  // 7 H 的矿机主板不收：最便宜也不算；快过期（< 10 分钟）的也不算
  const small = row(7, 3_150_000, 2n * E18 / 10n); // 日产能价约 6.35，最便宜
  const expiring = exp(row(100, 45_000_000, 4n * E18), NOW + 300); // 8.89
  const q = firstoQuote({ rows: [small, expiring, ...rows] }, { now: NOW });
  assert.equal(q.dailyCapacityPrice, 10n * E18, 'same as without the two');
  assert.equal(q.refWeight, 100n);
  assert.equal(q.refDailyAtomic, 45_000_000n);
  const later = exp(row(100, 45_000_000, 4n * E18), NOW + 3_600);
  assert.equal(firstoQuote({ rows: [later, ...rows] }, { now: NOW }).dailyCapacityPrice, 9n * E18);
});
