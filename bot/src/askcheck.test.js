import { test } from 'node:test';
import assert from 'node:assert/strict';
import { decodeFunctionData, parseAbi } from 'viem';
import { askCall, askCandidates, supportedSellers, verifiedAskRows, withMoreAskPages, SIM_BUYER } from './askcheck.js';
import { ASKS_URL, FIRSTO_ASK_EXCHANGE, FIRSTO_SIGNED_ASK_V2, OFFICIAL_MACHINES, asksPageUrl } from './firsto.js';

const E18 = 10n ** 18n;
const maker = (n) => `0x${n.toString(16).padStart(40, '0')}`;
const batch = (tokenId, m, costWei, extra = {}) => ({
  mining: { status: 'verified', weight: '100', estimated24hAtomic: '45000000' },
  bestAsk: {
    buyerCostWei: String(costWei),
    execution: {
      kind: 'circuit_batch_ask', chainId: 56, exchange: FIRSTO_ASK_EXCHANGE, collection: OFFICIAL_MACHINES, maker: m, tokenId: String(tokenId),
      merkleRoot: `0x${'11'.repeat(32)}`, batchNonce: '7', expiry: '1795507451', payoutRecipient: m, feeBps: 100, feeEpoch: '1', schemaVersion: '1',
      priceWei: String((costWei * 100n) / 101n), leafIndex: '0', merkleProof: [`0x${'22'.repeat(32)}`], signature: '0x1234', ...extra,
    },
  },
});

test('askcheck: batch ask → 0x20b36528 call paying the buyer cost', () => {
  const c = askCall(batch(5055, maker(1), 2n * E18));
  assert.equal(c.to, FIRSTO_ASK_EXCHANGE);
  assert.equal(c.data.slice(0, 10), '0x20b36528');
  assert.equal(c.value, 2n * E18);
  assert.ok(c.data.toLowerCase().includes(SIM_BUYER.slice(2).toLowerCase()), 'NFT goes to the simulated buyer');
});

test('askcheck: signed ask V2 → fillSignedAsk', () => {
  const r = batch(14439, maker(2), 3n * E18, { kind: 'signed_ask', exchange: FIRSTO_SIGNED_ASK_V2, nonce: '99', schemaVersion: '2' });
  const c = askCall(r);
  assert.equal(c.to, FIRSTO_SIGNED_ASK_V2);
  const abi = parseAbi(['function fillSignedAsk((address maker, address collection, uint256 tokenId, uint256 nonce, uint128 price, uint64 expiry, address payoutRecipient, uint16 feeBps, uint256 feeEpoch, uint16 schemaVersion) ask, bytes signature, address nftRecipient) payable']);
  const d = decodeFunctionData({ abi, data: c.data });
  assert.equal(d.args[0].tokenId, 14439n);
  assert.equal(d.args[0].nonce, 99n);
  assert.equal(d.args[2], SIM_BUYER);
});

test('askcheck: unknown exchange, collection or chain is never counted', () => {
  assert.equal(askCall(batch(1, maker(1), E18, { exchange: maker(9) })), null);
  assert.equal(askCall(batch(1, maker(1), E18, { collection: maker(9) })), null);
  assert.equal(askCall(batch(1, maker(1), E18, { chainId: 97 })), null);
});

test('askcheck: cheapest listing per seller, failed seller skipped, stop at three sellers', async () => {
  // 卖家 1：两条最便宜的（第一条模拟失败 → 卖家 1 本小时不算）；卖家 2、3、4、5 各一条
  const json = {
    rows: [
      batch(1, maker(1), 4n * E18), batch(2, maker(1), 41n * E18 / 10n),
      batch(3, maker(2), 42n * E18 / 10n), batch(4, maker(3), 43n * E18 / 10n), batch(5, maker(2), 44n * E18 / 10n),
      batch(6, maker(4), 45n * E18 / 10n), batch(7, maker(5), 46n * E18 / 10n),
    ],
  };
  assert.equal(askCandidates(json)[0].row.bestAsk.execution.tokenId, '1');
  const calls = [];
  const pub = {
    call: async ({ data, stateOverride }) => {
      assert.equal(stateOverride[0].address, SIM_BUYER);
      calls.push(data);
      if (data.includes((1).toString(16).padStart(64, '0') + (100n * 4n * E18 / 101n).toString(16).padStart(64, '0'))) throw new Error('execution reverted: NotOwner');
    },
  };
  const v = await verifiedAskRows(pub, json);
  assert.deepEqual(v.rows.map((r) => r.bestAsk.execution.tokenId), ['3', '4', '6']);
  assert.equal(v.checked, 4); // 1（失败）、3、4、6；卖家 1 的第二条和卖家 2 的第二条都不核对
  assert.equal(v.rejected.length, 1);
  assert.match(v.rejected[0].reason, /NotOwner/);
});

