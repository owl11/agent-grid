#!/usr/bin/env bash
# =============================================================================
#  onboard.sh — AgentGrid PRE-DEMO setup on Arc testnet.
#
#  This is what you run BEFORE the demo, not the demo itself. You arrive with
#  nothing; it mints the demo originator + agent wallets, holds your hand through
#  the faucet drip, seeds the CapitalPool LP position, and writes the task repo's
#  .env.demo (gitignored). When it exits you have everything the two-window
#  demo needs:
#
#    1. wallets    — fresh demo pair minted + funded (keys in my_job/.env.demo)
#    2. LP         — originator deposits USDC into the CapitalPool (seeded)
#    3. handoff    — keys written straight into the task repo's .env.demo
#
#  THE DEMO ITSELF is TWO WINDOWS on the task repo (one shared skill; the role
#  — originator / executor — is assigned in each window's prompt):
#     my_job/scripts/postUpkeep.sh      the originator posts the upkeep task
#     my_job (window B)                 the executor: keeper_jobs -> accept ->
#                                       poke + submit (agent_poke_and_submit)
#     originator window                 settles (originator_settle)
#    see ONBOARDING.md. 
#
#  NO AGENT AVAILABLE? `--demo` plays the WHOLE loop scripted (bond -> accept ->
#  poke -> submit -> approve, every step a real tx) — the pre-agent fallback for
#  rehearsal/recording. Every step everywhere is a real transaction.
#
#  Funding — faucet only:
#    The two fresh demo wallets are printed with the exact USDC amount to
#    drip each at https://faucet.circle.com (Arc gas IS USDC, so one drip
#    covers spend + gas), then the script polls until both transfers land.
#    The script NEVER moves funds from any key you hold.
#
#  USAGE:
#    ./script/onboard.sh                       # PRE-DEMO: mint + fund + LP seed,
#                                              #   wire keys, hand off (interactive
#                                              #   Enter pacing)
#    ./script/onboard.sh --auto                # same, hands-free (recording)
#    ./script/onboard.sh --keys-only           # mint TWO fresh demo keys ONLY into
#                                              #   the task-repo subdir (default
#                                              #   ./my_job, override DEMO_JOB_REPO),
#                                              #   write them to <repo>/.env.demo,
#                                              #   print addresses, exit. Never seeds
#                                              #   keys from the root .env (root .env
#                                              #   is an OPTIONAL dev override — the
#                                              #   script defaults to the deployed
#                                              #   constants without it). No tx,
#                                              #   no funding, no deposit.
#    ./script/onboard.sh --mcp                 # DRY-RUN: print the Cursor/Claude
#                                              #   Code mcpServers JSON block for
#                                              #   this machine (absolute paths +
#                                              #   live onchain defaults). No tx,
#                                              #   no mint, no funding — just the
#                                              #   config to paste. The .env.demo
#                                              #   path is shown so you can run
#                                              #   --mcp before keys are wired
#                                              #   (the server reads them at runtime).
#    ./script/onboard.sh --deposit [AMOUNT]    # LP seed ONLY, then stop (funds
#                                              #   just the LP wallet). Default
#                                              #   cash-in 50 USDC.
#    ./script/onboard.sh --position            # LP snapshot vs live pps — rerun
#                                              #   after each agent cycle to watch
#                                              #   yield grow.
#    ./script/onboard.sh --demo                # NO-AGENT FALLBACK: the full
#    ./script/onboard.sh --demo --auto         #        3-role loop, fully scripted
#    set DEMO_DEPOSIT_USDC, DEMO_OPEN_JOBS, DEMO_JOB_USDC, DEMO_BOND_USDC to
#    override the demo budget (defaults: 6 / 1 / 2 / 7). DEMO_FRESH_WALLETS=1
#    mints a brand-new demo pair (previous keys archived). DEMO_JOB_REPO=<path>
#    points the key-wiring step at a specific task repo (default: ./my_job).
#
#  NEEDS: cast (foundry), python3, node (for the subgraph verify read).
# =============================================================================
set -euo pipefail

