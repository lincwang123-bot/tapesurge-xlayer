import { test } from 'node:test';
const EXAMPLE_HASH = '0x325153d821eab5289316ddfbd38fd289d42874da6e6f77ab8aaf37d9a87d0ac3'; // Firsto 接入资料里的签名卖单 V2 示例哈希
import assert from 'node:assert/strict';
import { FIRSTO_ASK_EXCHANGE, OFFICIAL_MACHINES, bestBidFor, bidProceeds, parseAsks, parseBids, pickAsks } from './firsto.js';

const NOW = 1_792_700_000;
const E18 = 10n ** 18n;

/** 一行 Firsto 挂单（字段取自 2026-10-23 的真实数据，contracts/test/probe/firsto-snapshot.json） */
function row(tokenId, weight, buyerCostWei, over = {}) {
  const priceWei = (BigInt(buyerCostWei) * 100n) / 101n;
  return {
    mining: { status: 'verified', weight: String(weight), estimated24hAtomic: String(450_133n * BigInt(weight)), ...over.mining },
    bestAsk: {
      status: 'open',
      venue: 'firsto',
      buyerCostWei: String(buyerCostWei),
      execution: {
        kind: 'circuit_batch_ask',
        chainId: 56,
        exchange: FIRSTO_ASK_EXCHANGE,
        maker: '0x2bcb95bd3bb2b9f37dbe3005bba73e8b7aeec9ae',
        merkleRoot: '0x81f8177dd0498b33a69b2f5219cc90a68a7f7712b5382a3d05b5066aee8afd92',
        batchNonce: '95677179396820024381475665854744038602684829362478137000281378572200281421748',
        expiry: NOW + 86_400,
        payoutRecipient: '0x2bcb95bd3bb2b9f37dbe3005bba73e8b7aeec9ae',
        feeBps: 100,
        feeEpoch: 1,
        schemaVersion: 1,
        collection: OFFICIAL_MACHINES,
        tokenId: String(tokenId),
        priceWei: String(priceWei),
        leafIndex: 5,
        merkleProof: ['0x01', '0x02'],
        signature: '0xabcd',
        ...over.execution,
      },
      ...over.bestAsk,
    },
  };
}

test('parseAsks 只留符合条件的卖单，按每单位算力价从低到高排，同价算力大的在前', () => {
  const json = {
    rows: [
      row(1, 10, 454_181_108_256_000_000n),
      row(2, 44, 1_996_396_519_372_000_000n), // 每单位 0.04537…，比 10 的便宜一点
      row(3, 391, 17_740_705_639_688_000_000n), // 算力超过 300，不收
      row(4, 9, 400_000_000_000_000_000n), // 算力不到 10，不收
      row(5, 20, 900_000_000_000_000_000n, { mining: { status: 'unverified' } }),
      row(6, 20, 900_000_000_000_000_000n, { execution: { exchange: '0x0000000000000000000000000000000000000001' } }),
      row(7, 20, 900_000_000_000_000_000n, { execution: { expiry: NOW + 60 } }), // 快过期
      row(8, 20, 908_362_216_512_000_000n), // 和 #1 同单价、算力更大
    ],
  };
  const asks = parseAsks(json, { now: NOW });
  assert.deepEqual(asks.map((a) => a.tokenId), [2n, 8n, 1n]);
  const a = asks.find((x) => x.tokenId === 1n);
  assert.equal(a.leaf.tokenId, 1n);
  assert.equal(a.leaf.leafIndex, 5n);
  assert.equal(a.header.batchNonce, a.leaf.batchNonce);
  assert.equal(a.buyerCostWei, 454_181_108_256_000_000n);
  assert.deepEqual(a.proof, ['0x01', '0x02']);
});

