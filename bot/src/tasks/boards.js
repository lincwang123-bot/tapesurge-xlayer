// 每块主板该做的事。原则：能不能做由合约说了算（先模拟），机器人只负责"按时去试"。
import { randomBytes } from 'node:crypto';
import { ABI } from '../abi.js';
import { fetchSignature } from '../drand.js';
import * as log from '../log.js';

// 合约里的枚举值（ITapeBoard.BoardState / IMonthBoard.MonthState）
const STD = { Recruiting: 1, Failed: 2, Active: 3, Liquidating: 4 };
const MONTH = { Recruiting: 1, Failed: 2, Preparing: 3, Mining: 4, Drawing: 5, Settling: 6 };

const STD_FIELDS = [
  'state', 'number', 'socketCount', 'recruitDeadline', 'drawPending', 'pendingRequestId', 'lastRequestAt',
  'startedAt', 'finishedAt', 'claimsClosed', 'liabilities', 'potAllocated', 'machineCount', 'aliveCount',
];
const MONTH_FIELDS = [
  'state', 'number', 'socketCount', 'recruitDeadline', 'prepEnd', 'miningEnd', 'drawPending', 'pendingRequestId',
  'wordReceived', 'settleStart', 'principalRemaining', 'finishedAt', 'claimsClosed', 'liabilities', 'machineCount',
  'unsoldMachines', 'isPurchasing',
];

async function read(pub, address, abi, fields) {
  const res = await pub.multicall({
    contracts: fields.map((functionName) => ({ address, abi, functionName })),
    allowFailure: true,
  });
  const out = {};
  fields.forEach((f, i) => (out[f] = res[i].status === 'success' ? res[i].result : undefined));
  return out;
}

/** 两个工厂的全部主板地址。已知的地址缓存在本地状态里，每次只读新增的 */
export async function listBoards(ctx) {
  const { pub, dep, state } = ctx;
  const out = [];
  for (const [kind, factory, abi] of [
    ['std', dep.factory, ABI.factory],
    ['month', dep.monthFactory, ABI.monthFactory],
  ]) {
    if (!factory || !abi) continue; // X Layer 版只有月局
    state.data.known ??= {};
    const known = (state.data.known[kind] ??= []);
    const n = Number(await pub.readContract({ address: factory, abi, functionName: 'boardCount' }));
    if (n > known.length) {
      const res = await pub.multicall({
        contracts: Array.from({ length: n - known.length }, (_, j) => ({ address: factory, abi, functionName: 'allBoards', args: [BigInt(known.length + j)] })),
        allowFailure: false,
      });
      known.push(...res);
    }
    for (const a of known) out.push({ kind, address: a });
  }
  return out;
}

export async function readBoard(ctx, kind, address) {
  return read(ctx.pub, address, kind === 'std' ? ABI.std : ABI.month, kind === 'std' ? STD_FIELDS : MONTH_FIELDS);
}

/** 分批把可领的 BEM 和通行证推给所有参与者 */
async function distributeAll(ctx, name, address, abi, socketCount) {
  const batch = ctx.cfg.distributeBatch;
  // v2 月局：分批推送移到了单例卖矿合约 MonthMachineSales.distribute(board, from, count)；
  // v2.0-rc6 起标准局也一样，改由 StdMachineSales.distribute(board, from, count)（TapeBoard 上没有 distribute 了）
  const hasDist = (x) => x?.some((f) => f.type === 'function' && f.name === 'distribute' && f.inputs.length === 3);
  const sales = abi === ABI.month && ABI.monthSales ? [ctx.dep.monthSales, ABI.monthSales] : abi === ABI.std && hasDist(ABI.stdSales) ? [ctx.dep.stdSales, ABI.stdSales] : null;
  for (let from = 1n; from <= socketCount; from += batch) {
    const label = `${name} distribute ${from}-${from + batch - 1n}`;
    const r = sales
      ? await ctx.sender.send(label, sales[0], sales[1], 'distribute', [address, from, batch])
      : await ctx.sender.send(label, address, abi, 'distribute', [from, batch]);
    if (!r.sent && !r.dryRun) return false;
  }
  return true;
}

