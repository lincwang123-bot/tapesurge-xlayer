// 开奖记录：标准局逐次出局（Pulse 事件）；月局 5 个中奖者。
import { useApp } from '../../App.jsx';
import { useAsync } from '../../lib/useAsync.js';
import { ABI, eventAbi, getLogsChunked } from '../../lib/protocol.js';
import { explorerAddr, explorerTx } from '../../lib/chains.js';
import { fmtBEM, shortAddr } from '../../lib/format.js';

const PRIZE_SHARE = ['60%', '15%', '15%', '5%', '5%'];

function Pulses({ d }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const active = d.stateName === 'Active' || d.stateName === 'Liquidating';
  const logs = useAsync(
    () =>
      active
        ? getLogsChunked(app.client, {
            address: d.address,
            event: eventAbi(ABI.std, 'Pulse'),
            fromBlock: app.dep.fromBlock,
            chunk: app.net.logChunk,
          })
        : Promise.resolve({ logs: [] }),
    [d.address, active], { refresh: app.version });
  if (!active) return null;
  const list = [...(logs.data?.logs ?? [])].reverse();
  const me = app.wallet.account?.toLowerCase();
  return (
    <section className="panel history">
      <div className="panel-head">
        <h2>{zh ? '出局记录' : 'Ejections'}</h2>
        <span className="muted">
          {zh ? `已出局 ${String(d.socketCount - d.aliveCount)} / ${String(d.socketCount)} 人` : `${String(d.socketCount - d.aliveCount)} of ${String(d.socketCount)} ejected`}
        </span>
      </div>
      {d.stateName === 'Active' && (
        <p className="muted small">
          {d.drawPending
            ? zh
              ? '正在等待随机数，选出下一位出局者…'
              : 'Waiting for randomness to pick the next player…'
            : zh
              ? `脉冲池 ${fmtBEM(d.pool, 4)} / ${fmtBEM(d.drawThreshold, 4)} BEM：攒够后开下一次脉冲（够付在局最大投入的 105%，另含 3% 基金会和 2% 手续费）。`
              : `Pulse pool ${fmtBEM(d.pool, 4)} / ${fmtBEM(d.drawThreshold, 4)} BEM: the next pulse fires once it covers 105% of the largest stake in play, plus 3% foundation and 2% fees.`}
        </p>
      )}
      {logs.loading && !logs.data && <p className="muted">{zh ? '读取记录…' : 'Loading…'}</p>}
      {list.length > 0 && (
        <ol className="events">
          {list.map((l) => (
            <li key={`${l.transactionHash}:${l.logIndex}`} className={l.args.player.toLowerCase() === me ? 'is-me' : ''}>
              <span className="ev-tag">{l.args.king ? (zh ? '硅王' : 'King') : `#${String(l.args.slot)}`}</span>
              <a href={explorerAddr(app.chainId, l.args.player)} target="_blank" rel="noreferrer">
                {shortAddr(l.args.player)}
              </a>
              <span>
                {zh ? '获得' : 'received'} <strong>{fmtBEM(l.args.payout, 4)} BEM</strong>
              </span>
              <a className="muted" href={explorerTx(app.chainId, l.transactionHash)} target="_blank" rel="noreferrer">
                {zh ? '交易' : 'tx'}
              </a>
            </li>
          ))}
        </ol>
      )}
      {logs.data && list.length === 0 && <p className="muted">{zh ? '还没有人出局。' : 'Nobody has been ejected yet.'}</p>}
      {logs.data?.truncated && (
        <p className="muted small">
          {zh ? '只显示最近一段时间的记录，更早的请在区块浏览器查看。' : 'Only recent records are shown; see the explorer for older ones.'}
        </p>
      )}
    </section>
  );
}

function Winners({ d }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  if (!d.prizesDrawn) return null;
  const me = app.wallet.account?.toLowerCase();
  return (
    <section className="panel history">
      <div className="panel-head">
        <h2>{zh ? '中奖结果' : 'Prize winners'}</h2>
      </div>
      <ol className="events">
        {d.winners.map((w, i) => (
          <li key={i} className={w.owner?.toLowerCase() === me ? 'is-me' : ''}>
            <span className="ev-tag">
              {zh ? `第 ${i + 1} 奖` : `Prize ${i + 1}`} · {PRIZE_SHARE[i]}
            </span>
            {w.owner ? (
              <a href={explorerAddr(app.chainId, w.owner)} target="_blank" rel="noreferrer">
                {shortAddr(w.owner)}
              </a>
            ) : (
              <span>#{String(w.slot)}</span>
            )}
            <strong>{fmtBEM(w.amount, 4)} BEM</strong>
          </li>
        ))}
      </ol>
      <p className="muted small">
        {zh ? '奖金池一半按投入比例分给所有持仓（在"我的持仓"里领取），另一半抽这 5 个奖：独立抽取，同一个人可以中多个奖，奖金已直接打到中奖者钱包。' : 'Half of the prize pool is shared pro rata (claim it under My positions); the other half funds these 5 independent draws, which can repeat winners. Prizes were sent directly.'}
      </p>
    </section>
  );
}

export default function History({ d, kind }) {
  return kind === 'std' ? <Pulses d={d} /> : <Winners d={d} />;
}
