#!/usr/bin/env bash
# =============================================================================
#  seed_jobs.sh — Seed N demo jobs on Arc testnet using NATIVE USDC.
#
#  WHY cast send (not `forge script --broadcast`):
#    forge script simulates the tx LOCALLY in a fork first. Arc's USDC contract
#    calls a precompile `isBlocklisted` that does not exist in the fork EVM, so
#    simulation dies with StackUnderflow — the CHAIN is fine, the SIMULATOR is
#    not. `cast send` asks the RPC node to estimate gas / simulate server-side,
#    where the real precompile resolves fine.
#
#  USAGE:
#    source .env                       # exports DEPLOYER_PRIVATE_KEY (0x…)
#    ./script/seed_jobs.sh [COUNT] [USDC_PER_JOB]
#      COUNT        default 10
#      USDC_PER_JOB default 2   (atomic 6dp, i.e. 2e6)
#    ./script/seed_jobs.sh 5 4         # 5 jobs x 4 USDC = 20 USDC total
# =============================================================================
set -euo pipefail

# Auto-load .env if present (exported so ${VAR:?} sees it)
if [ -f ".env" ]; then
  set -a; source .env; set +a
fi

RPC="${ARC_TESTNET_RPC_URL:-https://rpc.testnet.arc.io}"
USDC="0x3600000000000000000000000000000000000000"   # Arc native USDC ERC-20 view (6 dp)
ROUTER="0xF11b9cCEcd0976A5A1F050F23fD028c6b59bD1e8" # deployed JobRouter (deploy #2, MIN_BOND=5)
PK="${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY in .env}"

COUNT="${1:-10}"
USDCPER="${2:-2}"
START="${3:-1}"                                  # resume offset: seed from job #START
if (( START < 0 )) || (( START > COUNT )); then  # negative or past-end -> just report
  START=1
fi
PAYMENT_ATOMIC=$(( USDCPER * 1000000 ))            # 6 dp
TOTAL_ATOMIC=$(( PAYMENT_ATOMIC * COUNT ))
# Zero-sentinel split -> contract resolves regime default (9000/500/500, gates OFF)
SPLIT="(0,0,0)"

now_ts="$(date +%s)"
EXEC_DEADLINE=$(( now_ts + 86400 ))                # +1 day
APPROVAL_WINDOW=7200                               # 2h

# Exact next usable nonce (account pending txs included via the RPC).
DEPLOYER="$(cast wallet address "$PK" 2>/dev/null || echo 0x9931C57D7a365Aeb64b8b38A821D8E762939F69f)"
NEXT_NONCE="$(cast nonce "$DEPLOYER" --rpc-url "$RPC")"

echo "=== seed_jobs — Arc testnet (native USDC) ==="
echo "  router          : $ROUTER"
echo "  usdc            : $USDC"
echo "  count x per-job : $COUNT x $USDCPER USDC = $(( TOTAL_ATOMIC / 1000000 )) USDC escrow"
echo "  execDeadline    : $EXEC_DEADLINE  (+1 day)"
echo "  approvalWindow  : $APPROVAL_WINDOW (2h)"
echo "  split           : $SPLIT (sentinel -> regime default)"
echo

# ---- 1) approve total escrow USDC to JobRouter (only if fresh run) ----------
if (( START == 1 )); then
  echo ">> approve($ROUTER, $TOTAL_ATOMIC) [nonce $NEXT_NONCE]"
  cast send "$USDC" \
    "approve(address,uint256)(bool)" \
    "$ROUTER" "$TOTAL_ATOMIC" \
    --rpc-url "$RPC" --private-key "$PK" --nonce "$NEXT_NONCE" --async || exit 1
  NEXT_NONCE=$((NEXT_NONCE + 1))
  echo ">> approve sent."
else
  echo ">> resume mode — skipping approve (allowance already granted)"
fi

# ---- 2) create COUNT open-post jobs (from START) ----------------------------
for (( i=START; i<=COUNT; i++ )); do
  # deterministic per-job specHash (on-chain provenance string)
  SPEC=$(printf 'seed-job-%d' "$i")
  SPECHASH=$(cast keccak "$SPEC")
  echo ">> createJob(#$i, ${SPECHASH:0:18}…, open, ops=0) [nonce $NEXT_NONCE]"
  cast send "$ROUTER" \
    "createJob(uint128,bytes32,(uint16,uint16,uint16),uint64,uint64,address,uint96)(uint256)" \
    "$PAYMENT_ATOMIC" "$SPECHASH" "$SPLIT" \
    "$EXEC_DEADLINE" "$APPROVAL_WINDOW" \
    "0x0000000000000000000000000000000000000000" \
    "0" \
    --rpc-url "$RPC" --private-key "$PK" --nonce "$NEXT_NONCE" --async || { echo "job $i failed at nonce $NEXT_NONCE"; exit 1; }
  NEXT_NONCE=$((NEXT_NONCE + 1))
  sleep 0.3   # keep a beat between async sends (some RPCs enqueue, some 429)
done

echo
echo "=== done — jobs $START..$COUNT queued (${COUNT} total requested)."
echo "Verify with:"
echo "  cast call $ROUTER 'jobCount()(uint256)' --rpc-url $RPC"
echo "  cast call $USDC 'balanceOf(address)(uint256)' $ROUTER --rpc-url $RPC"
echo "The subgraph indexes them within ~30s; front-end badge flips to LIVE."