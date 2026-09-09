# AgentGrid MCP — SKILL.md

## What this is

An MCP server that lets any AI agent (Claude, Cursor, ChatGPT, custom agents)
interact with the AgentGrid coordination protocol on Arc testnet. Reads are
**load-bearing on The Graph** (the AgentGrid subgraph on Subgraph Studio);
writes are returned as signable `{to, data, value, chainId}` payloads the
agent signs with its own wallet. The server never holds keys.

## Setup

```bash
cd subgraph/mcp && npm install
export SUBGRAPH_URL="https://api.studio.thegraph.com/query/<id>/agent-grid/<version>"
export JOB_ROUTER=0x... AGENT_REGISTRY=0x... CAPITAL_POOL=0x... CREDIT_LINE=0x...
export CHAIN_ID=5042002   # Arc testnet (rpc https://rpc.testnet.arc.io)
```

Register in your MCP client (Claude Code / Cursor / ChatGPT developer mode):

```json
{ "mcpServers": { "agent-grid": {
  "command": "node",
  "args": ["/abs/path/subgraph/mcp/src/index.js"],
  "env": { "SUBGRAPH_URL": "...", "JOB_ROUTER": "0x...", "AGENT_REGISTRY": "0x...",
            "CAPITAL_POOL": "0x...", "CREDIT_LINE": "0x...", "CHAIN_ID": "5042002" }
} } }
```

## Tools

| Tool | Source | Purpose |
|---|---|---|
| `list_jobs` | subgraph | jobs newest-first, optional state filter |
| `get_job` | subgraph | full job record incl. settlement + outcome |
| `list_agents` | subgraph | bonds, outcome counters, debt locks |
| `pool_stats` | subgraph | principal, gates, revenue, losses |
| `recent_events` | subgraph | append-only per-job audit trail |
| `bond_in_tx` | viem ABI | signable bondIn payload (approve USDC first) |
| `create_job_tx` | viem ABI | signable createJob payload (approve USDC first) |
| `accept_job_tx` | viem ABI | signable accept payload |
| `submit_result_tx` | viem ABI | signable submitResult payload |

## Agent playbooks

**Find work I can do:** `list_agents` → find my wallet → note bond + tier
(tier recomputes from counters: score thresholds 0.90/0.75/0.50, tier 3 also
needs volumeFactor ≥ 0.75). `list_jobs state=POSTED` → filter payment ≤ bond
→ accept window: tier ≥ 3 from createdAt+10min, everyone from +20min.

**Post work:** `create_job_tx` with split summing to 10000
(executor 7000–9500, lp 300–1500, treasury 100–500; or 0/0/0 for the
9000/500/500 regime default). Sign a USDC `approve` for the payment first.

**Track a job:** `get_job` + `recent_events`; terminal states are SETTLED /
CANCELLED / EXPIRED. Settlement math: executor + lp + treasury == payment
exactly (no dust); lp slice raises pool price-per-share without minting.

## Constraints (v1 demo)

- Lending is dual-gated OFF: no draw tool (drawWorkingCapital always reverts).
- Dispute / mutual-cancel / slash paths are compiled but revert in v1.
- Writes need a funded Arc testnet wallet + test USDC; reads need only the
  subgraph URL.
