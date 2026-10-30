import { useEffect } from 'react';
import { useApp } from '../App.jsx';

export default function ConnectModal({ onClose }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const w = app.wallet;

  useEffect(() => {
    if (w.account) onClose();
  }, [w.account, onClose]);

  useEffect(() => {
    const onKey = (e) => e.key === 'Escape' && onClose();
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose]);

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" role="dialog" aria-modal="true" onClick={(e) => e.stopPropagation()}>
        <div className="modal-head">
          <h2>{zh ? '连接钱包' : 'Connect a wallet'}</h2>
          <button className="icon-btn" onClick={onClose} aria-label={zh ? '关闭' : 'Close'}>
            ×
          </button>
        </div>
        {w.providers.length === 0 ? (
          <div className="modal-empty">
            <p>{zh ? '这个浏览器里没有检测到钱包。' : 'No browser wallet detected.'}</p>
            <p className="muted">
              {zh
                ? '安装一个支持 BNB Chain / X Layer 的浏览器钱包（例如 MetaMask、OKX Wallet、Binance Wallet）后刷新页面；手机上请在钱包 App 的内置浏览器里打开本页。'
                : 'Install a browser wallet that supports BNB Chain / X Layer (e.g. MetaMask, OKX Wallet, Binance Wallet) and reload. On mobile, open this page in your wallet app’s browser.'}
            </p>
          </div>
        ) : (
          <ul className="wallet-list">
            {w.providers.map((p) => (
              <li key={p.info.uuid}>
                <button onClick={() => w.connect(p)}>
                  {p.info.icon ? <img src={p.info.icon} alt="" /> : <span className="wallet-dot" />}
                  <span>{p.info.name}</span>
                </button>
              </li>
            ))}
          </ul>
        )}
        {w.error && (
          <p className="tx-error">
            {w.error === 'rejected' ? (zh ? '你在钱包里取消了连接' : 'You rejected the connection') : w.error}
          </p>
        )}
        <p className="muted small">
          {zh
            ? '连接只会读取你的地址。每一笔交易都会先在钱包里显示，由你确认后才发出。'
            : 'Connecting only shares your address. Every transaction is shown in your wallet for you to approve.'}
        </p>
      </div>
    </div>
  );
}
