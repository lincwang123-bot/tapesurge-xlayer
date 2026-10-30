#!/usr/bin/env bash
# M5a only. No .env sourcing, raw private keys, unlocked RPC signing, or automatic broadcast.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$PATH:$HOME/.foundry/bin"
# Prevent Forge from selecting an inherited signing option. No value is read or printed.
unset ETH_PRIVATE_KEY ETH_KEYSTORE ETH_KEYSTORE_ACCOUNT ETH_PASSWORD ETH_PASSWORD_FILE

usage() {
  cat <<'TXT'
Usage:
  bash script/xlayer-demo.sh [simulate] [--rpc-url URL] [--fork-block NUMBER]
  bash script/xlayer-demo.sh deploy (--account NAME | --ledger) [--rpc-url URL]
  bash script/xlayer-demo.sh rehearse --rpc-url http://127.0.0.1:PORT

rehearse: real broadcast to a LOCAL anvil fork of X Layer mainnet only
(anvil --fork-url https://rpc.xlayer.tech), to read actual receipt gas.
It impersonates the demo owner on that local node and writes
deployments/196-demo.rehearsal.json. Never accepted for a non-local RPC.

Default: simulate on https://rpc.xlayer.tech as the fixed demo owner.
Deployment requires an explicit wallet and typing DEPLOY after the simulation.
Only chain 196 is accepted. This is a Demo processor, NOT a Genesis pass.
TXT
}

MODE=simulate
if [ $# -gt 0 ] && [[ "$1" != --* ]]; then MODE="$1"; shift; fi
RPC=https://rpc.xlayer.tech
FORK_BLOCK=
WALLET=()
while [ $# -gt 0 ]; do
  case "$1" in
    --rpc-url)
      [ $# -ge 2 ] || { usage >&2; exit 2; }
      RPC="$2"; shift 2 ;;
    --fork-block)
      [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }
      FORK_BLOCK="$2"; shift 2 ;;
    --account)
      [ $# -ge 2 ] && [ -n "$2" ] && [[ "$2" != -* ]] && [ ${#WALLET[@]} -eq 0 ] \
        || { usage >&2; exit 2; }
      WALLET=(--account "$2"); shift 2 ;;
    --ledger)
      [ ${#WALLET[@]} -eq 0 ] || { usage >&2; exit 2; }
      WALLET=(--ledger); shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unsupported argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$MODE" in simulate|deploy|rehearse) ;; *) usage >&2; exit 2 ;; esac
is_local() { [[ "$RPC" =~ ^https?://(127\.0\.0\.1|localhost)(:[0-9]+)?/?$ ]]; }
if [ "$MODE" = rehearse ]; then
  is_local || { echo "rehearse only runs against a local anvil fork (127.0.0.1 / localhost)." >&2; exit 2; }
  [ ${#WALLET[@]} -eq 0 ] && [ -z "$FORK_BLOCK" ] || { echo "rehearse takes no wallet and no --fork-block (start anvil at the block you want)." >&2; exit 2; }
fi
if [ "$MODE" = simulate ] && [ ${#WALLET[@]} -ne 0 ]; then
  echo "Simulation does not need a wallet; remove --account / --ledger." >&2; exit 2
fi
if [ "$MODE" = deploy ] && { [ ${#WALLET[@]} -eq 0 ] || [ -n "$FORK_BLOCK" ]; }; then
  echo "Deployment requires --account or --ledger and cannot use a pinned fork block." >&2; exit 2
fi

OWNER=0x9304e363D12Fd84a32E92fD274C8EDC82Dd7d965
SCRIPT=script/XLayerDemoProcessor.s.sol:XLayerDemoProcessor
SIMULATED=deployments/196-demo.simulation.json
BROADCAST=broadcast/XLayerDemoProcessor.s.sol/196/run-latest.json
FINAL=deployments/196-demo.broadcast.json

CHAIN_ID="$(cast chain-id --rpc-url "$RPC")"
[ "$CHAIN_ID" = 196 ] || { echo "Refusing chain $CHAIN_ID; expected X Layer mainnet (196)." >&2; exit 1; }
if [ "$MODE" = deploy ] && { [ -e "$FINAL" ] || [ -e "$BROADCAST" ]; }; then
  echo "A deployment record already exists. Review it before any further deployment; no file was removed." >&2
  exit 1
fi
mkdir -p deployments
ARGS=("$SCRIPT" --rpc-url "$RPC" --sender "$OWNER")
if [ -n "$FORK_BLOCK" ]; then ARGS+=(--fork-block-number "$FORK_BLOCK"); fi

if [ "$MODE" = rehearse ]; then
  REHEARSAL=deployments/196-demo.rehearsal.json
  OVERRIDE=false
  cast rpc anvil_impersonateAccount "$OWNER" --rpc-url "$RPC" >/dev/null
  OBSERVED="$(cast balance "$OWNER" --rpc-url "$RPC")"
  if python3 -c "import sys; sys.exit(0 if int('$OBSERVED') < 10**17 else 1)"; then
    # Local node only: give the impersonated owner 0.1 OKB so the three transactions can be mined.
    cast rpc anvil_setBalance "$OWNER" 0x16345785D8A0000 --rpc-url "$RPC" >/dev/null
    OVERRIDE=true
  fi
  TMP_BROADCAST="$(mktemp -d)"
  trap 'rm -rf "$TMP_BROADCAST"' EXIT
  echo "Rehearsal: broadcasting the three calls to the LOCAL fork only ($RPC)."
  FOUNDRY_BROADCAST="$TMP_BROADCAST" forge script "${ARGS[@]}" --sig 'rehearse()' --unlocked --broadcast --slow -vv
  RUN="$TMP_BROADCAST/XLayerDemoProcessor.s.sol/196/rehearse-latest.json" # Forge names it after --sig
  [ -s "$RUN" ] || { echo "Missing local receipts." >&2; exit 1; }
  python3 - "$REHEARSAL" "$RUN" "$OBSERVED" "$OVERRIDE" "$(cast block-number --rpc-url "$RPC")" <<'PY'
import json, sys
from decimal import Decimal
path, run_path, observed, override, head = sys.argv[1:]
result = json.load(open(path))
run = json.load(open(run_path))
num = lambda v: int(v, 0) if isinstance(v, str) else int(v)
by_hash = {r["transactionHash"].lower(): r for r in run["receipts"]}
names = ["createCPU", "mint 5 NAND", "tapeout HA1"]
txs = []
for name, tx in zip(names, run["transactions"]):
    rc = by_hash[tx["hash"].lower()]
    assert num(rc["status"]) == 1, "local transaction failed"
    gas = num(rc["gasUsed"]); price = num(rc["effectiveGasPrice"])
    txs.append({"step": name, "gasUsed": gas, "effectiveGasPriceWei": price, "gasFeeWei": gas * price,
                "valueWei": num(tx["transaction"].get("value", "0x0")), "l1FeeWei": num(rc.get("l1Fee", "0x0"))})
assert len(txs) == 3
result.update({"simulationOnly": True, "status": "LOCAL_FORK_REHEARSAL_NOT_DEPLOYED",
               "rehearsalNode": "local anvil fork of X Layer mainnet", "localHeadBlock": int(head),
               "observedOwnerBalanceWei": int(observed), "localBalanceOverridden": override == "true",
               "transactions": txs, "gasUsedTotal": sum(t["gasUsed"] for t in txs),
               "gasFeeWeiTotal": sum(t["gasFeeWei"] for t in txs)})
result.pop("gasCost", None)
json.dump(result, open(path, "w"), indent=2); open(path, "a").write("\n")
for t in txs:
    print(f"{t['step']:12} gas {t['gasUsed']:>9,}  fee {Decimal(t['gasFeeWei'])/Decimal(10**18):.10f} OKB  value {Decimal(t['valueWei'])/Decimal(10**18)} OKB")
tot = result["gasFeeWeiTotal"] + result["transactionValueWei"]
print(f"total gas {result['gasUsedTotal']:,}  gas fee {Decimal(result['gasFeeWeiTotal'])/Decimal(10**18):.10f} OKB  all-in {Decimal(tot)/Decimal(10**18):.10f} OKB")
print("Rehearsal record:", path, "(local fork only; nothing deployed)")
PY
  exit 0
fi

echo "Simulating three calls: create Demo CPU, mint 5 NAND, tapeout HA1. No transaction is sent."
if [ "$MODE" = simulate ]; then
  # simulate() may fund only the local fork so a zero-balance owner can preview.
  # Skip the second transaction replay, which starts from the real zero balance;
  # the first execution still runs all calls against the genuine forked contracts.
  forge script "${ARGS[@]}" --sig 'simulate()' --skip-simulation -vv
else
  # Actual deployment preflight must use the real balance and replay all txs.
  forge script "${ARGS[@]}" -vv
fi
[ -s "$SIMULATED" ] || { echo "Missing simulation report." >&2; exit 1; }
if [ "$MODE" = simulate ]; then
  echo "Simulation complete: $SIMULATED. All addresses are predictions; nothing was deployed."
  exit 0
fi

echo "This creates a public 100-transistor Demo processor on X Layer MAINNET."
echo "Creator and circuit owner: $OWNER. This processor grants no Genesis or board rights."
read -r -p "Type DEPLOY to send these transactions: " ANSWER
[ "$ANSWER" = DEPLOY ] || { echo "Aborted; no transaction sent."; exit 1; }
# The user-provided wallet must sign for the fixed --sender; Forge rejects a mismatch.
forge script "${ARGS[@]}" "${WALLET[@]}" --broadcast --slow -vv
[ -s "$BROADCAST" ] || { echo "Missing Forge broadcast receipts; no deployed manifest was written." >&2; exit 1; }

# A real manifest is derived only from successful Forge receipts plus current RPC checks.
# The simulation JSON is never renamed or represented as a deployed record.
python3 - "$SIMULATED" "$BROADCAST" "$FINAL" "$RPC" "$OWNER" <<'PY'
import json, os, subprocess, sys
from decimal import Decimal

sim_path, broadcast_path, output_path, rpc, owner = sys.argv[1:]
with open(sim_path) as f:
    result = json.load(f)
with open(broadcast_path) as f:
    data = json.load(f)

def number(value):
    return int(value, 0) if isinstance(value, str) else int(value)

def cast(*args):
    return subprocess.check_output(["cast", *args, "--rpc-url", rpc], text=True).strip()

txs = data.get("transactions", [])
receipts = data.get("receipts", [])
assert len(txs) == 3 and len(receipts) == 3, "Expected exactly three actual transaction receipts"
by_hash = {r["transactionHash"].lower(): r for r in receipts}
records = []
for tx in txs:
    tx_hash = tx.get("hash")
    assert isinstance(tx_hash, str) and tx_hash.lower() in by_hash, "Missing actual transaction hash"
    receipt = by_hash[tx_hash.lower()]
    assert number(receipt["status"]) == 1, "Transaction failed; no deployed manifest written"
    submitted = tx["transaction"]
    assert submitted["from"].lower() == owner.lower(), "Unexpected signer"
    gas = number(receipt["gasUsed"])
    fee = gas * number(receipt["effectiveGasPrice"])
    records.append({"transactionHash": tx_hash, "blockNumber": number(receipt["blockNumber"]),
                    "gasUsed": gas, "gasFeeWei": fee, "valueWei": number(submitted.get("value", "0x0"))})

assert cast("chain-id") == "196", "Wrong chain"
for field in ("transistors", "circuits"):
    assert cast("code", result[field]) != "0x", f"No deployed code: {field}"
assert cast("call", result["transistors"], "creator()(address)").lower() == owner.lower(), "Creator mismatch"
assert cast("call", result["circuits"], "ownerOf(uint256)(address)", str(result["circuitId"])).lower() == owner.lower(), "Circuit owner mismatch"
assert sum(r["valueWei"] for r in records) == result["transactionValueWei"], "Transaction value mismatch"
result["simulationOnly"] = False
result["status"] = "DEPLOYED_RECEIPTS_AND_OWNERSHIP_VERIFIED"
result["simulationSourceBlock"] = result.pop("sourceBlock")
result["fromBlock"] = min(r["blockNumber"] for r in records)
result["transactions"] = records
result["broadcastSource"] = broadcast_path
result["gasFeeWei"] = sum(r["gasFeeWei"] for r in records)
result.pop("gasCost", None)
fd = os.open(output_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(result, f, indent=2)
    f.write("\n")
for receipt in records:
    print(receipt["transactionHash"], "block", receipt["blockNumber"], "gas", receipt["gasUsed"])
total = result["transactionValueWei"] + result["gasFeeWei"]
print("Verified deployment manifest:", output_path)
print("Actual value + gas:", Decimal(total) / Decimal(10**18), "OKB")
PY
