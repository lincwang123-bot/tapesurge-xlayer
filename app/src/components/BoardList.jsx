import { useApp } from '../App.jsx';
import { useAsync } from '../lib/useAsync.js';
import { loadBoardList } from '../lib/protocol.js';
import BoardCard from './BoardCard.jsx';
import './participation-ui.css';

export default function BoardList({ kind }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const list = useAsync(() => loadBoardList(app.client, app.dep, kind, app.wallet.account), [kind, app.chainId, app.wallet.account], {
    refresh: app.version,
    interval: 30_000,
  });
  // Keep failed boards in the shared data source so participants can still claim refunds in My boards.
  const visibleBoards = (list.data?.boards ?? []).filter((b) => b.stateName !== 'Failed');

  return (
    <div className="board-list">
      <div className="page-heading">
        <p className="eyebrow">{zh ? '主板 · 两种运行节奏' : 'Boards · Two rhythms'}</p>
        <h1>{zh ? '两种节奏，同一个主板。' : 'Two rhythms. One board.'}</h1>
        <p className="muted">{zh ? '选择主板，先了解它的分配方式与退出规则。' : 'Choose a board. Understand its distributions and exit rules first.'}</p>
      </div>
      <div className="tabs">
        {!app.xlayer && (
          <a href="#/boards/std" className={kind === 'std' ? 'is-active' : ''}>
            {zh ? '标准局' : 'Standard'}
          </a>
        )}
        <a href="#/boards/month" className={kind === 'month' ? 'is-active' : ''}>
          {zh ? '月局' : 'Monthly'}
        </a>
      </div>
      <section className="panel board-rules">
        <dl className="board-rules-summary">
          <div>
            <dt>{zh ? '运行节奏' : 'Rhythm'}</dt>
            <dd>{kind === 'std' ? (zh ? '产出攒够，逐轮分配' : 'Distributions as output builds') : (zh ? '招募 3 天 · 挖矿 30 天' : '3 days to join · 30 days to mine')}</dd>
          </div>
          <div>
            <dt>{zh ? '分配方式' : 'Distribution'}</dt>
            <dd>{kind === 'std' ? (zh ? '脉冲出局 · 硅王终局' : 'Pulse exits · Silicon King finale') : (zh ? '一半按投入分配 · 一半抽奖' : 'Half pro rata · Half prize draws')}</dd>
          </div>
          <div>
            <dt>{zh ? '退出方式' : 'Exit options'}</dt>
            <dd>{kind === 'std' ? (zh ? '出局领取 · 挂单转让 · 清算' : 'Pulse payout · Position sale · Liquidation') : (zh ? '矿机回款 · 结算期转让 · 投票清算' : 'Machine sales · Settlement trading · Liquidation vote')}</dd>
          </div>
        </dl>
        <p className="board-rules-risk">{zh ? '本金不保证全额收回，收回时间也不确定。' : 'Principal is not guaranteed; the timing of recovery is uncertain.'}</p>
        <details className="board-rules-full">
          <summary>{zh ? '查看完整规则与退出说明' : 'Full rules and exit details'}</summary>
          <p className="muted kind-intro">
        {kind === 'std'
          ? zh
            ? '标准局：主板用大家的 BEM 收购矿机，产出攒进脉冲池；每次够付一个人的 105%，就按随机数选一人出局拿走。投入越少，越容易先被选中。最后留下的人是硅王，分底池的 30%。开局后持仓可以在盘口买卖。'
            : 'Standard: the board buys machines with everyone’s BEM; output fills a pulse pool. Each time it covers 105% of a stake, one player is ejected at random and paid. Smaller stakes tend to go first. The last player standing is the Silicon King and takes 30% of the pot. Positions can be traded on an order book after the board starts.'
          : zh
            ? '月局：招募 3 天、准备矿机最多 3 天（买满就提前开挖）、挖矿 30 天。30 天产出全部作为奖金池（月局只收 1% 入场费，奖金池不扣费）：一半按投入比例分给所有持仓，另一半按投入比例独立抽 5 个奖（60% / 15% / 15% / 5% / 5%）。结束后矿机按市场价出售或交接给下一块月局（正常情况下不低于成本价），回收的 BEM 先退本金；结算期间持仓可以在盘口买卖，持有人也可以多数投票低于成本价清算。本金可能无法全额收回，到账时间不确定。'
            : 'Monthly: 3 days to join, up to 3 days to prepare machines (mining starts early once bought out), 30 days of mining. All 30 days of output form the prize pool (monthly boards only charge the 1% entry fee): half is shared pro rata by stake, the other half goes to 5 independent stake-weighted draws split 60/15/15/5/5%. Afterwards machines are sold at market or handed to the next monthly board (normally not below cost), and the BEM recovered returns stakes first; positions trade on an order book during settlement, and holders may vote by majority to liquidate below cost. Principal is not guaranteed.'}
          </p>
        </details>
      </section>
      {list.loading && !list.data && <p className="muted">{zh ? '读取中…' : 'Loading…'}</p>}
      {list.error && !list.data && <p className="tx-error">{zh ? '读取失败，正在重试…' : 'Could not load; retrying…'}</p>}
      {list.data && visibleBoards.length === 0 && (
        <p className="muted">{zh ? '暂时没有可展示的主板。' : 'No boards to display right now.'}</p>
      )}
      <div className="card-grid">
        {visibleBoards.map((b) => (
          <BoardCard key={b.address} b={b} />
        ))}
      </div>
      {list.data && list.data.total > list.data.boards.length && (
        <p className="muted small">
          {zh ? `已读取最近 ${list.data.boards.length} 块，当前显示 ${visibleBoards.length} 块。` : `Showing ${visibleBoards.length} boards from the latest ${list.data.boards.length} loaded.`}
        </p>
      )}
    </div>
  );
}
