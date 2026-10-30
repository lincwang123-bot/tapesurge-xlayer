// 和单块主板无关的事：创世开局、升级哨兵登记、分账合约（回购 / 首批回馈 / 补转）、余额监控、心跳。
import { formatEther, parseAbi } from 'viem';
import { ABI, COORDINATOR_ABI } from '../abi.js';
import * as log from '../log.js';
import { EIP1967_IMPL_SLOT, RIG_IMPL_196, implFromSlot, rigStatus } from '../rigwatch.js';

/** 创世条件满足后任何人都可以开局；机器人负责按时触发，免得开局拖延 */
export async function genesis(ctx) {
  const { pub, dep, sender } = ctx;
  // 注册中心：BSC 版是标准局工厂，X Layer 版是 XHub（config 已把 dep.hub 统一好）
  const started = await pub.readContract({ address: dep.hub, abi: ABI.hub, functionName: 'genesisStarted' });
  if (started) return true;
  if (ctx.state.due('genesis', ctx.every(300))) await sender.send('startGenesis', dep.hub, ABI.hub, 'startGenesis', [], { quiet: true });
  return false;
}

/**
 * 升级哨兵：TapeOut 的电路信标一旦升级，主板的实现合约会报告 sentinelTripped（BSC 版两种局，X Layer 版只有月局；
 * X Layer 的 RIG 是 UUPS 代理，升级在链上检测不到，由下面的 rigWatch 在链下监控）。
 * 冷静期从第一次登记（noteSentinel）开始算 30 天，所以发现后要立刻登记；信标恢复后再登记一次清零。
 */
export async function sentinel(ctx) {
  const { pub, dep, sender } = ctx;
  const hasStd = Boolean(ABI.std && dep.factory);
  const [stdImpl, monthImpl, since] = await Promise.all([
    hasStd ? pub.readContract({ address: dep.factory, abi: ABI.factory, functionName: 'boardImplementation' }) : null,
    pub.readContract({ address: dep.monthFactory, abi: ABI.monthFactory, functionName: 'boardImplementation' }),
    // 早期的测试网部署没有冷静期登记（sentinelSince），读不到就只做监控
    pub.readContract({ address: dep.hub, abi: ABI.hub, functionName: 'sentinelSince' }).catch(() => null),
  ]);
  const [a, b] = await Promise.all([
    hasStd ? pub.readContract({ address: stdImpl, abi: ABI.std, functionName: 'sentinelTripped' }) : false,
    pub.readContract({ address: monthImpl, abi: ABI.month, functionName: 'sentinelTripped' }),
  ]);
  const tripped = a || b;
  const mem = (ctx.state.data.sentinel ??= { cleared: false });
  if (since !== null) {
    if (tripped && since === 0n) {
      // 新触发，或者登记之后信标又换了 implementation（旧登记作废）：立即登记，冷静期从现在开始
      await sender.send('noteSentinel (tripped)', dep.hub, ABI.hub, 'noteSentinel');
      mem.cleared = false;
    } else if (!tripped && !mem.cleared) {
      // 信标恢复后，视图 sentinelSince() 已经返回 0，但存储里的旧登记还在。如果之后又升级回同一个 implementation，
      // 旧登记会重新生效、跳过冷静期（已知问题）。所以恢复后调用一次，把存储清零。
      // 机器人重启后不知道之前的状态，也调用一次（没有旧登记时不改状态，只花一点 gas）。
      const r = await sender.send('noteSentinel (clear)', dep.hub, ABI.hub, 'noteSentinel');
      if (r.sent || r.dryRun) mem.cleared = true;
    }
    if (tripped) mem.cleared = false;
  }
  if (tripped) {
    await ctx.alert.send(
      'sentinel',
      `🛑 升级哨兵已触发（${hasStd ? `标准局 ${a}，` : ''}月局 ${b}）：TapeOut 电路信标被升级。冷静期内暂停加入、开新主板和矿机交易，满 30 天自动恢复。请尽快公告。`,
      { everySec: 86_400 },
    );
  }
}

const RIG_SEALED_ABI = parseAbi(['function isSealed() view returns (bool)']);

