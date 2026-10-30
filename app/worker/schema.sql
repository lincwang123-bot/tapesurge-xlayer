-- Telegram 提醒（Cloudflare D1）。只存：Telegram 会话号、语言和提醒开关、绑定的钱包地址。没有私钥，也不存签名。
CREATE TABLE IF NOT EXISTS chats (
  chat_id    TEXT PRIMARY KEY,
  lang       TEXT NOT NULL DEFAULT 'zh',   -- 'zh' 或 'en'，按 Telegram 语言自动选，可在 /settings 改
  off        TEXT NOT NULL DEFAULT '',     -- 关掉的提醒类别，逗号分隔
  created_at INTEGER NOT NULL
);

-- 一次性验证码：/start 时生成，15 分钟内有效，用一次就删
CREATE TABLE IF NOT EXISTS codes (
  code       TEXT PRIMARY KEY,
  chat_id    TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS bindings (
  chat_id    TEXT NOT NULL,
  address    TEXT NOT NULL,                -- 小写
  created_at INTEGER NOT NULL,
  PRIMARY KEY (chat_id, address)
);
CREATE INDEX IF NOT EXISTS bindings_by_address ON bindings (address);
