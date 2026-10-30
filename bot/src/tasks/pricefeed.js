// v2.0-rc3 起两种局按 Firsto 买一 / 卖一由合约公式买卖矿机：运营地址每小时把买一、卖一报给 MarketPriceFeed
// （规则见 v2月局规则决定-2026-10-22.md 第 6.17、6.19、6.21 节）。
// 报价单位 = 每单位算力的 BEM 最小单位数（和 MonthBoard.buyPrice() 同单位）：
//   每单位算力的 BNB 价值 = Firsto 日产能价（BNB / (1 BEM/天)）× 每单位算力日产出（BEM/天）
//   再用链上 TWAP 预言机 quoteBemOut 换算成 BEM；卖一和 Firsto 自己的 BEM 价格偏差超过 10% 时不报，报警。
// 买一取 Firsto 统一买单（firstoBid）；没有符合条件的买单时，买一按"卖一 × (1 − FEED_NO_BID_SPREAD_BPS)"估（默认 9%，Firsto 平时的买卖价差），并报警。
// v2.0-rc5 起主板经 FirstoTrader 直接在 Firsto 成交（规则 6.22），报给链上的是"主板经 Firsto 实际要付 / 能拿到的价"：
//   卖一 = Firsto 含费卖价 ×（1 + 兑换成本）；买一 = Firsto 买单毛价 × 99%（卖方手续费）×（1 − 兑换成本）。
//   兑换成本 = BEM ↔ BNB 池子手续费 + 冲击：主网按卖一中位数那台矿机的金额用 QuoterV2 实时算（+0.25%，限制在 1.2%–2%，
//   见 src/swapcost.js），测试网用 cfg.swapCostBps。不这样算，主板的收购上限够不着最便宜的卖单、
//   卖出下限又高过买单的净到手，自动买卖就成交不了。
// 合约限制：两次报价至少间隔 minInterval（50 分钟）；上一次没过期时买一、卖一各自每次最多变 maxChangeBps（5%），
// 超过就先报 5% 的一步，下一小时再靠近；0 < 买一 ≤ 卖一。
// Firsto 读不到时不报；超过 3 小时没报，合约自动暂停两种局的矿机买卖，这里同时报警。
// 规则 6.36：主网的卖一只用链上模拟购买通过的挂单（src/askcheck.js），每个卖家一条，至少 3 个不同卖家；
// 卖一日产能价 24 小时内累计变动超过 FEED_MAX_DAY_CHANGE_BPS（15%）时暂停自动报价，等项目方确认（scripts/feed-confirm.mjs）。
// 买一只算剩余预算能买下一台参考矿机（卖一中位数那台）的买单，每个出价人一张，主网上逐张读链上状态核对
// （src/bidcheck.js）；买一 24 小时内大幅变动不暂停报价，先沿用上一次的买一，新价位维持 24 小时后自动采用。
// 卖一只看主板能收的矿机（算力 10–300、离过期 ≥ 10 分钟），不支持的挂单不占核对次数。
import { ABI } from '../abi.js';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { parseAbi } from 'viem';
import { ROOT } from '../config.js';
import { ASKS_URL as FIRSTO, BIDS_URL as FIRSTO_BIDS, FIRSTO_UA as UA, asksPageUrl, parseAsks } from '../firsto.js'; // 买一取统一买单
import { firstoBid, firstoQuote } from '../market.js';
import { verifiedAskRows, withMoreAskPages } from '../askcheck.js';
import { verifiedBids } from '../bidcheck.js';
import { getJson } from './firstoTrade.js';
import { feedSwapBps } from '../swapcost.js';
import * as log from '../log.js';

const E18 = 10n ** 18n;
const FIRSTO_SELLER_FEE_BPS = 100n; // Firsto 统一买单向卖方收 1%
const OWNER_OF = parseAbi(['function ownerOf(uint256 id) view returns (address)']);

/**
 * 目标报价，向上一次报价收敛：每次最多变动 maxChangeBps（取整时朝上一次的方向，保证不越界）。
 * v2.0-audit.2 起合约任何时候都限幅（规则决定 6.33），上一次过期了也一样，所以只有从没报过价（prev = 0）时直达目标。
 * fresh 参数保留给调用方记日志，不再影响结果（旧部署过期后本来可以一步到位，按新规则分步走也合法）。
 */
export function nextPost(target, prev, fresh, maxChangeBps) {
  if (prev === 0n) return target;
  const hi = (prev * (10_000n + maxChangeBps)) / 10_000n;
  const lo = (prev * (10_000n - maxChangeBps) + 9_999n) / 10_000n;
  return target > hi ? hi : target < lo ? lo : target;
}

