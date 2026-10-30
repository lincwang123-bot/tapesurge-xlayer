// Telegram 提醒绑定的签名文字：dApp 让钱包签它，Worker 用同一个函数重新拼出来核对签名。两边必须一字不差。
// 签名只证明"这个地址是我的"，不是交易，不花 gas，不授权任何转账。
import { getAddress } from 'viem';

export const CODE_RE = /^[A-HJ-NP-Z2-9]{8}$/; // 8 位验证码，去掉了容易看错的 0/O/1/I

export function bindMessage(address, code) {
  return [
    'TapeSurge 提醒绑定 / Reminder binding',
    `地址 Address: ${getAddress(address)}`,
    `验证码 Code: ${code}`,
    '这只是证明你拥有这个地址，不会授权任何转账。',
    'This only proves you own the address. It authorizes no transfer.',
  ].join('\n');
}
