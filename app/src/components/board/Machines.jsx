// 矿机：主板持有的矿机列表和当前买卖价（只读）。按规则决定 6.17，网站只做持仓交易，不提供矿机买卖入口；矿机由合约按 Firsto 买一 / 卖一公式买卖，任何人可以直接和合约交易。
import { useApp } from '../../App.jsx';
import { fmtBEM, fmtDuration, fmtInt } from '../../lib/format.js';

/** 收购期：只读显示主板当前收购价和收购条件。按规则决定 6.17，网站不提供矿机买卖入口，矿机交易直接和合约进行。 */
function PurchaseInfo({ d }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  if (!d.isPurchasing) return null;
  const c = d.config ?? {};
  const dur = (x) => fmtDuration(x ?? 0n, app.lang);
  if (app.xlayer) {
    return (
      <div className="sell-box">
        <h3>{zh ? '本局正在收购 RIG' : 'This board is buying RIG'}</h3>
        <p className="muted small">
          {zh
            ? `现在每单位算力收购价 ${fmtBEM(d.buyPrice, 4)} BEM：从上限的 ${Number(c.buyStartBps ?? 5000n) / 100}% 起，每 ${dur(c.buyStepInterval)}涨一点，上限 = min(BSC 矿机卖一, 开局快照 ${fmtBEM(d.buyPriceCap, 4)})；报价过期时暂停收购。两种卖法：直接按收购价卖给本局；或者在 RIG 矿机市场挂卖单，单价不高于收购价时，任何人（包括运营机器人）都可以把它卖给本局，按卖单价成交。只收算力 ${fmtInt(c.minMachineWeight)}–${fmtInt(c.maxMachineWeight)}、3 天内同步过的 RIG；收购预算还剩 ${fmtBEM(d.budget, 2)} BEM。`
            : `Current offer ${fmtBEM(d.buyPrice, 4)} BEM per unit of power: starts at ${Number(c.buyStartBps ?? 5000n) / 100}% of the cap and rises every ${dur(c.buyStepInterval)}; cap = min(BSC miner best ask, opening snapshot ${fmtBEM(d.buyPriceCap, 4)}); paused while the quote is stale. Sell directly at the offer, or list an ask on the RIG market: any ask at or below the offer can be sold to this board by anyone (including the operator bot) at the ask price. Only RIG with power ${fmtInt(c.minMachineWeight)}–${fmtInt(c.maxMachineWeight)} synced within 3 days. Budget left: ${fmtBEM(d.budget, 2)} BEM.`}{' '}
          <a href="#/market">{zh ? '去 RIG 市场' : 'Open the RIG market'}</a>
        </p>
      </div>
    );
  }
  return (
    <div className="sell-box">
      <h3>{zh ? '本局正在收购矿机' : 'This board is buying machines'}</h3>
      <p className="muted small">
        {d.feed?.updatedAt > 0n
          ? zh
            ? `现在每单位算力最多付 ${fmtBEM(d.buyPrice, 4)} BEM（Firsto 卖一，不超过一年产出 ${fmtBEM(d.buyPriceCap, 4)}）：运营机器人在 Firsto、官方矿机市场和 tapeout.market 上从最便宜的挂单往上买，主板按实际花费付款；报价超过 3 小时没更新时暂停收购。`
            : `Up to ${fmtBEM(d.buyPrice, 4)} BEM per unit of weight (the Firsto best ask, capped at one year of output, ${fmtBEM(d.buyPriceCap, 4)}): the operator bot buys the cheapest listings on Firsto, the official machine market and tapeout.market first, and the board pays the actual cost; paused when the quote is over 3 hours old. `
          : zh
            ? `现在每单位算力收购价 ${fmtBEM(d.buyPrice, 4)} BEM（还没有市场报价，按默认曲线）。`
            : `Current offer ${fmtBEM(d.buyPrice, 4)} BEM per unit of weight (no market quote yet; default curve). `}
        {zh
          ? `只收已验证、在挖、运行满 ${dur(c.minMachineAge)}、算力 ${fmtInt(c.minMachineWeight)}–${fmtInt(c.maxMachineWeight)} 的官方矿机（以及代码和官方矿机相同的工厂处理器矿机，如 Behemoth）；收购预算还剩 ${fmtBEM(d.budget, 2)} BEM。想把矿机卖给主板：挂到上面这几个市场，价格在收购上限以内、又是最便宜的那几张时，机器人会买入（主板不接受直接按报价卖进来）。`
          : `Only verified official machines that are mining, at least ${dur(c.minMachineAge)} old and weight ${fmtInt(c.minMachineWeight)}–${fmtInt(c.maxMachineWeight)} (also factory processors with the official machine code, such as Behemoth). Budget left: ${fmtBEM(d.budget, 2)} BEM. To sell a machine to the board, list it on one of those markets: the bot buys the cheapest listings within the limit (the board does not take direct sales at the quoted price).`}
      </p>
    </div>
  );
}

