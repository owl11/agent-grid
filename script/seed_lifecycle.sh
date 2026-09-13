#!/usr/bin/env bash
# =============================================================================
#  seed_lifecycle.sh — Run one full job lifecycle on Arc testnet (native USDC).
#
#  Bonds an agent, posts a DIRECT-HIRE keeper job to it, and drives
#  accept -> submitResult -> approve. Direct hire skips tier windows
#  (JobRouter.sol: direct-hire path), so this runs end-to-end with no waiting.
#  Every transition emits events the subgraph indexes (timing fields,
#  latency aggregates, EWMA score) — this is what fills the leaderboard.
#
#  WHY direct hire instead of an open post:
#    fresh agents are tier 0 and open posts need createdAt+W0+W1 (~20 min).
#    Direct hire exercises the identical settle path with zero waiting.
#
#  USAGE (full lifecycle — plays originator AND agent, needs both keys):
#    source .env                       # ORIGINATOR_PRIVATE_KEY + AGENT_PRIVATE_KEY
#    ./script/seed_lifecycle.sh [PAYMENT_USDC] [BOND_USDC]
#      PAYMENT_USDC default 2
#      BOND_USDC    default 10  (>= MIN_BOND 5, >= payment for accept gate)
#
#  USAGE (agent-only — just AGENT_PRIVATE_KEY, works a live open job):
#    ./script/seed_lifecycle.sh --agent-only <JOB_ID> [BOND_USDC]
#      bonds/tops-up the agent if needed, then accept -> submitResult.
#      Approval stays with the originator (or timeout-settles). Use this when
#      you only hold the agent key.
#
#  IDENTITY (both modes): bare wallet by default. For ERC-8004:
#    BOND_ADAPTER=0x476d… EXTERNAL_ID=<tokenId> ./script/seed_lifecycle.sh ...
#    The token must belong to the agent wallet (verified onchain); the
#    agentWallet-delegation pattern is out of scope — owner bonds directly.
#
#  NEEDS (full): deployer funded (escrow + gas), agent funded (bond + gas).
#  NEEDS (agent-only): agent funded (bond + gas).
#  Faucet: https://faucet.circle.com
#
#  ORACLE (optional): with ORACLE_ADDRESS set, the agent really pokes the mock
#    lending-pool feed (poke(tx) -> lastUpdated) and commits
#    keccak(txHash, postUpdateTimestamp); unset, it submits a synthetic hash
#    so any generic job still runs end-to-end.
# =============================================================================
set -euo pipefail

if [ -f ".env" ]; then
  set -a; source .env; set +a
fi
# Demo mode (onboard.sh): demo wallets override the canonical originator/agent.
if [ -f ".env.demo" ] && [ "${AGENTGRID_DEMO_KEYS:-0}" = "1" ]; then
  set -a; source .env.demo; set +a
fi

MODE="full"; JOB_ID=""
if [[ "${1:-}" == "--agent-only" ]]; then
  MODE="agent"
  JOB_ID="${2:?usage: seed_lifecycle.sh --agent-only <JOB_ID> [BOND_USDC]}"
  BOND_USDC="${3:-10}"
fi

cd "$(dirname "$0")/.."   # repo root: resolves ../specs + script/ regardless of cwd

RPC="${ARC_TESTNET_RPC_URL:-https://rpc.testnet.arc.io}"
USDC="0x3600000000000000000000000000000000000000"
# Pinned to the canonical deployment — override via env after a redeploy.
ROUTER="${JOB_ROUTER:-0xA4B7f0a1E650318CAe82a64902D1104466DE6ea0}"
REGISTRY="${AGENT_REGISTRY:-0x3Df83475b24fAF980E13105550790556B23480a5}"
POOL="${CAPITAL_POOL:?set CAPITAL_POOL (canonical pool) — jobs must never settle into an unseeded pool}"
EXPLORER="${EXPLORER:-https://explorer.testnet.arc.io}"
export TECH_LOG="${TECH_LOG:-/tmp/agentgrid-tech.log}"   # full receipts land here, never stdout
ORIG_PK=""; ORIGIN=""; ONONCE=0
AGENT_PK="${AGENT_PRIVATE_KEY:?set AGENT_PRIVATE_KEY in .env}"
if [[ "$MODE" == "full" ]]; then
  # Originator is deliberately NOT the deployer: deployer = protocol ops,
  # originator = the party posting escrow. Falls back to deployer if unset.
  ORIG_PK="${ORIGINATOR_PRIVATE_KEY:?full mode needs ORIGINATOR_PRIVATE_KEY (deployer key is retired) — or use --agent-only <JOB_ID> with just the agent key}"
  PAYMENT_USDC="${1:-2}"
  BOND_USDC="${2:-10}"
