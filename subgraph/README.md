# AgentGrid Subgraph

Indexes the four core contracts (JobRouter, AgentRegistry, CapitalPool, CreditLine) on Arc testnet. The MCP server reads exclusively through this subgraph.

## Structure

```
schema.graphql       Job, Agent, Pool, CreditPosition, JobEvent, WalletLink
subgraph.yaml        4 data sources
src/                 AssemblyScript mappings
abis/                Contract ABIs (re-exported from forge artifacts)
mcp/                 MCP server + SKILL.md
```

## Setup

1. Deploy contracts: `forge script script/Deploy.s.sol --rpc-url arc_testnet --broadcast`
2. Wire contract dependencies: `registry.setRouter`, `pool.setRouter`, `jobRouter.setCredit`, etc.
3. Fill `subgraph.yaml` with 4 contract addresses + start blocks:
   ```bash
   cd subgraph && npm run build && npm run deploy
   ```
4. Frontend + MCP read the pinned Studio endpoint (`SUBGRAPH_CONFIG.url` in `index.html`, `SUBGRAPH_URL` env for `mcp/`). No per-client configuration — update the constant on redeploy.

## Known Limitations

- `JobPosted` doesn't emit split/designatedAssignee — subgraph defaults (9000/500/500, open post); resolved client-side via `jobs(jobId)`.
- Registry write-paths are wallet-keyed — resolved via `WalletLink` (written on BondedIn).
