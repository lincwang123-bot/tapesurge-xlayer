// 读链上状态。所有读取都走 multicall，一次请求拿齐；单项失败（例如某个 view 在当前阶段 revert）返回 undefined。
import { erc20Abi, keccak256 } from 'viem';
import TapeBoardAbi from '../abi/TapeBoard.json';
import MonthBoardAbi from '../abi/MonthBoard.json';
import BoardFactoryAbi from '../abi/BoardFactory.json';
import MonthFactoryAbi from '../abi/MonthFactory.json';
import SplitterAbi from '../abi/GenesisSplitter.json';
import MonthSalesAbi from '../abi/MonthMachineSales.json';
import MonthPositionsAbi from '../abi/MonthPositions.json';
import StdSalesAbi from '../abi/StdMachineSales.json';
import PriceFeedAbi from '../abi/MarketPriceFeed.json';
import XMonthFactoryAbi from '../abi/xlayer/XMonthFactory.json';
import XMonthSalesAbi from '../abi/xlayer/XMonthMachineSales.json';
import { circuitsAbi, transistorsAbi, PASS_NETLIST_HASH } from '../abi/tapeout.js';

export const ABI = {
  std: TapeBoardAbi,
  month: MonthBoardAbi,
  factory: BoardFactoryAbi,
  monthFactory: MonthFactoryAbi,
  splitter: SplitterAbi,
  monthSales: MonthSalesAbi,
  monthPositions: MonthPositionsAbi,
  stdSales: StdSalesAbi,
  priceFeed: PriceFeedAbi,
  transistors: transistorsAbi,
  circuits: circuitsAbi,
  erc20: erc20Abi,
};

/** X Layer 版：注册中心是 XHub（部署文件里有 hub、没有 factory），只有月局 */
export const isXLayer = (dep) => !!dep?.hub && !dep?.factory;
/** 注册中心（开局、运营地址、升级哨兵）：BSC 是标准局工厂，X Layer 是 XHub；这几个函数两边同名同参 */
const registryOf = (dep) => dep.factory ?? dep.hub;

export const STD_STATE = ['Uninitialized', 'Recruiting', 'Failed', 'Active', 'Liquidating'];
export const MONTH_STATE = ['Uninitialized', 'Recruiting', 'Failed', 'Preparing', 'Mining', 'Drawing', 'Settling'];
export const SETTLE_MODE = ['None', 'Normal', 'Fallback', 'SafeExit'];

/** 读一组 [合约, 函数名, 参数]，返回按名字取值的对象 */
async function readNamed(client, address, abi, names) {
  const contracts = names.map((n) => {
    const [functionName, ...args] = Array.isArray(n) ? n : [n];
    return { address, abi, functionName, args };
  });
  const res = await client.multicall({ contracts, allowFailure: true });
  const out = {};
  names.forEach((n, i) => {
    const key = Array.isArray(n) ? n.join(':') : n;
    out[key] = res[i].status === 'success' ? res[i].result : undefined;
  });
  return out;
}

// ---------------------------------------------------------------- 总览

