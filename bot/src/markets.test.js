import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as M from './markets.js';
import { machineKey, minerView, parseTapeMarketFeed, pickMachines, seaportOrder } from './markets.js';

const NOW = 1_792_800_000;
const OFFICIAL = '0xb1024b89886b9a34aa4ff5f31c411d708b20a14c';
const BEHEMOTH = '0x1f5cb4aeae1807bf60c3b9c0d8adbcc14e91f12c';
const E18 = 10n ** 18n;

/** tapeout.market 挂单流的一行（字段取自 2026-10-24 的真实数据） */
function item(source, tokenId, buyerPays, over = {}) {
  return {
    poolState: 'verified',
    dailyOutput: { availability: 'available', amount: '31959360' },
    listing: {
      source,
      chainId: 56,
      purchasable: true,
      lifecycleStatus: 'ACTIVE',
      collectionAddress: OFFICIAL,
      tokenId: String(tokenId),
      buyerPaysWei: String(buyerPays),
      listingId: source === 'TAPEOUT_OFFICIAL' ? '25806' : null,
      orderHash: source === 'TAPEMARKET_SEAPORT' ? '0x0fa86c5637bff7db11994cbddaab0833ebf46546a4bf10be809efa4c32502e47' : null,
      endTime: String(NOW + 86_400),
      ...over.listing,
    },
    ...over.item,
  };
}

test('parseTapeMarketFeed 区分官方市场和 Seaport，过滤不能买的', () => {
  const c = parseTapeMarketFeed(
    {
      items: [
        item('TAPEOUT_OFFICIAL', 1416, 3_400_000_000_000_000_000n),
        item('TAPEMARKET_SEAPORT', 8340, 3_195_980_400_000_000_003n),
        item('TAPEMARKET_SEAPORT', 1, 1n, { listing: { endTime: String(NOW + 60) } }), // 快过期
        item('TAPEOUT_OFFICIAL', 2, 1n, { listing: { purchasable: false } }),
        item('TAPEOUT_OFFICIAL', 3, 1n, { item: { poolState: 'unverified' } }),
        item('SOMETHING_ELSE', 4, 1n),
      ],
    },
    { now: NOW },
  );
  assert.deepEqual(c.map((x) => `${x.venue}:${x.tokenId}`), ['official:1416', 'seaport:8340']);
  assert.equal(c[0].listingId, 25806n);
  assert.equal(c[1].key, machineKey(OFFICIAL, 8340));
});

/** 拼一个 getMiner 的原始返回：22 个字，填上要用到的几个 */
function minerHex({ collection = OFFICIAL, id, base, mult = 1n, since = NOW - 30 * 86_400, status = 1n, paid }) {
  const w = Array(22).fill(0n);
  w[0] = BigInt(collection);
  w[1] = BigInt(id);
  w[3] = base;
  w[7] = mult;
  w[8] = BigInt(since);
  w[9] = status;
  w[19] = paid;
  return `0x${w.map((x) => x.toString(16).padStart(64, '0')).join('')}`;
}

test('minerView 和合约同一算法：计价算力 = min(基础 × 倍数, 已验证池权重)', () => {
  assert.equal(minerView(minerHex({ id: 1, base: 71n, paid: 71n }), { collection: OFFICIAL, tokenId: 1n }).weight, 71n);
  // Behemoth 倍数 6：基础 10 → 60
  assert.equal(minerView(minerHex({ collection: BEHEMOTH, id: 2, base: 10n, mult: 6n, paid: 60n }), { collection: BEHEMOTH, tokenId: 2n }).weight, 60n);
  // 有最优加成时 [19] 更大，不计加成
  assert.equal(minerView(minerHex({ id: 3, base: 20n, paid: 26n }), { collection: OFFICIAL, tokenId: 3n }).weight, 20n);
  // 已验证池权重更小时取它
  assert.equal(minerView(minerHex({ id: 4, base: 20n, paid: 15n }), { collection: OFFICIAL, tokenId: 4n }).weight, 15n);
  const stopped = minerView(minerHex({ id: 5, base: 20n, paid: 0n, status: 3n }), { collection: OFFICIAL, tokenId: 5n });
  assert.equal(stopped.mining, false);
  assert.equal(stopped.verified, false);
  // 合集或编号对不上 → 不认
  assert.equal(minerView(minerHex({ id: 6, base: 20n, paid: 20n }), { collection: OFFICIAL, tokenId: 7n }).ok, false);
});

