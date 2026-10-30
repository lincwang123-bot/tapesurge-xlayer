import { test } from 'node:test';
import assert from 'node:assert/strict';
import { dayGuard, nextPost, targetPrice } from './tasks/pricefeed.js';

const B = 10n ** 8n;
const E18 = 10n ** 18n;

test('feed: only the very first post goes straight to the target; a stale previous price is still stepped', () => {
  assert.equal(nextPost(150n * B, 0n, false, 500n), 150n * B);
  assert.equal(nextPost(150n * B, 100n * B, false, 500n), 105n * B);
});

test('feed: a fresh previous price moves at most 5% per post, never past the bound', () => {
  assert.equal(nextPost(150n * B, 100n * B, true, 500n), 105n * B);
  assert.equal(nextPost(50n * B, 100n * B, true, 500n), 95n * B);
  assert.equal(nextPost(102n * B, 100n * B, true, 500n), 102n * B);
  // 取整朝上一次的方向：结果一定落在 ±5% 以内
  const prev = 333_333_333n;
  const up = nextPost(10n * prev, prev, true, 500n);
  const down = nextPost(1n, prev, true, 500n);
  assert.ok(up * 10_000n <= prev * 10_500n && down * 10_000n >= prev * 9_500n);
});

test('feed: target price per weight from Firsto, converted on-chain, with deviation check', async () => {
  // 每单位算力每天 0.0045 BEM；日产能价 9 BNB；BEM = 0.04 BNB → 每单位算力 0.0405 BNB → 1.0125 BEM
  const q = { perHourWeight: (450_000n * E18) / 1n, dailyCapacityPrice: 9n * E18, bemPriceBnbWei: E18 / 25n };
  const same = await targetPrice(q, async (bnb) => (bnb * 25n * B) / E18);
  assert.equal(same.price, 101_250_000n);
  assert.equal(same.deviationBps, 0n);
  const off = await targetPrice(q, async (bnb) => (bnb * 20n * B) / E18); // 链上 BEM 贵了 25%
  assert.equal(off.deviationBps, 2_000n);
});

import { nextPair } from './tasks/pricefeed.js';

test('feed: bid and ask converge separately and the posted bid never exceeds the ask', () => {
  // 上一次 买一 100 / 卖一 110，目标 买一 130 / 卖一 112：买一只能先到 105
  assert.deepEqual(nextPair({ bid: 130n * B, ask: 112n * B }, { bid: 100n * B, ask: 110n * B }, true, 500n), { bid: 105n * B, ask: 112n * B });
  // 上一次 买一 = 卖一 = 100，目标卖一跌 20%：卖一先到 95，买一跟着压到 95
  assert.deepEqual(nextPair({ bid: 90n * B, ask: 80n * B }, { bid: 100n * B, ask: 100n * B }, true, 500n), { bid: 95n * B, ask: 95n * B });
  // 过期后也照样分步：10 / 11 → 10.5 / 11.55
  assert.deepEqual(nextPair({ bid: 90n * B, ask: 99n * B }, { bid: 10n * B, ask: 11n * B }, false, 500n), { bid: 1_050_000_000n, ask: 1_155_000_000n });
});

import { postFunction } from './tasks/pricefeed.js';

test('feed: catch-up steps use postCatchUp, the step that reaches the target uses post', () => {
  const abi = [{ type: 'function', name: 'post' }, { type: 'function', name: 'postCatchUp' }];
  assert.equal(postFunction({ bid: 105n, ask: 110n }, { bid: 150n, ask: 160n }, abi), 'postCatchUp');
  assert.equal(postFunction({ bid: 150n, ask: 160n }, { bid: 150n, ask: 160n }, abi), 'post');
  assert.equal(postFunction({ bid: 105n, ask: 110n }, { bid: 150n, ask: 160n }, [{ type: 'function', name: 'post' }]), 'post', 'old deployment');
});