/**
 * X Layer：RIG 凭证合约的升级监控（全局审计 2026-10-29 第 4 条）。RIG 是 UUPS 代理，升级在链上检测不到：
 * 每 5 分钟读一次代理的实现槽，和期望值（RIG_IMPLEMENTATION / 部署文件的 rigImplementation / 主网默认值）比较，
 * 没有期望值时和第一次看到的比较。变了就报警，并停掉机器人从市场给月局买 RIG（ctx.rigUpgraded，见 rigMarket.js）。
 * 处理办法：核对新实现的源码；确认有问题时由手续费 Safe 调 XHub.setOperator(0)，报价失效后收购和卖矿都暂停，再公告。
 */
export async function rigWatch(ctx) {
  const { pub, dep, cfg } = ctx;
  const mem = (ctx.state.data.rigWatch ??= {});
  ctx.rigUpgraded = Boolean(mem.changed);
  if (cfg.network !== 'xlayer' || !dep.rig || !ctx.state.due('rig-watch', ctx.every(300))) return;
  const [word, sealed] = await Promise.all([
    pub.getStorageAt({ address: dep.rig, slot: EIP1967_IMPL_SLOT }),
    pub.readContract({ address: dep.rig, abi: RIG_SEALED_ABI, functionName: 'isSealed' }).catch(() => null), // 测试网的 MockRig 没有
  ]);
  const current = implFromSlot(word);
  const expected = cfg.rigImplementation ?? (cfg.chainId === 196 ? RIG_IMPL_196 : null);
  mem.baseline ??= current;
  const s = rigStatus({ expected, baseline: mem.baseline, current, sealed, wasSealed: mem.sealed ?? null });
  mem.current = current;
  mem.sealed = sealed;
  mem.changed = s.changed;
  ctx.rigUpgraded = s.changed;
  if (s.changed) {
    log.error('RIG implementation changed', { rig: dep.rig, from: s.ref, to: current });
    await ctx.alert.send(
      'rig-upgrade',
      `🛑 RIG 凭证合约 ${dep.rig} 被升级：实现从 ${s.ref} 换成 ${current}。机器人已停止从市场给月局买 RIG。请立即核对新实现的源码；有问题就由手续费 Safe 调 XHub.setOperator(0) 暂停收购和卖矿，并公告。确认没问题后把 RIG_IMPLEMENTATION 设成新地址。`,
      { everySec: 6 * 3600 },
    );
  }
  if (s.newlySealed) await ctx.alert.send('rig-sealed', `✅ RIG 凭证合约 ${dep.rig} 已经封印（isSealed = true），之后不能再升级`, { everySec: 365 * 86_400 });
}

/**
 * 分账合约的回购（第 0 路）和首批回馈第 i 桶（第 i 路）是否到点：合约要求 区块时间 ≥ lastSwapAt[i] + minSwapInterval。
 * 按合约记录的时间判断，而不是机器人自己的计时（2026-10-26：机器人按自己的钟隔 1 小时再试，上次成交比发起晚几秒上链，
 * 整点那次常常差几秒被拒，又要再等一小时，回购和回馈约慢 15%–20%）。
 */
export function swapDue(blockTime, lastSwapAt, minSwapInterval) {
  return BigInt(blockTime) >= BigInt(lastSwapAt) + BigInt(minSwapInterval);
}

// TapeOut 晶体管合约：只用到 creator 名下待提取的铸造收入
const TRANSISTORS_ABI = parseAbi(['function owed(address account) view returns (uint256)']);

/** 到点但模拟失败（池子空、主板没开局、滑点超限等）后，隔多久再试 */
export const SPLITTER_RETRY_SEC = 300;

/**
 * 分账合约：回购销毁、首批回馈兑换、拒收后的补转。都是任何人可调，限额和间隔由合约控制。
 * 回购和回馈每轮（约 1 分钟）读一次合约的 lastSwapAt，到点就调用；到点但模拟失败的那一路 5 分钟后再试。
 * 回馈桶是空的不调用（桶里的钱只在分账时进来，回购那一次调用会先分账）。补转每小时看一次。
 */