/** 测试网：随机数来自 MockRandomSource，由机器人扮演 VRF 节点交付 */
async function fulfillMock(ctx, name, requestId) {
  const word = BigInt(`0x${randomBytes(32).toString('hex')}`);
  await ctx.sender.send(`${name} mock VRF fulfill #${requestId}`, ctx.dep.randomSource, ABI.mockRandom, 'fulfill', [requestId, word]);
}

/**
 * X Layer 版：drand 交付。开奖请求锁定了一个未来轮次 R；第 R 轮签名产生后（roundTime(R)），
 * 从 drand 中继取签名交给适配器，适配器在链上验签。重发请求沿用同一轮，所以只看当前 pendingRequestId。
 */
async function deliverDrand(ctx, name, address, b) {
  const { pub, dep } = ctx;
  const id = b.pendingRequestId;
  const [consumer, round, fulfilled] = await pub.readContract({ address: dep.drandAdapter, abi: ABI.drand, functionName: 'requests', args: [id] });
  if (fulfilled) return;
  if (consumer.toLowerCase() !== address.toLowerCase()) {
    log.warn(`${name} pending request #${id} belongs to ${consumer}`);
    return;
  }
  const at = Number(await pub.readContract({ address: dep.drandAdapter, abi: ABI.drand, functionName: 'roundTime', args: [round] }));
  if (ctx.now < at) {
    log.info(`${name} waiting for drand round ${round}`, { inSec: at - ctx.now });
    return;
  }
  let sig;
  try {
    sig = await fetchSignature(round);
  } catch (e) {
    log.warn(`${name} drand fetch failed`, { round, reason: e.message });
    if (ctx.now - at > ctx.cfg.drawAlertSec) {
      await ctx.alert.send(`drand:${address}`, `⏳ ${name} 取不到 drand 第 ${round} 轮签名已经 ${((ctx.now - at) / 3600).toFixed(1)} 小时：${e.message}`);
    }
    return;
  }
  await ctx.sender.send(`${name} drand fulfill #${id} (round ${round})`, dep.drandAdapter, ABI.drand, 'fulfill', [id, sig]);
}

/**
 * X Layer 版：RIG 凭证的产出要有人在 BSC 金库上发起收取，经 LayerZero 送到 X Layer。
 * 测试网没有 BSC 和 LayerZero，用 MockRig.claim(ids) 代替（同时刷新"3 天内同步"的计时，交接时才不会被拒）。
 */
async function rigYield(ctx, name, address, b) {
  const { pub, dep, cfg } = ctx;
  if (!ctx.state.due(`rig:${address}`, ctx.every(43_200))) return;
  if (cfg.mainnet) {
    await ctx.alert.send(
      'rig-mainnet',
      `⚠️ ${name} 持有 RIG 凭证：X Layer 主网上的产出要在 BSC 金库发起收取（结算阶段的 RIG 1 天内没同步过就不能卖出或交接）`,
      { everySec: 86_400 },
    );
    return;
  }
  const n = Number(b.machineCount ?? 0n);
  const res = await pub.multicall({
    contracts: Array.from({ length: n }, (_, i) => ({ address, abi: ABI.month, functionName: 'machine', args: [BigInt(i)] })),
    allowFailure: true,
  });
  const ids = res.map((r) => r.result).filter((m) => m && !m.sold).map((m) => m.circuitId);
  if (!ids.length) return;
  const r = await ctx.sender.send(`${name} MockRig.claim(${ids.length})`, dep.rig, ABI.rig, 'claim', [ids], { quiet: true });
  if (r.sent) await ctx.sender.send(`${name} harvest`, address, ABI.month, 'harvest', [], { quiet: true });
}

