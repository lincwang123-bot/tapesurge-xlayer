// TapeSurge 运营机器人。用法见 README.md。
//   npm start                 持续运行
//   npm run once              只跑一轮
//   npm run dry               只跑一轮，只模拟不发交易（不需要私钥）
import { existsSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { loadConfig } from './config.js';
import { initAbi } from './abi.js';
import { Sender, errorName, makeClients } from './chain.js';
import { State } from './state.js';
import { Alert } from './alert.js';
import * as log from './log.js';
import { handleMonth, handleStd, listBoards, readBoard, relayAndList } from './tasks/boards.js';
import { genesis, monitor, rigWatch, sentinel, splitter } from './tasks/system.js';
import { priceFeed, templateWatch } from './tasks/pricefeed.js';
import { relayBscFeed } from './tasks/xfeed.js';
import { firstoTrade } from './tasks/firstoTrade.js';
import { marketTrade } from './tasks/marketTrade.js';
import { rigMarket } from './tasks/rigMarket.js';
import { checkInterval } from './timing.js';

const cfg = loadConfig();
initAbi(cfg.network, cfg.dep.monthSales ? 'v2' : 'v1');
log.initLog(cfg.logFile, cfg.secrets);
const clients = makeClients(cfg);
const state = new State(cfg.stateFile);
const alert = new Alert(cfg, state);
const sender = new Sender(cfg, clients, alert);

// 按部署记录的时间倍率检查，最短 15 秒；主网保持正常间隔。
const every = (sec) => checkInterval(sec, cfg.dep, cfg.chainId);

function lock() {
  const file = `${cfg.stateFile}.lock`;
  if (existsSync(file)) {
    const pid = Number(readFileSync(file, 'utf8'));
    try {
      process.kill(pid, 0);
      throw new Error(`已经有一个机器人在跑（pid ${pid}）。同一个运营地址只能跑一个实例，否则 nonce 会冲突`);
    } catch (e) {
      if (e.code !== 'ESRCH') throw e;
    }
  }
  writeFileSync(file, String(process.pid));
  const release = () => {
    try {
      unlinkSync(file);
    } catch {
      /* 忽略 */
    }
  };
  process.on('exit', release);
  for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => process.exit(0));
}

/** 单项任务出错只记日志，不影响本轮其他任务 */
async function safe(name, fn) {
  try {
    await fn();
  } catch (e) {
    log.error(`${name} failed`, { reason: errorName(e) });
  }
}

async function tick() {
  const block = await clients.pub.getBlock();
  const ctx = {
    cfg,
    dep: cfg.dep,
    pub: clients.pub,
    bsc: clients.bsc,
    sender,
    state,
    alert,
    every,
    now: Number(block.timestamp),
    receivers: [],
    settling: [],
    summary: { block: Number(block.number) },
  };

  await sentinel(ctx);
  // X Layer：RIG 凭证合约的升级监控（链上检测不到，全局审计 2026-10-29 第 4 条）
  if (cfg.network === 'xlayer') await safe('rig watch', () => rigWatch(ctx));
  // X Layer：先转报 BSC 行情。开局要求报过价，收购和卖矿也只在报价有效时进行
  if (cfg.network === 'xlayer') await safe('bsc feed relay', () => relayBscFeed(ctx));
  const live = await genesis(ctx);
  if (live) {
    const boards = await listBoards(ctx);
    let active = 0;
    for (const { kind, address } of boards) {
      const s = state.board(address);
      if (s.done && !state.due(`recheck:${address}`, every(86_400))) continue;
      try {
        const b = await readBoard(ctx, kind, address);
        if (b.state === undefined) continue;
        active += s.done ? 0 : 1;
        if (kind === 'std') await handleStd(ctx, address, b);
        else await handleMonth(ctx, address, b);
      } catch (e) {
        log.error(`board ${address} failed`, { reason: errorName(e) });
      }
    }
    if (ctx.settling.length && state.due('relay', every(600))) await relayAndList(ctx);
    // X Layer：RIG 矿机市场（交接之后：剩下的矿机再配统一买单；正在收购的月局从最便宜的卖单往上买）
    if (cfg.network === 'xlayer') await safe('rig market', () => rigMarket(ctx));
    // rc8 起是 MarketTrader（多来源 + 挂单），rc5–rc7 是 FirstoTrader
    if (cfg.dep.marketTrader) await safe('market trade', () => marketTrade(ctx, boards));
    else await safe('firsto trade', () => firstoTrade(ctx, boards));
    ctx.summary.boards = boards.length;
    ctx.summary.active = active;
  }
  await splitter(ctx);
  await safe('price feed', () => priceFeed(ctx));
  await safe('template watch', () => templateWatch(ctx));
  await monitor(ctx);

  state.data.lastTick = { ...ctx.summary, at: new Date().toISOString(), sent: sender.sent, spent: `${Number(sender.spentWei) / 1e18} ${cfg.native}` };
  state.save();
  log.info('tick done', state.data.lastTick);
}

async function main() {
  log.info('TapeSurge bot starting', {
    chain: cfg.chainName,
    chainId: cfg.chainId,
    operator: cfg.account?.address ?? '(none, dry-run)',
    dryRun: cfg.dryRun,
    factory: cfg.dep.factory,
    interval: cfg.intervalSec,
    mockRandom: !!cfg.dep.mockRandom,
  });
  const chainId = await clients.pub.getChainId();
  if (chainId !== cfg.chainId) throw new Error(`RPC 的链 ID 是 ${chainId}，配置的是 ${cfg.chainId}`);
  if (!cfg.once) lock();

  let failures = 0;
  for (;;) {
    try {
      await tick();
      failures = 0;
    } catch (e) {
      failures += 1;
      log.error('tick failed', { reason: errorName(e), failures });
      if (failures >= 5) await alert.send('tick', `⚠️ 机器人连续 ${failures} 轮出错：${errorName(e)}`);
      state.save();
    }
    if (cfg.once) break;
    await new Promise((r) => setTimeout(r, cfg.intervalSec * 1000));
  }
}

main().catch((e) => {
  log.error('fatal', { reason: errorName(e) });
  process.exit(1);
});
