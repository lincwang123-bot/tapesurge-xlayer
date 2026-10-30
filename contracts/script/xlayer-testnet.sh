#!/usr/bin/env bash
# TapeSurge X Layer 测试网分阶段执行脚本（月局；TapeOut / RIG / BEM / 交易池用 mock，随机数用真实的 drand evmnet 验签）
#
# 用法：bash script/xlayer-testnet.sh <阶段> [<阶段> ...] | from <阶段> | prep | all | status
#   prep：只做准备——deploy → feed → fund → mint → genesis（部署、转报一次 BSC 行情、给 PLAYERS 个玩家打测试 OKB、
#         铸通行证、开局；XHub.startGenesis 要求行情已经报过价，否则 FeedNotPosted），之后的开奖、
#         drand 交付、打款交给运营机器人。产出靠任何人调用 MockRig.claim(ids)（模拟在 BSC 金库上发起收取）。
#   按顺序执行（all = 全部按顺序跑完，中间自动等待链上时间）：
#     deploy          先按主网规则检查合约大小，再部署 mock 环境和 TapeSurge，地址写到 deployments/<链 ID>.json
#     feed            只读取 BSC 主网报价合约（BSC_PRICE_FEED）的买一 / 卖一和区块号，由运营地址转报到 X Layer 的 XMarketPriceFeed
#                     （清算计划价下限 = 买一 × 算力 × 95%；上线后由运营机器人每小时转报）
#     fund            部署者给 PLAYERS 个玩家各转一笔测试 OKB
#     mint            玩家各铸 5 颗创世 NAND、流片通行证，领 100 MockBEM
#     genesis         等到开局时间，开局（开出月局 #1）
#     join-month      玩家 0–24 加入月局 #1（招满即开局，进入准备期）
#     machines-month  部署者铸 mock RIG 卖给月局 #1（准备期内）
#     reward          领取首批回馈第 1 名（月局 #1；X Layer 默认铸造收入全给手续费 Safe，没有回馈桶，跳过）
#     month-yield     等月局 #1 准备期结束、进入挖矿，收取一次 RIG 产出
#     join-month2     等到月局 #1 挖矿结束前 1/15 个挖矿期，玩家 25–49 开出月局 #2
#     draw-m1         月局 #1 开奖：收取产出 → drawPrizes → 等 drand 锁定的那一轮产生 → 从 drand API 取签名 → fulfill → finalizePrizes
#     settle-m1       月局 #1：第 0 张凭证交接给月局 #2（按 #2 的收购价，不低于成本价），第 1 张挂成本价 120% 并成交
#     trade-m1        v2 持仓转让：玩家 0 把月局 #1 的持仓挂到持仓盘口，玩家 1 买走
#     settle-m1-auto  等 autoListDelay，其余凭证自动按成本价挂单并成交
#     fallback-month  等运营宽限期过去，由一位参与者代替运营地址给月局 #1 打款
#     join-month3     玩家 0–24（通行证已退回）开出下一块月局，确认月局 #1 的回馈资本滚了过去
#     buyback         回购一次（X Layer 默认不回购，跳过）
#     sweep           玩家把剩下的测试 OKB 退回部署者
#     report          打印部署者花费和各主板状态
#   status：随时查看各主板状态
#
# 环境变量：
#   KEY_SOURCE=env-file（默认）：在运行时读取 .env.xlayer-testnet（部署私钥 XLAYER_TESTNET_DEPLOYER_PK；可选
#                               XLAYER_TESTNET_RPC_URL、XLAYER_TESTNET_PLAYER_SEED），链 ID 必须是 1952。
#                               部署者必须是 EXPECT_DEPLOYER（默认 0xA4CAF27D2EF1eC0661a16a980c4E3C12B1808f12）。
#                               没有 XLAYER_TESTNET_PLAYER_SEED 时，玩家种子 = sha256("tapesurge-xlayer-testnet-players:" + 部署私钥)。
#   KEY_SOURCE=anvil：本地 anvil 演练（anvil 公开的开发账户和 BIP-39 测试助记词），RPC 默认 http://127.0.0.1:8545，链 ID 31337；
#                    等待时直接推进链上时间。drand 签名仍从 drand HTTP API 取，所以 anvil 要从过去的时间起步：
#                    anvil --timestamp $(( $(date +%s) - 3 * 86400 )) --block-base-fee-per-gas 20000000
#   RPC_URL / EXPECT_CHAIN_ID：覆盖默认值；TIME_DIVISOR（默认 720；48 = 1 天 → 30 分钟）；MOCK_FEE_DIVISOR（默认 100）；
#   BSC_RPC（默认 https://bsc-rpc.publicnode.com，只读）；BSC_PRICE_FEED（默认 BSC 主网 MarketPriceFeed）；
#   GENESIS_DELAY：开局等待秒数（默认 7 天 ÷ 比例）；PLAYERS：玩家人数（默认 50）；DRAND_API（默认 https://api.drand.sh）
#
# 安全：只接受链 ID 1952（X Layer 测试网）或 31337（本地）。私钥只放在本进程的环境变量里，由 forge 脚本内部签名，
#      不出现在命令行上；forge 的输出会把私钥、玩家种子和 RPC 地址遮掉。本脚本从不打印、复制 .env.xlayer-testnet。
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$PATH:$HOME/.foundry/bin"

