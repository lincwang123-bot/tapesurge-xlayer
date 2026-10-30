// v2 月局持仓挂单簿（PositionExchange，v2.0-rc1）。规则见 v2月局规则决定-2026-10-22.md 第 6.2、6.5 节。
// - 卖单挂在链上、非托管：持仓留在卖家钱包里，成交时才转走；
// - 买单是本局通用的，托管全款，本局任何一份大小合适的持仓都可以卖给它；
// - 报价单位：unitPrice = 每 1 BEM 原始本金对应的 BEM 最小单位数；页面上显示成"本金的 X%"（= unitPrice ÷ 1e6）。
// 成交款直接到卖家钱包，没有"市场余额"要领取。
import ExchangeAbi from '../abi/PositionExchange.json';

export { ExchangeAbi };

export const STAKE_UNIT = 100_000_000n; // 1 BEM 本金
export const MAX_VALIDITY_DAYS = 30;

/** unitPrice → "本金的 X%"（保留 1 位小数的字符串） */
export const pctOf = (unitPrice) => (Number(unitPrice) / 1e6).toFixed(1);

/** 用户输入的百分比（例如 "85" 或 "92.5"）→ unitPrice；格式不对或 ≤ 0 返回 null */
export function unitFromPct(text) {
  const s = String(text ?? '').trim();
  if (!/^\d+(\.\d{1,4})?$/.test(s)) return null;
  const [i, f = ''] = s.split('.');
  const v = BigInt(i) * 1_000_000n + BigInt((f + '0000').slice(0, 4)) * 100n;
  return v > 0n ? v : null;
}

/** 和合约 quote 一致：总价 = ⌈本金 × 单价 ÷ 1e8⌉ */
export const quote = (stake, unitPrice) => (BigInt(stake) * BigInt(unitPrice) + STAKE_UNIT - 1n) / STAKE_UNIT;

/** 一块月局的盘口：有效卖单（单价从低到高）、有效买单（从高到低）、最近 20 笔成交、能不能成交 */
export async function loadBook(client, exchange, board) {
  const [[asks, bids], trades, tradable, block] = await Promise.all([
    client.readContract({ address: exchange, abi: ExchangeAbi, functionName: 'book', args: [board, 0n] }),
    client.readContract({ address: exchange, abi: ExchangeAbi, functionName: 'recentTrades', args: [board] }),
    client.readContract({ address: exchange, abi: ExchangeAbi, functionName: 'tradable', args: [board] }),
    client.getBlock(),
  ]);
  return { asks, bids, trades, tradable, now: block.timestamp };
}

/** 某个地址在本局没关闭的买单（含已经失效、等退款的） */
export async function loadMyBids(client, exchange, board, account) {
  if (!account) return [];
  const all = await client.readContract({ address: exchange, abi: ExchangeAbi, functionName: 'bidsOf', args: [board, 0n, 0n] });
  const me = account.toLowerCase();
  return all.filter((b) => b.bidder.toLowerCase() === me).sort((a, b) => (a.unitPrice > b.unitPrice ? -1 : 1));
}

/** 能接住这份持仓的最高买单（大小在范围内、剩余预算够、不是自己的） */
export function bestBidFor(bids, stake, account) {
  const me = account?.toLowerCase();
  return bids.find((b) => b.valid && b.bidder.toLowerCase() !== me && stake >= b.minStake && stake <= b.maxStake && quote(stake, b.unitPrice) <= b.remaining);
}

/** 按最优价买入：从最便宜的卖单开始，在单价上限和总额以内能买到哪些 */
export function planBuyBest(asks, account, maxUnitPrice, maxTotal) {
  const me = account?.toLowerCase();
  const picked = [];
  let spent = 0n;
  let stake = 0n;
  for (const a of asks) {
    if (!a.valid || a.maker.toLowerCase() === me || a.unitPrice > maxUnitPrice) continue;
    if (spent + a.cost > maxTotal) continue;
    picked.push(a);
    spent += a.cost;
    stake += a.stake;
  }
  return { slots: picked.map((a) => a.slot), spent, stake, count: picked.length };
}
