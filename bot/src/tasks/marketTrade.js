// 主板多来源自动买卖矿机（规则 6.26 / 6.29，v2.0-rc8 起的 MarketTrader + MachineLister；rc5 的 FirstoTrader 见 firstoTrade.js）：
// - 买：两种局在收购期（isPurchasing）时，把 Firsto、TapeOut 官方矿机市场、Seaport（tapeout.market）的卖单统一比价，
//   按链上 PoD 的计价算力算"每单位算力含费价"，从低到高递给 MarketTrader；单价不超过 收购价 ÷ (1 + 兑换成本)，不超预算和名额。
// - 卖给买单：月局结算中、标准局终局卖矿中，每台没卖的矿机按卖矿合约的整台要价（quote），找净到手够还兑换的最高 Firsto 统一买单。
// - 挂单：同样这些矿机，交给 MachineLister 寄售并同时挂到官方市场和 Seaport（list）；之后定期按最新公式价改价（reprice，
//   合约只在相差 ≥ 0.5% 等情况下才改，否则模拟失败、不发交易）。
// 价格和资格由合约检查，机器人挑错了只会模拟失败、不发交易。公式价成交照常开着（6.22 F-3 a）。
// 数据：主网读 Firsto 和 tapeout.market 的公开接口（对方有频率和并发限制，串行请求、每 5 分钟最多一轮）；
// 测试网读部署时生成的模拟市场文件（cfg.firstoAsksFile、cfg.tapeFeedFile、cfg.tapeListingsFile）。
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { encodeFunctionData, parseAbi, parseEventLogs } from 'viem';
import { ABI } from '../abi.js';
import { ROOT } from '../config.js';
import { ASKS_URL, FIRSTO_ASKS_PUBLISH_URL, FIRSTO_UA, bestBidFor, firstoAskStatusUrl, parseAsks, parseSignedAsks, signedAskEnvelope } from '../firsto.js';
import { SUBSIDY_MIN_WEI, TAPEMARKET_FEED_URL, bemRoom, firstoCandidates, firstoSignedCandidates, floorTarget, isVaultListing, minerView, offerFor, parseTapeMarketFeed, pickMachines, seaportOrder, subsidyHold, tapemarketListingBody, tapemarketListingUrl } from '../markets.js';
import { firstoQuote } from '../market.js';
import { simulateCandidate } from '../askcheck.js';
import { quoteSwapCost } from '../swapcost.js';
import { failed, getJson, loadBids, markFailed } from './firstoTrade.js';
import { timeDivisor } from '../timing.js';
import * as log from '../log.js';

const E18 = 10n ** 18n;
const BPS = 10_000n;
const MAX_MACHINES = 100n;
const ADVANCE_MARGIN_BPS = 30n; // 卖出时多借 0.3% 的 BEM，防止要价在出块之间变动（多借的会回到主板）
const REPRICE_EVERY_SEC = 30 * 60; // 每台矿机最多 30 分钟改一次价（规则 6.29）
const POD_ABI = parseAbi(['function minerKey(address circuits, uint256 id) view returns (bytes32)', 'function getMiner(bytes32 key)']);
const OWNER_OF = parseAbi(['function ownerOf(uint256 id) view returns (address)']);
// 规则 6.29：报价合约的"保持排序第一"目标价（rc9 起才有；rc8 上模拟会失败，静默跳过）
const FLOOR_ABI = parseAbi(['function postFloor(uint256 price)', 'function floorPrice() view returns (uint256)', 'function floorAt() view returns (uint256)']);
const FLOOR_MIN_CHANGE_BPS = 10n; // 目标价变动不到 0.1% 就不重报
const FLOOR_REFRESH_SEC = 3_600; // 至少每小时重报一次（合约 3 小时不更新就不用）
const pause = (ms) => new Promise((r) => setTimeout(r, ms));

const readFile = (p) => JSON.parse(readFileSync(resolve(ROOT, p), 'utf8'));

