// Firsto 自动买卖（规则决定 6.22）：把 Firsto 公开接口里的卖单 / 统一买单整理成 FirstoTrader 要的订单参数，并按规则挑选。
// 这里只整理和挑选，不发交易；价格上限 / 下限和矿机资格最终由合约检查，机器人挑错了只会让交易回滚。
// 调用格式由链上成交反推，并经主网分叉实测：
//   卖单合约 0x20b36528(批次头, 叶子, merkleProof, signature, 收货地址)，付款必须正好等于 buyerCostWei（含买方 1% 手续费）；
//   统一买单 0x4c67242f(orderId, collection, tokenId, minerKey, 收款地址, 当前日产能价, 当前费率, 最低净到手)。
// Firsto 把算力叫 H：买单的 minCircuitH / maxCircuitH 就是它收的算力范围（0 / 0 = 不限）。

// 行情来自 Firsto 公开接口（api-tapeout.firsto.ai）。2026-10-23 Firsto 回复：按我们的频率（报价约每小时、递单主网每 5 分钟）
// 读取公开数据可以，不需要 API key，对外展示时注明 Firsto 来源。卖单列表按对方示例加 askPresence=listed（只返回有挂单的），
// 再加 miningStatus=verified（只要已验证的）。
export const ASKS_URL = 'https://api-tapeout.firsto.ai/v1/circuits?category=official_mining&sort=daily_capacity_price_low&askPresence=listed&miningStatus=verified&pageSize=50'; // 每页最多 50 条
/** 同一份快照（viewId）的第 page 页；第一页就是 ASKS_URL */
export const asksPageUrl = (viewId, page) => `${ASKS_URL}&page=${page}&viewId=${encodeURIComponent(viewId)}`;
export const BIDS_URL = 'https://api-tapeout.firsto.ai/v1/circuit/capacity-bids';
export const FIRSTO_UA = { accept: 'application/json', 'user-agent': 'TapeSurge-operator-bot/1 (+https://tapesurge.com)' };

export const FIRSTO_ASK_EXCHANGE = '0x3f58c9cbce933c76158b2a29b0d612c46546dc43';
export const FIRSTO_BID_EXCHANGE = '0x9273d46b77b67ba9b24177c25ec25fcbadf27040';
export const OFFICIAL_MACHINES = '0xb1024b89886b9a34aa4ff5f31c411d708b20a14c';

const BPS = 10_000n;
const lower = (a) => String(a ?? '').toLowerCase();
const big = (v) => BigInt(v ?? 0);

/**
 * 卖单（`/v1/circuits?category=official_mining&sort=daily_capacity_price_low&miningStatus=verified` 的 rows）
 * → 可以直接递给 FirstoTrader 的候选，按每单位算力的含费价从低到高排（同价时算力大的在前：交易次数少、占的名额少）。
 * 只留：已验证、在挖、官方矿机合集、算力在 [minWeight, maxWeight]、Firsto 卖单合约、BSC 主网、离过期还有 minExpiryLeft 秒以上
 * （测试网传入 mock 卖单合约、测试矿机合集和链 ID 97）。
 * 运行满 7 天等其余资格由合约在链上查。
 */
export function parseAsks(
  json,
  { now = Math.floor(Date.now() / 1000), minWeight = 10n, maxWeight = 300n, minExpiryLeft = 600, exchange = FIRSTO_ASK_EXCHANGE, collection = OFFICIAL_MACHINES, chainId = 56 } = {},
) {
  const out = [];
  for (const r of json?.rows ?? []) {
    const m = r?.mining;
    const a = r?.bestAsk;
    const e = a?.execution;
    if (!m || !a || !e || typeof e !== 'object') continue;
    if (m.status !== 'verified' || a.status !== 'open' || a.venue !== 'firsto') continue;
    if (e.kind !== 'circuit_batch_ask' || Number(e.chainId) !== chainId || lower(e.exchange) !== lower(exchange)) continue;
    if (lower(e.collection) !== lower(collection)) continue;
    const weight = big(m.weight);
    const dailyAtomic = big(m.estimated24hAtomic);
    if (weight < minWeight || weight > maxWeight || dailyAtomic <= 0n) continue;
    if (Number(e.expiry) < now + minExpiryLeft) continue;
    const buyerCostWei = big(a.buyerCostWei);
    if (buyerCostWei <= 0n || big(e.priceWei) <= 0n) continue;
    out.push({
      tokenId: big(e.tokenId),
      weight,
      dailyAtomic,
      buyerCostWei,
      perWeightWei: buyerCostWei / weight,
      header: {
        maker: e.maker,
        merkleRoot: e.merkleRoot,
        batchNonce: big(e.batchNonce),
        expiry: big(e.expiry),
        payoutRecipient: e.payoutRecipient,
        feeBps: big(e.feeBps),
        feeEpoch: big(e.feeEpoch),
        schemaVersion: big(e.schemaVersion),
      },
      leaf: {
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
      },
      proof: e.merkleProof ?? [],
      signature: e.signature,
    });
  }
  return out.sort((x, y) => (x.perWeightWei !== y.perWeightWei ? (x.perWeightWei < y.perWeightWei ? -1 : 1) : x.weight > y.weight ? -1 : x.weight < y.weight ? 1 : 0));
}