async function watchDraw(ctx, name, address, abi, b, safeFn) {
  if (ctx.cfg.network === 'xlayer') await deliverDrand(ctx, name, address, b);
  else if (ctx.dep.mockRandom) return fulfillMock(ctx, name, b.pendingRequestId);
  const waited = ctx.now - Number(b.lastRequestAt ?? 0n);
  if (b.lastRequestAt && waited > ctx.cfg.drawAlertSec) {
    await ctx.alert.send(`draw:${address}`, `⏳ ${name} 等随机数已经 ${(waited / 3600).toFixed(1)} 小时，检查 VRF 订阅余额和 consumer 设置`);
  }
  // X Layer 版重发会沿用同一轮次，没有意义；只在 BSC（Chainlink VRF）上重发
  if (ctx.cfg.network !== 'xlayer') await ctx.sender.send(`${name} retryDraw`, address, abi, 'retryDraw', [], { quiet: true });
  await ctx.sender.send(`${name} ${safeFn}`, address, abi, safeFn, [], { quiet: true });
}

export async function handleStd(ctx, address, b) {
  const s = ctx.state.board(address);
  const A = ABI.std;
  const name = `std#${b.number}`;
  const every = ctx.every;
  switch (Number(b.state)) {
    case STD.Recruiting:
      if (ctx.now >= Number(b.recruitDeadline)) await ctx.sender.send(`${name} closeRecruitment`, address, A, 'closeRecruitment');
      break;
    case STD.Failed:
      if (b.liabilities > 0n && ctx.state.due(`dist:${address}`, every(3600))) await distributeAll(ctx, name, address, A, b.socketCount);
      if (b.liabilities === 0n) s.done = true;
      break;
    case STD.Active:
      if (b.drawPending) await watchDraw(ctx, name, address, A, b, 'triggerSafeExit');
      else if (ctx.state.due(`pulse:${address}`, every(600))) await ctx.sender.send(`${name} pulse`, address, A, 'pulse', [], { quiet: true });
      if (ctx.state.due(`expire:${address}`, every(3600))) await ctx.sender.send(`${name} expire`, address, A, 'expire', [], { quiet: true });
      break;
    case STD.Liquidating: {
      // 卖不出的矿机继续挖：每天领一次产出并入底池
      if (!b.finishedAt && ctx.state.due(`harvest:${address}`, every(86_400))) await ctx.sender.send(`${name} harvest`, address, A, 'harvest', [], { quiet: true });
      // v2.0-rc3：终局满 30 天还没卖完的矿机转降价拍卖，用当时的买一快照起价（买家买的时候也会自动触发，这里只是不让它拖）
      if (!b.finishedAt && ABI.stdSales && ctx.dep.stdSales && !s.auctionStarted && ctx.state.due(`auction:${address}`, every(3600))) {
        const sales = ctx.dep.stdSales;
        const started = await ctx.pub.readContract({ address: sales, abi: ABI.stdSales, functionName: 'auctionStartPrice', args: [address] });
        if (started > 0n) s.auctionStarted = true;
        else await ctx.sender.send(`${name} startAuction`, sales, ABI.stdSales, 'startAuction', [address], { quiet: true });
      }
      const key = (x) => `${x.potAllocated}:${x.finishedAt}`;
      if (s.distKey !== key(b) || ctx.state.due(`dist:${address}`, every(7 * 86_400))) {
        // 发放本身会改变这些字段：发完重新读一次再记下，避免下一轮再做一次空发放
        if (await distributeAll(ctx, name, address, A, b.socketCount)) s.distKey = key(await readBoard(ctx, 'std', address));
      }
      if (b.finishedAt && ctx.state.due(`close:${address}`, every(86_400))) await ctx.sender.send(`${name} closeClaims`, address, A, 'closeClaims', [], { quiet: true });
      if (b.claimsClosed) s.done = true;
      break;
    }
  }
}

