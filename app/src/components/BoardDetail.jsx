import { useApp } from '../App.jsx';
import { useAsync, useNow } from '../lib/useAsync.js';
import { SETTLE_MODE, loadBoardDetail } from '../lib/protocol.js';
import { explorerAddr } from '../lib/chains.js';
import { fmtBEM, fmtInt, fmtTime, pct, shortAddr } from '../lib/format.js';
import { kindLabel, phaseLine, stateLabel } from './BoardCard.jsx';
import JoinPanel from './board/JoinPanel.jsx';
import MyPosition from './board/MyPosition.jsx';
import MonthMyPositions from './board/MonthMyPositions.jsx';
import { OrderBook } from './board/PositionTrade.jsx';
import Liquidation from './board/Liquidation.jsx';
import Machines from './board/Machines.jsx';
import History from './board/History.jsx';
import Fallback from './board/Fallback.jsx';
import './board-detail-ui.css';

function Kv({ label, value }) {
  return (
    <div className="stat">
      <span className="stat-label">{label}</span>
      <span className="stat-value">{value}</span>
    </div>
  );
}

function Numbers({ d, kind }) {
  const { lang } = useApp();
  const zh = lang === 'zh';
  const items = [
    [zh ? '总投入' : 'Total staked', `${fmtBEM(d.totalStake, 2)} / ${fmtBEM(d.target, 0)} BEM`, true],
    [zh ? '参与人数' : 'Players', fmtInt(d.socketCount), true],
  ];
  if (d.stateName === 'Recruiting') {
    items.push([zh ? '招募截止' : 'Joins close', fmtTime(d.recruitDeadline, lang)]);
    items.push([zh ? '单人投入' : 'Stake range', `${fmtBEM(d.minStake, 2)}–${fmtBEM(d.maxStake, 2)} BEM`]);
  }
  if (kind === 'std' && (d.stateName === 'Active' || d.stateName === 'Liquidating')) {
    items.push([zh ? '在局' : 'In play', `${fmtInt(d.aliveCount)} ${zh ? '人' : ''}`, true]);
    items.push([zh ? '脉冲池' : 'Pulse pool', `${fmtBEM(d.pool, 4)} BEM`, true]);
    items.push([zh ? '矿机花费' : 'Spent on machines', `${fmtBEM(d.totalSpent, 2)} BEM`]);
    items.push([zh ? '收购预算剩余' : 'Budget left', `${fmtBEM(d.budget, 2)} BEM`]);
    if (d.totalSubsidy) items.push([zh ? '首批回馈补贴' : 'Early-board reward', `${fmtBEM(d.totalSubsidy, 2)} BEM`]);
    if (d.king?.owner) items.push([zh ? '硅王' : 'Silicon King', shortAddr(d.king.owner)]);
    if (d.stateName === 'Liquidating') items.push([zh ? '结局方式' : 'Settlement', settleName(d.settleMode, zh)]);
  }
  if (kind === 'month' && ['Preparing', 'Mining', 'Drawing', 'Settling'].includes(d.stateName)) {
    if (d.stateName === 'Preparing') items.push([zh ? '准备期截止' : 'Preparation ends', fmtTime(d.prepEnd, lang)]);
    if (d.miningStart && d.miningStart !== 0n) {
      items.push([zh ? '挖矿期' : 'Mining', `${fmtTime(d.miningStart, lang)} → ${fmtTime(d.miningEnd, lang)}`]);
    }
    // 开奖后合约把 prizePool 清零（奖金已经记到 5 个中奖持仓上），这时改为显示已开出的奖金合计
    if (d.prizesDrawn) items.push([zh ? '已开奖金' : 'Prizes paid', `${fmtBEM(d.winners.reduce((a, w) => a + (w.amount ?? 0n), 0n), 4)} BEM`, true]);
    else items.push([zh ? '奖金池' : 'Prize pool', `${fmtBEM(d.prizePool, 4)} BEM`, true]);
    items.push([zh ? '矿机成本' : 'Machine cost', `${fmtBEM(d.totalSpent, 2)} BEM`]);
    if (d.subsidyCapital) items.push([zh ? '回馈资本' : 'Reward capital', `${fmtBEM(d.subsidyCapital, 2)} BEM`]);
    if (d.stateName === 'Settling') items.push([zh ? '待退本金' : 'Stake still to return', `${fmtBEM(d.principalRemaining, 4)} BEM`, true]);
  }
  const primary = items.filter(([, , main]) => main);
  const secondary = items.filter(([, , main]) => !main);
  return (
    <div className="board-detail-numbers">
      <div className="stats board-detail-key-stats" style={{ '--metric-count': primary.length }}>
        {primary.map(([l, v]) => (
          <Kv key={l} label={l} value={v} />
        ))}
      </div>
      {secondary.length > 0 && (
        <dl className="board-detail-facts">
          {secondary.map(([l, v]) => (
            <div key={l}>
              <dt className="stat-label">{l}</dt>
              <dd className="stat-value">{v}</dd>
            </div>
          ))}
        </dl>
      )}
    </div>
  );
}

