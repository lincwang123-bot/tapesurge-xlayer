#!/usr/bin/env bash
# TapeSurge X Layer 主网部署。只有在你自己提供钱包、并手动输入 DEPLOY 之后才会广播。
#
# 用法：
#   bash script/xlayer-mainnet.sh [simulate]                   只模拟（默认）：部署前自检 + 打印部署计划，不发送交易
#   bash script/xlayer-mainnet.sh deploy --account <keystore 名>   或   deploy --ledger
#                                                              广播部署（先确认链 ID 196、跑 forge test 和大小检查、模拟、等你输入 DEPLOY）
#   bash script/xlayer-mainnet.sh check                        部署后的只读核对（不一致的项标红，退出码非 0）
#   bash script/xlayer-mainnet.sh verify                       可选：Sourcify 源码验证（不需要 API key）
#
# 环境变量：
#   XLAYER_RPC_URL（默认 https://rpc.xlayer.tech）。本地主网分叉演练用 http://127.0.0.1:8545（anvil --fork-url ...）
#   SENDER（simulate / deploy 必填）：部署者地址（和 --account / --ledger 对应的地址一致）
#   FOUNDATION_SAFE、FEE_SAFE、OPERATOR（必填；X Layer 上的两个 Safe 还没建时脚本拒绝运行）
#   MINT_PRICE_WEI（可选，默认 0.006 OKB）：部署当天按 OKB 价格重算；MAX_GAS_PRICE_WEI（可选，默认 0.1 gwei）
#   EXPECT_OPERATOR / EXPECT_FOUNDATION_SAFE / EXPECT_FEE_SAFE / EXPECT_MINT_PRICE_WEI（check 可选）
#
# 安全：不读取任何 .env 文件，不接受 --private-key / 助记词；钱包只能是 --account（加密 keystore）或 --ledger。
#      只有 RPC 指向本机（anvil 分叉）时，deploy 才接受 --unlocked。输出里的 RPC 地址会被遮掉。
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$PATH:$HOME/.foundry/bin"