test('askcheck: fewer than three verifiable sellers', async () => {
  const json = { rows: [batch(1, maker(1), E18 * 4n), batch(2, maker(2), E18 * 5n), batch(3, maker(3), E18 * 6n)] };
  const pub = { call: async ({ data }) => { if (data.length > 0 && calls++ === 1) throw new Error('execution reverted'); } };
  let calls = 0;
  const v = await verifiedAskRows(pub, json);
  assert.equal(v.rows.length, 2);
});

test('askcheck: candidates follow the board purchase rules, unsupported listings cost no check', async () => {
  const NOW = 1_790_000_000;
  const small = { ...batch(10, maker(10), E18), mining: { status: 'verified', weight: '7', estimated24hAtomic: '3150000' } }; // 7 H：主板不收
  const expiring = batch(11, maker(11), 2n * E18, { expiry: String(NOW + 300) }); // 不到 10 分钟就过期
  const official = batch(12, maker(12), 3n * E18, { kind: undefined, exchange: maker(99) }); // 机器人不会模拟的来源
  const json = { rows: [small, expiring, official, batch(1, maker(1), 4n * E18), batch(2, maker(2), 41n * E18 / 10n), batch(3, maker(3), 42n * E18 / 10n)] };
  assert.deepEqual(askCandidates(json, { now: NOW }).map((c) => c.row.bestAsk.execution.tokenId), ['12', '1', '2', '3']);
  const pub = { call: async () => {} };
  const v = await verifiedAskRows(pub, json, { now: NOW });
  assert.deepEqual(v.rows.map((r) => r.bestAsk.execution.tokenId), ['1', '2', '3']);
  assert.equal(v.checked, 3, 'the unsupported listing did not use a check');
  assert.equal(v.skipped, 1);
});

import { simulateCandidate } from './askcheck.js';

test('askcheck: the lowest listing used for "stay first" is checked on chain (rule 6.37)', async () => {
  const calls = [];
  const pub = {
    call: async (x) => { calls.push(x); if (x.to === OFFICIAL_MARKET && x.value === 1n) throw new Error('execution reverted: not listed'); },
    readContract: async ({ args }) => (args[0] === 5n ? '0x00000000000000000000000000000000000000aa' : '0x00000000000000000000000000000000000000bb'),
  };
  const f = batch(5055, maker(1), 2n * E18);
  const e = f.bestAsk.execution;
  const firstoCand = { venue: 'firsto', costWei: 2n * E18, order: { header: { maker: e.maker, merkleRoot: e.merkleRoot, batchNonce: 7n, expiry: 1n, payoutRecipient: e.maker, feeBps: 100n, feeEpoch: 1n, schemaVersion: 1n }, leaf: { maker: e.maker, collection: e.collection, tokenId: 5055n, priceWei: 1n, payoutRecipient: e.maker, feeBps: 100n, feeEpoch: 1n, batchNonce: 7n, leafIndex: 0n, schemaVersion: 1n }, merkleProof: [], signature: '0x12' } };
  assert.deepEqual(await simulateCandidate(pub, firstoCand), { ok: true });
  assert.equal(calls[0].to, FIRSTO_ASK_EXCHANGE);
  assert.equal(calls[0].data.slice(0, 10), '0x20b36528');
  assert.equal(calls[0].value, 2n * E18);
  assert.equal(calls[0].stateOverride[0].address, SIM_BUYER);
  assert.equal((await simulateCandidate(pub, { venue: 'official', listingId: 9n, costWei: 1n }, { officialMarket: OFFICIAL_MARKET })).ok, false);
  assert.equal((await simulateCandidate(pub, { venue: 'official', listingId: 9n, costWei: 2n }, { officialMarket: OFFICIAL_MARKET })).ok, true);
  assert.equal((await simulateCandidate(pub, { venue: 'seaport', collection: OFFICIAL_MACHINES, tokenId: 5n, seller: '0x00000000000000000000000000000000000000AA' })).ok, true);
  assert.match((await simulateCandidate(pub, { venue: 'seaport', collection: OFFICIAL_MACHINES, tokenId: 6n, seller: '0x00000000000000000000000000000000000000AA' })).reason, /不在卖家手里/);
});
const OFFICIAL_MARKET = '0x6feEbbEbC07BcB90bd1Ac8b0CF9BaA4f0fF2B46f';

