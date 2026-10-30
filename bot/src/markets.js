// 多来源买矿机（规则 6.26，v2.0-rc8 MarketTrader）：把 Firsto、TapeOut 官方矿机市场、Seaport（tapeout.market 聚合）的卖单
// 统一成一种候选，按链上 PoD 的计价算力算"每单位算力的含费价"，挑最便宜的。只整理和挑选，不发交易；价格和资格最终由合约检查。
// 计价算力和合约 PoDReader 同一算法：min(基础算力 [3] × 处理器倍数 [7], 已验证池权重 [19])，不含最优加成；
// 合格 = 状态 [9] = 1、[19] > 0、运行满 minAge（[8] 开挖时间）、合集是工厂处理器（MachineRules.isMachineCollection）。

import { parseAsks } from './firsto.js';

export const TAPEMARKET_FEED_URL =
  'https://api.tapeout.market/api/v1/circuit-market/feed?processor=all&source=all&pool=all&sort=daily_capacity_price_asc&hideOptimal=true&tab=all&nandBand=all&purchasableOnly=true&limit=30';
export const tapemarketListingUrl = (orderHash) => `https://api.tapeout.market/api/v1/listings/${orderHash}`;

const lower = (a) => String(a ?? '').toLowerCase();
const big = (v) => BigInt(v ?? 0);
export const machineKey = (collection, tokenId) => `${lower(collection)}:${BigInt(tokenId)}`;

/**
 * tapeout.market 挂单流 → 候选：TAPEOUT_OFFICIAL（官方矿机市场，按挂单号买，正好付挂单价）和 TAPEMARKET_SEAPORT
 * （Seaport 卖单，买方付含 1% 手续费的总价，成交前要按 orderHash 取完整订单）。
 * 只留：BSC 主网、能买、状态 ACTIVE、已验证池、产出可用、Seaport 单离过期还有 minExpiryLeft 秒以上。
 */
export function parseTapeMarketFeed(json, { now = Math.floor(Date.now() / 1000), minExpiryLeft = 600, chainId = 56 } = {}) {
  const out = [];
  for (const it of json?.items ?? []) {
    const L = it?.listing;
    if (!L || Number(L.chainId) !== chainId || !L.purchasable || L.lifecycleStatus !== 'ACTIVE') continue;
    if (it.poolState !== 'verified' || it.dailyOutput?.availability !== 'available') continue;
    const cost = big(L.buyerPaysWei);
    if (cost <= 0n) continue;
    const base = { collection: L.collectionAddress, tokenId: big(L.tokenId), costWei: cost, dailyAtomic: big(it.dailyOutput.amount), key: machineKey(L.collectionAddress, L.tokenId), seller: L.seller };
    if (L.source === 'TAPEOUT_OFFICIAL' && L.listingId != null) out.push({ ...base, venue: 'official', listingId: big(L.listingId) });
    else if (L.source === 'TAPEMARKET_SEAPORT' && L.orderHash) {
      if (L.endTime != null && Number(L.endTime) < now + minExpiryLeft) continue;
      out.push({ ...base, venue: 'seaport', orderHash: L.orderHash });
    }
  }
  return out;
}

/** Firsto 卖单（parseAsks 的结果）→ 同一种候选 */
export function firstoCandidates(asks) {
  return asks.map((a) => ({
    venue: 'firsto',
    seller: a.header.maker,
    collection: a.leaf.collection,
    tokenId: a.tokenId,
    costWei: a.buyerCostWei,
    dailyAtomic: a.dailyAtomic,
    key: machineKey(a.leaf.collection, a.tokenId),
    order: { header: a.header, leaf: a.leaf, merkleProof: a.proof, signature: a.signature },
  }));
}

/** Firsto 单笔签名卖单 V2（parseSignedAsks 的结果）→ 同一种候选（规则决定 6.37） */
export function firstoSignedCandidates(asks) {
  return asks.map((a) => ({
    venue: 'firstoSigned',
    seller: a.maker,
    collection: a.ask.collection,
    tokenId: a.tokenId,
    costWei: a.buyerCostWei,
    dailyAtomic: a.dailyAtomic,
    key: machineKey(a.ask.collection, a.tokenId),
    order: { ask: a.ask, signature: a.signature },
  }));
}

export { parseAsks };

