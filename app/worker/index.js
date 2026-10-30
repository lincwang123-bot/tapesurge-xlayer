// TapeSurge 应用的 Cloudflare Worker：页面文件由 assets 直接返回，只有 /api/* 走这里。
// 功能：@TapeSurgeBot 的对话（Telegram webhook）、钱包签名绑定、给 VPS 提醒发送器读绑定名单。
// 设计见 ../Telegram提醒-设计.md。密钥（wrangler secret）：TELEGRAM_BOT_TOKEN、TELEGRAM_WEBHOOK_SECRET、NOTIFIER_SECRET。
import { verifyMessage } from 'viem';
import { bindMessage, CODE_RE } from '../src/lib/bindMessage.js';

const CODE_TTL = 15 * 60;
const MAX_ADDR_PER_CHAT = 5;
const MAX_CHAT_PER_ADDR = 3;
const CODE_CHARS = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

// 提醒类别（和 VPS 发送器一致）；全部默认打开
export const CATEGORIES = ['prize', 'eject', 'claim', 'trade', 'vote', 'result', 'ask', 'deadline', 'refund'];
const CAT_NAME = {
  zh: { prize: '月局中奖', eject: '标准局出局到账', claim: '待领取汇总', trade: '持仓成交', vote: '集体清算投票', result: '投票结果', ask: '卖单失效', deadline: '领取期限', refund: '招募失败退款' },
  en: { prize: 'Prizes', eject: 'Ejection payout', claim: 'Claimable digest', trade: 'Position trades', vote: 'Liquidation votes', result: 'Vote results', ask: 'Lapsed asks', deadline: 'Claim deadlines', refund: 'Recruitment refunds' },
};

const T = {
  zh: {
    welcome: (url) => `欢迎使用 TapeSurge 提醒。\n\n点下面的按钮打开 dApp，用钱包签一个名就能绑定（不花 gas，不是交易）。链接 15 分钟内有效。\n\n我永远不会向你索要私钥、助记词或让你转账。`,
    bindBtn: '绑定钱包',
    bound: (a) => `✅ 已绑定 ${a}\n以后有中奖、待领取、投票等事项会提醒你。发 /settings 可以关掉不想要的提醒，/unbind 解绑。`,
    status: (list) => (list.length ? `已绑定的地址：\n${list.join('\n')}\n\n待领取金额请在 dApp 的"我的"页面查看。` : '还没有绑定地址。发 /start 开始绑定。'),
    unbindAsk: '选择要解绑的地址：',
    unbound: (a) => `已解绑 ${a}`,
    nothing: '还没有绑定地址。',
    settings: '点按钮开关提醒（✅ 开 / ⬜ 关）：',
    lang: '语言：中文（点切换为 English）',
    help: '/start 绑定钱包\n/status 查看已绑定的地址\n/settings 提醒开关和语言\n/unbind 解绑\n\n我永远不会向你索要私钥、助记词或让你转账。',
    privateOnly: '请在和我的私聊里使用。',
  },
  en: {
    welcome: () => `Welcome to TapeSurge reminders.\n\nTap the button to open the dApp and sign a message with your wallet (no gas, not a transaction). The link is valid for 15 minutes.\n\nI will never ask for your private key, seed phrase or a transfer.`,
    bindBtn: 'Bind wallet',
    bound: (a) => `✅ Bound ${a}\nYou'll get reminders for prizes, claimable funds, votes and more. /settings to mute some, /unbind to remove.`,
    status: (list) => (list.length ? `Bound addresses:\n${list.join('\n')}\n\nSee claimable amounts on the dApp's "My" page.` : 'No address bound yet. Send /start to bind.'),
    unbindAsk: 'Choose an address to unbind:',
    unbound: (a) => `Unbound ${a}`,
    nothing: 'No address bound yet.',
    settings: 'Tap to toggle reminders (✅ on / ⬜ off):',
    lang: 'Language: English (tap for 中文)',
    help: '/start bind a wallet\n/status bound addresses\n/settings reminders and language\n/unbind remove an address\n\nI will never ask for your private key, seed phrase or a transfer.',
    privateOnly: 'Please use me in a private chat.',
  },
};

const short = (a) => `${a.slice(0, 6)}…${a.slice(-4)}`;
const now = () => Math.floor(Date.now() / 1000);
const json = (data, status = 200) => new Response(JSON.stringify(data), { status, headers: { 'content-type': 'application/json; charset=utf-8' } });