/** Firsto 买一 / 卖一报价的状态（两种局共用）；X Layer 上是运营地址转报的 BSC 行情 */
function FeedLine({ f, zh, xlayer }) {
  if (!f) return null;
  if (f.abandoned || !f.updatedAt)
    return <p className="muted small">{zh ? '矿机报价：运营地址停止报价（从没报过或超过 7 天没更新）。' : 'Machine quote: the operator has stopped quoting (never posted or over 7 days old).'}</p>;
  const mins = Math.max(0, Math.round((Date.now() / 1000 - Number(f.updatedAt)) / 60));
  const age = mins < 120 ? (zh ? `${mins} 分钟前` : `${mins} min ago`) : zh ? `${(mins / 60).toFixed(1)} 小时前` : `${(mins / 60).toFixed(1)} h ago`;
  return (
    <p className="muted small">
      {zh
        ? `矿机报价（每单位算力，行情数据来源：${xlayer ? '运营地址转报的 BSC 矿机行情' : 'Firsto'}）：买一 ${fmtBEM(f.bid, 4)} / 卖一 ${fmtBEM(f.ask, 4)} BEM，${age}更新${f.fresh ? '' : f.catchingUp ? '，追价中：市价离上一次报价超过 5%，每 50 分钟追 5%，追到市价前矿机买卖暂停' : '，已过期：矿机买卖暂停，等运营地址重新报价'}。`
        : `Machine quote (per unit of weight, market data: ${xlayer ? 'BSC miner market, relayed by the operator' : 'Firsto'}): bid ${fmtBEM(f.bid, 4)} / ask ${fmtBEM(f.ask, 4)} BEM, updated ${age}${f.fresh ? '' : f.catchingUp ? '; catching up with the market (5% every 50 minutes), machine trading is paused until it gets there' : '; stale, machine trading is paused until the operator posts again'}.`}
    </p>
  );
}