KEY_SOURCE="${KEY_SOURCE:-env-file}"
if [ "$KEY_SOURCE" = "anvil" ]; then
  RPC="${RPC_URL:-http://127.0.0.1:8545}"
  CHAIN="${EXPECT_CHAIN_ID:-31337}"
  # anvil / Foundry 公开的开发账户 0（任何人都知道，只能用于本地）
  export XLAYER_TESTNET_DEPLOYER_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
  DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
  export TEST_MNEMONIC="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
elif [ "$KEY_SOURCE" = "env-file" ]; then
  [ -f ./.env.xlayer-testnet ] || { echo "missing .env.xlayer-testnet" >&2; exit 1; }
  set -a
  . ./.env.xlayer-testnet
  set +a
  [ -n "${XLAYER_TESTNET_DEPLOYER_PK:-}" ] || { echo "XLAYER_TESTNET_DEPLOYER_PK is not set in .env.xlayer-testnet" >&2; exit 1; }
  export XLAYER_TESTNET_DEPLOYER_PK
  RPC="${RPC_URL:-${XLAYER_TESTNET_RPC_URL:-https://testrpc.xlayer.tech}}"
  CHAIN="${EXPECT_CHAIN_ID:-1952}"
  DEPLOYER="${EXPECT_DEPLOYER:-0xA4CAF27D2EF1eC0661a16a980c4E3C12B1808f12}"
  export EXPECT_DEPLOYER="$DEPLOYER"
  if [ -n "${XLAYER_TESTNET_PLAYER_SEED:-}" ]; then
    export TEST_MNEMONIC="$XLAYER_TESTNET_PLAYER_SEED"
  else
    TEST_MNEMONIC="$(python3 -c 'import os, hashlib; print("0x" + hashlib.sha256(("tapesurge-xlayer-testnet-players:" + os.environ["XLAYER_TESTNET_DEPLOYER_PK"]).encode()).hexdigest())')"
    export TEST_MNEMONIC
  fi
else
  echo "unknown KEY_SOURCE: $KEY_SOURCE" >&2
  exit 1
fi
case "$CHAIN" in 1952 | 31337) ;; *)
  echo "refusing: only chain 1952 (X Layer testnet) or 31337 (local) is allowed" >&2
  exit 1
  ;;
esac
export RPC
export GAS_PRICE_WEI="${GAS_PRICE_WEI:-20000001}"
export TIME_DIVISOR="${TIME_DIVISOR:-720}" STAKE_MODE="${STAKE_MODE:-max}"
# v2：基金会和手续费地址必须不同。FOUNDATION 没给时不导出，由 DeployXLayerTestnet 用部署者派生的固定地址
export FEE_SAFE="${FEE_SAFE:-$DEPLOYER}"
if [ -n "${FOUNDATION:-}" ]; then export FOUNDATION; fi
DRAND_API="${DRAND_API:-https://api.drand.sh}"
PLAYERS="${PLAYERS:-50}"
HALF=25
DEP="deployments/$CHAIN.json"
LOG="deployments/$CHAIN-run.log"
START_FILE="deployments/$CHAIN-start-balance"

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------