test('feed: a market move beyond 15% within 24 hours pauses posting until confirmed', () => {
  const H = 3_600;
  const opt = { maxBps: 1_500n };
  let h = [];
  // 每小时 −3%：前 5 小时累计 < 15%，第 6 小时（−16.7%）暂停
  let p = 100n * E18;
  let paused = null;
  for (let i = 0; i < 8 && !paused; i++) {
    const g = dayGuard(h, i * H, { ask: p, bid: null }, opt);
    if (g.ok) h = g.history;
    else paused = { i, reason: g.reason };
    p = (p * 97n) / 100n;
  }
  assert.equal(paused.i, 6);
  assert.match(paused.reason, /卖一比 24 小时内最高价低了 16/);
  assert.equal(h.length, 6, 'the paused reading is not recorded, the baseline stays');
  // 卖一往上也一样
  assert.equal(dayGuard([{ at: 0, ask: String(100n), bid: String(100n) }], H, { ask: 116n, bid: 100n }, opt).ok, false);
  // 买一单独检查，但只标记、不暂停
  const g = dayGuard([{ at: 0, ask: String(100n), bid: String(100n) }], H, { ask: 110n, bid: 116n }, opt);
  assert.equal(g.ok, true);
  assert.match(g.bidMoved, /买一比 24 小时内最低价高出 16/);
  assert.equal(g.history.at(-1).bid, '116', 'the moved bid is still recorded');
  assert.equal(dayGuard([{ at: 0, ask: String(100n), bid: String(100n) }], H, { ask: 110n, bid: 114n }, opt).bidMoved, undefined);
  // 25 小时前的记录丢掉，24 小时以外的不参与比较；0 = 不检查
  assert.equal(dayGuard([{ at: 0, ask: '100', bid: null }], 25 * H, { ask: 200n, bid: null }, opt).ok, true);
  assert.equal(dayGuard([{ at: 0, ask: '100', bid: null }], H, { ask: 200n, bid: null }, { maxBps: 0n }).ok, true);
  assert.equal(dayGuard([{ at: 0, ask: '100', bid: null }], 26 * H, { ask: 100n, bid: null }, opt).history.length, 1);
});


import { bidDecision } from './tasks/pricefeed.js';

/** 按小时喂一串买一（日产能价，单位 0.01 BNB），返回每小时的决定 */
function replay(bids, { maxBps = 1_500n } = {}) {
  const H = 3_600;
  let used = null;
  let pending = null;
  return bids.map((b, i) => {
    const d = bidDecision(b == null ? null : BigInt(b) * E18 / 100n, used, pending, i * H, { maxBps });
    used = d.lastUsed;
    pending = d.pending;
    return { dcp: d.dcp == null ? null : Number(d.dcp * 100n / E18), held: d.held, alert: d.alert };
  });
}

test('feed bid: a big jump is held and alerted once; when the bid comes back the hold ends quietly (2026-10-26 mainnet data)', () => {
  // 主网上线当晚：5.52 → 一张高价单 8.9 / 8.8 / 8.18 挂了约 5 小时 → 撤掉回到 5.52
  const r = replay([552, 552, 890, 880, 890, 890, 880, 818, 552, 552, 552, 552]);
  assert.deepEqual(r.map((x) => x.dcp), [552, 552, 552, 552, 552, 552, 552, 552, 552, 552, 552, 552], 'the bid in use never moves');
  assert.deepEqual(r.map((x) => x.alert), [null, null, 'new', null, null, null, null, null, null, null, null, null], 'one alert when the new level appears');
  assert.deepEqual(r.map((x) => x.held), [false, false, true, true, true, true, true, true, false, false, false, false], 'back at 5.52: no longer held');
});

test('feed bid: a new level that lasts 24 hours is adopted', () => {
  // 2026-10-25：买一 8.5 靠两张小单撑着，撤掉后一直是 5.5
  const r = replay([850, 850, 850, ...Array(27).fill(550)]);
  assert.equal(r[2].dcp, 850);
  assert.equal(r[3].alert, 'new');
  assert.ok(r[3].held && r[26].held && r[26].dcp === 850, 'hours 3–26: hold 8.5');
  assert.deepEqual(r[27], { dcp: 550, held: false, alert: 'adopted' }, 'hour 27: 5.5 has lasted 24 hours');
  assert.equal(r[28].alert, null);
});

test('feed bid: small moves follow the market; a jump to a third level restarts the 24-hour wait', () => {
  const small = replay([500, 540, 580, 620]); // 每步 < 15%：一路跟着走
  assert.deepEqual(small.map((x) => [x.dcp, x.held]), [[500, false], [540, false], [580, false], [620, false]]);
  const r = replay([500, 700, 700, 900, 900]); // 700 等了 2 小时又跳到 900：从 900 重新算
  assert.deepEqual(r.map((x) => x.alert), [null, 'new', null, 'new', null]);
  assert.ok(r.slice(1).every((x) => x.held && x.dcp === 500));
});