/** 这一侧（'ask' / 'bid'）的 v 比 24 小时内的最低价高出 maxBps、或比最高价低出 maxBps 时返回原因，否则 null */
function moveTooLarge(side, v, within, maxBps) {
  const vals = within.map((x) => x[side]).filter((x) => x != null).map(BigInt);
  if (v == null || !vals.length) return null;
  const name = side === 'ask' ? '卖一' : '买一';
  const lo = vals.reduce((a, b) => (b < a ? b : a));
  const hi = vals.reduce((a, b) => (b > a ? b : a));
  if (v * 10_000n > lo * (10_000n + maxBps)) return `${name}比 24 小时内最低价高出 ${pct(v - lo, lo)}`;
  if (v * 10_000n < hi * (10_000n - maxBps)) return `${name}比 24 小时内最高价低了 ${pct(hi - v, hi)}`;
  return null;
}

/**
 * 24 小时累计变动检查（2026-10-25 起只有卖一会暂停）：history 是最近读到的日产能价 [{ at, ask, bid }]（字符串），
 * cur 是这次的 { ask, bid }（bigint，bid 可以为 null）。
 * - 卖一比 24 小时内的最低价高出 maxBps、或比最高价低出 maxBps：返回 { ok: false, reason }，不把这次记进历史
 *   （基准不动，暂停报价直到项目方确认）；
 * - 只有买一这样变动：不暂停，返回 { ok: true, bidMoved: reason, history }。这次的买一照样记进历史，所以新价位维持 24 小时后
 *   旧记录滑出窗口，自动被接受；在那之前由调用方沿用上一次用过的买一（买单少，一张小单撤掉就会大跳，不该停掉整个报价）；
 * - 都没问题：返回 { ok: true, history }。history 已加上这次、去掉 25 小时前的。
 */
export function dayGuard(history, now, cur, { maxBps, windowSec = 86_400 }) {
  const kept = (history ?? []).filter((x) => x.at >= now - windowSec - 3_600);
  let bidMoved = null;
  if (maxBps > 0n) {
    const within = kept.filter((x) => x.at >= now - windowSec);
    const askMoved = moveTooLarge('ask', cur.ask, within, maxBps);
    if (askMoved) return { ok: false, reason: askMoved };
    bidMoved = moveTooLarge('bid', cur.bid, within, maxBps);
  }
  const history2 = [...kept, { at: now, ask: String(cur.ask), bid: cur.bid == null ? null : String(cur.bid) }];
  return bidMoved ? { ok: true, bidMoved, history: history2 } : { ok: true, history: history2 };
}
/** 读数按约 1 小时取样（相邻两点至少隔 50 分钟），最后一个读数总是保留：暂停期间约 5 分钟读一次，不取样会把同一小时的小抖动当成多次变动 */
function hourly(points) {
  const out = [];
  for (const p of points) {
    if (!out.length || p.at - out[out.length - 1].at >= 3_000) out.push(p);
  }
  const last = points[points.length - 1];
  if (last && out[out.length - 1] !== last) out.push(last);
  return out;
}

/** 24 小时内的卖一走势：暂停前的历史加暂停后的读数，按小时取样；[{ at, ask: bigint }] */
function askSeries(history, samples, now, windowSec) {
  return hourly(
    [...(history ?? []), ...(samples ?? [])]
      .filter((x) => x.at >= now - windowSec && x.ask != null)
      .map((x) => ({ at: x.at, ask: BigInt(x.ask) }))
      .sort((a, b) => a.at - b.at),
  );
}

/**
 * 慢跌 / 慢涨自动恢复（2026-10-30 项目方决定，见 上线/极端行情应急预案-2026-10-30.md 第八节第 3 条）。
 * 卖一 24 小时累计变动超过上限、暂停报价之后，每次读到行情（约 5 分钟一次）都判断一次：
 * - 逐步变动：暂停前 24 小时的读数加暂停后的读数，按小时取样，相邻两点变动都不超过 stepBps（默认 6%）；
 * - 新价位稳定：暂停后的读数覆盖了最近 stableSec（默认 2 小时），这段时间里的读数都在当前卖一的 stableBps（默认 1%）以内（Firsto 卖一是具体挂单的价格，真稳定时基本不动；匀速每小时跌 1.5% 不算稳定）；
 * - 累计不超过 hardBps（默认 30%）：比 24 小时内最高价低、或比最低价高超过它，一律等人确认。
 * 三条都满足返回 state = 'resume'（相当于机器人自己运行 feed-confirm.mjs）；前一条或第三条不满足返回 'manual'（等人确认）；
 * 只是还没稳定满 stableSec 返回 'waiting'。每个读数本身都是链上核对过、至少 3 个卖家的（不足 3 个时 firstoTargets 不报价也不走到这里）。
 * history 是暂停前的 feedDay，samples 是暂停后的读数 [{ at, ask }]（字符串，含这一次）。
 */
