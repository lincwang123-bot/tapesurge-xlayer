// @TapeSurgeBot 提醒发送器（跑在 VPS 上，和运营机器人分开的服务）。设计见 ../../../Telegram提醒-设计.md。
// 每轮：从 Worker 读绑定名单 → 扫描新区块里的事件 → 给相关的人发私信；每天汇总一次待领取金额和领取期限。
// 只读链，不发交易，不需要运营私钥。环境变量：CHAIN_ID、DEPLOYMENT_FILE、RPC_URLS、NOTIFY_API（Worker 地址）、
// NOTIFIER_SECRET（读名单的口令）、REMINDER_BOT_TOKEN（@TapeSurgeBot 的令牌）、APP_URL、NOTIFY_STATE_FILE、NOTIFY_LOG_FILE。
import { loadConfig } from '../config.js';
import { ABI, initAbi } from '../abi.js';
import { makeClients, errorName } from '../chain.js';
import { State } from '../state.js';
import * as log from '../log.js';
import { listBoards } from '../tasks/boards.js';
import { M } from './messages.js';

const env = process.env;
process.env.DRY_RUN = '1'; // 只读：不加载运营私钥
const cfg = loadConfig([]);
cfg.stateFile = env.NOTIFY_STATE_FILE ?? cfg.stateFile.replace(/\.json$/, '.notify.json');
initAbi(cfg.network, cfg.dep.monthSales ? 'v2' : 'v1');
log.initLog(env.NOTIFY_LOG_FILE ?? cfg.logFile.replace(/\.log$/, '.notify.log'), [env.REMINDER_BOT_TOKEN, env.NOTIFIER_SECRET].filter(Boolean));
const { pub } = makeClients(cfg);
const state = new State(cfg.stateFile);
const APP = env.APP_URL ?? 'https://app.tapesurge.com';
const DIV = BigInt(cfg.dep.timeDivisor ?? 1); // 测试网时间倍率
const DAY = 86_400n / DIV;
const CLAIM_WINDOW = 365n * DAY;
const MIN_CLAIM = 10_000_000n; // 0.1 BEM 以下不提醒
const PER_HOUR = 10;
const once = process.argv.includes('--once');

const link = (kind, board) => `${APP}/#/board/${kind}/${board}`;
const lower = (a) => a.toLowerCase();

// ------------------------------------------------------------ 名单和发送

async function subscriptions() {
  const res = await fetch(`${env.NOTIFY_API}/api/subscriptions`, { headers: { authorization: `Bearer ${env.NOTIFIER_SECRET}` }, signal: AbortSignal.timeout(15_000) });
  if (!res.ok) throw new Error(`名单读取失败 HTTP ${res.status}`);
  const { subscriptions: rows } = await res.json();
  const byAddr = new Map();
  for (const r of rows) {
    const list = byAddr.get(r.address) ?? [];
    list.push({ chat: r.chat_id, lang: r.lang === 'en' ? 'en' : 'zh', off: new Set(String(r.off || '').split(',').filter(Boolean)) });
    byAddr.set(r.address, list);
  }
  return byAddr;
}

/** 给某个地址的所有订阅者发一类提醒；key 用来去重（同一件事只发一次） */
function queue(out, subs, address, category, key, render) {
  for (const s of subs.get(lower(address)) ?? []) {
    if (s.off.has(category)) continue;
    const k = `${key}:${s.chat}`;
    if (state.data.sent?.[k]) continue;
    out.push({ chat: s.chat, lang: s.lang, key: k, text: render(M[s.lang]) });
  }
}

async function send(out) {
  state.data.sent ??= {};
  state.data.rate ??= {};
  const hour = Math.floor(Date.now() / 3_600_000);
  const overflow = new Map();
  const langOf = new Map(out.map((m) => [m.chat, m.lang]));
  for (const m of out) {
    if (state.data.sent[m.key]) continue;
    const r = (state.data.rate[m.chat] = state.data.rate[m.chat]?.hour === hour ? state.data.rate[m.chat] : { hour, n: 0 });
    state.data.sent[m.key] = Math.floor(Date.now() / 1000); // 超出限额的也记为已处理，合并成一条摘要
    if (r.n >= PER_HOUR) {
      overflow.set(m.chat, (overflow.get(m.chat) ?? 0) + 1);
      continue;
    }
    r.n += 1;
    await tg(m.chat, m.text);
  }
  for (const [chat, n] of overflow) await tg(chat, M[langOf.get(chat) ?? 'zh'].overflow(n));
}