fi
if [[ "$MODE" == "full" ]]; then
  PAYMENT_ATOMIC=$(( PAYMENT_USDC * 1000000 ))
else
  PAYMENT_ATOMIC=0
fi
BOND_ATOMIC=$(( BOND_USDC * 1000000 ))
SPLIT="(0,0,0)"   # sentinel -> regime default (9000/500/500, gates OFF)

now_ts="$(date +%s)"
EXEC_DEADLINE=$(( now_ts + 86400 ))
APPROVAL_WINDOW=7200

AGENT="$(cast wallet address "$AGENT_PK")"
ANONCE="$(cast nonce "$AGENT" --rpc-url "$RPC")"
WALLETS=("agent:$AGENT")
if [[ "$MODE" == "full" ]]; then
  ORIGIN="$(cast wallet address "$ORIG_PK")"
  ONONCE="$(cast nonce "$ORIGIN" --rpc-url "$RPC")"
  WALLETS+=("originator:$ORIGIN")
fi

# Preflight: Arc gas is native USDC (18dec) — estimation fails with -32000
# "gas required exceeds allowance (0)" when the sender holds no native balance.
# Check BEFORE any send so the failure names the faucet, not a revert.
for WHO in "${WALLETS[@]}"; do
  ROLE="${WHO%%:*}"; ADDR="${WHO##*:}"
  # cast pretty-prints large uints as "<value> [1eN]" — strip the annotation.
  GAS="$(cast balance "$ADDR" --rpc-url "$RPC" | awk '{print $1}')"
  if (( GAS == 0 )); then
    echo "FATAL: $ROLE wallet $ADDR has 0 native USDC for gas." >&2
    echo "Fund it at https://faucet.circle.com, then re-run." >&2
    exit 1
  fi
done

if [[ "$MODE" == "full" ]]; then
# specHash commits to the real keeper spec file (on-chain provenance).
SPECHASH="$(cast keccak "$(cat specs/4.json)")"
# Next job id = current count + 1 (demo chain: no concurrent creators).
NEXT_ID="$(cast call "$ROUTER" 'jobCount()(uint256)' --rpc-url "$RPC" | awk '{print $1}')"
NEXT_ID=$(( NEXT_ID + 1 ))

echo "=== seed_lifecycle — Arc testnet ==="
echo "  originator : $ORIGIN"
echo "  agent      : $AGENT"
echo "  job #${NEXT_ID} : ${PAYMENT_USDC} USDC direct hire, spec oracle-poke (${SPECHASH:0:18}…)"
echo "  bond       : ${BOND_USDC} USDC"
echo
fi

send() { # send <role·action> <key> <to> <sig> [args...] — one labelled ✓ line
  local label="$1"; local key="$2"; shift 2
  local out hash
  out="$(cast send "$@" --rpc-url "$RPC" --private-key "$key" --timeout 120 2>&1)" || {
    printf '%s\n' "$out" >> "$TECH_LOG"
    echo "   ✗ $label — transaction failed, full receipt in $TECH_LOG. Re-run after checking it." >&2
    exit 1
  }
  printf '%s\n' "$out" >> "$TECH_LOG"
  hash="$(awk '/^transactionHash/{print $2}' <<< "$out")"
  echo "   ✓ $label  $EXPLORER/tx/$hash"
}

# Mock lending-pool BTC feed (specs/4.json). Optional: when set, the agent
# really pokes the feed and commits the real poke tx.
ORACLE="${ORACLE_ADDRESS:-}"
POKE_VALUE="${ORACLE_POKE_VALUE:-420000}"

