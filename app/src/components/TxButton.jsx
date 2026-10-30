// 发交易的按钮：显示"模拟中 / 请在钱包确认 / 等待上链"，失败时在按钮下面显示原因。
import { useState } from 'react';
import { useApp } from '../App.jsx';
import { explain, sendTx } from '../lib/tx.js';
import { explorerTx } from '../lib/chains.js';

export function useTx() {
  const app = useApp();
  const [stage, setStage] = useState(null);
  const [hash, setHash] = useState(null);
  const [error, setError] = useState(null);

  async function run(steps, { onDone } = {}) {
    setError(null);
    setHash(null);
    try {
      const list = Array.isArray(steps) ? steps : [steps];
      let receipt;
      for (const step of list) {
        if (step.skip && (await step.skip())) continue;
        receipt = await sendTx({
          publicClient: app.client,
          walletClient: app.wallet.walletClient,
          // X Layer 节点状态会落后几个区块：上链后等节点追上；上一步刚上链时，这一步的模拟失败先重试几次
          laggy: app.xlayer,
          retries: app.xlayer && receipt ? 4 : 0,
          ...step,
          onStage: (s, h) => {
            setStage(step.label ? `${s}:${step.label}` : s);
            if (h) setHash(h);
          },
        });
        await step.after?.(receipt);
      }
      setStage('done');
      app.bump();
      onDone?.(receipt);
      return receipt;
    } catch (e) {
      setStage(null);
      setError(explain(e, app.lang));
      return null;
    }
  }
  return { stage, hash, error, run, busy: stage && stage !== 'done', reset: () => (setStage(null), setError(null)) };
}

export function TxStatus({ tx }) {
  const { lang, chainId } = useApp();
  const zh = lang === 'zh';
  if (tx.error) return <p className="tx-error">{tx.error}</p>;
  if (!tx.stage) return null;
  const [s, label] = tx.stage.split(':');
  const text = {
    simulating: zh ? '正在检查…' : 'Checking…',
    signing: zh ? '请在钱包里确认' : 'Confirm in your wallet',
    pending: zh ? '等待上链…' : 'Waiting for confirmation…',
    done: zh ? '已完成' : 'Done',
  }[s];
  return (
    <p className={`tx-status tx-${s}`}>
      {label ? `${label} · ` : ''}
      {text}
      {tx.hash && (
        <>
          {' '}
          <a href={explorerTx(chainId, tx.hash)} target="_blank" rel="noreferrer">
            {zh ? '查看交易' : 'View tx'}
          </a>
        </>
      )}
    </p>
  );
}

/** 需要钱包的按钮：没连钱包时变成"连接钱包"，网络不对时变成"切换网络" */
export function WalletGate({ children }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  if (!app.wallet.account) {
    return (
      <button className="btn btn-primary" onClick={() => app.openConnect()}>
        {zh ? '连接钱包' : 'Connect wallet'}
      </button>
    );
  }
  if (app.wallet.chainId !== app.chainId) {
    return (
      <button className="btn btn-primary" onClick={() => app.wallet.switchChain(app.chainId).catch(() => {})}>
        {zh ? `切换到 ${app.net.name}` : `Switch to ${app.net.name}`}
      </button>
    );
  }
  return children;
}
