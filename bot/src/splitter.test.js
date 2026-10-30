// 分账合约的回购 / 首批回馈：按合约的 lastSwapAt + minSwapInterval 到点就调用（2026-10-26），不按机器人自己的计时。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { initAbi } from './abi.js';
import { State } from './state.js';
import { SPLITTER_RETRY_SEC, splitter, swapDue } from './tasks/system.js';

test('swapDue：区块时间 ≥ lastSwapAt + 间隔才到点（和合约 TooSoon 的判断一致）', () => {
  assert.equal(swapDue(10_000, 6_400n, 3_600n), true);
  assert.equal(swapDue(9_999, 6_400n, 3_600n), false, '差 1 秒也不行');
  assert.equal(swapDue(1, 0n, 3_600n), false, '合约部署后第一个小时（lastSwapAt = 0）也要等');
  assert.equal(swapDue(3_600, 0n, 3_600n), true);
});

function fakeCtx({ now, last, buckets = [0n, 0n, 0n, 0n, 0n], result = { sent: true, ok: true } }) {
  const sends = [];
  const values = { minSwapInterval: 3_600n, foundation: '0x00000000000000000000000000000000000000f1', project: '0x00000000000000000000000000000000000000f2', owedBnb: 0n };
  const pub = {
    readContract: async ({ functionName, args }) => {
      if (functionName === 'lastSwapAt') return last[Number(args[0])];
      if (functionName === 'rewardBucket') return buckets[Number(args[0]) - 1];
      if (!(functionName in values)) throw new Error(`unexpected read ${functionName}`);
      return values[functionName];
    },
  };
  const ctx = {
    dep: { splitter: '0x00000000000000000000000000000000000000c6' },
    pub,
    sender: { send: async (label, address, abi, fn, args, opts) => (sends.push({ fn, args, opts }), result) },
    state: new State('/nonexistent/tapesurge-test-state.json'),
    every: (s) => s,
    now,
  };
  return { ctx, sends };
}

test('分账：回购到点就调用，没到点不调用（不再按机器人自己的 1 小时计时）', async () => {
  initAbi('bsc', 'v2');
  const last = [100_000n, 0n, 0n, 0n, 0n, 0n];
  const early = fakeCtx({ now: 103_599, last });
  await splitter(early.ctx);
  assert.equal(early.sends.filter((s) => s.fn === 'buyback').length, 0, '差 1 秒');
  const onTime = fakeCtx({ now: 103_600, last });
  await splitter(onTime.ctx);
  const bb = onTime.sends.filter((s) => s.fn === 'buyback');
  assert.equal(bb.length, 1);
  assert.equal(bb[0].opts.private, true, '经兑换：走防夹子节点');
});

test('分账：回馈桶空的不调用；有钱的桶按各自的 lastSwapAt 到点调用', async () => {
  initAbi('bsc', 'v2');
  const now = 200_000;
  // 第 1 桶到点、有钱；第 2 桶有钱但 10 分钟前刚领过；第 3 桶到点但空
  const last = [now, now - 3_600, now - 600, now - 7_200, 0n, 0n].map(BigInt);
  const { ctx, sends } = fakeCtx({ now, last, buckets: [10n ** 18n, 10n ** 18n, 0n, 0n, 0n] });
  await splitter(ctx);
  assert.deepEqual(sends.filter((s) => s.fn === 'claimReward').map((s) => s.args[0]), [1n]);
  assert.equal(sends.filter((s) => s.fn === 'buyback').length, 0, '回购 0 秒前刚做过');
});

test('分账：到点但模拟失败（池子空、主板没开局等）后，5 分钟内同一路不再试', async () => {
  initAbi('bsc', 'v2');
  const last = [0n, 0n, 0n, 0n, 0n, 0n];
  const { ctx, sends } = fakeCtx({ now: 1_000_000, last, buckets: [10n ** 18n, 0n, 0n, 0n, 0n], result: { sent: false, reason: 'BoardNotActive' } });
  await splitter(ctx);
  await splitter(ctx); // 下一轮（1 分钟后），合约状态没变
  assert.equal(sends.filter((s) => s.fn === 'buyback').length, 1);
  assert.equal(sends.filter((s) => s.fn === 'claimReward').length, 1);
  assert.equal(SPLITTER_RETRY_SEC, 300);
  // 5 分钟后再试
  for (const k of Object.keys(ctx.state.data.timers)) if (k.startsWith('splitterTry:')) ctx.state.data.timers[k] -= SPLITTER_RETRY_SEC;
  await splitter(ctx);
  assert.equal(sends.filter((s) => s.fn === 'buyback').length, 2);
  assert.equal(sends.filter((s) => s.fn === 'claimReward').length, 2);
});

test('X Layer 分账（回购 0%）：分账合约在晶体管合约名下有待取收入就调用 distribute，没有就不调用（协议费余额不算）', async () => {
  initAbi('xlayer');
  const run = async (pending) => {
    const { ctx, sends } = fakeCtx({ now: 50_000, last: [0n, 0n, 0n, 0n, 0n, 0n] });
    const read = ctx.pub.readContract;
    ctx.pub.readContract = async (q) => {
      if (q.functionName === 'owed') {
        assert.equal(q.address, ctx.dep.transistors);
        assert.equal(q.args[0], ctx.dep.splitter);
        return pending;
      }
      return q.functionName === 'buybackBps' || q.functionName === 'owedNative' ? 0n : read(q);
    };
    ctx.pub.getBalance = async () => 1_650_000_000_000_000n; // 晶体管合约里的协议费：不是分账合约的，不触发
    ctx.dep.transistors = '0x00000000000000000000000000000000000000d7';
    ctx.cfg = { network: 'xlayer', native: 'OKB' };
    await splitter(ctx);
    return sends.filter((s) => s.fn === 'distribute').length;
  };
  assert.equal(await run(6_000_000_000_000_000n), 1);
  assert.equal(await run(0n), 0);
  initAbi('bsc', 'v2');
});
