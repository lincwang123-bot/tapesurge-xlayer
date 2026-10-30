import { useApp } from '../App.jsx';
import { useAsync } from '../lib/useAsync.js';
import { loadBoardDetail, loadBoardList } from '../lib/protocol.js';
import { fmtBEM } from '../lib/format.js';
import BoardCard from './BoardCard.jsx';
import { BindEntry } from './BindPage.jsx';
import PassPanel from './PassPanel.jsx';
import { ZapSell } from './Zap.jsx';
import MyPosition from './board/MyPosition.jsx';
import MonthMyPositions from './board/MonthMyPositions.jsx';

export default function MyPositions() {
  const app = useApp();
  const zh = app.lang === 'zh';
  const account = app.wallet.account;
  const q = useAsync(
    async () => {
      if (!account) return [];
      // X Layer 版只有月局
      const [std, month] = await Promise.all([
        app.xlayer ? { boards: [] } : loadBoardList(app.client, app.dep, 'std', account),
        loadBoardList(app.client, app.dep, 'month', account),
      ]);
      const mine = [...std.boards, ...month.boards].filter((b) => b.mySlot && b.mySlot !== 0n);
      return Promise.all(mine.map((b) => loadBoardDetail(app.client, app.dep, b.kind, b.address, account)));
    },
    [account, app.chainId],
    { refresh: app.version, interval: 30_000 },
  );

  if (!account) {
    return (
      <section className="panel empty-state">
        <span className="empty-icon" aria-hidden="true">◇</span>
        <h1>{zh ? '我的主板' : 'My boards'}</h1>
        <p className="muted">{zh ? '连接钱包后显示你参加的主板和可领取的金额。' : 'Connect a wallet to see your boards and claimable amounts.'}</p>
        <button className="btn btn-primary" onClick={app.openConnect}>
          {zh ? '连接钱包' : 'Connect wallet'}
        </button>
      </section>
    );
  }

  const list = q.data ?? [];
  const totalOwed = list.reduce((s, d) => s + (d.myOwed ?? 0n), 0n);

  return (
    <div className="my">
      <section className="panel">
        <div className="panel-head">
          <h2>{zh ? '我的主板' : 'My boards'}</h2>
          {totalOwed > 0n && (
            <span className="pill pill-me">
              {zh ? '合计可领 ' : 'Claimable '}
              {fmtBEM(totalOwed, 4)} BEM
            </span>
          )}
        </div>
        {q.loading && !q.data && <p className="muted">{zh ? '读取中…' : 'Loading…'}</p>}
        {q.data && list.length === 0 && (
          <p className="muted">
            {zh ? '你还没有加入任何主板。' : 'You have not joined any board yet.'} <a href="#/boards/std">{zh ? '去看看' : 'Browse boards'}</a>
          </p>
        )}
      </section>
      {list.map((d) => (
        <div key={d.address} className="my-board">
          <BoardCard b={d} />
          {d.kind === 'std' ? <MyPosition d={d} kind={d.kind} /> : <MonthMyPositions d={d} />}
        </div>
      ))}
      <ZapSell />
      <BindEntry />
      <PassPanel compact />
    </div>
  );
}
