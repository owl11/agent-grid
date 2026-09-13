# AgentGrid — Onboarding

Prepare the live demo, learn the protocol by *living one task end-to-end* on
Arc testnet, then drive the same protocol from your own agent windows.

## What you just did (pre-demo setup)

`./script/onboard.sh` (the **pre-demo** script) minted two brand-new wallets,
walked you through the faucet drip, and seeded the pool as LP — against the
**live** contracts. The demo keys live in the task repo's `.env.demo` now (no
repo-root key file), so the task repo comes first:

```sh
cp -r template/my-job my_job && cd my_job && forge install forge-std
cd .. && DEMO_FRESH_WALLETS=1 ./script/onboard.sh   # fresh pair, mint + fund + LP
```

> The task repo is self-sufficient — `.env.demo.example` already carries the
> pool + RPC constants, so a user can run jobs from `my_job/` alone without
> the protocol repo. A root `.env` is an optional dev override (custom
> deployments, subgraph creds); the demo keys live **only** in `my_job/.env.demo`.

| Role | Pre-demo did | Onchain |
|---|---|---|
| **Wallets** | minted + funded the demo originator & agent (keys in `my_job/.env.demo`) | balances |
| **LP** | originator deposited 6 USDC into the CapitalPool | shares, `pricePerShare` moves when tasks settle |

Your fresh keys live in `my_job/.env.demo` (gitignored). The actual task is not played
here: **the demo is two agent windows** (a live agent each), see "The live
demo" below.

> Reproduce setup anytime: `./script/onboard.sh` (interactive / `--auto`
> hands-free). **No agent available?** `./script/onboard.sh --demo` plays the
> whole task loop scripted instead — bond → accept → poke → submit → approve,
> every step a real transaction, the pre-agent fallback.

## Generate fresh keys only (`--keys-only`)

If you only want two brand-new demo wallets (e.g. for a fresh run, or to retire
a previous pair), use `--keys-only`. It mints two fresh keys, writes them into
the task repo's `.env.demo` (default `./my_job`, override with
`DEMO_JOB_REPO=<path>`), and prints the **full** addresses — then stops. No
funding, no deposit, no onchain tx beyond the local `cast wallet new`.

```sh
./script/onboard.sh --keys-only
```

Typical output:

```
  minted two new keys into my_job/.env.demo (gitignored)
    originator : 0xE3b3…1d1c
    agent      : 0x1785…7C2C

  NOW: paste each address below into https://faucet.circle.com (Arc testnet)
  and drip BOTH — Arc gas IS USDC, so one drip per wallet covers spend + gas.
  Then re-run WITHOUT --keys-only to fund + seed the LP position, or continue
  with the two-window demo (see ONBOARDING.md).

    faucet: https://faucet.circle.com
    originator : 0xE3b3…1d1c
    agent      : 0x1785…7C2C
```

The script prints the addresses twice (once in the summary, once under the
explicit faucet prompt) so they are easy to copy. The two private keys are
written to `my_job/.env.demo` (gitignored) — **do not paste keys into the
faucet UI**; paste the *addresses* (the `0x…` strings labeled originator /
agent) to receive funds.

### Next step after the drip

Once both wallets show funded on https://explorer.testnet.arc.io, re-run
**without** `--keys-only` to fund + seed the LP position and hand off to the
two-window demo:

```sh
./script/onboard.sh            # asks to fund both wallets, seed LP, then print the demo instructions
```

Or go straight to the two-window demo if the wallets are already funded:

```sh
cd my_job && ./scripts/postUpkeep.sh      # originator window
# second window: open my_job, tell the agent "you are the executor"
```

To retire a previous pair and mint a brand-new one instead, set
`DEMO_FRESH_WALLETS=1` (the script archives the old `.env.demo` with a
timestamp before minting).

## The state machine, honestly

A job is a `bytes32`-auditable state machine onchain. **Every state in this
table is what the demo build actually deploys** — nothing is cosmetic.

```
POSTED → ASSIGNED → SUBMITTED → SETTLED
   │          │          │
   │          │          └─ rejected → EXPIRED   (implemented; live router is pre-redeploy — see below)
   │          └──────── expire(deadline passed)  → EXPIRED
   └──────── cancel(never assigned)              → EXPIRED
```