test('pickMachines：同一台只留最便宜的来源，按每单位计价算力排序，过滤资格和预算', () => {
  const k = (id) => machineKey(OFFICIAL, id);
  const cands = [
    { venue: 'firsto', collection: OFFICIAL, tokenId: 1n, costWei: 455n * 10n ** 15n, key: k(1) }, // 10 算力，0.0455 / 单位
    { venue: 'seaport', collection: OFFICIAL, tokenId: 1n, costWei: 450n * 10n ** 15n, key: k(1) }, // 同一台，Seaport 更便宜
    { venue: 'official', collection: OFFICIAL, tokenId: 2n, costWei: 3_400n * 10n ** 15n, key: k(2) }, // 72 算力，0.0472
    { venue: 'official', collection: OFFICIAL, tokenId: 3n, costWei: 100n * 10n ** 15n, key: k(3) }, // 2 算力，不收
    { venue: 'official', collection: OFFICIAL, tokenId: 4n, costWei: 450n * 10n ** 15n, key: k(4) }, // 刚开挖，不收
    { venue: 'seaport', collection: OFFICIAL, tokenId: 5n, costWei: 15_000n * 10n ** 15n, key: k(5) }, // 344 算力，超过 300
  ];
  const miners = new Map([
    [k(1), { ok: true, weight: 10n, mining: true, verified: true, since: BigInt(NOW - 30 * 86_400) }],
    [k(2), { ok: true, weight: 72n, mining: true, verified: true, since: BigInt(NOW - 30 * 86_400) }],
    [k(3), { ok: true, weight: 2n, mining: true, verified: true, since: BigInt(NOW - 30 * 86_400) }],
    [k(4), { ok: true, weight: 10n, mining: true, verified: true, since: BigInt(NOW - 86_400) }],
    [k(5), { ok: true, weight: 344n, mining: true, verified: true, since: BigInt(NOW - 30 * 86_400) }],
  ]);
  const base = { miners, okCollection: () => true, now: NOW, minAge: 7 * 86_400, budgetWei: 10n * E18 };
  const picked = pickMachines(cands, { ...base, maxWeiPerWeight: E18 });
  assert.deepEqual(picked.map((p) => `${p.venue}:${p.tokenId}`), ['seaport:1', 'official:2']);
  // 单价上限 0.046 BNB：只买 #1
  assert.deepEqual(pickMachines(cands, { ...base, maxWeiPerWeight: 46n * 10n ** 15n }).map((p) => p.tokenId), [1n]);
  // 合集不认的不买
  assert.deepEqual(pickMachines(cands, { ...base, maxWeiPerWeight: E18, okCollection: () => false }), []);
});

test('seaportOrder 按 API 的 parameters 和 signature 组成 AdvancedOrder（整单 1/1）', () => {
  const o = seaportOrder({
    status: 'ACTIVE',
    signature: '0xabcd',
    parameters: {
      offerer: '0x78e3a21209a35FD6BD101eb9eA0f44D00EcE2F88',
      zone: '0x0000000000000000000000000000000000000000',
      offer: [{ token: OFFICIAL, itemType: 2, endAmount: '1', startAmount: '1', identifierOrCriteria: '8340' }],
      consideration: [
        { token: '0x0000000000000000000000000000000000000000', itemType: 0, endAmount: '3164337029702970300', startAmount: '3164337029702970300', recipient: '0x78e3a21209a35FD6BD101eb9eA0f44D00EcE2F88', identifierOrCriteria: '0' },
        { token: '0x0000000000000000000000000000000000000000', itemType: 0, endAmount: '31643370297029703', startAmount: '31643370297029703', recipient: '0xf0972A5ee0FD4054159A8c7177e59126ef478dA9', identifierOrCriteria: '0' },
      ],
      orderType: 0,
      startTime: 1792668741,
      endTime: 1793273541,
      zoneHash: '0x0000000000000000000000000000000000000000000000000000000000000000',
      salt: '0x00000000000000000000000000000000000000000000000066e82ff5a011fc4b',
      conduitKey: '0x0000000000000000000000000000000000000000000000000000000000000000',
      totalOriginalConsiderationItems: 2,
    },
  });
  assert.equal(o.numerator, 1n);
  assert.equal(o.parameters.offer[0].identifierOrCriteria, 8340n);
  assert.equal(o.parameters.consideration.reduce((s, c) => s + c.startAmount, 0n), 3_195_980_400_000_000_003n);
  assert.equal(o.parameters.salt, 0x66e82ff5a011fc4bn);
  assert.throws(() => seaportOrder({ status: 'FILLED', parameters: {} }));
});

