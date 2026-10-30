// 报买一用的 Firsto 统一买单先在链上核对：接口返回的买单可能已经撤单、成交完或预算不够，有人挂几张假的高价单
// 就能把买一往上带。这里直接读统一买单合约里这张单的当前状态（只读 eth_call），用链上的价格、剩余预算、算力范围、出价人
// 替换接口数据，再按 market.js 的 bidCandidates 同样的条件过一遍。不发交易，不花钱。
import { concatHex, decodeAbiParameters, encodeAbiParameters, parseAbiParameters } from 'viem';
import { FIRSTO_BID_EXCHANGE } from './firsto.js';
import { bidCandidates } from './market.js';

// 统一买单合约 0x9273…7040（UUPS 代理）的读接口 0x3fbefb08(uint256 orderId)。实现合约没有公开源码，字段按 2026-10-25
// 主网只读调用和接口数据逐项对出来：state 1 = 有效，2 = 已结束；不存在的编号会回滚。
const GET_BID = '0x3fbefb08';
const BID_FIELDS = parseAbiParameters(
  'address maker, address nftRecipient, address refundRecipient, uint256 dailyCapacityPriceWei, uint256 remainingBudgetWei, uint256 minCircuitH, uint256 maxCircuitH, uint256 feeBps, uint256 state',
);
export const BID_STATE_ACTIVE = 1n;

/** 读一张买单的链上状态，返回和接口同样字段名的对象（state 有效时为 'active'） */
export async function readBid(pub, orderId, { exchange = FIRSTO_BID_EXCHANGE } = {}) {
  const { data } = await pub.call({ to: exchange, data: concatHex([GET_BID, encodeAbiParameters([{ type: 'uint256' }], [BigInt(orderId)])]) });
  const [maker, , , dcp, remaining, minH, maxH, feeBps, state] = decodeAbiParameters(BID_FIELDS, data);
  return {
    orderId: String(orderId),
    maker,
    dailyCapacityPriceWei: String(dcp),
    remainingBudgetWei: String(remaining),
    minCircuitH: String(minH),
    maxCircuitH: String(maxH),
    feeBps: Number(feeBps),
    state: state === BID_STATE_ACTIVE ? 'active' : `onchain-${state}`,
  };
}

/**
 * 从高到低逐张核对，每个出价人只核对他最高的一张（先按接口数据过滤掉预算不够、算力范围不含参考矿机的，这些不占核对次数）：
 * 链上读出的数据仍然满足同样的条件、出价人和接口一致，才保留（用链上数据）；不通过的出价人本小时就不算了。
 * 凑够 need 个不同出价人就停，最多核对 maxChecks 张。
 * 返回 { bids（通过核对的买单，链上数据，每个出价人一张）, checked, rejected: [{ orderId, maker, reason }] }。
 */
export async function verifiedBids(pub, json, { need = 3, maxChecks = 20, refWeight, refDailyAtomic, exchange } = {}) {
  const bids = [];
  const rejected = [];
  const seen = new Set();
  let checked = 0;
  for (const c of bidCandidates(json, { refWeight, refDailyAtomic })) {
    if (bids.length >= need || checked >= maxChecks) break;
    if (!c.maker || seen.has(c.maker)) continue;
    checked += 1;
    seen.add(c.maker);
    const orderId = String(c.bid.orderId ?? '');
    let b;
    try {
      b = await readBid(pub, orderId, { exchange });
    } catch (e) {
      rejected.push({ orderId, maker: c.maker, reason: (e?.shortMessage ?? e?.message ?? String(e)).split('\n')[0].slice(0, 160) });
      continue;
    }
    if (b.maker.toLowerCase() !== c.maker) {
      rejected.push({ orderId, maker: c.maker, reason: `链上出价人是 ${b.maker}` });
    } else if (!bidCandidates({ bids: [b] }, { refWeight, refDailyAtomic }).length) {
      rejected.push({ orderId, maker: c.maker, reason: `链上状态 ${b.state}、价格 ${b.dailyCapacityPriceWei}、剩余预算 ${b.remainingBudgetWei} 不满足条件` });
    } else {
      bids.push(b);
    }
  }
  return { bids, checked, rejected };
}
