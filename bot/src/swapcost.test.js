import { test } from 'node:test';
import assert from 'node:assert/strict';
import { costBps, exactOutputPath, feedBps, quoteSwapCost, feedSwapBps, WBNB, USDT } from './swapcost.js';

const E18 = 10n ** 18n;
const BEM = '0x5ce033B2bFCa3Af30b3e8C8457DeaF776A8b695a';

test('swap cost: bps relative to TWAP, rounded up; negative when spot beats TWAP', () => {
  assert.equal(costBps(10_100n, 10_000n), 100n);
  assert.equal(costBps(20_201n, 20_000n), 101n); // 100.5 向上取整
  assert.equal(costBps(9_950n, 10_000n), -50n);
  assert.throws(() => costBps(1n, 0n));
});

test('swap cost: feed value = actual + 0.25%, clamped to 1.2%–2%', () => {
  assert.equal(feedBps(80n), 120n);
  assert.equal(feedBps(110n), 135n);
  assert.equal(feedBps(190n), 200n);
  assert.equal(feedBps(-30n), 120n);
  assert.equal(feedBps(110n, { marginBps: 0n, minBps: 0n, maxBps: 1_000n }), 110n);
});

test('swap cost: exact-output paths run from output token to input token', () => {
  const hex = (a) => a.slice(2).toLowerCase();
  const bnbOut = exactOutputPath('bnbOut', BEM).toLowerCase();
  assert.equal(bnbOut, `0x${hex(WBNB)}000064${hex(USDT)}002710${hex(BEM)}`);
  const bemOut = exactOutputPath('bemOut', BEM).toLowerCase();
  assert.equal(bemOut, `0x${hex(BEM)}002710${hex(USDT)}000064${hex(WBNB)}`);
});

function fakeCtx({ mainnet = true, quoterIn, bemPerBnb = 3n * 10n ** 8n, fail = false } = {}) {
  const alerts = [];
  return {
    alerts,
    cfg: { mainnet, network: 'bsc', swapCostBps: 150n, swapFeed: { marginBps: 25n, minBps: 120n, maxBps: 200n } },
    dep: { bem: BEM, oracle: '0x0000000000000000000000000000000000000001' },
    alert: { send: async (k, msg) => alerts.push(k) },
    pub: {
      readContract: async ({ functionName, args }) => {
        if (functionName === 'quoteExactOutput') {
          if (fail) throw new Error('rpc down');
          return [quoterIn(args[1]), [], [], 0n];
        }
        if (functionName === 'quoteBemOut') return (args[0] * bemPerBnb) / E18;
        throw new Error(functionName);
      },
    },
  };
}

test('swap cost: mainnet quotes each order against the TWAP', async () => {
  // 买入：要 1 BNB，TWAP 折 3 BEM，实际要付 3.033 BEM → 1.1%
  const buy = await quoteSwapCost(fakeCtx({ quoterIn: () => 303_300_000n }), 'bnbOut', E18);
  assert.deepEqual(buy, { rawBps: 110n, amountIn: 303_300_000n, quoted: true });
  // 卖出：要 3 BEM，TWAP 折 1 BNB，实际要付 1.0125 BNB → 1.25%；报价用 1.5%
  const sell = await feedSwapBps(fakeCtx({ quoterIn: () => (E18 * 10_125n) / 10_000n }), 'bemOut', 300_000_000n);
  assert.equal(sell.rawBps, 125n);
  assert.equal(sell.bps, 150n);
});

test('swap cost: testnet and quoter failures fall back to SWAP_COST_BPS', async () => {
  const t = await feedSwapBps(fakeCtx({ mainnet: false, quoterIn: () => 0n }), 'bnbOut', E18);
  assert.deepEqual(t, { rawBps: 150n, amountIn: null, quoted: false, bps: 150n });
  const ctx = fakeCtx({ fail: true });
  const f = await feedSwapBps(ctx, 'bnbOut', E18);
  assert.equal(f.bps, 150n);
  assert.equal(f.quoted, false);
  assert.deepEqual(ctx.alerts, ['swap:quoter']);
});
