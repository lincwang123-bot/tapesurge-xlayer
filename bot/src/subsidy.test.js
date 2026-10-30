// 月局等首批回馈的接线：用假的链上读取跑一遍 marketTrade 的买入部分，
// 确认在回馈名单里、桶里有钱的月局会先领回馈，别的局不领，而且整轮不会因为新逻辑报错。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { initAbi } from './abi.js';
import { State } from './state.js';
import { marketTrade } from './tasks/marketTrade.js';

const B = 10n ** 8n;
const MONTH = '0x00000000000000000000000000000000000000a1';
const STD = '0x00000000000000000000000000000000000000b2';
const ZERO = '0x0000000000000000000000000000000000000000';

function fakeCtx({ bucketWei, ranked = MONTH }) {
  const sends = [];
  const reads = [];
  const now = 2_000_000;
  const values = {
    state: 2n,
    isPurchasing: true,
    quoteBemOut: 22n * B,
    SLIPPAGE_BPS: 200n,
    boardConfig: { minMachineWeight: 10n, maxMachines: 100n },
    rewardBucket: bucketWei,
    startedAt: BigInt(now - 600),
    prepEnd: BigInt(now + 3 * 86_400),
    buyPrice: (137n * B) / 100n,
    budget: 100n * B,
    machineCount: 0n,
  };
  const pub = {
    readContract: async ({ address, functionName, args }) => {
      reads.push({ address, functionName, args });
      if (functionName === 'rewardBoard') return args[0] === 1n ? ranked : ZERO;
      if (!(functionName in values)) throw new Error(`unexpected read ${functionName}`);
      return values[functionName];
    },
  };
  const ctx = {
    cfg: { mainnet: false, chainId: 97, firstoEverySec: 300, firstoMaxPerTick: 10, bemHourlyCap: 0n, swapTradeMarginBps: 10n },
    dep: { marketTrader: '0x00000000000000000000000000000000000000c3', oracle: '0x00000000000000000000000000000000000000c4', hub: '0x00000000000000000000000000000000000000c5', splitter: '0x00000000000000000000000000000000000000c6', monthFactory: '0x00000000000000000000000000000000000000c7', timeDivisor: 1 },
    pub,
    sender: { send: async (label, address, abi, fn, args, opts) => (sends.push({ label, address, fn, args, opts }), { sent: false, reason: 'TooSoon' }) },
    state: new State('/nonexistent/tapesurge-test-state.json'),
    every: (s) => s,
    now,
    summary: {},
  };
  return { ctx, sends, reads };
}

test('等首批回馈：回馈名单里的月局、桶里有钱时，买矿机前先领它那一桶（名次 1），走防夹子节点', async () => {
  initAbi('bsc', 'v2');
  const { ctx, sends, reads } = fakeCtx({ bucketWei: 10n ** 18n });
  await marketTrade(ctx, [{ kind: 'std', address: STD }, { kind: 'month', address: MONTH }]);
  const claims = sends.filter((s) => s.fn === 'claimReward');
  assert.equal(claims.length, 1, '只给月局领一次');
  assert.deepEqual(claims[0].args, [1n]);
  assert.equal(claims[0].address, ctx.dep.splitter);
  assert.equal(claims[0].opts.private, true);
  assert.ok(reads.some((r) => r.functionName === 'boardConfig'), '读模板参数（最小算力、台数上限）');
  assert.ok(reads.some((r) => r.functionName === 'prepEnd' && r.address === MONTH));
});

test('等首批回馈：桶里不到 0.01 BNB、或者月局不在名单里，不领回馈，照常买', async () => {
  initAbi('bsc', 'v2');
  for (const opt of [{ bucketWei: 10n ** 16n - 1n }, { bucketWei: 10n ** 18n, ranked: STD }]) {
    const { ctx, sends } = fakeCtx(opt);
    await marketTrade(ctx, [{ kind: 'month', address: MONTH }]);
    assert.equal(sends.filter((s) => s.fn === 'claimReward').length, 0);
  }
});