export async function handleMonth(ctx, address, b) {
  const s = ctx.state.board(address);
  const A = ABI.month;
  const name = `month#${b.number}`;
  const every = ctx.every;
  const st = Number(b.state);
  if (ctx.cfg.network === 'xlayer' && st >= MONTH.Preparing && b.machineCount > 0n && !b.claimsClosed) await rigYield(ctx, name, address, b);
  switch (Number(b.state)) {
    case MONTH.Recruiting:
      if (ctx.now >= Number(b.recruitDeadline)) await ctx.sender.send(`${name} closeRecruitment`, address, A, 'closeRecruitment');
      break;
    case MONTH.Failed:
      if (b.liabilities > 0n && ctx.state.due(`dist:${address}`, every(3600))) await distributeAll(ctx, name, address, A, b.socketCount);
      if (b.liabilities === 0n) s.done = true;
      break;
    case MONTH.Preparing:
      if (ctx.now >= Number(b.prepEnd)) await ctx.sender.send(`${name} sync (start mining)`, address, A, 'sync');
      else ctx.receivers.push({ address, name });
      break;
    case MONTH.Mining:
      if (ctx.now >= Number(b.miningEnd)) {
        const wall = Math.floor(Date.now() / 1000);
        if (ctx.cfg.network === 'xlayer' && chainLagBlocksDraw(ctx.now, wall, ctx.cfg.maxChainLagSec)) {
          log.warn(`${name} chain time is behind wall clock, not drawing yet`, { lagSec: wall - ctx.now });
          await ctx.alert.send(
            `lag:${address}`,
            `⏳ ${name} 该开奖了，但 X Layer 链上时间落后本机 ${wall - ctx.now} 秒（可能在停机追块），先不发 drawPrizes，免得锁定一个已经公开的 drand 轮次`,
            { everySec: 3600 },
          );
          break;
        }
        await ctx.sender.send(`${name} drawPrizes`, address, A, 'drawPrizes');
      } else if (ctx.state.due(`harvest:${address}`, every(86_400))) await ctx.sender.send(`${name} harvest`, address, A, 'harvest', [], { quiet: true });
      break;
    case MONTH.Drawing:
      if (b.wordReceived) await ctx.sender.send(`${name} finalizePrizes`, address, A, 'finalizePrizes');
      else if (b.drawPending) await watchDraw(ctx, name, address, A, b, 'triggerSafeSettle');
      break;
    case MONTH.Settling: {
      if (ABI.monthGovernor && ctx.dep.monthGovernor) await governance(ctx, name, address);
      if (b.unsoldMachines > 0n) ctx.settling.push({ address, name, b });
      if (b.unsoldMachines > 0n && ctx.state.due(`harvest:${address}`, every(86_400))) await ctx.sender.send(`${name} harvest`, address, A, 'harvest', [], { quiet: true });
      const key = (x) => `${x.principalRemaining}:${x.liabilities}:${x.finishedAt}`;
      if (s.distKey !== key(b) || ctx.state.due(`dist:${address}`, every(7 * 86_400))) {
        if (await distributeAll(ctx, name, address, A, b.socketCount)) s.distKey = key(await readBoard(ctx, 'month', address));
      }
      // X Layer 的 closeClaims 关闭之后还能再调（不报错），所以先看 claimsClosed，免得多花一次 gas
      if (b.finishedAt && !b.claimsClosed && ctx.state.due(`close:${address}`, every(86_400))) await ctx.sender.send(`${name} closeClaims`, address, A, 'closeClaims', [], { quiet: true });
      if (b.claimsClosed) s.done = true;
      break;
    }
  }
}

/**
 * v2 多数集体清算（MonthExitGovernor）：结算投票、执行计划、让过期提案失效，这三步任何人都可以做，
 * 机器人到点就做，免得没人点导致提案卡住或过期。发起投票和投票由持有人自己决定，机器人不碰。
 * proposals(board) = [phase, planHash, voteEnd, executeAfter, executeBy, yes, no, abstain, total]，phase 0 无 / 1 投票中 / 2 执行等待。
 */
