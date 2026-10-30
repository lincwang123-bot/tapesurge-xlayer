// 一键兑换的界面（规则见 lib/zap.js）：加入时用 OKB / USDT 补足 BEM（ZapPay，嵌在 JoinPanel 里），
// 结算拿回 BEM 后换回 OKB / USDT（ZapSell，在"我的"页）。
import { useState } from 'react';
import { erc20Abi, formatUnits } from 'viem';
import { useApp } from '../App.jsx';
import { useAsync } from '../lib/useAsync.js';
import { fmtBEM, parseBEM } from '../lib/format.js';
import { RouterAbi, SLIPPAGE_BPS, quoteBuy, quoteSell, sellSteps, spotPrices, zapConfig } from '../lib/zap.js';
import { TxStatus, WalletGate, useTx } from './TxButton.jsx';

/** 原生币留出的 gas（兑换和后面几步交易都要付 gas） */
const GAS_RESERVE = 2n * 10n ** 15n; // 0.002

const trim = (s, max) => {
  const [i, d = ''] = s.split('.');
  const cut = d.slice(0, max).replace(/0+$/, '');
  return cut ? `${i}.${cut}` : i;
};
export const fmtUnitsShort = (v, decimals, max = 4) => (v == null ? '—' : trim(formatUnits(v, decimals), max));

/** 兑换配置、现价和当前账户的原生币 / 稳定币 / BEM 余额；这个网络没有兑换时 data.cfg 为 null */
export function useZap() {
  const app = useApp();
  const account = app.wallet.account;
  return useAsync(
    async () => {
      const cfg = await zapConfig(app.client, app.net, app.dep);
      if (!cfg) return { cfg: null };
      const [prices, native, stable, bem, reserve] = await Promise.all([
        spotPrices(app.client, cfg),
        account ? app.client.getBalance({ address: account }) : null,
        account && cfg.stable ? app.client.readContract({ address: cfg.stable.address, abi: erc20Abi, functionName: 'balanceOf', args: [account] }) : null,
        account ? app.client.readContract({ address: cfg.bem, abi: erc20Abi, functionName: 'balanceOf', args: [account] }) : null,
        cfg.mock ? app.client.readContract({ address: cfg.router, abi: RouterAbi, functionName: 'reserve' }) : null,
      ]);
      return { cfg, prices, native, stable, bem, reserve };
    },
    [app.chainId, account],
    { refresh: app.version, interval: 30_000 },
  );
}

/** 付款币的显示信息 */
export function payAsset(cfg, payWith) {
  return payWith === 'stable' ? { symbol: cfg.stable.symbol, decimals: cfg.stable.decimals } : { symbol: cfg.native, decimals: 18 };
}

/**
 * 加入时补足 BEM 的计划：{ quote, ok, why }。ok = 余额够付上限（原生币另留 gas）。
 */
export function buyPlan(z, short, payWith, zh) {
  if (!z?.cfg || !z.prices || short <= 0n) return null;
  const quote = quoteBuy(z.prices, z.cfg, short, payWith);
  const have = payWith === 'stable' ? z.stable : z.native;
  const need = payWith === 'stable' ? quote.max : quote.max + GAS_RESERVE;
  const a = payAsset(z.cfg, payWith);
  const ok = have == null || have >= need;
  return { quote, ok, why: ok ? null : zh ? `${a.symbol} 余额不够（需要约 ${fmtUnitsShort(need, a.decimals)}，含 gas）` : `Not enough ${a.symbol} (about ${fmtUnitsShort(need, a.decimals)} needed incl. gas)` };
}

/** 加入面板里的"BEM 不够时用 OKB / USDT 补足" */
export function ZapPay({ z, short, payWith, setPayWith, plan }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const cfg = z.cfg;
  const options = [['native', cfg.native], ...(cfg.stable ? [['stable', cfg.stable.symbol]] : [])];
  const a = payAsset(cfg, payWith);
  return (
    <div className="zap-pay">
      <div className="zap-head">
        <strong>{zh ? `BEM 还差 ${fmtBEM(short, 8)}，用这个补足：` : `Short by ${fmtBEM(short, 8)} BEM. Pay the rest with:`}</strong>
        <div className="zap-options" role="radiogroup">
          {options.map(([k, label]) => (
            <button key={k} type="button" role="radio" aria-checked={payWith === k} className={`chip ${payWith === k ? 'is-on' : ''}`} onClick={() => setPayWith(k)}>
              {label}
            </button>
          ))}
        </div>
      </div>
      {plan && (
        <dl className="cost">
          <div>
            <dt>{zh ? '预计支付' : 'Estimated'}</dt>
            <dd>
              {fmtUnitsShort(plan.quote.est, a.decimals, 6)} {a.symbol}
              <small>{zh ? `最多 ${fmtUnitsShort(plan.quote.max, a.decimals, 6)}（多付的退回）` : `at most ${fmtUnitsShort(plan.quote.max, a.decimals, 6)} (any excess is refunded)`}</small>
            </dd>
          </div>
        </dl>
      )}
      {plan?.why && <p className="tx-error">{plan.why}</p>}
      <p className="small muted">
        {cfg.mock
          ? zh
            ? '测试网：用模拟路由按测试网报价兑换（同样扣 1% 池费），付的 OKB 留作别人换回 OKB 的储备。'
            : 'Testnet: a mock router swaps at the testnet quote (same 1% pool fee); the OKB you pay backs swaps back to OKB.'
          : zh
            ? `按链上池子现价兑换，含 1% 池费${payWith === 'stable' ? `，${cfg.stable.symbol} 先换成 ${cfg.native} 再换 BEM` : ''}；成交价比估价差超过 ${Number(SLIPPAGE_BPS) / 100}% 就整笔回滚。`
            : `Swaps at the on-chain pool price incl. the 1% pool fee${payWith === 'stable' ? ` (${cfg.stable.symbol} → ${cfg.native} → BEM)` : ''}; reverts if the price is more than ${Number(SLIPPAGE_BPS) / 100}% worse than the estimate.`}
        {zh
          ? ' 结算退回的是 BEM；之后换回 OKB / USDT 按当时的价格，可能比现在多，也可能少。'
          : ' Settlement pays back BEM; swapping it back later uses the price at that time, which may be higher or lower.'}
      </p>
    </div>
  );
}