CMD="${1:-simulate}"
[ $# -gt 0 ] && shift
RPC="${XLAYER_RPC_URL:-https://rpc.xlayer.tech}"
export RPC
SCRIPT=script/DeployXLayerMainnet.s.sol
BROADCAST_FILE="broadcast/DeployXLayerMainnet.s.sol/196/run-latest.json"
FINAL=deployments/196.json
PENDING=deployments/196.pending.json

is_local() { [[ "$RPC" =~ ^https?://(127\.0\.0\.1|localhost)(:[0-9]+)?/?$ ]]; }

redact() {
  python3 -c '
import os, sys
rpc = os.environ.get("RPC", "")
for line in sys.stdin:
    if len(rpc) > 8:
        line = line.replace(rpc, "<rpc>")
    sys.stdout.write(line)
    sys.stdout.flush()
'
}

check_chain() {
  local id
  id="$(cast chain-id --rpc-url "$RPC")"
  if [ "$id" != "196" ]; then
    echo "refusing: RPC chain id is $id, expected 196 (X Layer mainnet)" >&2
    exit 1
  fi
}

need_env() {
  for v in "$@"; do
    if [ -z "${!v:-}" ]; then
      echo "set $v" >&2
      exit 1
    fi
  done
}

print_txs() {
  python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
rc = {r["transactionHash"]: r for r in d.get("receipts", [])}
tot_gas = tot_fee = tot_value = 0
for t in d["transactions"]:
    r = rc.get(t.get("hash"), {})
    g = int(r.get("gasUsed", "0x0"), 16)
    p = int(r.get("effectiveGasPrice", "0x0"), 16)
    l1 = int(r.get("l1Fee", "0x0"), 16)
    v = int((t.get("transaction") or {}).get("value", "0x0") or "0x0", 16)
    tot_gas += g; tot_fee += g * p + l1; tot_value += v
    ok = "ok" if r.get("status") == "0x1" else "FAILED"
    name = t.get("contractName") or t.get("function") or "?"
    print(f"   {t.get('hash')}  {ok}  {name:34} gas {g:>11,}  fee {(g * p + l1) / 1e18:.10f} OKB" + (f"  value {v / 1e18:.6f} OKB" if v else ""))
print(f"== total: {len(d['transactions'])} txs, gas {tot_gas:,}, fee {tot_fee / 1e18:.10f} OKB, value {tot_value / 1e18:.6f} OKB, all-in {(tot_fee + tot_value) / 1e18:.10f} OKB")
PY
}

case "$CMD" in
simulate)
  check_chain
  need_env SENDER FOUNDATION_SAFE FEE_SAFE OPERATOR
  PENDING_FILE=deployments/196.simulated.json forge script "$SCRIPT" --rpc-url "$RPC" --sender "$SENDER" "$@" 2>&1 | redact
  rm -f deployments/196.simulated.json
  echo "(simulation only: nothing was broadcast)"
  ;;

deploy)
  need_env SENDER FOUNDATION_SAFE FEE_SAFE OPERATOR
  WALLET=("$@")
  has() { for a in "${WALLET[@]}"; do [ "$a" = "$1" ] && return 0; done; return 1; }
  if has --private-key || has --mnemonics || has --mnemonic; then
    echo "refusing: use --account (encrypted keystore) or --ledger, not a raw key" >&2
    exit 1
  fi
  if has --unlocked; then
    is_local || { echo "refusing: --unlocked is only allowed against a local anvil fork" >&2; exit 1; }
  elif ! has --account && ! has --ledger; then
    echo "usage: bash script/xlayer-mainnet.sh deploy --account <keystore name> | --ledger" >&2
    exit 1
  fi
  if [ -f "$FINAL" ] && ! is_local; then
    echo "refusing: $FINAL already exists (protocol already deployed?)" >&2
    exit 1
  fi
  check_chain
  echo "-- forge test"
  # 部署参数不传给测试进程（测试里有"没填 Safe 时拒绝运行"的用例）；分叉测试不在这里跑
  env -u FOUNDATION_SAFE -u FEE_SAFE -u OPERATOR -u MINT_PRICE_WEI XLAYER_RPC_URL= forge test >/dev/null 2>&1 \
    || { echo "forge test failed; run it to see why" >&2; exit 1; }
  echo "-- size check (EIP-170 / EIP-3860)"
  FOUNDRY_PROFILE=sizecheck forge test --match-path test/SizeLimits.t.sol >/dev/null 2>&1 \
    || { echo "size check failed: FOUNDRY_PROFILE=sizecheck forge test --match-path test/SizeLimits.t.sol -vv" >&2; exit 1; }
  echo "-- deployment plan (simulation)"
  PENDING_FILE=deployments/196.simulated.json forge script "$SCRIPT" --rpc-url "$RPC" --sender "$SENDER" 2>&1 | redact
  rm -f deployments/196.simulated.json
  echo
  echo "This will broadcast up to 7 transactions to X Layer MAINNET from $SENDER"
  echo "(pool observation cardinality, if needed, then 6 contract deployments)."
  echo "The genesis countdown starts as soon as GenesisSplitter is deployed."
  read -r -p "Type DEPLOY to broadcast: " answer
  [ "$answer" = "DEPLOY" ] || { echo "aborted, nothing was broadcast"; exit 1; }
  rm -f "$PENDING" "$BROADCAST_FILE"
  PENDING_FILE="$PENDING" forge script "$SCRIPT" --rpc-url "$RPC" --sender "$SENDER" "${WALLET[@]}" \
    --broadcast --slow 2>&1 | redact
  [ -f "$BROADCAST_FILE" ] || { echo "no broadcast record found" >&2; exit 1; }
  echo "-- transactions"
  print_txs "$BROADCAST_FILE"
  for key in oracle machineSource drandAdapter splitter hub monthFactory; do
    a="$(python3 -c "import json,sys; print(json.load(open('$PENDING'))[sys.argv[1]])" "$key")"
    if [ "$(cast code "$a" --rpc-url "$RPC")" = "0x" ]; then
      echo "deployment incomplete: $key ($a) has no code; $PENDING is NOT valid" >&2
      exit 1
    fi
  done
  python3 - "$PENDING" "$BROADCAST_FILE" "$FINAL" <<'PY'
import json, sys
pending, bc, final = sys.argv[1:]
d = json.load(open(pending))
r = json.load(open(bc))["receipts"]
d["fromBlock"] = min(int(x["blockNumber"], 16) for x in r)
json.dump(d, open(final, "w"), indent=2)
print(f"== {final} written (fromBlock {d['fromBlock']})")
PY
  rm -f "$PENDING"
  echo "NEXT: bash script/xlayer-mainnet.sh check"
  ;;

check)
  check_chain
  out="$(forge script script/CheckXLayerMainnet.s.sol --rpc-url "$RPC" 2>&1 | redact)"
  echo "$out" | sed -e $'s/.*MISMATCH.*/\033[31m&\033[0m/' -e $'s/.*ALL CHECKS PASSED.*/\033[32m&\033[0m/'
  if echo "$out" | grep -q "MISMATCH"; then exit 2; fi
  ;;

verify)
  check_chain
  need_env SENDER FOUNDATION_SAFE FEE_SAFE OPERATOR
  forge script "$SCRIPT" --rpc-url "$RPC" --sender "$SENDER" --resume --verify --verifier sourcify 2>&1 | redact
  echo "The XMonthBoard implementation is created inside the XMonthFactory constructor;"
  echo "if it is not matched automatically, verify it with forge verify-contract (constructor args = boardConfig())."
  ;;

*)
  echo "usage: bash script/xlayer-mainnet.sh [simulate|deploy|check|verify]" >&2
  exit 1
  ;;
esac