async function tg(chat, text) {
  const res = await fetch(`${env.TELEGRAM_API_BASE ?? 'https://api.telegram.org'}/bot${env.REMINDER_BOT_TOKEN}/sendMessage`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ chat_id: chat, text, disable_web_page_preview: true }),
    signal: AbortSignal.timeout(15_000),
  }).catch((e) => ({ ok: false, statusText: e.message }));
  if (!res.ok) log.warn('telegram send failed', { chat, status: res.status ?? res.statusText });
  else log.info('reminder sent', { chat, preview: text.slice(0, 60) });
}

// ------------------------------------------------------------ 读链

async function ownersOf(board, slots) {
  if (!slots.length) return [];
  const res = await pub.multicall({ contracts: slots.map((s) => ({ address: board, abi: ABI.month, functionName: 'socket', args: [BigInt(s)] })), allowFailure: true });
  return res.map((r) => r.result?.owner);
}

/** 订阅地址里，哪些在这块月局持有持仓，以及各自的插槽 */
async function holdings(board, subs) {
  const n = Number(await pub.readContract({ address: board, abi: ABI.month, functionName: 'socketCount' }));
  const owners = await ownersOf(board, Array.from({ length: n }, (_, i) => i + 1));
  const out = new Map();
  owners.forEach((o, i) => {
    if (o && subs.has(lower(o))) out.set(lower(o), [...(out.get(lower(o)) ?? []), BigInt(i + 1)]);
  });
  return out;
}

const EVENTS = {
  month: ['PrizesDrawn', 'TradeEpochBumped', 'RecruitmentFailed'],
  std: ['Pulse', 'RecruitmentFailed'],
  exchange: ['PositionTraded'],
  governor: ['VoteOpened', 'VoteFinalized', 'PlanExecuted', 'ProposalExpired'],
};
const ev = (abi, names) => abi.filter((x) => x.type === 'event' && names.includes(x.name));

async function scanEvents(subs, boards, from, to, out) {
  const kindOf = new Map(boards.map((b) => [lower(b.address), b.kind]));
  const numberOf = state.data.numbers ??= {};
  const num = async (kind, b) =>
    (numberOf[lower(b)] ??= Number(await pub.readContract({ address: b, abi: kind === 'std' ? ABI.std : ABI.month, functionName: 'number' }).catch(() => 0)));
  const month = boards.filter((b) => b.kind === 'month').map((b) => b.address);
  const std = boards.filter((b) => b.kind === 'std').map((b) => b.address);
  // 公共节点一次最多查 10 个地址（publicnode 的限制），按 10 个一批分开查再合并
  const get = async (address, abi, names) => {
    const out = [];
    for (let i = 0; i < address.length; i += 10)
      out.push(...(await pub.getLogs({ address: address.slice(i, i + 10), events: ev(abi, names), fromBlock: from, toBlock: to })));
    return out;
  };
  const [mLogs, sLogs, xLogs, gLogs] = await Promise.all([
    get(month, ABI.month, EVENTS.month),
    get(std, ABI.std, EVENTS.std),
    cfg.dep.positionExchange && ABI.exchange ? get([cfg.dep.positionExchange], ABI.exchange, EVENTS.exchange) : [],
    cfg.dep.monthGovernor && ABI.monthGovernor ? get([cfg.dep.monthGovernor], ABI.monthGovernor, EVENTS.governor) : [],
  ]);
  const id = (l) => `${l.transactionHash}:${l.logIndex}`;

  for (const l of mLogs) {
    const b = l.address;
    const n = await num('month', b);
    if (l.eventName === 'PrizesDrawn') {
      const owners = await ownersOf(b, l.args.slots.map(Number));
      owners.forEach((o, i) => o && queue(out, subs, o, 'prize', `prize:${id(l)}:${i}`, (t) => t.prize({ board: n, amount: l.args.amounts[i], link: link('month', b) })));
    } else if (l.eventName === 'TradeEpochBumped' && ABI.exchange) {
      // 卖单失效：本局所有曾经挂过卖单、且挂单人是订阅地址的
      const asks = await pub.readContract({ address: cfg.dep.positionExchange, abi: ABI.exchange, functionName: 'asksOf', args: [b, 0n, 0n] }).catch(() => []);
      for (const a of asks) if (subs.has(lower(a.maker))) queue(out, subs, a.maker, 'ask', `ask:${id(l)}`, (t) => t.ask({ board: n, link: link('month', b) }));
    } else if (l.eventName === 'RecruitmentFailed') {
      for (const [a] of await holdings(b, subs)) queue(out, subs, a, 'refund', `refund:${b}`, (t) => t.refund({ kind: 'month', board: n, link: link('month', b) }));
    }
  }
  for (const l of sLogs) {
    const b = l.address;
    const n = await num('std', b);
    if (l.eventName === 'Pulse') queue(out, subs, l.args.player, 'eject', `eject:${id(l)}`, (t) => t.eject({ board: n, payout: l.args.payout, link: link('std', b) }));
    else if (l.eventName === 'RecruitmentFailed') {
      const joined = await pub.getLogs({ address: b, event: ev(ABI.std, ['Joined'])[0], fromBlock: BigInt(cfg.dep.fromBlock ?? 0), toBlock: to }).catch(() => []);
      for (const j of joined) queue(out, subs, j.args.player, 'refund', `refund:${b}`, (t) => t.refund({ kind: 'std', board: n, link: link('std', b) }));
    }
  }
  for (const l of xLogs) {
    const b = l.args.board;
    const n = await num('month', b);
    const p = { board: n, slot: Number(l.args.slot), unit: l.args.unitPrice, cost: l.args.cost, link: link('month', b) };
    queue(out, subs, l.args.seller, 'trade', `sell:${id(l)}`, (t) => t.tradeSell(p));
    queue(out, subs, l.args.buyer, 'trade', `buy:${id(l)}`, (t) => t.tradeBuy(p));
  }
  for (const l of gLogs) {
    const b = l.args.board;
    if (!kindOf.has(lower(b))) continue;
    const n = await num('month', b);
    const holders = await holdings(b, subs);
    const L = link('month', b);
    if (l.eventName === 'VoteOpened') {
      const p = await pub.readContract({ address: cfg.dep.monthGovernor, abi: ABI.monthGovernor, functionName: 'proposals', args: [b] });
      const voteEnd = Number(p[2]);
      (state.data.votes ??= {})[`${b}:${l.args.proposalId}`] = { board: b, id: String(l.args.proposalId), voteEnd };
      for (const [a] of holders) queue(out, subs, a, 'vote', `vote:${id(l)}`, (t) => t.vote({ board: n, end: endText(voteEnd, t), link: L }));
    } else {
      const which = l.eventName === 'VoteFinalized' ? (l.args.passed ? 'resultPassed' : 'resultFailed') : l.eventName === 'PlanExecuted' ? 'resultExecuted' : 'resultExpired';
      for (const [a] of holders) queue(out, subs, a, 'result', `${which}:${id(l)}`, (t) => t[which]({ board: n, link: L }));
    }
  }
}