test('pickAsks 不超过单价上限、预算和名额，放不下的跳过', () => {
  const asks = parseAsks({ rows: [row(1, 10, 45n * 10n ** 16n), row(2, 100, 455n * 10n ** 16n), row(3, 10, 46n * 10n ** 16n), row(4, 10, 47n * 10n ** 16n)] }, { now: NOW });
  // 单价上限 0.046 BNB / 算力：#4（0.047）不要；预算 1 BNB：#2（4.55）放不下，买 #1 和 #3
  const picked = pickAsks(asks, { maxWeiPerWeight: 46n * 10n ** 15n, budgetWei: E18 });
  assert.deepEqual(picked.map((a) => a.tokenId), [1n, 3n]);
  assert.deepEqual(pickAsks(asks, { maxWeiPerWeight: E18, budgetWei: 10n * E18, slots: 1 }).map((a) => a.tokenId), [1n]);
});

test('统一买单：按算力范围和预算挑出价最高的，净到手扣 1%，低于下限就不卖', () => {
  const bids = parseBids({
    bids: [
      { orderId: '1215', state: 'active', dailyCapacityPriceWei: '9500000000000000000', remainingBudgetWei: '2000000000000000000', minCircuitH: '1', maxCircuitH: '30', feeBps: '100' },
      { orderId: '1217', state: 'active', dailyCapacityPriceWei: '9510000000000000000', remainingBudgetWei: '300000000000000000', minCircuitH: '0', maxCircuitH: '0', feeBps: '100' },
      { orderId: '1300', state: 'cancelled', dailyCapacityPriceWei: '99000000000000000000', remainingBudgetWei: '9000000000000000000', minCircuitH: '0', maxCircuitH: '0', feeBps: '100' },
    ],
  });
  assert.deepEqual(bids.map((b) => b.orderId), [1217n, 1215n]);
  // 实测那台：算力 10，预计日产出 0.04501327 BEM → 卖给 #1215 毛价 0.4276 BNB，净 0.4233
  const p = bidProceeds(bids[1], 4_501_327n);
  assert.equal(p.gross, 427_626_065_000_000_000n);
  assert.equal(p.net, 423_349_804_350_000_000n);
  // #1217 出价更高但预算只有 0.3 BNB，放不下，落到 #1215
  assert.equal(bestBidFor(bids, { weight: 10n, dailyAtomic: 4_501_327n })?.orderId, 1215n);
  // 算力 40 超出 #1215 的 1–30；#1217 预算不够 → 没有
  assert.equal(bestBidFor(bids, { weight: 40n, dailyAtomic: 18_005_308n }), null);
  // 净到手低于主板卖价下限 → 不卖
  assert.equal(bestBidFor(bids, { weight: 10n, dailyAtomic: 4_501_327n, minNetWei: 5n * 10n ** 17n }), null);
});

test('Firsto 签名卖单 V2：按资料的 typedData 算出的 EIP-712 哈希和资料示例一致；提交请求体用十进制字符串', async () => {
  const { hashTypedData } = await import('viem');
  const { SIGNED_ASK_TYPES, signedAskDomain, signedAskEnvelope } = await import('./firsto.js');
  const ask = {
    maker: '0x1111111111111111111111111111111111111111',
    collection: '0xb1024b89886B9a34Aa4ff5F31C411D708b20a14C',
    tokenId: 123n,
    nonce: 123456789n,
    price: 1_000_000_000_000_000_000n,
    expiry: 1_893_456_000n,
    payoutRecipient: '0x1111111111111111111111111111111111111111',
    feeBps: 100,
    feeEpoch: 1n,
    schemaVersion: 2,
  };
  const h = hashTypedData({ domain: signedAskDomain(), types: SIGNED_ASK_TYPES, primaryType: 'SignedAsk', message: ask });
  assert.equal(h, EXAMPLE_HASH);
  const body = signedAskEnvelope(ask);
  assert.equal(body.envelope.message.price, '1000000000000000000');
  assert.equal(body.envelope.message.feeBps, '100');
  assert.equal(body.envelope.domain.chainId, 56);
  assert.equal(body.envelope.primaryType, 'SignedAsk');
});