/** "我的"页：把钱包里的 BEM 换回 OKB / USDT */
export function ZapSell() {
  const app = useApp();
  const zh = app.lang === 'zh';
  const account = app.wallet.account;
  const q = useZap();
  const tx = useTx();
  const [text, setText] = useState('');
  const [receive, setReceive] = useState('native');
  const z = q.data;
  if (!account || !z?.cfg) return null;
  const cfg = z.cfg;
  const amount = text === '' ? null : parseBEM(text);
  const ok = amount != null && amount > 0n && z.bem != null && amount <= z.bem;
  const quote = ok && z.prices ? quoteSell(z.prices, cfg, amount, receive) : null;
  const a = payAsset(cfg, receive);
  const short = cfg.mock && quote && z.reserve != null && quote.est > z.reserve;
  const options = [['native', cfg.native], ...(cfg.stable ? [['stable', cfg.stable.symbol]] : [])];

  return (
    <section className="panel zap-sell">
      <div className="panel-head">
        <h2>{zh ? `把 BEM 换回 ${options.map(([, s]) => s).join(' / ')}` : `Swap BEM back to ${options.map(([, s]) => s).join(' / ')}`}</h2>
        <span className="muted small">{zh ? `钱包里有 ${fmtBEM(z.bem, 4)} BEM` : `${fmtBEM(z.bem, 4)} BEM in your wallet`}</span>
      </div>
      <label className="field">
        <span>{zh ? '卖出数量（BEM）' : 'Amount (BEM)'}</span>
        <div className="amount-row">
          <input value={text} onChange={(e) => setText(e.target.value)} inputMode="decimal" placeholder="0" />
          <button className="chip" type="button" onClick={() => setText(formatUnits(z.bem ?? 0n, 8))}>
            {zh ? '全部' : 'All'}
          </button>
        </div>
      </label>
      <div className="zap-options" role="radiogroup">
        {options.map(([k, label]) => (
          <button key={k} type="button" role="radio" aria-checked={receive === k} className={`chip ${receive === k ? 'is-on' : ''}`} onClick={() => setReceive(k)}>
            {zh ? `换成 ${label}` : `To ${label}`}
          </button>
        ))}
      </div>
      {quote && (
        <dl className="cost">
          <div>
            <dt>{zh ? '预计收到' : 'Estimated'}</dt>
            <dd>
              {fmtUnitsShort(quote.est, a.decimals, 6)} {a.symbol}
              <small>{zh ? `至少 ${fmtUnitsShort(quote.min, a.decimals, 6)}，含 1% 池费` : `at least ${fmtUnitsShort(quote.min, a.decimals, 6)}, incl. the 1% pool fee`}</small>
            </dd>
          </div>
        </dl>
      )}
      {amount != null && z.bem != null && amount > z.bem && <p className="tx-error">{zh ? 'BEM 余额不够' : 'Not enough BEM'}</p>}
      {short && (
        <p className="tx-error">
          {zh ? `测试网模拟路由里的 OKB 储备只剩 ${fmtUnitsShort(z.reserve, 18)}，换不了这么多` : `The testnet mock router only holds ${fmtUnitsShort(z.reserve, 18)} OKB`}
        </p>
      )}
      <WalletGate>
        <button
          className="btn btn-primary"
          disabled={tx.busy || !quote || short}
          onClick={() => tx.run(sellSteps({ cfg, account, amount, receive, min: quote.min, zh }), { onDone: () => setText('') })}
        >
          {zh ? '兑换' : 'Swap'}
        </button>
      </WalletGate>
      <TxStatus tx={tx} />
    </section>
  );
}