function newCode() {
  const b = crypto.getRandomValues(new Uint8Array(8));
  return [...b].map((x) => CODE_CHARS[x % CODE_CHARS.length]).join('');
}

async function tg(env, method, body) {
  // 本地测试时可以把 TELEGRAM_API_BASE 指到假的 Telegram 服务
  const res = await fetch(`${env.TELEGRAM_API_BASE ?? 'https://api.telegram.org'}/bot${env.TELEGRAM_BOT_TOKEN}/${method}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  return res.json().catch(() => ({ ok: false }));
}

async function chatRow(env, chatId, tgLang) {
  let row = await env.DB.prepare('SELECT * FROM chats WHERE chat_id = ?').bind(chatId).first();
  if (!row) {
    const lang = String(tgLang || '').startsWith('zh') ? 'zh' : 'en';
    await env.DB.prepare('INSERT INTO chats (chat_id, lang, off, created_at) VALUES (?, ?, ?, ?)').bind(chatId, lang, '', now()).run();
    row = { chat_id: chatId, lang, off: '' };
  }
  return row;
}

function settingsKeyboard(row) {
  const off = new Set(row.off.split(',').filter(Boolean));
  const names = CAT_NAME[row.lang];
  const rows = CATEGORIES.map((c) => [{ text: `${off.has(c) ? '⬜' : '✅'} ${names[c]}`, callback_data: `t:${c}` }]);
  rows.push([{ text: T[row.lang].lang, callback_data: 'lang' }]);
  return { inline_keyboard: rows };
}

async function addresses(env, chatId) {
  const { results } = await env.DB.prepare('SELECT address FROM bindings WHERE chat_id = ? ORDER BY created_at').bind(chatId).all();
  return results.map((r) => r.address);
}

// ------------------------------------------------------------ Telegram webhook

async function onUpdate(env, u) {
  if (u.callback_query) return onCallback(env, u.callback_query);
  const m = u.message;
  if (!m?.text || !m.chat) return;
  const chatId = String(m.chat.id);
  if (m.chat.type !== 'private') return; // 只做私聊；已经在 BotFather 里禁止拉进群
  const row = await chatRow(env, chatId, m.from?.language_code);
  const t = T[row.lang];
  const cmd = m.text.trim().split(/\s+/)[0].split('@')[0].toLowerCase();

  if (cmd === '/start' || cmd === '/bind') {
    const code = newCode();
    await env.DB.prepare('DELETE FROM codes WHERE chat_id = ? OR expires_at < ?').bind(chatId, now()).run();
    await env.DB.prepare('INSERT INTO codes (code, chat_id, expires_at) VALUES (?, ?, ?)').bind(code, chatId, now() + CODE_TTL).run();
    const url = `${env.APP_URL}/#/bind?code=${code}`;
    return tg(env, 'sendMessage', { chat_id: chatId, text: t.welcome(url), reply_markup: { inline_keyboard: [[{ text: t.bindBtn, url }]] } });
  }
  if (cmd === '/status') {
    const list = (await addresses(env, chatId)).map(short);
    return tg(env, 'sendMessage', { chat_id: chatId, text: t.status(list) });
  }
  if (cmd === '/unbind') {
    const list = await addresses(env, chatId);
    if (!list.length) return tg(env, 'sendMessage', { chat_id: chatId, text: t.nothing });
    return tg(env, 'sendMessage', { chat_id: chatId, text: t.unbindAsk, reply_markup: { inline_keyboard: list.map((a) => [{ text: short(a), callback_data: `u:${a}` }]) } });
  }
  if (cmd === '/settings') return tg(env, 'sendMessage', { chat_id: chatId, text: t.settings, reply_markup: settingsKeyboard(row) });
  return tg(env, 'sendMessage', { chat_id: chatId, text: t.help });
}