async function governance(ctx, name, address) {
  const G = ABI.monthGovernor;
  const gov = ctx.dep.monthGovernor;
  const [[phase, planHash, voteEnd, executeAfter, executeBy, yes, no, , total], id] = await ctx.pub.multicall({
    contracts: [
      { address: gov, abi: G, functionName: 'proposals', args: [address] },
      { address: gov, abi: G, functionName: 'proposalCount', args: [address] },
    ],
    allowFailure: false,
  });
  if (phase === 0) return;
  const s = ctx.state.board(address);
  // 用提案编号区分：同一个计划可以失败后再投一次，计划哈希会重复
  const tag = `${address}:${id}`;
  const share = (x) => (total > 0n ? `${(Number((x * 10_000n) / total) / 100).toFixed(2)}%` : '0%');
  const notify = async (p) => {
    if (s.govSeen === `${tag}:${p}`) return;
    s.govSeen = `${tag}:${p}`;
    const text =
      p === 1
        ? `🗳 ${name} 开始第 ${id} 次集体清算投票（计划 ${planHash.slice(0, 10)}），${new Date(Number(voteEnd) * 1000).toISOString()} 截止；投票期间持仓暂停转让`
        : p === 2
          ? `✅ ${name} 第 ${id} 次集体清算投票通过（赞成 ${share(yes)}，反对 ${share(no)}），等待期满后机器人自动执行`
          : `❎ ${name} 第 ${id} 次集体清算投票没通过（赞成 ${share(yes)}，需要超过 50%），进入冷却期`;
    await ctx.alert.send(`gov:${tag}:${p}`, text);
  };
  await notify(phase);
  if (phase === 1 && ctx.now >= Number(voteEnd)) {
    const r = await ctx.sender.send(`${name} finalizeVote`, gov, G, 'finalizeVote', [address]);
    if (r.ok) await notify(yes > total / 2n ? 2 : 'failed');
  } else if (phase === 2 && ctx.now >= Number(executeAfter) && ctx.now < Number(executeBy)) {
    await ctx.sender.send(`${name} execute liquidation plan`, gov, G, 'execute', [address]);
  } else if (phase === 2 && ctx.now >= Number(executeBy)) {
    // 正常不会走到这里（机器人在等待期满后就执行了）；走到这里说明机器人停摆过，要人看一下
    const r = await ctx.sender.send(`${name} expire proposal`, gov, G, 'expire', [address]);
    if (r.ok) await ctx.alert.send(`gov:${tag}:expired`, `⚠️ ${name} 第 ${id} 次集体清算超过执行期限没有执行，已失效（机器人可能停摆过）`);
  }
}

/**
 * 月局结算：矿机先按成本价交接给正在准备的月局（运营地址专属）；交接不了的，
 * 设了 LIST_PREMIUM_BPS 就按"成本价 × (1 + 溢价)"挂单，否则等合约 1 天后自动按成本价挂单。
 */
export async function relayAndList(ctx) {
  if (ABI.monthSales) return relayAndListV2(ctx);
  const A = ABI.month;
  for (const { address, name, b } of ctx.settling) {
    const n = Number(b.machineCount ?? 0n);
    const res = await ctx.pub.multicall({
      contracts: Array.from({ length: n }, (_, i) => ({ address, abi: A, functionName: 'machine', args: [BigInt(i)] })),
      allowFailure: true,
    });
    for (let i = 0; i < n; i++) {
      const m = res[i].result;
      if (!m || m.sold) continue;
      let relayed = false;
      for (const r of ctx.receivers) {
        const out = await ctx.sender.send(`${name} relay machine ${i} → ${r.name}`, address, A, 'relayMachine', [BigInt(i), r.address], { quiet: true });
        if (out.sent || out.dryRun) {
          relayed = true;
          break;
        }
      }
      if (!relayed && ctx.cfg.listPremiumBps > 0n && m.listedAt === 0n) {
        const price = (BigInt(m.cost) * (10_000n + ctx.cfg.listPremiumBps)) / 10_000n;
        await ctx.sender.send(`${name} list machine ${i} at ${price}`, address, A, 'setListing', [BigInt(i), price], { quiet: true });
      }
    }
  }
  if (ctx.settling.length && !ctx.receivers.length) log.info('settling machines waiting: no monthly board is preparing right now');
}

/**
 * v2 月局结算（规则见 v2月局规则决定-2026-10-22.md）：交接——旧月局在新月局的收购里当普通卖家（sales.relay），
 * 新局收购价不低于成本价才成交，合约会检查。v2.0-rc3 起不再挂单：卖价由合约按买一 / 卖一公式算
 * （不低于成本价），任何人按 askPrice 直接买；低于成本价时矿机继续挖，产出按比例分。
 * X Layer 2026-10-28 起也一样（和 BSC 对齐，挂单接口已删除）；另外交接前 RIG 要在 1 天内同步过。
 */
