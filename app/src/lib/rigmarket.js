// X Layer 的 RIG 矿机市场（XRigMarket，2026-10-29）。规则见 xlayer/contracts/README.md「RIG 矿机市场」。
// - 报价单位：每单位算力多少 BEM（最小单位），整张 = 单价 × 算力；
// - 卖单不托管：RIG 留在卖家钱包里，只授权给市场合约；买单托管 BEM，按算力范围和同步时间收 RIG；
// - 正在收购的月局可以买单价不高于收购价的卖单（任何人触发，按卖单价付款）；结算中的月局矿机按卖矿合约要价在这里卖。
import { parseAbi } from 'viem';
import MarketAbi from '../abi/xlayer/XRigMarket.json';
import RigAbi from '../abi/xlayer/MockRig.json';
import MonthBoardAbi from '../abi/MonthBoard.json';
import PriceFeedAbi from '../abi/MarketPriceFeed.json';
import { boardAddresses, eventAbi } from './protocol.js';
import { logClientOf } from './chains.js';

export { MarketAbi, RigAbi };

export const MAX_VALIDITY_DAYS = 30;
/** 成交类型（XRigMarket.KIND_*） */
export const TRADE_KIND = {
  1: ['吃卖单', 'Ask filled'],
  2: ['卖单卖给月局', 'Ask sold to a board'],
  3: ['卖给买单', 'Sold to a bid'],
  4: ['月局矿机卖给买单', 'Board RIG sold to a bid'],
  5: ['买月局矿机', 'Board RIG bought'],
};

const sourceAbi = parseAbi(['function purchaseWeight(uint256 id) view returns (uint256)']);
const erc20 = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function allowance(address owner, address spender) view returns (uint256)',
]);
const enumerableAbi = parseAbi([
  'function balanceOf(address owner) view returns (uint256)',
  'function tokenOfOwnerByIndex(address owner, uint256 index) view returns (uint256)',
]);

// 分页大小：每张卖单要调 RIG 合约好几次，一页 50 张大约 200 万 gas；买单只读存储，一页 200 张
const ASK_PAGE = 50n;
const BID_PAGE = 200n;
const cmpAsk = (a, b) => (a.price !== b.price ? (a.price < b.price ? -1 : 1) : a.rigId < b.rigId ? -1 : a.rigId > b.rigId ? 1 : 0);
const cmpBid = (a, b) => (a.price !== b.price ? (a.price > b.price ? -1 : 1) : a.bidId < b.bidId ? -1 : a.bidId > b.bidId ? 1 : 0);

/**
 * 一页一页读完全部订单（含失效的），再整理成盘口：只留有效的、按编号去重（翻页之间订单数组可能变动），
 * 卖单按单价从低到高、买单从高到低，同价按编号——和合约 book() 的顺序相同。
 * 不直接调 book()：它每次对全部订单排序、逐个调外部合约，订单多了会超出节点的调用 gas 上限（全局审计 2026-10-29 第 8 条）。
 * 返回 { asks, bids, allBids }，allBids 含失效的买单（"我的买单"要显示过期的，方便退款）。
 */
async function loadOrders(client, market) {
  const read = (functionName, args = []) => client.readContract({ address: market, abi: MarketAbi, functionName, args });
  const all = async (countFn, pageFn, size) => {
    const n = await read(countFn);
    const out = [];
    for (let off = 0n; off < n; off += size) out.push(...(await read(pageFn, [off, size])));
    return out;
  };
  const [askList, bidList] = await Promise.all([all('askCount', 'asksPage', ASK_PAGE), all('bidCount', 'bidsPage', BID_PAGE)]);
  const uniq = (xs, key) => [...new Map(xs.map((x) => [String(x[key]), x])).values()];
  const allBids = uniq(bidList, 'bidId');
  return {
    asks: uniq(askList, 'rigId').filter((a) => a.valid).sort(cmpAsk),
    bids: allBids.filter((b) => b.valid).sort(cmpBid),
    allBids,
  };
}

