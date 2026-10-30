import { test } from 'node:test';
import assert from 'node:assert/strict';
import { encodeAbiParameters, parseAbiParameters } from 'viem';
import { readBid, verifiedBids } from './bidcheck.js';
import { FIRSTO_BID_EXCHANGE } from './firsto.js';

const E18 = 10n ** 18n;
const who = (n) => `0x${n.toString(16).padStart(40, '0')}`;
const FIELDS = parseAbiParameters('address, address, address, uint256, uint256, uint256, uint256, uint256, uint256');
// 链上状态：orderId → [出价人, 日产能价, 剩余预算, 状态]
const chain = (state) => ({
  call: async ({ to, data }) => {
    assert.equal(to, FIRSTO_BID_EXCHANGE);
    assert.equal(data.slice(0, 10), '0x3fbefb08');
    const id = BigInt(`0x${data.slice(10)}`);
    const s = state[String(id)];
    if (!s) throw new Error('execution reverted: 0x3e4ee9f6');
    return { data: encodeAbiParameters(FIELDS, [s[0], s[0], s[0], s[1], s[2], 0n, 0n, 100n, s[3]]) };
  },
});
const apiBid = (orderId, maker, dcp, budget) => ({ orderId: String(orderId), maker, state: 'active', dailyCapacityPriceWei: String(dcp), remainingBudgetWei: String(budget), minCircuitH: '0', maxCircuitH: '0', feeBps: 100 });

test('bidcheck: reads one bid from the unified bid contract (0x3fbefb08)', async () => {
  const b = await readBid(chain({ 1269: [who(1), 851n * E18 / 100n, E18 / 2n, 1n] }), 1269);
  assert.equal(b.maker.toLowerCase(), who(1));
  assert.equal(b.dailyCapacityPriceWei, String(851n * E18 / 100n));
  assert.equal(b.remainingBudgetWei, String(E18 / 2n));
  assert.equal(b.state, 'active');
  assert.equal((await readBid(chain({ 7: [who(1), E18, 0n, 2n] }), 7)).state, 'onchain-2');
});

test('bidcheck: chain data replaces the API; closed, emptied or reassigned bids and unknown ids are dropped', async () => {
  const ref = { refWeight: 10n, refDailyAtomic: 4_501_145n }; // 10 H，约 0.38 BNB
  const api = {
    bids: [
      apiBid(1, who(1), 9n * E18, E18), // 接口说有效，链上已关闭
      apiBid(2, who(2), 89n * E18 / 10n, E18), // 链上只剩 0.1 BNB：吃不下一台
      apiBid(3, who(3), 88n * E18 / 10n, E18), // 链上出价人不同
      apiBid(4, who(4), 87n * E18 / 10n, E18), // 链上没有这张
      apiBid(5, who(5), 86n * E18 / 10n, E18),
      apiBid(6, who(5), 85n * E18 / 10n, E18), // 同一出价人的第二张：不核对
      apiBid(7, who(7), 55n * E18 / 10n, 10n * E18),
      apiBid(8, who(8), 5n * E18, 10n * E18),
      apiBid(9, who(9), 4n * E18, 10n * E18), // 凑够 3 个出价人后不再核对
      apiBid(10, who(10), 9n * E18, E18 / 10n), // 接口里预算就不够：不占核对次数
    ],
  };
  const pub = chain({
    1: [who(1), 9n * E18, E18, 2n],
    2: [who(2), 89n * E18 / 10n, E18 / 10n, 1n],
    3: [who(33), 88n * E18 / 10n, E18, 1n],
    5: [who(5), 86n * E18 / 10n, E18, 1n],
    6: [who(5), 85n * E18 / 10n, E18, 1n],
    7: [who(7), 55n * E18 / 10n, 10n * E18, 1n],
    8: [who(8), 5n * E18, 9n * E18, 1n],
    9: [who(9), 4n * E18, 10n * E18, 1n],
  });
  const v = await verifiedBids(pub, api, ref);
  assert.deepEqual(v.bids.map((b) => b.orderId), ['5', '7', '8']);
  assert.equal(v.bids[2].remainingBudgetWei, String(9n * E18), 'chain values, not the API');
  assert.equal(v.checked, 7);
  assert.deepEqual(v.rejected.map((r) => r.orderId), ['1', '2', '3', '4']);
});