export function autoResume(history, samples, now, { stepBps = 600n, stableSec = 7_200, stableBps = 100n, hardBps = 3_000n, windowSec = 86_400 } = {}) {
  const series = askSeries(history, samples, now, windowSec);
  const cur = BigInt(samples[samples.length - 1].ask);
  let maxStepBps = 0n;
  for (let i = 1; i < series.length; i++) {
    const [a, b] = [series[i - 1].ask, series[i].ask];
    const s = ((a > b ? a - b : b - a) * 10_000n) / a;
    if (s > maxStepBps) maxStepBps = s;
  }
  const vals = series.map((x) => x.ask);
  const hi = vals.reduce((a, b) => (b > a ? b : a), cur);
  const lo = vals.reduce((a, b) => (b < a ? b : a), cur);
  const down = ((hi - cur) * 10_000n) / hi;
  const up = ((cur - lo) * 10_000n) / lo;
  const totalBps = down > up ? down : up;
  const recent = samples.filter((x) => x.at >= now - stableSec).map((x) => BigInt(x.ask));
  const spreadBps = recent.reduce((m, v) => {
    const d = ((v > cur ? v - cur : cur - v) * 10_000n) / cur;
    return d > m ? d : m;
  }, 0n);
  const stableFor = now - samples[0].at; // 暂停后的读数覆盖了多久
  const out = { maxStepBps, totalBps, spreadBps, stableFor };
  const p = (bps) => `${(Number(bps) / 100).toFixed(1)}%`;
  if (maxStepBps > stepBps) return { ...out, state: 'manual', reason: `单小时最大变动 ${p(maxStepBps)}，超过 ${p(stepBps)}（可能是砸盘、挂错价或突发行情）` };
  if (totalBps > hardBps) return { ...out, state: 'manual', reason: `24 小时累计变动 ${p(totalBps)}，超过 ${p(hardBps)}` };
  if (spreadBps > stableBps) return { ...out, state: 'waiting', reason: `暂停后价格还在变（最近 ${stableSec / 3600} 小时最大偏离 ${p(spreadBps)}）`, wait: stableSec };
  if (stableFor < stableSec) return { ...out, state: 'waiting', reason: `新价位已稳定 ${Math.floor(stableFor / 60)} 分钟`, wait: stableSec - stableFor };
  return { ...out, state: 'resume', reason: `逐步变动（单小时最大 ${p(maxStepBps)}，24 小时累计 ${p(totalBps)}），新价位已稳定 ${Math.floor(stableFor / 60)} 分钟` };
}

/** 报警里的走势：24 小时内按小时取样，最多 6 个点，BNB 日产能价两位小数，例如 "9.65 → 9.28 → 9.04 → 8.93 → 8.53 → 8.17" */
export function trendText(history, samples, now, windowSec = 86_400) {
  const s = askSeries(history, samples, now, windowSec);
  if (!s.length) return '—';
  const n = Math.min(6, s.length);
  const pick = n === 1 ? [s[0]] : Array.from({ length: n }, (_, i) => s[Math.round((i * (s.length - 1)) / (n - 1))]);
  return pick.map((x) => (Number(x.ask) / 1e18).toFixed(2)).join(' → ');
}

/**
 * 这一小时用哪个买一日产能价（2026-10-27 改成和"正在用的买一"比）。
 * lastUsed = 正在用的买一 { dcp（字符串）, at（最近一次确认它的时间）}；pending = 偏离它的新价位 { dcp, since }（没有为 null）。
 * - 这次的买一离 lastUsed 不超过 maxBps：采用它（held = false），pending 清空。所以一张高价小单出现几小时又撤掉、买一回到原位时，
 *   直接回到正常，不再报警（原来和 24 小时内的最高 / 最低价比，买一回到原位也会被当成大幅变动、一直报警）；
 * - 超过 maxBps：沿用 lastUsed（held = true）。新价位第一次出现时记下 pending（alert = 'new'，只在这时报警一次）；之后一直在
 *   pending 的 maxBps 以内、满 windowSec（24 小时）就采用（alert = 'adopted'）；中途又跳到别的价位，pending 从那时重新算；
 * - 这次一张可用买单都没有：lastUsed 是 maxHoldSec（25 小时）内确认过的就沿用（held = true），否则 dcp = null，
 *   调用方按"卖一 × (1 − FEED_NO_BID_SPREAD_BPS)"估；沿用中的值超过 maxHoldSec 没被确认（新价位一直不稳定）同样按卖一估。
 * - maxBps = 0（测试网）：总是采用这次的买一。
 * 返回 { dcp, held, lastUsed, pending, alert }，调用方把 lastUsed / pending 存回状态。
 */
