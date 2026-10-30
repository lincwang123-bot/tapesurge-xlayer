// X Layer 版：把 BSC 主网报价合约（MarketPriceFeed）的买一 / 卖一转报到 X Layer 的 XMarketPriceFeed。
// 用途只有一个：多数集体清算的计划价不低于 BSC 买一 × 算力 × 95%（xlayer/contracts/V2-PORT.md 第 3 节）。
// 规则照搬 BSC：每次最多变 5%、两次至少隔 50 分钟、3 小时没更新算过期；BSC 在追价时这里用 postCatchUp，
// 这里落后 BSC 超过 5% 时也按 ±5% 一步步追（追价的报价不算有效），追到的最后一步用 post。
// BSC 那边过期（没在追价、fresh() 为假）就不转报：让 X Layer 的报价跟着过期，计划价暂停，和 BSC 一致。
import { ABI } from '../abi.js';
import * as log from '../log.js';

const BPS = 10_000n;

/** 把目标价限制在上次报价的 ±maxChangeBps 之内（和 XLayerTestnetScenario._step 相同，下限向上取整，保证合约认） */
export function stepToward(target, last, maxChangeBps) {
  const hi = (last * (BPS + maxChangeBps)) / BPS;
  const lo = (last * (BPS - maxChangeBps) + BPS - 1n) / BPS;
  return target > hi ? hi : target < lo ? lo : target;
}

/**
 * 这次要报的价。src = BSC 当前的 { bid, ask, catchingUp }，last = X Layer 上一次的 { bid, ask, updatedAt }。
 * 返回 { bid, ask, catchUp, gapBps }：gapBps 是 BSC 目标离上一次报价最远的一侧（万分比），只用来记日志 / 报警。
 */
export function planRelay(src, last, maxChangeBps) {
  let { bid, ask } = src;
  let catchUp = Boolean(src.catchingUp);
  let gapBps = 0n;
  if (last.updatedAt > 0n) {
    const gap = (to, from) => (from === 0n ? 0n : ((to > from ? to - from : from - to) * BPS) / from);
    gapBps = gap(bid, last.bid) > gap(ask, last.ask) ? gap(bid, last.bid) : gap(ask, last.ask);
    const b = stepToward(bid, last.bid, maxChangeBps);
    let a = stepToward(ask, last.ask, maxChangeBps);
    if (a < b) a = b;
    if (b !== bid || a !== ask) {
      bid = b;
      ask = a;
      catchUp = true;
    }
  }
  return { bid, ask, catchUp, gapBps };
}

/** 到点了吗：从没报过价就马上报；之后按 max(合约最短间隔, 配置的间隔) */
export function relayDue(now, updatedAt, minInterval, everySec) {
  if (updatedAt === 0n) return true;
  const wait = BigInt(everySec) > minInterval ? BigInt(everySec) : minInterval;
  return BigInt(now) >= updatedAt + wait;
}

export async function relayBscFeed(ctx) {
  const { pub, dep, cfg, sender, state } = ctx;
  const X = ABI.xFeed;
  if (!X || !dep.priceFeed || !ctx.bsc) return;
  if (!cfg.bscPriceFeed) {
    await ctx.alert.send('xfeed:config', '⚠️ X Layer 报价转报没有 BSC 报价合约地址（部署文件 bscPriceFeed 或 BSC_PRICE_FEED）', { everySec: 86_400 });
    return;
  }
  const read = (functionName) => ({ address: dep.priceFeed, abi: X, functionName });
  const [lastBid, lastAsk, updatedAt, minInterval, maxStaleness, maxChangeBps] = await pub.multicall({
    contracts: ['bid', 'ask', 'updatedAt', 'minInterval', 'maxStaleness', 'maxChangeBps'].map(read),
    allowFailure: false,
  });
  if (updatedAt > 0n && BigInt(ctx.now) >= updatedAt + maxStaleness) {
    const hours = Number(BigInt(ctx.now) - updatedAt) / 3600;
    await ctx.alert.send('xfeed:stale', `⏳ X Layer 的 BSC 行情转报已经 ${hours.toFixed(1)} 小时没更新（超过 3 小时算过期，集体清算的计划价暂停）`, { everySec: 6 * 3600 });
  }
  if (!relayDue(ctx.now, updatedAt, minInterval, cfg.xFeedEverySec)) return;
  // 到点之后读 BSC 失败、或 BSC 过期时，隔 5 分钟再试，不是每轮都去读
  if (!state.due('xfeed:try', ctx.every(300))) return;

  const B = ABI.bscFeed;
  const bscBlock = await ctx.bsc.getBlockNumber();
  const at = (functionName) => ({ address: cfg.bscPriceFeed, abi: B, functionName });
  const [bid, ask, catchingUp, fresh] = await ctx.bsc.multicall({
    contracts: ['bid', 'ask', 'catchingUp', 'fresh'].map(at),
    allowFailure: false,
    blockNumber: bscBlock,
  });
  ctx.summary.bscFeed = { block: Number(bscBlock), bid: String(bid), ask: String(ask), catchingUp, fresh };
  if (bid === 0n || bid > ask) {
    log.warn('BSC price feed has no usable prices', { bid, ask });
    return;
  }
  if (!fresh && !catchingUp) {
    log.info('BSC price feed is stale, not relaying', { bscBlock });
    await ctx.alert.send('xfeed:bscstale', '⏳ BSC 主网报价合约已过期（BSC 机器人可能停了），X Layer 暂不转报，计划价会跟着暂停', { everySec: 6 * 3600 });
    return;
  }
  const p = planRelay({ bid, ask, catchingUp }, { bid: lastBid, ask: lastAsk, updatedAt }, maxChangeBps);
  const fn = p.catchUp ? 'postCatchUp' : 'post';
  const r = await sender.send(`xfeed ${fn} ${p.bid} / ${p.ask} (BSC block ${bscBlock})`, dep.priceFeed, X, fn, [p.bid, p.ask, bscBlock]);
  if (r.ok && p.catchUp && !catchingUp && p.gapBps > 2n * maxChangeBps) {
    // 和 BSC 的追价提醒同一个门槛（离目标超过 10% 才发；一步能追上的只记日志）
    await ctx.alert.send('xfeed:catchup', `⏳ X Layer 行情转报离 BSC 差 ${(Number(p.gapBps) / 100).toFixed(2)}%，按每次 5% 分步追价，追价期间清算计划价暂停`, { everySec: 6 * 3600 });
  }
}
