// v2 月局：多数集体清算（MonthExitGovernor）。
// 结算阶段的持有人可以按原始本金加权、严格过半，批准一个低于成本价的售矿计划，把整块月局卖掉结算。
// 步骤：发布计划 → 表态支持（≥ 10% 才能发起）→ 24 小时投票（锁定转让）→ 结算投票 → 等 24 小时 → 48 小时内执行。
import { useState } from 'react';
import { logClientOf } from '../../lib/chains.js';
import { useApp } from '../../App.jsx';
import { useAsync } from '../../lib/useAsync.js';
import { CHOICE, GovernorAbi, loadGovernance, planFromPercent } from '../../lib/governance.js';
import { fmtBEM, fmtDuration, fmtTime, pct } from '../../lib/format.js';
import { TxStatus, WalletGate, useTx } from '../TxButton.jsx';

const short = (h) => `${h.slice(0, 8)}…${h.slice(-4)}`;
const CHOICE_TEXT = {
  [CHOICE.YES]: ['赞成', 'Yes'],
  [CHOICE.NO]: ['反对', 'No'],
  [CHOICE.ABSTAIN]: ['弃权', 'Abstain'],
};

export default function Liquidation({ d }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const gov = d.GOVERNOR ?? app.dep.monthGovernor;
  const active = !!gov && d.stateName === 'Settling' && !d.claimsClosed;
  const q = useAsync(
    () => (active ? loadGovernance(app.client, app.dep, d, app.wallet.account, app.net.logChunk, logClientOf(app.chainId)) : Promise.resolve(null)),
    [d.address, app.wallet.account, active],
    { refresh: app.version, interval: 20_000 },
  );
  if (!active) return null;
  const g = q.data;
  const t = (a, b) => (zh ? a : b);

  return (
    <section className="panel liquidation">
      <div className="panel-head">
        <h2>{t('多数集体清算', 'Majority liquidation')}</h2>
        <p className="muted">
          {t(
            '矿机价格低于成本价时，合约不会自动低价卖出。持有人可以提出一个售矿计划（每台矿机的起价和底价），按原始本金加权投票，赞成严格超过全部本金的一半才通过。通过后矿机在 7 天内从起价降到底价出售，但成交价不低于当时市场买一的 95%（可以一起止损，不能低于市价甩卖），报价过期时暂停；回款按投入比例退给持有人。投票和等待执行期间，持仓暂停转让。',
            'Machines are never sold below cost automatically. Holders can propose a sale plan (start and floor price per machine) and vote, weighted by original stake; it passes only with yes votes above half of all stake. Machines then sell on a 7-day price decline, never below 95% of the current market bid (paused while the quote is stale), and proceeds go to holders pro rata. Transfers are locked during the vote and the execution wait.',
          )}
        </p>
      </div>
      {!g && <p className="muted small">{q.error ? t('读取失败，稍后自动重试', 'Failed to load; retrying') : t('读取中…', 'Loading…')}</p>}
      {g && (
        <>
          <Status d={d} g={g} />
          {g.proposal.phase === 'Voting' && <VotePanel d={d} g={g} />}
          {g.proposal.phase === 'Delay' && <DelayPanel d={d} g={g} />}
          {g.proposal.phase === 'None' && (
            <>
              <PlanList d={d} g={g} />
              {d.unsoldMachines > 0n && <PublishPlan d={d} g={g} />}
            </>
          )}
        </>
      )}
    </section>
  );
}

