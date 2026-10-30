// 金额、时间、地址的显示格式。BEM 是 8 位小数，BNB 是 18 位。
import { formatUnits, parseUnits } from 'viem';

export const BEM_DECIMALS = 8;

function trim(str, maxDecimals) {
  const [i, d = ''] = str.split('.');
  const cut = d.slice(0, maxDecimals).replace(/0+$/, '');
  const int = i.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return cut ? `${int}.${cut}` : int;
}

export const fmtBEM = (v, max = 4) => (v == null ? '—' : trim(formatUnits(BigInt(v), BEM_DECIMALS), max));
export const fmtBNB = (v, max = 5) => (v == null ? '—' : trim(formatUnits(BigInt(v), 18), max));
export const fmtInt = (v) => (v == null ? '—' : trim(String(v), 0));

/** 用户输入的 BEM 数量 → 最小单位；格式不对返回 null */
export function parseBEM(text) {
  const s = String(text ?? '').trim().replace(/,/g, '');
  if (!/^\d+(\.\d{0,8})?$/.test(s)) return null;
  try {
    return parseUnits(s, BEM_DECIMALS);
  } catch {
    return null;
  }
}

export const shortAddr = (a) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : '');

export function pct(num, den, digits = 1) {
  if (!den || den === 0n) return '0';
  const scaled = (BigInt(num) * 10n ** BigInt(digits + 2)) / BigInt(den);
  const s = scaled.toString().padStart(digits + 1, '0');
  return digits ? `${s.slice(0, -digits)}.${s.slice(-digits)}` : s;
}

/** 秒数 → "2 天 3 小时" / "2d 3h"，只保留最大的两个单位 */
export function fmtDuration(seconds, lang = 'zh') {
  let s = Math.max(0, Math.floor(Number(seconds)));
  const units =
    lang === 'zh'
      ? [['天', 86400], ['小时', 3600], ['分', 60], ['秒', 1]]
      : [['d', 86400], ['h', 3600], ['m', 60], ['s', 1]];
  const parts = [];
  for (const [name, size] of units) {
    if (s >= size || (parts.length === 0 && size === 1)) {
      const n = Math.floor(s / size);
      s -= n * size;
      parts.push(lang === 'zh' ? `${n} ${name}` : `${n}${name}`);
    }
    if (parts.length === 2) break;
  }
  return parts.join(' ');
}

export function fmtTime(ts, lang = 'zh') {
  if (!ts || ts === 0n) return '—';
  const d = new Date(Number(ts) * 1000);
  return d.toLocaleString(lang === 'zh' ? 'zh-CN' : 'en-GB', {
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
}