/**
 * 从排好序的卖单里挑这一轮要买的：每单位算力含费价不高于 maxWeiPerWeight（主板当前收购价换算成 BNB），
 * 整台价不超过剩余预算 budgetWei，最多 slots 台。预算放不下的那张跳过，继续看后面更小的。
 */
export function pickAsks(asks, { maxWeiPerWeight, budgetWei, slots = 100 }) {
  const picked = [];
  let left = budgetWei;
  for (const a of asks) {
    if (picked.length >= slots) break;
    if (a.perWeightWei > maxWeiPerWeight) break; // 已按单价排序，后面只会更贵
    if (a.buyerCostWei > left) continue;
    picked.push(a);
    left -= a.buyerCostWei;
  }
  return picked;
}

/** 统一买单（`/v1/circuit/capacity-bids`）→ 还在收的买单，按日产能价从高到低排 */
export function parseBids(json) {
  return (json?.bids ?? [])
    .filter((b) => b?.state === 'active' && big(b.remainingBudgetWei) > 0n && big(b.dailyCapacityPriceWei) > 0n)
    .map((b) => ({
      orderId: big(b.orderId),
      dailyCapacityPriceWei: big(b.dailyCapacityPriceWei),
      remainingBudgetWei: big(b.remainingBudgetWei),
      minH: big(b.minCircuitH),
      maxH: big(b.maxCircuitH),
      feeBps: big(b.feeBps),
    }))
    .sort((x, y) => (x.dailyCapacityPriceWei > y.dailyCapacityPriceWei ? -1 : x.dailyCapacityPriceWei < y.dailyCapacityPriceWei ? 1 : 0));
}

/** 一台矿机卖给某张买单：毛价 = 日产能价 × 预计日产出 ÷ 1e8，卖方再付 feeBps 的手续费 */
export function bidProceeds(bid, dailyAtomic) {
  const gross = (bid.dailyCapacityPriceWei * dailyAtomic) / 10n ** 8n;
  return { gross, net: (gross * (BPS - bid.feeBps)) / BPS };
}

/**
 * 给一台矿机（weight 算力、预计日产出 dailyAtomic）找出价最高、而且收得下的买单：
 * 算力在买单的范围内（0 / 0 = 不限），剩余预算够付毛价，净到手不低于 minNetWei（主板当前卖价换算成 BNB）。找不到返回 null。
 */
export function bestBidFor(bids, { weight, dailyAtomic, minNetWei = 0n }) {
  for (const b of bids) {
    const anySize = b.minH === 0n && b.maxH === 0n;
    if (!anySize && (weight < b.minH || (b.maxH > 0n && weight > b.maxH))) continue;
    const p = bidProceeds(b, dailyAtomic);
    if (p.gross > b.remainingBudgetWei) continue;
    if (p.net < minNetWei) return null; // 已按价格从高到低排，这张都不够，后面的更不够
    return { ...b, ...p };
  }
  return null;
}