# 遮掉私钥、玩家种子和 RPC 地址；去掉 forge 的进度行（交易由 print_txs 统一打印）
redact() {
  python3 -c '
import os, re, sys
keys = ("XLAYER_TESTNET_DEPLOYER_PK", "XLAYER_TESTNET_PLAYER_SEED", "TEST_MNEMONIC", "XLAYER_TESTNET_RPC_URL", "RPC")
secrets = [os.environ.get(k, "") for k in keys]
pk = os.environ.get("XLAYER_TESTNET_DEPLOYER_PK", "")
if pk:
    secrets.append(pk[2:] if pk.startswith("0x") else "0x" + pk)
secrets = sorted({s for s in secrets if len(s) > 8}, key=len, reverse=True)
skip = re.compile(r"^\s*$|^#+|^\s*\[\d|Waiting for receipts|Sensitive values|Transactions saved|ONCHAIN EXECUTION|Paid:|Hash:|Block:|Contract Address:|^\s*✅|Total Paid|Estimated|Setting up|SIMULATION COMPLETE|^=+$|Chain \d+|No files changed|Compiling|Compiler run|Solc ")
for line in sys.stdin:
    for s in secrets:
        line = line.replace(s, "<redacted>")
    if not skip.search(line):
        sys.stdout.write(line)
        sys.stdout.flush()
'
}

check_chain() {
  local id
  id="$(cast chain-id --rpc-url "$RPC")"
  if [ "$id" != "$CHAIN" ]; then
    echo "refusing: RPC chain id $id != expected $CHAIN" >&2
    exit 1
  fi
}

# 节点偶尔断连（tls handshake eof）：查询失败时重试，不能把空值交给 wait_until，否则等待循环会提前退出
chain_now() {
  local t i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    t="$(cast block latest -f timestamp --rpc-url "$RPC" 2>/dev/null || true)"
    case "$t" in '' | *[!0-9]*) sleep 5 ;; *)
      echo "$t"
      return 0
      ;;
    esac
  done
  echo "chain_now: RPC failed 12 times" >&2
  return 1
}
balance() { cast balance "$1" --rpc-url "$RPC"; }
addr() { python3 -c "import json,sys; print(json.load(open('$DEP'))[sys.argv[1]])" "$1"; }
num() { cast call "$@" --rpc-url "$RPC" | awk '{print $1}'; }
month_board() { num "$(addr monthFactory)" "boardByNumber(uint256)(address)" "$1"; }
recruiting_month() { num "$(addr monthFactory)" "recruitingBoard()(address)"; }

# 等到链上时间 ≥ $1。anvil 上直接推进时间；测试网上每 10 秒查一次
wait_until() {
  local target="$1" label="$2" now
  now="$(chain_now)"
  if [ "$now" -ge "$target" ]; then return 0; fi
  echo "-- waiting $((target - now))s for: $label"
  if [ "$KEY_SOURCE" = "anvil" ]; then
    cast rpc evm_setNextBlockTimestamp "$target" --rpc-url "$RPC" >/dev/null
    cast rpc evm_mine --rpc-url "$RPC" >/dev/null
  else
    while :; do
      now="$(chain_now)" || exit 1
      [ "$now" -ge "$target" ] && break
      sleep 10
    done
  fi
}

# 打印本阶段的全部交易哈希、gas 和手续费，并追加到 deployments/<链 ID>-run.log
print_txs() {
  local stage="$1" file="$2"
  if [ ! -f "$file" ]; then
    echo "   (no transactions)" | tee -a "$LOG"
    return 0
  fi
  python3 - "$stage" "$file" <<'PY' | tee -a "$LOG"
import json, sys
stage, path = sys.argv[1], sys.argv[2]
d = json.load(open(path))
rc = {r["transactionHash"]: r for r in d.get("receipts", [])}
gas = fee = value = 0
failed = 0
lines = []
for t in d["transactions"]:
    h = t.get("hash")
    r = rc.get(h, {})
    g = int(r.get("gasUsed", "0x0"), 16)
    p = int(r.get("effectiveGasPrice", "0x0"), 16)
    l1 = int(r.get("l1Fee", "0x0") or "0x0", 16)
    v = int((t.get("transaction") or {}).get("value", "0x0") or "0x0", 16)
    gas += g
    fee += g * p + l1
    value += v
    ok = r.get("status") == "0x1"
    failed += 0 if ok else 1
    what = t.get("function") or ("deploy " + (t.get("contractName") or "?"))
    target = t.get("contractAddress") or (t.get("transaction") or {}).get("to") or ""
    lines.append(f"   {h}  {'ok' if ok else 'FAILED'}  {what}  {target}")
print(f"== {stage}: {len(d['transactions'])} txs, gas {gas:,}, fee {fee / 1e18:.10f} OKB, value {value / 1e18:.8f} OKB" + (f", {failed} FAILED" if failed else ""))
print("\n".join(lines))
PY
}

