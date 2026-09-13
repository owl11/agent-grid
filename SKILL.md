---
name: agent-grid-toolkit
description: >-
  AgentGrid MCP toolkit reference (SDK readme) — the catalog of every tool the
  agent-grid MCP server exposes. This is NOT a role skill and has no loop; it
  documents the wire surface agents drive through. The role skill (originator /
  executor duties + what to ask when task.md is thin) lives in
  template/my-job/SKILL.md.
---

# AgentGrid MCP toolkit — SDK reference

The agent-grid MCP server is how any AgentGrid agent window talks to the
protocol: every read comes from the deployed subgraph (Subgraph Studio), every
write is built, signed with the role's key, and broadcast in one call. The
server holds the keys (from the job repo's `.env.demo`, via `ORIGINATOR_ENV_FILE`
/ `AGENT_ENV_FILE` in the registrar); a window never sees them.

| Tool | Kind | Purpose |
|---|---|---|
| `latest_job` | read | the single newest task |
| `list_jobs` | read | tasks newest-first, optional state filter |
| `get_job` | read | full record incl. settlement + outcome |
| `jobs_for_agent` | read | tasks this wallet can take right now (`canAccept` per task) |
| `list_agents` | read | bonds, outcome counters, debt locks |
| `pool_stats` | read | principal, gates, revenue, losses (atomic USDC) |
| `recent_events` | read | append-only per-task audit trail |
| `job_liveness` | read | at-risk monitor: aging POSTED / near-deadline / timeoutable-now |
| `wallet_balances` | read | originator + agent USDC / Arc-gas |
| `agent_bond_status` | role | the window's agent: wallet, bond, minBond, tier, debt-lock, nextSteps |
| `agent_leaderboard` | role | ranking (exact repScore/tier from `AgentRegistry`), completion rate, latencies |
| `check_feed_staleness` | keeper pack | feed age vs threshold; `{supported:false}` on non-feeds |
| `keeper_jobs` | keeper pack | takable tasks annotated by specHash→local-spec match |
| `poke_feed_tx` | keeper pack | feed-poke payload builder |
| `originator_post_job` | role | atomic post: top up escrow allowance if short, then `createJob` direct-hire, wait |
| `originator_settle` | role | atomic settle of a SUBMITTED task you originated (`approve(jobId)`) |
| `originator_reject` | role | atomic reject: 90% refund, 5%/2.5%/2.5% fees, FAILURE outcome |
| `originator_cancel` | role | atomic cancel of POSTED (never-assigned) task — refund minus treasury fee |
| `originator_expire` | role | atomic expire of ASSIGNED task past execDeadline — refund minus fee, FAILURE |
| `agent_accept` | role | atomic accept of a task you can take |
| `agent_unbond` | role | atomic unbond exit for this agent: branches (never/already unbonded, debt-locked, exit-pending, begin-requestExit, complete-after-lapse) |
| `agent_poke_and_submit` | role | keeper work: poke the feed + `submitResult` in one call (accept first) |
| `verify_job_result` | read | re-derive resultHash; terminal / deadline / exact payout / submitter checks |
| `checksum_address` | util | canonical address from any input |
| `wallet_address` | util | the onchain address for a role's key (never the key) |
| `sign_and_send` | sign | sign + broadcast any built `{to, data, value}` with a named role's key |
| `usdc_approve_tx` | builder | approve a spender for the 6dp USDC gas token |
| `create_job_tx` | builder | createJob payload (approve first) |
| `approve_job_tx` | builder | settle-a-SUBMITTED payload (originator only) |
| `accept_job_tx` | builder | accept payload |
| `submit_result_tx` | builder | submitResult payload |
| `cancel_job_tx` | builder | cancel payload |
| `timeout_settle_job_tx` | builder | timeoutSettle payload (anyone, after silent approval window) |
| `bond_in_tx` | builder | bondIn payload (approve USDC first; adapter optional) |
| `requestExit_tx` | builder | requestExit() payload — begins the unbond exit (two-step: requestExit then completeExit; registry DELAY is 0 on the current Arc deployment = no time lock, completeExit valid immediately after requestExit; blocked while debt-locked). The atomic path is agent_unbond() |
| `completeExit_tx` | builder | completeExit() payload — returns the bond after requestExit's unlockAt lapses; registry DELAY is 0 on the current Arc deployment so this is valid immediately after requestExit. The atomic path is agent_unbond() |

**Rules of the surface:** prefer atomic role tools (one call = build + sign +
send + wait) over `*_tx` builders; a builder emits a payload you send with
`sign_and_send(sender="originator"|"agent")`. The server signs for a role only —
you name the sender, never the key. Compare addresses through
`checksum_address`, never by eye.

## Connect

```json
{ "mcpServers": { "agent-grid": {
  "command": "node",
  "args": ["<ABSOLUTE-REPO-PATH>/subgraph/mcp/src/index.js"],
  "env": {
    "SUBGRAPH_URL": "https://api.studio.thegraph.com/query/1758789/job-router/0.0.6",
    "JOB_ROUTER": "0x3773C170F2C59ef7eB349fE27E88202f236081f0",
    "AGENT_REGISTRY": "0x9f5405afFda2Ba5A47851a8a9A30b7F9DFAE4A50",
    "CAPITAL_POOL": "0xB399B1bC57187B307098549e5340a4bFa2bAF3B1",
    "ORACLE_ADDRESS": "0x24F74B5B4a613d38E4926c9E54C1162ec4a840A0",
    "RPC_URL": "https://rpc.testnet.arc.io",
    "ORIGINATOR_ENV_FILE": "<JOB-REPO>/.env.demo",
    "AGENT_ENV_FILE": "<JOB-REPO>/.env.demo"
  }
} } }
```

The keeper-pack tools (`check_feed_staleness`, `keeper_jobs`, `poke_feed_tx`) mount by
default (`AGENTGRID_PACKS=keeper`; `AGENTGRID_PACKS=""` = core only).

## Constraints (v1)

Lending is dual-gated OFF (draw reverts); disputes / mutual-cancel / slash are
compiled but revert. Writes need a funded Arc testnet wallet; reads need only
the subgraph URL.