| State | Meaning | Who flips it |
|---|---|---|
| `POSTED` | Escrow held; originator owns it | `createJob` |
| `ASSIGNED` | Bond locked behind the job | `accept` |
| `SUBMITTED` | Agent delivered a `resultHash` claim | `submitResult` (by the assigned agent) |
| `SETTLED` | Payout split 9000/500/500 → executor · LP · treasury | `approve` *or* `timeoutSettle` after the window |
| `EXPIRED` | Terminal. Two flavors: never-done (fails hard) vs rejected | `cancel` / `expire` / `reject` |

**State-shape facts that matter, verified in `src/JobRouter.sol`:**

- `reject(uint256,bytes32)` — originator-only, requires `SUBMITTED` *and* the
  approval window still open:
  - splits the fees `500/250/250` bps (5% executor / 2.5% pool / 2.5% fixed
    treasury) and refunds the remaining **90%** to the originator — rejection
    still pays LPs (`_poolSlice`, same as the settle path, line 368),
  - outcome `FAILURE` recorded against the assigned agent,
  - state → `EXPIRED`; emits `JobRejected(reasonHash)` (cause) **plus**
    `JobExpired` (indexed disposition) — this is why the subgraph never needs a
    new state literal.
  - the live router on testnet still runs a pre-redeploy hard-revert stub of
    this; the local build (this file) has the full behavior above.
- `timeoutSettle(jobId)` — anyone can auto-settle in the **agent's favor** once
  the silent approval window elapsed. Rules out "originator ghosts the work."
- `expire(jobId)` — paid agents that miss `execDeadline`: refund minus the
  cancel fee, outcome `FAILURE`, **no bond slash in the demo** (the slash table
  stays POSTPONED with disputes/lending).
- `DISPUTED` sits in `IJobRouter.sol`'s ABI for indexer stability only — it is
  unreachable in the demo.

## Why the demo verifies what it verifies

`verify_job_result` and the onboard validate beat prove **only what is
deterministically recheckable onchain**:

- feed `lastUpdated` vs block time (`check_feed_staleness`)
- poke + submit sender from transaction receipts
- exact payout split (`executorPaid 1.8M / lpPaid 100k / treasuryPaid 100k` for
  a 2 USDC job) and terminal state
- `resultHash` == `keccak(pokeTx:postTimestamp)` recomputed from chain data


## The live demo, two windows at once

The full recorded demo runs TWO editor windows side by side, each an independent agent
context — one per role. Both live in the **task repo** (`template/my-job`, copied
out to wherever you demo from), NOT in this protocol repo — the agents never see the
protocol's contracts or secrets.

```
my_job/  (one repo, one canonical skill, one env)
├── task.md                the mission brief — every agent reads this FIRST
├── SKILL.md               THE one skill — canonical, lives here. Your role
│                          (originator / executor) is assigned in your prompt
├── .env.demo              ONE env: ORIGINATOR_PRIVATE_KEY + AGENT_PRIVATE_KEY + RPC_URL
├── scripts/postUpkeep.sh  posts the template upkeep task (onboarding step 1)
└── specs/spec.json        the spec whose keccak256 is your specHash
```

1. **Stand it up:** `cp -r template/my-job my_job`, then in `my_job` copy
   `.env.demo.example` → `.env.demo` and paste BOTH demo keys (this one file
   serves both roles and postUpkeep.sh — no per-role files).
2. **Step 1 — post the template upkeep task:** `cd my_job && ./scripts/postUpkeep.sh`.
   It posts the exact keepalive the protocol has been poking all day (specs/4.json,
   pinned `specHash`, 2 USDC, open market) as one `createJob` tx. That is the originator
   side, scripted.
3. **Step 2 — the executor:** open `my_job/` in a SECOND window and tell the agent
   *"you are the executor"* — the ONE `SKILL.md` already knows the loop. It reads
   `task.md`, runs `agent_bond_status`, then `keeper_jobs` — the freshly posted task
   surfaces within ~30s (subgraph index) — accepts, pokes, submits; the originator
   window settles with `originator_settle`.

One person, two windows, both sides of one task — the same loop `onboard.sh --demo`
plays scripted, now as two live agents. The MCP registrar JSON
(`ORIGINATOR_ENV_FILE`/`AGENT_ENV_FILE` → `<my_job>/.env.demo`) lives in
`template/my-job/README.md` and is printed by `onboard.sh --demo`.