/** 所有来源的卖单 → 候选（主网读接口，测试网读模拟市场文件；读不到的来源跳过） */
async function loadCandidates(ctx) {
  const { cfg, dep } = ctx;
  const out = [];
  try {
    if (cfg.mainnet) {
      const json = await getJson(ASKS_URL);
      out.push(...firstoCandidates(parseAsks(json, { now: ctx.now })), ...firstoSignedCandidates(parseSignedAsks(json, { now: ctx.now })));
    }
    else if (dep.firstoAskExchange) {
      const file = cfg.firstoAsksFile ?? `deployments/${cfg.chainId}-firsto-asks.json`;
      if (existsSync(resolve(ROOT, file))) out.push(...firstoCandidates(parseAsks(readFile(file), { now: ctx.now, exchange: dep.firstoAskExchange, collection: dep.machines, chainId: cfg.chainId })));
    }
  } catch (e) {
    log.warn('market: Firsto asks unavailable', { reason: e.message });
  }
  try {
    if (cfg.mainnet) {
      await pause(1500); // 两家接口各自有并发限制，串行、隔开一点
      out.push(...parseTapeMarketFeed(await getJson(TAPEMARKET_FEED_URL), { now: ctx.now }));
    } else if (cfg.tapeFeedFile && existsSync(resolve(ROOT, cfg.tapeFeedFile))) {
      out.push(...parseTapeMarketFeed(readFile(cfg.tapeFeedFile), { now: ctx.now, chainId: cfg.chainId }));
    }
  } catch (e) {
    log.warn('market: tapeout.market feed unavailable', { reason: e.message });
  }
  if (cfg.mainnet) return out;
  // 测试网的模拟挂单是部署时写好的固定文件：矿机已经不在挂单人手里的（成交了或转走了）跳过，免得拿它当最低价或反复去买
  const live = [];
  for (const c of out) {
    const seller = c.venue === 'firsto' ? c.order.leaf.maker : c.seller;
    const owner = await ctx.pub.readContract({ address: c.collection, abi: OWNER_OF, functionName: 'ownerOf', args: [c.tokenId] }).catch(() => null);
    if (owner && seller && owner.toLowerCase() === String(seller).toLowerCase()) live.push(c);
  }
  return live;
}

/** 每台候选矿机的 PoD 计价算力和资格（和合约 PoDReader 同一算法） */
async function readMiners(ctx, cands) {
  const { pub, dep } = ctx;
  const miners = new Map();
  for (const c of cands) {
    if (miners.has(c.key)) continue;
    try {
      const key = await pub.readContract({ address: dep.pod, abi: POD_ABI, functionName: 'minerKey', args: [c.collection, c.tokenId] });
      const { data } = await pub.call({ to: dep.pod, data: encodeFunctionData({ abi: POD_ABI, functionName: 'getMiner', args: [key] }) });
      miners.set(c.key, minerView(data, c));
    } catch {
      miners.set(c.key, { ok: false });
    }
  }
  return miners;
}

/** Seaport 卖单的完整订单：主网按 orderHash 问 tapeout.market，测试网查模拟市场文件 */
async function seaportOrderFor(ctx, orderHash) {
  if (ctx.cfg.mainnet) return seaportOrder(await getJson(tapemarketListingUrl(orderHash)));
  const all = ctx.cfg.tapeListingsFile ? readFile(ctx.cfg.tapeListingsFile) : {};
  return seaportOrder(all[orderHash] ?? all[String(orderHash).toLowerCase()]);
}

/**
 * 主网：把挂单库刚在 Seaport 上挂好的单提交给 tapeout.market，让它在网站上显示（cfg.tapemarketSubmit 打开时才提交）。
 * 提交失败不影响链上挂单（单子仍有效，官方市场那边照常），只记日志。
 */