test('feed bid: no usable bid holds the last one for 25 hours, then falls back to the ask estimate; testnet never holds', () => {
  const r = replay([800, ...Array(26).fill(null)]);
  assert.deepEqual(r[10], { dcp: 800, held: true, alert: null });
  assert.equal(r[25].dcp, 800, 'hour 25: still within 25 hours of the last confirmation');
  assert.equal(r[26].dcp, null, 'hour 26: estimate from the ask');
  assert.deepEqual(replay([null]), [{ dcp: null, held: false, alert: null }]);
  assert.deepEqual(replay([500, 900], { maxBps: 0n }).map((x) => x.dcp), [500, 900], 'maxBps 0 (testnet): always take the bid');
});

import { catchUpGapBps } from './tasks/pricefeed.js';

test('追价提醒：取离上一次报价最远的一侧；只有超过 2 × 5% 才发（2026-10-27 实际三次）', () => {
  // 11:39：卖一 149117315 → 136906850（−8.19%），一步追上，不发
  assert.equal(catchUpGapBps({ bid: 75933130n, ask: 136906850n }, { bid: 80244337n, ask: 149117315n }), 818n);
  // 21:50：卖一 132608179 → 141345830（+6.58%）
  assert.equal(catchUpGapBps({ bid: 76452736n, ask: 141345830n }, { bid: 73337977n, ask: 132608179n }), 658n);
  // 买一差 12% 也算
  assert.equal(catchUpGapBps({ bid: 112n, ask: 100n }, { bid: 100n, ask: 100n }), 1200n);
  assert.equal(catchUpGapBps({ bid: 5n, ask: 5n }, { bid: 0n, ask: 0n }), 0n);
});

import { autoResume, trendText } from './tasks/pricefeed.js';

// 2026-10-30 BSC 主网的真实走势：卖一日产能价（BNB），10-29 01:02 UTC 起约每 55 分钟一个读数（服务器 state/56.json）。
// 10-30 01:13 卖一 8.173，比 24 小时内最高的 9.648 低 15.29%，机器人暂停报价；03:18 合约报价过期；05:52 人工确认后恢复。
const AH = 3_600;
const T = (h, m) => h * AH + m * 60; // 10-29 00:00 UTC 起的秒数
const bnb = (v) => String(BigInt(Math.round(v * 1000)) * 10n ** 15n);
const REAL = [
  [T(1, 2), 9.648], [T(1, 57), 9.648], [T(2, 53), 9.648], [T(3, 49), 9.282], [T(4, 44), 9.282], [T(5, 40), 9.282],
  [T(6, 35), 9.237], [T(7, 31), 9.237], [T(8, 26), 8.85], [T(9, 28), 9.137], [T(10, 23), 9.04], [T(11, 19), 9.04],
  [T(12, 15), 9.04], [T(13, 10), 9.04], [T(14, 6), 8.935], [T(15, 1), 8.935], [T(15, 57), 8.649], [T(16, 53), 8.935],
  [T(17, 48), 8.935], [T(18, 44), 8.935], [T(19, 39), 8.935], [T(20, 35), 8.935], [T(21, 31), 8.935], [T(22, 26), 8.935],
  [T(23, 22), 8.932], [T(24, 17), 8.534],
].map(([at, v]) => ({ at, ask: bnb(v), bid: null }));
const opt15 = { maxBps: 1_500n };

/** 从 start 起每 330 秒读一次（暂停期间机器人约 5.5 分钟读一次），价格由 priceAt(t) 给出；返回第一次 resume 的时间和过程中的状态 */
function replayAuto(history, start, end, priceAt) {
  const samples = [];
  const states = [];
  for (let t = start; t <= end; t += 330) {
    samples.push({ at: t, ask: bnb(priceAt(t)) });
    const r = autoResume(history, samples, t);
    states.push({ t, ...r });
    if (r.state === 'resume') return { at: t, r, states };
  }
  return { at: null, states };
}

test('feed auto-resume: 2026-10-30 real gradual drop resumes by itself 2 hours after the pause, before the 3-hour staleness', () => {
  assert.equal(dayGuard(REAL, T(25, 13), { ask: BigInt(bnb(8.173)), bid: null }, opt15).ok, false, 'the real data does trip the 15% guard');
  const { at, r, states } = replayAuto(REAL, T(25, 13), T(30, 0), () => 8.173);
  assert.ok(at >= T(25, 13) + 7_200, 'waits until the new level has held 2 hours');
  assert.ok(at < T(27, 18), 'resumes before the contract feed went stale at 03:18');
  assert.equal(states[0].state, 'waiting');
  assert.ok(states[0].wait > 7_000);
  assert.equal(r.maxStepBps, 445n, 'largest hourly step was 8.932 → 8.534 (−4.46%, rounded down)');
  assert.ok(r.totalBps < 1_500n, 'by 03:14 the 9.648 readings have left the 24-hour window');
});

