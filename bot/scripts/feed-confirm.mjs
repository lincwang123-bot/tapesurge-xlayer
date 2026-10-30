// 确认矿机市场价的大幅变动（规则 6.36）：机器人发现 Firsto 日产能价 24 小时内累计变动超过 15% 时会暂停自动报价
// 并发 Telegram 提醒。先到 Firsto 核对行情是真实的，再在服务器上运行：
//   cd ~/tapesurge-bot && node scripts/feed-confirm.mjs 56
// 机器人下一次读行情时把 24 小时基准重置为当时的价格，然后照常报价（每次仍最多 5%，离得远就分步追价）。
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const chainId = Number(process.argv[2] ?? process.env.CHAIN_ID ?? 56);
const file = resolve(ROOT, process.env.FEED_CONFIRM_FILE ?? `state/${chainId}.feed-confirm.json`);
const confirmedAt = Math.floor(Date.now() / 1000);
mkdirSync(dirname(file), { recursive: true });
writeFileSync(file, JSON.stringify({ confirmedAt, note: 'owner confirmed the market move' }, null, 2) + '\n');
console.log(`已确认（${new Date(confirmedAt * 1000).toISOString()}），写入 ${file}。机器人下一次读行情时恢复报价。`);