/** tapeout.market `GET /api/v1/listings/<orderHash>` → MarketTrader.buyFromSeaport 要的 AdvancedOrder（合约按 1/1 整单成交） */
export function seaportOrder(json) {
  const p = json?.parameters;
  if (!p || json.status !== 'ACTIVE') throw new Error('Seaport 卖单不可用');
  return {
    parameters: {
      offerer: p.offerer,
      zone: p.zone,
      offer: p.offer.map((o) => ({ itemType: Number(o.itemType), token: o.token, identifierOrCriteria: big(o.identifierOrCriteria), startAmount: big(o.startAmount), endAmount: big(o.endAmount) })),
      consideration: p.consideration.map((c) => ({
        itemType: Number(c.itemType),
        token: c.token,
        identifierOrCriteria: big(c.identifierOrCriteria),
        startAmount: big(c.startAmount),
        endAmount: big(c.endAmount),
        recipient: c.recipient,
      })),
      orderType: Number(p.orderType),
      startTime: big(p.startTime),
      endTime: big(p.endTime),
      zoneHash: p.zoneHash,
      salt: big(p.salt),
      conduitKey: p.conduitKey,
      totalOriginalConsiderationItems: big(p.totalOriginalConsiderationItems),
    },
    numerator: 1n,
    denominator: 1n,
    signature: json.signature ?? '0x',
    extraData: '0x',
  };
}

/** PoD getMiner 的原始返回（每个字 32 字节）→ 计价算力和资格，和合约 PoDReader.tryRead 同一算法 */
export function minerView(hex, { collection, tokenId }) {
  const data = String(hex ?? '0x').slice(2);
  if (data.length < 20 * 64) return { ok: false };
  const word = (i) => BigInt(`0x${data.slice(i * 64, (i + 1) * 64)}`);
  if (lower(`0x${data.slice(24, 64)}`) !== lower(collection) || word(1) !== BigInt(tokenId)) return { ok: false };
  const base = word(3);
  const mult = word(7);
  const paid = word(19);
  const weight = mult === 0n ? 0n : base <= paid / mult ? base * mult : paid;
  return { ok: true, weight, mining: word(9) === 1n, since: word(8), verified: paid > 0n };
}

/**
 * 挑这一轮要买的：每台矿机只留最便宜的那个来源；合格（资格 + 计价算力 10–300）；每单位计价算力的含费价不超过 maxWeiPerWeight
 * （主板收购价换成 BNB 再扣兑换成本）；整台价不超预算，最多 slots 台。同价时算力大的在前（交易少、占名额少）。
 * miners：Map(key → minerView 结果)；okCollection(collection) → 是否工厂处理器的矿机合集。
 */
/**
 * MachineLister.listings(卖家) 的返回值是不是本协议的挂单库：`listings` 返回结构体，viem 给的是带字段名的对象（不是数组），
 * 第一个字段 board 非零才是挂单库。2026-10-26 主网分叉演练发现原来按 l[0] 读，永远是 undefined，所有卖家都被当成
 * 自己的挂单库，机器人一台都不买。
 */
/**
 * 机器人在 PancakeSwap 上买卖 BEM 的每小时上限（项目方 2026-10-26 决定：不超过全市场成交量的约 10%，主网每小时 80 BEM）。
 * flow = 最近换过的 BEM [{ at, bem }]（bem 是 BEM 最小单位的字符串），cap = 每小时上限（0 = 不限）。
 * 返回 { flow（只留窗口内的）, used, allows(need) }：窗口里还没换过时，单笔超过上限也放行一笔（否则大一点的矿机永远买不了），
 * 否则 used + need ≤ cap 才放行。
 */
export function bemRoom(flow, now, cap, windowSec = 3_600) {
  const kept = (flow ?? []).filter((x) => x.at > now - windowSec);
  const used = kept.reduce((s, x) => s + BigInt(x.bem), 0n);
  return { flow: kept, used, allows: (need) => cap <= 0n || used === 0n || used + need <= cap };
}

/**
 * 月局"等首批回馈"（2026-10-26）：规则决定 6.37 让月局买满就开挖，之后才到账的回馈买不了矿机，
 * 闲置到局终再滚给下一块月局。所以这块月局的回馈桶里还有钱时，机器人先领回馈，买矿机时留出
 * "一台最小算力矿机的钱 + 10%"（卖一每次报价最多涨 5%，涨两次也还够一台，别人调 sync 也开不了挖）和最后一个名额，不触发买满。
 * 满足任一条件就不再等：桶里不到 0.01 BNB；开局满 24 小时（铸造还在继续时桶里会一直进新钱）；离准备期结束不到 2 小时；
 * 只剩最后一个名额。时长按测试网的时间倍率 divisor 缩短。
 * 返回 { hold, reserveBem（买矿机时不花的 BEM）, slotsLeft（还能买几台）, reason }。
 */
