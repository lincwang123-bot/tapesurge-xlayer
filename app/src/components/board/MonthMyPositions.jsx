// v2 月局：我持有的每份持仓（可能是自己加入的，也可能是买来的），以及转让时结转给我的款项。
import { useApp } from '../../App.jsx';
import { ABI, monthWinChance } from '../../lib/protocol.js';
import { fmtBEM } from '../../lib/format.js';
import { TxStatus, WalletGate, useTx } from '../TxButton.jsx';
import { PositionMarket } from './PositionTrade.jsx';

function transferLine(d, zh) {
  if (d.stateName !== 'Settling') return zh ? '满月后（结算阶段）才能转让' : 'Transferable only after the month (settling phase)';
  if (d.claimsClosed) return zh ? '领取期限已过，不能再转让' : 'Claim window closed; no longer transferable';
  if (d.governanceLocked) return zh ? '集体清算投票进行中，暂时不能转让' : 'Locked while a liquidation vote is in progress';
  return zh ? '现在可以整份转让' : 'Transferable now';
}

function PositionCard({ d, p }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const tx = useTx();
  const s = p.socket;
  const passBack = !s.passReturned && (d.stateName === 'Failed' || d.stateName === 'Settling');
  const canClaim = (!d.claimsClosed && p.owed > 0n) || passBack;
  const chance = ['Recruiting', 'Preparing', 'Mining', 'Drawing'].includes(d.stateName) ? monthWinChance(s.stake, d.totalStake) : null;
  const wins = d.prizesDrawn ? d.winners.filter((w) => w.slot === p.slot) : [];
  const tradable = d.stateName === 'Settling' && !d.claimsClosed && !d.governanceLocked;

  return (
    <div className="position-card">
      <div className="panel-head">
        <h3>{zh ? `持仓 #${String(p.slot)}` : `Position #${String(p.slot)}`}</h3>
      </div>
      <dl className="kv">
        <div>
          <dt>{zh ? '原始投入' : 'Original stake'}</dt>
          <dd>{fmtBEM(s.stake, 4)} BEM</dd>
        </div>
        <div>
          <dt>{zh ? '通行证' : 'Pass'}</dt>
          <dd>
            HA1 #{String(s.passId)} · {s.passReturned ? (zh ? '已退回原持有人' : 'returned to its owner') : zh ? '锁在主板里' : 'locked in board'}
          </dd>
        </div>
        {wins.length > 0 && (
          <div>
            <dt>{zh ? '中奖' : 'Prizes'}</dt>
            <dd className="is-good">{wins.map((w) => `${fmtBEM(w.amount, 4)} BEM`).join(' + ')}</dd>
          </div>
        )}
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
        <p className="hint">{zh ? `5 个奖里至少中一个的概率约 ${chance.toFixed(2)}%` : `Chance to win at least one prize: about ${chance.toFixed(2)}%`}</p>
      )}
      {canClaim && (
        <WalletGate>
          <button
            className="btn btn-primary btn-sm"
            disabled={tx.busy}
            onClick={() => tx.run({ address: d.address, abi: ABI.month, functionName: 'claimAll', args: [p.slot] })}
          >
            {p.owed > 0n ? (zh ? `领取 ${fmtBEM(p.owed, 4)} BEM` : `Claim ${fmtBEM(p.owed, 4)} BEM`) : zh ? '退回通行证' : 'Return pass'}
          </button>
        </WalletGate>
      )}
      <TxStatus tx={tx} />
      {d.stateName === 'Settling' && !d.claimsClosed && app.dep.positionExchange && (
        <>
          <PositionMarket d={d} p={p} />
        </>
      )}
    </div>
  );
}

export default function MonthMyPositions({ d }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const tx = useTx();
  const slots = d.mySlots ?? [];
  if (!slots.length && !(d.myCredit > 0n)) return null;
  return (
    <section className="panel my-position">
      <div className="panel-head">
        <h2>{zh ? '我的持仓' : 'My positions'}</h2>
        <p className="muted">
          {zh
            ? '满月后，持仓可以整份转让给别人，折价卖出就等于接受损失、提前离场。转让时，卖方此前已经累计的款项留给卖方，买方只拿之后的部分；通行证退回原持有人。'
            : 'After the month, a position can be transferred whole; selling at a discount is how you exit early and accept the loss. Amounts accrued before the transfer stay with the seller; the pass returns to its original owner.'}
        </p>
      </div>
      {slots.map((p) => (
        <PositionCard key={String(p.slot)} d={d} p={p} />
      ))}
      {d.myCredit > 0n && (
        <div className="position-card">
          <dl className="kv">
            <div>
              <dt>{zh ? '转让时结转给你的款项' : 'Carried over to you on transfer'}</dt>
              <dd className="is-good">{fmtBEM(d.myCredit, 6)} BEM</dd>
            </div>
          </dl>
          <WalletGate>
            <button
              className="btn btn-primary btn-sm"
              disabled={tx.busy}
              onClick={() => tx.run({ address: d.address, abi: ABI.month, functionName: 'withdrawCredit', args: [app.wallet.account] })}
            >
              {zh ? '领取' : 'Claim'}
            </button>
          </WalletGate>
          <TxStatus tx={tx} />
        </div>
      )}
    </section>
  );
}
