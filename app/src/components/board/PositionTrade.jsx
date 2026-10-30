// 持仓挂单簿界面（PositionExchange；月局 v2.0-rc1，标准局 v2.0-rc6 起）：
// - OrderBook：本局盘口（卖一卖二 / 买一买二、最近成交）、按最优价买入、挂买单、我的买单；
// - PositionMarket：每份持仓卡片上的"挂单出售 / 改价 / 撤单"和"卖给最高买单"。
// 价格一律按"每 1 BEM 本金"报价，页面显示成"本金的 X%"；成交款直接到卖家钱包。
import { useState } from 'react';
import { erc20Abi } from 'viem';
import { useApp } from '../../App.jsx';
import { useAsync } from '../../lib/useAsync.js';
import { ABI } from '../../lib/protocol.js';
import { ExchangeAbi, MAX_VALIDITY_DAYS, bestBidFor, loadBook, loadMyBids, pctOf, planBuyBest, quote, unitFromPct } from '../../lib/market.js';
import { fmtBEM, fmtTime, parseBEM } from '../../lib/format.js';
import { TxStatus, WalletGate, useTx } from '../TxButton.jsx';

const DAYS = [1, 7, MAX_VALIDITY_DAYS];

/** 交易所要能在成交时转走持仓：一次性授权本人全部持仓（挂单期间持仓仍在自己钱包里） */
function approvePositionsStep(app, d, zh) {
  return {
    label: zh ? '授权交易所' : 'Approve exchange',
    address: d.positionsAddress,
    abi: ABI.monthPositions,
    functionName: 'setApprovalForAll',
    args: [app.dep.positionExchange, true],
    skip: () =>
      app.client.readContract({
        address: d.positionsAddress,
        abi: ABI.monthPositions,
        functionName: 'isApprovedForAll',
        args: [app.wallet.account, app.dep.positionExchange],
      }),
  };
}

function approveBemStep(app, amount, zh) {
  return {
    label: zh ? '授权 BEM' : 'Approve BEM',
    address: app.dep.bem,
    abi: erc20Abi,
    functionName: 'approve',
    args: [app.dep.positionExchange, amount],
    skip: async () =>
      (await app.client.readContract({ address: app.dep.bem, abi: erc20Abi, functionName: 'allowance', args: [app.wallet.account, app.dep.positionExchange] })) >= amount,
  };
}

/** 有效期：按链上时间算，比上限少留 10 分钟余量 */
const deadlineAfter = (now, days) => BigInt(now) + BigInt(days) * 86_400n - (days === MAX_VALIDITY_DAYS ? 600n : 0n);

function useBook(d) {
  const app = useApp();
  return useAsync(() => loadBook(app.client, app.dep.positionExchange, d.address), [d.address, app.chainId], { refresh: app.version, interval: 20_000 });
}

function lockedText(d, zh) {
  if (d.kind === 'std') {
    if (d.stateName === 'Active' && d.drawPending) return zh ? '正在等开奖随机数，暂停成交（可以挂单）' : 'Trading paused while a draw waits for randomness';
    if (d.stateName === 'Active') return zh ? '首轮收购结束后才能成交（可以先挂单）' : 'Trading opens after the first purchase round';
  }
  if (d.governanceLocked) return zh ? '集体清算投票进行中，暂停成交（可以挂单，投票结束后才能成交）' : 'Trading paused during the liquidation vote';
  return zh ? '现在不能成交' : 'Trading is closed right now';
}

// ------------------------------------------------------------------ 盘口

