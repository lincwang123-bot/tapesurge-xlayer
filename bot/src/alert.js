// 报警：Telegram 和 / 或任意 webhook（POST JSON）。同一个 key 一小时内只报一次。都没配置时只写日志。
import * as log from './log.js';

export class Alert {
  constructor(cfg, state) {
    this.cfg = cfg;
    this.state = state;
  }

  async send(key, text, { everySec = 3600 } = {}) {
    const alerts = this.state.data.alerts;
    const now = Date.now() / 1000;
    if (alerts[key] && now - alerts[key] < everySec) return;
    alerts[key] = now;
    const msg = `[TapeSurge ${this.cfg.chainName}] ${text}`;
    log.warn(`ALERT ${key}`, { text });
    const { telegramToken, telegramChat, webhook } = this.cfg.alert;
    const jobs = [];
    if (telegramToken && telegramChat) {
      jobs.push(
        fetch(`https://api.telegram.org/bot${telegramToken}/sendMessage`, {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ chat_id: telegramChat, text: msg, disable_web_page_preview: true }),
        }),
      );
    }
    if (webhook) {
      jobs.push(fetch(webhook, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ key, text: msg }) }));
    }
    const res = await Promise.allSettled(jobs);
    for (const r of res) if (r.status === 'rejected') log.error('alert delivery failed', { reason: String(r.reason?.message ?? r.reason) });
  }
}
