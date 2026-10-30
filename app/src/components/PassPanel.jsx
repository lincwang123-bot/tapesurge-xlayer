// 通行证：列出钱包里的通行证；两步铸造（铸 5 颗 NAND 晶体管 → 流片 HA1 半加器）。
import { useState } from 'react';
import { parseEventLogs } from 'viem';
import { useApp } from '../App.jsx';
import { useAsync } from '../lib/useAsync.js';
import { checkPasses, findPasses, rememberPass } from '../lib/protocol.js';
import { PASS_NETLIST, PASS_TRANSISTORS, circuitsAbi, transistorsAbi } from '../abi/tapeout.js';
import { fmtBNB } from '../lib/format.js';
import { TxStatus, WalletGate, useTx } from './TxButton.jsx';

export function usePasses() {
  const app = useApp();
  const account = app.wallet.account;
  return useAsync(
    () => (account ? findPasses(app.client, app.dep, app.chainId, account) : Promise.resolve([])),
    [account, app.chainId], { refresh: app.version });
}

export default function PassPanel({ overview, compact = false }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const passes = usePasses();
  const tx = useTx();
  const [manual, setManual] = useState('');
  const [manualMsg, setManualMsg] = useState('');
  const o = overview;
  const account = app.wallet.account;

  const perTransistor = o?.mintPrice != null && o?.protocolFee != null ? o.mintPrice + o.protocolFee : null;
  const soldOut = o?.minted != null && o?.supplyCap != null && o.minted + PASS_TRANSISTORS > o.supplyCap;

  async function mint() {
    await tx.run([
      {
        label: zh ? '第 1 步 铸晶体管' : 'Step 1 · mint transistors',
        address: app.dep.transistors,
        abi: transistorsAbi,
        functionName: 'mint',
        args: [0n, PASS_TRANSISTORS],
        value: perTransistor * PASS_TRANSISTORS,
        // 钱包里已经有 5 颗 NAND（上次只完成了第 1 步）就跳过
        skip: async () => {
          const bal = await app.client
            .readContract({ address: app.dep.transistors, abi: transistorsAbi, functionName: 'balanceOf', args: [account, 0n] })
            .catch(() => 0n);
          return bal >= PASS_TRANSISTORS;
        },
      },
      {
        label: zh ? '第 2 步 流片通行证' : 'Step 2 · tape out the pass',
        address: app.dep.passCircuits,
        abi: circuitsAbi,
        functionName: 'tapeout',
        args: [PASS_NETLIST, 2, 2],
        value: o.tapeoutFee,
        after: (receipt) => {
          const logs = parseEventLogs({ abi: circuitsAbi, eventName: 'Transfer', logs: receipt.logs });
          for (const l of logs) {
            if (l.address.toLowerCase() === app.dep.passCircuits.toLowerCase() && l.args.to.toLowerCase() === account.toLowerCase()) {
              rememberPass(app.chainId, account, l.args.tokenId);
            }
          }
        },
      },
    ]);
  }

  async function addManual() {
    setManualMsg('');
    if (!/^\d+$/.test(manual.trim())) return;
    const found = await checkPasses(app.client, app.dep, account, [manual.trim()]);
    if (!found.length) {
      setManualMsg(zh ? '这个编号的电路不在你的钱包里' : 'That circuit is not in your wallet');
      return;
    }
    rememberPass(app.chainId, account, manual.trim());
    setManual('');
    passes.reload();
  }

  const list = passes.data ?? [];
  const standard = list.filter((p) => p.standard);

  return (
    <section className="panel pass-panel" id={!compact ? 'overview-pass' : undefined}>
      <div className="panel-head">
        <h2>{zh ? '创世通行证' : 'Genesis Pass'}</h2>
        {!compact && (
          <p className="muted">
            {zh
              ? '加入任何一块主板都需要一张通行证。通行证在局里时锁在主板合约中，退出或结束后退回，可以反复使用。'
              : 'Each board seat needs a pass. It is locked in the board while you play and returned afterwards, so it can be reused.'}
          </p>
        )}
      </div>

      {account && (
        <div className="pass-list">
          {passes.loading && !passes.data ? (
            <p className="muted">{zh ? '正在查找你的通行证…' : 'Looking for your passes…'}</p>
          ) : standard.length ? (
            <ul>
              {standard.map((p) => (
                <li key={String(p.id)} className="pass-chip">
                  <span className="pass-icon" aria-hidden="true">
                    HA1
                  </span>
                  #{String(p.id)}
                </li>
              ))}
            </ul>
          ) : (
            <p className="muted">{zh ? '钱包里还没有可用的通行证。' : 'No pass in your wallet yet.'}</p>
          )}
          {passes.error && <p className="tx-error">{zh ? '读取通行证失败，稍后会自动重试' : 'Could not load passes; will retry'}</p>}
        </div>
      )}

      {!compact && (
        <div className="mint-box">
          <dl className="cost pass-cost-summary">
            <div className="cost-total">
              <dt>{zh ? '合计' : 'Total'}</dt>
              <dd>{o?.passCost != null ? `${fmtBNB(o.passCost, 8)} ${app.net.native}` : '—'}</dd>
            </div>
          </dl>
          <details className="pass-cost-details">
            <summary>{zh ? '费用明细与分配' : 'Fee breakdown and allocation'}</summary>
            <dl className="cost">
              <div>
                <dt>{zh ? '5 颗 NAND 晶体管' : '5 NAND transistors'}</dt>
                <dd>
                  {perTransistor != null ? `${fmtBNB(perTransistor * PASS_TRANSISTORS, 8)} ${app.net.native}` : '—'}
                  <small>
                    {zh
                      ? `每颗：铸造价 ${fmtBNB(o?.mintPrice, 8)} + 协议费 ${fmtBNB(o?.protocolFee, 8)}`
                      : `each: mint ${fmtBNB(o?.mintPrice, 8)} + protocol fee ${fmtBNB(o?.protocolFee, 8)}`}
                  </small>
                </dd>
              </div>
              <div>
                <dt>{zh ? '流片费（TapeOut）' : 'Tape-out fee (TapeOut)'}</dt>
                <dd>{o?.tapeoutFee != null ? `${fmtBNB(o.tapeoutFee, 8)} ${app.net.native}` : '—'}</dd>
              </div>
            </dl>
            <p className="muted small">
              {zh
                ? '铸造价进入创世分账合约，按 40% 回购销毁 BEM、10% 运营、20% 基金会、30% 首批主板回馈分配；协议费和流片费归 TapeOut。'
                : 'The mint price goes to the genesis splitter: 40% BEM buyback-and-burn, 10% operations, 20% foundation, 30% early-board rewards. Protocol and tape-out fees go to TapeOut.'}
            </p>
          </details>
          <p className="muted small pass-nand-warning">
            {zh
              ? '⚠️ 通行证只用 NAND。这里的按钮只会铸 NAND；如果在 TapeOut 官网铸造，请选 NAND，不要选 LATCH——LATCH 做不了通行证，铸错不能退。'
              : '⚠️ Passes use NAND only. This button mints NAND only; if you mint on the TapeOut site, choose NAND, not LATCH. A LATCH cannot become a pass, and a wrong mint cannot be refunded.'}
          </p>
          <p className="muted small pass-confirmation-note">
            {zh
              ? '钱包最多确认两步：① 铸 5 颗 NAND → ② 流片通行证。已有 5 颗 NAND 时会跳过第 1 步；另需预留 gas。'
              : 'Up to two wallet confirmations: ① mint 5 NAND → ② tape out the pass. Step 1 is skipped if you already hold 5 NAND. Keep extra BNB for gas.'}
          </p>
          <WalletGate>
            <button className="btn btn-primary" disabled={tx.busy || soldOut || o?.passCost == null} onClick={mint}>
              {soldOut ? (zh ? '已铸完' : 'Sold out') : zh ? '铸一张通行证' : 'Mint a pass'}
            </button>
          </WalletGate>
          <TxStatus tx={tx} />
        </div>
      )}

      {account && !compact && (
        <details className="manual">
          <summary>{zh ? '通行证没显示出来？' : 'Pass not showing?'}</summary>
          <p className="muted small">
            {zh
              ? '页面通过扫描转账记录找通行证。如果你是从别人那里收到的，或者扫描还没完成，可以直接输入编号。'
              : 'Passes are found by scanning transfer logs. If you received one from someone else, enter its number.'}
          </p>
          <div className="row">
            <input value={manual} onChange={(e) => setManual(e.target.value)} placeholder={zh ? '通行证编号' : 'Pass ID'} inputMode="numeric" />
            <button className="btn btn-ghost btn-sm" onClick={addManual}>
              {zh ? '添加' : 'Add'}
            </button>
          </div>
          {manualMsg && <p className="tx-error">{manualMsg}</p>}
        </details>
      )}
    </section>
  );
}

