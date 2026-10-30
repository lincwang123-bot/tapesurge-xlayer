// 主板在 Firsto 上自动买卖矿机（规则 6.22，v2.0-rc5 FirstoTrader）：机器人读 Firsto 的卖单 / 统一买单，挑出主板规则允许的单递给
// FirstoTrader，一笔交易内完成 BEM ↔ BNB 兑换和成交。价格上限 / 下限和矿机资格由合约检查，挑错了只会模拟失败、不发交易。
// - 买：两种局在收购期（isPurchasing）时，按"每单位算力含费价"从低到高吃卖单，单价不超过 收购价 ÷ (1 + 兑换成本)，不超预算和名额；
// - 卖：月局结算中、标准局终局卖矿中，每台没卖的矿机按卖矿合约的当前要价，找净到手够还兑换的最高统一买单。
// 主网的单来自 Firsto 公开接口（对方有频率限制，主网每 5 分钟最多各读一次）；测试网的 Firsto 是 mock：卖单读部署时生成的 JSON 文件，
// 买单从 mock 合约链上读。公式价成交照常开着（6.22 F-3 a），这里只是多一条路。
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { parseAbi } from 'viem';
import { ABI } from '../abi.js';
import { ROOT } from '../config.js';
import { ASKS_URL, BIDS_URL, FIRSTO_UA as UA, bestBidFor, parseAsks, parseBids, pickAsks } from '../firsto.js';
import { firstoQuote } from '../market.js';
import { quoteSwapCost } from '../swapcost.js';
import * as log from '../log.js';

const E18 = 10n ** 18n;
const BPS = 10_000n;
const MAX_MACHINES = 100n;
const FAIL_COOLDOWN_SEC = 1800; // 一张单模拟失败后 30 分钟内不再试
const OWNER_OF = parseAbi(['function ownerOf(uint256 id) view returns (address)']);
const ADVANCE_MARGIN_BPS = 30n; // 卖出时多借 0.3% 的 BEM，防止要价在出块之间变动（多借的会回到主板）

// Firsto 接口按约定每台服务器每小时读一次（Firsto 接入说明）：报价、自动买卖、查收录状态
// 都经这里读，同一个地址一小时内只真正请求一次，其余直接用缓存；失败的不缓存（调用方 5 分钟后重试）。其他网站不受这个限制。
const FIRSTO_HOST = 'https://api-tapeout.firsto.ai/';
const FIRSTO_TTL_MS = 3_600_000;
const cache = new Map();
export async function getJson(url, { fresh = false } = {}) {
  const hit = cache.get(url);
  if (!fresh && url.startsWith(FIRSTO_HOST) && hit && Date.now() - hit.at < FIRSTO_TTL_MS) return hit.json;
  const res = await fetch(url, { signal: AbortSignal.timeout(15_000), headers: UA });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const json = await res.json();
  if (url.startsWith(FIRSTO_HOST)) cache.set(url, { at: Date.now(), json });
  return json;
}

/** 卖单：主网读 Firsto 接口；测试网读部署时生成的 mock 卖单文件 */
async function loadAsks(ctx) {
  const { cfg, dep } = ctx;
  if (cfg.mainnet) return parseAsks(await getJson(ASKS_URL), { now: ctx.now });
  const file = resolve(ROOT, cfg.firstoAsksFile ?? `deployments/${cfg.chainId}-firsto-asks.json`);
  const json = JSON.parse(readFileSync(file, 'utf8'));
  const asks = parseAsks(json, { now: ctx.now, exchange: dep.firstoAskExchange, collection: dep.machines, chainId: cfg.chainId });
  // 模拟卖单是部署时写好的固定文件：矿机已经不在挂单人手里的（成交了或转走了）跳过
  const live = [];
  for (const a of asks) {
    const owner = await ctx.pub.readContract({ address: dep.machines, abi: OWNER_OF, functionName: 'ownerOf', args: [a.tokenId] }).catch(() => null);
    if (owner && owner.toLowerCase() === String(a.leaf.maker).toLowerCase()) live.push(a);
  }
  return live;
}