export function OrderBook({ d, kind = 'month' }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const q = useBook(d);
  // 月局：结算阶段；标准局：开局后（首轮收购、等开奖时只能挂单不能成交）和终局阶段
  const open = kind === 'std' ? d.stateName === 'Active' || d.stateName === 'Liquidating' : d.stateName === 'Settling';
  if (!open || d.claimsClosed) return null;
  const b = q.data;
  const me = app.wallet.account?.toLowerCase();

  return (
    <section className="panel order-book">
      <div className="panel-head">
        <h2>{zh ? '持仓盘口' : 'Position order book'}</h2>
        <p className="muted">
          {zh
            ? '价格按"每 1 BEM 原始本金"计算，显示为本金的百分比。买到的是这份持仓今后的全部权益（矿机卖出回款和继续挖矿的产出），卖方此前已累计的款项归卖方，通行证也留给原持有人。不承诺保本。'
            : 'Prices are per 1 BEM of original stake, shown as % of principal. A buyer gets all future proceeds of the position; amounts already accrued stay with the seller, and the pass stays with its original holder. Not principal-protected.'}
        </p>
      </div>
      {!b && <p className="muted small">{q.error ? (zh ? '读取失败，稍后自动重试' : 'Failed to load') : zh ? '读取中…' : 'Loading…'}</p>}
      {b && (
        <>
          {!b.tradable && <p className="tx-error">{lockedText(d, zh)}</p>}
          <div className="book">
            <div>
              <h4>{zh ? '卖单' : 'Asks'}</h4>
              <BookTable rows={[...b.asks].reverse()} kind="ask" me={me} zh={zh} best={b.asks[0]} />
            </div>
            <div>
              <h4>{zh ? '买单' : 'Bids'}</h4>
              <BookTable rows={b.bids} kind="bid" me={me} zh={zh} best={b.bids[0]} />
            </div>
          </div>
          <BuyBest d={d} b={b} />
          <PlaceBid d={d} b={b} />
          <MyBids d={d} />
          <Trades trades={b.trades} zh={zh} lang={app.lang} />
        </>
      )}
    </section>
  );
}