/** 盘口、最近成交、手续费、BSC 行情（参考价），以及当前账户的余额、授权和买单 */
export async function loadMarket(client, dep, account) {
  const m = dep.market;
  const [{ asks, bids, allBids }, trades, feeBps, feed, block] = await Promise.all([
    loadOrders(client, m),
    client.readContract({ address: m, abi: MarketAbi, functionName: 'recentTrades' }),
    client.readContract({ address: m, abi: MarketAbi, functionName: 'FEE_BPS' }),
    client
      .multicall({
        contracts: ['bid', 'ask', 'fresh', 'updatedAt'].map((functionName) => ({ address: dep.priceFeed, abi: PriceFeedAbi, functionName })),
        allowFailure: true,
      })
      .then((r) => ({ bid: r[0].result, ask: r[1].result, fresh: r[2].result, updatedAt: r[3].result })),
    client.getBlock(),
  ]);
  let me = null;
  if (account) {
    const [bem, allowance, approved] = await Promise.all([
      client.readContract({ address: dep.bem, abi: erc20, functionName: 'balanceOf', args: [account] }),
      client.readContract({ address: dep.bem, abi: erc20, functionName: 'allowance', args: [account, m] }),
      client.readContract({ address: dep.rig, abi: RigAbi, functionName: 'isApprovedForAll', args: [account, m] }),
    ]);
    const lower = account.toLowerCase();
    me = { bem, allowance, approved, bids: allBids.filter((b) => b.bidder.toLowerCase() === lower) };
  }
  return { asks, bids, trades, feeBps, feed, now: block.timestamp, me };
}

/** 最近的月局里：正在收购的（收购价、预算）和结算中在卖的矿机（卖矿合约要价） */
export async function loadBoardSide(client, dep) {
  const { addresses } = await boardAddresses(client, dep, 'month', 12);
  const fields = ['state', 'number', 'isPurchasing', 'buyPrice', 'budget'];
  const res = await client.multicall({
    contracts: addresses.flatMap((address) => fields.map((functionName) => ({ address, abi: MonthBoardAbi, functionName }))),
    allowFailure: true,
  });
  const boards = addresses.map((address, i) => {
    const r = Object.fromEntries(fields.map((f, k) => [f, res[i * fields.length + k].result]));
    return { address, ...r, state: Number(r.state ?? 0) };
  });
  const buying = boards.filter((b) => b.isPurchasing && b.buyPrice > 0n);
  const settling = boards.filter((b) => b.state === 6);
  const offerLists = await Promise.all(
    settling.map((b) => client.readContract({ address: dep.market, abi: MarketAbi, functionName: 'boardOffers', args: [b.address] }).catch(() => [])),
  );
  const offers = settling.flatMap((b, i) => offerLists[i].map((o) => ({ ...o, board: b.address, number: b.number })));
  return { buying, offers };
}

// 本地记住的 RIG 编号（领到、买到、手动添加的）：测试网的模拟 RIG 不能按持有人枚举，X Layer 节点查日志一次又只能查 100 个区块
const rigKey = (chainId, account) => `tapesurge:rigs:${chainId}:${account.toLowerCase()}`;

function readRigCache(chainId, account) {
  try {
    const v = JSON.parse(localStorage.getItem(rigKey(chainId, account)) || '[]');
    return Array.isArray(v) ? v : [];
  } catch {
    return [];
  }
}

function writeRigCache(chainId, account, ids) {
  try {
    localStorage.setItem(rigKey(chainId, account), JSON.stringify(ids));
  } catch {
    /* 隐私模式下没有 localStorage，忽略 */
  }
}

export function rememberRig(chainId, account, id) {
  const ids = readRigCache(chainId, account);
  if (!ids.includes(String(id))) writeRigCache(chainId, account, [...ids, String(id)]);
}

/** 最近多少个区块里转给本地址的 RIG 也找出来（X Layer 节点每次最多查 100 个区块，这里查 30 次） */
const RECENT_SCAN_CHUNKS = 30;

/**
 * 当前账户的 RIG：真实 RIG 是 ERC721Enumerable，直接按持有人枚举；测试网的模拟 RIG 不是，就合并本地记住的编号和最近区块里
 * 转给本地址的 Transfer 事件，再核对当前持有人。每张读出算力、同步时间、能不能卖给月局（RigMachineSource.purchaseWeight）、有没有卖单。
 */