/** 统一买单：主网读 Firsto 接口；测试网从 mock 合约读 */
export async function loadBids(ctx) {
  if (ctx.cfg.mainnet) return parseBids(await getJson(BIDS_URL));
  const { pub, dep } = ctx;
  const n = Number(await pub.readContract({ address: dep.firstoBidExchange, abi: ABI.mockFirstoBids, functionName: 'bidCount' }));
  const fee = await pub.readContract({ address: dep.firstoBidExchange, abi: ABI.mockFirstoBids, functionName: 'FEE_BPS' });
  const raw = [];
  for (let i = 0; i < n; i++) {
    const b = await pub.readContract({ address: dep.firstoBidExchange, abi: ABI.mockFirstoBids, functionName: 'bid', args: [BigInt(i)] });
    raw.push({ orderId: i, state: b.active ? 'active' : 'closed', dailyCapacityPriceWei: b.dailyCapacityPriceWei, remainingBudgetWei: b.remainingBudgetWei, minCircuitH: b.minCircuitH, maxCircuitH: b.maxCircuitH, feeBps: fee });
  }
  return parseBids({ bids: raw });
}

export const failed = (ctx, key) => (ctx.state.data.firstoFailed ??= {})[key] > ctx.now;
export const markFailed = (ctx, key) => ((ctx.state.data.firstoFailed ??= {})[key] = ctx.now + FAIL_COOLDOWN_SEC);

