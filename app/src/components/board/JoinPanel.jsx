// 加入主板：选通行证 → 填金额 → 授权通行证 → 授权 BEM → join
import { useEffect, useMemo, useState } from 'react';
import { erc20Abi, formatUnits } from 'viem';
import { useApp } from '../../App.jsx';
import { ABI, ejectChance, monthWinChance } from '../../lib/protocol.js';
import { circuitsAbi } from '../../abi/tapeout.js';
import { fmtBEM, parseBEM } from '../../lib/format.js';
import { usePasses } from '../PassPanel.jsx';
import { TxStatus, WalletGate, useTx } from '../TxButton.jsx';
import { ZapPay, buyPlan, useZap } from '../Zap.jsx';
import { buySteps } from '../../lib/zap.js';
import '../participation-ui.css';

export default function JoinPanel({ d, kind }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const account = app.wallet.account;
  const passes = usePasses();
  const tx = useTx();
  const standard = (passes.data ?? []).filter((p) => p.standard);
  const [passId, setPassId] = useState('');
  const remaining = d.target - d.totalStake;
  const fixed = remaining < d.minStake; // 剩余额度小于最低投入：只能投恰好补满的金额
  const suggested = fixed ? remaining : remaining < d.maxStake ? remaining : d.maxStake;
  const [agreed, setAgreed] = useState(false);
  const [text, setText] = useState(() => formatUnits(suggested, 8));
  const [balance, setBalance] = useState(null);

  useEffect(() => {
    if (!passId && standard.length) setPassId(String(standard[0].id));
  }, [standard.length]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (!account) return;
    app.client
      .readContract({ address: app.dep.bem, abi: erc20Abi, functionName: 'balanceOf', args: [account] })
      .then(setBalance)
      .catch(() => setBalance(null));
  }, [account, app.version]); // eslint-disable-line react-hooks/exhaustive-deps

  const amount = fixed ? remaining : parseBEM(text);
  const stake = amount != null && amount > remaining ? remaining : amount;
  const feeBps = d.config?.entryFeeBps ?? 100n;
  const fee = stake != null ? (stake * feeBps) / 10_000n : null;
  const total = stake != null ? stake + fee : null;
  const amountOk = amount != null && amount > 0n && (fixed ? true : amount >= d.minStake && amount <= d.maxStake);
  const enough = balance == null || total == null || balance >= total;
  // BEM 不够时：用 OKB / USDT 补足差额（lib/zap.js，2026-10-29）
  const zapQ = useZap();
  const zap = zapQ.data?.cfg ? zapQ.data : null;
  const [payWith, setPayWith] = useState('native');
  const short = !enough && amountOk ? total - balance : 0n;
  const plan = zap && short > 0n ? buyPlan(zap, short, payWith, zh) : null;
  const canPay = enough || Boolean(plan?.ok);

  const chance = useMemo(() => {
    if (!stake || stake <= 0n) return null;
    if (kind === 'std') return ejectChance(stake, d.totalStake + stake, d.socketCount + 1n);
    return monthWinChance(stake, d.totalStake + stake);
  }, [stake, d.totalStake, d.socketCount, kind]);

  async function join() {
    const id = BigInt(passId);
    const swap = plan ? buySteps({ cfg: zap.cfg, account, need: short, payWith, max: plan.quote.max, zh }) : [];
    await tx.run([
      ...swap,
      {
        label: zh ? '授权通行证' : 'Approve pass',
        address: app.dep.passCircuits,
        abi: circuitsAbi,
        functionName: 'approve',
        args: [d.address, id],
        skip: async () => {
          const [approved, all] = await Promise.all([
            app.client.readContract({ address: app.dep.passCircuits, abi: circuitsAbi, functionName: 'getApproved', args: [id] }).catch(() => null),
            app.client
              .readContract({ address: app.dep.passCircuits, abi: circuitsAbi, functionName: 'isApprovedForAll', args: [account, d.address] })
              .catch(() => false),
          ]);
          return all || approved?.toLowerCase() === d.address.toLowerCase();
        },
      },
      {
        label: zh ? '授权 BEM' : 'Approve BEM',
        address: app.dep.bem,
        abi: erc20Abi,
        functionName: 'approve',
        args: [d.address, total],
        skip: async () => {
          const a = await app.client.readContract({ address: app.dep.bem, abi: erc20Abi, functionName: 'allowance', args: [account, d.address] });
          return a >= total;
        },
      },
      {
        label: zh ? '加入' : 'Join',
        address: d.address,
        abi: kind === 'std' ? ABI.std : ABI.month,
        functionName: 'join',
        args: [id, amount],
      },
    ]);
  }

  return (
    <section className="panel join-panel">
      <div className="panel-head">
        <h2>{zh ? '加入本局' : 'Join this board'}</h2>
        <p className="muted">
          {zh
            ? `每人投入 ${fmtBEM(d.minStake, 2)}–${fmtBEM(d.maxStake, 2)} BEM，另收 ${Number(feeBps) / 100}% 入场费（开局后才转给手续费地址；招募不成会一起退回）。一个地址一局只能加入一次。`
            : `Stake ${fmtBEM(d.minStake, 2)}–${fmtBEM(d.maxStake, 2)} BEM plus a ${Number(feeBps) / 100}% entry fee (sent to the fee address only once the board starts, refunded if it does not fill). One seat per address.`}
        </p>
      </div>

      <label className="field">
        <span>{zh ? '通行证' : 'Pass'}</span>
        {standard.length ? (
          <select value={passId} onChange={(e) => setPassId(e.target.value)}>
            {standard.map((p) => (
              <option key={String(p.id)} value={String(p.id)}>
                HA1 #{String(p.id)}
              </option>
            ))}
          </select>
        ) : account && passes.loading && !passes.data ? (
          <span className="muted pass-feedback" role="status">{zh ? '正在读取你的通行证…' : 'Loading your passes…'}</span>
        ) : account && passes.error ? (
          <span className="pass-feedback tx-error" role="status">{zh ? '通行证读取失败，请稍后刷新。暂时无法确认可用数量。' : 'Could not load passes. Refresh shortly; availability is not yet confirmed.'}</span>
        ) : (
          <span className="muted">
            {account ? (zh ? '钱包里没有可用的通行证，' : 'No free pass in your wallet. ') : zh ? '连接钱包后显示' : 'Connect to see your passes'}
            {account && <a href="#/">{zh ? '先去铸一张' : 'Mint one first'}</a>}
          </span>
        )}
      </label>
      {standard.length > 0 && passes.error && (
        <p className="small muted pass-feedback" role="status">{zh ? '通行证刷新失败，当前显示上次读取的结果。' : 'Pass refresh failed; showing the last loaded results.'}</p>
      )}

      <label className="field">
        <span>{zh ? '投入金额（BEM）' : 'Stake (BEM)'}</span>
        {fixed ? (
          <span className="field-fixed">
            {fmtBEM(remaining, 8)}
            <small>{zh ? '（剩余额度不足最低投入，只能补满）' : ' (only the remaining amount can be added)'}</small>
          </span>
        ) : (
          <div className="amount-row">
            <input value={text} onChange={(e) => setText(e.target.value)} inputMode="decimal" />
            <button className="chip" onClick={() => setText(formatUnits(d.minStake, 8))}>
              {zh ? '最低' : 'Min'}
            </button>
            <button className="chip" onClick={() => setText(formatUnits(remaining < d.maxStake ? remaining : d.maxStake, 8))}>
              {zh ? '最高' : 'Max'}
            </button>
          </div>
        )}
      </label>

      <dl className="cost">
        <div>
          <dt>{zh ? '本金' : 'Stake'}</dt>
          <dd>{stake != null ? `${fmtBEM(stake, 8)} BEM` : '—'}</dd>
        </div>
        <div>
          <dt>{zh ? '入场费' : 'Entry fee'}</dt>
          <dd>{fee != null ? `${fmtBEM(fee, 8)} BEM` : '—'}</dd>
        </div>
        <div className="cost-total">
          <dt>{zh ? '合计转入' : 'Total'}</dt>
          <dd>{total != null ? `${fmtBEM(total, 8)} BEM` : '—'}</dd>
        </div>
        {balance != null && (
          <div>
            <dt>{zh ? '你的 BEM 余额' : 'Your BEM'}</dt>
            <dd className={enough ? '' : 'is-bad'}>{fmtBEM(balance, 4)}</dd>
          </div>
        )}
      </dl>

      {zap && short > 0n && <ZapPay z={zap} short={short} payWith={payWith} setPayWith={setPayWith} plan={plan} />}

      {chance != null && (
        <p className="hint">
          {kind === 'std'
            ? zh
              ? `按现在的人数和金额估算：开局后第一次脉冲选中你出局的概率约 ${chance.toFixed(2)}%（出局即拿回本金的 105%）。投入越多，每次被选中的概率越低。`
              : `At current numbers, your chance of being picked at the first pulse is about ${chance.toFixed(2)}% (an ejected player receives 105% of stake). Larger stakes are picked less often.`
            : zh
              ? `按现在的总投入估算：5 个奖里至少中一个的概率约 ${chance.toFixed(2)}%。最终概率按开局时的总投入计算。`
              : `At current totals, your chance of winning at least one of the 5 prizes is about ${chance.toFixed(2)}%. Final odds use the total at start.`}
        </p>
      )}

      <ExitTerms kind={kind} zh={zh} />
      <label className="agree small">
        <input type="checkbox" checked={agreed} onChange={(e) => setAgreed(e.target.checked)} />
        {zh ? '我已了解上面的退出方式：本金不保证全额收回，收回时间也不确定。' : 'I understand the exit options above: principal is not guaranteed, and the timing is uncertain.'}
      </label>
      <div className="join-guidance">
        <p className="join-next-step" role="status">
          {!account
            ? (zh ? '下一步：连接钱包，查看可用通行证和余额。' : 'Next: connect your wallet to see passes and balance.')
            : app.wallet.chainId !== app.chainId
              ? (zh ? `下一步：切换到 ${app.net.name}。` : `Next: switch to ${app.net.name}.`)
              : tx.busy
                ? (zh ? '正在处理，请按钱包提示完成确认。' : 'In progress. Follow the confirmation prompts in your wallet.')
                : d.sentinelPaused
                  ? (zh ? '升级冷静期内暂停加入，请等待恢复。' : 'Joining is paused during the upgrade cooling period.')
                  : !passId
                    ? passes.loading && !passes.data
                      ? (zh ? '正在读取通行证，请稍候。' : 'Loading passes. Please wait.')
                      : passes.error
                        ? (zh ? '暂时无法确认可用通行证，请稍后刷新。' : 'Pass availability could not be confirmed. Refresh shortly.')
                        : (zh ? '下一步：先在总览准备一张可用的标准通行证。' : 'Next: prepare an available standard pass on Overview.')
                    : !amountOk
                      ? (zh ? '下一步：填写允许范围内的投入金额。' : 'Next: enter a stake within the allowed range.')
                      : !canPay
                        ? zap
                          ? (zh ? `BEM 不够，${zap.cfg.native} / USDT 余额也不够补足差额。` : `Not enough BEM, and not enough to cover the rest by swapping.`)
                          : (zh ? 'BEM 余额不足以支付本金和入场费。' : 'Your BEM balance does not cover the stake and entry fee.')
                        : !agreed
                          ? (zh ? '下一步：阅读退出说明，并勾选风险确认。' : 'Next: read the exit details and acknowledge the risks.')
                          : (zh ? '可以发起加入，最终以钱包确认和链上结果为准。' : 'You can request to join; wallet confirmation and the on-chain result apply.')}
        </p>
        <p className="small muted">
          {plan
            ? zh
              ? `钱包最多确认 ${payWith === 'stable' ? 5 : 4} 步：${payWith === 'stable' ? '授权 USDT → ' : ''}兑换 → 授权通行证 → 授权 BEM → 加入。已有足够授权时会跳过对应步骤。`
              : `Up to ${payWith === 'stable' ? 5 : 4} wallet confirmations: ${payWith === 'stable' ? 'approve USDT → ' : ''}swap → approve pass → approve BEM → join. Sufficient existing approvals are skipped.`
            : zh
              ? '钱包最多确认 3 步：授权通行证 → 授权 BEM → 加入。已有足够授权时会跳过对应步骤。'
              : 'Up to 3 wallet confirmations: approve pass → approve BEM → join. Sufficient existing approvals are skipped.'}
        </p>
      </div>
      <WalletGate>
        <button className="btn btn-primary" disabled={tx.busy || !amountOk || !passId || !canPay || !agreed || d.sentinelPaused} onClick={join}>
          {d.sentinelPaused ? (zh ? '升级冷静期，暂停加入' : 'Paused (upgrade cooling period)') : plan ? (zh ? '兑换并加入' : 'Swap and join') : zh ? '加入' : 'Join'}
        </button>
      </WalletGate>
      {!amountOk && !fixed && text && <p className="tx-error">{zh ? '金额不在允许范围内' : 'Amount out of range'}</p>}
      {!enough && !zap && <p className="tx-error">{zh ? 'BEM 余额不够' : 'Not enough BEM'}</p>}
      <TxStatus tx={tx} />
    </section>
  );
}