## Drive it yourself from Cursor / Claude Code

### 1. Register the MCP server

The pre-demo setup left your keys in `my_job/.env.demo` — the ONLY home for
them (no repo-root key file). The MCP reads each role's key from that file
itself (no key in your config). Drop this into your Cursor / Claude Code MCP
settings; replace `<PATH-TO-MY_JOB>` with your materialized task repo:

```json
{ "mcpServers": { "agent-grid": {
  "command": "node",
  "args": ["<ABSOLUTE-REPO-PATH>/subgraph/mcp/src/index.js"],
  "env": {
    "SUBGRAPH_URL": "https://api.studio.thegraph.com/query/1758789/job-router/0.0.6",
    "JOB_ROUTER": "0xA4B7f0a1E650318CAe82a64902D1104466DE6ea0",
    "AGENT_REGISTRY": "0x3Df83475b24fAF980E13105550790556B23480a5",
    "CAPITAL_POOL": "0x62bb4fEa3e21b45F6A71CCd8bFE763F1ED92E254",
    "ORACLE_ADDRESS": "0x24F74B5B4a613d38E4926c9E54C1162ec4a840A0",
    "RPC_URL": "https://rpc.testnet.arc.io",
    // keys not listed: the server reads ORIGINATOR_PRIVATE_KEY / AGENT_PRIVATE_KEY
    // from the two *_ENV_FILE paths (the file overrides any env block)
    "ORIGINATOR_ENV_FILE": "<PATH-TO-MY_JOB>/.env.demo",
    "AGENT_ENV_FILE": "<PATH-TO-MY_JOB>/.env.demo"
  }
} } }
```

### 2. The three recipes

**Post a task (originator)**
```
Use create_job_tx to build a transaction that posts a task with specHash of our
spec, payment 2 USDC, the 0/0/0 split sentinel, execDeadline +1 day,
approvalWindow 7200, and no designated assignee. Print the hex.
```
Sign the hex with your kitty wallet → paste the tx hash → watch it land:
`jobs_for_agent  <JOB_ID>` to see it as POSTED.

**Give the task to your agent**
```
Get the job id, then call canAccept to check the agent's eligibility, and if
true build an accept_job_tx. Sign it.
```

**Submit + verify**
```
Build a submit_result_tx for our task. The result must be a valid claim for the
oracle feed job (specs/4.json). For the mock-oracle job poke the feed first so
the claim is real. After signing, run verify_job_result and then check the feed
with check_feed_staleness(0x24F74B5B4a613d38E4926c9E54C1162ec4a840A0, 3600).
```

### 3. Numbers you'll see — what they mean

- `executorPaid 1.8M / lpPaid 100k / treasuryPaid 100k` — 6-decimal USDC of a
  2 USDC job (9000/500/500 bps; the three sum to exactly 2e6).
- `pricePerShare 1000000` — exactly 1.0 USDC. The onboarding prints it as
  `1.000000`; after a settle it inches up — that is LP yield from `_poolSlice`.
- `lastUpdated` stale > 3600s → the demo's `check_feed_staleness` reports STALE;
  the keeper pokes (`poke(uint256)` = `0xd39ce84c01096b5c06a6f1f1f8be2a4a1d…` hash of BTC price).
- `bondOf` 10 USDC is the agent's skin-in-the-game; the acceptor gate is
  `canAccept = bonded ≥ payment`.

## File map

- `script/onboard.sh` — the PRE-DEMO setup (mint + fund + LP seed + key wiring),
  with `--demo` as the fully scripted no-agent fallback loop
- `template/my-job/` — the task repo: `task.md` (the changing mission brief) +
  `SKILL.md` (the one canonical skill) + `.env.demo.example` + `scripts/postUpkeep.sh`
- `script/seed_lifecycle.sh` — the full task lifecycle (bond → accept → submit → approve)
- `script/seed_jobs.sh` — post open-market jobs
- `specs/4.json` — the mock lending-pool oracle job spec
- `subgraph/mcp/src/index.js` — the MCP server (tools your Cursor agent uses)
- `src/JobRouter.sol` — the state machine above