export async function loadOverview(client, dep, account) {
  const [f, m, s, t, c] = await Promise.all([
    readNamed(client, registryOf(dep), BoardFactoryAbi, [
      'genesisStarted',
      'genesisMintThreshold',
      'genesisDelay',
      'recruitingBoard',
      'boardCount',
      'operator',
      'sentinelSince',
    ]),
    readNamed(client, dep.monthFactory, MonthFactoryAbi, ['recruitingBoard', 'boardCount', 'totalRolloverPaid']),
    readNamed(client, dep.splitter, SplitterAbi, ['mintStart', 'totalBemBurned', 'totalToFoundation', 'totalDistributed']),
    readNamed(client, dep.transistors, transistorsAbi, ['minted', 'supplyCap', 'mintPrice', 'protocolFee', 'PROTOCOL_FEE']),
    readNamed(client, dep.passCircuits, circuitsAbi, ['TAPEOUT_FEE']),
  ]);
  let bem, bnb;
  if (account) {
    [bem, bnb] = await Promise.all([
      client.readContract({ address: dep.bem, abi: erc20Abi, functionName: 'balanceOf', args: [account] }).catch(() => undefined),
      client.getBalance({ address: account }).catch(() => undefined),
    ]);
  }
  const protocolFee = t.protocolFee ?? t.PROTOCOL_FEE;
  const passCost =
    t.mintPrice != null && protocolFee != null && c.TAPEOUT_FEE != null
      ? (t.mintPrice + protocolFee) * 5n + c.TAPEOUT_FEE
      : undefined;
  return {
    genesisStarted: f.genesisStarted,
    genesisThreshold: f.genesisMintThreshold,
    genesisDelay: f.genesisDelay,
    stdRecruiting: f.recruitingBoard,
    stdCount: f.boardCount,
    operator: f.operator,
    sentinelSince: f.sentinelSince,
    monthRecruiting: m.recruitingBoard,
    monthCount: m.boardCount,
    rolloverPaid: m.totalRolloverPaid,
    mintStart: s.mintStart,
    burned: s.totalBemBurned,
    toFoundation: s.totalToFoundation,
    distributed: s.totalDistributed,
    minted: t.minted,
    supplyCap: t.supplyCap,
    mintPrice: t.mintPrice,
    protocolFee,
    tapeoutFee: c.TAPEOUT_FEE,
    passCost,
    bem,
    bnb,
  };
}

// ---------------------------------------------------------------- 主板列表

const SUMMARY_COMMON = ['state', 'number', 'target', 'totalStake', 'socketCount', 'recruitDeadline', 'startedAt', 'minStake', 'maxStake'];
const SUMMARY_STD = ['aliveCount', 'pool', 'settleMode', 'finishedAt'];
const SUMMARY_MONTH = ['miningStart', 'miningEnd', 'prizePool', 'prizesDrawn', 'prepEnd', 'finishedAt', 'principalRemaining'];

/**
 * 一个地址可以持有多份持仓（转让来的；v2 月局，v2.0-rc6 起标准局也是），合约里没有"地址 → 插槽"的映射。
 * 遍历本局全部插槽的当前持有人，找出属于 account 的；插槽数有上限（目标 ÷ 最低投入），一次 multicall 读完。
 * abi：两种主板的 socket(slot) 结构体不同，按主板类型传入。
 */
export async function mySlotsOf(client, address, account, socketCount, abi = MonthBoardAbi) {
  const n = Number(socketCount ?? 0n);
  if (!account || n === 0) return [];
  const res = await client.multicall({
    contracts: Array.from({ length: n }, (_, i) => ({ address, abi, functionName: 'socket', args: [BigInt(i + 1)] })),
    allowFailure: true,
  });
  const me = account.toLowerCase();
  return res.flatMap((r, i) => (r.result?.owner?.toLowerCase() === me ? [{ slot: BigInt(i + 1), socket: r.result }] : []));
}

/**
 * 主板地址：按编号取每个编号最新的那一块（招募失败会以同一编号重开，旧的那块进入 Failed），再加上最近创建的
 * limit 块（里面可能有招募失败、还要退款的）。两份去重合并，新的在前。
 */
export async function boardAddresses(client, dep, kind, limit = 24) {
  const factory = kind === 'std' ? dep.factory : dep.monthFactory;
  const abi = kind === 'std' ? BoardFactoryAbi : MonthFactoryAbi;
  const [count, current] = await client.multicall({
    contracts: [
      { address: factory, abi, functionName: 'boardCount' },
      { address: factory, abi, functionName: 'currentNumber' },
    ],
    allowFailure: false,
  });
  const n = Number(count);
  const numbers = [];
  for (let k = Number(current); k >= 1 && numbers.length < limit; k--) numbers.push(BigInt(k));
  const idx = [];
  for (let i = n - 1; i >= 0 && idx.length < limit; i--) idx.push(BigInt(i));
  const res = await client.multicall({
    contracts: [
      ...numbers.map((k) => ({ address: factory, abi, functionName: 'boardByNumber', args: [k] })),
      ...idx.map((i) => ({ address: factory, abi, functionName: 'allBoards', args: [i] })),
    ],
    allowFailure: false,
  });
  const seen = new Set();
  const addresses = res.filter((a) => /^0x/.test(a) && !/^0x0{40}$/i.test(a) && !seen.has(a.toLowerCase()) && seen.add(a.toLowerCase()));
  return { total: n, addresses };
}