export default function Machines({ d, kind }) {
  const { lang, xlayer } = useApp();
  const zh = lang === 'zh';
  const list = d.machines ?? [];
  const ss = d.stdSales ?? {};
  const dur = (x) => fmtDuration(x ?? 0n, lang);
  const step = dur(d.feed?.sellStepInterval ?? 6n * 3600n);
  const saleNote = (m) => {
    if (m.sold) return null;
    if (kind === 'month' && d.stateName === 'Settling')
      return m.askPrice > 0n ? `${zh ? '现价' : 'price'} ${fmtBEM(m.askPrice, 2)}` : zh ? '暂停出售（报价过期）' : 'paused (stale quote)';
    if (kind === 'std' && d.stateName === 'Liquidating') {
      if (!m.salePhase) return zh ? '暂停出售（报价过期）' : 'paused (stale quote)';
      const p = `${fmtBEM(m.pricePerWeight * BigInt(m.weight), 2)}`;
      return m.salePhase === 2 ? `${zh ? '拍卖价' : 'auction'} ${p}` : `${zh ? '现价' : 'price'} ${p}`;
    }
    return null;
  };

  return (
    <section className="panel machines">
      <div className="panel-head">
        <h2>{zh ? '矿机' : 'Machines'}</h2>
        <span className="muted">
          {zh ? `${list.length} 台 · 在挖算力 ${fmtInt(d.activeWeight)}` : `${list.length} · active weight ${fmtInt(d.activeWeight)}`}
        </span>
      </div>
      {kind === 'std' && d.stateName === 'Liquidating' && (
        <p className="muted small">
          {zh
            ? `终局出售：前 ${dur(ss.marketPeriod ?? 30n * 86_400n)}按市价卖，每单位算力 = max(买一, 卖一 × (99% − 每 ${step}降 0.5%))，没有成本价底线，但不低于采购均价的 60%；之后还没卖掉的转降价拍卖，从当时的买一起，${dur(ss.decayDuration ?? 14n * 86_400n)}降到采购均价的 60%，在底价停留 ${dur(ss.floorHold ?? 7n * 86_400n)}后重新开始。卖矿机的收入并入底池。`
            : `Final sale: for the first ${dur(ss.marketPeriod ?? 30n * 86_400n)} machines sell at market, max(bid, ask × (99% − 0.5% every ${step})) per unit of weight, with no cost floor but never below 60% of the average buy price; after that, unsold machines go to a falling auction from the then best bid down to 60% of the average buy price over ${dur(ss.decayDuration ?? 14n * 86_400n)}, holding ${dur(ss.floorHold ?? 7n * 86_400n)} at the floor before restarting. Sales go into the pot.`}
        </p>
      )}
      {kind === 'month' && d.stateName === 'Settling' && xlayer && (
        <p className="muted small">
          {zh
            ? `结算：每台 RIG 的整台价 = max(算力 × max(买一, 卖一 × (99% − 每 ${step}降 0.5%)), 成本价)。可以在 RIG 矿机市场直接买，或者挂统一买单等机器人成交（买家只付这个价）；也会交接给正在准备的月局（不低于成本价才成交）。卖出前这张 RIG 要在 1 天内同步过。报价过期时暂停出售；市场价低于成本价时继续挖，产出按投入比例分给持有人。`
            : `Settling: whole-RIG price = max(power × max(bid, ask × (99% − 0.5% every ${step})), cost). Buy it on the RIG market, or place a collection bid there and the bot fills it (you pay this price only); it can also go to a preparing board (only at or above cost). The RIG must have synced within 1 day. Sales pause while the quote is stale; below cost, RIG keep mining and output goes to holders pro rata.`}{' '}
          <a href="#/market">{zh ? '去 RIG 市场' : 'Open the RIG market'}</a>
        </p>
      )}
      {kind === 'month' && d.stateName === 'Settling' && !xlayer && (
        <p className="muted small">
          {zh
            ? `结算：矿机由合约按市价出售，整台价 = max(算力 × max(买一, 卖一 × (99% − 每 ${step}降 0.5%)), 成本价)，任何人都可以直接和卖矿合约成交（网站不提供买入入口）；也可以交接给正在准备的月局（不低于成本价才成交）。报价过期时暂停出售；运营地址停止报价时，任何人都可以按成本价买。市场价低于成本价时矿机继续挖，产出按投入比例分给持有人；持有人多数投票通过集体清算后，按批准的计划价出售，可以低于成本价。`
            : `Settling: machines are sold by the contract at market, whole-machine price = max(weight × max(bid, ask × (99% − 0.5% every ${step})), cost), and anyone can buy directly; they can also go to a preparing monthly board (only if not below cost). Sales pause while the quote is stale; if the operator stops quoting, anyone can buy at cost. Below cost, machines keep mining and output goes to holders pro rata; after a majority liquidation vote they sell at the approved plan prices, possibly below cost.`}
        </p>
      )}
      {((kind === 'std' && d.stateName === 'Liquidating') || (kind === 'month' && d.stateName === 'Settling') || d.isPurchasing) && (
        <FeedLine f={d.feed} zh={zh} xlayer={xlayer} />
      )}
      {list.length === 0 ? (
        <p className="muted">{zh ? '还没有矿机。' : 'No machines yet.'}</p>
      ) : (
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>#</th>
                <th>{xlayer ? (zh ? 'RIG 编号' : 'RIG') : zh ? '电路编号' : 'Circuit'}</th>
                <th>{zh ? '算力' : xlayer ? 'Power' : 'Weight'}</th>
                {kind === 'month' && <th>{zh ? '成本' : 'Cost'}</th>}
                <th>{zh ? '状态' : 'Status'}</th>
              </tr>
            </thead>
            <tbody>
              {list.map((m) => (
                <tr key={m.index}>
                  <td>{m.index}</td>
                  <td>{String(m.circuitId)}</td>
                  <td>{String(m.weight)}</td>
                  {kind === 'month' && <td>{fmtBEM(m.cost, 2)}</td>}
                  <td>
                    {m.sold
                      ? zh
                        ? '已售出 / 已交接'
                        : 'Sold / handed over'
                      : m.active
                        ? zh
                          ? '在挖'
                          : 'Mining'
                        : zh
                          ? '停止'
                          : 'Stopped'}
                    {saleNote(m) && <small>{' · '}{saleNote(m)}</small>}
                    {xlayer && !m.sold && m.syncFresh === false && <small>{zh ? ' · 待同步' : ' · needs sync'}</small>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <PurchaseInfo d={d} />
    </section>
  );
}