export const SUBSIDY_MIN_WEI = 10n ** 16n;
export const SUBSIDY_MAX_WAIT_SEC = 86_400;
export const SUBSIDY_END_MARGIN_SEC = 7_200;
export const SUBSIDY_RESERVE_MARGIN_BPS = 1_000n;

export function subsidyHold({ now, startedAt, prepEnd, bucketWei, price, minWeight = 10n, count, maxMachines = 100n, divisor = 1 }) {
  const free = { hold: false, reserveBem: 0n, slotsLeft: maxMachines > count ? maxMachines - count : 0n };
  const t = BigInt(now);
  let reason = null;
  if (bucketWei < SUBSIDY_MIN_WEI) reason = 'bucket empty';
  else if (t >= startedAt + BigInt(Math.floor(SUBSIDY_MAX_WAIT_SEC / divisor))) reason = 'waited 24 h';
  else if (t + BigInt(Math.floor(SUBSIDY_END_MARGIN_SEC / divisor)) >= prepEnd) reason = 'preparation ends soon';
  else if (count + 1n >= maxMachines) reason = 'last slot';
  if (reason) return { ...free, reason };
  return { hold: true, reserveBem: (price * minWeight * (10_000n + SUBSIDY_RESERVE_MARGIN_BPS)) / 10_000n, slotsLeft: maxMachines - count - 1n, reason: 'waiting for subsidy' };
}

export function isVaultListing(l) {
  const board = l?.board ?? (Array.isArray(l) ? l[0] : undefined);
  return typeof board === 'string' && /^0x[0-9a-fA-F]{40}$/.test(board) && !/^0x0{40}$/i.test(board);
}

export function pickMachines(cands, { miners, okCollection, now, minAge, minWeight = 10n, maxWeight = 300n, maxWeiPerWeight, budgetWei, slots = 100 }) {
  const best = new Map();
  for (const c of cands) {
    const m = miners.get(c.key);
    if (!m?.ok || !m.mining || !m.verified || !okCollection(c.collection)) continue;
    if (m.weight < minWeight || m.weight > maxWeight) continue;
    if (BigInt(now) < m.since + BigInt(minAge)) continue;
    const perWeight = c.costWei / m.weight;
    const prev = best.get(c.key);
    if (!prev || perWeight < prev.perWeight) best.set(c.key, { ...c, weight: m.weight, perWeight });
  }
  const sorted = [...best.values()].sort((x, y) => (x.perWeight !== y.perWeight ? (x.perWeight < y.perWeight ? -1 : 1) : x.weight > y.weight ? -1 : x.weight < y.weight ? 1 : 0));
  const picked = [];
  let left = budgetWei;
  for (const c of sorted) {
    if (picked.length >= slots) break;
    if (c.perWeight > maxWeiPerWeight) break;
    if (c.costWei > left) continue;
    picked.push(c);
    left -= c.costWei;
  }
  return picked;
}

/**
 * 主板挂单库在 Seaport 上 validate 过的卖单 → 提交给 tapeout.market（`POST /api/v1/listings`，和它网页提交签名卖单用同一个接口），
 * 这样卖单才会显示在 tapeout.market 上。订单按 V2-ABI rc8 一节的格式组：offerer = 挂单库，对价 = [净价 → 挂单库, 手续费 → 收款地址]，
 * 链上已 validate，所以签名为空。startTime / endTime / salt / net / fee 取 MachineLister 的 `SeaportListed` 事件。
 */
export function tapemarketListingBody({ vault, collection, tokenId, net, fee, feeRecipient, salt, startTime, endTime }) {
  const zero = '0x0000000000000000000000000000000000000000';
  const zero32 = `0x${'0'.repeat(64)}`;
  const consideration = [{ itemType: 0, token: zero, identifierOrCriteria: '0', startAmount: String(net), endAmount: String(net), recipient: vault }];
  if (BigInt(fee) > 0n) consideration.push({ itemType: 0, token: zero, identifierOrCriteria: '0', startAmount: String(fee), endAmount: String(fee), recipient: feeRecipient });
  return {
    assetStandard: 'ERC721',
    processorAddress: collection,
    collectionAddress: collection,
    parameters: {
      offerer: vault,
      zone: zero,
      offer: [{ itemType: 2, token: collection, identifierOrCriteria: String(tokenId), startAmount: '1', endAmount: '1' }],
      consideration,
      orderType: 0,
      startTime: String(startTime),
      endTime: String(endTime),
      zoneHash: zero32,
      salt: `0x${BigInt(salt).toString(16).padStart(64, '0')}`,
      conduitKey: zero32,
      counter: '0',
      totalOriginalConsiderationItems: consideration.length,
    },
    signature: '0x',
  };
}