function endText(ts, t) {
  const d = new Date(ts * 1000);
  const zh = t === M.zh;
  return d.toLocaleString(zh ? 'zh-CN' : 'en-GB', { timeZone: 'Asia/Shanghai', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }) + (zh ? '（北京时间）' : ' (UTC+8)');
}

/** 投票截止前 6 小时（测试网按倍率缩短），还有持仓没投票的再提醒一次 */
async function voteReminders(subs, now, out) {
  const votes = state.data.votes ?? {};
  for (const [k, v] of Object.entries(votes)) {
    if (now >= v.voteEnd) {
      delete votes[k];
      continue;
    }
    if (now < v.voteEnd - Number(6n * 3_600n / DIV)) continue;
    const n = state.data.numbers?.[lower(v.board)] ?? 0;
    for (const [a, slots] of await holdings(v.board, subs)) {
      const res = await pub.multicall({
        contracts: slots.map((s) => ({ address: cfg.dep.monthGovernor, abi: ABI.monthGovernor, functionName: 'voteOf', args: [v.board, BigInt(v.id), s] })),
        allowFailure: true,
      });
      if (res.some((r) => Number(r.result ?? 0) === 0)) queue(out, subs, a, 'vote', `remind:${k}`, (t) => t.voteRemind({ board: n, end: endText(v.voteEnd, t), link: link('month', v.board) }));
    }
  }
}