export async function loadSummary(client, kind, address, account) {
  const abi = kind === 'std' ? TapeBoardAbi : MonthBoardAbi;
  const names = [...SUMMARY_COMMON, ...(kind === 'std' ? SUMMARY_STD : SUMMARY_MONTH)];
  const r = await readNamed(client, address, abi, names);
  const mySlots = await mySlotsOf(client, address, account, r.socketCount, abi);
  const mySlot = mySlots[0]?.slot ?? 0n;
  return { ...r, kind, address, mySlot, mySlots, stateName: (kind === 'std' ? STD_STATE : MONTH_STATE)[r.state ?? 0] };
}

export async function loadBoardList(client, dep, kind, account) {
  const { total, addresses } = await boardAddresses(client, dep, kind);
  const boards = await Promise.all(addresses.map((a) => loadSummary(client, kind, a, account)));
  return { total, boards };
}

// ---------------------------------------------------------------- 主板详情

const DETAIL_STD = [
  'openedAt',
  'aliveStake',
  'kingSocket',
  'kingPaid',
  'drawPending',
  'lastPulseAt',
  'budget',
  'machineCount',
  'activeWeight',
  'totalSpent',
  'totalWeightBought',
  'buyRoundStart',
  'buyRoundEnd',
  'isPurchasing',
  'buyPrice',
  'buyPriceCap',
  'liquidationStart',
  'SALES',
  'PRICE_FEED',
  'POSITIONS',
  'tradeEpoch',
  'transferable',
  'initialBuyEnd',
  'claimsClosed',
  'drawThreshold',
  'maxAliveStake',
  'totalSubsidy',
  'unsoldMachines',
  'sentinelPaused',
  'sentinelTripped',
  'totalEntryFees',
  'kingPot',
];
const DETAIL_MONTH = [
  'budget',
  'pendingRequestId', // X Layer：持有人兜底交 drand 签名时用（board/Fallback.jsx）
  'subsidyCapital',
  'unsoldMachines',
  'totalSpent',
  'activeWeight',
  'drawPending',
  'wordReceived',
  'settleStart',
  'subsidyRemaining',
  'rolledOver',
  'claimsClosed',
  'isPurchasing',
  'buyPrice',
  'buyPriceCap',
  'machineCount',
  'sentinelPaused',
  'sentinelTripped',
  'totalEntryFees',
  'tradeEpoch',
  'governanceLocked',
  'liquidating',
  'SALES',
  'POSITIONS',
  'GOVERNOR',
  'PRICE_FEED',
  ['winnerSlots', 0n],
  ['winnerSlots', 1n],
  ['winnerSlots', 2n],
  ['winnerSlots', 3n],
  ['winnerSlots', 4n],
  ['prizeAmounts', 0n],
  ['prizeAmounts', 1n],
  ['prizeAmounts', 2n],
  ['prizeAmounts', 3n],
  ['prizeAmounts', 4n],
];

// 读不到链上参数时（旧部署的结构不同）用白皮书的主网参数显示说明文字
const DAY = 86_400n;
export const DEFAULT_CONFIG = {
  entryFeeBps: 100n,
  operatorGrace: 3n * DAY,
  buyStepInterval: 6n * 3_600n,
  minMachineAge: 7n * DAY,
  minMachineWeight: 10n,
  maxMachineWeight: 300n,
  assumed: true,
};

const configCache = new Map();
/** 两种局的共用参数（入场费、各种时长）：部署后不会变，每个工厂只读一次 */
export async function loadBoardConfig(client, dep, kind) {
  const factory = kind === 'std' ? dep.factory : dep.monthFactory;
  const key = `${factory}:${kind}`;
  if (!configCache.has(key)) {
    const abi = kind === 'std' ? BoardFactoryAbi : isXLayer(dep) ? XMonthFactoryAbi : MonthFactoryAbi;
    configCache.set(key, client.readContract({ address: factory, abi, functionName: 'boardConfig' }).catch((e) => {
      configCache.delete(key);
      throw e;
    }));
  }
  return configCache.get(key);
}