# 执行一次 forge script（broadcast + --slow），然后打印交易。签名在脚本内部用环境变量里的私钥完成。
fs() {
  local stage="$1" script="$2" base
  base="$(basename "$script")"
  local latest="broadcast/$base/$CHAIN/run-latest.json"
  rm -f "$latest"
  check_chain
  echo "## stage $stage ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))" >>"$LOG"
  forge script "$script" --rpc-url "$RPC" --broadcast --slow --with-gas-price "$GAS_PRICE_WEI" 2>&1 | redact
  print_txs "$stage" "$latest"
}

scenario() { # scenario <阶段名> <STAGE> [VAR=值 ...]
  local stage="$1" st="$2"
  shift 2
  (
    export STAGE="$st"
    for kv in "$@"; do export "${kv?}"; done
    fs "$stage" script/XLayerTestnetScenario.s.sol
  )
}

time_divisor() { python3 -c "import json; print(json.load(open('$DEP')).get('timeDivisor', 720))"; }
operator_grace() { echo $((3 * 86400 / $(time_divisor))); }
auto_list_delay() { echo $((86400 / $(time_divisor))); }

# 当前招募中的月局已过期就先关闭；离截止不到 330 秒就等它过期再关闭
fresh_month() {
  local m deadline now
  m="$(recruiting_month)"
  deadline="$(num "$m" "recruitDeadline()(uint256)")"
  now="$(chain_now)"
  if [ "$KEY_SOURCE" != "anvil" ] && [ "$now" -lt "$deadline" ] && [ $((now + 330)) -gt "$deadline" ]; then
    wait_until "$((deadline + 1))" "month board recruit deadline (too close to join safely)"
    now="$(chain_now)"
  fi
  if [ "$now" -ge "$deadline" ]; then scenario "$1-close" close; fi
}

# 从 drand HTTP API 取第 $1 轮的签名（64 字节：x ‖ y，十六进制）。轮次还没产生时每 3 秒重试，最多 5 分钟。
drand_signature() {
  local round="$1" i out
  for i in $(seq 1 100); do
    out="$(curl -s --max-time 10 "$DRAND_API/v2/beacons/evmnet/rounds/$round" || true)"
    if python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert len(d["signature"]) == 128' "$out" 2>/dev/null; then
      python3 -c 'import json,sys; print("0x" + json.loads(sys.argv[1])["signature"])' "$out"
      return 0
    fi
    sleep 3
  done
  echo "drand round $round not available from $DRAND_API" >&2
  return 1
}

# ---------------------------------------------------------------------------
# 各阶段
# ---------------------------------------------------------------------------

st_deploy() {
  check_chain
  echo "-- size check: FOUNDRY_PROFILE=sizecheck forge test --match-path test/SizeLimits.t.sol"
  if ! FOUNDRY_PROFILE=sizecheck forge test --match-path test/SizeLimits.t.sol >/dev/null 2>&1; then
    echo "refusing to deploy: contract size check failed (run the command above with -vv for details)" >&2
    exit 1
  fi
  [ -f "$START_FILE" ] || balance "$DEPLOYER" >"$START_FILE"
  (
    export WRITE_DEPLOYMENT=1
    fs deploy script/DeployXLayerTestnet.s.sol
  )
  if [ "$(cast code "$(addr hub)" --rpc-url "$RPC")" = "0x" ] || [ "$(cast code "$(addr monthFactory)" --rpc-url "$RPC")" = "0x" ]; then
    echo "deployment incomplete: XHub / XMonthFactory are not on chain; $DEP is not valid" >&2
    mv "$DEP" "$DEP.invalid"
    exit 1
  fi
  echo "== addresses ($DEP)"
  python3 -c "import json; [print(f'   {k:20} {v}') for k, v in json.load(open('$DEP')).items()]" | tee -a "$LOG"
}