export function bidDecision(current, lastUsed, pending, now, { maxBps, windowSec = 86_400, maxHoldSec = 90_000 }) {
  const adopt = (alert = null) => ({ dcp: current, held: false, lastUsed: { dcp: String(current), at: now }, pending: null, alert });
  const near = (v, base) => base > 0n && (v > base ? v - base : base - v) * 10_000n <= base * maxBps;
  const usable = lastUsed?.dcp != null && now - Number(lastUsed.at ?? 0) <= maxHoldSec;
  if (current == null) {
    return usable ? { dcp: BigInt(lastUsed.dcp), held: true, lastUsed, pending, alert: null } : { dcp: null, held: false, lastUsed, pending, alert: null };
  }
  if (maxBps <= 0n || lastUsed?.dcp == null || near(current, BigInt(lastUsed.dcp))) return adopt();
  let p = pending;
  let alert = null;
  if (!p || !near(current, BigInt(p.dcp))) {
    p = { dcp: String(current), since: now };
    alert = 'new';
  }
  if (now - Number(p.since) >= windowSec) return adopt('adopted');
  if (!usable) return { dcp: null, held: false, lastUsed, pending: p, alert };
  return { dcp: BigInt(lastUsed.dcp), held: true, lastUsed, pending: p, alert };
}

/** 变动 diff 占基准 base 的百分比（两位小数） */
const pct = (diff, base) => `${(Number((diff * 10_000n) / base) / 100).toFixed(2)}%`;

/** 项目方确认过的大幅变动（scripts/feed-confirm.mjs 写的文件）：比上次处理的更新就清空历史，从这次重新算 */
function applyConfirm(ctx) {
  let c;
  try {
    c = JSON.parse(readFileSync(ctx.cfg.feedConfirmFile, 'utf8'));
  } catch {
    return false;
  }
  const at = Number(c?.confirmedAt ?? 0);
  if (!(at > (ctx.state.data.feedDayResetAt ?? 0))) return false;
  ctx.state.data.feedDayResetAt = at;
  ctx.state.data.feedDay = [];
  log.info('price feed: big move confirmed by the owner, 24h baseline reset', { confirmedAt: at });
  return true;
}

/** 每单位算力的 BEM 价格；dcp 是日产能价（默认卖一），bnbToBem 是链上换算函数 */
export async function targetPrice(q, bnbToBem, dcp = q.dailyCapacityPrice) {
  // 每单位算力每天产出（BEM 最小单位）× 日产能价（BNB wei / 1 BEM/天）÷ 1e8 = 每单位算力的 BNB wei
  const bnbPerWeight = (q.perHourWeight * dcp) / E18 / 10n ** 8n;
  const onchain = await bnbToBem(bnbPerWeight);
  const firsto = (bnbPerWeight * 10n ** 8n) / q.bemPriceBnbWei;
  const diff = onchain > firsto ? onchain - firsto : firsto - onchain;
  return { price: onchain, firsto, deviationBps: firsto > 0n ? (diff * 10_000n) / firsto : 10_000n };
}

/** 这次报的（买一，卖一）：各自向上一次收敛，再保证 买一 ≤ 卖一（上一次合法时，收敛后的卖一一定不低于买一的下限） */
export function nextPair(target, prev, fresh, maxChangeBps) {
  const ask = nextPost(target.ask, prev.ask, fresh, maxChangeBps);
  let bid = nextPost(target.bid, prev.bid, fresh, maxChangeBps);
  if (bid > ask) bid = ask;
  return { bid, ask };
}

/**
 * 用哪个函数报价（v2.0-audit.3 起）：这一步已经到了目标价（买一、卖一都等于目标）用 post，报价随即有效；
 * 还在分步追（离目标超过 5%）用 postCatchUp，合约在追价期间暂停两种局按报价买卖。旧部署没有 postCatchUp 时一律用 post。
 */
export function postFunction(post, target, abi) {
  const reached = post.bid === target.bid && post.ask === target.ask;
  if (reached || !abi?.some((x) => x.name === 'postCatchUp')) return 'post';
  return 'postCatchUp';
}

/** 目标离上一次报价最远的一侧差多少（bps）；从没报过价时为 0 */
export function catchUpGapBps(target, prev) {
  const gap = (t, p) => (p === 0n ? 0n : ((t > p ? t - p : p - t) * 10_000n) / p);
  const a = gap(target.ask, prev.ask);
  const b = gap(target.bid, prev.bid);
  return a > b ? a : b;
}