AUTO=0
FULL_DEMO=0
DEPOSIT_ONLY=0
DEPOSIT_ARG=""
POSITION_ONLY=0
KEYS_ONLY=0
MCP=0
for a in "$@"; do
  case "$a" in
    --auto) AUTO=1 ;;
    --demo) FULL_DEMO=1 ;;
    --position) POSITION_ONLY=1 ;;
    --deposit) DEPOSIT_ONLY=1 ;;
    --deposit=*) DEPOSIT_ONLY=1; DEPOSIT_ARG="${a#--deposit=}" ;;
                    --keys-only) KEYS_ONLY=1 ;;
    --mcp) MCP=1 ;;
    *)
      if (( DEPOSIT_ONLY )) && [[ -z "$DEPOSIT_ARG" ]] && [[ "$a" =~ ^[0-9]+$ ]]; then
        DEPOSIT_ARG="$a"
      else
        echo "unknown arg: $a" >&2; exit 1
      fi ;;
  esac
done

cd "$(dirname "$0")/.."
if [ -f ".env" ]; then set -a; source .env; set +a; fi
export ORACLE_ADDRESS="${ORACLE_ADDRESS:-0x24F74B5B4a613d38E4926c9E54C1162ec4a840A0}"
command -v cast >/dev/null 2>&1 || { echo "FATAL: cast not found — install foundry-rs/foundry." >&2; exit 1; }
# where the demo keys get wired — resolved before the keys-only path so it can
# mint into <JOBREPO>/.env.demo without touching the root .env for keys.
JOBREPO="${DEMO_JOB_REPO:-${PWD}/my_job}"
DEMO_ENV="$JOBREPO/.env.demo"
# The task repo (default ./my_job, override DEMO_JOB_REPO) is the ONLY home for
# the demo keys + task. No root-.env hunting, no silent mkdir — if it isn't
# here, ASK: copy the template, or re-run pointing at where you placed it.
ensure_jobrepo() {
  [ -d "$JOBREPO" ] && return
  echo "  no task repo at $JOBREPO (that's where the demo keys + task live)."
  if (( ! AUTO )) && [ -t 0 ]; then
    read -r -p "  copy template/my-job to $JOBREPO now? [Y/n]  (N = I placed it elsewhere → set DEMO_JOB_REPO=) " _ans
  else
    _ans="Y"   # --auto / piped: materialize the template, keep moving
  fi
  case "${_ans:-Y}" in
    ""|Y|y|[Yy]*) cp -r template/my-job "$JOBREPO" ;;
    *) echo "  ok — re-run with DEMO_JOB_REPO=<your-repo-path>." >&2; exit 1 ;;
  esac
}
ensure_jobrepo
# infra constants needed even by the keys-only path (to write <JOBREPO>/.env.demo)
RPC="${ARC_TESTNET_RPC_URL:-https://rpc.testnet.arc.io}"
# Deployed pool is a public testnet constant (same value as .env.example /
# ONBOARDING.md's MCP config) — a fresh machine needs NO root .env for key
# minting; the demo pair lands only in <JOBREPO>/.env.demo. Root .env stays
# an optional dev override (custom deployments, subgraph creds).
POOL="${CAPITAL_POOL:-0xB399B1bC57187B307098549e5340a4bFa2bAF3B1}"


new_key() {   # cast wallet new --json -> bare private key. Newer foundry (v1.8+)
              # wraps the payload in an envelope {"data": [...], success, ...};
              # older versions emit the bare list. Handle both; fail loudly with
              # the keys we saw on anything else (fresh-machine version skew
              # should diagnose itself, not die on a bare KeyError).
  cast wallet new --json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
if isinstance(d,dict) and "data" in d:
    d=d["data"]   # foundry v1.8+ envelope
row=d[0] if isinstance(d,list) and d else d
if not isinstance(row,dict):
    sys.stderr.write("new_key: unrecognized cast wallet JSON (top-level %s) — check foundry version\n" % type(d).__name__)
    sys.exit(1)
key=row.get("private_key") or row.get("privateKey")
if not key:
    sys.stderr.write("new_key: unrecognized cast wallet JSON (keys=%s) — check foundry version\n" % sorted(row))
    sys.exit(1)
print(key)'
}

