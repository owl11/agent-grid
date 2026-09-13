#!/usr/bin/env bash
# =============================================================================
#  postUpkeep.sh — post ONE template upkeep task on Arc testnet (onboarding step 1).
#
#  Runs from THIS task repo (the two-window demo lives here too). It posts
#  THE same keepalive upkeep the demo has been poking all day — the mock
#  lending-pool BTC feed (specs/4.json) — with its pinned specHash, 2 USDC
#  escrow, the 0/0/0 split sentinel (regime default 9000/500/500), execDeadline
#  +1 day, approvalWindow 2h, open market. One task. Then demo worker mode:
#  open the repo root in a second window and tell the agent 'you are the
#  executor' — the SKILL.md resolves its role and runs keeper_jobs.
#
#  Creates a single createJob tx using `cast send` (NOT forge script — Arc's
#  USDC blocklist precompile breaks local fork simulation; the chain is fine,
#  the simulator is not).
#
#  USAGE:
#    ./scripts/postUpkeep.sh                   # from the task repo root
#    UPKEEP_PAYMENT_USDC=4 ./scripts/postUpkeep.sh
#
#  The originator key resolves in this order:
#    1. $ORIGINATOR_PRIVATE_KEY env   2. .env.demo in this repo (next to task.md)
#
#  NEEDS: cast (foundry), and a funded originator console key.
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

# ---- originator key resolution (never echoed) --------------------------------
extract_pk() {   # strip whitespace + surrounding quotes from a grep result
  cut -d= -f2- | tr -d " \t\"'"
}
PK=""
if [ -n "${ORIGINATOR_PRIVATE_KEY:-}" ]; then
  PK="$ORIGINATOR_PRIVATE_KEY"
elif [ -f ".env.demo" ]; then
  PK="$(grep '^ORIGINATOR_PRIVATE_KEY=' .env.demo | head -1 | extract_pk)"
fi
if [ -z "${PK:-}" ]; then
  echo "FATAL: no originator key — copy .env.demo.example to .env.demo (right next" >&2
  echo "  to task.md) and paste your ORIGINATOR_PRIVATE_KEY." >&2
  exit 1
