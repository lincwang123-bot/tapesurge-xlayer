// 兜底操作：运营地址超时没执行时，参与者（部分操作任何人）可以自己推进。
// 展开时逐个模拟，只把现在能执行的按钮点亮，不能执行的显示原因。
import { useEffect, useState } from 'react';
import { useApp } from '../../App.jsx';
import { ABI } from '../../lib/protocol.js';
import { canCall, explain } from '../../lib/tx.js';
import { fmtDuration } from '../../lib/format.js';
import { DrandAbi, fetchDrandSignature, pendingDrand } from '../../lib/drand.js';
import { TxStatus, WalletGate, useTx } from '../TxButton.jsx';

function actionsFor(d, kind) {
  const all = (fn, args, zh, en, states) => ({ fn, args, zh, en, states });
  const n = d.socketCount ?? 0n;
  const alive = (d.mySlots ?? []).find((p) => !p.socket.ejected);
  if (kind === 'std') {
    return [
      all('closeRecruitment', [], '结束招募（招募到期后，任何人）', 'Close recruitment (after the deadline, anyone)', ['Recruiting']),
      all('pulse', [], '推进脉冲 / 请求开奖', 'Run a pulse (request a draw)', ['Active']),
      all('retryDraw', [], '重新请求随机数（等待超过 24 小时）', 'Re-request randomness (after 24 h)', ['Active']),
      all('triggerSafeExit', [], '随机数停摆 7 天：安全退出', 'Safe exit after 7 days without randomness', ['Active']),
      all('expire', [], '到达最长期限 / 首轮没买到矿机：保底分配', 'Fallback settlement (max duration or no machines)', ['Active']),
      // 提前退出按持仓：用我第一份还没出局的持仓（v2.0-rc6）
      ...(alive ? [all('emergencyExit', [alive.slot], `升级哨兵触发：持仓 #${String(alive.slot)} 提前退出`, `Emergency exit of position #${String(alive.slot)} after an upgrade`, ['Active'])] : []),
      { ...all('distribute', [d.address, 1n, n], '把可领的 BEM 和通行证发给所有人', 'Push claimable BEM and passes to everyone', ['Active', 'Liquidating', 'Failed']), sales: true },
      all('harvest', [], '领取矿机产出进主板（任何人）', 'Harvest machine output (anyone)', ['Active']),
    ];
  }
  return [
    all('closeRecruitment', [], '结束招募（招募到期后，任何人）', 'Close recruitment (after the deadline, anyone)', ['Recruiting']),
    all('sync', [], '推进阶段：准备期结束后开始挖矿（任何人）', 'Advance phase: start mining after preparation (anyone)', ['Preparing', 'Mining']),
    all('drawPrizes', [], '挖矿期满：请求开奖', 'Request the prize draw after mining', ['Mining']),
    all('finalizePrizes', [], '随机数已到：完成开奖并发奖', 'Finalize the draw and pay prizes', ['Drawing']),
    all('retryDraw', [], '重新请求随机数（等待超过 24 小时）', 'Re-request randomness (after 24 h)', ['Drawing']),
    all('triggerSafeSettle', [], '随机数停摆 7 天：不抽奖直接结算', 'Settle without a draw after 7 days without randomness', ['Drawing']),
    all('emergencySettle', [], '升级哨兵触发：提前结算', 'Emergency settlement after an upgrade', ['Preparing', 'Mining']),
    all('sweep', [], '把未分配的 BEM 按比例记给参与者（任何人）', 'Credit unallocated BEM to participants (anyone)', ['Settling']),
    { ...all('distribute', [d.address, 1n, n], '把可领的 BEM 和通行证发给所有人', 'Push claimable BEM and passes to everyone', ['Settling', 'Failed']), sales: true },
    all('harvest', [], '领取矿机产出进主板（任何人）', 'Harvest machine output (anyone)', ['Preparing', 'Mining', 'Settling']),
  ];
}

/** 分批发放在卖矿单例（月局 MonthMachineSales、标准局 StdMachineSales），其余在主板 */
const abiFor = (a, kind) => (a.sales ? (kind === 'std' ? ABI.stdSales : ABI.monthSales) : kind === 'std' ? ABI.std : ABI.month);

function Action({ d, kind, a, check }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const tx = useTx();
  return (
    <li className="fallback-item">
      <div>
        <strong>{zh ? a.zh : a.en}</strong>
        {check && !check.ok && <span className="muted small"> · {explain(check.error, app.lang)}</span>}
      </div>
      <WalletGate>
        <button
          className="btn btn-ghost btn-sm"
          disabled={!check?.ok || tx.busy}
          onClick={() =>
            tx.run({ address: a.sales ? d.salesAddress : d.address, abi: abiFor(a, kind), functionName: a.fn, args: a.args })
          }
        >
          {zh ? '执行' : 'Run'}
        </button>
      </WalletGate>
      <TxStatus tx={tx} />
    </li>
  );
}

