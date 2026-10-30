#!/usr/bin/env bash
# Telegram 提醒上线：一次性设置（在你自己的 Mac 上运行，先 npx wrangler login 登录 Cloudflare）。
#   cd dapp && bash worker/setup.sh
# 做的事：建 D1 数据库和表 → 生成两个随机口令 → 把 @TapeSurgeBot 令牌和口令存进 Cloudflare（不显示）→ 构建并发布
# → 告诉 Telegram 把消息推到 app.tapesurge.com/api/telegram → 把令牌和口令写进 VPS，启动提醒发送器。
# 令牌只在你的终端里输入，不会出现在屏幕上，也不会经过任何第三方。
set -euo pipefail
cd "$(dirname "$0")/.."
APP_URL="${APP_URL:-https://app.tapesurge.com}"
VPS="${VPS:-your-server}"

# 电脑开了系统代理（例如 Clash）而终端没设代理时，让 wrangler 和 curl 也走这个代理
if [ -z "${HTTPS_PROXY:-}${https_proxy:-}" ] && command -v scutil >/dev/null; then
  P=$(scutil --proxy | awk '/HTTPSProxy/ {h=$3} /HTTPSPort/ {p=$3} /HTTPSEnable : 1/ {e=1} END {if (e && h && p) print "http://" h ":" p}')
  if [ -n "$P" ]; then export HTTPS_PROXY="$P" HTTP_PROXY="$P" NODE_USE_ENV_PROXY=1 NODE_NO_WARNINGS=1; echo "（检测到系统代理 ${P}，本次运行走代理）"; fi
fi

echo "1/6 检查 Cloudflare 登录"
WHO=$(npx wrangler whoami 2>&1 || true)
echo "$WHO" | grep -q "You are logged in" || { echo "还没登录或连不上 Cloudflare：先运行 npx wrangler login；如果已经登录，检查网络 / 代理"; echo "$WHO" | grep -iE "error|timeout" | head -3; exit 1; }
echo "   已登录"

echo "2/6 数据库"
if grep -q REPLACE_WITH_D1_DATABASE_ID wrangler.jsonc; then
  OUT=$(npx wrangler d1 create tapesurge-reminders 2>&1 || true)
  ID=$(echo "$OUT" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
  [ -z "$ID" ] && ID=$(npx wrangler d1 list --json | python3 -c "import json,sys;print([d['uuid'] for d in json.load(sys.stdin) if d['name']=='tapesurge-reminders'][0])")
  sed -i '' "s/REPLACE_WITH_D1_DATABASE_ID/$ID/" wrangler.jsonc
  echo "   数据库 ID：${ID}（已写进 wrangler.jsonc）"
fi
npx wrangler d1 execute tapesurge-reminders --remote --file worker/schema.sql >/dev/null
echo "   表已建好"

echo "3/6 构建并发布到 ${APP_URL}（先发布，之后才能往这个 Worker 存令牌）"
npm run build >/dev/null
npx wrangler deploy >/dev/null
echo "   已发布"

echo "4/6 令牌和口令"
read -r -s -p "   粘贴 @TapeSurgeBot 的令牌后回车（屏幕不显示）：" TOKEN; echo
TOKEN="$(printf %s "$TOKEN" | tr -d '[:space:]')"
[[ "$TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]] || { echo "   令牌格式不对"; exit 1; }
ME=$(curl -s "https://api.telegram.org/bot$TOKEN/getMe")
echo "$ME" | grep -q '"username":"TapeSurgeBot"' || { echo "   这个令牌不是 @TapeSurgeBot 的"; exit 1; }
HOOK_SECRET=$(openssl rand -hex 24)
NOTIFIER_SECRET=$(openssl rand -hex 24)
printf %s "$TOKEN" | npx wrangler secret put TELEGRAM_BOT_TOKEN >/dev/null
printf %s "$HOOK_SECRET" | npx wrangler secret put TELEGRAM_WEBHOOK_SECRET >/dev/null
printf %s "$NOTIFIER_SECRET" | npx wrangler secret put NOTIFIER_SECRET >/dev/null
echo "   已存进 Cloudflare"

echo "5/6 设置 Telegram 推送地址"
curl -s "https://api.telegram.org/bot$TOKEN/setWebhook" \
  --data-urlencode "url=$APP_URL/api/telegram" \
  --data-urlencode "secret_token=$HOOK_SECRET" \
  --data-urlencode 'allowed_updates=["message","callback_query"]' | grep -q '"ok":true' && echo "   已设置" || { echo "   设置失败"; exit 1; }

echo "6/6 写入 VPS（${VPS}）并启动提醒发送器"
printf 'REMINDER_BOT_TOKEN=%s\nNOTIFIER_SECRET=%s\n' "$TOKEN" "$NOTIFIER_SECRET" |
  ssh "$VPS" 'umask 077; cat > ~/tapesurge-bot/secrets/reminder.env; chmod 600 ~/tapesurge-bot/secrets/reminder.env; systemctl --user daemon-reload; systemctl --user enable --now tapesurge-notify-testnet.service >/dev/null 2>&1; sleep 5; echo "   发送器状态：$(systemctl --user is-active tapesurge-notify-testnet.service)"'
unset TOKEN HOOK_SECRET NOTIFIER_SECRET

echo
echo "完成。在 Telegram 打开 @TapeSurgeBot，点"开始"，按提示绑定你的钱包试一下。"