function BookTable({ rows, kind, me, zh, best }) {
  if (!rows.length) return <p className="muted small">{zh ? '暂无' : 'None'}</p>;
  return (
    <table className={`book-table is-${kind}`}>
      <thead>
        <tr>
          <th>{zh ? '本金的' : '% of stake'}</th>
          <th>{kind === 'ask' ? (zh ? '持仓本金' : 'Stake') : zh ? '剩余预算' : 'Budget left'}</th>
          <th>{kind === 'ask' ? (zh ? '总价' : 'Total') : zh ? '收多大' : 'Size'}</th>
        </tr>
      </thead>
      <tbody>
        {rows.map((r) => {
          const mine = (kind === 'ask' ? r.maker : r.bidder).toLowerCase() === me;
          const isBest = best && (kind === 'ask' ? r.slot === best.slot : r.bidId === best.bidId);
          return (
            <tr key={String(kind === 'ask' ? r.slot : r.bidId)} className={`${isBest ? 'is-best' : ''} ${mine ? 'is-me' : ''}`}>
              <td>{pctOf(r.unitPrice)}%</td>
              <td>{fmtBEM(kind === 'ask' ? r.stake : r.remaining, 2)}</td>
              <td>{kind === 'ask' ? fmtBEM(r.cost, 2) : r.minStake > 1n ? `${fmtBEM(r.minStake, 2)}–${fmtBEM(r.maxStake, 2)}` : `≤ ${fmtBEM(r.maxStake, 2)}`}</td>
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}

/** 按最优价买入：从卖一开始吃，单价不超过上限、总额不超过预算 */
function BuyBest({ d, b }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const tx = useTx();
  const others = b.asks.filter((a) => a.maker.toLowerCase() !== app.wallet.account?.toLowerCase());
  const [budget, setBudget] = useState('');
  const [maxPct, setMaxPct] = useState('');
  if (!others.length) return null;
  const total = parseBEM(budget);
  const cap = unitFromPct(maxPct || pctOf(others[others.length - 1].unitPrice));
  const plan = total && cap ? planBuyBest(b.asks, app.wallet.account, cap, total) : null;

  return (
    <div className="trade-box">
      <h4>{zh ? '按最优价买入' : 'Buy at best price'}</h4>
      <p className="muted small">
        {zh ? `卖一：本金的 ${pctOf(others[0].unitPrice)}%。从最便宜的卖单开始，一笔交易买到预算用完为止。` : `Best ask: ${pctOf(others[0].unitPrice)}% of stake. Fills from the cheapest ask until the budget is used.`}
      </p>
      <div className="row">
        <input value={budget} onChange={(e) => setBudget(e.target.value)} placeholder={zh ? '最多花（BEM）' : 'Spend up to (BEM)'} inputMode="decimal" />
        <input value={maxPct} onChange={(e) => setMaxPct(e.target.value)} placeholder={zh ? `最高 %（默认 ${pctOf(others[others.length - 1].unitPrice)}）` : 'Max % of stake'} inputMode="decimal" />
      </div>
      {plan && (
        <p className="small">
          {plan.count
            ? zh
              ? `能买到 ${plan.count} 份持仓，本金合计 ${fmtBEM(plan.stake, 2)} BEM，花 ${fmtBEM(plan.spent, 4)} BEM`
              : `${plan.count} position(s), ${fmtBEM(plan.stake, 2)} BEM of stake, for ${fmtBEM(plan.spent, 4)} BEM`
            : zh
              ? '这个预算和价格买不到任何一份'
              : 'Nothing fits this budget and price'}
        </p>
      )}
      <WalletGate>
        <button
          className="btn btn-primary btn-sm"
          disabled={tx.busy || !b.tradable || !plan?.count}
          onClick={() =>
            tx.run([
              approveBemStep(app, plan.spent, zh),
              {
                label: zh ? '买入' : 'Buy',
                address: app.dep.positionExchange,
                abi: ExchangeAbi,
                functionName: 'buyBest',
                args: [d.address, plan.slots, cap, plan.spent],
              },
            ])
          }
        >
          {zh ? '买入' : 'Buy'}
        </button>
      </WalletGate>
      <TxStatus tx={tx} />
    </div>
  );
}

/** 挂买单：托管预算，本局任何一份大小合适的持仓都可以卖给它 */
function PlaceBid({ d, b }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const tx = useTx();
  const [pct, setPct] = useState('');
  const [budget, setBudget] = useState('');
  const [minS, setMinS] = useState('');
  const [maxS, setMaxS] = useState('');
  const [days, setDays] = useState(7);
  const unit = unitFromPct(pct);
  const amount = parseBEM(budget);
  const lo = minS ? parseBEM(minS) : 0n;
  const hi = maxS ? parseBEM(maxS) : d.maxStake ?? 0n;
  const ok = unit && amount && amount >= 100_000_000n && lo != null && hi != null && hi >= (lo || 1n) && amount >= quote(lo || 1n, unit);
  const crosses = unit && b.asks[0] && unit >= b.asks[0].unitPrice;

  return (
    <div className="trade-box">
      <h4>{zh ? '挂买单' : 'Place a bid'}</h4>
      <p className="muted small">
        {zh
          ? `预算全额托管在交易所，有人卖给你时直接成交；可以连续买多份，直到预算用完。每张至少 1 BEM，每人每局最多 20 张，最长 ${MAX_VALIDITY_DAYS} 天，撤单或过期后剩余预算退回钱包。${d.kind === 'std' ? '标准局的买单只收还没出局的持仓。' : ''}`
          : `The budget is held by the exchange and fills whenever a holder sells to you. At least 1 BEM, up to 20 open bids per board, up to ${MAX_VALIDITY_DAYS} days; the rest is refunded on cancel or expiry.${d.kind === 'std' ? ' On standard boards bids only buy positions still in play.' : ''}`}
      </p>
      <div className="row">
        <input value={pct} onChange={(e) => setPct(e.target.value)} placeholder={zh ? '出价：本金的 %' : 'Bid: % of stake'} inputMode="decimal" />
        <input value={budget} onChange={(e) => setBudget(e.target.value)} placeholder={zh ? '预算（BEM）' : 'Budget (BEM)'} inputMode="decimal" />
      </div>
      <div className="row">
        <input value={minS} onChange={(e) => setMinS(e.target.value)} placeholder={zh ? '只收本金 ≥（可不填）' : 'Min stake (optional)'} inputMode="decimal" />
        <input value={maxS} onChange={(e) => setMaxS(e.target.value)} placeholder={zh ? '只收本金 ≤（可不填）' : 'Max stake (optional)'} inputMode="decimal" />
        <select value={days} onChange={(e) => setDays(Number(e.target.value))}>
          {DAYS.map((x) => (
            <option key={x} value={x}>
              {zh ? `${x} 天` : `${x} d`}
            </option>
          ))}
        </select>
      </div>
      {crosses && <p className="muted small">{zh ? '你的出价不低于卖一，可以直接用上面的"按最优价买入"立刻成交。' : 'Your bid reaches the best ask; you can buy instantly above.'}</p>}
      <WalletGate>
        <button
          className="btn btn-ghost btn-sm"
          disabled={tx.busy || !ok}
          onClick={() =>
            tx.run([
              approveBemStep(app, amount, zh),
              {
                label: zh ? '挂买单' : 'Place bid',
                address: app.dep.positionExchange,
                abi: ExchangeAbi,
                functionName: 'placeBid',
                args: [d.address, unit, amount, lo, hi, deadlineAfter(b.now, days)],
              },
            ])
          }
        >
          {zh ? '挂买单' : 'Place bid'}
        </button>
      </WalletGate>
      <TxStatus tx={tx} />
    </div>
  );
}

function MyBids({ d }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const tx = useTx();
  const me = app.wallet.account;
  const q = useAsync(() => loadMyBids(app.client, app.dep.positionExchange, d.address, me), [d.address, me], { refresh: app.version, interval: 30_000 });
  if (!q.data?.length) return null;
  return (
    <div className="trade-box">
      <h4>{zh ? '我的买单' : 'My bids'}</h4>
      <ul className="bid-list">
        {q.data.map((b) => (
          <li key={String(b.bidId)}>
            <span>
              {pctOf(b.unitPrice)}% · {zh ? '剩余' : 'left'} {fmtBEM(b.remaining, 2)} BEM · {zh ? '截止' : 'until'} {fmtTime(b.deadline, app.lang)}
              {!b.valid && <small> · {zh ? '已失效，可以退款' : 'expired, refundable'}</small>}
            </span>
            <button
              className="btn btn-ghost btn-sm"
              disabled={tx.busy}
              onClick={() => tx.run({ address: app.dep.positionExchange, abi: ExchangeAbi, functionName: 'cancelBid', args: [b.bidId] })}
            >
              {zh ? '撤单退款' : 'Cancel'}
            </button>
          </li>
        ))}
      </ul>
      <TxStatus tx={tx} />
    </div>
  );
}

function Trades({ trades, zh, lang }) {
  if (!trades.length) return null;
  return (
    <div className="trade-box">
      <h4>{zh ? '最近成交' : 'Recent trades'}</h4>
      <ul className="bid-list">
        {trades.map((t, i) => (
          <li key={i}>
            <span>
              {pctOf(t.unitPrice)}% · {zh ? '持仓' : 'position'} #{String(t.slot)} · {fmtBEM(t.stake, 2)} BEM {zh ? '本金' : 'stake'}
            </span>
            <small>{fmtTime(t.time, lang)}</small>
          </li>
        ))}
      </ul>
    </div>
  );
}

// ------------------------------------------------------------------ 持仓卡片上的卖出

export function PositionMarket({ d, p }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const q = useBook(d);
  const b = q.data;
  if (!b) return null;
  const mine = b.asks.find((a) => a.slot === p.slot);
  const bid = bestBidFor(b.bids, p.socket.stake, app.wallet.account);
  return (
    <div className="trade-box">
      <h4>{zh ? '卖出这份持仓' : 'Sell this position'}</h4>
      {!b.tradable && <p className="muted small">{lockedText(d, zh)}</p>}
      {bid && <SellToBid d={d} p={p} bid={bid} tradable={b.tradable} />}
      <ListAsk d={d} p={p} b={b} mine={mine} />
    </div>
  );
}

function SellToBid({ d, p, bid, tradable }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const tx = useTx();
  const get = quote(p.socket.stake, bid.unitPrice);
  return (
    <div className="row small">
      <span>
        {zh ? `最高买单：本金的 ${pctOf(bid.unitPrice)}%，卖出到手 ${fmtBEM(get, 4)} BEM` : `Best bid: ${pctOf(bid.unitPrice)}%, you receive ${fmtBEM(get, 4)} BEM`}
      </span>
      <WalletGate>
        <button
          className="btn btn-primary btn-sm"
          disabled={tx.busy || !tradable}
          onClick={() =>
            tx.run([
              approvePositionsStep(app, d, zh),
              { label: zh ? '卖出' : 'Sell', address: app.dep.positionExchange, abi: ExchangeAbi, functionName: 'sellToBid', args: [bid.bidId, p.slot, bid.unitPrice] },
            ])
          }
        >
          {zh ? '立即卖出' : 'Sell now'}
        </button>
      </WalletGate>
      <TxStatus tx={tx} />
    </div>
  );
}

function ListAsk({ d, p, b, mine }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const tx = useTx();
  const [pct, setPct] = useState('');
  const [days, setDays] = useState(7);
  const unit = unitFromPct(pct);
  const best = b.asks.find((a) => a.slot !== p.slot);
  return (
    <>
      {mine ? (
        <p className="small">
          {zh
            ? `你的卖单：本金的 ${pctOf(mine.unitPrice)}%（总价 ${fmtBEM(mine.cost, 4)} BEM），${fmtTime(mine.deadline, app.lang)} 到期。挂单期间持仓仍在你钱包里，照常收到分配。`
            : `Your ask: ${pctOf(mine.unitPrice)}% (${fmtBEM(mine.cost, 4)} BEM), until ${fmtTime(mine.deadline, app.lang)}. The position stays in your wallet while listed.`}
        </p>
      ) : (
        <p className="muted small">
          {zh
            ? `挂到本局盘口上，等别人来买。${best ? `现在卖一是本金的 ${pctOf(best.unitPrice)}%。` : ''}${d.kind === 'std' ? '有人出局或进入终局后' : '卖出矿机、清算投票开始或结束后'}，旧卖单会失效，需要重新挂。`
            : `List on this board's order book. ${best ? `Best ask now: ${pctOf(best.unitPrice)}%. ` : ''}${d.kind === 'std' ? 'Asks lapse when someone is ejected or the final phase starts.' : 'Asks lapse when a machine is sold or a vote starts or ends.'}`}
        </p>
      )}
      <div className="row">
        <input value={pct} onChange={(e) => setPct(e.target.value)} placeholder={zh ? '卖价：本金的 %' : 'Ask: % of stake'} inputMode="decimal" />
        <select value={days} onChange={(e) => setDays(Number(e.target.value))}>
          {DAYS.map((x) => (
            <option key={x} value={x}>
              {zh ? `${x} 天` : `${x} d`}
            </option>
          ))}
        </select>
        <WalletGate>
          <button
            className="btn btn-ghost btn-sm"
            disabled={tx.busy || !unit}
            onClick={() =>
              tx.run([
                approvePositionsStep(app, d, zh),
                { label: zh ? '挂单' : 'List', address: app.dep.positionExchange, abi: ExchangeAbi, functionName: 'listAsk', args: [d.address, p.slot, unit, deadlineAfter(b.now, days)] },
              ])
            }
          >
            {mine ? (zh ? '改价' : 'Reprice') : zh ? '挂单' : 'List'}
          </button>
        </WalletGate>
        {mine && (
          <button
            className="link-btn"
            disabled={tx.busy}
            onClick={() => tx.run({ address: app.dep.positionExchange, abi: ExchangeAbi, functionName: 'cancelAsk', args: [d.address, p.slot] })}
          >
            {zh ? '撤单' : 'Cancel'}
          </button>
        )}
      </div>
      {unit && <p className="muted small">{zh ? `总价 ${fmtBEM(quote(p.socket.stake, unit), 4)} BEM` : `Total ${fmtBEM(quote(p.socket.stake, unit), 4)} BEM`}</p>}
      <TxStatus tx={tx} />
    </>
  );
}