export async function priceFeed(ctx) {
  const feed = ctx.dep.priceFeed;
  if (!feed || !ABI.priceFeed || process.env.MARKET_SOURCE !== 'firsto') return;
  const F = ABI.priceFeed;
  const [bid, ask, updatedAt, minInterval, maxChangeBps, maxStaleness] = await ctx.pub.multicall({
    contracts: ['bid', 'ask', 'updatedAt', 'minInterval', 'maxChangeBps', 'maxStaleness'].map((functionName) => ({ address: feed, abi: F, functionName })),
    allowFailure: false,
  });
  const age = BigInt(ctx.now) - updatedAt;
  if (updatedAt > 0n && age > maxStaleness) await ctx.alert.send('feed:stale', `⚠️ 矿机买卖报价已超过 ${Number(maxStaleness) / 3600} 小时没更新，合约已暂停两种局的矿机买卖`, { everySec: 3 * 3600 });
  if (updatedAt > 0n && age < minInterval + 60n) return; // 留 1 分钟余量，免得区块时间差导致 TooSoon
  // 成功后约 1 小时再报；读 Firsto 失败后 5 分钟重试（不要猛刷对方接口，对方有频率限制）
  const nowSec = Date.now() / 1000;
  if (nowSec < (ctx.state.data.feedNextTry ?? 0)) return;
  ctx.state.data.feedNextTry = nowSec + 300;

  const t = ctx.cfg.mainnet || !ctx.dep.firstoAskExchange ? await firstoTargets(ctx) : await mockTargets(ctx);
  if (!t) return;
  const { askTarget } = t;
  let { bidTarget } = t;
  if (bidTarget > askTarget) bidTarget = askTarget;
  if (bidTarget <= 0n) return;
  const fresh = updatedAt > 0n && age <= maxStaleness;
  const post = nextPair({ bid: bidTarget, ask: askTarget }, { bid, ask }, fresh, maxChangeBps);
  if (post.bid <= 0n) return;
  const note = post.bid !== bidTarget || post.ask !== askTarget ? ` (target ${bidTarget} / ${askTarget})` : '';
  const fn = postFunction(post, { bid: bidTarget, ask: askTarget }, F);
  if (fn === 'postCatchUp') {
    // 只差一步（≤ 2 × 5%）下一次就追上，只记日志；超过 10% 要追两步以上才发提醒（2026-10-28 定）
    const gapBps = catchUpGapBps({ bid: bidTarget, ask: askTarget }, { bid, ask });
    if (gapBps > 2n * maxChangeBps) {
      await ctx.alert.send('feed:catchup', `⏳ 市价离上一次报价超过 ${Number(2n * maxChangeBps) / 100}%（差 ${Number(gapBps) / 100}%），正在分步追价（每 50 分钟 ${Number(maxChangeBps) / 100}%），追价期间两种局暂停矿机买卖：现报 ${post.bid} / ${post.ask}，目标 ${bidTarget} / ${askTarget}`, { everySec: 3 * 3600 });
    } else {
      log.info('price feed: catching up one step, no alert', { gapBps: Number(gapBps), post: `${post.bid} / ${post.ask}`, target: `${bidTarget} / ${askTarget}` });
    }
  }
  const r = await ctx.sender.send(`price feed ${fn} ${post.bid} / ${post.ask}${note}`, feed, F, fn, [post.bid, post.ask]);
  if (r.ok) {
    ctx.state.data.feedLast = { bid: String(post.bid), ask: String(post.ask), target: { bid: String(bidTarget), ask: String(askTarget) }, at: ctx.now };
    ctx.state.data.feedNextTry = nowSec + (ctx.cfg.mainnet ? 3_300 : 3_000);
  }
}