export async function loadBoardDetail(client, dep, kind, address, account) {
  const abi = kind === 'std' ? TapeBoardAbi : MonthBoardAbi;
  // 地址来自网址，可能被人换成假合约：先向注册中心确认这是本协议创建的主板（BoardFactory.isBoard 同时认两种局）
  // X Layer 没有标准局工厂：月局由 XMonthFactory 认
  const registered = await client
    .readContract(
      isXLayer(dep)
        ? { address: dep.monthFactory, abi: XMonthFactoryAbi, functionName: 'isBoard', args: [address] }
        : { address: dep.factory, abi: BoardFactoryAbi, functionName: 'isBoard', args: [address] },
    )
    .catch(() => false);
  if (!registered) return { address, kind, registered: false };
  const [summary, extra, config, operator] = await Promise.all([
    loadSummary(client, kind, address, account),
    readNamed(client, address, abi, kind === 'std' ? DETAIL_STD : DETAIL_MONTH),
    // 旧部署的参数结构可能和当前 ABI 不一致（例如少了后来加的字段）：读不出来就不显示，不影响其他数据
    loadBoardConfig(client, dep, kind).catch(() => null),
    client.readContract({ address: registryOf(dep), abi: BoardFactoryAbi, functionName: 'operator' }).catch(() => undefined),
  ]);
  const d = { ...summary, ...extra, config: config ?? DEFAULT_CONFIG, operator, registered: true };
  // 卖矿单例：月局 MonthMachineSales、标准局 StdMachineSales（v2.0-rc3 起）；主板自己记着地址
  d.salesAddress = d.SALES ?? (kind === 'month' ? dep.monthSales : dep.stdSales);
  // 两种局共用的 Firsto 买一 / 卖一报价（MarketPriceFeed）
  const feed = d.PRICE_FEED ?? dep.priceFeed;
  if (feed) d.feed = await readNamed(client, feed, PriceFeedAbi, ['bid', 'ask', 'updatedAt', 'fresh', 'abandoned', 'sellStepInterval', 'catchingUp']);
  if (kind === 'std' && d.salesAddress) {
    const r = await readNamed(client, d.salesAddress, StdSalesAbi, [['auctionStartPrice', address], 'MARKET_PERIOD', 'DECAY_DURATION', 'FLOOR_HOLD']);
    d.stdSales = { auctionStartPrice: r[`auctionStartPrice:${address}`], marketPeriod: r.MARKET_PERIOD, decayDuration: r.DECAY_DURATION, floorHold: r.FLOOR_HOLD };
  }
  d.positionsAddress = d.POSITIONS ?? dep.monthPositions;

  // 我的位置
  // 标准局（v2.0-rc6 起）：每份持仓的可领款项在 StdMachineSales.owed(board, slot)；地址上的记账款（出局推送失败、
  // 转让时结转给卖方的份额）在主板的 credit(address)
  if (kind === 'std' && account && d.mySlots.length) {
    const [res, credit] = await Promise.all([
      d.salesAddress
        ? client.multicall({
            contracts: d.mySlots.map((p) => ({ address: d.salesAddress, abi: StdSalesAbi, functionName: 'owed', args: [address, p.slot] })),
            allowFailure: true,
          })
        : [],
      client.readContract({ address, abi, functionName: 'credit', args: [account] }).catch(() => 0n),
    ]);
    d.mySlots = d.mySlots.map((p, i) => ({ ...p, owed: res[i]?.result ?? 0n }));
    d.myCredit = credit;
    d.myOwed = d.mySlots.reduce((a, p) => a + p.owed, 0n) + credit;
  }
  // v2 月局：每份持仓按插槽编号领取；转让时结转给卖方的款项按地址领取（credit）
  if (kind === 'month' && account) {
    const calls = d.mySlots.map((p) => ['owed', p.slot]);
    const r = await readNamed(client, address, abi, [...calls, ['credit', account]]);
    d.mySlots = d.mySlots.map((p) => ({ ...p, owed: r[`owed:${p.slot}`] ?? 0n }));
    d.myCredit = r[`credit:${account}`] ?? 0n;
    d.myOwed = d.mySlots.reduce((a, p) => a + p.owed, 0n) + d.myCredit;
  }

  // 矿机（最多 100 台，合约上限）
  const n = Number(d.machineCount ?? 0n);
  if (n > 0) {
    const calls = [];
    for (let i = 0; i < n; i++) {
      calls.push({ address, abi, functionName: 'machine', args: [BigInt(i)] });
      // 卖价由卖矿单例按报价公式算：月局 askPrice = 整台价；标准局 askPrice = (每单位算力价, 阶段)
      if (d.salesAddress) {
        calls.push({ address: d.salesAddress, abi: kind === 'month' ? MonthSalesAbi : StdSalesAbi, functionName: 'askPrice', args: [address, BigInt(i)] });
      }
    }
    const res = await client.multicall({ contracts: calls, allowFailure: true });
    const step = d.salesAddress ? 2 : 1;
    d.machines = [];
    for (let i = 0; i < n; i++) {
      const m = res[i * step].result;
      if (!m) continue;
      d.machines.push({
        index: i,
        ...m,
        ...(step === 2 && kind === 'month' ? { askPrice: res[i * step + 1].result } : {}),
        ...(step === 2 && kind === 'std' && res[i * step + 1].result
          ? { pricePerWeight: res[i * step + 1].result[0], salePhase: Number(res[i * step + 1].result[1]) }
          : {}),
      });
    }
  } else d.machines = [];
  // X Layer：卖出 / 交接前 RIG 要在 1 天内同步过（XMonthMachineSales.syncFresh，审计 M-2）
  if (isXLayer(dep) && kind === 'month' && d.stateName === 'Settling' && d.salesAddress && d.machines.length) {
    const res = await client.multicall({
      contracts: d.machines.map((m) => ({ address: d.salesAddress, abi: XMonthSalesAbi, functionName: 'syncFresh', args: [address, BigInt(m.index)] })),
      allowFailure: true,
    });
    d.machines.forEach((m, i) => (m.syncFresh = res[i].result));
  }

  // 月局中奖者
  if (kind === 'month') {
    d.winners = [0, 1, 2, 3, 4].map((i) => ({ slot: d[`winnerSlots:${i}`], amount: d[`prizeAmounts:${i}`] }));
    const slots = d.winners.filter((w) => w.slot && w.slot !== 0n);
    if (d.prizesDrawn && slots.length) {
      const res = await client.multicall({
        contracts: slots.map((w) => ({ address, abi, functionName: 'socket', args: [w.slot] })),
        allowFailure: true,
      });
      slots.forEach((w, i) => (w.owner = res[i].result?.owner));
    }
  }

  // 标准局硅王
  if (kind === 'std' && d.kingSocket && d.kingSocket !== 0n) {
    d.king = await client.readContract({ address, abi, functionName: 'socket', args: [d.kingSocket] }).catch(() => undefined);
  }
  return d;
}