async function onCallback(env, q) {
  const chatId = String(q.message?.chat?.id ?? '');
  if (!chatId) return;
  const row = await chatRow(env, chatId, q.from?.language_code);
  const data = String(q.data || '');
  if (data.startsWith('u:')) {
    const a = data.slice(2).toLowerCase();
    await env.DB.prepare('DELETE FROM bindings WHERE chat_id = ? AND address = ?').bind(chatId, a).run();
    await tg(env, 'answerCallbackQuery', { callback_query_id: q.id });
    return tg(env, 'editMessageText', { chat_id: chatId, message_id: q.message.message_id, text: T[row.lang].unbound(short(a)) });
  }
  if (data.startsWith('t:') || data === 'lang') {
    if (data === 'lang') row.lang = row.lang === 'zh' ? 'en' : 'zh';
    else {
      const c = data.slice(2);
      if (!CATEGORIES.includes(c)) return;
      const off = new Set(row.off.split(',').filter(Boolean));
      off.has(c) ? off.delete(c) : off.add(c);
      row.off = [...off].join(',');
    }
    await env.DB.prepare('UPDATE chats SET lang = ?, off = ? WHERE chat_id = ?').bind(row.lang, row.off, chatId).run();
    await tg(env, 'answerCallbackQuery', { callback_query_id: q.id });
    return tg(env, 'editMessageText', { chat_id: chatId, message_id: q.message.message_id, text: T[row.lang].settings, reply_markup: settingsKeyboard(row) });
  }
}

// ------------------------------------------------------------ dApp 提交签名

async function onBind(env, req) {
  let body;
  try {
    body = await req.json();
  } catch {
    return json({ error: 'bad_request' }, 400);
  }
  const { address, code, signature } = body ?? {};
  if (!/^0x[0-9a-fA-F]{40}$/.test(address ?? '') || !CODE_RE.test(code ?? '') || !/^0x[0-9a-fA-F]{130}$/.test(signature ?? '')) return json({ error: 'bad_request' }, 400);
  const c = await env.DB.prepare('SELECT * FROM codes WHERE code = ?').bind(code).first();
  if (!c || c.expires_at < now()) return json({ error: 'code_expired' }, 400);
  // 只认普通钱包（EOA）的签名；合约钱包（如 Safe）暂不支持
  const ok = await verifyMessage({ address, message: bindMessage(address, code), signature }).catch(() => false);
  if (!ok) return json({ error: 'bad_signature' }, 400);
  const a = address.toLowerCase();
  const nChat = (await env.DB.prepare('SELECT COUNT(*) AS n FROM bindings WHERE chat_id = ?').bind(c.chat_id).first()).n;
  const nAddr = (await env.DB.prepare('SELECT COUNT(*) AS n FROM bindings WHERE address = ?').bind(a).first()).n;
  const exists = await env.DB.prepare('SELECT 1 FROM bindings WHERE chat_id = ? AND address = ?').bind(c.chat_id, a).first();
  if (!exists && nChat >= MAX_ADDR_PER_CHAT) return json({ error: 'too_many_addresses' }, 400);
  if (!exists && nAddr >= MAX_CHAT_PER_ADDR) return json({ error: 'too_many_chats' }, 400);
  await env.DB.batch([
    env.DB.prepare('INSERT OR IGNORE INTO bindings (chat_id, address, created_at) VALUES (?, ?, ?)').bind(c.chat_id, a, now()),
    env.DB.prepare('DELETE FROM codes WHERE code = ?').bind(code),
  ]);
  const row = await chatRow(env, c.chat_id);
  await tg(env, 'sendMessage', { chat_id: c.chat_id, text: T[row.lang].bound(short(address)) });
  return json({ ok: true });
}

// ------------------------------------------------------------ VPS 发送器读名单

async function onSubscriptions(env, req) {
  const auth = req.headers.get('authorization') || '';
  if (!env.NOTIFIER_SECRET || auth !== `Bearer ${env.NOTIFIER_SECRET}`) return json({ error: 'unauthorized' }, 401);
  const { results } = await env.DB.prepare(
    'SELECT b.chat_id, b.address, c.lang, c.off FROM bindings b JOIN chats c ON c.chat_id = b.chat_id',
  ).all();
  return json({ subscriptions: results });
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    if (url.pathname === '/api/telegram' && req.method === 'POST') {
      // Telegram 每次推送都带上我们设置 webhook 时给的密钥，防止别人伪造
      if (req.headers.get('x-telegram-bot-api-secret-token') !== env.TELEGRAM_WEBHOOK_SECRET) return new Response('forbidden', { status: 403 });
      const u = await req.json().catch(() => null);
      if (u) await onUpdate(env, u).catch((e) => console.error('update failed', e?.message));
      return new Response('ok');
    }
    if (url.pathname === '/api/bind' && req.method === 'POST') return onBind(env, req);
    if (url.pathname === '/api/subscriptions' && req.method === 'GET') return onSubscriptions(env, req);
    if (url.pathname.startsWith('/api/')) return json({ error: 'not_found' }, 404);
    return env.ASSETS.fetch(req);
  },
};