/** 当前阶段一句话 + 关键时间 */
function Status({ d, g }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const t = (a, b) => (zh ? a : b);
  const dur = (x) => fmtDuration(x, app.lang);
  const p = g.proposal;
  const rows = [];
  if (d.liquidating) {
    rows.push([
      t('状态', 'Status'),
      t('已在清算中：没卖出的矿机按批准的计划价出售。还可以提出更低的计划（改价）', 'Liquidating at the approved plan prices; a lower plan (reprice) can still be proposed'),
    ]);
  }
  if (p.phase === 'Voting') rows.push([t('投票截止', 'Vote ends'), `${fmtTime(p.voteEnd, app.lang)}（${g.now < p.voteEnd ? t('还有 ', '') + dur(p.voteEnd - g.now) : t('已截止', 'ended')}）`]);
  if (p.phase === 'Delay') {
    rows.push([t('最早执行', 'Executable from'), fmtTime(p.executeAfter, app.lang)]);
    rows.push([t('执行期限', 'Execute by'), fmtTime(p.executeBy, app.lang)]);
  }
  if (p.phase === 'None') {
    if (g.now < g.earliestOpen) rows.push([t('最早发起投票', 'Earliest vote'), `${fmtTime(g.earliestOpen, app.lang)}（${t('结算开始满 ', '')}${dur(g.MIN_SETTLE_AGE)}${t('', ' after settlement')}）`]);
    if (g.now < g.cooldownUntil) rows.push([t('冷却到', 'Cooldown until'), `${fmtTime(g.cooldownUntil, app.lang)}（${t('上一次提案没通过或没执行', 'last proposal failed or expired')}）`]);
    rows.push([t('发起需要的支持', 'Support needed'), `${fmtBEM(g.supportNeeded, 2)} BEM（${t('全部本金的 10%', '10% of all stake')}）`]);
  }
  rows.push([t('全部原始本金', 'Total stake'), `${fmtBEM(g.totalStake, 2)} BEM`]);
  return (
    <dl className="kv">
      {rows.map(([k, v]) => (
        <div key={k}>
          <dt>{k}</dt>
          <dd>{v}</dd>
        </div>
      ))}
    </dl>
  );
}