fi
if ! [[ "$PK" =~ ^0x[0-9a-fA-F]{64}$ || "$PK" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "FATAL: ORIGINATOR_PRIVATE_KEY in .env.demo does not look like a private key" >&2
  echo "  (want 64 hex, optionally 0x-prefixed). Check the file." >&2
  exit 1
fi

command -v cast >/dev/null 2>&1 || { echo "FATAL: cast not found — install foundry-rs/foundry." >&2; exit 1; }

# ---- connection defaults ride along in the root .env.demo (next to task.md) ---
# Source it for the INFRA vars only (RPC_URL, CAPITAL_POOL); keys already
# resolved above, never echoed. Missing file = rely on the pinned demo defaults
# below (RPC is hardcoded, CAPITAL_POOL then cannot resolve → FATAL below).
# Env set by the caller (exported CAPITAL_POOL etc.) wins over the file.
if [ -f ".env.demo" ]; then
  while IFS='=' read -r key val; do
    case "$key" in
      ''|\#*) continue ;;
    esac
    val="${val%\"}"; val="${val#\"}"
    if [ "${!key+x}" != "x" ]; then export "$key=$val"; fi
  done < .env.demo
fi

# ---- pinned onchain environment (override via env after a redeploy) ----------
RPC="${ARC_TESTNET_RPC_URL:-${RPC_URL:-https://rpc.testnet.arc.io}}"
EXPLORER="${EXPLORER:-https://explorer.testnet.arc.io}"
USDC="0x3600000000000000000000000000000000000000"
ROUTER="${JOB_ROUTER:-0x3773C170F2C59ef7eB349fE27E88202f236081f0}"
POOL="${CAPITAL_POOL:?set CAPITAL_POOL in .env.demo — tasks must never settle into an unseeded pool}"
export TECH_LOG="${TECH_LOG:-/tmp/agentgrid-tech.log}"

PAYMENT_ATOMIC=$(( ${UPKEEP_PAYMENT_USDC:-2} * 1000000 ))
SPEC_HASH="0xca1a4b1b1086abf031df037c51df8b882a81f2f5aaf4ee210ae667ef48034bb2" # keccak(specs/4.json)
SPLIT="(0,0,0)"                                                             # sentinel -> 9000/500/500
now_ts="$(date +%s)"
EXEC_DEADLINE=$(( now_ts + 86400 ))
APPROVAL_WINDOW=7200
AGENT="0x0000000000000000000000000000000000000000"

echo "=== postUpkeep — one template upkeep task (Arc testnet) ==="
echo "  spec           : specs/4.json (keep the lending-pool BTC feed fresh)"
echo "  specHash       : $SPEC_HASH"
echo "  payment        : $(( PAYMENT_ATOMIC / 1000000 )) USDC escrow"
echo "  execDeadline   : $EXEC_DEADLINE (+1 day) · approvalWindow $APPROVAL_WINDOW (2h)"
echo "  designate      : open market (any bonded agent may take it)"
echo

SUPPLY="$(cast call "$POOL" 'totalSupply()(uint256)' --rpc-url "$RPC" | awk '{print $1}')"
if (( SUPPLY == 0 )); then
  echo "FATAL: pool $POOL has zero shares — the protocol pool must be seeded first." >&2
  exit 1
fi

ORIGINATOR="$(cast wallet address "$PK")"
NEXT_NONCE="$(cast nonce "$ORIGINATOR" --rpc-url "$RPC")"

echo ">> originator ${ORIGINATOR:0:6}…${ORIGINATOR: -4} · approve router $(( PAYMENT_ATOMIC / 1000000 )) USDC"
out="$(cast send "$USDC" "approve(address,uint256)(bool)" \
  "$ROUTER" "$PAYMENT_ATOMIC" \
  --rpc-url "$RPC" --private-key "$PK" --nonce "$NEXT_NONCE" --timeout 120 2>&1)" || {
  printf '%s\n' "$out" >> "$TECH_LOG"
  echo "   ✗ originator · escrow approve — tx failed, full receipt in $TECH_LOG" >&2
  exit 1
}
printf '%s\n' "$out" >> "$TECH_LOG"
HASH="$(awk '/^transactionHash/{print $2}' <<< "$out")"
echo "   ✓ approve  $EXPLORER/tx/$HASH"
NEXT_NONCE=$((NEXT_NONCE + 1))

JOB_BEFORE="$(cast call "$ROUTER" 'jobCount()(uint256)' --rpc-url "$RPC" | awk '{print $1}')"
echo ">> post the upkeep task"
out="$(cast send "$ROUTER" \
  "createJob(uint128,bytes32,(uint16,uint16,uint16),uint64,uint64,address,uint96)(uint256)" \
  "$PAYMENT_ATOMIC" "$SPEC_HASH" "$SPLIT" \
  "$EXEC_DEADLINE" "$APPROVAL_WINDOW" "$AGENT" "0" \
  --rpc-url "$RPC" --private-key "$PK" --nonce "$NEXT_NONCE" --timeout 120 2>&1)" || {
  printf '%s\n' "$out" >> "$TECH_LOG"
  echo "   ✗ originator · post upkeep task — tx failed, full receipt in $TECH_LOG" >&2
  exit 1
}
printf '%s\n' "$out" >> "$TECH_LOG"
HASH="$(awk '/^transactionHash/{print $2}' <<< "$out")"
JOB_ID=$(( JOB_BEFORE + 1 ))
echo "   ✓ task #$JOB_ID posted ($EXPLORER/tx/$HASH)"
echo
echo "══════════════════════════════════════════════════════════════════════"
echo "  upkeep task #$JOB_ID is POSTED onchain. Now demo worker mode:"
echo "    open THIS repo in a second window and tell the agent 'you are the"
echo "    executor'; the SKILL.md resolves its role and it runs keeper_jobs —"
echo "    the task surfaces once the subgraph indexes (~30s), it accepts and"
echo "    agent_poke_and_submit does the poke + submit."
echo "  Then settle it from the originator window (originator_settle)."
echo "══════════════════════════════════════════════════════════════════════"