# ---- keys-only: mint two fresh demo keys into the task-repo subdir, exit --------
# The task repo (default ./my_job, override via DEMO_JOB_REPO / JOBREPO) is the
# only home for the demo pair. The root .env is NEVER used to seed these keys —
# and is not even required anymore: infra constants (pool/router/registry/RPC)
# default to the deployed testnet values, so this path works on a bare clone.
# keys-only always mints fresh, writes ORIGINATOR_PRIVATE_KEY + AGENT_PRIVATE_KEY
# into <JOBREPO>/.env.demo, prints both addresses, and exits.
if (( KEYS_ONLY )); then
  ORIG_PK="$(new_key)"
  AGENT_PK="$(new_key)"
  DEMO_WALLET="$(cast wallet address "$ORIG_PK")"
  AGENT_ADDR="$(cast wallet address "$AGENT_PK")"
  printf 'ORIGINATOR_PRIVATE_KEY=%s\nAGENT_PRIVATE_KEY=%s\nCAPITAL_POOL=%s\nRPC_URL="%s"\n' \
    "$ORIG_PK" "$AGENT_PK" "$POOL" "$RPC" > "$DEMO_ENV"
  echo
  echo "  minted two new keys into $DEMO_ENV (gitignored)"
  echo "    originator : $DEMO_WALLET"
  echo "    agent      : $AGENT_ADDR"
  echo
  echo "  NOW: paste each address below into https://faucet.circle.com (Arc testnet)"
  echo "  and drip BOTH — Arc gas IS USDC, so one drip per wallet covers spend + gas."
  echo "  Then re-run WITHOUT --keys-only to fund + seed the LP position, or continue"
  echo "  with the two-window demo (see ONBOARDING.md)."
  echo
  echo "    faucet: https://faucet.circle.com"
  echo "    originator : $DEMO_WALLET"
  echo "    agent      : $AGENT_ADDR"
  echo
  echo "  (root .env was NOT used for these keys — only infra constants come from it)"
  echo
  exit 0
fi

# ---- deployed testnet constants (public; override via root .env) ------------
# Same values as .env.example / ONBOARDING.md's MCP config. Every one defaults
# to the shared testnet deployment, so a fresh machine runs the script with no
# root .env at all; the root .env is an OPTIONAL dev override (custom deploys,
# subgraph creds) — never a source of demo keys (those are minted fresh below
# into <JOBREPO>/.env.demo).
USDC="0x3600000000000000000000000000000000000000"
ROUTER="${JOB_ROUTER:-0x3773C170F2C59ef7eB349fE27E88202f236081f0}"
REGISTRY="${AGENT_REGISTRY:-0x9f5405afFda2Ba5A47851a8a9A30b7F9DFAE4A50}"
ORACLE="$ORACLE_ADDRESS"
SUBGRAPH="${SUBGRAPH_URL:-https://api.studio.thegraph.com/query/1758789/job-router/0.0.6}"
CHAIN="${CHAIN_ID:-5042002}"
EXPLORER="${EXPLORER:-https://explorer.testnet.arc.io}"
export TECH_LOG="${TECH_LOG:-/tmp/agentgrid-tech.log}"   # full receipts, never stdout

# ---- --mcp: dry-run. Print the Cursor/Claude Code mcpServers block for this
# machine (absolute paths, live onchain defaults) and exit. No tx, no mint.
# The .env.demo path is shown so users can paste this config BEFORE running
# --keys-only — the MCP server reads the keys at runtime, not at config time.
if (( MCP )); then
  if [ ! -d "$JOBREPO" ]; then
    echo "  (note: no task repo at $JOBREPO yet — run ./script/onboard.sh first or"
    echo "   set DEMO_JOB_REPO=<path>. The .env.demo path below will be <repo>/.env.demo.)"
  fi
    MCP_JS="$PWD/subgraph/mcp/src/index.js"
  echo
  echo "=== >>> paste this into your Cursor / Claude Code mcpServers config file <<<"
  echo
  cat <<EOF
{
  "mcpServers": {
    "agent-grid": {
      "command": "node",
      "args": ["$MCP_JS"],
      "env": {
        "SUBGRAPH_URL": "$SUBGRAPH",
        "JOB_ROUTER": "$ROUTER",
        "AGENT_REGISTRY": "$REGISTRY",
        "CAPITAL_POOL": "$POOL",
        "CREDIT_LINE": "0x060c68A7E696aa88D5d7aB37722681BD1894B783",
        "USDC_TOKEN": "$USDC",
        "ORACLE_ADDRESS": "$ORACLE",
        "CHAIN_ID": "$CHAIN",
        "RPC_URL": "$RPC",
        "ORIGINATOR_ENV_FILE": "$DEMO_ENV",
        "AGENT_ENV_FILE": "$DEMO_ENV"
      }
    }
  }
}
EOF
  echo "  (keys: ORIGINATOR_PRIVATE_KEY + AGENT_PRIVATE_KEY are read by the server from $DEMO_ENV at runtime — never paste them here.)"
  echo
  exit 0
fi