// ---------- 主板挂单库在 Firsto 上挂的签名卖单（规则 6.30，v2.0-rc10） ----------
// 格式按 Firsto 接入资料：单笔签名卖单 V2，EIP-712；挂单人是我们的挂单库合约，
// Firsto 成交时回调库合约的 isValidSignature 验签（EIP-1271），所以提交时签名字段只要非空（库合约不看签名内容）。
export const FIRSTO_SIGNED_ASK_V2 = '0x33423244F9a5bF81b12B1a018aF6F4e079B97f29';
export const FIRSTO_ASKS_PUBLISH_URL = 'https://api-tapeout.firsto.ai/v1/circuit-asks';
export const firstoAskStatusUrl = (askHash) => `https://api-tapeout.firsto.ai/v1/circuit-asks/${askHash}/status`;
export const SIGNED_ASK_TYPES = {
  SignedAsk: [
    { name: 'maker', type: 'address' },
    { name: 'collection', type: 'address' },
    { name: 'tokenId', type: 'uint256' },
    { name: 'nonce', type: 'uint256' },
    { name: 'price', type: 'uint128' },
    { name: 'expiry', type: 'uint64' },
    { name: 'payoutRecipient', type: 'address' },
    { name: 'feeBps', type: 'uint16' },
    { name: 'feeEpoch', type: 'uint256' },
    { name: 'schemaVersion', type: 'uint16' },
  ],
};
export const signedAskDomain = (chainId = 56, verifyingContract = FIRSTO_SIGNED_ASK_V2) => ({ name: 'Firsto Circuit Signed Ask', version: '2', chainId, verifyingContract });

/** 一张签名卖单（数字用 bigint）→ 提交给 POST /v1/circuit-asks 的请求体：{ envelope: { domain, primaryType, message, signature } }，整数字段用十进制字符串 */
export function signedAskEnvelope(ask, { chainId = 56, verifyingContract = FIRSTO_SIGNED_ASK_V2, signature = '0x01' } = {}) {
  const message = {};
  for (const { name } of SIGNED_ASK_TYPES.SignedAsk) message[name] = typeof ask[name] === 'bigint' || typeof ask[name] === 'number' ? String(ask[name]) : ask[name];
  return { envelope: { domain: signedAskDomain(chainId, verifyingContract), primaryType: 'SignedAsk', message, signature } };
}

/**
 * 单笔签名卖单 V2（`bestAsk.execution.kind = signed_ask`，规则决定 6.37：Firsto 上新挂的单大多是这种）→ MarketTrader.buyFromSignedAsk
 * 要的订单。筛选同 parseAsks（已验证、挂单中、官方矿机合集、算力 [minWeight, maxWeight]、离过期 ≥ minExpiryLeft 秒），
 * 并核对含费价 = price + price × feeBps / 10000（卖单合约要求正好付这个数）。返回 { tokenId, weight, dailyAtomic, buyerCostWei, maker, ask, signature }。
 */
export function parseSignedAsks(
  json,
  { now = Math.floor(Date.now() / 1000), minWeight = 10n, maxWeight = 300n, minExpiryLeft = 600, exchange = FIRSTO_SIGNED_ASK_V2, collection = OFFICIAL_MACHINES, chainId = 56 } = {},
) {
  const out = [];
  for (const r of json?.rows ?? []) {
    const m = r?.mining;
    const a = r?.bestAsk;
    const e = a?.execution;
    if (!m || !a || !e || typeof e !== 'object') continue;
    if (m.status !== 'verified' || a.status !== 'open' || a.venue !== 'firsto') continue;
    if (e.kind !== 'signed_ask' || Number(e.chainId) !== chainId || lower(e.exchange) !== lower(exchange)) continue;
    if (lower(e.collection) !== lower(collection)) continue;
    const weight = big(m.weight);
    const dailyAtomic = big(m.estimated24hAtomic);
    if (weight < minWeight || weight > maxWeight || dailyAtomic <= 0n) continue;
    if (Number(e.expiry) < now + minExpiryLeft) continue;
    const price = big(e.priceWei);
    const buyerCostWei = big(a.buyerCostWei);
    if (price <= 0n || buyerCostWei !== price + (price * big(e.feeBps)) / BPS) continue;
    out.push({
      tokenId: big(e.tokenId),
      weight,
      dailyAtomic,
      buyerCostWei,
      maker: e.maker,
      ask: {
        maker: e.maker,
        collection: e.collection,
        tokenId: big(e.tokenId),
        nonce: big(e.nonce),
        price,
        expiry: big(e.expiry),
        payoutRecipient: e.payoutRecipient,
        feeBps: Number(e.feeBps),
        feeEpoch: big(e.feeEpoch),
        schemaVersion: Number(e.schemaVersion),
      },
      signature: e.signature,
    });
  }
  return out;
}
