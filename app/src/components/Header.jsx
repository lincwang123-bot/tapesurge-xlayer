import { useState } from 'react';
import { useApp } from '../App.jsx';
import { AVAILABLE } from '../lib/chains.js';
import { shortAddr } from '../lib/format.js';

function Logo() {
  return (
    <svg viewBox="0 0 56 48" aria-hidden="true" className="logo">
      <path d="M2 25h6l5-10 6 20 7-29 7 40 7-30 5 14 5-7h5" />
      <circle cx="26" cy="3" r="2.6" fill="currentColor" stroke="none" />
    </svg>
  );
}

export default function Header() {
  const app = useApp();
  const zh = app.lang === 'zh';
  const [menu, setMenu] = useState(false);
  const page = app.route.page;
  const nav = [
    ['home', '#/', zh ? '总览' : 'Overview'],
    ['boards', app.xlayer ? '#/boards/month' : '#/boards/std', zh ? (app.xlayer ? '月局' : '主板') : app.xlayer ? 'Monthly boards' : 'Boards'],
    ...(app.xlayer ? [['market', '#/market', zh ? 'RIG 市场' : 'RIG market']] : []),
    ['me', '#/me', zh ? '我的' : 'My positions'],
  ];
  const w = app.wallet;
  const wrongChain = w.account && w.chainId !== app.chainId;

  return (
    <header className="header">
      <a className="brand" href="#/">
        <Logo />
        <span>TapeSurge</span>
        <small>{zh ? '晶涌协议' : 'App'}</small>
      </a>
      <nav className="nav" aria-label={zh ? '主导航' : 'Main navigation'}>
        {nav.map(([key, href, label]) => (
          <a key={key} href={href} aria-current={page === key || (key === 'boards' && page === 'board') ? 'page' : undefined} className={page === key || (key === 'boards' && page === 'board') ? 'is-active' : ''}>
            {label}
          </a>
        ))}
      </nav>
      <div className="header-actions">
        {AVAILABLE.length > 1 && (
          <select
            className="chain-select"
            value={app.chainId}
            onChange={(e) => app.setChainId(Number(e.target.value))}
            aria-label={zh ? '选择网络' : 'Network'}
          >
            {AVAILABLE.map((n) => (
              <option key={n.id} value={n.id}>
                {n.name}
              </option>
            ))}
          </select>
        )}
        {AVAILABLE.length === 1 && <span className={`chain-pill ${app.net.testnet ? 'is-test' : ''}`}>{app.net.name}</span>}
        <button className="lang" onClick={() => app.setLang(zh ? 'en' : 'zh')} aria-label={zh ? 'Switch to English' : '切换为中文'}>
          {zh ? 'EN' : '中文'}
        </button>
        {!w.account ? (
          <button className="btn btn-primary btn-sm" onClick={app.openConnect}>
            {zh ? '连接钱包' : 'Connect'}
          </button>
        ) : (
          <div className="wallet">
            <button className={`btn btn-ghost btn-sm ${wrongChain ? 'is-warn' : ''}`} onClick={() => setMenu((m) => !m)}>
              {w.active?.info?.icon && <img src={w.active.info.icon} alt="" />}
              {wrongChain ? (zh ? '网络不对' : 'Wrong network') : shortAddr(w.account)}
            </button>
            {menu && (
              <div className="wallet-menu" onMouseLeave={() => setMenu(false)}>
                {wrongChain && (
                  <button onClick={() => w.switchChain(app.chainId).catch(() => {})}>
                    {zh ? `切换到 ${app.net.name}` : `Switch to ${app.net.name}`}
                  </button>
                )}
                <button onClick={() => navigator.clipboard?.writeText(w.account)}>{zh ? '复制地址' : 'Copy address'}</button>
                <button
                  onClick={() => {
                    w.disconnect();
                    setMenu(false);
                  }}
                >
                  {zh ? '断开连接' : 'Disconnect'}
                </button>
              </div>
            )}
          </div>
        )}
      </div>
    </header>
  );
}
