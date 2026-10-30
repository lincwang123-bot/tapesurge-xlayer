// 机器人的本地状态（state/<链 ID>.json）：哪些主板已经结束、上次各项检查的时间、报警去重。
// 丢了也没关系：重新扫一遍链上就能恢复，只是会多做几次模拟。
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';

export class State {
  constructor(file) {
    this.file = file;
    this.data = { boards: {}, timers: {}, alerts: {} };
    if (existsSync(file)) {
      try {
        this.data = { ...this.data, ...JSON.parse(readFileSync(file, 'utf8')) };
      } catch {
        /* 文件损坏就从头开始 */
      }
    }
  }

  board(address) {
    const k = address.toLowerCase();
    this.data.boards[k] ??= {};
    return this.data.boards[k];
  }

  /** 距离上次执行 key 是否已经超过 everySec 秒；是就记下现在的时间并返回 true */
  due(key, everySec, now = Date.now() / 1000) {
    const last = this.data.timers[key] ?? 0;
    if (now - last < everySec) return false;
    this.data.timers[key] = now;
    return true;
  }

  save() {
    mkdirSync(dirname(this.file), { recursive: true });
    const tmp = `${this.file}.tmp`;
    writeFileSync(tmp, JSON.stringify(this.data, (_, v) => (typeof v === 'bigint' ? v.toString() : v), 2));
    renameSync(tmp, this.file);
  }
}