/** 计划内容：每台矿机的成本、起价、底价 */
function PlanTable({ d, items }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const cost = (i) => d.machines.find((m) => BigInt(m.index) === BigInt(i))?.cost ?? 0n;
  return (
    <div className="table-wrap">
      <table>
        <thead>
          <tr>
            <th>{zh ? '矿机' : 'Machine'}</th>
            <th>{zh ? '成本' : 'Cost'}</th>
            <th>{zh ? '起价' : 'Start'}</th>
            <th>{zh ? '底价' : 'Floor'}</th>
          </tr>
        </thead>
        <tbody>
          {items.map((it) => {
            const c = cost(it.index);
            return (
              <tr key={String(it.index)}>
                <td>#{String(it.index)}</td>
                <td>{fmtBEM(c, 2)}</td>
                <td>
                  {fmtBEM(it.start, 2)} <small>{pct(it.start, c, 0)}%</small>
                </td>
                <td>
                  {fmtBEM(it.floor, 2)} <small>{pct(it.floor, c, 0)}%</small>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

/** 已发布的计划：支持 / 撤回支持 / 发起投票 */
function PlanList({ d, g }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const t = (a, b) => (zh ? a : b);
  if (!g.plans.length) return <p className="muted small">{t('还没有人发布售矿计划。', 'No sale plan has been published yet.')}</p>;
  return (
    <div className="plan-list">
      <h3>{t('已发布的计划', 'Published plans')}</h3>
      {g.plans.map((p) => (
        <PlanCard key={p.hash} d={d} g={g} p={p} />
      ))}
    </div>
  );
}

function PlanCard({ d, g, p }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const t = (a, b) => (zh ? a : b);
  const tx = useTx();
  const mine = g.myPositions;
  const mineSupporting = mine.filter((x) => x.supporting === p.hash);
  const mineOther = mine.filter((x) => x.supporting !== p.hash);
  const enough = p.weight >= g.supportNeeded;
  const timeOk = g.now >= g.earliestOpen && g.now >= g.cooldownUntil;
  // 计划发布后又卖出了矿机：合约要求计划列出发起时全部没卖出的矿机，这份计划就不能再发起了
  const stale = p.items.some((it) => d.machines.find((m) => BigInt(m.index) === it.index)?.sold) || BigInt(p.items.length) !== d.unsoldMachines;
  const call = (functionName, args) => ({ address: g.gov, abi: GovernorAbi, functionName, args });
  const sorted = (xs) => xs.map((x) => x.slot).sort((a, b) => (a < b ? -1 : 1));

  if (p.executed) {
    return (
      <div className="position-card">
        <h3>
          {t('计划', 'Plan')} {short(p.hash)} <span className="muted small">· {t('已执行', 'executed')}</span>
        </h3>
        <PlanTable d={d} items={p.items} />
        <p className="muted small">{t('这个计划已经通过并执行。要改价，请发布一个新的计划。', 'This plan was approved and executed. Publish a new plan to reprice.')}</p>
      </div>
    );
  }

  return (
    <div className="position-card">
      <h3>
        {t('计划', 'Plan')} {short(p.hash)}
      </h3>
      <PlanTable d={d} items={p.items} />
      <div>
        <p className="small">
          {t('有效支持', 'Support')} {fmtBEM(p.weight, 2)} / {fmtBEM(g.supportNeeded, 2)} BEM（{pct(p.weight, g.totalStake)}% {t('的全部本金', 'of stake')}）
        </p>
        <div className="progress small">
          <div className="progress-bar" style={{ width: `${Math.min(100, Number(pct(p.weight, g.supportNeeded, 0)))}%` }} />
        </div>
      </div>
      {stale && <p className="muted small">{t('发布后又卖出了矿机，这份计划已不完整，需要重新发布。', 'A machine was sold after publishing; publish a new plan.')}</p>}
      <WalletGate>
        <div className="row">
          {mineOther.length > 0 && (
            <button className="btn btn-ghost btn-sm" disabled={tx.busy} onClick={() => tx.run({ label: t('支持', 'Support'), ...call('support', [d.address, sorted(mineOther), p.hash]) })}>
              {t(`用我的 ${mineOther.length} 份持仓支持`, `Support with my ${mineOther.length} position(s)`)}
            </button>
          )}
          {mineSupporting.length > 0 && (
            <button className="btn btn-ghost btn-sm" disabled={tx.busy} onClick={() => tx.run({ label: t('撤回支持', 'Withdraw'), ...call('withdrawSupport', [d.address, sorted(mineSupporting)]) })}>
              {t('撤回我的支持', 'Withdraw my support')}
            </button>
          )}
          <button
            className="btn btn-primary btn-sm"
            disabled={tx.busy || !enough || !timeOk || stale}
            onClick={() => tx.run({ label: t('发起投票', 'Open vote'), ...call('openVote', [d.address, p.hash, p.supporterSlots]) })}
          >
            {t('发起 24 小时投票', 'Open the 24-hour vote')}
          </button>
        </div>
      </WalletGate>
      {mineSupporting.length > 0 && <p className="muted small">{t(`你有 ${mineSupporting.length} 份持仓在支持这个计划。持仓转让后支持自动作废。`, `${mineSupporting.length} of your positions support this plan; support lapses on transfer.`)}</p>}
      {!timeOk && enough && <p className="muted small">{t('支持已经够了，到上面写的时间后就可以发起。', 'Support is enough; the vote can open at the time shown above.')}</p>}
      <TxStatus tx={tx} />
    </div>
  );
}

/** 发布计划：按成本价的百分比给全部没卖出的矿机定起价和底价 */
function PublishPlan({ d, g }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const t = (a, b) => (zh ? a : b);
  const tx = useTx();
  const [startPct, setStartPct] = useState('100');
  const [floorPct, setFloorPct] = useState('');
  const s = Number(startPct);
  const f = Number(floorPct);
  // 规则决定 6.33：起价不低于成本价（合约 publishPlan 会拒绝），成交价另由卖矿合约保证不低于买一 × 95%
  const valid = floorPct !== '' && f > 0 && s >= f && s >= 100 && s <= 1000;
  const items = valid ? planFromPercent(d.machines, s, f) : [];
  const okItems = items.length > 0 && items.every((it) => it.floor > 0n && it.start >= it.floor);
  const exists = okItems && g.plans.some((p) => p.items.length === items.length && p.items.every((x, i) => x.index === items[i].index && x.start === items[i].start && x.floor === items[i].floor));

  return (
    <div className="trade-box">
      <h4>{t('发布一个售矿计划', 'Publish a sale plan')}</h4>
      <p className="muted small">
        {t(
          `计划要覆盖本局全部 ${String(d.unsoldMachines)} 台没卖出的矿机。执行后每台从起价开始，在 7 天内线性降到底价，之后保持底价，谁先付款谁买走。任何人都可以发布，只需要付 gas；发布不等于支持。`,
          `The plan covers all ${String(d.unsoldMachines)} unsold machines. Once executed, each price falls linearly from start to floor over 7 days, then stays at the floor. Anyone can publish; publishing does not count as support.`,
        )}
      </p>
      <div className="row">
        <label className="small">
          {t('起价 = 成本的', 'Start = cost ×')}
          <input value={startPct} onChange={(e) => setStartPct(e.target.value)} inputMode="decimal" placeholder="100" />%
        </label>
        <label className="small">
          {t('底价 = 成本的', 'Floor = cost ×')}
          <input value={floorPct} onChange={(e) => setFloorPct(e.target.value)} inputMode="decimal" placeholder={t('例如 70', 'e.g. 70')} />%
        </label>
      </div>
      {floorPct !== '' && !valid && <p className="tx-error">{t('起价不能低于成本价（100%）；底价要大于 0，且不能高于起价', 'Start must be at least cost (100%); floor must be above 0 and not above start')}</p>}
      {okItems && <PlanTable d={d} items={items} />}
      {exists && <p className="muted small">{t('同样的计划已经发布过了，直接在上面支持它就行。', 'This exact plan already exists; support it above.')}</p>}
      <WalletGate>
        <button
          className="btn btn-ghost btn-sm"
          disabled={tx.busy || !okItems || exists}
          onClick={() =>
            tx.run({
              label: t('发布计划', 'Publish plan'),
              address: g.gov,
              abi: GovernorAbi,
              functionName: 'publishPlan',
              args: [d.address, items.map((x) => x.index), items.map((x) => x.start), items.map((x) => x.floor)],
            })
          }
        >
          {t('发布计划', 'Publish plan')}
        </button>
      </WalletGate>
      <TxStatus tx={tx} />
    </div>
  );
}

function Tally({ g }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const p = g.proposal;
  const row = (label, v, cls) => (
    <div className="tally-row">
      <span>{label}</span>
      <div className="progress small">
        <div className={`progress-bar ${cls}`} style={{ width: `${pct(v, p.total, 1)}%` }} />
      </div>
      <span className="small">
        {fmtBEM(v, 2)} BEM · {pct(v, p.total)}%
      </span>
    </div>
  );
  return (
    <div className="tally">
      {row(zh ? '赞成' : 'Yes', p.yes, 'is-yes')}
      {row(zh ? '反对' : 'No', p.no, 'is-no')}
      {row(zh ? '弃权' : 'Abstain', p.abstain, 'is-abstain')}
      <p className="muted small">
        {zh
          ? `通过条件：赞成超过 ${fmtBEM(p.total / 2n, 2)} BEM（全部本金的一半，没投票和弃权都算在分母里）`
          : `Passes with yes above ${fmtBEM(p.total / 2n, 2)} BEM (half of all stake; abstentions and non-votes count in the total)`}
      </p>
    </div>
  );
}

function VotePanel({ d, g }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const t = (a, b) => (zh ? a : b);
  const tx = useTx();
  const p = g.proposal;
  const plan = g.plans.find((x) => x.hash === p.planHash);
  const open = g.now < p.voteEnd;
  const mine = g.myPositions;
  const weight = mine.reduce((a, x) => a + x.socket.stake, 0n);
  const votes = [...new Set(mine.map((x) => x.vote))];
  const current = votes.length === 1 && votes[0] ? (zh ? CHOICE_TEXT[votes[0]][0] : CHOICE_TEXT[votes[0]][1]) : votes.some(Boolean) ? t('不一致', 'mixed') : t('还没投', 'not voted');
  const call = (functionName, args, label) => ({ label, address: g.gov, abi: GovernorAbi, functionName, args });

  return (
    <div className="trade-box">
      <h4>
        {t('正在投票：计划', 'Voting on plan')} {short(p.planHash)}
      </h4>
      {plan && <PlanTable d={d} items={plan.items} />}
      <Tally g={g} />
      {open && mine.length > 0 && (
        <>
          <p className="small">
            {t(`你有 ${mine.length} 份持仓，合计 ${fmtBEM(weight, 2)} BEM 票数。当前选择：${current}。截止前可以改票。`, `You hold ${mine.length} position(s), ${fmtBEM(weight, 2)} BEM of votes. Current: ${current}. You can change it before the deadline.`)}
          </p>
          <WalletGate>
            <div className="row">
              {[CHOICE.YES, CHOICE.NO, CHOICE.ABSTAIN].map((c) => (
                <button
                  key={c}
                  className={`btn btn-sm ${c === CHOICE.YES ? 'btn-primary' : 'btn-ghost'}`}
                  disabled={tx.busy}
                  onClick={() => tx.run(call('castVote', [d.address, mine.map((x) => x.slot), c], zh ? CHOICE_TEXT[c][0] : CHOICE_TEXT[c][1]))}
                >
                  {zh ? CHOICE_TEXT[c][0] : CHOICE_TEXT[c][1]}
                </button>
              ))}
            </div>
          </WalletGate>
        </>
      )}
      {open && mine.length === 0 && <p className="muted small">{t('你在本局没有持仓，不能投票。', 'You hold no position on this board.')}</p>}
      {!open && (
        <>
          <p className="small">{t('投票已截止，任何人都可以结算结果。', 'Voting has ended; anyone can finalize.')}</p>
          <WalletGate>
            <button className="btn btn-primary btn-sm" disabled={tx.busy} onClick={() => tx.run(call('finalizeVote', [d.address], t('结算投票', 'Finalize')))}>
              {t('结算投票结果', 'Finalize the vote')}
            </button>
          </WalletGate>
        </>
      )}
      <TxStatus tx={tx} />
    </div>
  );
}

function DelayPanel({ d, g }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const t = (a, b) => (zh ? a : b);
  const tx = useTx();
  const p = g.proposal;
  const plan = g.plans.find((x) => x.hash === p.planHash);
  const ready = g.now >= p.executeAfter && g.now < p.executeBy;
  const late = g.now >= p.executeBy;
  const call = (functionName, label) => ({ label, address: g.gov, abi: GovernorAbi, functionName, args: [d.address] });

  return (
    <div className="trade-box">
      <h4>
        {t('计划已通过', 'Plan approved')} {short(p.planHash)}
      </h4>
      {plan && <PlanTable d={d} items={plan.items} />}
      <Tally g={g} />
      <p className="small">
        {late
          ? t('执行期限已过，任何人都可以让提案失效：转让解锁，进入冷却期。', 'The window has passed; anyone can expire the proposal, which unlocks transfers and starts the cooldown.')
          : ready
            ? t('任何人都可以执行：计划写入卖矿合约，矿机开始按计划价出售，持仓恢复可以转让。投票期间已经按成本价以上卖掉的矿机会被跳过。', 'Anyone can execute: the plan goes live, machines go on sale at plan prices and transfers unlock. Machines sold at or above cost during the vote are skipped.')
            : t(`还要等 ${fmtDuration(p.executeAfter - g.now, app.lang)} 才能执行。`, `Executable in ${fmtDuration(p.executeAfter - g.now, app.lang)}.`)}
      </p>
      <WalletGate>
        {late ? (
          <button className="btn btn-ghost btn-sm" disabled={tx.busy} onClick={() => tx.run(call('expire', t('提案失效', 'Expire')))}>
            {t('让提案失效', 'Expire the proposal')}
          </button>
        ) : (
          <button className="btn btn-primary btn-sm" disabled={tx.busy || !ready} onClick={() => tx.run(call('execute', t('执行计划', 'Execute')))}>
            {t('执行计划', 'Execute the plan')}
          </button>
        )}
      </WalletGate>
      <TxStatus tx={tx} />
    </div>
  );
}