export async function splitter(ctx) {
  const { pub, dep, sender, state } = ctx;
  const S = ABI.splitter;
  const read = (functionName, args = []) => pub.readContract({ address: dep.splitter, abi: S, functionName, args });
  const interval = await read('minSwapInterval');
  const retry = ctx.every(SPLITTER_RETRY_SEC);
  const due = async (i) => swapDue(ctx.now, await read('lastSwapAt', [BigInt(i)]), interval) && state.due(`splitterTry:${i}`, retry);
  if (await due(0)) {
    await sender.send('splitter buyback', dep.splitter, S, 'buyback', [], { quiet: true, private: true }); // 经兑换：走防夹子节点
  }
  for (let i = 1n; i <= 5n; i++) {
    if ((await read('rewardBucket', [i])) === 0n) continue;
    if (await due(i)) await sender.send(`splitter claimReward(${i})`, dep.splitter, S, 'claimReward', [i], { quiet: true, private: true }); // 经兑换
  }
  if (!state.due('splitter', ctx.every(3600))) return;
  // X Layer 默认回购 0%、铸造收入全给手续费 Safe（2026-10-28）：buyback 会以 NothingToSwap 整笔回滚，连带里面的分账，
  // 所以收入要单独调 distribute() 才会转出去。每小时看一次晶体管合约里分账合约名下还没取的铸造收入
  // （看 owed(splitter)，不看合约余额：余额里还有 TapeOut 的协议费，分账合约取不走）
  if (ctx.cfg?.network === 'xlayer' && dep.transistors && (await read('buybackBps')) === 0n) {
    const pending = await pub.readContract({ address: dep.transistors, abi: TRANSISTORS_ABI, functionName: 'owed', args: [dep.splitter] });
    if (pending > 0n) await sender.send(`splitter distribute (${Number(pending) / 1e18} ${ctx.cfg.native})`, dep.splitter, S, 'distribute');
  }
  const [foundation, project] = await Promise.all([read('foundation'), read('project')]);
  // BSC 版叫 owedBnb，X Layer 版叫 owedNative
  const owedFn = S.some((x) => x.name === 'owedNative') ? 'owedNative' : 'owedBnb';
  for (const to of [foundation, project]) {
    const owed = await read(owedFn, [to]);
    if (owed > 0n) await sender.send(`splitter withdrawOwed(${to})`, dep.splitter, S, 'withdrawOwed', [to]);
  }
}

/** 运营钱包 gas 余额、VRF 订阅余额、心跳 */
export async function monitor(ctx) {
  const { pub, dep, cfg } = ctx;
  if (cfg.account) {
    const bal = Number(formatEther(await pub.getBalance({ address: cfg.account.address })));
    if (bal < cfg.minOperatorBnb) {
      await ctx.alert.send('gas', `⛽ 运营钱包 ${cfg.account.address} 只剩 ${bal.toFixed(5)} ${cfg.native}，低于 ${cfg.minOperatorBnb}，请充值`, { everySec: 6 * 3600 });
    }
    ctx.summary.operatorBnb = bal;
  }
  // Chainlink VRF 订阅只有 BSC 版有；X Layer 版用 drand，不需要订阅
  if (cfg.network === 'bsc' && !dep.mockRandom && ctx.state.due('vrf', 1800)) {
    try {
      const [coordinator, subId] = await Promise.all([
        pub.readContract({ address: dep.randomSource, abi: ABI.vrfAdapter, functionName: 'coordinator' }),
        pub.readContract({ address: dep.randomSource, abi: ABI.vrfAdapter, functionName: 'subscriptionId' }),
      ]);
      const [link, native, reqCount, , consumers] = await pub.readContract({ address: coordinator, abi: COORDINATOR_ABI, functionName: 'getSubscription', args: [subId] });
      const nativeBnb = Number(formatEther(native));
      ctx.state.data.vrf = { nativeBnb, link: Number(formatEther(link)), reqCount: Number(reqCount) };
      if (!consumers.map((c) => c.toLowerCase()).includes(dep.randomSource.toLowerCase())) {
        await ctx.alert.send('vrf-consumer', `🎲 VRF 订阅里没有适配器 ${dep.randomSource}：开奖会一直等不到随机数，请在 vrf.chain.link 上 Add consumer`, { everySec: 6 * 3600 });
      }
      if (nativeBnb < cfg.minVrfBnb) {
        await ctx.alert.send('vrf', `🎲 VRF 订阅余额只剩 ${nativeBnb.toFixed(4)} BNB（低于 ${cfg.minVrfBnb}），请到 vrf.chain.link 充值`, { everySec: 6 * 3600 });
      }
    } catch (e) {
      log.warn('vrf check failed', { reason: e.shortMessage ?? e.message });
    }
  }
  if (process.env.HEARTBEAT_URL) {
    fetch(process.env.HEARTBEAT_URL).catch(() => {}); // 例如 healthchecks.io：机器人停了会收到通知
  }
}
