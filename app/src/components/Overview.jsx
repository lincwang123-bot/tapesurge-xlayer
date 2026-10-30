import { useApp } from '../App.jsx';
import { useAsync, useNow } from '../lib/useAsync.js';
import { ABI, loadOverview, loadSummary } from '../lib/protocol.js';
import { fmtBEM, fmtBNB, fmtDuration, fmtInt, pct } from '../lib/format.js';
import { TxStatus, WalletGate, useTx } from './TxButton.jsx';
import PassPanel from './PassPanel.jsx';
import BoardCard from './BoardCard.jsx';
import MockBEMAbi from '../abi/MockBEM.json';
import '../overview-ui.css';

const ZERO = '0x0000000000000000000000000000000000000000';

function Genesis({ o }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const now = useNow();
  const tx = useTx();
  if (!o) return null;
  const deadline = Number(o.mintStart ?? 0n) + Number(o.genesisDelay ?? 0n);
  const native = app.net.native;
  const ready = o.minted >= o.genesisThreshold || now >= deadline;

  if (o.genesisStarted) {
    return (
      <section className="panel genesis is-live">
        <div className="panel-head">
          <h2>{zh ? '协议运行中' : 'Protocol live'}</h2>
          <span className="pill pill-live">{zh ? '已开局' : 'Live'}</span>
        </div>
        <div className="stats">
          <Stat label={zh ? '已铸晶体管' : 'Transistors minted'} value={fmtInt(o.minted)} sub={`/ ${fmtInt(o.supplyCap)}`} />
          {/* X Layer 版：铸造收入全部给手续费 Safe，没有回购和基金会份额 */}
          {!app.xlayer && <Stat label={zh ? '回购销毁' : 'BEM burned'} value={fmtBEM(o.burned, 2)} sub="BEM" />}
          <Stat label={zh ? '已分账铸造收入' : 'Mint revenue split'} value={fmtBNB(o.distributed, 4)} sub={native} />
          {!app.xlayer && <Stat label={zh ? '其中给基金会' : 'To foundation'} value={fmtBNB(o.toFoundation, 4)} sub="BNB" />}
        </div>
      </section>
    );
  }

  return (
    <section className="panel genesis">
      <div className="panel-head">
        <h2>{zh ? '创世开局' : 'Genesis'}</h2>
        <span className="pill">{zh ? '铸造中' : 'Minting'}</span>
      </div>
      <p className="muted">
        {zh
          ? `铸满 ${fmtInt(o.genesisThreshold)} 颗晶体管，或者从开放铸造起满 ${fmtDuration(o.genesisDelay, 'zh')}，任何人都可以触发开局，${app.xlayer ? '第一块月局开放招募' : '第一块标准局和月局同时开放招募'}。`
          : `Once ${fmtInt(o.genesisThreshold)} transistors are minted, or ${fmtDuration(o.genesisDelay, 'en')} after minting opened, anyone can start genesis and ${app.xlayer ? 'the first monthly board opens' : 'the first standard and monthly boards open'}.`}
      </p>
      <div className="progress">
        <div className="progress-bar" style={{ width: `${Math.min(100, Number(pct(o.minted ?? 0n, o.genesisThreshold ?? 1n)))}%` }} />
      </div>
      <div className="stats">
        <Stat label={zh ? '已铸晶体管' : 'Minted'} value={fmtInt(o.minted)} sub={`/ ${fmtInt(o.genesisThreshold)}`} />
        <Stat
          label={zh ? '最晚开局' : 'Latest start'}
          value={now >= deadline ? (zh ? '已到时间' : 'Now') : fmtDuration(deadline - now, app.lang)}
          sub={now >= deadline ? '' : zh ? '后' : 'left'}
        />
        <Stat label={zh ? '通行证上限' : 'Pass cap'} value={fmtInt((o.supplyCap ?? 0n) / 5n)} sub={zh ? '张' : 'passes'} />
      </div>
      {ready && (
        <WalletGate>
          <button
            className="btn btn-primary"
            disabled={tx.busy}
            onClick={() => tx.run({ address: app.dep.factory ?? app.dep.hub, abi: ABI.factory, functionName: 'startGenesis' })}
          >
            {zh ? '触发开局' : 'Start genesis'}
          </button>
        </WalletGate>
      )}
      <TxStatus tx={tx} />
    </section>
  );
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

function Faucet({ o }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const tx = useTx();
  if (!app.net.testnet) return null;
  const gas = app.xlayer ? 'OKB' : 'tBNB';
  return (
    <section className="panel faucet" id="overview-test-tokens">
      <div className="panel-head">
        <h2>{zh ? '测试网领币' : 'Testnet tokens'}</h2>
        <span className="pill pill-warn">{zh ? '仅供测试' : 'Test only'}</span>
      </div>
      <div className="faucet-art" aria-hidden="true"><span className="brand-art brand-art-pool" /></div>
      <p className="muted">
        {zh
          ? `测试网上的 BEM 是模拟代币，每次可以领 100 枚。gas 用的 ${gas} 请到 `
          : `Testnet BEM is a mock token; claim 100 at a time. Get ${gas} for gas from the `}
        <a href={app.xlayer ? 'https://web3.okx.com/xlayer/faucet' : 'https://www.bnbchain.org/en/testnet-faucet'} target="_blank" rel="noreferrer">
          {app.xlayer ? (zh ? 'X Layer 官方水龙头' : 'X Layer faucet') : zh ? 'BNB Chain 官方水龙头' : 'BNB Chain faucet'}
        </a>
        {zh ? ' 领取。' : '.'}
        {app.xlayer && (zh ? '想试 RIG 矿机市场，可以在「RIG 市场」页领一张测试 RIG。' : ' To try the RIG market, claim a test RIG on the RIG market page.')}
      </p>
      {app.wallet.account && (
        <p className="balances">
          <span>
            {fmtBEM(o?.bem, 2)} <small>BEM</small>
          </span>
          <span>
            {fmtBNB(o?.bnb, 4)} <small>{gas}</small>
          </span>
        </p>
      )}
      <WalletGate>
        <button
          className="btn btn-ghost"
          disabled={tx.busy}
          onClick={() =>
            tx.run({ address: app.dep.bem, abi: MockBEMAbi, functionName: 'mint', args: [app.wallet.account, 100n * 10n ** 8n] })
          }
        >
          {zh ? '领 100 测试 BEM' : 'Claim 100 test BEM'}
        </button>
      </WalletGate>
      <TxStatus tx={tx} />
    </section>
  );
}

function Recruiting({ o }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const account = app.wallet.account;
  const boards = useAsync(
    async () => {
      const list = [];
      if (o?.stdRecruiting && o.stdRecruiting !== ZERO) list.push(await loadSummary(app.client, 'std', o.stdRecruiting, account));
      if (o?.monthRecruiting && o.monthRecruiting !== ZERO) list.push(await loadSummary(app.client, 'month', o.monthRecruiting, account));
      return list;
    },
    [o?.stdRecruiting, o?.monthRecruiting, account],
    { refresh: app.version, interval: 20_000 },
  );
  const visibleBoards = (boards.data ?? []).filter((b) => b.stateName !== 'Failed');
  if (!o?.genesisStarted) return null;
  return (
    <section className="recruiting">
      <h2 className="section-title">{zh ? '正在招募' : 'Recruiting now'}</h2>
      {boards.loading && !boards.data && <p className="muted" role="status">{zh ? '正在读取招募主板…' : 'Loading recruiting boards…'}</p>}
      {boards.error && <p className="tx-error" role="status">{zh ? '招募主板读取失败，正在重试…' : 'Could not load recruiting boards; retrying…'}</p>}
      <div className="card-grid">
        {visibleBoards.map((b) => (
          <BoardCard key={b.address} b={b} />
        ))}
        {boards.data && !boards.error && visibleBoards.length === 0 && (
          <p className="muted recruiting-empty">{zh ? '暂时没有招募中的主板（可能处于升级冷静期）。' : 'No board is recruiting right now.'}</p>
        )}
      </div>
    </section>
  );
}

function scrollToPreparation(id) {
  document.getElementById(id)?.scrollIntoView({
    behavior: window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth',
    block: 'start',
  });
}

function PreparationGuide() {
  const app = useApp();
  const zh = app.lang === 'zh';
  const account = app.wallet.account;
  return (
    <section className="panel overview-start" aria-labelledby="overview-start-title">
      <div className="overview-start-head">
        <h2 id="overview-start-title">{zh ? '准备好，再加入主板' : 'Get ready to join a board'}</h2>
        <p className="muted small">{zh ? '已有代币和通行证？可以直接选主板。' : 'Already have tokens and a pass? Go straight to boards.'}</p>
      </div>
      <ol className="overview-steps">
        <li>
          <span className="overview-step-number" aria-hidden="true">1</span>
          <div className="overview-step-content">
            <h3>{zh ? '连接钱包' : 'Connect your wallet'}</h3>
            {account
              ? <span className="overview-step-connected">{zh ? '✓ 已连接' : '✓ Connected'}</span>
              : <button className="overview-step-action" onClick={() => app.openConnect()}>{zh ? '连接' : 'Connect'}<span aria-hidden="true">↗</span></button>}
          </div>
        </li>
        <li>
          <span className="overview-step-number" aria-hidden="true">2</span>
          <div className="overview-step-content">
            <h3>{zh ? '准备参与材料' : 'Prepare essentials'}</h3>
            <div className="overview-step-links">
              {app.net.testnet && <button className="overview-step-action" onClick={() => scrollToPreparation('overview-test-tokens')}>{zh ? '测试币' : 'Test tokens'}<span aria-hidden="true">↓</span></button>}
              <button className="overview-step-action" onClick={() => scrollToPreparation('overview-pass')}>{zh ? '通行证' : 'Genesis Pass'}<span aria-hidden="true">↓</span></button>
            </div>
          </div>
        </li>
        <li>
          <span className="overview-step-number" aria-hidden="true">3</span>
          <div className="overview-step-content">
            <h3>{zh ? '选择主板' : 'Choose a board'}</h3>
            <a className="overview-step-action" href={app.xlayer ? '#/boards/month' : '#/boards/std'}>{zh ? '浏览主板' : 'Explore boards'}<span aria-hidden="true">↗</span></a>
          </div>
        </li>
      </ol>
    </section>
  );
}

export default function Overview() {
  const app = useApp();
  const zh = app.lang === 'zh';
  const ov = useAsync(() => loadOverview(app.client, app.dep, app.wallet.account), [app.chainId, app.wallet.account], {
    refresh: app.version,
    interval: 20_000,
  });
  const o = ov.data;

  return (
    <div className="overview overview-refined">
      <section className="intro">
        <div className="intro-copy">
        <span className="intro-eyebrow">{zh ? '晶涌协议 · 主板应用' : 'TapeSurge · Board app'}</span>
        <h1>{zh ? <>让矿机产出，<br />汇成下一次脉冲。</> : <>Mining output.<br />A new kind of surge.</>}</h1>
        <p>
          {zh
            ? '用创世通行证加入主板，让 BEM 汇集为 PoD 矿机，查看产出如何按链上规则分配。'
            : 'Join a board with a Genesis Pass. Pool BEM into PoD miners and follow rule-based onchain distributions.'}
        </p>
        <div className="intro-actions">
          <a className="btn btn-primary" href={app.xlayer ? '#/boards/month' : '#/boards/std'}>{zh ? '浏览主板' : 'Explore boards'}<span aria-hidden="true">↗</span></a>
          {app.xlayer && <a className="btn btn-ghost" href="#/market">{zh ? 'RIG 矿机市场' : 'RIG market'}<span aria-hidden="true">↗</span></a>}
          <a className="intro-paper" href="https://tapesurge.com/whitepaper.html" target="_blank" rel="noreferrer">{zh ? '阅读白皮书' : 'Read the whitepaper'}<span aria-hidden="true">↗</span></a>
        </div>
        <p className="intro-risk">{zh ? '产出与结算时间不作保证，参与前请阅读退出规则。' : 'Output and settlement timing are uncertain. Read the exit rules before joining.'}</p>
        </div>
      </section>
      {ov.error && !o && <p className="tx-error">{zh ? '读取链上数据失败，正在重试…' : 'Could not read the chain; retrying…'}</p>}
      <PreparationGuide />
      <div className={`overview-preparation-grid${app.net.testnet ? ' is-testnet' : ''}`}>
        <Faucet o={o} />
        <PassPanel overview={o} />
      </div>
      <Recruiting o={o} />
      <Genesis o={o} />
    </div>
  );
}
