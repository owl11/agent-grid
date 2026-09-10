// AgentGrid MCP server — stdio transport.
//
// LAYERING (doctrine — keep it):
// - CORE (this file): protocol state via The Graph, receipt reads, file
//   mechanics, signable-payload builders. Never interprets domain semantics.
// - PACKS (keeper.js, ...): domain tooling for agent verticals, mounted
//   conditionally via AGENTGRID_PACKS (default: keeper on). Packs may read
//   feeds and specs; they may not touch settlement, reputation, or escrow.
//
// READS (load-bearing on The Graph): list_jobs, get_job, list_agents,
// pool_stats, recent_events — all served from the AgentGrid subgraph on
// Subgraph Studio. No chain RPC needed for reads.
//
// VERIFY reads (read-only RPC, never signs): verify_job_result checks the
// submit-tx sender via receipt. RPC_URL defaults to the Arc testnet public
// endpoint; the subgraph stays the source of truth for protocol state.
//
// WRITES: returned as signable payloads {to, data, value, chainId} encoded
// with viem from the contract ABIs. The agent signs with its own wallet
// (viem/ethers/Metamask); this server never sees private keys.
//
// Env: SUBGRAPH_URL (required for reads), JOB_ROUTER, AGENT_REGISTRY,
// CAPITAL_POOL, CREDIT_LINE, CHAIN_ID (default 5042002 = Arc testnet),
// RPC_URL (default https://rpc.testnet.arc.io, reads only), VOL_CAP,
// AGENTGRID_PACKS (comma list, default "keeper"; empty = core only).
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { encodeFunctionData, parseUnits } from "viem";
import { z } from "zod";
import { readFileSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";
import { loadLocalSpecs, readSpecFile } from "./specs.js";

const SUBGRAPH_URL = process.env.SUBGRAPH_URL ?? "";
const CHAIN_ID = Number(process.env.CHAIN_ID ?? 5042002);
const RPC_URL = process.env.RPC_URL ?? "https://rpc.testnet.arc.io";
const PACKS = (process.env.AGENTGRID_PACKS ?? "keeper").split(",").map((s) => s.trim()).filter(Boolean);
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

// ---------------- read-only chain access (verify paths only) ----------------

async function rpc(method, params, rpcUrl) {
  const url = rpcUrl || RPC_URL;
  if (!url) throw new Error("RPC_URL is not set");
  const r = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const j = await r.json();
  if (j.error) throw new Error(j.error.message || "rpc error");
  return j.result;
}

async function txSender(txHash, rpcUrl) {
  const tx = await rpc("eth_getTransactionByHash", [txHash], rpcUrl);
  if (!tx) throw new Error("transaction not found: " + txHash);
  return tx.from;
}

const server = new McpServer({ name: "agent-grid", version: "0.1.0" });

// ---------------- reads (The Graph) ----------------

server.tool(
  "list_jobs",
  "List indexed jobs, newest first. Filter by state (POSTED, ASSIGNED, SUBMITTED, SETTLED, CANCELLED, EXPIRED, DISPUTED).",
  { state: z.string().optional(), limit: z.number().min(1).max(100).default(20) },
  async ({ state, limit }) => {
    const where = state ? `, where: {state: "${state}"}` : "";
    const data = await gql(`{ jobs(first: ${limit}, orderBy: createdAt, orderDirection: desc${where}) {
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

// ---------------- reasoning (computed over indexed data) ----------------

// AgentRegistry.sol:18 — $100k USDC cap for volume factor. Env-overridable
// so a redeploy with a new cap doesn't need a code change here.
const VOL_CAP = BigInt(process.env.VOL_CAP ?? "100000000000");
const E18 = 10n ** 18n;

function tierOf(score, volume) {
  const vf = (volume > VOL_CAP ? VOL_CAP : volume) * E18 / VOL_CAP;
  const s = score * vf / E18; // == repScore: ewma x volumeFactor (registry repScore)
  const tier = (s >= 9n * 10n ** 17n && vf >= 75n * 10n ** 16n) ? 3
    : s >= 75n * 10n ** 16n ? 2
    : s >= 5n * 10n ** 17n ? 1 : 0;
  return { score: s.toString(), volumeFactor: vf.toString(), tier };
}

server.tool(
  "agent_leaderboard",
  "Ranked agents by exact onchain reputation: recomputes repScore/tier bit-for-bit from indexed EWMA score + volume (same formula as AgentRegistry.tier). Includes completion rate and average accept/submit/settle latencies from indexed timing fields.",
  { limit: z.number().min(1).max(100).default(20) },
  async ({ limit }) => {
    const data = await gql(`{ agents(first: ${limit}, orderBy: bond, orderDirection: desc) {
      id wallet bond success failure neutral fraud volume jobsAssigned jobsCompleted
      score acceptLatencyTotal submitLatencyTotal settleLatencyTotal debtLocked } }`);
    const rows = data.agents.map((a) => {
      const t = tierOf(BigInt(a.score), BigInt(a.volume));
      const done = a.jobsCompleted > 0;
      return {
        id: a.id, wallet: a.wallet, bond: a.bond, debtLocked: a.debtLocked,
        tier: t.tier, repScore: t.score,
        success: a.success, failure: a.failure, neutral: a.neutral, fraud: a.fraud,
        completionRate: a.jobsAssigned > 0 ? a.jobsCompleted / a.jobsAssigned : null,
        avgAcceptLatencySec: done ? Number(BigInt(a.acceptLatencyTotal) / BigInt(a.jobsCompleted)) : null,
        avgSubmitLatencySec: done ? Number(BigInt(a.submitLatencyTotal) / BigInt(a.jobsCompleted)) : null,
        avgSettleLatencySec: done ? Number(BigInt(a.settleLatencyTotal) / BigInt(a.jobsCompleted)) : null,
      };
    });
    rows.sort((x, y) => y.tier - x.tier || (BigInt(y.repScore) > BigInt(x.repScore) ? 1 : -1));
    return { content: [{ type: "text", text: JSON.stringify(rows, null, 2) }] };
  }
);

server.tool(
  "job_liveness",
  "At-risk monitor over live jobs: aging POSTED (unpicked >1h), ASSIGNED near/past execDeadline (<6h left), SUBMITTED near/past approvalDeadline (<2h left, else timeoutable now). Timestamps are unix seconds.",
  {},
  async () => {
    const now = Math.floor(Date.now() / 1000);
    const data = await gql(`{ posted: jobs(where: {state: "POSTED"}, orderBy: createdAt, orderDirection: asc, first: 50) {
        id payment createdAt designatedAssignee }
      assigned: jobs(where: {state: "ASSIGNED"}, orderBy: execDeadline, orderDirection: asc, first: 50) {
        id payment execDeadline assignedWallet }
      submitted: jobs(where: {state: "SUBMITTED"}, orderBy: approvalDeadline, orderDirection: asc, first: 50) {
        id payment approvalDeadline assignedWallet } }`);
    const agingPosted = data.posted
      .filter((j) => now - Number(j.createdAt) > 3600)
      .map((j) => ({ ...j, ageSec: now - Number(j.createdAt) }));
    const execRisk = data.assigned.map((j) => ({ ...j, leftSec: Number(j.execDeadline) - now }));
    const approvalRisk = data.submitted.map((j) => ({ ...j, leftSec: Number(j.approvalDeadline) - now }));
    return { content: [{ type: "text", text: JSON.stringify({
      now, execRiskHorizonSec: 6 * 3600, approvalRiskHorizonSec: 2 * 3600,
      agingPosted,
      execRisk: execRisk.filter((j) => j.leftSec < 6 * 3600),
      approvalRisk: approvalRisk.filter((j) => j.leftSec < 2 * 3600),
      timeoutableNow: approvalRisk.filter((j) => j.leftSec <= 0).map((j) => j.id),
    }, null, 2) }] };
  }
);

server.tool(
  "verify_job_result",
  "Verify a job's result: terminal state/outcome, submit-before-deadline (indexed timing), payout sums exactly to payment (no dust), resultHash present, submit-tx sender equals the assigned agent (receipt check). Links the resolved spec's asserts as a checklist (live feed measurement lives in the keeper pack's check_feed_staleness).",
  { jobId: z.string(), rpcUrl: z.string().optional() },
  async ({ jobId, rpcUrl }) => {
    const data = await gql(`{ job(id: "${jobId}") {
      id state outcome payment executorPaid lpPaid treasuryPaid assignedAgent assignedWallet
      resultHash submittedAt execDeadline specHash } }`);
    const j = data.job;
    if (!j) return { content: [{ type: "text", text: "job not found" }] };
    const sum = BigInt(j.executorPaid) + BigInt(j.lpPaid) + BigInt(j.treasuryPaid);
    const ZERO = "0x0000000000000000000000000000000000000000000000000000000000000000";
    const ZERO_ADDR = "0x0000000000000000000000000000000000000000";
    const checks = [
      { name: "terminal", pass: ["SETTLED", "CANCELLED", "EXPIRED"].includes(j.state), detail: `${j.state}/${j.outcome ?? "-"}` },
      { name: "submittedBeforeDeadline", pass: j.submittedAt !== "0" && BigInt(j.submittedAt) <= BigInt(j.execDeadline), detail: `submittedAt=${j.submittedAt} execDeadline=${j.execDeadline}` },
      { name: "payoutExact", pass: j.state === "SETTLED" ? sum === BigInt(j.payment) : true, detail: `executorPaid+lpPaid+treasuryPaid=${sum} payment=${j.payment}` },
      { name: "resultPresent", pass: j.resultHash !== ZERO, detail: j.resultHash },
      { name: "assigneeKnown", pass: j.assignedWallet !== ZERO_ADDR, detail: j.assignedWallet },
    ];
    // Receipt linkage: the ResultSubmitted tx must come from the assignee.
    // Only meaningful once a result exists; otherwise n/a (not a failure).
    if (j.resultHash !== ZERO) {
      try {
        const ev = await gql(`{ jobEvents(where: {jobId: "${jobId}", kind: "ResultSubmitted"}, first: 1) { txHash } }`);
        const txHash = ev.jobEvents?.[0]?.txHash;
        if (!txHash) {
          checks.push({ name: "submitterMatches", pass: false, detail: "no indexed ResultSubmitted event" });
        } else {
          const from = await txSender(txHash, rpcUrl);
          checks.push({
            name: "submitterMatches",
            pass: from.toLowerCase() === j.assignedWallet.toLowerCase(),
            detail: `tx ${txHash} from=${from} assignee=${j.assignedWallet}`,
          });
        }
      } catch (e) {
        checks.push({ name: "submitterMatches", pass: false, detail: "receipt read failed: " + (e.reason || e.message) });
      }
    } else {
      checks.push({ name: "submitterMatches", pass: true, detail: "n/a (no result submitted)" });
    }
    // Spec linkage: onchain specHash first (cryptographic — job ids recycle
    // across deployments, filenames don't), local file by id as fallback.
    // Asserts are listed verbatim for the agent/judge to evaluate; live
    // measurement of feed asserts belongs to the keeper pack.
    let spec = loadLocalSpecs()[String(j.specHash).toLowerCase()]?.spec ?? null;
    if (!spec?.verification) {
      spec = readSpecFile(jobId);
    }
    const manual = [];
    if (spec?.verification?.asserts) {
      for (const a of spec.verification.asserts) manual.push(a);
    }
    return { content: [{ type: "text", text: JSON.stringify({ jobId, checks, manualAsserts: manual }, null, 2) }] };
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

// ---------------- packs (domain tooling, conditional) ----------------

if (PACKS.includes("keeper")) {
  const { registerKeeperTools } = await import("./keeper.js");
  registerKeeperTools(server, { gql, rpc });
}

const transport = new StdioServerTransport();
await server.connect(transport);