DEPOSIT_USDC="${DEMO_DEPOSIT_USDC:-6}"
OPEN_JOBS="${DEMO_OPEN_JOBS:-1}"
JOB_USDC="${DEMO_JOB_USDC:-2}"
BOND_USDC="${DEMO_BOND_USDC:-7}"
if (( DEPOSIT_ONLY )); then
  # deposit-only mode: open the LP position and stop. Default cash-in is 50
  # USDC (a chunky position so each 5% settlement slice visibly moves pps);
  # override with --deposit <amount>.
  [[ -n "$DEPOSIT_ARG" ]] && DEPOSIT_USDC="$DEPOSIT_ARG"
  DEPOSIT_USDC="${DEPOSIT_USDC:-50}"
fi

pause() {
  (( AUTO )) && return
  echo -n "        press Enter to continue (Ctrl-C to pause) … "
  read -r _ || true
  echo
}
say() { echo "        $*"; }

tx_hash() {   # stdin = cast send output (plain or --json) -> bare 0x.. hash
  python3 -c '
import sys, re, json
s = sys.stdin.read()
try:
    print(json.loads(s).get("transactionHash") or "")
    sys.exit()
except Exception:
    pass
m = re.search(r"(?:transactionHash|hash)\s*[:=]\s*(0x[0-9a-fA-F]{64})", s) \
  or re.search(r"(?m)^\s*(?:transactionHash|hash)\s+(0x[0-9a-fA-F]{64})\s*$", s)
print(m.group(1) if m else "")'
}

do_tx() {   # do_tx <key> <label> <to> <sig> [args...] — sync send, receipt => log, one ✓
  local key="$1" label="$2" to="$3" sig="$4"; shift 4
  local out hash
  out="$(cast send "$to" "$sig" "$@" --rpc-url "$RPC" --private-key "$key" --timeout 120 2>&1)" || {
    printf '%s\n' "$out" >> "$TECH_LOG"
    echo "   ✗ $label — tx failed, full receipt in $TECH_LOG. Re-run after checking it." >&2
    exit 1
  }
  printf '%s\n' "$out" >> "$TECH_LOG"
  hash="$(tx_hash <<< "$out")"
  if [[ -n "$hash" ]]; then
    echo "   ✓ $label  $EXPLORER/tx/$hash"
  else
    echo "   ✓ $label  (receipt logged to $TECH_LOG; no tx hash in cast output)" 
  fi
}

# ---- position: re-read the LP snapshot after agent cycles --------------------
if (( POSITION_ONLY )); then
  SNAP=".env.demo.position"
  if [ ! -f "$SNAP" ]; then
    echo "FATAL: no $SNAP — run ./script/onboard.sh --deposit [AMOUNT] first." >&2
    exit 1
  fi
  set -a; source "$SNAP"; set +a
  PPS_NOW="$(cast call "$POOL" 'pricePerShare()(uint256)' --rpc-url "$RPC" | awk '{print $1}')"
  python3 - "$CASH_USDC" "$SHARES" "$PPS" "$PPS_NOW" <<'EOF'
import sys
cash, shares_s, pps0_s, pps1_s = sys.argv[1:5]
cash, shares = float(cash), int(shares_s)/1e18
pps0, pps1 = int(pps0_s)/1e6, int(pps1_s)/1e6
pos0, pos1 = shares*pps0, shares*pps1
yield_usdc, pct = pos1-cash, 100.0*(pos1-pos0)/pos0 if pos0 else 0.0
print()
print("  [position] LP position vs deposit-time snapshot")
print("    cash in     : %.4f USDC" % cash)
print("    shares      : %.6f" % shares)
print("    price/share : %.6f -> %.6f USDC  (%+.4f%%)" % (pps0, pps1, pct))
print("    position    : %.4f USDC  (yield %+.6f USDC)" % (pos1, yield_usdc))
print()
print("    each keepalive settlement pays the 5% LP slice into this pool,")
print("    so re-run --position after every cycle to watch it compound.")
EOF
  exit 0
fi


wait_jobcount() {   # poll the router until at least $1 onchain jobs exist
  local TARGET="$1"
  local N tries=0
  N=$(cast call "$ROUTER" 'jobCount()(uint256)' --rpc-url "$RPC" | awk '{print $1}')
  while (( N < TARGET )); do
    (( tries >= 90 )) && { echo "FATAL: jobCount stuck at $N (want $TARGET) after ${tries}s" >&2; exit 1; }
    sleep 1; tries=$(( tries + 1 ))
    N=$(cast call "$ROUTER" 'jobCount()(uint256)' --rpc-url "$RPC" | awk '{print $1}')
  done
}

