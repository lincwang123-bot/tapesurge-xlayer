// 矿机行情：从 Firsto TapeOut 交易终端的公开接口算买一 / 卖一（v2.0-rc3 起两种局的矿机买卖都按这两个价由合约公式定价，
// 机器人只负责每小时报价，见 tasks/pricefeed.js）。合约读不到外部市场，所以由运营地址报价。

import { askCandidates, dcpOf } from './askcheck.js';

const E18 = 10n ** 18n;
const MIN_DCP = E18 / 2n; // 日产能价合理范围：0.5–100 BNB
const MAX_DCP = 100n * E18;

const median3 = (sorted) => (sorted.length >= 3 ? sorted[1] : sorted[0]);

/**
 * Firsto 的计价单位是"日产能价"：每天产出 1 BEM 要花多少 BNB。
 * - 卖一：按买家实际付出（`bestAsk.buyerCostWei`，含买方 1% 手续费）算，同一卖家只算最便宜的一条，取最便宜 3 个不同卖家的
 *   中位数，不足 3 个卖家就抛错（一个人用几台矿机就能决定中位数）。主网上调用方先用 askcheck.js 在链上核对挂单，
 *   只把能真实成交的传进来；
 * - 买一：见 `firstoBid`（读 Firsto 的统一买单，不在这里算）。
 * 同类矿机的日产出和算力成正比，所以一台矿机的市场价（BEM）= 算力 × 每 H 日产出 × 日产能价 ÷ BEM 的 BNB 价格。
 * 数据要新，价格要在合理范围内，否则抛错（不报价）。
 */
export function firstoQuote(json, { latestBlock, now } = {}) {
  const seen = new Set();
  const rows = askCandidates(json, { now })
    .filter((c) => c.maker && !seen.has(c.maker) && seen.add(c.maker))
    .map((c) => c.row);
  if (rows.length < 3) throw new Error(`Firsto 已验证挂单的卖家太少（${rows.length} 个，至少要 3 个不同卖家）`);
  if (latestBlock != null && json.sourceBlock && latestBlock - BigInt(json.sourceBlock) > 1200n) {
    throw new Error(`Firsto 数据落后 ${latestBlock - BigInt(json.sourceBlock)} 个区块`); // BSC 约 0.75 秒一块，1200 块约 15 分钟
  }
  // 日产能价，BNB wei / (1 BEM / 天)；rows 已按它从低到高排
  const priced = rows.map((r) => ({ dcp: dcpOf(r), cost: BigInt(r.bestAsk.buyerCostWei) }));
  const dailyCapacityPrice = priced[1].dcp; // 最便宜 3 个卖家的中位数
  const refCostWei = priced[1].cost; // 这一条的整台含费价：报价时按这个金额估兑换成本
  // 每 H 每天产出（BEM 最小单位 × 1e18 精度），用同一批挂单算
  const r0 = rows[0];
  const perHourWeight = (BigInt(r0.mining.estimated24hAtomic) * E18) / BigInt(r0.mining.weight);
  const bemPriceBnbWei = BigInt(r0.valuation?.bemPriceBnbWei ?? 0);
  if (bemPriceBnbWei <= 0n) throw new Error('Firsto 没有 BEM 价格');
  if (dailyCapacityPrice < MIN_DCP || dailyCapacityPrice > MAX_DCP) throw new Error(`日产能价 ${dailyCapacityPrice} 不在 0.5–100 BNB 范围内`);
  return {
    dailyCapacityPrice,
    refCostWei,
    // 参考矿机（卖一中位数那台）：买一只算能买下它的买单
    refWeight: BigInt(rows[1].mining.weight),
    refDailyAtomic: BigInt(rows[1].mining.estimated24hAtomic),
    perHourWeight,
    bemPriceBnbWei,
    sourceBlock: json.sourceBlock,
    /** 一台算力为 weight 的矿机按卖一的市场价，BEM 最小单位 */
    priceFor: (m) => {
      const w = BigInt(m?.weight ?? 0);
      if (w <= 0n) return undefined;
      const dailyBem = (w * perHourWeight) / E18; // BEM 最小单位 / 天
      return (dailyBem * dailyCapacityPrice) / bemPriceBnbWei;
    },
  };
}