st_fund() { scenario fund fund PLAYER_FROM=0 PLAYER_COUNT=$PLAYERS; }
st_mint() { scenario mint mint PLAYER_FROM=0 PLAYER_COUNT=$PLAYERS; }

st_genesis() {
  local at
  at=$(($(num "$(addr splitter)" "mintStart()(uint256)") + $(num "$(addr hub)" "genesisDelay()(uint256)") + 1))
  wait_until "$at" "genesis delay"
  scenario genesis genesis
  echo "   month board #1 $(month_board 1)"
}

st_join_month() {
  fresh_month join-month
  scenario join-month join PLAYER_FROM=0 PLAYER_COUNT=$HALF
}
st_machines_month() { scenario machines-month machines MONTH_NUMBER=1; }
st_reward() { scenario reward reward REWARD_RANK=1; }

st_month_yield() {
  wait_until "$(($(num "$(month_board 1)" "prepEnd()(uint256)") + 1))" "month board #1 preparation period"
  scenario month-yield yield MONTH_NUMBER=1
}

st_join_month2() {
  local m start end
  m="$(month_board 1)"
  start="$(num "$m" "miningStart()(uint256)")"
  end="$(num "$m" "miningEnd()(uint256)")"
  wait_until "$((end - (end - start) / 15))" "the last 1/15 of month board #1 mining"
  scenario join-month2-yield yield MONTH_NUMBER=1
  fresh_month join-month2
  scenario join-month2 join PLAYER_FROM=$HALF PLAYER_COUNT=$HALF
  echo "   month board #2 $(month_board 2)"
}

st_draw_m1() {
  wait_until "$(($(num "$(month_board 1)" "miningEnd()(uint256)") + 1))" "month board #1 mining period"
  scenario draw-m1 draw MONTH_NUMBER=1
  local m id round rtime sig
  m="$(month_board 1)"
  [ "$(num "$m" "drawPending()(bool)")" = "true" ] || { echo "   (no drand request: empty prize pool or already drawn)"; return 0; }
  id="$(num "$m" "pendingRequestId()(uint256)")"
  round="$(cast call "$(addr drandAdapter)" "requests(uint256)(address,uint64,bool)" "$id" --rpc-url "$RPC" | sed -n 2p | awk '{print $1}')"
  rtime="$(num "$(addr drandAdapter)" "roundTime(uint64)(uint256)" "$round")"
  echo "   drand request $id locked round $round (round time $rtime)" | tee -a "$LOG"
  # 链上时间到了这一轮，才能交付（drand 网络也是按真实时间出块）
  wait_until "$((rtime + 1))" "drand round $round on chain"
  sig="$(drand_signature "$round")"
  echo "   drand round $round signature fetched from $DRAND_API" | tee -a "$LOG"
  scenario deliver-m1 deliver MONTH_NUMBER=1 DRAND_REQUEST_ID="$id" DRAND_SIGNATURE="$sig"
}

st_settle_m1() { scenario settle-m1 settle MONTH_NUMBER=1 RELAY_TO=2; }

st_feed() {
  check_chain
  local bsc_rpc="${BSC_RPC:-https://bsc-rpc.publicnode.com}" src="${BSC_PRICE_FEED:-0x5479E1ca5EA5052d3EB699BF9C738Ac358FC3465}"
  local blk bid ask cu
  blk="$(cast block-number --rpc-url "$bsc_rpc")"
  bid="$(cast call "$src" "bid()(uint256)" --block "$blk" --rpc-url "$bsc_rpc" | awk '{print $1}')"
  ask="$(cast call "$src" "ask()(uint256)" --block "$blk" --rpc-url "$bsc_rpc" | awk '{print $1}')"
  cu="$(cast call "$src" "catchingUp()(bool)" --block "$blk" --rpc-url "$bsc_rpc")"
  echo "   BSC price feed $src at block $blk: bid $bid ask $ask catchingUp $cu" | tee -a "$LOG"
  scenario feed feed FEED_BID="$bid" FEED_ASK="$ask" BSC_BLOCK="$blk" FEED_CATCHUP="$cu"
}