wait_funded() {   # poll until $1 holds >= $2 USDC; $3 = label; times out ~20 min
  local ADDR=$1 NEED=$2 LABEL=$3 A BAL=0 tries=0
  echo "  waiting for $LABEL funding…"
  while (( BAL < NEED )); do
    BAL=$(cast call "$USDC" 'balanceOf(address)(uint256)' "$ADDR" --rpc-url "$RPC" | awk '{print $1}')
    if (( tries % 5 == 0 )); then
      echo "    $LABEL: $(python3 -c "print(f'{$BAL/1e6:.2f}')") / $(python3 -c "print(f'{$NEED/1e6:.1f}')") USDC"
    fi
    (( tries >= 600 )) && { echo "FATAL: timed out waiting for $LABEL balance" >&2; exit 1; }
    sleep 2; tries=$(( tries + 1 ))
  done
  echo "  [✓] $LABEL funded: $(python3 -c "print(f'{$BAL/1e6:.3f}')") USDC"
}

# ---- 0. wallets: reuse the last minted pair, or mint fresh (never toss) ------
# Keys live in the TASK REPO's .env.demo (right next to task.md) — there is no
# protocol-repo key file anymore. The ROOT .env is never used to seed these keys;
# it is sourced above only for infra constants (ORACLE_ADDRESS, RPC, pool
# addresses, etc.). The task repo is guaranteed above by ensure_jobrepo; a
# failed/interrupted walkthrough must not orphan keys, and re-runs reuse the
# task repo's .env.demo as-is; only DEMO_FRESH_WALLETS=1 mints anew (archive first).
DEMO_ENV="$JOBREPO/.env.demo"
if [ -f "$DEMO_ENV" ] && [ "${DEMO_FRESH_WALLETS:-0}" != "1" ]; then
  set -a; source "$DEMO_ENV"; set +a
  ORIG_PK="$ORIGINATOR_PRIVATE_KEY"
  AGENT_PK="$AGENT_PRIVATE_KEY"
  echo "  reusing demo wallets from $DEMO_ENV — the pair you funded is kept."
  echo "  (set DEMO_FRESH_WALLETS=1 to mint a brand-new pair instead)"
else
  if [ -f "$DEMO_ENV" ]; then
    PRESERVED="${DEMO_ENV}.$(date +%Y%m%d-%H%M%S)"
    cp "$DEMO_ENV" "$PRESERVED" && echo "  preserved previous demo keys at $PRESERVED"
  fi
  ORIG_PK="$(new_key)"
  AGENT_PK="$(new_key)"
  printf 'ORIGINATOR_PRIVATE_KEY=%s\nAGENT_PRIVATE_KEY=%s\nCAPITAL_POOL=%s\nRPC_URL="%s"\n' \
    "$ORIG_PK" "$AGENT_PK" "$POOL" "$RPC" > "$DEMO_ENV"
  echo "  minted a fresh demo pair — keys saved in $JOBREPO/.env.demo (gitignored)"
fi
DEMO_WALLET="$(cast wallet address "$ORIG_PK")"
AGENT_ADDR="$(cast wallet address "$AGENT_PK")"
export AGENTGRID_DEMO_KEYS=1   # seed_*.sh layer demo keys over the canonical ones

trap 'rc=$?; if [ $rc -ne 0 ]; then echo "  NOTE: keys for the demo wallets are saved in $DEMO_ENV — wire them into" >&2; echo "        the agent-grid MCP to keep testing; re-runs reuse them." >&2; fi' EXIT

echo "══════════════════════════════════════════════════════════════════════"
if (( FULL_DEMO )); then
  echo "  AgentGrid NO-AGENT FALLBACK DEMO — Arc testnet (full loop, scripted)"
else
  echo "  AgentGrid pre-demo setup — Arc testnet"
fi
echo "══════════════════════════════════════════════════════════════════════"
echo
echo "──────────────────────────────────────────────────────────────"
echo "  CAST OF CHARACTERS (who you will watch move money):"
echo "   you       : ${DEMO_WALLET:0:6}…${DEMO_WALLET: -4}   originator — posts escrow, settles tasks"
echo "   the agent : ${AGENT_ADDR:0:6}…${AGENT_ADDR: -4}   does the work — bonds, submits, pokes the feed"
echo "   router    : ${ROUTER:0:6}…${ROUTER: -4}   the escrow state machine (each task is a statechart here)"
echo "   pool      : ${POOL:0:6}…${POOL: -4}   your LP deposit — earns a 5% slice on every settlement"
echo "   oracle    : ${ORACLE:0:6}…${ORACLE: -4}   the BTC feed the agent pokes (spec 4)"
echo "   usdc      : ${USDC:0:6}…${USDC: -4}   native gas AND payment — one faucet drip feeds everything"
echo "──────────────────────────────────────────────────────────────"
echo
if (( FULL_DEMO )); then
  say "No agent today: this plays all three roles scripted — an LP (you deposit),"
  say "an originator (you post escrow), and an agent (bond, work, submit)."
  say "Every line below is a real transaction; full addresses are in every"
  say "✓ line alongside what each transaction does."
