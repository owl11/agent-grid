# AgentGrid — Bonded Agent Capital + Coordination Protocol

Spec validation document — **nothing here is final; every section is subject to revision as the keeper network surfaces new findings.**

A set of Solidity contracts that let bonded AI agents draw working capital from a shared USDC pool, accept escrowed jobs through a deterministic onchain router, and settle every job with a transparent value split.

**No token. No offchain trust in the trust path. Every decision derivable from chain data alone (P1).**

Built with [Foundry](https://book.getfoundry.sh/) on **Arc testnet** (chain 5042002, native USDC gas).

## Why This Exists

This protocol is informed by the research findings from KeeperDAO and similar pooled-capital coordination experiments — projects that proved pooled capital, explicit splits, proactive underwriting, and risk isolation work in practice, but whose trust failures (offchain coordination discretion, social slashing, whitelist capture, unverifiable splits, token friction) showed where the hard edges are. Every design choice here traces back to one of those findings.

**The KeeperDAO insight we build on:** a race (zero-sum, value burned) becomes a split (positive-sum, value shared). We inherit that transformation — and harden it with deterministic onchain settlement, append-only reputation, and a USDC-only trust surface.

### The Gap This Protocol Fills

Every standard in this space stops at coordination plumbing — identity, escrow state machines, execution encodings, payment rails. **None of them hold capital, price credit risk, enforce cooperation economically (bonding/slashing), or distribute value across multiple parties per job.** That combination requires a balance sheet and loss-bearing appetite — which marketplaces won't build.

## ERC Context

**ERC-4626** — Pool share accounting, adopted day-1: `totalShares ≡ totalSupply()`, dead-share guard against inflation attacks. The LP bookkeeping is a vault.

**ERC-8004** — Identity linking, optional via `ERC8004Adapter`: bonded agents can attach an existing ERC-8004 identity. Live mainnet Jan 2026 (~183k registrations); our bond-backed track record is the *costly* signal 8004's free registry lacks.

### Adoptable, not committed

**ERC-8211 (smart batching)** — turns two transactions (poke + submit) into one. Adoptable as-is when/if we want it; not needed today.

## Architecture

### Marketplace Engine, Not a Marketplace

The `JobRouter` implements the full onchain skeleton of a job marketplace — escrowed posting, tiered claim windows, enforced settlement — but the marketplace proper (discovery UX, search, demand acquisition) is a **non-goal**. Any frontend can index `JobPosted` events and render a marketplace over the router without permission. The protocol owns the scarce layers marketplaces won't build: pooled capital, credit underwriting, and financially-backed reputation.

**Primary go-to-market risk:** demand-seeding (routing existing agent activity — ERC-8004 agents — through the router). Ahead of any technical risk.

### Component Map

```
 Originator console ── createJob(escrow) ──────────────────────┐
  (controller-driven   ▲                                      ▲
   agent / keeper)     │ approve / reject      ┌──────────────────┐
                       │                       │    JobRouter     │
                       └───────────────────────┘  (state machine) │
                                                 └───┬────┬────┬───┘
                         accept / submitResult       │    │    │
                                                     │    │    │
               ┌─────────────────────────────────────┘    │    └──────────────┐
               │ draw / repay / slash                     │ record outcome    │ settle(split)
               ▼                                          ▼                   ▼
        ┌────────────┐   bond / rep events / adapters   ┌──────────────┐   ┌────────────┐
        │ CreditLine │◄────────────────────────────────│ AgentRegistry│   │ ValueSplit │
        └─────┬──────┘                                 └──────────────┘   └─────┬──────┘
              │ borrow liquidity / repay + interest
              ▼
        ┌────────────┐
        │ CapitalPool │  ← LPs deposit USDC, earn settlement revenue
        └─────┬──────┘
              │ (settlement → receiveRevenue; credit repayment → receiveRepayment)
              ▼
        ┌────────────┐
        │  USDC      │  ← single asset, single chain (Arc testnet)
        └────────────┘
```

## The Five Contracts

### 1. ValueSplit (Pure Library)

No state. Validates and distributes 3-role splits.

```solidity
struct Split {
    uint16 executorBps;   // executing agent
    uint16 lpBps;         // capital providers
    uint16 treasuryBps;   // protocol accumulator
} // must sum to exactly 10_000 bps
```

**Regime-coupled defaults** (one onchain bit selects the row):
- **Draws inert (v1):** `9000 / 500 / 500` — LPs earn standby liquidity income, no lending risk
- **Draws active:** `8500 / 1000 / 500` — LPs are actual lenders bearing default risk

The lp share *prices what the pool provides*. Executor is the remainder `total − (lp + treasury)` so no dust is lost or created (I4).

**Hard bounds (P7):** executor [7000, 9500], lp [300, 1500], treasury [100, 500]. Executor additionally capped by per-agent experience-rated wage cap (start 90%, ±500 bps per 10 net outcomes, floor 70%).

### 2. CapitalPool (USDC Vault)

Lends exclusively to `CreditLine`. LP return in v1 is settlement revenue via `receiveRevenue` — no interest, no draws (lending is **built but dual-gated OFF**).

**Key decisions:**
- `bookedAssets` is **derived**, not stored (`usdc.balanceOf(this)` — G1). No second counter to drift from reality.
- ERC-4626 surface adopted day-1: `totalShares ≡ totalSupply()`, dead-share guard prevents inflation attacks.
- `reportLoss` lands same-block in share price (visible, not hidden). Loss socialization only at v2-unsecured stages.
- Dual-gate defense-in-depth: `lendTo` requires both `lendEnabled` (pool) AND `lendingEnabled` (CreditLine). Pause-entry/open-exit: outstanding debt can always wind down.

### 3. AgentRegistry (Bonding + Reputation)

Append-only reputation. No discretionary score adjustments ever (P2, P5).

**Identity:** Pluggable adapters (`IAgentIdentity`). Bare-address mode (wallet == identity) or `ERC8004Adapter` (verifies against the ERC-8004 Identity Registry). Ownership verified ONCE at bond time; revocation checked LAZILY at eligibility-sensitive moments.

**Reputation scoring (deterministic, pure over events):**
```
score = clamp(0, 1e18, ewmaSuccess × volumeFactor)
ewmaSuccess  : half-life ≈ 30d job-time; SUCCESS=1, FAILURE=0, FRAUD=0×5 severity
              NEUTRAL: skipped entirely (weight-zero — anti-wash property)
volumeFactor : min(1, totalSettledVolume / VOLUME_CAP)  // caps whale dominance
tier         : 3 ≥ 0.90·volFactor; 2 ≥ 0.75; 1 ≥ 0.50; else 0
```

`minBond = 100 USDC`; exit unlock delay = 7 days; slash bounds enforced at call sites.

### 4. CreditLine (Reputation-Underwritten Credit)

Bond is the floor; reputation buys headroom. Ships compiled in v1, **dual-gated OFF** (`lendingEnabled = false`). Principal-only loans — no interest, no accrual, no rate model.

```
limit(agent)   = min(bondOf(agent), ABSOLUTE_CAP)
usable(agent)  = UTIL[tier] × limit − principal
UTIL           = [50%, 70%, 85%, 95%] for tiers 0–3
ABSOLUTE_CAP   = 10_000 USDC (v1 bootstrap)
```

Even at tier 3, an agent can owe at most 95% of its bond — **LP expected credit loss at COLLATERALIZED stage is exactly zero** (bond = collateral, slash = liquidation).

Tiers scale utilization of the agent's **own bond**, never leverage. Limits bind at draw time only — no liquidation cascades from reputation drift.

### 5. JobRouter (Onchain Job Lifecycle)

Fully deterministic. Coordination enforced onchain — escrow, conditional settlement, and an onchain arbiter for disputes — not by a trusted server or whitelist (P1, P4).

**Job record:**
```solidity
struct Job {
    address originator;
    address designatedAssignee; // zero = open post; set = direct hire
    bytes32 specHash;
    uint128 payment;         // USDC escrowed at creation
    uint64  execDeadline;
    uint64  approvalWindow;
    Split   split;           // 3-role, validated at creation, immutable
    bytes32 assignedAgent;
    bytes32 resultHash;
    uint96  drawnForJob;     // gated OFF in v1
    uint96  opsBudget;       // gated OFF in v1
    State   state;
}
enum State { NONE, POSTED, ASSIGNED, SUBMITTED, SETTLED, CANCELLED, EXPIRED, DISPUTED }
```

**Access windows (P5):** Pure priority, not exclusion. Tiers buy earlier access, nothing more.
- W0 (tier ≥ 3): opens at `createdAt + 10m`
- W1 (tier ≥ 2): opens 10m later
- W2 (any bonded agent): open

**Direct hires:** `designatedAssignee` non-zero → windows skipped, only that wallet may accept.

**Settlement ordering (I3):** debt repayment (no-op in v1) → split → outcome. Slash proceeds credit pool FIRST.

**Failure paths — severity-graded** (percentages are compile-time constants, not owner dials):

| Ruling | Escrow | Bond | Outcome |
|---|---|---|---|
| Success | 3-role split (90/5/5 v1), executor capped by wage cap | untouched | SUCCESS |
| OOPS (mutual "didn't work out") | 80% refund · 10% agent effort · 10% pool | untouched | NEUTRAL (weight-zero rep) |
| AGENT_FAULT (honest failure) | 90% refund · 10% pool | 5%-of-bond fee → pool | FAILURE |
| ORIGINATOR_FAULT (vague spec) | 5% fee → pool; remainder 50/50 agent comp / originator refund | untouched | FAILURE vs originator job |
| MALICE | at-fault party forfeits fully | full forfeiture | FRAUD (5× weight); adapter revoked |

**Mutual cancel:** Free window (2h post-accept) → NEUTRAL, no cost. Post-window: proposed onchain, confirmed by counterparty; pool retains a small fee so washing stays unprofitable.

**Arbiter (v1):** timelocked multisig, bounded ruling window (72h) with auto-refund fallback. MAX_PAYMENT bound (5,000 USDC, hard cap 50,000) caps bribery value-at-risk.

## Invariants (Enforced by Test Suite)

- **I1 Solvency:** pool assets ≥ total outstanding principal at every transition
- **I2 Terminality:** every posted job reaches exactly one terminal state (SETTLED / CANCELLED incl. mutual / EXPIRED / dispute-resolved); no stranded escrow
- **I3 Slash precedence:** slashed funds credit pool before any router distribution in the same transaction
- **I4 Split validity:** splits sum to exactly 10,000 bps; settlement distributes exactly the escrowed amount, no dust loss
- **I5 Reputation integrity:** events append-only; scores are pure functions of events (NEUTRAL weight-zero, FRAUD severity-weighted)
- **I6 Eligibility:** no draw beyond utilization limit; no acceptance outside open window; no settlement without assignment; mutual cancel requires two-party consent within bounds
- **I7 Escrow conservation:** escrowed funds move only via settlement/cancel/failure paths; total out = total in
- **I8 Visible flows:** share price changes only via emitted events (no silent write-downs/mark-ups)
- **I9 Breaker consistency:** trailing-loss breach pauses draws; state is pure function of pool history

## Design Principles (P1–P9)

| Principle | What it means |
|---|---|
| **P1** | Every decision derivable from chain data alone — no offchain trust in the trust path |
| **P2** | Bonded identity — no free reputation; Sybil resistance via costly signaling |
| **P3** | No token, no governance token — nothing to price, or gate |
| **P4** | Determinism over tunability — failure-path percentages are compile-time constants |
| **P5** | Permissionless participation — tiers are earned time windows, not whitelists |
| **P6** | Honest framing — losses marked to market same-block; visible from day one |
| **P7** | Hard bounds on every parameter — timelocked changes; no owner dials on justice |
| **P8** | Build on evidence, not vibes — activation on data, not conviction |
| **P9** | Every dollar of every split is an event tied to jobId — fully auditable |

## Key Decision Records

- **Bond-centric posture:** originator rebate role retired (originators are customers, not value creators). 3-role split with regime-coupled defaults.
- **Lending built-dark:** full CreditLine compiles in v1, ships with `lendingEnabled = false`. Activation = two timelocked boolean flips, never a migration or rewire. Breaker semantics live from day one; fuzz coverage before activation.
- **Principal-only loans:** no interest, no accrual checkpoints. The 5% headroom (tier 3: 95% of bond) is pure safety margin — no interest to absorb.
- **Integrity canary → entry-only pause:** deposit/lendTo revert when paused; withdraw/repay/reportLoss stay live. Outstanding debt always wind-downable.
- **MAX_PAYMENT bound:** caps bribery value-at-risk at 5,000 USDC (hard cap 50,000, timelocked).
- **Wage cap:** executor experience-rated cap starts at 90%, adjusts ±500 bps per 10 net outcomes, floor 70%. Preempts demotion at tier boundaries without tier coupling.

## Getting Started

```bash
forge build && forge test          # build + full test suite
./script/onboard.sh --deposit 5    # deposit LP shares on Arc testnet
```

See [README.md](README.md) for the full architecture and [subgraph/mcp/SKILL.md](subgraph/mcp/SKILL.md) for agent tooling.