async function submitSeaportListing(ctx, receipt, m) {
  if (!ctx.cfg.mainnet || !ctx.cfg.tapemarketSubmit || !receipt) return;
  const L = ABI.machineLister;
  for (const e of parseEventLogs({ abi: L, logs: receipt.logs, eventName: 'SeaportListed' })) {
    try {
      const feeRecipient = await ctx.pub.readContract({ address: ctx.dep.machineLister, abi: L, functionName: 'SEAPORT_FEE_RECIPIENT' });
      const body = tapemarketListingBody({ vault: e.args.vault, collection: m.collection, tokenId: m.circuitId, net: e.args.net, fee: e.args.fee, feeRecipient, salt: e.args.salt, startTime: e.args.startTime, endTime: e.args.endTime });
      const res = await fetch('https://api.tapeout.market/api/v1/listings', { method: 'POST', signal: AbortSignal.timeout(15_000), headers: { 'content-type': 'application/json', accept: 'application/json', 'user-agent': 'TapeSurge-operator-bot/1 (+https://tapesurge.com)' }, body: JSON.stringify(body) });
      if (!res.ok) throw new Error(`HTTP ${res.status} ${(await res.text()).slice(0, 200)}`);
      log.info('tapeout.market listing submitted', { vault: e.args.vault, tokenId: String(m.circuitId) });
    } catch (err) {
      log.warn('tapeout.market listing submit failed', { reason: err.message });
    }
  }
}

/**
 * 规则 6.30（rc10）：挂单库在 Firsto 上挂的签名卖单要提交给 Firsto（POST /v1/circuit-asks）才会公开显示。
 * 挂单 / 改价后按 MachineLister.firstoAsk(board, index) 取当前这张单（digest = Firsto 的 askHash，0 = 没挂），
 * 提交过的 askHash 记在状态里不重复提交；之后每轮查一次收录状态，被拒（例如挂单价不高于 Firsto 最高买单）只记日志——
 * 那种情况卖出循环本来就会直接卖给那张买单。只在主网、FIRSTO_SUBMIT=1 时提交（测试网没有 Firsto 接口）。
 */
async function submitFirstoAsk(ctx, board, index) {
  const { cfg, dep, pub, state } = ctx;
  if (!cfg.mainnet || !cfg.firstoSubmit || !ABI.machineLister?.some((f) => f.name === 'firstoAsk')) return;
  let ask;
  let digest;
  try {
    [ask, digest] = await pub.readContract({ address: dep.machineLister, abi: ABI.machineLister, functionName: 'firstoAsk', args: [board, BigInt(index)] });
  } catch {
    return;
  }
  if (!digest || /^0x0{64}$/i.test(digest)) return;
  const sent = (state.data.firstoSubmitted ??= {});
  if (sent[digest]) return;
  try {
    const res = await fetch(FIRSTO_ASKS_PUBLISH_URL, { method: 'POST', signal: AbortSignal.timeout(15_000), headers: { ...FIRSTO_UA, 'content-type': 'application/json' }, body: JSON.stringify(signedAskEnvelope(ask, { chainId: cfg.chainId, verifyingContract: dep.firstoSignedAsk ?? undefined })) });
    const text = await res.text();
    if (!res.ok) throw new Error(`HTTP ${res.status} ${text.slice(0, 200)}`);
    sent[digest] = { at: ctx.now, board, index: Number(index), status: 'submitted' };
    log.info('Firsto ask submitted', { digest, board, index: Number(index) });
  } catch (e) {
    log.warn('Firsto ask submit failed', { digest, reason: e.message });
  }
}

/** 查已提交的 Firsto 签名卖单收录状态（accepted / pending_approval / open / 被拒）；一轮最多查 3 张，对方有频率限制 */
async function checkFirstoAsks(ctx) {
  const { cfg, state } = ctx;
  if (!cfg.mainnet || !cfg.firstoSubmit) return;
  if (!state.due('firstoStatus', 3_600)) return; // 一小时最多查一轮（Firsto 约定的读取频率）
  const sent = state.data.firstoSubmitted ?? {};
  let n = 0;
  for (const [digest, v] of Object.entries(sent)) {
    if (v.status === 'open' || v.final || n >= 3) continue;
    n += 1;
    try {
      const j = await getJson(firstoAskStatusUrl(digest));
      const st = j?.status ?? j?.state ?? 'unknown';
      if (st !== v.status) log.info('Firsto ask status', { digest, status: st });
      v.status = st;
      if (!['accepted', 'pending_approval', 'open', 'unknown'].includes(st)) v.final = true;
    } catch (e) {
      log.warn('Firsto ask status unavailable', { digest, reason: e.message });
    }
    if (ctx.now - v.at > 31 * 86_400) delete sent[digest];
  }
}

