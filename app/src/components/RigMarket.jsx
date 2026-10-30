// X Layer 的 RIG 矿机市场页（XRigMarket，2026-10-29）：
// - 盘口：卖单（不托管，按每单位算力报价）和统一买单（托管 BEM，按算力范围和同步时间收 RIG）；
// - 月局：正在收购的月局可以买单价不高于收购价的卖单（任何人触发，按卖单价成交）；结算中的月局矿机按卖矿合约要价在这里卖；
// - 我的 RIG：挂卖单、卖给买单、直接卖给正在收购的月局；测试网可以领一张模拟 RIG、刷新同步时间。
// 市场成交价只展示，不参与月局定价（月局按 BSC 转报的行情定价）。
import { useState } from 'react';
import { erc20Abi } from 'viem';
import { useApp } from '../App.jsx';
import { useAsync } from '../lib/useAsync.js';
import { ABI } from '../lib/protocol.js';
import {
  MAX_VALIDITY_DAYS,
  MarketAbi,
  RigAbi,
  TRADE_KIND,
  bestBidForRig,
  boardForAsk,
  deadlineAfter,
  loadBoardSide,
  loadMarket,
  loadMyRigs,
  rememberRig,
  syncAge,
} from '../lib/rigmarket.js';
import { fmtBEM, fmtDuration, fmtInt, fmtTime, parseBEM, shortAddr } from '../lib/format.js';
import { TxStatus, WalletGate, useTx } from './TxButton.jsx';
import './market-ui.css';

const DAYS = [1, 7, MAX_VALIDITY_DAYS];

function approveBemStep(app, amount, zh) {
  return {
    label: zh ? '授权 BEM' : 'Approve BEM',
    address: app.dep.bem,
    abi: erc20Abi,
    functionName: 'approve',
    args: [app.dep.market, amount],
    skip: async () =>
      (await app.client.readContract({ address: app.dep.bem, abi: erc20Abi, functionName: 'allowance', args: [app.wallet.account, app.dep.market] })) >= amount,
  };
}

/** 卖单和卖给买单都要市场能转走 RIG：一次性授权（RIG 仍在自己钱包里，成交时才转走） */
function approveRigStep(app, zh) {
  return {
    label: zh ? '授权市场' : 'Approve market',
    address: app.dep.rig,
    abi: RigAbi,
    functionName: 'setApprovalForAll',
    args: [app.dep.market, true],
    skip: () => app.client.readContract({ address: app.dep.rig, abi: RigAbi, functionName: 'isApprovedForAll', args: [app.wallet.account, app.dep.market] }),
  };
}

const per = (zh) => (zh ? 'BEM / 算力' : 'BEM / power');

function ageText(now, syncedAt, lang) {
  if (!syncedAt) return '—';
  return lang === 'zh' ? `${fmtDuration(syncAge(now, syncedAt), 'zh')}前` : `${fmtDuration(syncAge(now, syncedAt), 'en')} ago`;
}

function Stat({ label, value, sub }) {
  return (
    <div className="stat">
      <span className="stat-label">{label}</span>
      <span className="stat-value">
        {value}
        {sub && <small> {sub}</small>}
      </span>
    </div>
  );
}

function Summary({ m }) {
  const { lang } = useApp();
  const zh = lang === 'zh';
  const f = m.feed ?? {};
  return (
    <section className="panel">
      <div className="stats">
        <Stat label={zh ? '卖一' : 'Best ask'} value={m.asks[0] ? fmtBEM(m.asks[0].price, 4) : '—'} sub={per(zh)} />
        <Stat label={zh ? '买一' : 'Best bid'} value={m.bids[0] ? fmtBEM(m.bids[0].price, 4) : '—'} sub={per(zh)} />
        <Stat
          label={zh ? 'BSC 矿机行情（参考）' : 'BSC miner market (ref.)'}
          value={f.ask ? `${fmtBEM(f.bid, 4)} / ${fmtBEM(f.ask, 4)}` : '—'}
          sub={f.fresh ? per(zh) : zh ? '已过期' : 'stale'}
        />
        <Stat label={zh ? '手续费' : 'Fee'} value={`${Number(m.feeBps) / 100}%`} />
      </div>
      <p className="muted small">
        {zh
          ? '月局的收购价和卖价按运营地址转报的 BSC 矿机行情计算，不看这里的成交价（成交量小的时候容易被操纵）。'
          : "Boards price miners from the BSC miner market relayed by the operator, not from trades here (thin markets are easy to move)."}
      </p>
    </section>
  );
}