export async function firstoTrade(ctx, boards) {
  const { cfg, dep, pub, state } = ctx;
  if (!dep.firstoTrader || !ABI.firstoTrader || !dep.oracle) return;
  if (!state.due('firsto', ctx.every(cfg.firstoEverySec))) return;
  const buying = [];
  const selling = [];
  for (const { kind, address } of boards) {
    const abi = kind === 'std' ? ABI.std : ABI.month;
    const st = Number(await pub.readContract({ address, abi, functionName: 'state' }));
    if (await pub.readContract({ address, abi, functionName: 'isPurchasing' }).catch(() => false)) buying.push({ kind, address, abi });
    else if ((kind === 'month' && st === 6) || (kind === 'std' && st === 4)) selling.push({ kind, address, abi });
  }
  if (!buying.length && !selling.length) return;
  // BEM 和 BNB 的换算统一用链上 30 分钟 TWAP：1 BNB 能换多少 BEM（最小单位）
  const bemPerBnb = await pub.readContract({ address: dep.oracle, abi: ABI.oracle, functionName: 'quoteBemOut', args: [E18] });
  if (bemPerBnb <= 0n) return;
  const toBnb = (bem) => (bem * E18) / bemPerBnb;
  const margin = cfg.swapTradeMarginBps;
  // 兑换成本：主网按单子金额用 QuoterV2 实时算（src/swapcost.js），测试网 / 读不到时用 cfg.swapCostBps
  const withMargin = (x) => (x * (BPS + margin)) / BPS;
  let done = 0;

  if (buying.length) {
    let asks = [];
    try {
      asks = await loadAsks(ctx);
    } catch (e) {
      log.warn('firsto: asks unavailable', { reason: e.message });
    }
    for (const b of buying) {
      if (done >= cfg.firstoMaxPerTick) break;
      const [price, budget, count] = await Promise.all(['buyPrice', 'budget', 'machineCount'].map((fn) => pub.readContract({ address: b.address, abi: b.abi, functionName: fn })));
      if (price <= 0n || budget <= 0n) continue;
      const candidates = asks.filter((a) => !failed(ctx, `ask:${a.tokenId}`));
      if (!candidates.length) continue;
      // 主板要求 实际花的 BEM ≤ 权重 × 收购价；实际花 ≈ 含费 BNB 价 ×（1 + 兑换成本）换成 BEM。
      // 先按最便宜那张的兑换成本粗挑，递单前再按每张自己的金额精确核一遍（大单冲击更大）
      const q0 = await quoteSwapCost(ctx, 'bnbOut', candidates[0].buyerCostWei);
      const s = q0.quoted ? q0.rawBps + margin : q0.rawBps;
      const div = BPS + (s > 0n ? s : 0n);
      const maxWeiPerWeight = (toBnb(price) * BPS) / div;
      const budgetWei = (toBnb(budget) * BPS) / div;
      for (const a of pickAsks(candidates, { maxWeiPerWeight, budgetWei, slots: Number(MAX_MACHINES - count) })) {
        if (done >= cfg.firstoMaxPerTick) break;
        const q = await quoteSwapCost(ctx, 'bnbOut', a.buyerCostWei);
        if (q.quoted && withMargin(q.amountIn) > a.weight * price) continue; // 这一单的兑换冲击太大，收购价还够不着，下一轮再看
        const order = { header: a.header, leaf: a.leaf, merkleProof: a.proof, signature: a.signature };
        const r = await ctx.sender.send(`firsto buy #${a.tokenId} (w${a.weight}) → ${b.kind} ${b.address}`, dep.firstoTrader, ABI.firstoTrader, 'buyFromAsk', [b.address, order], { private: true });
        if (r.ok) {
          done += 1;
          asks = asks.filter((x) => x.tokenId !== a.tokenId);
        } else if (!r.dryRun) markFailed(ctx, `ask:${a.tokenId}`);
      }
    }
  }

  if (selling.length && done < cfg.firstoMaxPerTick) {
    let bids;
    try {
      bids = await loadBids(ctx);
    } catch (e) {
      log.warn('firsto: bids unavailable', { reason: e.message });
      return;
    }
    if (!bids.length) return;
    // 每单位算力的预计日产出：主网用 Firsto 的数据（和报价同源），测试网直接问 mock 买单合约的毛价
    let perHourWeight = null;
    if (cfg.mainnet) {
      try {
        perHourWeight = firstoQuote(await getJson(ASKS_URL)).perHourWeight;
      } catch (e) {
        log.warn('firsto: output rate unavailable', { reason: e.message });
        return;
      }
    }
    for (const b of selling) {
      const n = Number(await pub.readContract({ address: b.address, abi: b.abi, functionName: 'machineCount' }));
      for (let i = 0; i < n && done < cfg.firstoMaxPerTick; i++) {
        const m = await pub.readContract({ address: b.address, abi: b.abi, functionName: 'machine', args: [BigInt(i)] });
        if (m.sold || failed(ctx, `sell:${b.address}:${i}`)) continue;
        let bem;
        if (b.kind === 'month') bem = await pub.readContract({ address: dep.monthSales, abi: ABI.monthSales, functionName: 'askPrice', args: [b.address, BigInt(i)] });
        else {
          const [perWeight] = await pub.readContract({ address: dep.stdSales, abi: ABI.stdSales, functionName: 'askPrice', args: [b.address, BigInt(i)] });
          bem = perWeight * BigInt(m.weight);
        }
        if (!bem || bem <= 0n) continue; // 暂停出售（报价过期等）
        const advance = (bem * (BPS + ADVANCE_MARGIN_BPS)) / BPS;
        // 闪电借 BEM 要还的 BNB：主网按这一单用 QuoterV2 精确报（再留余量），否则 ≈ 借的 BEM 换成 BNB ×（1 + 兑换成本）；买单的净到手要够还
        const q = await quoteSwapCost(ctx, 'bemOut', advance);
        const owed = q.quoted ? withMargin(q.amountIn) : (toBnb(advance) * (BPS + q.rawBps)) / BPS;
        let bid;
        if (cfg.mainnet) {
          bid = bestBidFor(bids, { weight: BigInt(m.weight), dailyAtomic: (BigInt(m.weight) * perHourWeight) / E18, minNetWei: owed });
        } else {
          for (const x of bids) {
            const gross = await pub.readContract({ address: dep.firstoBidExchange, abi: ABI.mockFirstoBids, functionName: 'grossFor', args: [x.orderId, dep.machines, m.circuitId] }).catch(() => 0n);
            const net = (gross * (BPS - x.feeBps)) / BPS;
            if (gross > 0n && gross <= x.remainingBudgetWei && net >= owed) {
              bid = { ...x, gross, net };
              break;
            }
          }
        }
        if (!bid) continue;
        const order = { orderId: bid.orderId, dailyCapacityPriceWei: bid.dailyCapacityPriceWei, feeBps: Number(bid.feeBps), minNetProceedsWei: owed };
        const r = await ctx.sender.send(`firsto sell ${b.kind} ${b.address} #${i} → bid ${bid.orderId}`, dep.firstoTrader, ABI.firstoTrader, 'sellToBid', [b.address, BigInt(i), order, advance], { private: true });
        if (r.ok) done += 1;
        else if (!r.dryRun) markFailed(ctx, `sell:${b.address}:${i}`);
      }
    }
  }
  if (done) ctx.summary.firsto = done;
}
