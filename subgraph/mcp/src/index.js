// AgentGrid MCP server — stdio transport.
//
// READS (load-bearing on The Graph): list_jobs, get_job, list_agents,
// get_agent, pool_stats, recent_events — all served from the AgentGrid
// subgraph on Subgraph Studio. No chain RPC needed for reads.
//
// WRITES: returned as signable payloads {to, data, value, chainId} encoded
// with viem from the contract ABIs. The agent signs with its own wallet
// (viem/ethers/Metamask); this server never sees private keys.
//
// Env: SUBGRAPH_URL (required for reads), JOB_ROUTER, AGENT_REGISTRY,
// CAPITAL_POOL, CREDIT_LINE, CHAIN_ID (default 5042002 = Arc testnet).
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { encodeFunctionData, parseUnits } from "viem";
import { z } from "zod";
import { readFileSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

const SUBGRAPH_URL = process.env.SUBGRAPH_URL ?? "";
const CHAIN_ID = Number(process.env.CHAIN_ID ?? 5042002);
const ADDR = {
  router: process.env.JOB_ROUTER ?? "",
  registry: process.env.AGENT_REGISTRY ?? "",
  pool: process.env.CAPITAL_POOL ?? "",
  credit: process.env.CREDIT_LINE ?? "",
};

const here = dirname(fileURLToPath(import.meta.url));
const abis = {
  router: JSON.parse(readFileSync(join(here, "..", "..", "abis", "JobRouter.json"), "utf8")),
  registry: JSON.parse(readFileSync(join(here, "..", "..", "abis", "AgentRegistry.json"), "utf8")),
  pool: JSON.parse(readFileSync(join(here, "..", "..", "abis", "CapitalPool.json"), "utf8")),
};

async function gql(query, variables = {}) {
  if (!SUBGRAPH_URL) throw new Error("SUBGRAPH_URL is not set");
  const r = await fetch(SUBGRAPH_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ query, variables }),
  });
  const j = await r.json();
  if (j.errors) throw new Error(j.errors.map((e) => e.message).join("; "));
  return j.data;
}

function tx(to, data) {
  if (!to) throw new Error("contract address env is not set");
  return { to, data, value: "0", chainId: CHAIN_ID };
}

const server = new McpServer({ name: "agent-grid", version: "0.1.0" });

// ---------------- reads (The Graph) ----------------

server.tool(
  "list_jobs",
  "List indexed jobs, newest first. Filter by state (POSTED, ASSIGNED, SUBMITTED, SETTLED, CANCELLED, EXPIRED, DISPUTED).",
  { state: z.string().optional(), limit: z.number().min(1).max(100).default(20) },
  async ({ state, limit }) => {
    const where = state ? `(where: {state: "${state}"})` : "";
    const data = await gql(`{ jobs(first: ${limit}, orderBy: createdAt, orderDirection: desc ${where}) {
      id originator payment state executorBps lpBps treasuryBps assignedAgent outcome createdAt execDeadline } }`);
    return { content: [{ type: "text", text: JSON.stringify(data.jobs, null, 2) }] };
  }
);

server.tool(
  "get_job",
  "Full indexed record for one jobId, including settlement amounts and outcome.",
  { jobId: z.string() },
  async ({ jobId }) => {
    const data = await gql(`{ job(id: "${jobId}") {
      id originator specHash payment createdAt execDeadline approvalWindow acceptedAt
      executorBps lpBps treasuryBps assignedAgent resultHash drawnForJob opsBudget
      state executorPaid lpPaid treasuryPaid debtRepaid outcome } }`);
    return { content: [{ type: "text", text: JSON.stringify(data.job, null, 2) }] };
  }
);

server.tool(
  "list_agents",
  "List bonded agents with bond, outcome counters, settled volume, and debt-lock flag. Tier/score recompute client-side from counters (EWMA formula in README).",
  { limit: z.number().min(1).max(100).default(20) },
  async ({ limit }) => {
    const data = await gql(`{ agents(first: ${limit}, orderBy: bond, orderDirection: desc) {
      id wallet bond adapter externalId debtLocked success failure neutral fraud volume jobsAssigned } }`);
    return { content: [{ type: "text", text: JSON.stringify(data.agents, null, 2) }] };
  }
);