else
  say "This is PRE-DEMO setup: mint the demo pair, fund them, seed the LP position,"
  say "wire keys into the task repo — then the DEMO is two windows on that repo,"
  say "each told 'you are the originator' / 'you are the executor'. No agent here."
fi
say "Whatever you do onchain is one keystroke a real agent does in the demo:"
say "postUpkeep.sh (originator) and the executor's loop. Every step is a tx."

# ---- 1. fund the fresh wallets ----------------------------------------------
# Gas on Arc IS native USDC, so headroom is part of the same USDC budget:
# functional spend = 6 (LP) + 2 (posted task) + 2 (direct hire) + 7 (bond) = 17,
# plus 2.5 total headroom -> the whole demo fits one 20-USDC faucet drip.
# You drip these two brand-new wallets yourself (https://faucet.circle.com) —
# the script will not move funds from any key you hold.
NEEDED_ORIG=$(( (DEPOSIT_USDC + (OPEN_JOBS + 1) * JOB_USDC) * 1000000 + 1500000 ))
BOND_ATOMIC=$(( (BOND_USDC + 1) * 1000000 ))

if (( DEPOSIT_ONLY )); then
  # deposit-only: the agent isn't part of this phase — fund just the LP wallet.
  NEED_DEP=$(( DEPOSIT_USDC * 1000000 + 1000000 ))   # cash in + 1 USDC gas headroom
  echo "=== [1] funding — drip the LP wallet at the faucet ==="
  echo "  Arc gas IS USDC, so ONE drip covers your deposit + gas."
  echo
  echo "  you  $DEMO_WALLET"
  echo "    drip  $(python3 -c "print(f'{$NEED_DEP/1e6:.1f}')") USDC"
  echo
  echo "  faucet: https://faucet.circle.com  (one paste = 20 USDC — plenty)"
  echo
  wait_funded "$DEMO_WALLET" "$NEED_DEP" "you (LP)"
else
  echo "=== [1] funding — drip these two wallets at the faucet ==="
  echo "  Arc gas IS USDC, so ONE drip per wallet covers its spend + gas."
  echo
  echo "  originator $DEMO_WALLET"
  echo "    drip  $(python3 -c "print(f'{$NEEDED_ORIG/1e6:.1f}')") USDC"
  echo "  agent     $AGENT_ADDR"
  echo "    drip  $(python3 -c "print(f'{$BOND_ATOMIC/1e6:.1f}')") USDC"
  echo
  echo "  faucet: https://faucet.circle.com  (Arc testnet — paste each address)"
  echo
  wait_funded "$DEMO_WALLET" "$NEEDED_ORIG"  "originator"
  wait_funded "$AGENT_ADDR"  "$BOND_ATOMIC"  "agent"
fi

# ---- 2. you are the LP -----------------------------------------------------
echo "=== [2] you are the LP ==="
SUPPLY="$(cast call "$POOL" 'totalSupply()(uint256)' --rpc-url "$RPC" | awk '{print $1}')"
if (( SUPPLY == 0 )); then
  echo "FATAL: pool $POOL has zero shares — a genesis deposit must exist first (Deploy.s.sol fronts 1 USDC)." >&2
  exit 1
