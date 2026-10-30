// Telegram 提醒绑定：#/bind?code=XXXXXXXX。验证码由 @TapeSurgeBot 在 /start 时发出，15 分钟内有效。
// 用户连接钱包、签一段文字（不是交易、不花 gas），dApp 把"地址 + 验证码 + 签名"交给 /api/bind，后端核对后完成绑定。
import { useState } from 'react';
import { useApp } from '../App.jsx';
import { bindMessage, CODE_RE } from '../lib/bindMessage.js';
import { WalletGate } from './TxButton.jsx';

export const BOT_URL = 'https://t.me/TapeSurgeBot';
const API = import.meta.env.VITE_API_BASE ?? '';

const ERR = {
  code_expired: ['验证码已过期或已用过。回到 @TapeSurgeBot 重新发 /start 拿新链接。', 'The code expired or was used. Send /start to @TapeSurgeBot again.'],
  bad_signature: ['签名核对没通过。请用要绑定的那个钱包签名。', 'Signature check failed. Sign with the wallet you want to bind.'],
  too_many_addresses: ['这个 Telegram 已经绑了 5 个地址，先在机器人里发 /unbind 解绑一个。', 'This Telegram already has 5 addresses. /unbind one first.'],
  too_many_chats: ['这个地址已经绑到 3 个 Telegram 账号了，先在其中一个里解绑。', 'This address is already bound to 3 Telegram accounts.'],
  bad_request: ['链接不完整，请回到机器人重新打开。', 'Broken link; open it again from the bot.'],
};

export default function BindPage({ code }) {
  const app = useApp();
  const zh = app.lang === 'zh';
  const [state, setState] = useState('idle'); // idle | signing | sending | done
  const [err, setErr] = useState('');
  const valid = CODE_RE.test(code ?? '');
  const account = app.wallet.account;

  async function bind() {
    setErr('');
    try {
      setState('signing');
      const signature = await app.wallet.walletClient.signMessage({ account, message: bindMessage(account, code) });
      setState('sending');
      const res = await fetch(`${API}/api/bind`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ address: account, code, signature }),
      });
      const j = await res.json().catch(() => ({}));
      if (!res.ok || !j.ok) {
        const m = ERR[j.error];
        throw new Error(m ? m[zh ? 0 : 1] : zh ? '绑定失败，请稍后再试。' : 'Binding failed; try again later.');
      }
      setState('done');
    } catch (e) {
      setState('idle');
      const rejected = /reject|denied|cancel/i.test(e?.message ?? '');
      setErr(rejected ? (zh ? '你取消了签名。' : 'Signature cancelled.') : e.message);
    }
  }

  return (
    <section className="panel bind-page">
      <div className="panel-head">
        <h2>{zh ? '绑定 Telegram 提醒' : 'Telegram reminders'}</h2>
        <p className="muted">
          {zh
            ? '绑定后，@TapeSurgeBot 会在你中奖、有待领取的款项、持仓成交、集体清算投票开始、领取期限快到时私聊提醒你。'
            : '@TapeSurgeBot will message you about prizes, claimable funds, position trades, liquidation votes and claim deadlines.'}
        </p>
      </div>
      {!valid && (
        <p className="tx-error">
          {zh ? '链接里没有有效的验证码。' : 'No valid code in this link. '}
          <a href={BOT_URL} target="_blank" rel="noreferrer">
            {zh ? '打开 @TapeSurgeBot，发 /start 拿绑定链接' : 'Open @TapeSurgeBot and send /start'}
          </a>
        </p>
      )}
      {valid && state !== 'done' && (
        <>
          <ol className="bind-steps small">
            <li>{zh ? '连接你要接收提醒的钱包。' : 'Connect the wallet you want reminders for.'}</li>
            <li>
              {zh
                ? '点"签名绑定"，钱包会弹出一段文字让你签名。这不是交易，不花 gas，也不会授权任何转账。'
                : 'Tap "Sign to bind". Your wallet shows a text to sign: not a transaction, no gas, no transfer authorised.'}
            </li>
          </ol>
          <WalletGate>
            <button className="btn btn-primary" disabled={state !== 'idle'} onClick={bind}>
              {state === 'signing' ? (zh ? '请在钱包里签名…' : 'Sign in your wallet…') : state === 'sending' ? (zh ? '提交中…' : 'Submitting…') : zh ? '签名绑定' : 'Sign to bind'}
            </button>
          </WalletGate>
          {account && <p className="muted small">{zh ? `将绑定：${account}` : `Binding: ${account}`}</p>}
          {err && <p className="tx-error">{err}</p>}
        </>
      )}
      {state === 'done' && (
        <p className="is-good">
          {zh ? '✅ 绑定成功。回到 Telegram，@TapeSurgeBot 已经给你发了确认消息。' : '✅ Bound. @TapeSurgeBot has sent you a confirmation in Telegram.'}
        </p>
      )}
      <p className="muted small">{zh ? '我们只保存你的地址和 Telegram 会话号，永远不会向你索要私钥或助记词。' : 'We store only your address and Telegram chat id, and will never ask for your keys.'}</p>
    </section>
  );
}

/** "我的"页面上的入口 */
export function BindEntry() {
  const app = useApp();
  const zh = app.lang === 'zh';
  return (
    <section className="panel">
      <div className="panel-head">
        <h2>{zh ? 'Telegram 提醒' : 'Telegram reminders'}</h2>
        <p className="muted">
          {zh ? '中奖、待领取、投票开始、领取期限快到时，由 @TapeSurgeBot 私聊提醒你。' : 'Get prize, claim, vote and deadline reminders from @TapeSurgeBot.'}
        </p>
      </div>
      <a className="btn btn-ghost" href={`${BOT_URL}?start=bind`} target="_blank" rel="noreferrer">
        {zh ? '打开 @TapeSurgeBot 绑定' : 'Open @TapeSurgeBot'}
      </a>
    </section>
  );
}