/** 仅说明已有阶段，不推断链上状态，也不触发推进操作。 */
function PhaseSummary({ d, now, lang }) {
  const zh = lang === 'zh';
  let next;
  switch (d.stateName) {
    case 'Failed':
      next = d.claimsClosed
        ? zh ? '查看持仓的领取期限与通行证退回状态。' : 'Check the claim window and pass-return status for your positions.'
        : zh ? '参与者可在下方持仓中领取待退金额并取回通行证。' : 'Participants can claim refundable funds and recover passes from their positions below.';
      break;
    case 'Active':
      next = d.drawPending
        ? zh ? '等待随机数返回，随后确认本次脉冲的出局结果。' : 'Wait for randomness, then finalize this pulse’s ejection.'
        : zh ? '脉冲池达到门槛后，按链上规则推进下一次出局。' : 'Once the pulse pool reaches its threshold, the next ejection can proceed under the onchain rules.';
      break;
    case 'Liquidating':
      next = d.finishedAt && d.finishedAt !== 0n
        ? zh ? '查看持仓中的可领取金额与通行证状态。' : 'Check claimable funds and pass status in your positions.'
        : zh ? '跟踪矿机出售进度，回款按本局结算规则分配。' : 'Follow machine sales; proceeds are distributed under this board’s settlement rules.';
      break;
    case 'Preparing':
      next = Number(d.prepEnd) > now
        ? zh ? '买满（100 台，或剩余预算买不下一台）就提前开始挖矿，否则准备期结束后开始。' : 'Mining starts as soon as the board is bought out (100 machines, or the budget left cannot buy one), otherwise when preparation ends.'
        : zh ? '准备期已结束，等待链上推进到挖矿阶段。' : 'Preparation has ended; the next onchain step starts mining.';
      break;
    case 'Mining':
      next = Number(d.miningEnd) > now
        ? zh ? '挖矿期结束后请求开奖，完成分配后进入结算。' : 'After mining ends, request the draw; settlement follows the distribution.'
        : zh ? '挖矿期已结束，等待请求开奖并完成分配。' : 'Mining has ended; the draw and distribution are next.';
      break;
    case 'Drawing':
      next = d.wordReceived
        ? zh ? '随机数已到，等待完成开奖与奖金分配。' : 'Randomness has arrived; finalizing the draw and prize distribution is next.'
        : zh ? '等待随机数返回，完成开奖后进入结算。' : 'Wait for randomness; settlement follows the completed draw.';
      break;
    case 'Settling':
      next = d.principalRemaining === 0n
        ? zh ? '查看持仓中的可领取金额与通行证状态。' : 'Check claimable funds and pass status in your positions.'
        : zh ? '跟踪矿机出售、交接及待退本金，查看持仓的可领取金额。' : 'Follow machine sales, handovers and outstanding principal, then check claimable amounts in your positions.';
      break;
    default:
      next = zh ? '以当前链上状态和下方操作说明为准。' : 'Follow the current onchain state and the instructions below.';
  }
  return (
    <div className="board-phase-summary">
      <div>
        <span className="board-phase-label">{zh ? '当前阶段' : 'Current phase'}</span>
        <p>{phaseLine(d, now, lang)}</p>
      </div>
      <div>
        <span className="board-phase-label">{zh ? '下一步' : 'Next step'}</span>
        <p>{next}</p>
      </div>
    </div>
  );
}

