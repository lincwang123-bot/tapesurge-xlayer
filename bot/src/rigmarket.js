// X Layer RIG 矿机市场（XRigMarket）的选单逻辑：纯函数，方便单测。链上读写在 tasks/rigMarket.js。
// 价格单位都是"每单位算力的 BEM 最小单位"，整张 = 单价 × 算力；全部是 bigint。

const cmpPriceAsc = (a, b) => (a.price < b.price ? -1 : a.price > b.price ? 1 : a.rigId < b.rigId ? -1 : a.rigId > b.rigId ? 1 : 0);
const cmpPriceDesc = (a, b) => (a.price > b.price ? -1 : a.price < b.price ? 1 : a.bidId < b.bidId ? -1 : a.bidId > b.bidId ? 1 : 0);

/**
 * 分页读到的订单（asksPage / bidsPage）整理成盘口：只留有效的，按 key 去重（分页之间订单数组可能变动），
 * 卖单按单价从低到高、买单从高到低，同价按编号——和合约 book() 的顺序相同。
 * 不直接调 book()：它每次对全部订单排序、逐个调外部合约，订单多了会超出节点的调用 gas 上限（全局审计 2026-10-29 第 8 条）。
 */
export function bookFromPages(asks, bids) {
  const uniq = (xs, key) => [...new Map(xs.map((x) => [String(x[key]), x])).values()];
  return [uniq(asks, 'rigId').filter((a) => a.valid).sort(cmpPriceAsc), uniq(bids, 'bidId').filter((b) => b.valid).sort(cmpPriceDesc)];
}

/**
 * 正在收购的月局从市场买哪些卖单（对应 BSC 规则 6.37：从最便宜的往上买）：
 * 只看有效、符合月局收购资格（boardEligible）的卖单；单价不超过月局当前收购价 buyPrice；
 * 整张价累计不超过剩余预算 budget；最多 slots 张；taken 里的（别的月局这一轮已经选了）跳过。
 * 合约还会再查一遍（算力范围、预算、买满），挑错了只会模拟失败、不发交易。
 */
export function pickAsksForBoard(asks, { buyPrice, budget, slots, taken = new Set() }) {
  const out = [];
  let left = budget;
  for (const a of [...asks].sort(cmpPriceAsc)) {
    if (out.length >= slots) break;
    if (a.price > buyPrice) break;
    if (!a.valid || !a.boardEligible || taken.has(a.rigId)) continue;
    if (a.total > left) continue;
    out.push(a.rigId);
    left -= a.total;
  }
  return out;
}

/**
 * 结算中的月局矿机（boardOffers）配哪张统一买单：出价从高到低，第一张满足条件的——
 * 算力在 [minPower, maxPower]，同步时间满足 maxSyncAge（0 = 不限），单价 × 算力 ≥ 月局要价，剩余预算够付要价。
 * 买家只付要价，剩余预算按要价扣（同一轮里一张买单可以配多台）。
 * assumeSynced = true 时按"马上会先收取一次"处理（同步时间当作 now），用来决定要不要先刷新同步时间。
 * 返回 [{ index, rigId, bidId, total, fresh }]，fresh = 卖矿合约现在就认这台的同步时间（1 天内）。
 */
export function matchBids(offers, bids, now, { assumeSynced = false } = {}) {
  const pool = bids.filter((b) => b.valid).map((b) => ({ ...b, left: b.remaining })).sort(cmpPriceDesc);
  const out = [];
  for (const o of offers) {
    const syncedAt = assumeSynced ? now : o.syncedAt;
    for (const b of pool) {
      if (o.power < b.minPower || o.power > b.maxPower) continue;
      // 同步时间晚于 now（刚收取过、链上时间比 ctx.now 新）按 0 算；合约成交时还会再查
      if (b.maxSyncAge > 0n && syncedAt < now && now - syncedAt > b.maxSyncAge) continue;
      if (b.price * o.power < o.total || b.left < o.total) continue;
      out.push({ index: o.index, rigId: o.rigId, bidId: b.bidId, total: o.total, fresh: o.syncFresh });
      b.left -= o.total;
      break;
    }
  }
  return out;
}

/** 已失效、可以清理的卖单编号（asksPage 的结果） */
export function deadAsks(asks) {
  return asks.filter((a) => !a.valid).map((a) => a.rigId);
}

/** 已过期、可以帮买家退款的买单编号（bidsPage 的结果） */
export function expiredBids(bids, now) {
  return bids.filter((b) => b.bidder !== '0x0000000000000000000000000000000000000000' && BigInt(b.deadline) <= now).map((b) => b.bidId);
}
