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
#    source .env                       # exports ORIGINATOR_PRIVATE_KEY
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
# Demo mode (onboard.sh): demo originator posts the market-color escrow.
if [ -f ".env.demo" ] && [ "${AGENTGRID_DEMO_KEYS:-0}" = "1" ]; then
  set -a; source .env.demo; set +a
fi

RPC="${ARC_TESTNET_RPC_URL:-https://rpc.testnet.arc.io}"
EXPLORER="${EXPLORER:-https://explorer.testnet.arc.io}"
export TECH_LOG="${TECH_LOG:-/tmp/agentgrid-tech.log}"   # full receipts land here, never stdout
USDC="0x3600000000000000000000000000000000000000"   # Arc native USDC ERC-20 view (6 dp)
# Pinned to the canonical deployment — override via env after a redeploy.
ROUTER="${JOB_ROUTER:-0xA4B7f0a1E650318CAe82a64902D1104466DE6ea0}" # canonical JobRouter (redeploy #4)
POOL="${CAPITAL_POOL:?set CAPITAL_POOL (canonical pool) — jobs must never settle into an unseeded pool}"
# Originator posts escrow — deliberately NOT the deployer (protocol ops).
# Falls back to deployer if ORIGINATOR_PRIVATE_KEY is unset.
PK="${ORIGINATOR_PRIVATE_KEY:?set ORIGINATOR_PRIVATE_KEY in .env (deployer key is retired — originator posts escrow)}"

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
# No address fallback: a failed derivation aborts loudly instead of
# posting escrow from a stale hard-coded wallet.
ORIGINATOR="$(cast wallet address "$PK")"
NEXT_NONCE="$(cast nonce "$ORIGINATOR" --rpc-url "$RPC")"

# Genesis guard: refuse to post if the pool has no shares. Settlement revenue
# landing in an empty pool strands value and imprints a distorted genesis
# price permanently (proportional deposits preserve it — it never washes out).
# Run ./script/seed_pool.sh first; it pins pricePerShare at exactly 1.0.
SUPPLY="$(cast call "$POOL" 'totalSupply()(uint256)' --rpc-url "$RPC" | awk '{print $1}')"
if (( SUPPLY == 0 )); then
  echo "FATAL: pool $POOL has zero shares — seed it first:" >&2
  echo "  CAPITAL_POOL=$POOL ./script/seed_pool.sh 10" >&2
  exit 1
fi

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
  # AWAIT the approve (no --async): createJob's gas-estimate must see the
  # allowance already on-chain, else it reverts ERC20: transfer amount exceeds
  # allowance the instant the RPC estimates before the approve mines.
  out="$(cast send "$USDC" \
    "approve(address,uint256)(bool)" \
    "$ROUTER" "$TOTAL_ATOMIC" \
    --rpc-url "$RPC" --private-key "$PK" --nonce "$NEXT_NONCE" --timeout 120 2>&1)" || {
    printf '%s\n' "$out" >> "$TECH_LOG"
    echo "   ✗ originator · escrow approve — tx failed, full receipt in $TECH_LOG. Re-run after checking it." >&2
    exit 1
  }
  printf '%s\n' "$out" >> "$TECH_LOG"
  hash="$(awk '/^transactionHash/{print $2}' <<< "$out")"
  echo "   ✓ originator · escrow approve $(( TOTAL_ATOMIC / 1000000 )) USDC  $EXPLORER/tx/$hash"
  NEXT_NONCE=$((NEXT_NONCE + 1))
else
  echo ">> resume mode — skipping approve (allowance already granted)"
fi

# ---- 2) create COUNT open-post jobs (from START) ----------------------------
BASE_JOB="$(cast call "$ROUTER" 'jobCount()(uint256)' --rpc-url "$RPC" | awk '{print $1}')"
for (( i=START; i<=COUNT; i++ )); do
  JOB_ID=$(( BASE_JOB + i - START + 1 ))
  # deterministic per-job specHash (on-chain provenance string)
  SPEC=$(printf 'seed-job-%d' "$i")
  SPECHASH=$(cast keccak "$SPEC")
  HASH="$(cast send "$ROUTER" \
    "createJob(uint128,bytes32,(uint16,uint16,uint16),uint64,uint64,address,uint96)(uint256)" \
    "$PAYMENT_ATOMIC" "$SPECHASH" "$SPLIT" \
    "$EXEC_DEADLINE" "$APPROVAL_WINDOW" \
    "0x0000000000000000000000000000000000000000" \
    "0" \
    --rpc-url "$RPC" --private-key "$PK" --nonce "$NEXT_NONCE" --async 2>/dev/null)" || {
      printf 'createJob #%s failed at nonce %s\n' "$i" "$NEXT_NONCE" >> "$TECH_LOG"
      echo "   ✗ originator · post job #$i failed at nonce $NEXT_NONCE — see $TECH_LOG" >&2
      exit 1
    }
  echo "   ✓ originator · post job #${JOB_ID}  $EXPLORER/tx/${HASH}"
  NEXT_NONCE=$((NEXT_NONCE + 1))
  sleep 0.3   # keep a beat between async sends (some RPCs enqueue, some 429)
done

echo
echo "=== ${COUNT} job(s) queued — subgraph indexes them within ~30s ==="
echo "Explorer: $EXPLORER   (click any tx hash above)"