/** 主网：Firsto 接口的买一 / 卖一，换成主板经 Firsto 实际成交的价（见文件开头）。读不到或偏差太大时返回 null（本小时不报） */
export async function firstoTargets(ctx) {
  let q;
  try {
    const latestBlock = ctx.cfg.mainnet ? BigInt(ctx.summary.block) : null;
    // 每小时这一次是"真正去读"（fresh），同时更新共用缓存，自动买卖在这一小时里就用缓存（Firsto 约定每小时一次）
    let asks = await getJson(FIRSTO, { fresh: true });
    if (ctx.cfg.mainnet) {
      // 第一页被少数卖家占满时往后翻（同一份快照），凑够卖家再核对
      asks = await withMoreAskPages(asks, async (page) => {
        await new Promise((r) => setTimeout(r, 1500)); // 对方有并发限制
        return getJson(asksPageUrl(asks.viewId, page), { fresh: true });
      }, { now: Math.floor(ctx.now) });
      // 挂单逐条在链上模拟购买，买不到的不算，每个卖家一条
      const v = await verifiedAskRows(ctx.pub, asks, { now: Math.floor(ctx.now) });
      ctx.summary.feedAsks = { pages: asks.pagesRead ?? 1, checked: v.checked, skipped: v.skipped, verified: v.rows.length, rejected: v.rejected };
      if (v.rejected.length) log.warn('price feed: Firsto listings failed the on-chain check', { rejected: v.rejected });
      if (v.rows.length < 3) {
        await ctx.alert.send(
          'feed:asks',
          `⚠️ Firsto 上能在链上确认真实可买的挂单不足 3 个不同卖家（读了 ${asks.pagesRead ?? 1} 页，核对 ${v.checked} 条，通过 ${v.rows.length} 个卖家），本小时没有报价`,
          { everySec: 3 * 3600 },
        );
        return null;
      }
      asks = { ...asks, rows: v.rows }; // 不改共用缓存：自动买卖自己逐单模拟
    }
    q = firstoQuote(asks, { latestBlock, now: Math.floor(ctx.now) });
    await new Promise((r) => setTimeout(r, 1500)); // 两次请求隔开一点，对方有并发限制
    let bids = await getJson(FIRSTO_BIDS, { fresh: true });
    // 买一只算能买下参考矿机（卖一中位数那台）的买单，每个出价人一张；主网上逐张读链上状态核对
    const ref = { refWeight: q.refWeight, refDailyAtomic: q.refDailyAtomic };
    if (ctx.cfg.mainnet) {
      const vb = await verifiedBids(ctx.pub, bids, ref);
      ctx.summary.feedBids = { checked: vb.checked, verified: vb.bids.length, rejected: vb.rejected };
      if (vb.rejected.length) log.warn('price feed: Firsto bids failed the on-chain check', { rejected: vb.rejected });
      bids = { ...bids, bids: vb.bids };
    }
    Object.assign(q, firstoBid(bids, { latestBlock, ...ref }));
  } catch (e) {
    log.warn('price feed: Firsto unavailable', { reason: e.message });
    await ctx.alert.send('feed:firsto', `⚠️ 读不到 Firsto 行情，本小时没有报价：${e.message}`, { everySec: 3 * 3600 });
    return null;
  }
  if (ctx.cfg.mainnet) {
    // 卖一大幅变动：暂停报价。逐步变动、新价位稳定 2 小时后自动恢复（autoResume，2026-10-30 项目方决定）；
    // 跳变或累计太大一直停着，直到项目方确认（不会因为 24 小时窗口滑过去就自己恢复）。买一大幅变动不暂停（见 bidDecision）
    if (applyConfirm(ctx)) delete ctx.state.data.feedDayPaused;
    const now = Math.floor(ctx.now);
    const cur = { ask: q.dailyCapacityPrice, bid: q.bidDailyCapacityPrice };
    const maxBps = ctx.cfg.feedMaxDayChangeBps;
    let paused = ctx.state.data.feedDayPaused;
    let g = paused ? { ok: false, reason: paused.reason } : dayGuard(ctx.state.data.feedDay, now, cur, { maxBps });
    if (!g.ok) {
      paused = ctx.state.data.feedDayPaused ??= { at: now, reason: g.reason };
      // 暂停后的读数（只记卖一），用来判断新价位稳不稳；最多留 24 小时
      paused.samples = [...(paused.samples ?? []), { at: now, ask: String(cur.ask) }].filter((x) => x.at >= now - 86_400).slice(-400);
      const history = ctx.state.data.feedDay;
      const auto = ctx.cfg.feedAutoResume ? autoResume(history, paused.samples, now, ctx.cfg.feedAuto) : null;
      const sellers = ctx.summary.feedAsks?.verified;
      const evidence =
        `走势（卖一日产能价，BNB，约每 4 小时一个点）：${trendText(history, paused.samples, now)}\n` +
        (auto ? `单小时最大变动 ${(Number(auto.maxStepBps) / 100).toFixed(1)}%，` : '') +
        `本次核对通过 ${sellers ?? '?'} 个卖家`;
      if (auto?.state === 'resume') {
        log.info('price feed: gradual move, auto-resumed', { reason: paused.reason, auto: auto.reason });
        await ctx.alert.send(
          'feed:dayauto',
          `✅ 矿机报价已自动恢复：${paused.reason}，属于${auto.reason}。按新价位继续报价，每次仍最多变 5%。\n${evidence}`,
          { everySec: 3_600 },
        );
        delete ctx.state.data.feedDayPaused;
        g = dayGuard([], now, cur, { maxBps }); // 和 feed-confirm 一样：24 小时基准从这次重新算
      } else {
        log.warn('price feed: paused, 24h move too large', { reason: g.reason, auto: auto?.state, why: auto?.reason });
        const { stableSec, stableBps } = ctx.cfg.feedAuto;
        const how = !auto
          ? '请先到 Firsto 核对行情是否真实，确认后恢复。'
          : auto.state === 'waiting'
            ? `看起来是逐步变动（${auto.reason}）：新价位连续稳定 ${stableSec / 3600} 小时后会自动恢复` +
              `${auto.spreadBps <= stableBps ? `（约 ${Math.ceil(auto.wait / 60)} 分钟后）` : ''}，一般不用处理；拿不准可以先到 Firsto 看一眼。`
            : `不会自动恢复：${auto.reason}。请先到 Firsto 核对行情是否真实，确认后恢复。`;
        await ctx.alert.send(
          'feed:daymove',
          `🛑 矿机市场价 24 小时内变动过大（${g.reason}，上限 ${Number(maxBps) / 100}%），已暂停自动报价。\n${evidence}\n${how}\n` +
            `要立即恢复：cd ~/tapesurge-bot && node scripts/feed-confirm.mjs ${ctx.cfg.chainId}`,
          { everySec: 3 * 3600 },
        );
        return null;
      }
    }
    ctx.state.data.feedDay = g.history;
  }
  const toBem = (bnb) => ctx.pub.readContract({ address: ctx.dep.oracle, abi: ABI.oracle, functionName: 'quoteBemOut', args: [bnb] });
  const a = await targetPrice(q, toBem);
  const now = Math.floor(ctx.now);
  const d = bidDecision(q.bidDailyCapacityPrice, ctx.state.data.feedBidUsed, ctx.state.data.feedBidPending ?? null, now, {
    maxBps: ctx.cfg.mainnet ? ctx.cfg.feedMaxDayChangeBps : 0n,
  });
  ctx.state.data.feedBidUsed = d.lastUsed;
  ctx.state.data.feedBidPending = d.pending;
  const { dcp: bidDcp, held } = d;
  const dcpBnb = (x) => (Number(x) / 1e18).toFixed(3);
  let rawBid;
  if (bidDcp != null) {
    rawBid = (await targetPrice(q, toBem, bidDcp)).price;
    if (d.alert === 'new' && q.bidDailyCapacityPrice != null) {
      // 只在新价位第一次出现时报一次（价格回到原位就自动恢复，不再报）
      await ctx.alert.send(
        'feed:bidhold',
        `ℹ️ 矿机买一和正在用的相差超过 ${Number(ctx.cfg.feedMaxDayChangeBps) / 100}%（Firsto 现在 ${dcpBnb(q.bidDailyCapacityPrice)} BNB，正在用 ${dcpBnb(bidDcp)} BNB，均为日产能价），` +
          `先沿用原来的买一，报价照常。新价位连续维持 24 小时才会采用，中途回到原位就当没发生；买单很少时一张单挂上或撤掉就会这样，一般不用处理`,
        { everySec: 3_600 },
      );
    } else if (held && q.bidDailyCapacityPrice == null) {
      await ctx.alert.send('feed:bidhold', `ℹ️ 这次没有能买下一台参考矿机的买单，沿用原来的买一（日产能价 ${dcpBnb(bidDcp)} BNB），报价照常`, { everySec: 24 * 3600 });
    }
  } else {
    rawBid = (a.price * (10_000n - ctx.cfg.feedNoBidSpreadBps)) / 10_000n;
    await ctx.alert.send('feed:nobid', `⚠️ Firsto 上没有能买下一台参考矿机的求购（或买一刚大幅变动、没有上一次可沿用），买一按卖一 − ${Number(ctx.cfg.feedNoBidSpreadBps) / 100}% 估算`, { everySec: 24 * 3600 });
  }
  if (d.alert === 'adopted') {
    await ctx.alert.send('feed:bidadopt', `ℹ️ 矿机买一的新价位已连续维持 24 小时，已采用（日产能价 ${dcpBnb(bidDcp)} BNB）；离上一次报价超过 5% 时会分步追价`, { everySec: 3_600 });
  }
  // 兑换成本按"卖一中位数那台矿机"的整台金额实时报（两个方向各算一次），见 src/swapcost.js
  const sAsk = await feedSwapBps(ctx, 'bnbOut', q.refCostWei);
  const sBid = await feedSwapBps(ctx, 'bemOut', await toBem(q.refCostWei));
  const askTarget = (a.price * (10_000n + sAsk.bps)) / 10_000n;
  const bidTarget = (rawBid * (10_000n - FIRSTO_SELLER_FEE_BPS) * (10_000n - sBid.bps)) / 10_000n / 10_000n;
  ctx.summary.feed = {
    bid: String(bidTarget),
    ask: String(askTarget),
    rawBid: String(rawBid),
    rawAsk: String(a.price),
    firsto: String(a.firsto),
    deviationBps: Number(a.deviationBps),
    bids: q.bidCount,
    bidDcp: bidDcp == null ? null : String(bidDcp),
    bidHeld: held,
    swapBps: { ask: Number(sAsk.bps), bid: Number(sBid.bps), rawAsk: Number(sAsk.rawBps), rawBid: Number(sBid.rawBps), refWei: String(q.refCostWei) },
  };
  // 测试网的 TWAP 来自测试网池子，和主网 Firsto 价格没有可比性，只在主网做偏差检查
  if (ctx.cfg.mainnet && a.deviationBps > 1_000n) {
    await ctx.alert.send('feed:deviation', `⚠️ 链上 TWAP 和 Firsto 的 BEM 价格偏差 ${Number(a.deviationBps) / 100}%，本小时不报价`, { everySec: 3 * 3600 });
    return null;
  }
  return { askTarget, bidTarget };
}

