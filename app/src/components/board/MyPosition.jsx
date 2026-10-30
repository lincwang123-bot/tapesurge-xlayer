// 标准局：我持有的每份持仓（自己加入的或转让来的，v2.0-rc6 起可转让）：状态、出局概率、可领取金额、领取 / 取回通行证、
// 盘口挂单；以及转让时结转给我的款项（主板 credit）。月局见 MonthMyPositions.jsx。
import { useApp } from '../../App.jsx';
import { ABI, ejectChance } from '../../lib/protocol.js';
import { fmtBEM } from '../../lib/format.js';
import { TxStatus, WalletGate, useTx } from '../TxButton.jsx';
import { PositionMarket } from './PositionTrade.jsx';

function stdStatus(d, p, zh) {
  const s = p.socket;
  const king = d.kingSocket === p.slot;
  switch (d.stateName) {
    case 'Recruiting':
      return zh ? '已加入，等待开局' : 'Joined, waiting for the board to start';
    case 'Failed':
      return s.refunded
        ? zh
          ? '招募未成，本金和入场费已退回'
          : 'Not filled; stake and fee refunded'
        : zh
          ? '招募未成，可以取回本金和入场费'
          : 'Not filled; you can withdraw stake and fee';
    case 'Active':
      if (s.ejected) return zh ? `已出局，已获得本金的 105%（${fmtBEM((BigInt(s.stake) * 105n) / 100n, 4)} BEM）` : `Ejected with 105% of stake (${fmtBEM((BigInt(s.stake) * 105n) / 100n, 4)} BEM)`;
      return zh ? '在局中' : 'Still in play';
    case 'Liquidating':
      if (king) return zh ? '这份是硅王：底池的 30% 归它' : 'This is the Silicon King: 30% of the pot is its share';
      return s.ejected
        ? zh
          ? '已出局；终局时还按投入分底池'
          : 'Ejected; it still shares the pot by stake'
        : zh
          ? '终局：按投入分底池'
          : 'Final phase: the pot is shared by stake';
    default:
      return '';
  }
}

function transferLine(d, zh) {
  if (d.claimsClosed) return zh ? '领取期限已过，不能再转让' : 'Claim window closed; no longer transferable';
  if (d.transferable) return zh ? '现在可以整份转让' : 'Transferable now';
  if (d.stateName === 'Active' && d.drawPending) return zh ? '正在等开奖随机数，暂时不能转让' : 'Locked while a draw is waiting for randomness';
  if (d.stateName === 'Active') return zh ? '首轮收购结束后才能转让' : 'Transferable after the first purchase round';
  return zh ? '开局后才能转让' : 'Transferable after the board starts';
}

function PositionCard({ d, p }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const tx = useTx();
  const s = p.socket;
  const returnable = d.stateName === 'Failed' || d.stateName === 'Liquidating' || s.ejected;
  const passBack = returnable && !s.passReturned;
  const canClaim = (!d.claimsClosed && p.owed > 0n) || passBack; // 领取期限过后通行证仍可取回
  let chance = null;
  if (d.stateName === 'Active' && !s.ejected) chance = ejectChance(s.stake, d.aliveStake, d.aliveCount);

  return (
    <div className="position-card">
      <div className="panel-head">
        <h3>{zh ? `持仓 #${String(p.slot)}` : `Position #${String(p.slot)}`}</h3>
      </div>
      <dl className="kv">
        <div>
          <dt>{zh ? '投入' : 'Stake'}</dt>
          <dd>{fmtBEM(s.stake, 4)} BEM</dd>
        </div>
        <div>
          <dt>{zh ? '通行证' : 'Pass'}</dt>
          <dd>
            HA1 #{String(s.passId)} · {s.passReturned ? (zh ? '已退回加入者' : 'returned to the joiner') : zh ? '锁在主板里' : 'locked in board'}
          </dd>
        </div>
        <div>
          <dt>{zh ? '状态' : 'Status'}</dt>
          <dd>{stdStatus(d, p, zh)}</dd>
        </div>
        <div>
          <dt>{zh ? '现在可领取' : 'Claimable now'}</dt>
          <dd className={p.owed > 0n ? 'is-good' : ''}>{fmtBEM(p.owed, 6)} BEM</dd>
        </div>
        <div>
          <dt>{zh ? '转让' : 'Transfer'}</dt>
          <dd>{transferLine(d, zh)}</dd>
        </div>
      </dl>
      {chance != null && (
        <p className="hint">
          {zh
            ? `下一次脉冲选中这份出局的概率约 ${chance.toFixed(2)}%（在局 ${String(d.aliveCount)} 人）`
            : `Chance this position is picked at the next pulse: about ${chance.toFixed(2)}% (${String(d.aliveCount)} in play)`}
        </p>
      )}
      {canClaim && d.salesAddress && (
        <WalletGate>
          <button
            className="btn btn-primary"
            disabled={tx.busy}
            onClick={() => tx.run({ address: d.salesAddress, abi: ABI.stdSales, functionName: 'claimAll', args: [d.address, p.slot] })}
          >
            {p.owed > 0n
              ? zh
                ? `领取 ${fmtBEM(p.owed, 4)} BEM${passBack ? ' 和通行证' : ''}`
                : `Claim ${fmtBEM(p.owed, 4)} BEM${passBack ? ' and pass' : ''}`
              : zh
                ? '取回通行证'
                : 'Return the pass'}
          </button>
        </WalletGate>
      )}
      <TxStatus tx={tx} />
      {d.transferable && app.dep.positionExchange && <PositionMarket d={d} p={p} />}
    </div>
  );
}

export default function MyPosition({ d }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const tx = useTx();
  const slots = d.mySlots ?? [];
  const credit = d.myCredit ?? 0n;
  if (!slots.length && credit === 0n) return null;

  return (
    <section className="panel my-position">
      <div className="panel-head">
        <h2>{zh ? '我的持仓' : 'My positions'}</h2>
        <span className="pill pill-me">{slots.length}</span>
      </div>
      {slots.map((p) => (
        <PositionCard key={String(p.slot)} d={d} p={p} />
      ))}
      {credit > 0n && !d.claimsClosed && (
        <div className="position-card">
          <p>
            {zh
              ? `记在你地址上的款项 ${fmtBEM(credit, 6)} BEM（出局推送失败的 105%，或转让持仓时结转给你的份额）`
              : `Held for your address: ${fmtBEM(credit, 6)} BEM (a failed 105% push, or your share carried over when you sold a position)`}
          </p>
          <WalletGate>
            <button
              className="btn btn-primary"
              disabled={tx.busy}
              onClick={() => tx.run({ address: d.address, abi: ABI.std, functionName: 'withdrawCredit', args: [app.wallet.account] })}
            >
              {zh ? `领取 ${fmtBEM(credit, 4)} BEM` : `Claim ${fmtBEM(credit, 4)} BEM`}
            </button>
          </WalletGate>
          <TxStatus tx={tx} />
        </div>
      )}
      <p className="muted small">
        {zh
          ? '运营地址会定期把可领的 BEM 和通行证自动打给每个人；你也可以随时自己领取。持仓的款项打给当前持有人，通行证退给最初加入的人。'
          : 'The operator pushes claimable BEM and passes to everyone periodically; you can also claim at any time. Position proceeds go to the current holder; passes go back to the original joiner.'}
      </p>
      {d.claimsClosed && <p className="muted">{zh ? '领取期限已过，剩余 BEM 已销毁。' : 'The claim window has closed; the remaining BEM was burned.'}</p>}
    </section>
  );
}