fi
PPS_BEFORE="$(cast call "$POOL" 'pricePerShare()(uint256)' --rpc-url "$RPC" | awk '{print $1}')"
SHARES_BEFORE="$(cast call "$POOL" 'balanceOf(address)(uint256)' "$DEMO_WALLET" --rpc-url "$RPC" | awk '{print $1}')"
echo ">> [you] approve(pool, ${DEPOSIT_USDC} USDC) + deposit"
do_tx "$ORIG_PK" "you · approve pool" "$USDC" "approve(address,uint256)(bool)" "$POOL" "$(( DEPOSIT_USDC * 1000000 ))"
do_tx "$ORIG_PK" "you · deposit ${DEPOSIT_USDC} USDC" "$POOL" "deposit(uint256,address)(uint256)" "$(( DEPOSIT_USDC * 1000000 ))" "$DEMO_WALLET"
LP_SHARES="$(cast call "$POOL" 'balanceOf(address)(uint256)' "$DEMO_WALLET" --rpc-url "$RPC" | awk '{print $1}')"
GAIN=$(( LP_SHARES - SHARES_BEFORE ))
echo "  your shares: $(python3 -c "print(f'{$LP_SHARES/1e18:.4f}')") (+$(python3 -c "print(f'{$GAIN/1e18:.4f}')") this deposit) @ pps $(python3 -c "print(f'{$PPS_BEFORE/1e6:.6f}')") USDC/share"
printf 'CASH_USDC=%s\nSHARES=%s\nPPS=%s\nDEPOSITED_AT=%s\n' \
  "$DEPOSIT_USDC" "$GAIN" "$PPS_BEFORE" "$(date +%s)" > ".env.demo.position"
say "Settlement pays a 5% LP slice into this pool — watch your share price move"
say "when a task settles (that is the whole LP yield: shares appreciate, no mint)."
pause

if (( DEPOSIT_ONLY )); then
  echo
  echo "══════════════════════════════════════════════════════════════════════"
  echo "  [deposit-only] your LP position is live"
  echo "    cash in     : ${DEPOSIT_USDC} USDC"
  echo "    shares      : $(python3 -c "print(f'{$LP_SHARES/1e18:.4f}')")"
  echo "    price/share : $(python3 -c "print(f'{$PPS_BEFORE/1e6:.6f}')") USDC (pps)"
  echo "══════════════════════════════════════════════════════════════════════"
  echo
  say "LP seed done. To finish pre-demo setup: ./script/onboard.sh"
  say "Then RUN the demo in two windows on the task repo — every keepalive"
  say "settlement sends its 5% LP slice INTO this pool; after each agent cycle"
  say "run:"
  say "    ./script/onboard.sh --position"
  say "to see your yield compound since this deposit (baseline locked above)."
  echo
  exit 0
fi

if (( ! FULL_DEMO )); then
  # ---- PRE-DEMO complete: hand off to the two-console demo ------------------
  echo
  echo "══════════════════════════════════════════════════════════════════════"
  echo "  pre-demo setup complete — the demo pair is funded and LP is seeded"
  echo "══════════════════════════════════════════════════════════════════════"
  echo
  say "   keys: already in $JOBREPO/.env.demo (minted above, gitignored, next to"
  say "   task.md) — postUpkeep sources it; the MCP reads both roles from it."
  echo
  say "THE DEMO IS TWO WINDOWS ON THE TASK REPO (one shared skill) — run it now:"
  say "  1. originator window:  cd $JOBREPO && ./scripts/postUpkeep.sh"
  say "        posts the template upkeep task (escrow + deadline + spec, one tx)."
  say "  2. executor window:    open $JOBREPO (a second window) and tell the agent"
  say "        'you are the executor'. The one SKILL.md resolves its role and it"
  say "        runs: agent_bond_status → keeper_jobs → agent_accept"
  say "        → agent_poke_and_submit — the poke + submit in ONE call."
  say "  3. originator settles: originator_settle on that task."
  say "  4. after each cycle:   ./script/onboard.sh --position  → LP yield grows."
  echo
  say "No agent available? ./script/onboard.sh --demo plays the whole loop"
  say "scripted instead (the pre-agent fallback)."
  echo
  exit 0
fi

# ---- 3. scripted originator (no-agent fallback) -----------------------------
echo "=== [3] scripted originator ==="
echo ">> post one open-market job (market color) to a fresh job id"
JOBS_BEFORE="$(cast call "$ROUTER" 'jobCount()(uint256)' --rpc-url "$RPC" | awk '{print $1}')"
./script/seed_jobs.sh "$OPEN_JOBS" "$JOB_USDC"
wait_jobcount $(( JOBS_BEFORE + OPEN_JOBS ))   # seed_jobs sends --async; wait for onchain
NEXT_ID="$(cast call "$ROUTER" 'jobCount()(uint256)' --rpc-url "$RPC" | awk '{print $1}')"
NEXT_ID=$(( NEXT_ID + 1 ))                     # our direct hire will be the next id
SPECHASH="$(cast keccak "$(cat specs/4.json)")"
say "Posted ${OPEN_JOBS} open task(s) with specHash ${SPECHASH:0:18}… (provenance is onchain)."
say "Now we direct-hire the agent for the mock lending-pool oracle task (specs/4.json)"
say "— escrow lands inside seed_lifecycle, which owns that nonce so the demo stays safe."
pause