function settleName(mode, zh) {
  const name = SETTLE_MODE[Number(mode ?? 0)];
  const map = {
    Normal: ['正常终局：65% 按投入分给其他人，30% 硅王', 'Normal: 65% by stake to others, 30% to the King'],
    Fallback: ['保底分配：收 2% 手续费后，先退未出局者的投入，剩余按投入分', 'Fallback: 2% fee, then stakes still in play first, then by stake'],
    SafeExit: ['安全退出（随机数停摆，分配同保底，收 2% 手续费）', 'Safe exit (randomness stalled; same split as fallback, 2% fee)'],
  };
  return map[name]?.[zh ? 0 : 1] ?? name;
}

export default function BoardDetail({ kind, address }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const now = useNow();
  const q = useAsync(() => loadBoardDetail(app.client, app.dep, kind, address, app.wallet.account), [kind, address, app.wallet.account, app.chainId], {
    refresh: app.version,
    interval: 15_000,
  });
  const d = q.data;

  if (!d) {
    return (
      <div className="board-detail">
        <a className="back" href={`#/boards/${kind}`}>
          ← {zh ? '返回列表' : 'All boards'}
        </a>
        <p className="muted">{q.error ? (zh ? '读取失败，正在重试…' : 'Could not load; retrying…') : zh ? '读取中…' : 'Loading…'}</p>
      </div>
    );
  }
  if (!d.registered || d.state === undefined || d.stateName === 'Uninitialized') {
    return (
      <p className="tx-error">
        {zh ? '这不是 TapeSurge 的主板地址，请不要在这个页面授权或转账。' : 'This is not a TapeSurge board. Do not approve or send anything here.'}
      </p>
    );
  }

  const canJoin = d.stateName === 'Recruiting' && Number(d.recruitDeadline) > now && (!d.mySlot || d.mySlot === 0n);
  const progress = Math.min(100, Number(pct(d.totalStake ?? 0n, d.target ?? 1n)));

  return (
    <div className="board-detail">
      <a className="back" href={`#/boards/${kind}`}>
        ← {zh ? '返回列表' : 'All boards'}
      </a>
      <section className="panel board-head">
        <div className="board-card-top">
          <span className="board-kind">{kindLabel(kind, app.lang)}</span>
          <h1 className="board-no">#{String(d.number)}</h1>
          <span className={`pill state-${d.stateName}`}>{stateLabel(kind, d.stateName, app.lang)}</span>
          {d.sentinelPaused && <span className="pill pill-warn">{zh ? '升级冷静期' : 'Upgrade cooling period'}</span>}
        </div>
        {d.stateName === 'Recruiting' ? (
          <div className="board-recruitment-progress">
            <p className="board-card-line">{phaseLine(d, now, app.lang)}</p>
            <div className="progress">
              <div className="progress-bar" style={{ width: `${progress}%` }} />
            </div>
          </div>
        ) : (
          <PhaseSummary d={d} now={now} lang={app.lang} />
        )}
        <Numbers d={d} kind={kind} />
        <p className="muted small board-detail-addresses">
          {zh ? '合约地址 ' : 'Contract '}
          <a href={explorerAddr(app.chainId, d.address)} target="_blank" rel="noreferrer">
            {shortAddr(d.address)}
          </a>
          {d.operator && (
            <>
              {' · '}
              {zh ? '运营地址 ' : 'Operator '}
              <a href={explorerAddr(app.chainId, d.operator)} target="_blank" rel="noreferrer">
                {shortAddr(d.operator)}
              </a>
            </>
          )}
        </p>
      </section>

      <div className={`two-col board-detail-layout${d.stateName === 'Recruiting' || d.stateName === 'Failed' ? ' is-stacked' : ''}`}>
        <div className="col board-detail-primary">
          {canJoin && <JoinPanel d={d} kind={kind} />}
          {kind === 'std' && <MyPosition d={d} />}
          {kind === 'month' && <MonthMyPositions d={d} />}
          {app.dep.positionExchange && <OrderBook d={d} kind={kind} />}
          {kind === 'month' && <Liquidation d={d} />}
          <History d={d} kind={kind} />
        </div>
        <div className="col board-detail-secondary">
          {d.stateName !== 'Recruiting' && d.stateName !== 'Failed' && <Machines d={d} kind={kind} />}
          <Fallback d={d} kind={kind} />
        </div>
      </div>
    </div>
  );
}