export async function loadMyRigs(client, dep, net, chainId, account) {
  if (!account) return [];
  const found = new Set(readRigCache(chainId, account));
  try {
    const n = await client.readContract({ address: dep.rig, abi: enumerableAbi, functionName: 'balanceOf', args: [account] });
    const r = await client.multicall({
      contracts: Array.from({ length: Number(n) }, (_, i) => ({ address: dep.rig, abi: enumerableAbi, functionName: 'tokenOfOwnerByIndex', args: [account, BigInt(i)] })),
      allowFailure: false,
    });
    r.forEach((id) => found.add(String(id)));
  } catch {
    // 最近 30 段（每段 logChunk 个区块）同时查：viem 会把并发请求合成一次批量请求；查失败的段跳过
    const latest = await client.getBlockNumber();
    const start = BigInt(dep.fromBlock ?? 0);
    const event = eventAbi(RigAbi, 'Transfer');
    const ranges = [];
    for (let i = 0n, to = latest; i < BigInt(RECENT_SCAN_CHUNKS) && to >= start; i++, to -= net.logChunk) {
      const from = to - net.logChunk + 1n > start ? to - net.logChunk + 1n : start;
      ranges.push([from, to]);
    }
    const logs = logClientOf(chainId); // 不合并批量请求（X Layer 节点处理不了一批多条 eth_getLogs）
    const parts = await Promise.allSettled(
      ranges.map(([fromBlock, toBlock]) => logs.getLogs({ address: dep.rig, event, args: { to: account }, fromBlock, toBlock })),
    );
    parts.forEach((p) => p.status === 'fulfilled' && p.value.forEach((l) => found.add(String(l.args.tokenId))));
  }
  const ids = [...found].map((s) => BigInt(s));
  if (!ids.length) return [];
  const per = 4;
  const res = await client.multicall({
    contracts: ids.flatMap((id) => [
      { address: dep.rig, abi: RigAbi, functionName: 'ownerOf', args: [id] },
      { address: dep.rig, abi: RigAbi, functionName: 'rigs', args: [id] },
      { address: dep.machineSource, abi: sourceAbi, functionName: 'purchaseWeight', args: [id] },
      { address: dep.market, abi: MarketAbi, functionName: 'askValid', args: [id] },
    ]),
    allowFailure: true,
  });
  const lower = account.toLowerCase();
  const mine = ids
    .map((id, i) => {
      const [owner, rig, weight, listed] = res.slice(i * per, i * per + per).map((x) => x.result);
      return { id, owner, power: rig?.power ?? 0n, syncedAt: rig?.syncedAt ?? 0n, eligible: (weight ?? 0n) > 0n, listed: !!listed };
    })
    .filter((r) => r.owner?.toLowerCase() === lower)
    .sort((a, b) => (a.id < b.id ? -1 : 1));
  writeRigCache(chainId, account, mine.map((r) => String(r.id)));
  return mine;
}

/** 能收下这张 RIG 的最高买单（算力范围、同步时间、剩余预算；不是自己的） */
export function bestBidForRig(bids, rig, now, account) {
  const me = account?.toLowerCase();
  return bids.find(
    (b) =>
      b.valid &&
      b.bidder.toLowerCase() !== me &&
      rig.power >= b.minPower &&
      rig.power <= b.maxPower &&
      (b.maxSyncAge === 0n || BigInt(now) - BigInt(rig.syncedAt) <= b.maxSyncAge) &&
      b.price * rig.power <= b.remaining,
  );
}

/** 卖单能卖给哪块正在收购的月局：符合月局收购资格、单价不高于收购价、整张不超过剩余预算；挑收购价最高的那块 */
export function boardForAsk(buying, ask) {
  if (!ask.boardEligible) return null;
  return buying.filter((b) => ask.price <= b.buyPrice && ask.total <= b.budget).sort((a, b) => (a.buyPrice > b.buyPrice ? -1 : 1))[0] ?? null;
}

/** 有效期：按链上时间算，最长 30 天时少留 10 分钟余量 */
export const deadlineAfter = (now, days) => BigInt(now) + BigInt(days) * 86_400n - (days === MAX_VALIDITY_DAYS ? 600n : 0n);

/** 同步多久了（秒） */
export const syncAge = (now, syncedAt) => (BigInt(now) > BigInt(syncedAt) ? Number(BigInt(now) - BigInt(syncedAt)) : 0);
