// 报卖一用的 Firsto 挂单先在链上核对（规则决定 6.36）：Firsto 接口返回的挂单可能已经买不到（卖家转走了矿机、
// 撤销了授权、撤单、过期），有人挂几条假的低价单就能把卖一往下带。这里对每条挂单做一次"模拟购买"：eth_call 真实的成交函数，
// 付款正好等于接口给的含费价，调用者用余额覆盖临时给足 BNB。模拟成交 = 卖家还持有、授权有效、订单没撤没过期、签名有效、
// 价格就是这个价，一次全部覆盖。不发交易，不花钱。
import { concatHex, encodeAbiParameters, encodeFunctionData, parseAbi, parseAbiParameters } from 'viem';
import { FIRSTO_ASK_EXCHANGE, FIRSTO_SIGNED_ASK_V2, OFFICIAL_MACHINES } from './firsto.js';

/** 模拟购买的买家 / 收货地址：任何没有合约代码的地址都行，模拟时用余额覆盖给它 1000 BNB */
export const SIM_BUYER = '0x000000000000000000000000000000000000bEEF';
const SIM_BALANCE = 1000n * 10n ** 18n;

const lower = (a) => String(a ?? '').toLowerCase();
const big = (v) => BigInt(v ?? 0);

// 批量卖单 0x20b36528(批次头, 叶子, merkleProof, signature, 收货地址)
const BATCH_SELECTOR = '0x20b36528';
const BATCH_PARAMS = parseAbiParameters([
  '(address maker, bytes32 merkleRoot, uint256 batchNonce, uint256 expiry, address payoutRecipient, uint256 feeBps, uint256 feeEpoch, uint256 schemaVersion) header',
  '(address maker, address collection, uint256 tokenId, uint256 priceWei, address payoutRecipient, uint256 feeBps, uint256 feeEpoch, uint256 batchNonce, uint256 leafIndex, uint256 schemaVersion) leaf',
  'bytes32[] proof, bytes signature, address recipient',
]);
// 单笔签名卖单 V2，字段同 contracts/src/market/FirstoSignedAsk.sol
const SIGNED_ABI = parseAbi([
  'function fillSignedAsk((address maker, address collection, uint256 tokenId, uint256 nonce, uint128 price, uint64 expiry, address payoutRecipient, uint16 feeBps, uint256 feeEpoch, uint16 schemaVersion) ask, bytes signature, address nftRecipient) payable',
]);

/** 卖家地址（同一卖家只算一条） */
export const makerOf = (row) => lower(row?.bestAsk?.execution?.maker ?? row?.bestAsk?.account);

/**
 * 一条挂单 → 模拟购买要发的调用 { to, data, value }。只认 BSC 主网、Firsto 的两个卖单合约、官方矿机合集；
 * 其他一律返回 null（不核对 = 不算）。
 */
export function askCall(row, { buyer = SIM_BUYER, chainId = 56 } = {}) {
  const a = row?.bestAsk;
  const e = a?.execution;
  if (!a || !e || Number(e.chainId) !== chainId || lower(e.collection) !== lower(OFFICIAL_MACHINES)) return null;
  const value = big(a.buyerCostWei);
  if (value <= 0n) return null;
  if (e.kind === 'circuit_batch_ask' && lower(e.exchange) === lower(FIRSTO_ASK_EXCHANGE)) {
    const header = {
      maker: e.maker,
      merkleRoot: e.merkleRoot,
      batchNonce: big(e.batchNonce),
      expiry: big(e.expiry),
      payoutRecipient: e.payoutRecipient,
      feeBps: big(e.feeBps),
      feeEpoch: big(e.feeEpoch),
      schemaVersion: big(e.schemaVersion),
    };
    const leaf = {
      maker: e.maker,
      collection: e.collection,
      tokenId: big(e.tokenId),
      priceWei: big(e.priceWei),
      payoutRecipient: e.payoutRecipient,
      feeBps: big(e.feeBps),
      feeEpoch: big(e.feeEpoch),
      batchNonce: big(e.batchNonce),
      leafIndex: big(e.leafIndex),
      schemaVersion: big(e.schemaVersion),
    };
    const data = concatHex([BATCH_SELECTOR, encodeAbiParameters(BATCH_PARAMS, [header, leaf, e.merkleProof ?? [], e.signature ?? '0x', buyer])]);
    return { to: FIRSTO_ASK_EXCHANGE, data, value };
  }
  if (e.kind === 'signed_ask' && lower(e.exchange) === lower(FIRSTO_SIGNED_ASK_V2)) {
    const ask = {
      maker: e.maker,
      collection: e.collection,
      tokenId: big(e.tokenId),
      nonce: big(e.nonce),
      price: big(e.priceWei),
      expiry: big(e.expiry),
      payoutRecipient: e.payoutRecipient,
      feeBps: Number(e.feeBps),
      feeEpoch: big(e.feeEpoch),
      schemaVersion: Number(e.schemaVersion),
    };
    const data = encodeFunctionData({ abi: SIGNED_ABI, functionName: 'fillSignedAsk', args: [ask, e.signature ?? '0x', buyer] });
    return { to: FIRSTO_SIGNED_ASK_V2, data, value };
  }
  return null;
}