test('tapemarketListingBody 按 V2-ABI 的格式组主板挂单库的 Seaport 卖单', () => {
  const { tapemarketListingBody } = M;
  const b = tapemarketListingBody({ vault: '0x1111111111111111111111111111111111111111', collection: OFFICIAL, tokenId: 8340n, net: 3_000n, fee: 30n, feeRecipient: '0xf0972A5ee0FD4054159A8c7177e59126ef478dA9', salt: 5n, startTime: 100n, endTime: 200n });
  assert.equal(b.assetStandard, 'ERC721');
  assert.equal(b.parameters.offerer, '0x1111111111111111111111111111111111111111');
  assert.equal(b.parameters.offer[0].identifierOrCriteria, '8340');
  assert.deepEqual(b.parameters.consideration.map((c) => c.startAmount), ['3000', '30']);
  assert.equal(b.parameters.totalOriginalConsiderationItems, 2);
  assert.equal(b.parameters.salt, `0x${'0'.repeat(63)}5`);
  assert.equal(b.signature, '0x');
  // 手续费为 0 时只有一项对价
  assert.equal(tapemarketListingBody({ vault: '0x1', collection: OFFICIAL, tokenId: 1n, net: 1n, fee: 0n, feeRecipient: '0x2', salt: 1n, startTime: 1n, endTime: 2n }).parameters.totalOriginalConsiderationItems, 1);
});

test('floorTarget：排除自己的挂单，取最低那张再低 0.1%，按官方市场手续费和 98% 余量折回 BEM', () => {
  const k = (id) => machineKey(OFFICIAL, id);
  const miner = (w) => ({ ok: true, weight: w, mining: true, verified: true, since: BigInt(NOW - 30 * 86_400) });
  const cands = [
    { venue: 'seaport', collection: OFFICIAL, tokenId: 1n, costWei: 455n * 10n ** 15n, key: k(1) }, // 0.0455 / 单位
    { venue: 'official', collection: OFFICIAL, tokenId: 2n, costWei: 440n * 10n ** 15n, key: k(2), seller: '0xvault' }, // 我们自己的挂单库
    { venue: 'firsto', collection: OFFICIAL, tokenId: 3n, costWei: 900n * 10n ** 15n, key: k(3) }, // 20 算力，0.045 / 单位
  ];
  const miners = new Map([[k(1), miner(10n)], [k(2), miner(10n)], [k(3), miner(20n)]]);
  const r = M.floorTarget(cands, { miners, okCollection: () => true, ownVault: (c) => c.seller === '0xvault', now: NOW, minAge: 7 * 86_400, bemPerBnb: 28n * 10n ** 8n });
  assert.equal(r.best.tokenId, 3n);
  // 0.045 × 0.999 × 0.99 × 0.98 = 0.0436127... BNB；× 28 BEM / BNB
  const expectBnb = (((45n * 10n ** 15n * 9_990n) / 10_000n) * 9_900n / 10_000n) * 9_800n / 10_000n;
  assert.equal(r.floorBem, (expectBnb * 28n * 10n ** 8n) / 10n ** 18n);
  assert.equal(M.floorTarget([], { miners, okCollection: () => true, ownVault: () => false, now: NOW, minAge: 0, bemPerBnb: 1n }), null);
});