/** 剩余预算的绝对下限：低于它的统一买单一律不算（没有参考矿机时只用这一条） */
export const MIN_BID_BUDGET_WEI = 10n ** 17n; // 0.1 BNB

/**
 * 一张买单按它自己的日产能价买下参考矿机要付多少（BNB wei）= 参考矿机日产出（BEM 最小单位）× 日产能价 ÷ 1e8，
 * 不低于 MIN_BID_BUDGET_WEI。剩余预算不够这个数的买单连一台参考矿机都吃不下，不能代表"现在能卖出去的价"。
 */
export function bidNeedWei(dcp, refDailyAtomic) {
  const need = refDailyAtomic ? (BigInt(refDailyAtomic) * dcp) / 10n ** 8n : 0n;
  return need > MIN_BID_BUDGET_WEI ? need : MIN_BID_BUDGET_WEI;
}

/** 买单收的算力范围（minCircuitH / maxCircuitH，0 = 不限）是否包括参考矿机的算力 */
const acceptsWeight = (b, weight) =>
  weight == null ||
  ((BigInt(b.minCircuitH ?? 0) === 0n || weight >= BigInt(b.minCircuitH)) && (BigInt(b.maxCircuitH ?? 0) === 0n || weight <= BigInt(b.maxCircuitH)));

/**
 * 能参与买一的统一买单：状态有效、日产能价在合理范围内、剩余预算够买下一台参考矿机（按这张买单自己的价格算）、
 * 收的算力范围包括参考矿机。按日产能价从高到低排；maker = 出价人（小写，用来去重）。
 */
export function bidCandidates(json, { refWeight, refDailyAtomic } = {}) {
  const weight = refWeight == null ? null : BigInt(refWeight);
  return (json?.bids ?? [])
    .map((b) => ({ bid: b, dcp: BigInt(b?.dailyCapacityPriceWei ?? 0), maker: String(b?.maker ?? '').toLowerCase() }))
    .filter(({ bid, dcp }) => bid?.state === 'active' && dcp >= MIN_DCP && dcp <= MAX_DCP)
    .filter(({ bid, dcp }) => BigInt(bid.remainingBudgetWei ?? 0) >= bidNeedWei(dcp, refDailyAtomic) && acceptsWeight(bid, weight))
    .sort((a, b) => (a.dcp > b.dcp ? -1 : a.dcp < b.dcp ? 1 : 0));
}

/**
 * 买一：Firsto 的"统一买单"（`/v1/circuit/capacity-bids`），每张买单直接写明日产能价，任何符合条件的已验证矿机都能卖给它。
 * 只算 bidCandidates 留下的买单，每个出价人只算他最高的一张，取最高 3 个出价人的中位数（不足 3 个取最高的那个）。
 * 主网上调用方先用 bidcheck.js 在链上核对买单，只把核对通过的传进来。
 * 2026-10-23 测试发现：单台矿机上的定向出价（`maxBidSellerNetWei`）大多是压价单，只有卖一的约 30%，不能当买一。
 * 没有符合条件的买单时返回 null，由调用方决定怎么办。
 */
export function firstoBid(json, { latestBlock, refWeight, refDailyAtomic } = {}) {
  if (latestBlock != null && json?.sourceBlock && latestBlock - BigInt(json.sourceBlock) > 1200n) {
    throw new Error(`Firsto 买单数据落后 ${latestBlock - BigInt(json.sourceBlock)} 个区块`);
  }
  const seen = new Set();
  const bids = bidCandidates(json, { refWeight, refDailyAtomic })
    .filter((c) => !c.maker || (!seen.has(c.maker) && seen.add(c.maker)))
    .map((c) => c.dcp);
  return { bidDailyCapacityPrice: bids.length ? median3(bids) : null, bidCount: bids.length };
}

