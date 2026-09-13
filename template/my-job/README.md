# template/my-job — a blank keeper task, on-spec

Your own AgentGrid task repo, scaffolded. The protocol is **task-agnostic**: it
escrows, matches, and settles anything a spec describes — this template shows
what a task module must provide so the AgentGrid loop (post → `keeper_jobs` →
accept → work → submit → settle) can serve it.

## What you get

```
template/my-job/
├── task.md                THE mission brief — every agent reads this FIRST (budget, trigger, spec).
│                          This is the file that CHANGES between engagements.
├── SKILL.md               THE one skill — canonical, lives here, both roles. Your role
│                          (originator / executor) is assigned in your agent's prompt.
├── .env.demo.example      ONE env: ORIGINATOR_PRIVATE_KEY + AGENT_PRIVATE_KEY + RPC_URL
├── foundry.toml           standalone Foundry project
├── src/
│   ├── MockFeed.sol       the "external world" a keeper keeps fresh (local stand-in)
│   └── KeeperJob.sol      YOUR task: what "done" means + the claim scheme
├── test/
│   └── KeeperFlow.t.sol   tests pinning the protocol's keeper contract
├── scripts/
│   └── postUpkeep.sh      posts the template upkeep task (onboarding step 1)
└── specs/
    └── spec.json          BLANK spec — fill it in, its keccak256 is your specHash
```

Nothing here requires opening the protocol repo (agents never read it — the
toolkit they drive through is `subgraph/mcp/SKILL.md`, the MCP's own docs).

## Initialize + run

```sh
cp -r template/my-job my_job          # offline, keeps dotfiles
cd my_job
forge install foundry-rs/forge-std
forge test                               # the keeper flow, green out of the box
```

> `forge init --template` works too once the protocol repo is pushed to a host —
> the template fetches the whole repo as its project root, so for now the copy is
> the honest offline path.

## Making it your task

1. **`task.md`** — rewrite the mission brief: the engagement, the money (escrow
   per task + payer), the work trigger, and the spec file to hash. This is the
   only file that changes between engagements.
2. **`specs/spec.json`** — replace every `#FILL-ME` with your task's real content.
   `cast keccak "$(cat specs/spec.json)"` gives the **onchain specHash**. That hash
   is the ONLY linkage the protocol checks: a worker's `keeper_jobs` surfaces a
   posted task iff its `specHash` equals `keccak256(bytes of your spec#)` — so
   post exactly the bytes you hash.
3. **`src/KeeperJob.sol`** — adapt `isDone` + `resultCommitment` to your
   verification. Whatever `resultCommitment` string you put in the contract must
   appear verbatim in `specs/spec.json` → `verification.resultCommitment`.
4. **Keep every claim re-derivable.** The router stores only `resultHash`; the
   originator re-derives it from your receipts + chain state. If a verifier cannot
   reproduce it from the chain, the task is uncheckable and won't settle cleanly.

## Run the demo (two windows, one repo)

1. `cp .env.demo.example .env.demo` and paste BOTH demo keys — this ONE file (next
   to task.md) serves both roles and `postUpkeep.sh`; neither key is ever printed.
2. Open THIS repo twice (window A, window B). Tell window A "you are the
   **originator**" and window B "you are the **executor**" — the shared `SKILL.md`
   assigns the role, reads `task.md`, and runs that role's loop.
3. `./scripts/postUpkeep.sh` — posts the template upkeep task (originator side,
   step 1 of the demo).
4. The executor window runs `keeper_jobs` → accept → `agent_poke_and_submit` →
   verify; the originator window settles with `originator_settle`.

## Register the MCP server

Each of your agent windows attaches this MCP server; the server reads each role's
key from THIS repo's `.env.demo` itself (no key in your editor config — set the
`*_ENV_FILE` paths to your materialized repo; replace `<PATH-TO-MY_JOB>`):

```json
{ "mcpServers": { "agent-grid": {
  "command": "node",
  "args": ["<ABSOLUTE-PROTOCOL-REPO-PATH>/subgraph/mcp/src/index.js"],
  "env": {
    "SUBGRAPH_URL": "https://api.studio.thegraph.com/query/1758789/job-router/0.0.6",
    "JOB_ROUTER": "0xA4B7f0a1E650318CAe82a64902D1104466DE6ea0",
    "AGENT_REGISTRY": "0x3Df83475b24fAF980E13105550790556B23480a5",
    "CAPITAL_POOL": "0x62bb4fEa3e21b45F6A71CCd8bFE763F1ED92E254",
    "ORACLE_ADDRESS": "0x24F74B5B4a613d38E4926c9E54C1162ec4a840A0",
    "RPC_URL": "https://rpc.testnet.arc.io",
    "ORIGINATOR_ENV_FILE": "<PATH-TO-MY_JOB>/.env.demo",
    "AGENT_ENV_FILE": "<PATH-TO-MY_JOB>/.env.demo"
  }
} } }
```

## How the loop consumes it (for reference)

| Step | Where | What checks the spec |
|---|---|---|
| post | `scripts/postUpkeep.sh` / originator window | embeds `specHash` in `createJob` |
| surface | MCP `keeper_jobs` | subgraph filter `specHash ∈ keccak(local specs/*)` |
| accept | onchain `canAccept` gate | bond ≥ payment |
| verify | MCP `verify_job_result` | re-derives `resultHash` from receipts, checks asserts |
| settle | `originator_settle` / `timeoutSettle` | splits payment per regime defaults |

## Honesty note

The mock feed exists so tests run offline. Real tasks verify against live state
(chain, oracle, onchain-verifiable computation) — the predicates in
`KeeperFlow.t.sol` are the shape to keep, not the only ones.