test('offerFor：整合集 WBNB 出价，净到手扣掉卖方手续费，合集 / 代币不对的不要', () => {
  const WBNB = '0xf4ecd4006faa8d52041c69a8781b76cf54a3ad32';
  const o = {
    orderHash: '0xabc',
    signature: '0x',
    parameters: {
      offerer: '0x9219f75d863e54a066be9f713061ff64302fa8de',
      zone: '0x0000000000000000000000000000000000000000',
      offer: [{ itemType: '1', token: WBNB, identifierOrCriteria: '0', startAmount: '7135158000000000', endAmount: '7135158000000000' }],
      consideration: [
        { itemType: '4', token: OFFICIAL, identifierOrCriteria: '0', startAmount: '1', endAmount: '1', recipient: '0x9219f75d863e54a066be9f713061ff64302fa8de' },
        { itemType: '1', token: WBNB, identifierOrCriteria: '0', startAmount: '71351580000000', endAmount: '71351580000000', recipient: '0x9219f75d863e54a066be9f713061ff64302fa8de' },
      ],
      orderType: '0',
      startTime: String(NOW - 100),
      endTime: String(NOW + 86_400),
      zoneHash: `0x${'0'.repeat(64)}`,
      salt: '1',
      conduitKey: `0x${'0'.repeat(64)}`,
      totalOriginalConsiderationItems: '2',
    },
  };
  const r = M.offerFor(o, { collection: OFFICIAL, tokenId: 7n, wbnb: WBNB, now: NOW });
  assert.equal(r.net, 7_135_158_000_000_000n - 71_351_580_000_000n);
  assert.deepEqual(r.cr, [{ orderIndex: 0n, side: 1, index: 0n, identifier: 7n, criteriaProof: [] }]);
  assert.equal(M.offerFor(o, { collection: BEHEMOTH, tokenId: 7n, wbnb: WBNB, now: NOW }), null);
  assert.equal(M.offerFor(o, { collection: OFFICIAL, tokenId: 7n, wbnb: '0x0000000000000000000000000000000000000001', now: NOW }), null);
  assert.equal(M.offerFor(o, { collection: OFFICIAL, tokenId: 7n, wbnb: WBNB, now: NOW + 86_400 }), null); // 快过期
});

import { parseSignedAsks, FIRSTO_SIGNED_ASK_V2, OFFICIAL_MACHINES } from './firsto.js';

test('signed ask V2 → MarketTrader.buyFromSignedAsk candidate; the fee must match exactly (rule 6.37)', () => {
  const NOW = 1_790_000_000;
  // 2026-10-25 真实卖单 #14511 的格式
  const row = (extra = {}, weight = '61') => ({
    mining: { status: 'verified', weight, estimated24hAtomic: '27456985' },
    bestAsk: {
      status: 'open', venue: 'firsto', buyerCostWei: '2706800000000000000',
      execution: { kind: 'signed_ask', chainId: 56, exchange: FIRSTO_SIGNED_ASK_V2.toLowerCase(), collection: OFFICIAL_MACHINES, maker: '0xc2e9ae3ee72a276232a17ff7679837080cfc741e', tokenId: '14511', nonce: '5607', priceWei: '2680000000000000000', expiry: String(NOW + 30 * 86_400), payoutRecipient: '0xc2e9ae3ee72a276232a17ff7679837080cfc741e', feeBps: 100, feeEpoch: '1', schemaVersion: '2', signature: '0xb11b', ...extra },
    },
  });
  const [a] = parseSignedAsks({ rows: [row()] }, { now: NOW });
  assert.equal(a.buyerCostWei, 2_706_800_000_000_000_000n);
  assert.equal(a.ask.price, 2_680_000_000_000_000_000n);
  assert.equal(a.ask.feeBps, 100);
  assert.equal(a.ask.schemaVersion, 2);
  const [c] = M.firstoSignedCandidates([a]);
  assert.equal(c.venue, 'firstoSigned');
  assert.equal(c.seller, a.maker);
  assert.equal(c.costWei, a.buyerCostWei);
  // 含费价对不上、快过期、算力超范围、批量卖单：都不算
  assert.equal(parseSignedAsks({ rows: [row({ priceWei: '2680000000000000001' })] }, { now: NOW }).length, 0);
  assert.equal(parseSignedAsks({ rows: [row({ expiry: String(NOW + 60) })] }, { now: NOW }).length, 0);
  assert.equal(parseSignedAsks({ rows: [row({}, '318')] }, { now: NOW }).length, 0);
  assert.equal(parseSignedAsks({ rows: [row({ kind: 'circuit_batch_ask' })] }, { now: NOW }).length, 0);
});