server.tool(
  "pool_stats",
  "CapitalPool index state: outstanding principal, lending gate, pause state, cumulative settlement revenue and reported losses.",
  {},
  async () => {
    const data = await gql(`{ pools(first: 1) {
      totalPrincipal lendEnabled paused revenueTotal lossTotal updatedAt } }`);
    return { content: [{ type: "text", text: JSON.stringify(data.pools?.[0] ?? null, null, 2) }] };
  }
);

server.tool(
  "recent_events",
  "Append-only per-job audit trail (Router Events tab). Kinds: Posted, Accepted, ResultSubmitted, Settled, Cancelled, Expired, DisputeOpened, DisputeResolved, TimeoutSettled, MutualCancelProposed, MutualCancelled, WorkingCapitalDrawn.",
  { limit: z.number().min(1).max(100).default(20) },
  async ({ limit }) => {
    const data = await gql(`{ jobEvents(first: ${limit}, orderBy: at, orderDirection: desc) {
      jobId kind at txHash } }`);
    return { content: [{ type: "text", text: JSON.stringify(data.jobEvents, null, 2) }] };
  }
);

// ---------------- writes (signable payloads) ----------------

server.tool(
  "bond_in_tx",
  "Build bondIn(adapter, externalId, amountUSDC) payload. NOTE: USDC approve() for the amount must be signed first.",
  { adapter: z.string(), externalId: z.string(), amountUSDC: z.string() },
  async ({ adapter, externalId, amountUSDC }) => {
    const data = encodeFunctionData({
      abi: abis.registry,
      functionName: "bondIn",
      args: [adapter, BigInt(externalId), parseUnits(amountUSDC, 6)],
    });
    return { content: [{ type: "text", text: JSON.stringify(tx(ADDR.registry, data), null, 2) }] };
  }
);

server.tool(
  "create_job_tx",
  "Build createJob(payment, specHash, split, execDeadline, approvalWindow, designatedAssignee, opsBudget) payload. Split must sum to 10000 within bounds (executor 7000-9500, lp 300-1500, treasury 100-500); use 0/0/0 for the regime default (9000/500/500 while lending is off). NOTE: USDC approve() for payment must be signed first. execDeadline/approvalWindow are unix seconds.",
  {
    paymentUSDC: z.string(),
    specHash: z.string(),
    executorBps: z.number(),
    lpBps: z.number(),
    treasuryBps: z.number(),
    execDeadline: z.string(),
    approvalWindow: z.string(),
    designatedAssignee: z.string().default("0x0000000000000000000000000000000000000000"),
    opsBudgetUSDC: z.string().default("0"),
  },
  async (a) => {
    const data = encodeFunctionData({
      abi: abis.router,
      functionName: "createJob",
      args: [
        parseUnits(a.paymentUSDC, 6),
        a.specHash,
        { executorBps: a.executorBps, lpBps: a.lpBps, treasuryBps: a.treasuryBps },
        BigInt(a.execDeadline),
        BigInt(a.approvalWindow),
        a.designatedAssignee,
        parseUnits(a.opsBudgetUSDC, 6),
      ],
    });
    return { content: [{ type: "text", text: JSON.stringify(tx(ADDR.router, data), null, 2) }] };
  }
);

server.tool(
  "accept_job_tx",
  "Build accept(jobId) payload. Caller must be bond-eligible with bond >= payment and inside its tier window (or the designated assignee).",
  { jobId: z.string() },
  async ({ jobId }) => {
    const data = encodeFunctionData({ abi: abis.router, functionName: "accept", args: [BigInt(jobId)] });
    return { content: [{ type: "text", text: JSON.stringify(tx(ADDR.router, data), null, 2) }] };
  }
);

server.tool(
  "submit_result_tx",
  "Build submitResult(jobId, resultHash) payload. Caller must be the assigned agent; must land before execDeadline.",
  { jobId: z.string(), resultHash: z.string() },
  async ({ jobId, resultHash }) => {
    const data = encodeFunctionData({
      abi: abis.router, functionName: "submitResult", args: [BigInt(jobId), resultHash],
    });
    return { content: [{ type: "text", text: JSON.stringify(tx(ADDR.router, data), null, 2) }] };
  }
);

const transport = new StdioServerTransport();
await server.connect(transport);