// 2026-10-27 主网：一个卖家挂满了最便宜的第一页，第二页才有别的卖家
const signed = (tokenId, m, costWei) => batch(tokenId, m, costWei, { kind: 'signed_ask', exchange: FIRSTO_SIGNED_ASK_V2, nonce: String(tokenId) });
const flooded = (from, n, m, base) => Array.from({ length: n }, (_, i) => signed(from + i, m, base + BigInt(i) * 10n ** 15n));

test('askcheck: one seller filling page 1 → read page 2 of the same view', async () => {
  const first = { viewId: 'v1', totalPages: 14, rows: flooded(1, 50, maker(1), 2n * E18) };
  assert.equal(supportedSellers(first), 1);
  const asked = [];
  const pages = { 2: { viewId: 'v1', rows: [...flooded(100, 10, maker(1), 21n * E18 / 10n), signed(200, maker(2), 22n * E18 / 10n), signed(201, maker(3), 22n * E18 / 10n), signed(202, maker(4), 23n * E18 / 10n), signed(203, maker(5), 23n * E18 / 10n)] } };
  const json = await withMoreAskPages(first, async (p) => { asked.push(p); return pages[p]; });
  assert.deepEqual(asked, [2]); // 第二页已凑够 5 个卖家，不再读第三页
  assert.equal(json.rows.length, 64);
  assert.equal(json.pagesRead, 2);
  assert.equal(supportedSellers(json), 5);
});

test('askcheck: no extra pages when page 1 already has enough sellers, and stop at maxPages', async () => {
  const many = { viewId: 'v1', totalPages: 9, rows: [1, 2, 3, 4, 5].map((m) => signed(m, maker(m), 2n * E18)) };
  assert.equal(await withMoreAskPages(many, async () => assert.fail('should not page')), many);
  const asked = [];
  const json = await withMoreAskPages({ viewId: 'v1', totalPages: 9, rows: flooded(1, 5, maker(1), 2n * E18) }, async (p) => { asked.push(p); return { viewId: 'v1', rows: flooded(p * 100, 5, maker(1), 3n * E18) }; });
  assert.deepEqual(asked, [2, 3]);
  assert.equal(json.pagesRead, 3);
});

test('askcheck: paging stops on failure, a different snapshot, or a single page', async () => {
  const first = { viewId: 'v1', totalPages: 5, rows: flooded(1, 5, maker(1), 2n * E18) };
  assert.equal((await withMoreAskPages(first, async () => { throw new Error('HTTP 400'); })).rows.length, 5);
  assert.equal((await withMoreAskPages(first, async () => ({ viewId: 'v2', rows: [signed(9, maker(2), E18)] }))).rows.length, 5);
  const single = { ...first, totalPages: 1 };
  assert.equal(await withMoreAskPages(single, async () => assert.fail('single page')), single);
  assert.equal(asksPageUrl('v60420-p1:ab', 2), `${ASKS_URL}&page=2&viewId=v60420-p1%3Aab`);
  assert.match(ASKS_URL, /pageSize=50$/);
});