test('markets: listings() struct → own vault only when board is set (fork rehearsal 2026-10-26)', async () => {
  const { isVaultListing } = await import('./markets.js');
  const zero = '0x0000000000000000000000000000000000000000';
  assert.equal(isVaultListing({ board: zero, index: 0n }), false, 'an ordinary seller (empty struct) is not our vault');
  assert.equal(isVaultListing({ board: '0x6BA15812fBD72D2134f34deB5D3514bb7deB6129', index: 3n }), true);
  assert.equal(isVaultListing(null), false, 'read failed: not ours');
  assert.equal(isVaultListing([zero, 0n]), false);
  assert.equal(isVaultListing(['0x6BA15812fBD72D2134f34deB5D3514bb7deB6129', 0n]), true);
});


test('markets: hourly BEM cap (80 BEM ≈ 10% of market volume, user decision 2026-10-26)', async () => {
  const { bemRoom } = await import('./markets.js');
  const B = 10n ** 8n;
  const cap = 80n * B;
  // 窗口里没换过：单笔超过上限也放行一笔（87 BEM 的矿机）
  assert.equal(bemRoom([], 10_000, cap).allows(87n * B), true);
  // 换过 50 BEM：再 30 可以，31 不行
  const r = bemRoom([{ at: 9_000, bem: String(50n * B) }], 10_000, cap);
  assert.equal(r.used, 50n * B);
  assert.equal(r.allows(30n * B), true);
  assert.equal(r.allows(31n * B), false);
  // 1 小时以前的不算
  const old = bemRoom([{ at: 6_000, bem: String(80n * B) }, { at: 9_500, bem: String(10n * B) }], 10_000, cap);
  assert.equal(old.flow.length, 1);
  assert.equal(old.used, 10n * B);
  // 0 = 不限
  assert.equal(bemRoom([{ at: 9_999, bem: String(1000n * B) }], 10_000, 0n).allows(1000n * B), true);
});

test('subsidyHold：月局回馈桶里还有钱时留一台最小算力的预算和最后一个名额，不触发买满', async () => {
  const { subsidyHold, SUBSIDY_MIN_WEI } = await import('./markets.js');
  const B = 10n ** 8n;
  const price = (137n * B) / 100n; // 每单位算力 1.37 BEM
  const start = 1_000_000n;
  const base = { now: Number(start) + 600, startedAt: start, prepEnd: start + 3n * 86_400n, bucketWei: 10n ** 18n, price, minWeight: 10n, count: 3n, maxMachines: 100n };
  const h = subsidyHold(base);
  assert.equal(h.hold, true);
  assert.equal(h.reserveBem, (price * 10n * 11_000n) / 10_000n, '一台最小算力矿机的钱 + 10%');
  assert.equal(h.slotsLeft, 96n, '留出最后一个名额');
  // 停止等待的四种情况：照常买满（不留钱、名额全给）
  const free = (over, reason) => {
    const r = subsidyHold({ ...base, ...over });
    assert.equal(r.hold, false, reason);
    assert.equal(r.reserveBem, 0n);
    assert.equal(r.reason, reason);
    return r;
  };
  free({ bucketWei: SUBSIDY_MIN_WEI - 1n }, 'bucket empty');
  assert.equal(subsidyHold({ ...base, bucketWei: SUBSIDY_MIN_WEI }).hold, true, '正好 0.01 BNB 还要等');
  free({ now: Number(start) + 86_400 }, 'waited 24 h');
  free({ now: Number(start) + 3_600, prepEnd: start + 10_800n }, 'preparation ends soon'); // 准备期被提前到 3 小时（举例），离结束正好 2 小时
  assert.equal(subsidyHold({ ...base, now: Number(start) + 3_599, prepEnd: start + 10_800n }).hold, true);
  assert.equal(free({ count: 99n }, 'last slot').slotsLeft, 1n);
  // 测试网 288 倍：24 小时 → 300 秒，2 小时 → 25 秒
  assert.equal(subsidyHold({ ...base, now: Number(start) + 299, prepEnd: start + 900n, divisor: 288 }).hold, true);
  assert.equal(subsidyHold({ ...base, now: Number(start) + 300, prepEnd: start + 900n, divisor: 288 }).reason, 'waited 24 h');
  assert.equal(subsidyHold({ ...base, now: Number(start) + 100, prepEnd: start + 125n, divisor: 288 }).reason, 'preparation ends soon');
});