/**
 * X Layer：提交 drand 签名（全局审计 2026-10-29 第 7 条）。开奖请求锁定了一个未来轮次，这一轮公开后，运营地址宽限期内没交，
 * 本局持仓的持有人可以自己从 drand 中继取签名交给适配器（适配器在链上验签，结果和谁交无关）。
 * 没有这个按钮的话，运营地址不交签名，持有人只能等 7 天"不抽奖结算"。
 */
function DrandAction({ d, checkKey }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const tx = useTx();
  const [st, setSt] = useState(null); // { ok, note, sig, id }
  const adapter = app.dep.drandAdapter;
  const account = app.wallet.account;

  useEffect(() => {
    if (!account || !adapter || d.pendingRequestId == null) return;
    let live = true;
    (async () => {
      try {
        const q = await pendingDrand(app.client, adapter, d.address, d.pendingRequestId);
        if (!q.mine || q.fulfilled) return live && setSt({ ok: false, note: zh ? '这一轮随机数已经交付过了' : 'Already delivered' });
        const now = BigInt(Math.floor(Date.now() / 1000));
        if (now < q.at) {
          const left = fmtDuration(q.at - now, app.lang);
          return live && setSt({ ok: false, note: zh ? `第 ${q.round} 轮还没公开，约 ${left}后` : `Round ${q.round} is public in about ${left}` });
        }
        const sig = await fetchDrandSignature(q.round);
        const c = await canCall({ publicClient: app.client, account, address: adapter, abi: DrandAbi, functionName: 'fulfill', args: [q.id, sig] });
        if (live) setSt({ ok: c.ok, note: c.ok ? null : explain(c.error, app.lang), sig, id: q.id, round: q.round });
      } catch (e) {
        if (live) setSt({ ok: false, note: zh ? `取不到 drand 签名：${e.message}` : `Could not fetch the drand signature: ${e.message}` });
      }
    })();
    return () => {
      live = false;
    };
  }, [checkKey, account, adapter, d.address, d.pendingRequestId, app.client, app.lang, zh]);

  return (
    <li className="fallback-item">
      <div>
        <strong>
          {zh
            ? `提交 drand 随机数签名${st?.round ? `（第 ${st.round} 轮）` : ''}：运营地址没交时，持有人可以自己交`
            : `Submit the drand signature${st?.round ? ` (round ${st.round})` : ''} if the operator has not`}
        </strong>
        {st?.note && <span className="muted small"> · {st.note}</span>}
      </div>
      <WalletGate>
        <button
          className="btn btn-ghost btn-sm"
          disabled={!st?.ok || tx.busy}
          onClick={() => tx.run({ address: adapter, abi: DrandAbi, functionName: 'fulfill', args: [st.id, st.sig] })}
        >
          {zh ? '执行' : 'Run'}
        </button>
      </WalletGate>
      <TxStatus tx={tx} />
    </li>
  );
}

export default function Fallback({ d, kind }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const [checks, setChecks] = useState(null);
  const [checkKey, setCheckKey] = useState(0);
  const actions = actionsFor(d, kind).filter((a) => a.states.includes(d.stateName));
  // X Layer 月局等随机数时：多一项"提交 drand 签名"
  const drand = app.xlayer && kind === 'month' && d.stateName === 'Drawing' && d.drawPending && Boolean(app.dep.drandAdapter);
  const account = app.wallet.account;
  const grace = d.config?.operatorGrace;

  async function runChecks() {
    if (!account) return;
    setCheckKey((k) => k + 1);
    const res = await Promise.all(
      actions.map((a) =>
        canCall({ publicClient: app.client, account, address: a.sales ? d.salesAddress : d.address, abi: abiFor(a, kind), functionName: a.fn, args: a.args }),
      ),
    );
    setChecks(Object.fromEntries(actions.map((a, i) => [a.fn, res[i]])));
  }

  if (!actions.length) return null;
  return (
    <details className="panel fallback" onToggle={(e) => e.currentTarget.open && runChecks()}>
      <summary>
        <h2>{zh ? '兜底操作' : 'Step in yourself'}</h2>
        <span className="muted small">
          {zh
            ? `运营地址负责开奖、发放和挂单；它超过 ${fmtDuration(grace ?? 0n, 'zh')}没执行时，本局参与者可以自己执行。`
            : `The operator runs draws, payouts and listings; if it is idle for ${fmtDuration(grace ?? 0n, 'en')}, participants can run them.`}
        </span>
      </summary>
      {!account ? (
        <p className="muted">{zh ? '连接钱包后检查哪些操作现在可以执行。' : 'Connect a wallet to check what you can run now.'}</p>
      ) : (
        <ul className="fallback-list">
          {drand && checkKey > 0 && <DrandAction d={d} checkKey={checkKey} />}
          {actions.map((a) => (
            <Action key={a.fn} d={d} kind={kind} a={a} check={checks?.[a.fn]} />
          ))}
        </ul>
      )}
      {account && (
        <button className="btn btn-ghost btn-sm" onClick={runChecks}>
          {zh ? '重新检查' : 'Re-check'}
        </button>
      )}
    </details>
  );
}