/** 每天一次：待领取汇总；领取期限还剩 30 / 7 / 1 天 */
async function daily(subs, boards, now, out) {
  const day = Math.floor(now / Number(DAY));
  if (state.data.dailyDay === day) return;
  const per = new Map(); // 地址 → [{kind, board, number, amount, closesAt}]
  for (const { kind, address: b } of boards) {
    const abi = kind === 'std' ? ABI.std : ABI.month;
    const [closed, finishedAt, number] = await pub.multicall({
      contracts: ['claimsClosed', 'finishedAt', 'number'].map((functionName) => ({ address: b, abi, functionName })),
      allowFailure: true,
    });
    if (closed.result) continue;
    const addrs = [...subs.keys()];
    let amounts;
    // v2.0-rc6 前的标准局按地址记账（owed(address)）；rc6 起按持仓：TapeBoard.credit(地址) + StdMachineSales.owed(主板, 持仓号)，和月局同一种算法
    const stdByAddress = kind === 'std' && abi.some((f) => f.type === 'function' && f.name === 'owed');
    if (stdByAddress) {
      const res = await pub.multicall({ contracts: addrs.flatMap((a) => ['owed', 'credit'].map((f) => ({ address: b, abi, functionName: f, args: [a] }))), allowFailure: true });
      amounts = addrs.map((_, i) => (res[2 * i].result ?? 0n) + (res[2 * i + 1].result ?? 0n));
    } else {
      const held = await holdings(b, subs);
      const owedOf = (s) => (kind === 'std' ? { address: cfg.dep.stdSales, abi: ABI.stdSales, functionName: 'owed', args: [b, s] } : { address: b, abi, functionName: 'owed', args: [s] });
      const res = await pub.multicall({
        contracts: addrs.flatMap((a) => [{ address: b, abi, functionName: 'credit', args: [a] }, ...(held.get(a) ?? []).map(owedOf)]),
        allowFailure: true,
      });
      let k = 0;
      amounts = addrs.map((a) => {
        let sum = 0n;
        for (let j = 0; j < 1 + (held.get(a)?.length ?? 0); j++) sum += res[k++].result ?? 0n;
        return sum;
      });
    }
    const fin = BigInt(finishedAt.result ?? 0n);
    addrs.forEach((a, i) => {
      if (amounts[i] > 0n) per.set(a, [...(per.get(a) ?? []), { kind, board: b, number: Number(number.result ?? 0), amount: amounts[i], closesAt: fin > 0n ? fin + CLAIM_WINDOW : 0n }]);
    });
  }
  for (const [a, items] of per) {
    const total = items.reduce((s, x) => s + x.amount, 0n);
    if (total >= MIN_CLAIM) {
      queue(out, subs, a, 'claim', `claim:${day}`, (t) => t.claim({ total, items: items.map((x) => t.claimItem({ kind: x.kind, board: x.number, amount: x.amount })), link: `${APP}/#/me` }));
    }
    for (const x of items) {
      if (!x.closesAt) continue;
      const left = Number(x.closesAt - BigInt(now)) / Number(DAY);
      for (const mark of [30, 7, 1]) {
        if (left > 0 && left <= mark) {
          queue(out, subs, a, 'deadline', `deadline:${x.board}:${mark}`, (t) => t.deadline({ kind: x.kind, board: x.number, days: Math.ceil(left), amount: x.amount, link: link(x.kind, x.board) }));
          break;
        }
      }
    }
  }
  state.data.dailyDay = day;
}

// ------------------------------------------------------------ 主循环

async function tick() {
  const subs = await subscriptions();
  const latest = await pub.getBlockNumber();
  const now = Number((await pub.getBlock()).timestamp);
  // 第一次运行从当前区块开始，不补发历史事件
  let from = state.data.lastBlock != null ? BigInt(state.data.lastBlock) + 1n : latest;
  const out = [];
  if (subs.size) {
    const boards = await listBoards({ pub, dep: cfg.dep, state });
    while (from <= latest) {
      const to = from + 4_999n < latest ? from + 4_999n : latest;
      await scanEvents(subs, boards, from, to, out);
      from = to + 1n;
    }
    await voteReminders(subs, now, out);
    await daily(subs, boards, now, out);
    await send(out);
  }
  state.data.lastBlock = String(latest);
  // 去重记录只留 60 天
  const cutoff = Math.floor(Date.now() / 1000) - 60 * 86_400;
  for (const [k, t] of Object.entries(state.data.sent ?? {})) if (t < cutoff) delete state.data.sent[k];
  state.save();
  log.info('notify tick', { block: Number(latest), subscribers: subs.size, sent: out.length });
}

async function main() {
  for (const k of ['NOTIFY_API', 'NOTIFIER_SECRET', 'REMINDER_BOT_TOKEN']) if (!env[k]) throw new Error(`缺少环境变量 ${k}`);
  log.info('TapeSurge notifier starting', { chain: cfg.chainName, app: APP, api: env.NOTIFY_API });
  for (;;) {
    try {
      await tick();
    } catch (e) {
      // viem 的错误信息里带出错的 RPC 方法和参数，留一段方便排查（RPC 地址在写日志时会被遮掉）
      log.error('notify tick failed', { reason: errorName(e), detail: String(e?.message ?? e).slice(0, 800) });
    }
    if (once) return;
    await new Promise((r) => setTimeout(r, Number(env.NOTIFY_INTERVAL_SEC ?? 180) * 1000));
  }
}

main();