/**
 * 测试网：Firsto 不在测试网上，部署时生成了模拟市场（卖单 JSON + mock 合约），而且测试网汇率和价格都按比例缩放过，
 * 不能再用主网 Firsto 的 BNB 价格。卖一 = 还没成交的模拟卖单里最便宜 3 张"每单位算力含费价"的中位数 ×（1 + 兑换成本），
 * 用链上 TWAP 换成 BEM；买一 = 卖一 ×（1 − feedTestnetSpreadBps）。价差要窄：报价合约"每小时 +0.5%"按真实时间走，
 * 288 倍下一轮收购只有约 35 分钟，收购价基本停在买一 × 1.005，价差宽了就一张卖单都吃不到。
 */
async function mockTargets(ctx) {
  const { pub, dep, cfg } = ctx;
  let asks;
  try {
    const file = resolve(ROOT, cfg.firstoAsksFile ?? `deployments/${cfg.chainId}-firsto-asks.json`);
    asks = parseAsks(JSON.parse(readFileSync(file, 'utf8')), { now: ctx.now, exchange: dep.firstoAskExchange, collection: dep.machines, chainId: cfg.chainId });
  } catch (e) {
    log.warn('price feed: mock asks unavailable', { reason: e.message });
    return null;
  }
  const live = [];
  for (const a of asks) {
    const owner = await pub.readContract({ address: dep.machines, abi: OWNER_OF, functionName: 'ownerOf', args: [a.tokenId] }).catch(() => null);
    if (owner && owner.toLowerCase() === String(a.leaf.maker).toLowerCase()) live.push(a); // 矿机还在挂单人手里 = 还没成交
  }
  if (!live.length) {
    await ctx.alert.send('feed:mock', '⚠️ 测试网的模拟卖单都已成交，本小时不报价', { everySec: 6 * 3600 });
    return null;
  }
  const per = live.map((a) => a.perWeightWei).sort((x, y) => (x < y ? -1 : x > y ? 1 : 0));
  const median = per.length >= 3 ? per[1] : per[0];
  const rawAsk = await pub.readContract({ address: dep.oracle, abi: ABI.oracle, functionName: 'quoteBemOut', args: [median] });
  const askTarget = (rawAsk * (10_000n + cfg.swapCostBps)) / 10_000n;
  const bidTarget = (askTarget * (10_000n - cfg.feedTestnetSpreadBps)) / 10_000n;
  ctx.summary.feed = { bid: String(bidTarget), ask: String(askTarget), rawAsk: String(rawAsk), mockAsks: live.length };
  return { askTarget, bidTarget };
}

/** 新局模板升级提议（7 天公示）：有待生效的模板就报警，方便大家检查新代码 */
export async function templateWatch(ctx) {
  for (const [name, address, abi] of [
    ['标准局工厂', ctx.dep.factory, ABI.factory],
    ['月局工厂', ctx.dep.monthFactory, ABI.monthFactory],
  ]) {
    if (!address || !abi?.some((x) => x.name === 'pendingImplementation')) continue;
    const [impl, eta] = await ctx.pub.multicall({
      contracts: [
        { address, abi, functionName: 'pendingImplementation' },
        { address, abi, functionName: 'pendingEta' },
      ],
      allowFailure: false,
    });
    if (/^0x0{40}$/i.test(impl)) continue;
    await ctx.alert.send(`template:${address}:${impl}`, `🛠 ${name}有新模板提议待生效：${impl}，最早 ${new Date(Number(eta) * 1000).toISOString()} 生效`, { everySec: 86_400 });
  }
}
