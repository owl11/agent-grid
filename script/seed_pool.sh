#!/usr/bin/env bash
# =============================================================================
#  seed_pool.sh — First LP deposit into a fresh CapitalPool (Arc testnet).
#
#  WHY cast send (not part of `forge script Deploy.s.sol`):
#    forge simulates LOCALLY first, and Arc's USDC calls an `isBlocklisted`
#    precompile missing from the simulator — any transferFrom reverts there
#    while the chain is fine. `cast send` simulates server-side. Same reason
#    as seed_jobs.sh.
#
#  WHY first, before any job settles:
#    settlement revenue lands in the pool with no shares required. If revenue
#    precedes the first mint, pricePerShare prices astronomically and the
#    first minter captures all stranded revenue.
#    Deploy.s.sol already fronts a 1 USDC genesis deposit (resting pps at
#    exactly 1.0, supply never 0). This script is the top-up that adds real
#    liquidity beyond that, keeping the same invariants.
#
#  USAGE:
#    source .env                       # DEPLOYER_PRIVATE_KEY; CAPITAL_POOL env
#    CAPITAL_POOL=0xNewPool... ./script/seed_pool.sh [AMOUNT_USDC]
#      AMOUNT_USDC default 10 (additional liquidity; genesis already seeded)
#
#  NEEDS: deployer funded (seed + gas). No default pool — seeding a stale
#  address would lock funds in the wrong pool, so CAPITAL_POOL is required.
#  Faucet: https://faucet.circle.com
# =============================================================================
set -euo pipefail

if [ -f ".env" ]; then
  set -a; source .env; set +a
fi

cd "$(dirname "$0")/.."   # repo root regardless of cwd

RPC="${ARC_TESTNET_RPC_URL:-https://rpc.testnet.arc.io}"
USDC="0x3600000000000000000000000000000000000000"
POOL="${CAPITAL_POOL:?set CAPITAL_POOL to the fresh pool address (no default — never seed blind)}"
PK="${DEPLOYER_PRIVATE_KEY:?set DEPLOYER_PRIVATE_KEY in .env}"

AMOUNT_USDC="${1:-10}"
AMOUNT_ATOMIC=$(( AMOUNT_USDC * 1000000 ))

DEPLOYER="$(cast wallet address "$PK")"
NONCE="$(cast nonce "$DEPLOYER" --rpc-url "$RPC")"

# Preflight: Arc gas is native USDC (18dec).
GAS="$(cast balance "$DEPLOYER" --rpc-url "$RPC" | awk '{print $1}')"
if (( GAS == 0 )); then
  echo "FATAL: deployer $DEPLOYER has 0 native USDC for gas." >&2
  echo "Fund it at https://faucet.circle.com, then re-run." >&2
  exit 1
fi

echo "=== seed_pool — Arc testnet ==="
echo "  pool   : $POOL"
echo "  amount : ${AMOUNT_USDC} USDC (${AMOUNT_ATOMIC} atomic) -> $DEPLOYER"
echo

echo ">> approve(pool, ${AMOUNT_ATOMIC}) [nonce $NONCE]"
cast send "$USDC" "approve(address,uint256)(bool)" "$POOL" "$AMOUNT_ATOMIC" \
  --rpc-url "$RPC" --private-key "$PK" --nonce "$NONCE" --timeout 120 || exit 1
NONCE=$((NONCE + 1))

echo ">> deposit(${AMOUNT_ATOMIC}, deployer) [nonce $NONCE]"
cast send "$POOL" "deposit(uint256,address)(uint256)" "$AMOUNT_ATOMIC" "$DEPLOYER" \
  --rpc-url "$RPC" --private-key "$PK" --nonce "$NONCE" --timeout 120 || exit 1

echo
echo "=== verify ==="
PPS="$(cast call "$POOL" 'pricePerShare()(uint256)' --rpc-url "$RPC" | awk '{print $1}')"
TA="$(cast call "$POOL" 'totalAssets()(uint256)' --rpc-url "$RPC" | awk '{print $1}')"
echo "  pricePerShare : $PPS (expect 1000000 = exactly 1.0 USDC)"
echo "  totalAssets   : $TA atomic (expect ${AMOUNT_ATOMIC})"
# Units (do not "fix" to 1e18): pricePerShare returns asset-atomic per 1e18
# shares, and USDC has 6 decimals — so a perfect 1.0 reads 1000000, not 1e18.
# Proportional mints preserve it bit-exact from an empty start.
if [[ "$PPS" != "1000000" ]]; then
  echo "WARN: price is not exactly 1.0 — revenue may have landed before this seed. Redeploy rather than building on it." >&2
  exit 1
fi
echo "Pool seeded clean."