// ---------------------------------------------------------------- 事件（分段扫描）

/** 分段 getLogs：公共节点限制单次区块范围。maxChunks 控制最多往回查多远 */
export async function getLogsChunked(client, { address, event, args, fromBlock, chunk = 40_000n, maxChunks = 40, minChunk = 2_000n }) {
  const latest = await client.getBlockNumber();
  const start = BigInt(fromBlock ?? 0);
  const logs = [];
  let to = latest;
  let truncated = false;
  let size = BigInt(chunk);
  for (let i = 0; to >= start; i++) {
    if (i >= maxChunks) {
      truncated = true;
      break;
    }
    const from = to - size + 1n > start ? to - size + 1n : start;
    let part;
    try {
      part = await client.getLogs({ address, event, args, fromBlock: from, toBlock: to });
    } catch (e) {
      // 公共节点对一次查询的区块范围有限制（各家不同）：失败就把范围减半再试，减到 minChunk 还失败才报错
      if (size / 2n < minChunk) throw e;
      size /= 2n;
      continue;
    }
    logs.unshift(...part);
    to = from - 1n;
  }
  return { logs, latest, truncated };
}

/**
 * X Layer 节点一次 eth_getLogs 最多查 100 个区块：从最新区块往回切成 chunk 大小的段，每次并发查 group 段，最多查 maxChunks 段
 * （默认 400 段 = 4 万个区块，约 11 小时）。查失败的段直接报错（和 getLogsChunked 一样，让上层重试）。
 */