st_trade_m1() { scenario trade-m1 trade MONTH_NUMBER=1 PLAYER_FROM=0; }

st_settle_m1_auto() {
  local m
  m="$(month_board 1)"
  wait_until "$(($(num "$m" "settleStart()(uint256)") + $(auto_list_delay) + 1))" "auto listing at cost on month board #1"
  scenario settle-m1-auto settle MONTH_NUMBER=1
}

st_fallback_month() {
  local m
  m="$(month_board 1)"
  wait_until "$(($(num "$m" "settleStart()(uint256)") + $(operator_grace) + 1))" "operator grace on month board #1"
  scenario fallback-month fallback MONTH_NUMBER=1 PLAYER_FROM=0 PLAYER_COUNT=$HALF
}

st_join_month3() {
  fresh_month join-month3
  scenario join-month3 join PLAYER_FROM=0 PLAYER_COUNT=$HALF
  local n m
  n="$(num "$(addr monthFactory)" "currentNumber()(uint256)")"
  m="$(month_board $((n - 1)))"
  echo "   month board #$((n - 1)) $m  rollover received: $(num "$m" "subsidyCapital()(uint256)") (BEM, 8 decimals)" | tee -a "$LOG"
  echo "   month board #1 rolled over: $(num "$(month_board 1)" "rolledOver()(uint256)")" | tee -a "$LOG"
}

st_buyback() { scenario buyback buyback; }
st_sweep() { scenario sweep sweep PLAYER_FROM=0 PLAYER_COUNT=$PLAYERS; }

st_report() {
  check_chain
  local start now
  start="$(cat "$START_FILE")"
  now="$(balance "$DEPLOYER")"
  python3 - "$start" "$now" <<'PY' | tee -a "$LOG"
import sys
s, n = int(sys.argv[1]), int(sys.argv[2])
print(f"== deployer balance: start {s / 1e18:.8f}, now {n / 1e18:.8f}, spent {(s - n) / 1e18:.8f} OKB")
PY
  st_status
}

st_status() {
  check_chain
  (
    export STAGE=status
    forge script script/XLayerTestnetScenario.s.sol --rpc-url "$RPC" 2>&1 | redact
  )
}

st_prep_summary() {
  echo "== prep done (timeDivisor $(time_divisor)); the operator bot takes over from here" | tee -a "$LOG"
  echo "   month board #1 $(month_board 1)" | tee -a "$LOG"
  echo "   players [0, $PLAYERS) hold a pass and 100 MockBEM each; the board starts when filled (join-month stage" | tee -a "$LOG"
  echo "   or real users); RIGs are sold with machines-month; yield arrives when anyone calls MockRig.claim(ids)" | tee -a "$LOG"
}

STAGES=(deploy feed fund mint genesis join-month machines-month reward month-yield join-month2 draw-m1 settle-m1
  trade-m1 settle-m1-auto fallback-month join-month3 buyback sweep report)

run_stage() {
  local s="$1"
  case "$s" in
  status) st_status ;;
  prep)
    for x in deploy feed fund mint genesis; do run_stage "$x"; done
    st_prep_summary
    ;;
  all) for x in "${STAGES[@]}"; do run_stage "$x"; done ;;
  *)
    local fn="st_${s//-/_}"
    if ! declare -F "$fn" >/dev/null; then
      echo "unknown stage: $s" >&2
      echo "stages: ${STAGES[*]} status all prep" >&2
      exit 1
    fi
    echo ">>> $s"
    "$fn"
    ;;
  esac
}

[ $# -ge 1 ] || {
  echo "usage: bash script/xlayer-testnet.sh <stage> [<stage> ...] | from <stage> | prep | all | status   (stages: ${STAGES[*]})" >&2
  exit 1
}
if [ "$1" = "from" ]; then
  first="${2:?usage: bash script/xlayer-testnet.sh from <stage>}"
  started=0
  set --
  for x in "${STAGES[@]}"; do
    if [ "$x" = "$first" ]; then started=1; fi
    if [ "$started" = 1 ]; then set -- "$@" "$x"; fi
  done
  if [ $# -eq 0 ]; then
    echo "unknown stage: $first" >&2
    exit 1
  fi
fi
mkdir -p deployments
for s in "$@"; do run_stage "$s"; done