# Poke the oracle as the assigned agent and commit: RESULT = keccak256(
# "<pokeTxHash>:<postUpdateTimestamp>"). Generic jobs (no oracle set) fall
# back to a synthetic hash so the lifecycle still runs end-to-end.
post_result() { # <label>
  local label="$1" poke_tx post_ts out
  if [[ -n "$ORACLE" ]]; then
    out="$(cast send "$ORACLE" "poke(uint256)" "$POKE_VALUE" --rpc-url "$RPC" --private-key "$AGENT_PK" --nonce "$ANONCE" --timeout 120 --json 2>&1)" || {
      printf '%s\n' "$out" >> "$TECH_LOG"
      echo "   ✗ poke failed — full receipt in $TECH_LOG." >&2
      exit 1
    }
    printf '%s\n' "$out" >> "$TECH_LOG"
    poke_tx="$(sed -nE 's/.*"(transactionHash|hash)":"(0x[0-9a-fA-F]+)".*/\2/p' <<< "$out" | head -1)"
    ANONCE=$((ANONCE + 1))   # the poke consumed the agent nonce we tracked
    [[ -n "$poke_tx" ]] || { echo "FATAL: could not parse poke tx hash from cast send" >&2; exit 1; }
    post_ts="$(cast call "$ORACLE" 'lastUpdated()(uint256)' --rpc-url "$RPC" | awk '{print $1}')"
    RESULT="$(cast keccak "${poke_tx#0x}:${post_ts}")"   # strip 0x so cast treats it as ASCII
    echo "   ✓ agent · poke feed (${POKE_VALUE}) — feed now ${post_ts}  $EXPLORER/tx/$poke_tx"
  else
    RESULT="$(cast keccak "keeper-demo-result-${label}")"
    echo ">> [agent] ORACLE_ADDRESS unset — synthetic result"
  fi
}

# Feed-age stamp for oracle-poke runs (no-op without ORACLE_ADDRESS).
feed_status() {
  local last now age fresh
  if [[ -n "$ORACLE" ]]; then
    last="$(cast call "$ORACLE" 'lastUpdated()(uint256)' --rpc-url "$RPC" | awk '{print $1}')"
    now="$(date +%s)"
    age=$(( now - last ))
    if (( age <= 3600 )); then fresh="fresh"; else fresh="STALE"; fi
    echo "   feed ${ORACLE:0:10}… : lastUpdated ${last} (age ${age}s, threshold 3600s) → ${fresh}"
  fi
}

echo ">> [agent] bond check"
EXISTING_BOND="$(cast call "$REGISTRY" 'bondOf(address)(uint256)' "$AGENT" --rpc-url "$RPC" | awk '{print $1}')"
echo "   existing bond: $(( EXISTING_BOND / 1000000 )) USDC (need ${BOND_USDC})"
# Identity: bare wallet by default; set EXTERNAL_ID (+ BOND_ADAPTER) to bind
# the bond to an Arc IdentityRegistry NFT. The adapter verifies the *owner* —
# operator/agentWallet delegation is out of scope (see SKILL.md).
ADAPTER="${BOND_ADAPTER:-0x0000000000000000000000000000000000000000}"
EXT_ID="${EXTERNAL_ID:-0}"
if (( EXT_ID > 0 )) && [[ "$ADAPTER" == "0x0000000000000000000000000000000000000000" ]]; then
  echo "FATAL: EXTERNAL_ID set but BOND_ADAPTER is zero — deploy the adapter first (see README)." >&2
  exit 1
fi
[[ "$EXT_ID" == "0" ]] && IDMODE="bare wallet" || IDMODE="8004 #$EXT_ID via ${ADAPTER:0:10}…"
echo "   identity: $IDMODE"
if (( EXISTING_BOND >= BOND_ATOMIC )); then
  echo "   already bonded — skipping approve + bondIn (bondIn reverts AlreadyBonded)."
else
  DELTA=$(( BOND_ATOMIC - EXISTING_BOND ))
  send "agent · approve registry" "$AGENT_PK" "$USDC" "approve(address,uint256)(bool)" "$REGISTRY" "$DELTA" --nonce "$ANONCE"; ANONCE=$((ANONCE + 1))
  if (( EXISTING_BOND == 0 )); then
    send "agent · bond (post ${DELTA} USDC)" "$AGENT_PK" "$REGISTRY" "bondIn(address,uint256,uint256)" "$ADAPTER" "$EXT_ID" "$DELTA" --nonce "$ANONCE"; ANONCE=$((ANONCE + 1))
  else
    send "agent · addBond (top up ${DELTA} USDC)" "$AGENT_PK" "$REGISTRY" "addBond(uint256)" "$DELTA" --nonce "$ANONCE"; ANONCE=$((ANONCE + 1))
  fi
fi

if [[ "$MODE" == "agent" ]]; then
  echo "=== seed_lifecycle --agent-only (job #${JOB_ID}) ==="
  echo "  agent : $AGENT"
  echo
  CAN="$(cast call "$ROUTER" 'canAccept(uint256,address)(bool)' "$JOB_ID" "$AGENT" --rpc-url "$RPC")"
  if [[ "$CAN" != "true" ]]; then
    echo "FATAL: canAccept(#${JOB_ID}, agent) = false." >&2
    echo "The job isn't POSTED, its tier window hasn't opened, your bond is below" >&2
    echo "its payment, or the agent is ineligible (pending exit / debt lock)." >&2
    exit 1
  fi
  echo "   canAccept(#${JOB_ID}, agent) = true — gate open"
  send "agent · accept #${JOB_ID}" "$AGENT_PK" "$ROUTER" "accept(uint256)" "$JOB_ID" --nonce "$ANONCE"; ANONCE=$((ANONCE + 1))

  post_result "$JOB_ID"
  send "agent · submit #${JOB_ID}" "$AGENT_PK" "$ROUTER" "submitResult(uint256,bytes32)" "$JOB_ID" "$RESULT" --nonce "$ANONCE"; ANONCE=$((ANONCE + 1))

  feed_status
  echo
  echo "=== submitted job #${JOB_ID} — approval stays with the originator ==="
  echo "It settles on approve, or anyone can timeout-settle after the approval window."
  echo "Subgraph index: http://explorer.testnet.arc.io  (all txs above are live on Arc)"
  exit 0
fi

# Genesis guard (full mode posts): refuse if the pool has no shares — revenue
# settling into an empty pool imprints a distorted genesis price permanently.
# Run ./script/seed_pool.sh first.
SUPPLY="$(cast call "$POOL" 'totalSupply()(uint256)' --rpc-url "$RPC" | awk '{print $1}')"
if (( SUPPLY == 0 )); then
  echo "FATAL: pool $POOL has zero shares — seed it first:" >&2
  echo "  CAPITAL_POOL=$POOL ./script/seed_pool.sh 10" >&2
  exit 1
fi
send "originator · approve router (${PAYMENT_USDC} USDC escrow)" "$ORIG_PK" "$USDC" "approve(address,uint256)(bool)" "$ROUTER" "$PAYMENT_ATOMIC" --nonce "$ONONCE"; ONONCE=$((ONONCE + 1))

send "originator · direct-hire #${NEXT_ID}" "$ORIG_PK" "$ROUTER" \
  "createJob(uint128,bytes32,(uint16,uint16,uint16),uint64,uint64,address,uint96)(uint256)" \
  "$PAYMENT_ATOMIC" "$SPECHASH" "$SPLIT" \
  "$EXEC_DEADLINE" "$APPROVAL_WINDOW" "$AGENT" "0" \
  --nonce "$ONONCE"; ONONCE=$((ONONCE + 1))

send "agent · accept #${NEXT_ID}" "$AGENT_PK" "$ROUTER" "accept(uint256)" "$NEXT_ID" --nonce "$ANONCE"; ANONCE=$((ANONCE + 1))

post_result "$NEXT_ID"
send "agent · submit #${NEXT_ID}" "$AGENT_PK" "$ROUTER" "submitResult(uint256,bytes32)" "$NEXT_ID" "$RESULT" --nonce "$ANONCE"; ANONCE=$((ANONCE + 1))

send "originator · approve #${NEXT_ID} (settles 9000/500/500)" "$ORIG_PK" "$ROUTER" "approve(uint256)" "$NEXT_ID" --nonce "$ONONCE"; ONONCE=$((ONONCE + 1))

feed_status
echo
echo "=== job #${NEXT_ID} is SETTLED — the subgraph indexes it within ~30s ==="
echo "Every tx above is live on Arc: $EXPLORER"