/** 模拟购买一条挂单：{ ok, reason } */
export async function simulateAsk(pub, row, opts = {}) {
  const call = askCall(row, opts);
  if (!call) return { ok: false, reason: 'unsupported listing' };
  const buyer = opts.buyer ?? SIM_BUYER;
  try {
    await pub.call({ account: buyer, ...call, stateOverride: [{ address: buyer, balance: SIM_BALANCE }] });
    return { ok: true };
  } catch (e) {
    return { ok: false, reason: (e?.shortMessage ?? e?.message ?? String(e)).split('\n')[0].slice(0, 160) };
  }
}

/** 日产能价（BNB wei / (1 BEM / 天)），口径同 market.js 的 firstoQuote */
export const dcpOf = (row) => (big(row.bestAsk.buyerCostWei) * 10n ** 8n) / big(row.mining.estimated24hAtomic);

/**
 * 可以参与卖一的挂单：已验证、有产出、有含费价，并且是主板能收的矿机：算力在 [minWeight, maxWeight]
 * （和合约 minMachineWeight / maxMachineWeight、firsto.js 的 parseAsks 一致），挂单离过期还有 minExpiryLeft 秒以上。
 * 按日产能价从低到高排。
 */
export function askCandidates(json, { now = Math.floor(Date.now() / 1000), minWeight = 10n, maxWeight = 300n, minExpiryLeft = 600 } = {}) {
  return (json?.rows ?? [])
    .filter((r) => r?.mining?.status === 'verified' && big(r.mining.estimated24hAtomic) > 0n && big(r.bestAsk?.buyerCostWei) > 0n)
    .filter((r) => big(r.mining.weight) >= minWeight && big(r.mining.weight) <= maxWeight)
    .filter((r) => r.bestAsk.execution?.expiry == null || Number(r.bestAsk.execution.expiry) >= now + minExpiryLeft)
    .map((r) => ({ row: r, dcp: dcpOf(r), maker: makerOf(r) }))
    .sort((a, b) => (a.dcp < b.dcp ? -1 : a.dcp > b.dcp ? 1 : 0));
}

/** 机器人能核对的挂单里有几个不同卖家 */
export function supportedSellers(json, { now, chainId = 56 } = {}) {
  const makers = new Set();
  for (const c of askCandidates(json, { now })) if (c.maker && askCall(c.row, { chainId })) makers.add(c.maker);
  return makers.size;
}

/**
 * 一个卖家一次挂很多台，就能占满最便宜的第一页（2026-10-27 主网：一个卖家占满前 30 条，卖一凑不够 3 个卖家，停报一小时以上）。
 * 不同卖家不足 want 个时，按同一份快照（viewId）往后翻，最多读 maxPages 页；翻页失败就用已经读到的。
 * fetchPage(page) 返回那一页的 json。
 */
export async function withMoreAskPages(first, fetchPage, { now, want = 5, maxPages = 3 } = {}) {
  let json = first;
  const last = Math.min(maxPages, Number(first?.totalPages ?? 1));
  for (let page = 2; page <= last && first.viewId; page++) {
    if (supportedSellers(json, { now }) >= want) break;
    let next;
    try {
      next = await fetchPage(page);
    } catch {
      break;
    }
    if (!Array.isArray(next?.rows) || next.viewId !== first.viewId) break;
    json = { ...json, rows: [...json.rows, ...next.rows], pagesRead: page };
  }
  return json;
}