export async function getLogsRecent(client, { address, event, args, fromBlock, chunk = 100n, maxChunks = 400, group = 10 }) {
  const latest = await client.getBlockNumber();
  const start = BigInt(fromBlock ?? 0);
  const ranges = [];
  for (let to = latest; to >= start && ranges.length < maxChunks; to -= chunk) {
    ranges.push([to - chunk + 1n > start ? to - chunk + 1n : start, to]);
  }
  const logs = [];
  for (let i = 0; i < ranges.length; i += group) {
    // 公共节点偶尔拒掉批量里的某一个请求（"unknown RPC error"）：每段最多试 3 次
    const one = async ([from, to]) => {
      for (let k = 0; ; k++) {
        try {
          return await client.getLogs({ address, event, args, fromBlock: from, toBlock: to });
        } catch (e) {
          if (k >= 2) throw e;
          await new Promise((r) => setTimeout(r, 400 * (k + 1)));
        }
      }
    };
    const parts = await Promise.all(ranges.slice(i, i + group).map(one));
    parts.forEach((p) => logs.push(...p));
  }
  logs.sort((a, b) => (a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : a.blockNumber < b.blockNumber ? -1 : 1));
  return { logs, latest, truncated: ranges.length >= maxChunks };
}

export function eventAbi(abi, name) {
  return abi.find((x) => x.type === 'event' && x.name === name);
}

// ---------------------------------------------------------------- 通行证

const passKey = (chainId, account) => `tapesurge:passes:${chainId}:${account.toLowerCase()}`;

function readPassCache(chainId, account) {
  try {
    const v = JSON.parse(localStorage.getItem(passKey(chainId, account)) || 'null');
    return v && Array.isArray(v.ids) ? v : { ids: [], scanned: null };
  } catch {
    return { ids: [], scanned: null };
  }
}

function writePassCache(chainId, account, v) {
  try {
    localStorage.setItem(passKey(chainId, account), JSON.stringify(v));
  } catch {
    /* 忽略 */
  }
}

export function rememberPass(chainId, account, id) {
  const v = readPassCache(chainId, account);
  const s = String(id);
  if (!v.ids.includes(s)) v.ids.push(s);
  writePassCache(chainId, account, v);
}

/**
 * 找出钱包里的通行证：TapeOut 的电路合约不支持按持有人枚举，所以扫描转入本地址的 Transfer 事件，
 * 再逐个核对现在的持有人和网表哈希。扫描进度存在本地，下次只扫新区块。
 */
/**
 * 找钱包里的通行证。电路合约有 nextId() 和 balanceOf(地址) 时（主网）：按编号批量核对 ownerOf，不依赖查日志
 * （2026-10-27：公共节点查日志经常被拒，页面显示"读取通行证失败"）。先只看上次之后新流片的编号，数量还对不上
 * （比如从别人那里收到一张旧编号的）再全部核对一遍。读不到这两个接口（测试网 mock）时退回按转账日志找。
 */