test('feed auto-resume: a sudden jump stays paused for a human, however long it holds', () => {
  const flat = Array.from({ length: 24 }, (_, i) => ({ at: i * AH, ask: bnb(9.0), bid: null }));
  assert.equal(dayGuard(flat, 24 * AH, { ask: BigInt(bnb(7.6)), bid: null }, opt15).ok, false);
  const { at, states } = replayAuto(flat, 24 * AH, 30 * AH, () => 7.6);
  assert.equal(at, null);
  const last = states[states.length - 1];
  assert.equal(last.state, 'manual');
  assert.match(last.reason, /单小时最大变动 15\.6%/);
});

test('feed auto-resume: still drifting waits; it resumes once the last 2 hours stay within 1% of the price', () => {
  const hist = [10, 10, 10, 10, 9.6, 9.2, 8.8].map((v, i) => ({ at: i * AH, ask: bnb(v), bid: null }));
  const start = 7 * AH; // 8.4 = −16%：暂停
  assert.equal(dayGuard(hist, start, { ask: BigInt(bnb(8.4)), bid: null }, opt15).ok, false);
  // 暂停后 2 小时继续慢慢跌到 7.6（每小时约 −5%），然后不动
  const priceAt = (t) => (t < start + 2 * AH ? 8.4 - (0.8 * (t - start)) / (2 * AH) : 7.6);
  const { at, r, states } = replayAuto(hist, start, start + 8 * AH, priceAt);
  assert.ok(states.some((s) => s.state === 'waiting' && /还在变/.test(s.reason)), 'while drifting it says the price is still moving');
  assert.ok(at > start + 2 * AH, 'not before the drift ends');
  const window = states.filter((s) => s.t >= at - 2 * AH).map((s) => priceAt(s.t));
  assert.ok(window.every((v) => v <= 7.6 * 1.01 + 1e-9), 'every reading in the last 2 hours is within 1% of 7.6');
  assert.ok(r.totalBps <= 3_000n && r.maxStepBps <= 600n);
});

test('feed auto-resume: a steady 1.5%/hour slide is not "stable", so it keeps waiting', () => {
  const hist = Array.from({ length: 12 }, (_, i) => ({ at: i * AH, ask: bnb(10 * 0.986 ** i), bid: null }));
  const start = 12 * AH;
  const priceAt = (t) => 10 * 0.986 ** 11 * 0.985 ** (Math.floor((t - start) / AH) + 1); // 一直匀速跌
  const { at, states } = replayAuto(hist, start, start + 6 * AH, priceAt);
  assert.equal(at, null);
  assert.equal(states[states.length - 1].state, 'waiting');
});

test('feed auto-resume: more than 30% within 24 hours always waits for a human, even if gradual', () => {
  const hist = [...Array(12).fill(10), 9.6, 9.22, 8.85].map((v, i) => ({ at: i * AH, ask: bnb(v), bid: null }));
  const start = 15 * AH; // 8.49 = −15.1%：暂停
  assert.equal(dayGuard(hist, start, { ask: BigInt(bnb(8.49)), bid: null }, opt15).ok, false);
  // 暂停后每小时再跌 4%，5 小时后到约 6.9（比 10 低约 31%），之后不动
  const priceAt = (t) => 8.49 * 0.96 ** Math.min(5, Math.floor((t - start) / AH));
  const { at, states } = replayAuto(hist, start, start + 9 * AH, priceAt);
  assert.equal(at, null);
  const last = states[states.length - 1];
  assert.equal(last.state, 'manual');
  assert.match(last.reason, /24 小时累计变动 3\d\.\d%，超过 30\.0%/);
});

test('feed alert trend: up to 6 hourly points from the last 24 hours', () => {
  const s = trendText(REAL, [{ at: T(25, 13), ask: bnb(8.173) }], T(25, 13));
  const pts = s.split(' → ');
  assert.equal(pts.length, 6);
  assert.equal(pts[0], '9.65', '01:02 is outside the window; 01:57 still 9.648');
  assert.equal(pts[5], '8.17');
  assert.equal(trendText([], [], 0), '—');
});