/**
 * 规则 6.29"保持排序第一"的目标价：在所有平台的合格挂单（已验证、在挖、计价算力 10–300、工厂处理器矿机，不含我们自己的挂单库）里，
 * 取"买家实付 ÷ 计价算力"最低的那张，再低 0.1%，折回"主板每单位权重实得多少 BEM"（报价合约 postFloor 的单位）：
 *   挂单模块的定价（MachineLister.prices）：净价 net = ⌈要价 ÷ TWAP⌉ ÷ 98%；官方市场挂单价 = net ÷ (1 − 1%)；Seaport 买家付 net × (1 + 1%)。
 *   两边都要排第一时，按更严的官方市场算：net = 目标买家实付 × 99%；要价 = net × 98%，再按 TWAP 换成 BEM。
 * 返回 { floorBem（每单位权重，BEM 最小单位）, best（最低那张候选）}；没有合格挂单返回 null。
 */
export function floorTarget(cands, { miners, okCollection, ownVault, now, minAge, bemPerBnb, minWeight = 10n, maxWeight = 300n, undercutBps = 10n, officialFeeBps = 100n, slippageBps = 200n }) {
  let best = null;
  for (const c of cands) {
    if (ownVault(c)) continue;
    const m = miners.get(c.key);
    if (!m?.ok || !m.mining || !m.verified || !okCollection(c.collection)) continue;
    if (m.weight < minWeight || m.weight > maxWeight || BigInt(now) < m.since + BigInt(minAge)) continue;
    const perWeight = c.costWei / m.weight;
    if (!best || perWeight < best.perWeight) best = { ...c, weight: m.weight, perWeight };
  }
  if (!best) return null;
  const BPS = 10_000n;
  const buyerPays = (best.perWeight * (BPS - undercutBps)) / BPS;
  const net = (buyerPays * (BPS - officialFeeBps)) / BPS;
  const quoteBnb = (net * (BPS - slippageBps)) / BPS;
  return { floorBem: (quoteBnb * bemPerBnb) / 10n ** 18n, best };
}

/**
 * Seaport 上的 WBNB 出价 → MarketTrader.sellToOffer 的参数和净到手：
 * 出价的 offer 是 WBNB（itemType 1）；consideration[0] 是要的矿机（itemType 2 指定一台，或 4 = 整个合集按条件，identifierOrCriteria 0 = 任意一台）；
 * 其余 WBNB 对价项是卖方要付的手续费（从收到的 WBNB 里付）。净到手 = 出价 − 这些手续费。不合这台矿机的返回 null。
 * 主网 tapeout.market 现在没有矿机出价，这条路径目前只在测试网（cfg.seaportOffersFile）用；合约已支持，以后有出价时直接可用。
 */
export function offerFor(o, { collection, tokenId, wbnb, now }) {
  const p = o?.parameters;
  if (!p?.offer?.length || !p?.consideration?.length) return null;
  const want = p.consideration[0];
  const type = Number(want.itemType);
  if (lower(want.token) !== lower(collection)) return null;
  if (type === 2 && big(want.identifierOrCriteria) !== BigInt(tokenId)) return null;
  if (type === 4 && big(want.identifierOrCriteria) !== 0n) return null; // 带 Merkle 根的条件出价不支持
  if (type !== 2 && type !== 4) return null;
  const pay = p.offer[0];
  if (Number(pay.itemType) !== 1 || lower(pay.token) !== lower(wbnb)) return null;
  if (now != null && (Number(p.endTime) <= now + 600 || Number(p.startTime) > now)) return null;
  const gross = big(pay.startAmount);
  const fees = p.consideration.slice(1).filter((c) => Number(c.itemType) === 1 && lower(c.token) === lower(wbnb)).reduce((s, c) => s + big(c.startAmount), 0n);
  if (gross <= fees) return null;
  const order = seaportOrder({ status: 'ACTIVE', parameters: p, signature: o.signature ?? '0x' });
  const cr = type === 4 ? [{ orderIndex: 0n, side: 1, index: 0n, identifier: BigInt(tokenId), criteriaProof: [] }] : [];
  return { orderHash: o.orderHash, gross, net: gross - fees, order, cr };
}
