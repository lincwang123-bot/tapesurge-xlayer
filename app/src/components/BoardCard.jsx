import { useApp } from '../App.jsx';
import { useNow } from '../lib/useAsync.js';
import { fmtBEM, fmtDuration, fmtInt, pct } from '../lib/format.js';

export const STATE_LABEL = {
  std: {
    Recruiting: ['招募中', 'Recruiting'],
    Failed: ['招募未成', 'Not filled'],
    Active: ['进行中', 'Running'],
    Liquidating: ['终局结算', 'Settling'],
  },
  month: {
    Recruiting: ['招募中', 'Recruiting'],
    Failed: ['招募未成', 'Not filled'],
    Preparing: ['准备矿机', 'Preparing'],
    Mining: ['挖矿中', 'Mining'],
    Drawing: ['开奖中', 'Drawing'],
    Settling: ['结算中', 'Settling'],
  },
};

export function stateLabel(kind, name, lang) {
  const l = STATE_LABEL[kind][name];
  return l ? l[lang === 'zh' ? 0 : 1] : name;
}

export function kindLabel(kind, lang) {
  if (kind === 'std') return lang === 'zh' ? '标准局' : 'Standard';
  return lang === 'zh' ? '月局' : 'Monthly';
}

/** 当前阶段的一句话 + 倒计时 */
export function phaseLine(b, now, lang) {
  const zh = lang === 'zh';
  const left = (t) => fmtDuration(Number(t) - now, lang);
  switch (b.stateName) {
    case 'Recruiting':
      return Number(b.recruitDeadline) > now
        ? zh
          ? `招募还剩 ${left(b.recruitDeadline)}`
          : `${left(b.recruitDeadline)} left to join`
        : zh
          ? '招募已到期，等待结束招募'
          : 'Recruitment ended, waiting to close';
    case 'Failed':
      return zh ? '未达到开局金额，全员可以取回本金和入场费' : 'Did not fill; everyone can withdraw stake and fee';
    case 'Active':
      return zh ? `在局 ${fmtInt(b.aliveCount)} 人 · 脉冲池 ${fmtBEM(b.pool, 2)} BEM` : `${fmtInt(b.aliveCount)} in play · pulse pool ${fmtBEM(b.pool, 2)} BEM`;
    case 'Liquidating':
      if (b.finishedAt && b.finishedAt !== 0n) return zh ? '已结束：矿机全部卖出，底池可以领取' : 'Finished: all machines sold, the pot is claimable';
      return zh ? '终局：矿机拍卖中，底池按规则分配' : 'Final phase: machines auctioned, pot distributed';
    case 'Preparing':
      // 月局的阶段是惰性推进的：准备期满后要有人调用 sync（运营机器人会做），链上状态才变成挖矿
      return Number(b.prepEnd) > now
        ? zh
          ? `准备矿机，买满即开挖，最晚 ${left(b.prepEnd)} 后开始挖矿`
          : `Preparing machines, mining starts within ${left(b.prepEnd)}`
        : zh
          ? '准备期已结束，等待推进到挖矿阶段'
          : 'Preparation is over, waiting to move to mining';
    case 'Mining':
      return Number(b.miningEnd) > now
        ? zh
          ? `挖矿还剩 ${left(b.miningEnd)} · 奖金池 ${fmtBEM(b.prizePool, 2)} BEM`
          : `${left(b.miningEnd)} of mining left · prize pool ${fmtBEM(b.prizePool, 2)} BEM`
        : zh
          ? '挖矿期满，等待开奖'
          : 'Mining done, waiting for the draw';
    case 'Drawing':
      return zh ? '正在开奖' : 'Drawing prizes';
    case 'Settling':
      if (b.principalRemaining === 0n) return zh ? '已开奖，本金已全部退回，可以领取' : 'Prizes drawn; all stakes returned and claimable';
      return zh ? '已开奖，矿机交接或出售后退还本金' : 'Prizes drawn; stake returned as machines are handed over or sold';
    default:
      return '';
  }
}

export default function BoardCard({ b }) {
  const { lang } = useApp();
  const zh = lang === 'zh';
  const now = useNow();
  const progress = Math.min(100, Number(pct(b.totalStake ?? 0n, b.target ?? 1n)));
  return (
    <a className={`board-card kind-${b.kind}`} href={`#/board/${b.kind}/${b.address}`}>
      <div className="board-card-top">
        <span className="board-kind">{kindLabel(b.kind, lang)}</span>
        <span className="board-no">#{String(b.number ?? '')}</span>
        <span className={`pill state-${b.stateName}`}>{stateLabel(b.kind, b.stateName, lang)}</span>
        {b.mySlot && b.mySlot !== 0n ? <span className="pill pill-me">{zh ? '我在局里' : 'Joined'}</span> : null}
      </div>
      <div className="board-card-amount">
        <strong>{fmtBEM(b.totalStake, 2)}</strong>
        <span> / {fmtBEM(b.target, 0)} BEM</span>
      </div>
      <div className="progress small">
        <div className="progress-bar" style={{ width: `${progress}%` }} />
      </div>
      <p className="board-card-line">{phaseLine(b, now, lang)}</p>
      <p className="board-card-meta">
        {zh ? `${fmtInt(b.socketCount)} 人参与` : `${fmtInt(b.socketCount)} players`}
        {b.stateName === 'Recruiting' && (
          <>
            {' · '}
            {zh ? '每人 ' : 'stake '}
            {fmtBEM(b.minStake, 2)}–{fmtBEM(b.maxStake, 2)} BEM
          </>
        )}
      </p>
    </a>
  );
}