# ---- 4. scripted agent lifecycle (no-agent fallback) ------------------------
echo "=== [4] scripted agent (bond → direct hire → accept → poke → submit → approve) ==="
PPS_PRE_SETTLE="$(cast call "$POOL" 'pricePerShare()(uint256)' --rpc-url "$RPC" | awk '{print $1}')"
./script/seed_lifecycle.sh "$JOB_USDC" "$BOND_USDC"
wait_jobcount "$NEXT_ID"                       # lifecycle's direct hire must be onchain
PPS_POST_SETTLE="$(cast call "$POOL" 'pricePerShare()(uint256)' --rpc-url "$RPC" | awk '{print $1}')"
say "That was the full loop. Our task is the highest id; the pool price moved >1.0."
pause

# ---- 5. validate — onchain proof only (subgraph read + cast, no JS apps) ----
echo "=== [5] validate ==="
sleep 20   # subgraph indexes within ~30s; give it a beat before querying
JOB_ID="$(cast call "$ROUTER" 'jobCount()(uint256)' --rpc-url "$RPC" | awk '{print $1}')"
SETTLED="$(JOB_ID="$JOB_ID" node -e 'const u=process.env.SUBGRAPH_URL;fetch(u,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({query:`{ job(id: "${process.env.JOB_ID}") { state outcome resultHash submittedAt settledAt executorPaid lpPaid treasuryPaid } }`})}).then(r=>r.json()).then(j=>console.log(JSON.stringify(j.data.job,null,2)))')"
echo "$SETTLED"
LAST="$(cast call "$ORACLE" 'lastUpdated()(uint256)' --rpc-url "$RPC" | awk '{print $1}')"
AGE=$(( $(date +%s) - LAST ))
if (( AGE <= 3600 )); then FRESH="fresh"; else FRESH="S T A L E"; fi
echo "  feed lastUpdated ${LAST} — age ${AGE}s (threshold 3600s) → ${FRESH}"
echo "  pricePerShare : $(python3 -c "print(f'{$PPS_BEFORE/1e6:.6f}')") → $(python3 -c "print(f'{$PPS_POST_SETTLE/1e6:.6f}')") USDC/share"
YIELD="$(python3 -c "print(f'{$LP_SHARES*($PPS_POST_SETTLE-$PPS_BEFORE)/1e24:.6f}')")"
echo "  your LP yield : +${YIELD} USDC on ${DEPOSIT_USDC} USDC deposit (5% slice landed)"
echo
echo "══════════════════════════════════════════════════════════════════════"
echo "  task #${JOB_ID} settled · feed fresh · payout spelled out in the JSON above"
echo "══════════════════════════════════════════════════════════════════════"
echo
echo "  That was the NO-AGENT FALLBACK demo — every role scripted with cast."
echo "  The live demo is the same loop but a real agent on one side:"
echo
echo "    originator   my_job/scripts/postUpkeep.sh   (posts the upkeep task)"
echo "    executor     open my_job, tell the agent 'you are the executor'"
echo "                 (agent_bond_status → keeper_jobs → agent_accept →"
echo "                  agent_poke_and_submit → verify_job_result)"
echo "    originator   originator_settle on that task; onboard.sh --position"
echo
echo "  The agent keys are in my_job/.env.demo (gitignored) — the task repo is"
echo "  the only home for them now; that ONE file serves both roles and"
echo "  postUpkeep.sh."
echo
cat <<EOF
{ "mcpServers": { "agent-grid": {
  "command": "node",
  "args": ["$(pwd)/subgraph/mcp/src/index.js"],
  "env": {
    "SUBGRAPH_URL": "$SUBGRAPH",
    "JOB_ROUTER": "$ROUTER",
    "AGENT_REGISTRY": "$REGISTRY",
    "CAPITAL_POOL": "$POOL",
    "CREDIT_LINE": "${CREDIT_LINE:-0x060c68A7E696aa88D5d7aB37722681BD1894B783}",
    "ORACLE_ADDRESS": "$ORACLE",
    "CHAIN_ID": "$CHAIN",
    "RPC_URL": "$RPC",
    "ORIGINATOR_ENV_FILE": "$JOBREPO/.env.demo",
    "AGENT_ENV_FILE": "$JOBREPO/.env.demo"
  }
} } }
EOF
echo
echo "  full receipts for every step are in ${TECH_LOG:-/tmp/agentgrid-tech.log}"
echo