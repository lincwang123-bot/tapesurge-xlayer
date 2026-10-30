// v2 月局多数集体清算（MonthExitGovernor）：读提案、计划、支持和投票。
// 流程：发布计划 → 持有人表态支持 → 支持 ≥ 10% 时任何人可以发起 24 小时投票（锁定转让）
//      → 截止后结算：赞成严格过半通过 → 等 24 小时 → 48 小时内任何人可以执行（矿机按计划价 7 天降到底价）。
import GovernorAbi from '../abi/MonthExitGovernor.json';
import MonthBoardAbi from '../abi/MonthBoard.json';
import { eventAbi, getLogsChunked, getLogsRecent } from './protocol.js';

export { GovernorAbi };

export const PHASE = ['None', 'Voting', 'Delay'];
export const CHOICE = { YES: 1, NO: 2, ABSTAIN: 3 };
const ZERO_HASH = '0x0000000000000000000000000000000000000000000000000000000000000000';

const CONSTS = ['MIN_SETTLE_AGE', 'VOTE_PERIOD', 'EXECUTION_DELAY', 'EXECUTION_WINDOW', 'FAIL_COOLDOWN', 'REPRICE_COOLDOWN', 'SUPPORT_BPS'];

/**
 * 一块月局的全部治理状态。d 是 loadBoardDetail 的结果；时间一律用链上最新区块时间。
 * logChunk：网络一次能查多少个区块的日志；X Layer 只有 100，改成并发查最近的区块（见 getLogsRecent）。
 */
export async function loadGovernance(client, dep, d, account, logChunk, logClient = client) {
  const gov = d.GOVERNOR ?? dep.monthGovernor;
  const board = d.address;
  const n = Number(d.socketCount ?? 0n);
  const g = (functionName, args = []) => ({ address: gov, abi: GovernorAbi, functionName, args });
  // X Layer：只查最近 60 段（6,000 个区块，约 1.7 小时；测试网时间压缩后一次清算从投票到执行约 40 分钟）。更早发布的计划不显示
  const scan = (q) => (logChunk && logChunk <= 1000n ? getLogsRecent(logClient, { ...q, chunk: logChunk, maxChunks: 60 }) : getLogsChunked(client, q));

  const [head, block, published, executed] = await Promise.all([
    client.multicall({
      contracts: [
        g('proposals', [board]),
        g('proposalCount', [board]),
        g('cooldownUntil', [board]),
        g('intentEpoch', [board]),
        ...CONSTS.map((c) => g(c)),
      ],
      allowFailure: false,
    }),
    client.getBlock(),
    scan({ address: gov, event: eventAbi(GovernorAbi, 'PlanPublished'), args: { board }, fromBlock: dep.fromBlock, maxChunks: 400 }),
    scan({ address: gov, event: eventAbi(GovernorAbi, 'PlanExecuted'), args: { board }, fromBlock: dep.fromBlock, maxChunks: 400 }),
  ]);
  const executedHashes = new Set(executed.logs.map((l) => l.args.planHash));
  const [prop, count, cooldownUntil, epoch, ...consts] = head;
  const c = Object.fromEntries(CONSTS.map((k, i) => [k, consts[i]]));
  const [phase, planHash, voteEnd, executeAfter, executeBy, yes, no, abstain, total] = prop;
  const proposal = { phase: PHASE[phase], planHash, voteEnd, executeAfter, executeBy, yes, no, abstain, total, id: count };

  // 所有持仓和它们的支持意向（每块月局最多几百份持仓，一次 multicall）
  const slots = Array.from({ length: n }, (_, i) => BigInt(i + 1));
  const res = await client.multicall({
    contracts: slots.flatMap((s) => [
      { address: board, abi: MonthBoardAbi, functionName: 'socket', args: [s] },
      g('supportOf', [board, s]),
      ...(phase !== 0 ? [g('voteOf', [board, count, s])] : []),
    ]),
    allowFailure: true,
  });
  const step = phase !== 0 ? 3 : 2;
  const me = account?.toLowerCase();
  const positions = slots
    .map((slot, i) => {
      const socket = res[i * step].result;
      const sup = res[i * step + 1].result;
      if (!socket) return null;
      const [supHash, supEpoch, supVersion] = sup ?? [ZERO_HASH, 0n, 0];
      // 和合约 supportValid 相同：同一轮意向、持仓没有转让过
      const supporting = supHash !== ZERO_HASH && supEpoch === epoch && supVersion === socket.version ? supHash : null;
      return { slot, socket, supporting, vote: phase !== 0 ? Number(res[i * step + 2].result ?? 0) : 0, mine: !!me && socket.owner.toLowerCase() === me };
    })
    .filter(Boolean);

  // 已发布的计划，按支持权重排序
  const hashes = [...new Set(published.logs.map((l) => l.args.planHash))];
  const planRes = hashes.length
    ? await client.multicall({ contracts: hashes.map((h) => g('plan', [h])), allowFailure: true })
    : [];
  const plans = hashes
    .map((hash, i) => {
      const r = planRes[i].result;
      if (!r) return null;
      const [, indexes, start, floor] = r;
      const supporters = positions.filter((p) => p.supporting === hash);
      return {
        hash,
        executed: executedHashes.has(hash), // 已经执行过的计划：再投一次没有意义，只做展示
        items: indexes.map((index, k) => ({ index, start: start[k], floor: floor[k] })),
        weight: supporters.reduce((a, p) => a + p.socket.stake, 0n),
        supporterSlots: supporters.map((p) => p.slot), // 已经按插槽编号递增，openVote 需要
      };
    })
    .filter(Boolean)
    .sort((a, b) => a.executed - b.executed || (a.weight > b.weight ? -1 : a.weight < b.weight ? 1 : 0));

  const totalStake = d.totalStake ?? 0n;
  return {
    gov,
    now: block.timestamp,
    proposal,
    cooldownUntil,
    epoch,
    ...c,
    earliestOpen: (d.settleStart ?? 0n) + c.MIN_SETTLE_AGE,
    supportNeeded: (totalStake * c.SUPPORT_BPS + 9_999n) / 10_000n, // 10%，向上取整
    totalStake,
    positions,
    myPositions: positions.filter((p) => p.mine),
    plans,
  };
}

/** 按成本价的百分比生成一份计划：本局每一台没卖出的矿机，序号递增 */
export function planFromPercent(machines, startPct, floorPct) {
  const items = machines
    .filter((m) => !m.sold)
    .sort((a, b) => a.index - b.index)
    .map((m) => ({
      index: BigInt(m.index),
      cost: m.cost,
      start: (m.cost * BigInt(Math.round(startPct * 100))) / 10_000n,
      floor: (m.cost * BigInt(Math.round(floorPct * 100))) / 10_000n,
    }));
  return items;
}