async function relayAndListV2(ctx) {
  const A = ABI.month;
  const S = ABI.monthSales;
  const sales = ctx.dep.monthSales;
  for (const { address, name, b } of ctx.settling) {
    if (!ctx.receivers.length) break;
    const n = Number(b.machineCount ?? 0n);
    const res = await ctx.pub.multicall({
      contracts: Array.from({ length: n }, (_, i) => ({ address, abi: A, functionName: 'machine', args: [BigInt(i)] })),
      allowFailure: true,
    });
    const machines = res.map((r) => r.result);
    if (ctx.cfg.network === 'xlayer') await freshenRigs(ctx, name, address, machines);
    for (let i = 0; i < n; i++) {
      const m = machines[i];
      if (!m || m.sold) continue;
      for (const r of ctx.receivers) {
        const out = await ctx.sender.send(`${name} relay machine ${i} → ${r.name}`, sales, S, 'relay', [address, BigInt(i), r.address], { quiet: true });
        if (out.sent || out.dryRun) break;
      }
    }
  }
  if (ctx.settling.length && !ctx.receivers.length) log.info('settling machines waiting: no monthly board is preparing right now');
}

/** X Layer 开奖前：链上时间落后本机时间超过 maxLagSec 秒时先不开奖；maxLagSec = 0 不检查 */
export function chainLagBlocksDraw(chainNow, wallNow, maxLagSec) {
  return maxLagSec > 0 && wallNow - chainNow > maxLagSec;
}

/** 同步不够新的 RIG 编号（items：{ id, fresh }） */
export function staleRigIds(items) {
  return items.filter((x) => !x.fresh).map((x) => x.id);
}

/**
 * X Layer：交接 / 卖出前 RIG 要在 1 天内同步过（XMonthMachineSales.syncFresh）。
 * 测试网先对同步不够新的调用 MockRig.claim（模拟 BSC 金库收取 + LayerZero 送达），再 harvest；
 * 主网要在 BSC 金库上发起收取，这里提醒运营方。读不到 syncFresh（审计修复之前的旧部署）时当作没问题。
 */
async function freshenRigs(ctx, name, board, machines) {
  const S = ABI.monthSales;
  if (!S.some((f) => f.type === 'function' && f.name === 'syncFresh')) return;
  const idx = machines.map((m, i) => (m && !m.sold ? i : -1)).filter((i) => i >= 0);
  if (!idx.length) return;
  const res = await ctx.pub.multicall({
    contracts: idx.map((i) => ({ address: ctx.dep.monthSales, abi: S, functionName: 'syncFresh', args: [board, BigInt(i)] })),
    allowFailure: true,
  });
  const stale = staleRigIds(idx.map((i, k) => ({ id: machines[i].circuitId, fresh: res[k].status === 'success' ? res[k].result : true })));
  await refreshStaleRigs(ctx, name, board, stale);
}

/**
 * 让这些 RIG 的同步时间变新（卖矿合约要求 1 天内同步过）：测试网调用 MockRig.claim（模拟 BSC 金库收取 + LayerZero 送达）
 * 再 harvest；主网要在 BSC 金库上发起收取，这里提醒运营方。返回是否已经刷新（之后要重新读链上数据）。
 */
export async function refreshStaleRigs(ctx, name, board, ids) {
  if (!ids.length) return false;
  if (ctx.cfg.mainnet) {
    await ctx.alert.send(
      `rig-sync:${board}`,
      `⚠️ ${name} 有 ${ids.length} 张 RIG 超过 1 天没同步，交接和卖出会被合约拒绝：请在 BSC 金库为它们发起一次收取`,
      { everySec: 6 * 3600 },
    );
    return false;
  }
  const r = await ctx.sender.send(`${name} MockRig.claim(${ids.length}) before sale`, ctx.dep.rig, ABI.rig, 'claim', [ids], { quiet: true });
  if (r.sent) await ctx.sender.send(`${name} harvest`, board, ABI.month, 'harvest', [], { quiet: true });
  return !!r.sent;
}