/** 月局在首批回馈名单里的名次（rewardBoard(1..5)，两种局合计按开局先后）：地址小写 → 名次 */
async function rewardRanks(ctx) {
  const { pub, dep } = ctx;
  const ranks = new Map();
  for (let i = 1n; i <= 5n; i++) {
    const a = await pub.readContract({ address: dep.hub, abi: ABI.hub, functionName: 'rewardBoard', args: [i] }).catch(() => null);
    if (a && !/^0x0{40}$/i.test(a)) ranks.set(a.toLowerCase(), i);
  }
  return ranks;
}

/**
 * 月局等首批回馈（规则见 markets.js 的 subsidyHold）：这块月局的回馈桶里还有钱时，买矿机之前先领一次
 * （合约限制每个桶每小时一次、每次最多 0.5 BNB；没到时间模拟失败，静默跳过），再读领完后的桶余额。
 * 不在回馈名单里的局返回 null（照常买满）。
 */
async function subsidyState(ctx, b, ranks) {
  const { pub, dep } = ctx;
  const rank = b.kind === 'month' && dep.splitter && ABI.splitter ? ranks.get(b.address.toLowerCase()) : null;
  if (!rank) return null;
  const S = ABI.splitter;
  const bucket = () => pub.readContract({ address: dep.splitter, abi: S, functionName: 'rewardBucket', args: [rank] });
  if ((await bucket()) >= SUBSIDY_MIN_WEI) {
    await ctx.sender.send(`splitter claimReward(${rank}) before buying → month ${b.address}`, dep.splitter, S, 'claimReward', [rank], { quiet: true, private: true }); // 经兑换：走防夹子节点
  }
  const [startedAt, prepEnd, bucketWei] = await Promise.all([
    pub.readContract({ address: b.address, abi: b.abi, functionName: 'startedAt' }),
    pub.readContract({ address: b.address, abi: b.abi, functionName: 'prepEnd' }),
    bucket(),
  ]);
  return { rank, startedAt, prepEnd, bucketWei };
}