export async function findPasses(client, dep, chainId, account, opts = {}) {
  let next;
  let balance;
  try {
    [next, balance] = await Promise.all([
      client.readContract({ address: dep.passCircuits, abi: circuitsAbi, functionName: 'nextId' }),
      client.readContract({ address: dep.passCircuits, abi: circuitsAbi, functionName: 'balanceOf', args: [account] }),
    ]);
  } catch {
    return findPassesByLogs(client, dep, chainId, account, opts);
  }
  const cache = readPassCache(chainId, account);
  const ids = new Set(cache.ids);
  const owned = async (from, to) => {
    for (let a = from; a < to; a += PASS_SCAN_BATCH) {
      const b = a + PASS_SCAN_BATCH < to ? a + PASS_SCAN_BATCH : to;
      const list = [];
      for (let id = a; id < b; id++) list.push(id);
      const res = await client.multicall({
        contracts: list.map((id) => ({ address: dep.passCircuits, abi: circuitsAbi, functionName: 'ownerOf', args: [id] })),
        allowFailure: true,
      });
      res.forEach((r, i) => {
        if (r.result && r.result.toLowerCase() === account.toLowerCase()) ids.add(String(list[i]));
      });
    }
  };
  const mine = () => [...ids];
  let found = await checkPasses(client, dep, account, mine());
  if (BigInt(found.length) < balance) {
    const scannedTo = cache.scannedId != null ? BigInt(cache.scannedId) : 0n;
    await owned(scannedTo + 1n > 1n ? scannedTo + 1n : 1n, next);
    found = await checkPasses(client, dep, account, mine());
    if (BigInt(found.length) < balance && scannedTo > 0n) {
      await owned(1n, scannedTo + 1n);
      found = await checkPasses(client, dep, account, mine());
    }
  }
  writePassCache(chainId, account, { ids: found.map((p) => String(p.id)), scanned: cache.scanned ?? null, scannedId: String(next - 1n) });
  return found;
}

const PASS_SCAN_BATCH = 500n;

async function findPassesByLogs(client, dep, chainId, account, { chunk } = {}) {
  const cache = readPassCache(chainId, account);
  const from = cache.scanned != null ? BigInt(cache.scanned) + 1n : BigInt(dep.fromBlock ?? 0);
  const { logs, latest } = await getLogsChunked(client, {
    address: dep.passCircuits,
    event: eventAbi(circuitsAbi, 'Transfer'),
    args: { to: account },
    fromBlock: from,
    chunk,
    maxChunks: 400,
  });
  const ids = new Set(cache.ids);
  for (const l of logs) ids.add(String(l.args.tokenId));
  writePassCache(chainId, account, { ids: [...ids], scanned: String(latest) });
  return checkPasses(client, dep, account, [...ids]);
}

export async function checkPasses(client, dep, account, ids) {
  if (!ids.length) return [];
  const res = await client.multicall({
    contracts: ids.flatMap((id) => [
      { address: dep.passCircuits, abi: circuitsAbi, functionName: 'ownerOf', args: [BigInt(id)] },
      { address: dep.passCircuits, abi: circuitsAbi, functionName: 'netlist', args: [BigInt(id)] },
    ]),
    allowFailure: true,
  });
  const out = [];
  ids.forEach((id, i) => {
    const owner = res[2 * i].result;
    const nl = res[2 * i + 1].result;
    if (!owner || owner.toLowerCase() !== account.toLowerCase()) return;
    out.push({ id: BigInt(id), standard: nl ? keccak256(nl) === PASS_NETLIST_HASH : false });
  });
  return out.sort((a, b) => (a.id < b.id ? -1 : 1));
}

// ---------------------------------------------------------------- 概率

/** 标准局：下一次脉冲选中某人出局的概率 = (S − w) / ((n − 1) S) */
export function ejectChance(stake, aliveStake, aliveCount) {
  const n = BigInt(aliveCount ?? 0);
  const S = BigInt(aliveStake ?? 0);
  if (n < 2n || S === 0n) return null;
  return Number(((S - BigInt(stake)) * 1_000_000n) / ((n - 1n) * S)) / 10_000; // 百分比
}

/** 月局：5 个奖独立按投入抽取，至少中一个的概率 = 1 − (1 − w/S)^5 */
export function monthWinChance(stake, totalStake) {
  const S = Number(totalStake ?? 0);
  if (!S) return null;
  const p = Number(stake) / S;
  return (1 - Math.pow(1 - p, 5)) * 100;
}
