// X Layer：RIG 矿机市场（XRigMarket）嵌进月局的买入和卖出（2026-10-29 项目方决定）。
// - 买：正在收购的月局从市场上单价不超过当前收购价的卖单里，从最便宜的往上买（sellAskToBoard，任何人可调，
//   月局按卖单实价付款，对应 BSC 规则 6.37 的 MarketTrader）。收购拍卖照常开着。
// - 卖：结算中的月局矿机按卖矿合约要价卖给出价够高的统一买单（fillBidFromBoard，买家只付要价）。
//   交接（relayAndList）先做，剩下的再配买单。RIG 要 1 天内同步过：测试网先 MockRig.claim，主网报警。
// - 打理：每 6 小时清掉失效卖单（pruneAsks）、帮过期买单的买家退款（refundBid，钱只退给买家）。
// 前期月局定价仍按 BSC 转报的行情（XMarketPriceFeed）；市场成交价只展示，不参与定价。
// 价格、资格、预算都由合约检查，机器人挑错了只会模拟失败、不发交易。
import { ABI } from '../abi.js';
import * as log from '../log.js';
import { bookFromPages, deadAsks, expiredBids, matchBids, pickAsksForBoard } from '../rigmarket.js';
import { refreshStaleRigs } from './boards.js';

const TIDY_EVERY_SEC = 6 * 3600;
const PRUNE_BATCH = 50;
const REFUND_BATCH = 20;
// 分页大小：每张卖单要调 RIG 合约好几次，一页 50 张大约 200 万 gas；买单只读存储，一页 200 张
const ASK_PAGE = 50n;
const BID_PAGE = 200n;

export async function rigMarket(ctx) {
  const { dep, state } = ctx;
  if (!ABI.rigMarket || !dep.market) return;
  if (!state.due('rig-market', ctx.every(300))) return;
  await buyForBoards(ctx);
  await sellToBids(ctx);
  if (state.due('rig-market-tidy', ctx.every(TIDY_EVERY_SEC))) await tidy(ctx);
}

/** 一页一页读完全部订单（含失效的）：{ asks, bids } */
async function readOrders(ctx) {
  const read = (functionName, args = []) => ctx.pub.readContract({ address: ctx.dep.market, abi: ABI.rigMarket, functionName, args });
  const all = async (countFn, pageFn, size) => {
    const n = await read(countFn);
    const out = [];
    for (let off = 0n; off < n; off += size) out.push(...(await read(pageFn, [off, size])));
    return out;
  };
  return { asks: await all('askCount', 'asksPage', ASK_PAGE), bids: await all('bidCount', 'bidsPage', BID_PAGE) };
}

/** 盘口：[有效卖单从低到高, 有效买单从高到低]（不用 book()，见 bookFromPages） */
async function book(ctx) {
  const { asks, bids } = await readOrders(ctx);
  return bookFromPages(asks, bids);
}

/** 正在收购的月局：从最便宜的合格卖单往上买，单价不超过当前收购价、不超预算和名额 */
async function buyForBoards(ctx) {
  if (!ctx.receivers.length) return;
  if (ctx.rigUpgraded) {
    log.warn('rig market: RIG implementation changed, not buying RIG for boards (see rig-upgrade alert)');
    return;
  }
  const { pub, dep } = ctx;
  const [asks] = await book(ctx);
  if (!asks.some((a) => a.valid && a.boardEligible)) return;
  const { maxMachines } = await pub.readContract({ address: dep.monthFactory, abi: ABI.monthFactory, functionName: 'boardConfig' });
  const taken = new Set();
  for (const { address, name } of ctx.receivers) {
    const [buyPrice, budget, count] = await pub.multicall({
      contracts: ['buyPrice', 'budget', 'machineCount'].map((functionName) => ({ address, abi: ABI.month, functionName })),
      allowFailure: false,
    });
    if (buyPrice === 0n) continue; // 报价无效：合约暂停收购
    const slots = maxMachines > count ? Number(maxMachines - count) : 0;
    for (const id of pickAsksForBoard(asks, { buyPrice, budget, slots, taken })) {
      const r = await ctx.sender.send(`${name} buy RIG ${id} from the market`, dep.market, ABI.rigMarket, 'sellAskToBoard', [id, address]);
      if (r.sent || r.dryRun) taken.add(id);
    }
  }
}

/** 结算中的月局：每台还没卖的矿机配出价最高的合格统一买单，按要价成交 */
async function sellToBids(ctx) {
  const { pub, dep } = ctx;
  const now = BigInt(ctx.now);
  for (const { address, name } of ctx.settling) {
    const [, bids] = await book(ctx); // 每块主板重读一次：上一块成交后买单余额变了
    if (!bids.length) return;
    const offersOf = () => pub.readContract({ address: dep.market, abi: ABI.rigMarket, functionName: 'boardOffers', args: [address] });
    let offers = await offersOf();
    if (!offers.length) continue;
    // 能配上买单、但同步时间超过 1 天的，先刷新同步时间再成交
    const stale = matchBids(offers, bids, now, { assumeSynced: true }).filter((m) => !m.fresh).map((m) => m.rigId);
    if (await refreshStaleRigs(ctx, name, address, stale)) offers = await offersOf();
    for (const m of matchBids(offers, bids, now).filter((x) => x.fresh)) {
      await ctx.sender.send(
        `${name} sell machine ${m.index} (RIG ${m.rigId}) to market bid ${m.bidId} for ${m.total}`,
        dep.market,
        ABI.rigMarket,
        'fillBidFromBoard',
        [m.bidId, address, m.index],
      );
    }
  }
}

/** 清掉失效卖单、帮过期买单退款（只影响盘口读取成本和买家的钱，不涉及主板资金） */
async function tidy(ctx) {
  const { dep } = ctx;
  const M = ABI.rigMarket;
  const { asks, bids } = await readOrders(ctx);
  const dead = deadAsks(asks).slice(0, PRUNE_BATCH);
  if (dead.length) await ctx.sender.send(`rig market prune ${dead.length} dead asks`, dep.market, M, 'pruneAsks', [dead], { quiet: true });
  for (const id of expiredBids(bids, BigInt(ctx.now)).slice(0, REFUND_BATCH)) {
    await ctx.sender.send(`rig market refund expired bid ${id}`, dep.market, M, 'refundBid', [id], { quiet: true });
  }
}