export async function marketTrade(ctx, boards) {
  const { cfg, dep, pub, state } = ctx;
  if (!dep.marketTrader || !ABI.marketTrader || !dep.oracle) return;
  if (!state.due('market', ctx.every(cfg.firstoEverySec))) return;
  const T = ABI.marketTrader;
  const buying = [];
  const selling = [];
  for (const { kind, address } of boards) {
    const abi = kind === 'std' ? ABI.std : ABI.month;
    const st = Number(await pub.readContract({ address, abi, functionName: 'state' }));
    if (await pub.readContract({ address, abi, functionName: 'isPurchasing' }).catch(() => false)) buying.push({ kind, address, abi });
    else if ((kind === 'month' && st === 6) || (kind === 'std' && st === 4)) selling.push({ kind, address, abi, sales: kind === 'std' ? dep.stdSales : dep.monthSales, salesAbi: kind === 'std' ? ABI.stdSales : ABI.monthSales });
  }
  if (!buying.length && !selling.length) return;
  // BEM 和 BNB 的换算统一用链上 30 分钟 TWAP：1 BNB 能换多少 BEM（最小单位）
  const bemPerBnb = await pub.readContract({ address: dep.oracle, abi: ABI.oracle, functionName: 'quoteBemOut', args: [E18] });
  if (bemPerBnb <= 0n) return;
  const toBnb = (bem) => (bem * E18) / bemPerBnb;
  // 每小时换 BEM 的上限（见 markets.js 的 bemRoom）：买矿机卖出的 BEM 和卖矿机买回的 BEM 合在一起算
  let room = bemRoom(state.data.bemFlow, ctx.now, cfg.bemHourlyCap);
  let capLogged = false;
  const capReached = (need) => {
    if (room.allows(need)) return false;
    if (!capLogged) log.info('market: hourly BEM cap reached, wait', { usedBem: String(room.used), needBem: String(need), capBem: String(cfg.bemHourlyCap) });
    capLogged = true;
    return true;
  };
  const recordBem = (bem) => {
    state.data.bemFlow = [...room.flow, { at: ctx.now, bem: String(bem) }];
    room = bemRoom(state.data.bemFlow, ctx.now, cfg.bemHourlyCap);
  };
  const margin = cfg.swapTradeMarginBps;
  const withMargin = (x) => (x * (BPS + margin)) / BPS;
  let done = 0;

  // 所有平台的卖单：买入用来挑单，卖出用来算"保持排序第一"的目标价（规则 6.29）
  const all = await loadCandidates(ctx);
  const miners = all.length ? await readMiners(ctx, all) : new Map();
  const okCache = new Map();
  for (const c of all) {
    if (okCache.has(c.collection.toLowerCase())) continue;
    okCache.set(c.collection.toLowerCase(), await pub.readContract({ address: dep.machineRules, abi: ABI.machineRules, functionName: 'isMachineCollection', args: [c.collection] }).catch(() => false));
  }
  const okCollection = (a) => okCache.get(String(a).toLowerCase()) === true;
  const minAge = Math.floor((7 * 86_400) / Number(dep.timeDivisor ?? 1));
  // 我们自己的挂单库挂出去的单（主板寄售的矿机）：买入时不买（一块局买另一块局的矿机只会白付手续费和兑换费，规则决定 6.37），
  // "保持排序第一"时也不和自己比
  const own = new Map();
  if (dep.machineLister && ABI.machineLister) {
    for (const c of all) {
      if (!c.seller || own.has(c.seller.toLowerCase())) continue;
      const l = await pub.readContract({ address: dep.machineLister, abi: ABI.machineLister, functionName: 'listings', args: [c.seller] }).catch(() => null);
      own.set(c.seller.toLowerCase(), isVaultListing(l));
    }
  }
  const ownVault = (c) => own.get(String(c.seller ?? '').toLowerCase()) === true;

  // ---------- 买 ----------
  if (buying.length) {
    const bought = new Set();
    // MarketTrader 的兑换保护：兑换花的 BEM 不超过 TWAP × (1 + SLIPPAGE_BPS)，超过的单递上去也会回滚，先在链下筛掉
    const slip = await pub.readContract({ address: dep.marketTrader, abi: T, functionName: 'SLIPPAGE_BPS' }).catch(() => 200n);
    // 月局等首批回馈要用到的：回馈名次、最小算力和台数上限（模板参数）、测试网时间倍率
    const anyMonth = buying.some((b) => b.kind === 'month');
    const ranks = anyMonth ? await rewardRanks(ctx) : new Map();
    const mcfg = anyMonth && dep.monthFactory ? await pub.readContract({ address: dep.monthFactory, abi: ABI.monthFactory, functionName: 'boardConfig' }).catch(() => null) : null;
    const minWeight = mcfg?.minMachineWeight ?? 10n;
    const maxMachines = mcfg?.maxMachines ?? MAX_MACHINES;
    const divisor = timeDivisor(dep, cfg.chainId);
    for (const b of buying) {
      const sub = await subsidyState(ctx, b, ranks);
      // 挑单按预算预先挑一批；挑中的单失败（兑换冲击太大、已被买走等）时，同一轮里把它排除、用剩下的预算重新挑，
      // 免得几张注定失败的大单占住整轮的预算（2026-10-26 主网分叉演练：两台 149 算力的单每轮都被兑换保护拦下，别的单一张没买）
      const tried = new Set();
      for (let pass = 0; pass < 4 && done < cfg.firstoMaxPerTick; pass++) {
        const [price, budget, count] = await Promise.all(['buyPrice', 'budget', 'machineCount'].map((fn) => pub.readContract({ address: b.address, abi: b.abi, functionName: fn })));
        let spendable = budget;
        let slots = MAX_MACHINES - count;
        if (sub && price > 0n) {
          const h = subsidyHold({ now: ctx.now, startedAt: sub.startedAt, prepEnd: sub.prepEnd, bucketWei: sub.bucketWei, price, minWeight, count, maxMachines, divisor });
          if (h.hold) {
            spendable = budget > h.reserveBem ? budget - h.reserveBem : 0n;
            slots = h.slotsLeft;
            if (pass === 0) log.info('market buy: holding back one machine for the subsidy', { board: b.address, rank: Number(sub.rank), bucketBnb: Number(sub.bucketWei) / 1e18, reserveBem: String(h.reserveBem) });
          }
        }
        if (price <= 0n || spendable <= 0n) break;
        const cands = all.filter((c) => !bought.has(c.key) && !tried.has(c.key) && !ownVault(c) && !failed(ctx, `buy:${c.venue}:${c.key}`));
        if (!cands.length) break;
        // 先按最便宜那张的兑换成本粗挑，递单前再按每张自己的金额核一遍（大单冲击更大）
        const q0 = await quoteSwapCost(ctx, 'bnbOut', cands.reduce((m, c) => (c.costWei < m ? c.costWei : m), cands[0].costWei));
        const s = q0.quoted ? q0.rawBps + margin : q0.rawBps;
        const div = BPS + (s > 0n ? s : 0n);
        const maxWeiPerWeight = (toBnb(price) * BPS) / div;
        const picks = pickMachines(cands, { miners, okCollection, now: ctx.now, minAge, maxWeiPerWeight, budgetWei: (toBnb(spendable) * BPS) / div, slots: Number(slots) });
        if (!picks.length) {
          if (pass === 0) log.info('market buy: no listing within the limit', { board: b.address, candidates: cands.length, maxWeiPerWeight: String(maxWeiPerWeight), swapBps: String(s) });
          break;
        }
        let failedOne = false;
        let capHit = false;
        for (const c of picks) {
          if (done >= cfg.firstoMaxPerTick) break;
          tried.add(c.key);
          const q = await quoteSwapCost(ctx, 'bnbOut', c.costWei);
          const needBem = q.quoted ? withMargin(q.amountIn) : (c.costWei * bemPerBnb * div) / E18 / BPS;
          if (capReached(needBem)) {
            capHit = true;
            break;
          }
          if (q.quoted && (withMargin(q.amountIn) > c.weight * price || q.rawBps + margin > slip)) {
            // 这一单兑换冲击太大（超过收购上限或兑换保护），冷却后再看
            log.info('market buy: swap cost too high, skip', { board: b.address, venue: c.venue, tokenId: String(c.tokenId), bemIn: String(withMargin(q.amountIn)), limitBem: String(c.weight * price), swapBps: String(q.rawBps) });
            markFailed(ctx, `buy:${c.venue}:${c.key}`);
            failedOne = true;
            continue;
          }
          let fn;
          let args;
          try {
            if (c.venue === 'firsto') [fn, args] = ['buyFromAsk', [b.address, c.order]];
            else if (c.venue === 'firstoSigned') {
              if (!T.some((x) => x.name === 'buyFromSignedAsk')) continue; // audit.5 及以前的部署没有这个入口
              [fn, args] = ['buyFromSignedAsk', [b.address, c.order.ask, c.order.signature]];
            }
            else if (c.venue === 'official') [fn, args] = ['buyFromOfficial', [b.address, c.listingId]];
            else [fn, args] = ['buyFromSeaport', [b.address, await seaportOrderFor(ctx, c.orderHash)]];
          } catch (e) {
            log.warn('market: order unavailable', { venue: c.venue, key: c.key, reason: e.message });
            markFailed(ctx, `buy:${c.venue}:${c.key}`);
            failedOne = true;
            continue;
          }
          const r = await ctx.sender.send(`market buy ${c.venue} ${c.collection.slice(0, 8)}#${c.tokenId} (w${c.weight}) → ${b.kind} ${b.address}`, dep.marketTrader, T, fn, args, { private: true }); // 经兑换：走防夹子节点
          if (r.ok) {
            done += 1;
            bought.add(c.key);
            recordBem(needBem);
          } else if (!r.dryRun) {
            markFailed(ctx, `buy:${c.venue}:${c.key}`);
            failedOne = true;
          }
        }
        if (capHit || !failedOne) break; // 到了每小时上限，或者挑中的都处理完了
      }
    }
  }

  if (!selling.length) {
    if (done) ctx.summary.market = done;
    return;
  }

  // ---------- 卖给 Firsto 统一买单 / Seaport 出价（挑净到手最多、又够还兑换的） ----------
  // Seaport 出价：主网 tapeout.market 现在没有矿机出价，暂时只有测试网的模拟出价文件
  let offers = [];
  if (!cfg.mainnet && cfg.seaportOffersFile && existsSync(resolve(ROOT, cfg.seaportOffersFile))) offers = readFile(cfg.seaportOffersFile).offers ?? [];
  const used = (state.data.usedOffers ??= {});
  const wbnb = dep.wbnb ?? '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c';
  let bids = [];
  try {
    bids = await loadBids(ctx);
  } catch (e) {
    log.warn('market: Firsto bids unavailable', { reason: e.message });
  }
  let perHourWeight = null;
  if (cfg.mainnet && bids.length) {
    try {
      perHourWeight = firstoQuote(await getJson(ASKS_URL)).perHourWeight;
    } catch (e) {
      log.warn('market: output rate unavailable', { reason: e.message });
      bids = [];
    }
  }
  const unsold = [];
  for (const b of selling) {
    const n = Number(await pub.readContract({ address: b.address, abi: b.abi, functionName: 'machineCount' }));
    for (let i = 0; i < n; i++) {
      const m = await pub.readContract({ address: b.address, abi: b.abi, functionName: 'machine', args: [BigInt(i)] });
      if (!m.sold) unsold.push({ b, i, m });
    }
  }
  for (const { b, i, m } of unsold) {
    if (done >= cfg.firstoMaxPerTick || (!bids.length && !offers.length)) break;
    if (failed(ctx, `sell:${b.address}:${i}`)) continue;
    const bem = await pub.readContract({ address: b.sales, abi: b.salesAbi, functionName: 'quote', args: [b.address, BigInt(i)] }).catch(() => 0n);
    if (!bem) continue; // 现在不能卖（报价过期等）
    const advance = (bem * (BPS + ADVANCE_MARGIN_BPS)) / BPS;
    const q = await quoteSwapCost(ctx, 'bemOut', advance);
    const owed = q.quoted ? withMargin(q.amountIn) : (toBnb(advance) * (BPS + q.rawBps)) / BPS;
    let bid = null;
    if (!bids.length) {
      // 没有 Firsto 买单，只看 Seaport 出价
    } else if (cfg.mainnet) bid = bestBidFor(bids, { weight: BigInt(m.weight), dailyAtomic: (BigInt(m.weight) * perHourWeight) / E18, minNetWei: owed });
    else {
      for (const x of bids) {
        const gross = await pub.readContract({ address: dep.firstoBidExchange, abi: ABI.mockFirstoBids, functionName: 'grossFor', args: [x.orderId, m.collection, m.circuitId] }).catch(() => 0n);
        const net = (gross * (BPS - x.feeBps)) / BPS;
        if (gross > 0n && gross <= x.remainingBudgetWei && net >= owed) {
          bid = { ...x, gross, net };
          break;
        }
      }
    }
    let offer = null;
    for (const o of offers) {
      if (used[o.orderHash]) continue;
      const x = offerFor(o, { collection: m.collection, tokenId: m.circuitId, wbnb, now: ctx.now });
      if (x && x.net >= owed && (!offer || x.net > offer.net)) offer = x;
    }
    if (!bid && !offer) continue;
    if (capReached(advance)) break; // 卖矿机要用 BNB 买回 BEM，也算进每小时上限
    let r;
    if (offer && (!bid || offer.net > bid.net)) {
      r = await ctx.sender.send(`market sell ${b.kind} ${b.address} #${i} → Seaport offer ${String(offer.orderHash).slice(0, 10)}`, dep.marketTrader, T, 'sellToOffer', [b.address, BigInt(i), offer.order, offer.cr, advance], { private: true });
      if (r.ok) used[offer.orderHash] = ctx.now;
    } else {
      const order = { orderId: bid.orderId, dailyCapacityPriceWei: bid.dailyCapacityPriceWei, feeBps: Number(bid.feeBps), minNetProceedsWei: owed };
      r = await ctx.sender.send(`market sell ${b.kind} ${b.address} #${i} → Firsto bid ${bid.orderId}`, dep.marketTrader, T, 'sellToBid', [b.address, BigInt(i), order, advance], { private: true });
    }
    if (r.ok) {
      done += 1;
      m.sold = true;
      recordBem(advance);
      // 同一轮里接着卖下一台时，这张买单的剩余预算已经少了（不然会拿旧余额去试，白白标记失败）
      if (!(offer && (!bid || offer.net > bid.net)) && bid?.gross) {
        const orig = bids.find((x) => x.orderId === bid.orderId); // bid 是拷贝，要改原来那张
        if (orig) orig.remainingBudgetWei -= bid.gross;
      }
    } else if (!r.dryRun) markFailed(ctx, `sell:${b.address}:${i}`);
  }

  // ---------- 规则 6.29：报"保持排序第一"的目标价 ----------
  if (dep.priceFeed && dep.machineLister && ABI.machineLister && unsold.some((u) => !u.m.sold)) {
    // 主网：最低那张先在链上核对真能买到，买不到就换下一张（最多 5 次）；测试网的模拟挂单已经按 ownerOf 过滤过
    const skip = new Set();
    let t = null;
    for (let i = 0; i < 5; i++) {
      t = floorTarget(all.filter((c) => !skip.has(c.key)), { miners, okCollection, ownVault, now: ctx.now, minAge, bemPerBnb });
      if (!t || !cfg.mainnet) break;
      const v = await simulateCandidate(pub, t.best, { officialMarket: dep.officialMarket });
      if (v.ok) break;
      log.warn('market: lowest listing failed the on-chain check, trying the next one', { venue: t.best.venue, key: t.best.key, reason: v.reason });
      skip.add(t.best.key);
      t = null;
    }
    if (t) {
      const [last, at] = await Promise.all(['floorPrice', 'floorAt'].map((fn) => pub.readContract({ address: dep.priceFeed, abi: FLOOR_ABI, functionName: fn }).catch(() => 0n)));
      const diff = last > t.floorBem ? last - t.floorBem : t.floorBem - last;
      if (last === 0n || diff * BPS >= last * FLOOR_MIN_CHANGE_BPS || BigInt(ctx.now) >= at + BigInt(FLOOR_REFRESH_SEC)) {
        const r = await ctx.sender.send(`price feed floor ${t.floorBem} (best ${t.best.venue} ${t.best.collection.slice(0, 8)}#${t.best.tokenId})`, dep.priceFeed, FLOOR_ABI, 'postFloor', [t.floorBem], { quiet: true });
        if (r.ok) ctx.summary.floor = String(t.floorBem);
      }
    }
  }

  // ---------- 挂到官方市场和 Seaport，定期改价 ----------
  if (dep.machineLister && ABI.machineLister) {
    const L = ABI.machineLister;
    for (const { b, i, m } of unsold) {
      if (m.sold) continue;
      const vault = await pub.readContract({ address: dep.machineLister, abi: L, functionName: 'vaultOf', args: [b.address, BigInt(i)] }).catch(() => null);
      const owner = vault ? await pub.readContract({ address: m.collection, abi: OWNER_OF, functionName: 'ownerOf', args: [m.circuitId] }).catch(() => null) : null;
      const consigned = vault && owner && owner.toLowerCase() === vault.toLowerCase();
      if (!consigned) {
        const r = await ctx.sender.send(`list ${b.kind} ${b.address} #${i}`, dep.machineLister, L, 'list', [b.address, BigInt(i)], { quiet: true });
        if (r.ok) {
          await submitSeaportListing(ctx, r.receipt, m);
          await submitFirstoAsk(ctx, b.address, i);
        }
        continue;
      }
      if (!state.due(`reprice:${b.address}:${i}`, ctx.every(REPRICE_EVERY_SEC))) continue;
      const r = await ctx.sender.send(`reprice ${b.kind} ${b.address} #${i}`, dep.machineLister, L, 'reprice', [b.address, BigInt(i)], { quiet: true });
      if (r.ok) {
        await submitSeaportListing(ctx, r.receipt, m); // Seaport 改价是撤旧单挂新单，订单哈希会变，要重新提交
        await submitFirstoAsk(ctx, b.address, i); // Firsto 同样换了新 nonce
      }
    }
  }
  await checkFirstoAsks(ctx);
  if (done) ctx.summary.market = done;
}
