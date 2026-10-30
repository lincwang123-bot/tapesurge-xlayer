// 日志：控制台 + 按行 JSON 写入 logs/<链 ID>.log。所有输出先过 redact()：私钥和 RPC 地址（initLog 传入）逐字替换，
// 任何 URL 的路径部分（常带 API key）都去掉。
import { appendFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

let file = null;
const secrets = [];

export function initLog(path, extraSecrets = []) {
  file = path;
  mkdirSync(dirname(path), { recursive: true });
  for (const s of extraSecrets) if (s) secrets.push(String(s));
}

export function redact(text) {
  let s = String(text);
  for (const secret of secrets) if (secret.length >= 8) s = s.split(secret).join('<redacted>');
  s = s.replace(/(https?:\/\/[^/\s]+)\/[^\s"']*/g, '$1/…'); // RPC 地址的路径里常带 API key
  return s;
}

const fmt = (v) => (typeof v === 'bigint' ? v.toString() : v);

export function log(level, msg, data) {
  const line = { t: new Date().toISOString(), level, msg, ...(data ?? {}) };
  const text = redact(JSON.stringify(line, (_, v) => fmt(v)));
  const human = redact(`${line.t.slice(11, 19)} ${level.padEnd(5)} ${msg}${data ? ' ' + JSON.stringify(data, (_, v) => fmt(v)) : ''}`);
  (level === 'error' ? console.error : console.log)(human);
  if (file) {
    try {
      appendFileSync(file, text + '\n');
    } catch {
      /* 写日志失败不影响运行 */
    }
  }
}

export const info = (m, d) => log('info', m, d);
export const warn = (m, d) => log('warn', m, d);
export const error = (m, d) => log('error', m, d);
export const action = (m, d) => log('tx', m, d);