/** 加入之前把退出方式说清楚（规则见 v2月局规则决定-2026-10-22.md 第 6.1 节） */
function ExitTerms({ kind, zh }) {
  const items =
    kind === 'std'
      ? zh
        ? [
            ['被抽中出局', '产出攒够门槛就抽一次，被抽中时当场拿回本金的 105% 和通行证。什么时候轮到你不确定，投入越多越晚。'],
            ['保底清算', '满最长期限、首轮一台矿机没买到、随机数服务停摆超过 7 天、或 TapeOut 升级后参与者发起提前结算：停止抽签，卖掉矿机，先收 2% 手续费（不收基金会 3%），再退还没出局者的本金（不够时按比例），剩下的按投入比例分。首轮一台没买到时，未出局者拿回本金的 98%。'],
            ['挂单转让', '开局且首轮收购结束后、以及终局阶段，可以把持仓挂到本局的盘口出售，或卖给别人的买单；等开奖随机数时暂停成交。低于本金卖出，就是接受亏损提前离场。通行证退给最初加入的人。'],
          ]
        : [
            ['Being picked', 'Each pulse picks one player, who receives 105% of stake and the pass at once. When that happens is uncertain; larger stakes tend to wait longer.'],
            ['Fallback liquidation', 'At the maximum term, if the first purchase round bought no machine, after a 7-day randomness outage, or on early settlement after a TapeOut upgrade: draws stop, machines are sold, a 2% fee is taken (no 3% foundation share), remaining principal is repaid first (pro rata if short), the rest is shared by stake. If no machine was bought, players still in get 98% of their stake back.'],
            ['Sell your position', 'After the first purchase round, and during the final phase, you can list your position on this board’s order book or sell to a bid; trades pause while a draw waits for randomness. Selling below principal means taking the loss and leaving early. The pass goes back to the original joiner.'],
          ]
      : zh
        ? [
            ['等矿机卖出', '挖满 30 天开奖后进入结算：矿机高于成本价时按市场价卖出，回款按投入比例退回；低于成本价时先不卖，继续挖矿、继续分产出。'],
            ['挂单转让', '结算阶段可以把你的持仓挂到本局的盘口上出售，也可以卖给别人的买单。低于本金卖出，就是接受亏损提前离场。挖矿期间不能转让。'],
            ['多数集体清算', '结算满 7 天后，持有人可以投票批准低于成本价卖矿，赞成超过全部本金的一半才通过。通过后矿机降价出售，但成交价不低于当时市场买一的 95%（可以一起止损，不能低于市价甩卖），回款先退本金。'],
            ['本金与结算风险', '矿机价格可能长期低于成本价，本金可能拿不全，拿回的时间也不确定。'],
          ]
        : [
            ['Machine sales', 'After the 30-day draw the board settles: machines above cost are sold at market and proceeds return pro rata; below cost they keep mining and output keeps being shared.'],
            ['Sell your position', 'During settlement you can list your position on this board’s order book or sell to a bid. Selling below principal means taking the loss and leaving early. No transfers while mining.'],
            ['Majority liquidation', 'From 7 days into settlement, holders can vote to sell machines below cost; it needs yes votes above half of all stake. Sales never go below 95% of the current market bid. Proceeds repay principal first.'],
            ['No guarantee', 'Machines may stay below cost for a long time; principal may not be fully recovered and timing is uncertain.'],
          ];
  return (
    <details className="exit-terms" open>
      <summary>{zh ? '怎么退出（加入前请读完）' : 'How you exit (read before joining)'}</summary>
      <dl className="kv">
        {items.map(([k, v]) => (
          <div key={k}>
            <dt>{k}</dt>
            <dd>{v}</dd>
          </div>
        ))}
      </dl>
    </details>
  );
}
