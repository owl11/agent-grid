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
# =============================================================================
set -euo pipefail

if [ -f ".env" ]; then
  set -a; source .env; set +a
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

send() { # send <key> <nonce-var> <to> <sig> [args...] — sync, waits for receipt
  local key="$1"; shift
  cast send "$@" --rpc-url "$RPC" --private-key "$key" --timeout 120 || exit 1
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
  echo ">> [agent] approve registry ${DELTA}"
  send "$AGENT_PK" "$USDC" "approve(address,uint256)(bool)" "$REGISTRY" "$DELTA" --nonce "$ANONCE"; ANONCE=$((ANONCE + 1))
  if (( EXISTING_BOND == 0 )); then
    echo ">> [agent] bondIn(${ADAPTER}, ${EXT_ID}, ${DELTA})"
    send "$AGENT_PK" "$REGISTRY" "bondIn(address,uint256,uint256)" "$ADAPTER" "$EXT_ID" "$DELTA" --nonce "$ANONCE"; ANONCE=$((ANONCE + 1))
  else
    echo ">> [agent] addBond(${DELTA}) — topping up to ${BOND_USDC}"
    send "$AGENT_PK" "$REGISTRY" "addBond(uint256)" "$DELTA" --nonce "$ANONCE"; ANONCE=$((ANONCE + 1))
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
  echo ">> [agent] accept(${JOB_ID}) — gate open"
  send "$AGENT_PK" "$ROUTER" "accept(uint256)" "$JOB_ID" --nonce "$ANONCE"; ANONCE=$((ANONCE + 1))

  RESULT="$(cast keccak "keeper-demo-result-${JOB_ID}")"
  echo ">> [agent] submitResult(${JOB_ID}, ${RESULT:0:18}…)"
  send "$AGENT_PK" "$ROUTER" "submitResult(uint256,bytes32)" "$JOB_ID" "$RESULT" --nonce "$ANONCE"; ANONCE=$((ANONCE + 1))

  echo
  echo "=== submitted job #${JOB_ID} — approval stays with the originator ==="
  echo "It settles on approve, or anyone can timeout-settle after the approval window."
  echo "Watch it index (~30s):"
  echo "  SUBGRAPH_URL=\"https://api.studio.thegraph.com/query/1758789/job-router/0.0.5\" \\"
  echo "    node -e 'fetch(process.env.SUBGRAPH_URL,{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},body:JSON.stringify({query:\"{ job(id: \\\"${JOB_ID}\\\") { state outcome assignedWallet resultHash submittedAt } }\"})}).then(r=>r.json()).then(j=>console.log(JSON.stringify(j.data.job)))'"
  exit 0
fi

echo ">> [origin] approve router ${PAYMENT_ATOMIC}"
# Genesis guard (full mode posts): refuse if the pool has no shares — revenue
# settling into an empty pool imprints a distorted genesis price permanently.
# Run ./script/seed_pool.sh first.
SUPPLY="$(cast call "$POOL" 'totalSupply()(uint256)' --rpc-url "$RPC" | awk '{print $1}')"
if (( SUPPLY == 0 )); then
  echo "FATAL: pool $POOL has zero shares — seed it first:" >&2
  echo "  CAPITAL_POOL=$POOL ./script/seed_pool.sh 10" >&2
  exit 1
fi
send "$ORIG_PK" "$USDC" "approve(address,uint256)(bool)" "$ROUTER" "$PAYMENT_ATOMIC" --nonce "$ONONCE"; ONONCE=$((ONONCE + 1))

echo ">> [origin] createJob(#${NEXT_ID}, direct hire)"
send "$ORIG_PK" "$ROUTER" \
  "createJob(uint128,bytes32,(uint16,uint16,uint16),uint64,uint64,address,uint96)(uint256)" \
  "$PAYMENT_ATOMIC" "$SPECHASH" "$SPLIT" \
  "$EXEC_DEADLINE" "$APPROVAL_WINDOW" "$AGENT" "0" \
  --nonce "$ONONCE"; ONONCE=$((ONONCE + 1))

echo ">> [agent] accept(${NEXT_ID})"
send "$AGENT_PK" "$ROUTER" "accept(uint256)" "$NEXT_ID" --nonce "$ANONCE"; ANONCE=$((ANONCE + 1))

RESULT="$(cast keccak "keeper-demo-result-${NEXT_ID}")"
echo ">> [agent] submitResult(${NEXT_ID}, ${RESULT:0:18}…)"
send "$AGENT_PK" "$ROUTER" "submitResult(uint256,bytes32)" "$NEXT_ID" "$RESULT" --nonce "$ANONCE"; ANONCE=$((ANONCE + 1))

echo ">> [origin] approve(${NEXT_ID}) — settles 9000/500/500"
send "$ORIG_PK" "$ROUTER" "approve(uint256)" "$NEXT_ID" --nonce "$ONONCE"; ONONCE=$((ONONCE + 1))

echo
echo "=== settled job #${NEXT_ID} — subgraph indexes within ~30s ==="
echo "Verify with:"
echo "  SUBGRAPH_URL=\"https://api.studio.thegraph.com/query/1758789/job-router/0.0.3\" \\"
  echo "    node -e 'fetch(process.env.SUBGRAPH_URL,{method:\"POST\",headers:{\"Content-Type\":\"application/json\"},body:JSON.stringify({query:\"{ job(id: \\\"${NEXT_ID}\\\") { state outcome executorPaid lpPaid treasuryPaid submittedAt settledAt } }\"})}).then(r=>r.json()).then(j=>console.log(JSON.stringify(j.data.job)))'"