/**
 * 从便宜到贵逐条核对，每个卖家只核对最便宜的一条：通过就保留，不通过这个卖家本小时就不算了（免得一个人用很多条假单耗光核对次数）。
 * 机器人不会模拟的挂单（别的平台、别的合集、别的链）直接跳过，不占核对次数、也不算这个卖家。
 * 凑够 need 个不同卖家就停，最多核对 maxChecks 条（控制 RPC 用量）。
 * 返回 { rows（通过核对的挂单，每个卖家一条）, checked, skipped, rejected: [{ maker, tokenId, reason }] }。
 */
export async function verifiedAskRows(pub, json, { need = 3, maxChecks = 20, now, ...opts } = {}) {
  const rows = [];
  const rejected = [];
  const seen = new Set();
  let checked = 0;
  let skipped = 0;
  for (const c of askCandidates(json, { now })) {
    if (rows.length >= need || checked >= maxChecks) break;
    if (!c.maker || seen.has(c.maker)) continue;
    if (!askCall(c.row, opts)) {
      skipped += 1;
      continue;
    }
    checked += 1;
    seen.add(c.maker);
    const r = await simulateAsk(pub, c.row, opts);
    if (r.ok) {
      rows.push(c.row);
    } else {
      rejected.push({ maker: c.maker, tokenId: String(c.row.bestAsk?.execution?.tokenId ?? ''), reason: r.reason });
    }
  }
  return { rows, checked, skipped, rejected };
}

const OFFICIAL_BUY = parseAbi(['function buy(uint256 listingId, uint96 maxPrice) payable']);
const OWNER_OF = parseAbi(['function ownerOf(uint256 id) view returns (address)']);

/**
 * 核对 markets.js 统一格式的一张候选挂单现在真能买到（第六轮审阅 / 规则决定 6.37：卖出要挂在"市场最低价"，这个最低价必须真实，
 * 否则有人挂一张买不到的低价单就能把主板的卖价带下去）：
 * - Firsto 批量卖单、签名卖单 V2、TapeOut 官方市场挂单：按真实成交函数模拟购买（eth_call，余额覆盖），付款 = 买家实付；
 * - Seaport 卖单：完整订单要另外取，这里只核对矿机还在卖家手里（卖单不托管，转走即失效）。
 * 返回 { ok, reason }。不发交易，不花钱。
 */
export async function simulateCandidate(pub, c, { buyer = SIM_BUYER, officialMarket } = {}) {
  try {
    if (c.venue === 'firsto') {
      const { header, leaf, merkleProof, signature } = c.order;
      const data = concatHex([BATCH_SELECTOR, encodeAbiParameters(BATCH_PARAMS, [header, leaf, merkleProof ?? [], signature ?? '0x', buyer])]);
      await pub.call({ account: buyer, to: FIRSTO_ASK_EXCHANGE, data, value: c.costWei, stateOverride: [{ address: buyer, balance: SIM_BALANCE }] });
    } else if (c.venue === 'firstoSigned') {
      const data = encodeFunctionData({ abi: SIGNED_ABI, functionName: 'fillSignedAsk', args: [c.order.ask, c.order.signature ?? '0x', buyer] });
      await pub.call({ account: buyer, to: FIRSTO_SIGNED_ASK_V2, data, value: c.costWei, stateOverride: [{ address: buyer, balance: SIM_BALANCE }] });
    } else if (c.venue === 'official' && officialMarket) {
      const data = encodeFunctionData({ abi: OFFICIAL_BUY, functionName: 'buy', args: [BigInt(c.listingId), c.costWei] });
      await pub.call({ account: buyer, to: officialMarket, data, value: c.costWei, stateOverride: [{ address: buyer, balance: SIM_BALANCE }] });
    } else {
      const owner = await pub.readContract({ address: c.collection, abi: OWNER_OF, functionName: 'ownerOf', args: [BigInt(c.tokenId)] });
      if (lower(owner) !== lower(c.seller)) return { ok: false, reason: `矿机已经不在卖家手里（现在是 ${owner}）` };
    }
    return { ok: true };
  } catch (e) {
    return { ok: false, reason: (e?.shortMessage ?? e?.message ?? String(e)).split('\n')[0].slice(0, 160) };
  }
}