/** 正在收购的月局和结算中月局在卖的矿机 */
function BoardSide({ side, m }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const tx = useTx();
  const { buying = [], offers = [] } = side ?? {};
  return (
    <section className="panel">
      <div className="panel-head">
        <h2>{zh ? '月局在买 / 在卖' : 'Boards buying / selling'}</h2>
      </div>
      {buying.length === 0 ? (
        <p className="muted small">{zh ? '现在没有正在收购的月局。' : 'No board is buying right now.'}</p>
      ) : (
        <ul className="bid-list">
          {buying.map((b) => (
            <li key={b.address}>
              <span>
                <a href={`#/board/month/${b.address}`}>{zh ? `月局 #${b.number}` : `Board #${b.number}`}</a>
                {zh
                  ? ` 正在收购：每单位算力最多 ${fmtBEM(b.buyPrice, 4)} BEM，预算还剩 ${fmtBEM(b.budget, 2)} BEM。单价不高于它的卖单，任何人都可以卖给它（按卖单价成交）。`
                  : ` is buying: up to ${fmtBEM(b.buyPrice, 4)} BEM per unit of power, ${fmtBEM(b.budget, 2)} BEM left. Any ask at or below this can be sold to it, at the ask price.`}
              </span>
            </li>
          ))}
        </ul>
      )}
      <h3 className="market-sub">{zh ? '结算中月局在卖的 RIG' : 'RIG from settling boards'}</h3>
      {offers.length === 0 ? (
        <p className="muted small">{zh ? '现在没有月局在卖矿机。' : 'No board is selling right now.'}</p>
      ) : (
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>{zh ? '月局' : 'Board'}</th>
                <th>RIG</th>
                <th>{zh ? '算力' : 'Power'}</th>
                <th>{zh ? '整台价' : 'Price'}</th>
                <th>{zh ? '单价' : 'Per power'}</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {offers.map((o) => (
                <tr key={`${o.board}:${o.index}`}>
                  <td>
                    <a href={`#/board/month/${o.board}`}>#{String(o.number)}</a>
                  </td>
                  <td>{String(o.rigId)}</td>
                  <td>{fmtInt(o.power)}</td>
                  <td>{fmtBEM(o.total, 2)}</td>
                  <td>{o.power > 0n ? fmtBEM(o.total / o.power, 4) : '—'}</td>
                  <td>
                    <WalletGate>
                      {o.syncFresh ? (
                        <button
                          className="btn btn-primary btn-sm"
                          disabled={tx.busy}
                          onClick={() =>
                            tx.run([
                              approveBemStep(app, o.total, zh),
                              {
                                label: zh ? '买入' : 'Buy',
                                address: app.dep.market,
                                abi: MarketAbi,
                                functionName: 'buyBoardMachine',
                                args: [o.board, o.index, o.total],
                                after: () => rememberRig(app.chainId, app.wallet.account, o.rigId),
                              },
                            ])
                          }
                        >
                          {zh ? '买入' : 'Buy'}
                        </button>
                      ) : app.net.testnet ? (
                        <button
                          className="btn btn-ghost btn-sm"
                          disabled={tx.busy}
                          title={zh ? '模拟在 BSC 金库为它发起一次收取' : 'Simulates a claim in the BSC vault'}
                          onClick={() => tx.run({ address: app.dep.rig, abi: RigAbi, functionName: 'claim', args: [[o.rigId]] })}
                        >
                          {zh ? '刷新同步' : 'Refresh sync'}
                        </button>
                      ) : (
                        <small className="muted">{zh ? '待同步' : 'Needs sync'}</small>
                      )}
                    </WalletGate>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <p className="muted small">
        {zh
          ? '月局矿机的整台价 = max(算力 × max(BSC 买一, 卖一 × (99% − 每 6 小时降 0.5%)), 成本价)；卖出前这张 RIG 要在 1 天内同步过。也可以挂一张统一买单，出价够高时运营机器人会把月局的矿机卖给你，你只付这个价。'
          : 'Board price = max(power × max(BSC bid, ask × (99% − 0.5% every 6 h)), cost); the RIG must have synced within 1 day. You can also place a collection bid: when it is high enough, the operator bot sells board RIG to it and you pay only this price.'}
      </p>
      <TxStatus tx={tx} />
    </section>
  );
}

function Book({ m, side }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const tx = useTx();
  const me = app.wallet.account?.toLowerCase();
  const buying = side?.buying ?? [];
  return (
    <section className="panel">
      <div className="panel-head">
        <h2>{zh ? '盘口' : 'Order book'}</h2>
        <span className="muted">{zh ? `${m.asks.length} 张卖单 · ${m.bids.length} 张买单` : `${m.asks.length} asks · ${m.bids.length} bids`}</span>
      </div>
      <h3 className="market-sub">{zh ? '卖单（从便宜到贵）' : 'Asks (cheapest first)'}</h3>
      {m.asks.length === 0 ? (
        <p className="muted small">{zh ? '还没有卖单。' : 'No asks yet.'}</p>
      ) : (
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>RIG</th>
                <th>{zh ? '算力' : 'Power'}</th>
                <th>{zh ? '单价' : 'Per power'}</th>
                <th>{zh ? '整张' : 'Total'}</th>
                <th>{zh ? '同步' : 'Synced'}</th>
                <th>{zh ? '卖家' : 'Seller'}</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {m.asks.map((a) => {
                const mine = a.seller.toLowerCase() === me;
                const board = boardForAsk(buying, a);
                return (
                  <tr key={String(a.rigId)}>
                    <td>{String(a.rigId)}</td>
                    <td>{fmtInt(a.power)}</td>
                    <td>{fmtBEM(a.price, 4)}</td>
                    <td>{fmtBEM(a.total, 2)}</td>
                    <td>
                      {ageText(m.now, a.syncedAt, app.lang)}
                      {a.boardEligible && <small className="muted">{zh ? ' · 月局可收' : ' · board-eligible'}</small>}
                    </td>
                    <td>{mine ? (zh ? '我' : 'me') : shortAddr(a.seller)}</td>
                    <td className="market-actions">
                      <WalletGate>
                        {mine ? (
                          <button
                            className="btn btn-ghost btn-sm"
                            disabled={tx.busy}
                            onClick={() => tx.run({ address: app.dep.market, abi: MarketAbi, functionName: 'cancelAsk', args: [a.rigId] })}
                          >
                            {zh ? '撤单' : 'Cancel'}
                          </button>
                        ) : (
                          <button
                            className="btn btn-primary btn-sm"
                            disabled={tx.busy}
                            onClick={() =>
                              tx.run([
                                approveBemStep(app, a.total, zh),
                                {
                                  label: zh ? '买入' : 'Buy',
                                  address: app.dep.market,
                                  abi: MarketAbi,
                                  functionName: 'buyAsk',
                                  args: [a.rigId, a.total],
                                  after: () => rememberRig(app.chainId, app.wallet.account, a.rigId),
                                },
                              ])
                            }
                          >
                            {zh ? '买入' : 'Buy'}
                          </button>
                        )}
                        {board && (
                          <button
                            className="btn btn-ghost btn-sm"
                            disabled={tx.busy}
                            title={zh ? '把这张卖单卖给正在收购的月局，按卖单价成交' : 'Sell this ask to the buying board at the ask price'}
                            onClick={() => tx.run({ address: app.dep.market, abi: MarketAbi, functionName: 'sellAskToBoard', args: [a.rigId, board.address] })}
                          >
                            {zh ? `卖给月局 #${board.number}` : `Sell to board #${board.number}`}
                          </button>
                        )}
                      </WalletGate>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
      <h3 className="market-sub">{zh ? '统一买单（从高到低）' : 'Collection bids (highest first)'}</h3>
      {m.bids.length === 0 ? (
        <p className="muted small">{zh ? '还没有买单。' : 'No bids yet.'}</p>
      ) : (
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>#</th>
                <th>{zh ? '单价' : 'Per power'}</th>
                <th>{zh ? '剩余预算' : 'Budget left'}</th>
                <th>{zh ? '算力范围' : 'Power range'}</th>
                <th>{zh ? '同步要求' : 'Sync limit'}</th>
                <th>{zh ? '截止' : 'Until'}</th>
                <th>{zh ? '买家' : 'Bidder'}</th>
              </tr>
            </thead>
            <tbody>
              {m.bids.map((b) => (
                <tr key={String(b.bidId)}>
                  <td>{String(b.bidId)}</td>
                  <td>{fmtBEM(b.price, 4)}</td>
                  <td>{fmtBEM(b.remaining, 2)}</td>
                  <td>
                    {fmtInt(b.minPower)}–{b.maxPower >= 4_294_967_295n ? '∞' : fmtInt(b.maxPower)}
                  </td>
                  <td>{b.maxSyncAge === 0n ? (zh ? '不限' : 'any') : fmtDuration(b.maxSyncAge, app.lang)}</td>
                  <td>{fmtTime(b.deadline, app.lang)}</td>
                  <td>{b.bidder.toLowerCase() === me ? (zh ? '我' : 'me') : shortAddr(b.bidder)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <TxStatus tx={tx} />
    </section>
  );
}

/** 测试网：领一张模拟 RIG（编号随机，算力 10–60，同步时间 = 现在） */
function TestRig({ m }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const tx = useTx();
  if (!app.net.testnet || !app.dep.mockMachineCircuits) return null;
  const claim = () => {
    const id = 100_000n + BigInt(Math.floor(Math.random() * 900_000_000));
    const power = 10n + BigInt(Math.floor(Math.random() * 51));
    return tx.run({
      address: app.dep.rig,
      abi: RigAbi,
      functionName: 'mintRig',
      args: [app.wallet.account, id, app.dep.mockMachineCircuits, id, power],
      after: () => rememberRig(app.chainId, app.wallet.account, id),
    });
  };
  return (
    <div className="trade-box">
      <h4>{zh ? '测试网：领一张模拟 RIG' : 'Testnet: claim a mock RIG'}</h4>
      <p className="muted small">
        {zh
          ? '主网上的 RIG 是 TapeOut 发行的跨链凭证（每张对应一台锁在 BSC 金库里的 PoD 矿机）；测试网上用模拟合约，算力随机 10–60，可以拿来挂单、卖给买单或卖给正在收购的月局。'
          : 'On mainnet, RIG are TapeOut cross-chain vouchers (each stands for a PoD miner locked in a BSC vault). On testnet a mock contract mints one with random power 10–60 that you can list, sell to a bid or sell to a buying board.'}
        {m.me && <> {zh ? `你的 BEM：${fmtBEM(m.me.bem, 2)}` : `Your BEM: ${fmtBEM(m.me.bem, 2)}`}</>}
      </p>
      <WalletGate>
        <button className="btn btn-ghost btn-sm" disabled={tx.busy} onClick={claim}>
          {zh ? '领一张测试 RIG' : 'Claim a test RIG'}
        </button>
      </WalletGate>
      <TxStatus tx={tx} />
    </div>
  );
}

function ListAsk({ rigs, m }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const tx = useTx();
  const [id, setId] = useState('');
  const [price, setPrice] = useState('');
  const [days, setDays] = useState(7);
  const rig = rigs.find((r) => String(r.id) === id) ?? rigs[0];
  const p = parseBEM(price);
  const ok = rig && p && p > 0n;
  const ref = m.feed?.ask;
  return (
    <div className="trade-box">
      <h4>{zh ? '挂卖单' : 'List an ask'}</h4>
      <p className="muted small">
        {zh
          ? `RIG 留在你的钱包里，只授权给市场合约；有人买、或者卖给正在收购的月局时才转走。按每单位算力报价${ref ? `（BSC 卖一 ${fmtBEM(ref, 4)} 供参考）` : ''}，最长 ${MAX_VALIDITY_DAYS} 天；转走 RIG 或撤销授权后卖单自动失效。`
          : `The RIG stays in your wallet, approved to the market; it moves only when someone buys it or it is sold to a buying board. Price per unit of power${ref ? ` (BSC ask ${fmtBEM(ref, 4)} for reference)` : ''}, up to ${MAX_VALIDITY_DAYS} days; the ask lapses if the RIG moves or the approval is revoked.`}
      </p>
      <div className="row">
        <select value={rig ? String(rig.id) : ''} onChange={(e) => setId(e.target.value)}>
          {rigs.map((r) => (
            <option key={String(r.id)} value={String(r.id)}>
              RIG {String(r.id)} · {zh ? '算力' : 'power'} {fmtInt(r.power)}
            </option>
          ))}
        </select>
        <input value={price} onChange={(e) => setPrice(e.target.value)} placeholder={zh ? `单价（${per(zh)}）` : `Price (${per(zh)})`} inputMode="decimal" />
        <select value={days} onChange={(e) => setDays(Number(e.target.value))}>
          {DAYS.map((x) => (
            <option key={x} value={x}>
              {zh ? `${x} 天` : `${x} d`}
            </option>
          ))}
        </select>
      </div>
      {ok && <p className="small">{zh ? `整张 ${fmtBEM(p * rig.power, 2)} BEM` : `Total ${fmtBEM(p * rig.power, 2)} BEM`}</p>}
      <WalletGate>
        <button
          className="btn btn-primary btn-sm"
          disabled={tx.busy || !ok}
          onClick={() =>
            tx.run([
              approveRigStep(app, zh),
              { label: zh ? '挂单' : 'List', address: app.dep.market, abi: MarketAbi, functionName: 'listAsk', args: [rig.id, p, deadlineAfter(m.now, days)] },
            ])
          }
        >
          {zh ? '挂单' : 'List'}
        </button>
      </WalletGate>
      <TxStatus tx={tx} />
    </div>
  );
}

/** 别人转给你的、或者机器人从月局卖给你的 RIG，页面不一定能自动找到：按编号添加 */
function AddRig() {
  const app = useApp();
  const zh = app.lang === 'zh';
  const [id, setId] = useState('');
  if (!app.wallet.account) return null;
  const ok = /^\d+$/.test(id.trim());
  return (
    <div className="row market-add">
      <input value={id} onChange={(e) => setId(e.target.value)} placeholder={zh ? '没看到你的 RIG？按编号添加' : 'Missing a RIG? Add it by ID'} inputMode="numeric" />
      <button
        className="btn btn-ghost btn-sm"
        disabled={!ok}
        onClick={() => {
          rememberRig(app.chainId, app.wallet.account, BigInt(id.trim()));
          setId('');
          app.bump();
        }}
      >
        {zh ? '添加' : 'Add'}
      </button>
    </div>
  );
}

function MyRigs({ rigs, loading, m, side }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const tx = useTx();
  const buying = side?.buying ?? [];
  return (
    <section className="panel">
      <div className="panel-head">
        <h2>{zh ? '我的 RIG' : 'My RIG'}</h2>
        <span className="muted">{zh ? `${rigs.length} 张` : `${rigs.length}`}</span>
      </div>
      {rigs.length === 0 ? (
        <p className="muted small">
          {!app.wallet.account
            ? zh
              ? '连接钱包后显示。'
              : 'Connect a wallet to see your RIG.'
            : loading
              ? zh
                ? '正在查找你的 RIG…'
                : 'Looking for your RIG…'
              : zh
                ? '钱包里没有 RIG。'
                : 'No RIG in this wallet.'}
        </p>
      ) : (
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>RIG</th>
                <th>{zh ? '算力' : 'Power'}</th>
                <th>{zh ? '同步' : 'Synced'}</th>
                <th>{zh ? '状态' : 'Status'}</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {rigs.map((r) => {
                const bid = bestBidForRig(m.bids, r, m.now, app.wallet.account);
                const board = r.eligible ? buying.filter((b) => b.buyPrice * r.power <= b.budget).sort((a, b) => (a.buyPrice > b.buyPrice ? -1 : 1))[0] : null;
                return (
                  <tr key={String(r.id)}>
                    <td>{String(r.id)}</td>
                    <td>{fmtInt(r.power)}</td>
                    <td>{ageText(m.now, r.syncedAt, app.lang)}</td>
                    <td>
                      {r.listed ? (zh ? '已挂单' : 'Listed') : '—'}
                      {r.eligible && <small className="muted">{zh ? ' · 月局可收' : ' · board-eligible'}</small>}
                    </td>
                    <td className="market-actions">
                      <WalletGate>
                        {bid && (
                          <button
                            className="btn btn-primary btn-sm"
                            disabled={tx.busy}
                            onClick={() =>
                              tx.run([
                                approveRigStep(app, zh),
                                { label: zh ? '卖给买单' : 'Sell to bid', address: app.dep.market, abi: MarketAbi, functionName: 'sellToBid', args: [bid.bidId, r.id] },
                              ])
                            }
                          >
                            {zh ? `卖给买单 ${fmtBEM(bid.price * r.power, 2)}` : `Sell to bid ${fmtBEM(bid.price * r.power, 2)}`}
                          </button>
                        )}
                        {board && (
                          <button
                            className="btn btn-ghost btn-sm"
                            disabled={tx.busy}
                            onClick={() =>
                              tx.run([
                                { label: zh ? '授权月局' : 'Approve board', address: app.dep.rig, abi: RigAbi, functionName: 'approve', args: [board.address, r.id] },
                                // 最低单价 = 页面上显示的收购价 × 99%：签名到上链之间报价下调超过 1% 就回滚，不按更低的价卖（全局审计 2026-10-29 第 9 条）
                                { label: zh ? '卖给月局' : 'Sell to board', address: board.address, abi: ABI.month, functionName: 'sellMachine', args: [app.dep.rig, r.id, (board.buyPrice * 99n) / 100n] },
                              ])
                            }
                          >
                            {zh ? `按收购价卖给月局 #${board.number}（${fmtBEM(board.buyPrice * r.power, 2)}）` : `Sell to board #${board.number} (${fmtBEM(board.buyPrice * r.power, 2)})`}
                          </button>
                        )}
                        {app.net.testnet && (
                          <button
                            className="btn btn-ghost btn-sm"
                            disabled={tx.busy}
                            title={zh ? '模拟在 BSC 金库为它发起一次收取' : 'Simulates a claim in the BSC vault'}
                            onClick={() => tx.run({ address: app.dep.rig, abi: RigAbi, functionName: 'claim', args: [[r.id]] })}
                          >
                            {zh ? '刷新同步' : 'Refresh sync'}
                          </button>
                        )}
                      </WalletGate>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
      <TxStatus tx={tx} />
      <AddRig />
      <div className="market-forms">
        <TestRig m={m} />
        {rigs.length > 0 && <ListAsk rigs={rigs} m={m} />}
      </div>
    </section>
  );
}

function PlaceBid({ m }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const tx = useTx();
  const [price, setPrice] = useState('');
  const [budget, setBudget] = useState('');
  const [minP, setMinP] = useState('');
  const [maxP, setMaxP] = useState('');
  const [hours, setHours] = useState('');
  const [days, setDays] = useState(7);
  const p = parseBEM(price);
  const amount = parseBEM(budget);
  const lo = minP ? BigInt(minP.replace(/\D/g, '') || '0') : 1n;
  const hi = maxP ? BigInt(maxP.replace(/\D/g, '') || '0') : 4_294_967_295n;
  const age = hours ? BigInt(Math.round(Number(hours) * 3600)) : 0n;
  const ok = p && amount && amount >= 100_000_000n && lo > 0n && hi >= lo && amount >= p * lo;
  return (
    <div className="trade-box">
      <h4>{zh ? '挂统一买单' : 'Place a collection bid'}</h4>
      <p className="muted small">
        {zh
          ? `预算全额托管在市场合约。算力在范围内、同步时间满足要求的 RIG，持有人可以直接卖给你（按 单价 × 算力）；结算中月局的矿机要价不高于你的出价时，运营机器人也会卖给你，你只付月局的要价。每张至少 1 BEM，每人最多 20 张，最长 ${MAX_VALIDITY_DAYS} 天，撤单或过期后剩余预算退回。`
          : `The budget is escrowed. Any RIG in your power range that meets the sync limit can be sold to you at price × power; when a settling board's price is at or below your bid, the operator bot sells it to you and you pay only the board's price. At least 1 BEM, up to 20 open bids, up to ${MAX_VALIDITY_DAYS} days; the rest is refunded on cancel or expiry.`}
      </p>
      <div className="row">
        <input value={price} onChange={(e) => setPrice(e.target.value)} placeholder={zh ? `出价（${per(zh)}）` : `Price (${per(zh)})`} inputMode="decimal" />
        <input value={budget} onChange={(e) => setBudget(e.target.value)} placeholder={zh ? '预算（BEM）' : 'Budget (BEM)'} inputMode="decimal" />
      </div>
      <div className="row">
        <input value={minP} onChange={(e) => setMinP(e.target.value)} placeholder={zh ? '最小算力（可不填）' : 'Min power (optional)'} inputMode="numeric" />
        <input value={maxP} onChange={(e) => setMaxP(e.target.value)} placeholder={zh ? '最大算力（可不填）' : 'Max power (optional)'} inputMode="numeric" />
        <input value={hours} onChange={(e) => setHours(e.target.value)} placeholder={zh ? '同步不超过几小时（可不填）' : 'Synced within h (optional)'} inputMode="decimal" />
        <select value={days} onChange={(e) => setDays(Number(e.target.value))}>
          {DAYS.map((x) => (
            <option key={x} value={x}>
              {zh ? `${x} 天` : `${x} d`}
            </option>
          ))}
        </select>
      </div>
      <WalletGate>
        <button
          className="btn btn-primary btn-sm"
          disabled={tx.busy || !ok}
          onClick={() =>
            tx.run([
              approveBemStep(app, amount, zh),
              { label: zh ? '挂买单' : 'Place bid', address: app.dep.market, abi: MarketAbi, functionName: 'placeBid', args: [p, amount, lo, hi, age, deadlineAfter(m.now, days)] },
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

function MyBids({ m }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const tx = useTx();
  const bids = m.me?.bids ?? [];
  if (!bids.length) return null;
  return (
    <div className="trade-box">
      <h4>{zh ? '我的买单' : 'My bids'}</h4>
      <ul className="bid-list">
        {bids.map((b) => (
          <li key={String(b.bidId)}>
            <span>
              #{String(b.bidId)} · {fmtBEM(b.price, 4)} {per(zh)} · {zh ? '剩余' : 'left'} {fmtBEM(b.remaining, 2)} BEM · {zh ? '截止' : 'until'} {fmtTime(b.deadline, app.lang)}
              {!b.valid && <small> · {zh ? '已过期，可以退款' : 'expired, refundable'}</small>}
            </span>
            <button
              className="btn btn-ghost btn-sm"
              disabled={tx.busy}
              onClick={() => tx.run({ address: app.dep.market, abi: MarketAbi, functionName: 'cancelBid', args: [b.bidId] })}
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

function Trades({ m }) {
  const { lang } = useApp();
  const zh = lang === 'zh';
  return (
    <div className="trade-box">
      <h4>{zh ? '最近成交' : 'Recent trades'}</h4>
      {m.trades.length === 0 ? (
        <p className="muted small">{zh ? '还没有成交。' : 'No trades yet.'}</p>
      ) : (
        <ul className="bid-list">
          {m.trades.map((t, i) => (
            <li key={i}>
              <span>
                {fmtTime(t.time, lang)} · RIG {String(t.rigId)} · {zh ? '算力' : 'power'} {fmtInt(t.power)} · {fmtBEM(t.price, 4)} {per(zh)} ·{' '}
                {(TRADE_KIND[t.kind] ?? ['', ''])[zh ? 0 : 1]}
              </span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

export default function RigMarket() {
  const app = useApp();
  const zh = app.lang === 'zh';
  const account = app.wallet.account;
  const opts = { refresh: app.version, interval: 20_000 };
  const mk = useAsync(() => loadMarket(app.client, app.dep, account), [app.chainId, account], opts);
  const side = useAsync(() => loadBoardSide(app.client, app.dep), [app.chainId], opts);
  const mine = useAsync(() => loadMyRigs(app.client, app.dep, app.net, app.chainId, account), [app.chainId, account], { refresh: app.version, interval: 60_000 });
  if (!app.dep.market) {
    return (
      <section className="panel">
        <p>{zh ? '这套部署还没有 RIG 矿机市场。' : 'This deployment has no RIG market yet.'}</p>
      </section>
    );
  }
  const m = mk.data;
  return (
    <div className="rig-market">
      <div className="page-heading">
        <p className="eyebrow">{zh ? 'X Layer · RIG 矿机市场' : 'X Layer · RIG market'}</p>
        <h1>{zh ? '买卖 RIG，也和月局成交。' : 'Trade RIG, with players and boards.'}</h1>
        <p className="muted">
          {zh
            ? 'RIG 是 TapeOut 的矿机凭证：每张对应一台锁在 BSC 金库、仍在挖矿的 PoD 矿机，产出经 LayerZero 送到持有人。这里按每单位算力报价，月局在这里买矿、也在这里卖矿。'
            : 'RIG are TapeOut miner vouchers: each stands for a PoD miner locked in a BSC vault that keeps mining, with output delivered to the holder via LayerZero. Prices are per unit of power; boards buy and sell their miners here.'}
        </p>
      </div>
      {mk.error && !m && <p className="tx-error">{zh ? '读取市场失败，正在重试…' : 'Could not read the market; retrying…'}</p>}
      {!m ? (
        <p className="muted" role="status">
          {zh ? '正在读取盘口…' : 'Loading the book…'}
        </p>
      ) : (
        <>
          <Summary m={m} />
          <BoardSide side={side.data} m={m} />
          <Book m={m} side={side.data} />
          <MyRigs rigs={mine.data ?? []} loading={mine.loading} m={m} side={side.data} />
          <section className="panel">
            <div className="market-forms">
              <PlaceBid m={m} />
              <MyBids m={m} />
              <Trades m={m} />
            </div>
          </section>
        </>
      )}
    </div>
  );
}
