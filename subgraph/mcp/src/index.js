// AgentGrid MCP server (stdio). State reads come from the AgentGrid subgraph
// (SUBGRAPH_URL); writes are returned as signable payloads {to,data,value,
// chainId} that the agent signs itself — this server never sees private keys.
// RPC_URL is read-only, used only to link submit-tx senders during verify.
//
// Env: SUBGRAPH_URL*, JOB_ROUTER, AGENT_REGISTRY, CAPITAL_POOL, CREDIT_LINE,
// CHAIN_ID (default 5042002), RPC_URL, VOL_CAP, AGENTGRID_PACKS ("keeper").
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  createPublicClient,
  createWalletClient,
  decodeFunctionResult,
  encodeFunctionData,
  formatUnits,
  getAddress,
  http,
  keccak256,
  parseUnits,
  toBytes,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { z } from "zod";
import { readFileSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";
import { loadLocalSpecs, readSpecFile } from "./specs.js";
import { tierOf } from "./reputation.js";

// Dotenv comes first so the consts below (RPC_URL, SUBGRAPH_URL, addresses)
// can default from the demo env files instead of a hardcoded RPC. A job-test
// repo carries ONE dotenv file at its root, right next to job.md — ".env.demo"
// during the demo (that name is the demo convention) or plain ".env" for real
// protocol users. Both roles read the SAME file, each taking its own key line
// (ORIGINATOR_PRIVATE_KEY / AGENT_PRIVATE_KEY). There is NO protocol-repo key
// file — the keys live ONLY in the job repo, so the resolver needs
// ORIGINATOR_ENV_FILE / AGENT_ENV_FILE (or ORIGINATOR_REPO_DIR / AGENT_REPO_DIR,
// which joins "<repo>/.env.demo") pointing there; with neither, the role is
// simply unavailable and its tools say so (a registrar env-block key still
// counts).
//
// Precedence for a value: process env (e.g. the Cline MCP env block) WINS over
// an env file — except role PRIVATE KEYS, where the resolved env file always
// wins so ops can't be silently pointed at forgotten keys. Keys are never
// output. Startup diagnostics go to stderr: stdout is the MCP protocol channel
// and must stay clean.
const here = dirname(fileURLToPath(import.meta.url));
const ROLE_KEY = { originator: "ORIGINATOR_PRIVATE_KEY", agent: "AGENT_PRIVATE_KEY" };

function roleEnvFile(role) {
  const isOrig = role === "originator";
  const explicit = process.env[isOrig ? "ORIGINATOR_ENV_FILE" : "AGENT_ENV_FILE"];
  const repoDir = process.env[isOrig ? "ORIGINATOR_REPO_DIR" : "AGENT_REPO_DIR"];
  const candidates = explicit
    ? [explicit]
    : [repoDir && join(repoDir, ".env.demo"), repoDir && join(repoDir, ".env")].filter(Boolean);
  return candidates.find((f) => {
    try { readFileSync(f, "utf8"); return true; } catch { return false; }
  });
}

function readDotenvKey(file, key) {
  const text = readFileSync(file, "utf8");
  for (const line of text.split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
    if (m && m[1] === key) return m[2].replace(/^["']|["']$/g, "");
  }
  return undefined;
}

// Lay every KEY=VALUE from a dotenv file into process.env as a DEFAULT only —
// anything already set (registrar JSON env block) keeps its value. Empty values
// are skipped so a commented-out line can't blank an address.
function applyDotenvDefaults(file) {
  if (!file) return;
  const text = readFileSync(file, "utf8");
  for (const line of text.split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
    if (!m || m[1] in process.env) continue;
    const value = m[2].replace(/^["']|["']$/g, "");
    if (value !== "") process.env[m[1]] = value;
  }
}

const resolvedRoleFile = {};
for (const role of ["originator", "agent"]) {
  const file = roleEnvFile(role);
  resolvedRoleFile[role] = file;
  if (!file) {
    if (process.env[ROLE_KEY[role]]) {
      console.error(`[agent-grid mcp] ${role} key: from the server env block`);
      continue;
    }
    console.error(`[agent-grid mcp] ${role} key: NO FILE — set ${role === "originator" ? "ORIGINATOR_ENV_FILE" : "AGENT_ENV_FILE"} (or *_REPO_DIR) to the job repo's .env.demo`);
    continue; // the role is simply unavailable; its tools will say so
  }
  const key = readDotenvKey(file, ROLE_KEY[role]);
  if (!key) {
    console.error(`[agent-grid mcp] ${role} key: ${file} exists but has no ${ROLE_KEY[role]}`);
    continue;
  }
  process.env[ROLE_KEY[role]] = key; // file wins over any stale env block
  console.error(`[agent-grid mcp] ${role} key: ${file}`);
}
// The job repo's single root .env.demo may carry infra defaults (RPC_URL,
// addresses); apply them so the whole demo config rides along with the repo.
applyDotenvDefaults(resolvedRoleFile.agent);
applyDotenvDefaults(resolvedRoleFile.originator);

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
const USDC_ADDR = process.env.USDC_TOKEN ?? "0x3600000000000000000000000000000000000000";

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

// read-only chain access (verify paths only)

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

// --- optional server-side sign + broadcast ---------------------------------
// Only active when a role key is in this server's env. The key never appears
// in any tool output or log; the agent only ever names the role ("agent" or
// "originator"). Writes are still available as unsigned payloads via the *_tx
// tools for any external signer.

const ARC = {
  id: CHAIN_ID,
  name: "Arc Testnet",
  network: "arc-testnet",
  nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 6 },
  rpcUrls: { default: { http: [RPC_URL] } },
};

function signerKeyFor(sender) {
  if (sender === "originator") return process.env.ORIGINATOR_PRIVATE_KEY ?? "";
  return process.env.AGENT_PRIVATE_KEY ?? "";
}

async function signAndSend(to, data, value, sender) {
  const key = signerKeyFor(sender);
  if (!key) {
    throw new Error(
      `no ${sender} key in server env (set ${sender === "originator" ? "ORIGINATOR_PRIVATE_KEY" : "AGENT_PRIVATE_KEY"} in the MCP server's environment)`
    );
  }
  const account = privateKeyToAccount(key);
  const client = createWalletClient({ account, chain: ARC, transport: http(RPC_URL) });
  const request = { to, data, value: BigInt(value), chain: ARC };
  let hash;
  try {
    hash = await client.sendTransaction(request);
  } catch (e) {
    // networks without an EIP-1559 base-fee market fall back to legacy gas
    const gasPrice = await rpc("eth_gasPrice", []);
    hash = await client.sendTransaction({ ...request, type: "legacy", gasPrice: BigInt(gasPrice) });
  }
  const publicClient = createPublicClient({ chain: ARC, transport: http(RPC_URL) });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  return {
    txHash: hash,
    status: receipt.status,
    blockNumber: String(receipt.blockNumber),
    from: account.address,
  };
}

const server = new McpServer({ name: "agent-grid", version: "0.1.0" });

// reads (The Graph)

server.tool(
  "list_jobs",
  "List indexed jobs, newest first. Filter by state (POSTED, ASSIGNED, SUBMITTED, SETTLED, CANCELLED, EXPIRED, DISPUTED).",
  { state: z.string().optional(), limit: z.number().min(1).max(100).default(5) },
  async ({ state, limit }) => {
    const where = state ? `, where: {state: "${state}"}` : "";
    const data = await gql(`{ jobs(first: ${limit}, orderBy: createdAt, orderDirection: desc${where}) {
      id originator payment state executorBps lpBps treasuryBps assignedAgent outcome createdAt execDeadline } }`);
    return { content: [{ type: "text", text: JSON.stringify(data.jobs, null, 2) }] };
  }
);

server.tool(
  "latest_job",
  "The newest indexed job (highest jobId / most recent createdAt).",
  {},
  async () => {
    const data = await gql(`{ jobs(first: 1, orderBy: createdAt, orderDirection: desc) {
      id originator payment state executorBps lpBps treasuryBps assignedAgent outcome createdAt execDeadline } }`);
    return { content: [{ type: "text", text: JSON.stringify(data.jobs[0] ?? null, null, 2) }] };
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
  "jobs_for_agent",
  "POSTED jobs this agent wallet can currently accept. Onchain truth: for every posted job we eth_call router.canAccept(jobId, wallet) and return the jobs that answer true (window open, bond >= payment, eligible, direct-hire match). Also reports each rejected job's reason from the same call.",
  { wallet: z.string(), limit: z.number().min(1).max(100).default(10), rpcUrl: z.string().optional() },
  async ({ wallet, limit, rpcUrl }) => {
    const data = await gql(`{ jobs(orderBy: createdAt, orderDirection: desc, first: ${limit}, where: {state: "POSTED"}) {
      id payment execDeadline createdAt designatedAssignee specHash } }`);
    const ZERO = "0x" + "00".repeat(32);
    const ok = [];
    const blocked = [];
    for (const j of data.jobs ?? []) {
      const calldata = encodeFunctionData({
        abi: abis.router, functionName: "canAccept", args: [BigInt(j.id), wallet],
      });
      const raw = await rpc("eth_call", [{ to: ADDR.router, data: calldata }, "latest"], rpcUrl);
      const can = raw !== undefined && raw !== null && BigInt(raw).toString(2) === "1";
      if (can) ok.push(j);
      else blocked.push({ ...j, fee: 0, reason: "canAccept=false (window, bond, eligibility, or direct-hire mismatch)" });
    }
    return { content: [{ type: "text", text: JSON.stringify({ wallet, acceptable: ok, blocked }, null, 2) }] };
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
  { limit: z.number().min(1).max(100).default(5) },
  async ({ limit }) => {
    const data = await gql(`{ jobEvents(first: ${limit}, orderBy: at, orderDirection: desc) {
      jobId kind at txHash } }`);
    return { content: [{ type: "text", text: JSON.stringify(data.jobEvents, null, 2) }] };
  }
);

// reasoning (computed over indexed data)

// tierOf() lives in ./reputation.js — bit-for-bit mirror of AgentRegistry
// repScore()/tier(), including the den == 0 → flat DEFAULT_REP early return
// (fresh agents are tier 1 onchain; the old inline copy collapsed them to 0).

server.tool(
  "agent_leaderboard",
  "Ranked agents by exact onchain reputation: recomputes repScore/tier bit-for-bit from indexed EWMA score + volume (same formula as AgentRegistry.tier). Includes completion rate and average accept/submit/settle latencies from indexed timing fields.",
  { limit: z.number().min(1).max(100).default(20) },
  async ({ limit }) => {
    const data = await gql(`{ agents(first: ${limit}, orderBy: bond, orderDirection: desc) {
      id wallet bond success failure neutral fraud volume jobsAssigned jobsCompleted
      score acceptLatencyTotal submitLatencyTotal settleLatencyTotal debtLocked } }`);
    const rows = data.agents.map((a) => {
      // hasOutcomes == den != 0 onchain: any non-NEUTRAL outcome ever recorded
      // (NEUTRAL is weight-zero). den == 0 → registry returns DEFAULT_REP flat.
      const t = tierOf(
        BigInt(a.score), BigInt(a.volume),
        BigInt(a.success) + BigInt(a.failure) + BigInt(a.fraud) > 0n,
      );
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
    // Query scans the full oldest/deadline-nearest set; the RESPONSE only
    // carries the 5 most critical per bucket so a stray call stays cheap.
    const top5 = (rows) => rows.slice(0, 5);
    return { content: [{ type: "text", text: JSON.stringify({
      now, execRiskHorizonSec: 6 * 3600, approvalRiskHorizonSec: 2 * 3600,
      agingPosted: top5(agingPosted),
      execRisk: top5(execRisk.filter((j) => j.leftSec < 6 * 3600)),
      approvalRisk: top5(approvalRisk.filter((j) => j.leftSec < 2 * 3600)),
      timeoutableNow: approvalRisk.filter((j) => j.leftSec <= 0).slice(0, 5).map((j) => j.id),
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
    // Receipt linkage: the ResultSubmitted tx must be sent by the assignee;
    // only meaningful once a result exists, otherwise n/a (not a failure).
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
    // across deployments), local file by id as fallback. Asserts are listed
    // verbatim; live feed measurement lives in the keeper pack.
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

// writes (signable payloads)

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
  "requestExit_tx",
  "Build requestExit() payload for the caller's wallet: begins the unbond exit (sets unlockAt = now + DELAY, refused while debt-locked). The registry's DELAY is 0 on the current Arc deployment, so completeExit is valid immediately after requestExit (no time lock); test configs use 7 days. Complete the exit with completeExit() after unlockAt lapses. NOTE: the atomic agent tool agent_unbond() does requestExit for you (and only when there is no pending exit).",
  {},
  async () => {
    const data = encodeFunctionData({ abi: abis.registry, functionName: "requestExit", args: [] });
    return { content: [{ type: "text", text: JSON.stringify(tx(ADDR.registry, data), null, 2) }] };
  }
);

server.tool(
  "completeExit_tx",
  "Build completeExit() payload for the caller's wallet: returns the escrowed bond and clears the exit. Only valid after requestExit's unlockAt has lapsed (or never set); reverts UnlockPending otherwise. The registry's DELAY is 0 on the current Arc deployment, so completeExit is valid immediately after requestExit (no time lock); test configs use 7 days. NOTE: the atomic agent tool agent_unbond() is the happy path; call this only to finish an already-pending exit.",
  {},
  async () => {
    const data = encodeFunctionData({ abi: abis.registry, functionName: "completeExit", args: [] });
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

server.tool(
  "approve_job_tx",
  "Build the originator-side approve(jobId) payload: settles a SUBMITTED job and pays out the split. Only the job's originator may call it. Sign + send via sign_and_send(sender=originator) or your own signer.",
  { jobId: z.string() },
  async ({ jobId }) => {
    const data = encodeFunctionData({ abi: abis.router, functionName: "approve", args: [BigInt(jobId)] });
    return { content: [{ type: "text", text: JSON.stringify(tx(ADDR.router, data), null, 2) }] };
  }
);

server.tool(
  "timeout_settle_job_tx",
  "Build timeoutSettle(jobId) payload: settles a SUBMITTED job past its approval deadline (originator ghosted or slow). Any caller may pay it.",
  { jobId: z.string() },
  async ({ jobId }) => {
    const data = encodeFunctionData({ abi: abis.router, functionName: "timeoutSettle", args: [BigInt(jobId)] });
    return { content: [{ type: "text", text: JSON.stringify(tx(ADDR.router, data), null, 2) }] };
  }
);

server.tool(
  "cancel_job_tx",
  "Build cancel(jobId) payload: the originator may cancel a POSTED job and get the escrow back.",
  { jobId: z.string() },
  async ({ jobId }) => {
    const data = encodeFunctionData({ abi: abis.router, functionName: "cancel", args: [BigInt(jobId)] });
    return { content: [{ type: "text", text: JSON.stringify(tx(ADDR.router, data), null, 2) }] };
  }
);

server.tool(
  "usdc_approve_tx",
  "Build USDC approve(spender, amountUSDC) for the 6dp gas token (0x3600...0000). The router needs allowance to escrow payment; the registry needs it for bond. Sign + send via sign_and_send. spender defaults to env JOB_ROUTER.",
  { spender: z.string().optional(), amountUSDC: z.string() },
  async ({ spender, amountUSDC }) => {
    const target = spender || process.env.JOB_ROUTER;
    if (!target) throw new Error("no spender (pass spender or set JOB_ROUTER in server env)");
    const data = encodeFunctionData({
      abi: [
        {
          type: "function", name: "approve",
          inputs: [{ type: "address" }, { type: "uint256" }],
          outputs: [{ type: "bool" }], stateMutability: "nonpayable",
        },
      ],
      functionName: "approve", args: [target, parseUnits(amountUSDC, 6)],
    });
    return { content: [{ type: "text", text: JSON.stringify(tx(USDC_ADDR, data), null, 2) }] };
  }
);

server.tool(
  "keccak256_helper",
  "keccak256 of a UTF-8 string (a leading 0x is stripped). Use it to derive job result commitments, e.g. RESULT = keccak256_helper('<pokeTxHash>:<postUpdatedAt>') — keccak of the ASCII '<hash-without-0x>:<unix seconds>'.",
  { input: z.string() },
  async ({ input }) => {
    const clean = input.replace(/^0x/, "");
    return { content: [{ type: "text", text: keccak256(toBytes(clean)) }] };
  }
);

server.tool(
  "sign_and_send",
  "Sign + broadcast a tx payload the server built (or any {to,data,value}), using the private key in THIS server's env for the named role. The key never leaves the server and never appears in output — you only name the sender. Waits for the receipt and returns txHash/status/blockNumber. sender 'agent'=AGENT_PRIVATE_KEY, 'originator'=ORIGINATOR_PRIVATE_KEY.",
  {
    to: z.string(),
    data: z.string(),
    value: z.string().default("0"),
    sender: z.enum(["agent", "originator"]).default("agent"),
  },
  async ({ to, data, value, sender }) => {
    const res = await signAndSend(to, data, value, sender);
    return { content: [{ type: "text", text: JSON.stringify(res, null, 2) }] };
  }
);

server.tool(
  "wallet_address",
  "Return the onchain address for a role's key in this server's env (agent => AGENT_PRIVATE_KEY, originator => ORIGINATOR_PRIVATE_KEY). Never returns the key itself — only the derived address.",
  { sender: z.enum(["agent", "originator"]).default("agent") },
  async ({ sender }) => {
    const key = signerKeyFor(sender);
    if (!key) throw new Error(`no ${sender} key in server env`);
    return { content: [{ type: "text", text: privateKeyToAccount(key).address }] };
  }
);

server.tool(
  "agent_bond_status",
  "FIRST tool an agent runs before anything else: derive this server's agent wallet from AGENT_PRIVATE_KEY — IN MEMORY ONLY, the key is never read back, echoed, or logged (startup logs the env FILE, never the key) — then report its live AgentRegistry state: is it bonded/registered, minBond, bond amount, agentId, exit/unlock status, debt lock, tier. If NOT bonded the response spells out the exact two-step setup (usdc_approve_tx for the registry + bond_in_tx) instead of guessing. \"Registered\" IS \"bonded\" on AgentRegistry: bondIn() writes the record, so there is no separate register step.",
  {},
  async () => {
    const key = signerKeyFor("agent");
    if (!key) throw new Error("no agent key in server env (set AGENT_ENV_FILE to the job repo's .env.demo)");
    let wallet;
    try {
      wallet = privateKeyToAccount(key).address;
    } catch {
      throw new Error(
        "the resolved agent key file does not contain a valid private key — rewrite .env.demo from .env.demo.example and rerun " +
        "(the key itself is never echoed; the invalid value stays in the server)"
      );
    }
    if (!ADDR.registry) throw new Error("AGENT_REGISTRY env is not set");
    const view = async (functionName, args) => {
      const data = encodeFunctionData({ abi: abis.registry, functionName, args });
      const raw = await rpc("eth_call", [{ to: ADDR.registry, data }, "latest"]);
      return decodeFunctionResult({ abi: abis.registry, functionName, data: raw });
    };
    const rec = await view("agentRecord", [wallet]);
    const minBond = await view("minBond", []);
    const [debtLocked, tier] = await Promise.all([
      view("isDebtLocked", [wallet]),
      view("tier", [wallet]),
    ]);
    // agentRecord(address) -> (bond, registeredAt, exitAt, agentId, adapter, externalId, revoked)
    const [bond, registeredAt, exitAt, agentId, adapter, externalId, revoked] = rec;
    const bonded = bond > 0n;
    const registration = {
      wallet,
      bonded,
      minBondUSDC: formatUnits(minBond, 6),
      bondUSDC: formatUnits(bond, 6),
      registeredAt: registeredAt.toString(),
      exitPending: exitAt.toString(),
      agentId,
      adapter,
      externalId: String(externalId),
      revoked: Boolean(revoked),
      debtLocked: Boolean(debtLocked),
      tier: Number(tier),
    };
    if (!bonded) {
      registration.verdict = "NOT BONDED — you are not registered on AgentRegistry.";
      registration.nextSteps = [
        `usdc_approve_tx(spender="${ADDR.registry}", amountUSDC="${formatUnits(minBond, 6)}") then sign_and_send(sender="agent")`,
        `bond_in_tx(adapter="0x0000000000000000000000000000000000000000", externalId="0", amountUSDC="${formatUnits(minBond, 6)}") then sign_and_send(sender="agent")`,
        "rerun agent_bond_status — bonded:true means you may proceed to keeper_jobs / jobs_for_agent",
      ];
    } else {
      registration.verdict = (revoked
        ? "BONDED but REVOKED on AgentRegistry — resolve revocation before taking jobs."
        : debtLocked
        ? "BONDED but DEBT-LOCKED — settle debt before taking jobs."
        : "BONDED and in good standing — run keeper_jobs to find work. To leave the registry, call agent_unbond() (begins the exit; see its nextSteps).");
    }
    return { content: [{ type: "text", text: JSON.stringify(registration, null, 2) }] };
  }
);

// composite writes (build + sign + send for a named role). HAPPY PATH tools:
// no calldata hex ever touches the conversation — one call, one {txHash,...}.
// The *_tx builder tools stay available for external signers / debugging.

server.tool(
  "agent_unbond",
  "Atomic agent action: begin or complete the unbond exit for THIS agent's wallet, in one call. The AgentRegistry exit is a two-step cast (requestExit sets unlockAt = now + DELAY; completeExit pays out after it lapses; the registry's DELAY is 0 on the current Arc deployment, so completeExit is valid immediately after requestExit — no time lock; test configs use 7 days) and the exit is blocked while the agent is debt-locked. This tool handles the branching: (1) never/already unbonded (bond == 0) -> reports 'nothing to do'; (2) debt-locked -> refuses with the reason and tells you to settle debt first; (3) an exit already pending (unlockAt in the future) -> reports the unlockAt and tells you to call agent_unbond again (or completeExit_tx + sign_and_send) after it lapses; (4) no pending exit -> runs requestExit() for you now and reports the new unlockAt plus the next step. To finish a pending exit yourself (after the delay lapses), use completeExit_tx + sign_and_send(sender=\"agent\"), or just call agent_unbond() again — it will complete the exit when unlockAt has lapsed.",
  {},
  async () => {
    const key = signerKeyFor("agent");
    if (!key) throw new Error("no agent key in server env (set AGENT_ENV_FILE to the job repo's .env.demo)");
    const wallet = privateKeyToAccount(key).address;
    if (!ADDR.registry) throw new Error("AGENT_REGISTRY env is not set");
    const view = async (functionName, args) => {
      const data = encodeFunctionData({ abi: abis.registry, functionName, args });
      const raw = await rpc("eth_call", [{ to: ADDR.registry, data }, "latest"]);
      return decodeFunctionResult({ abi: abis.registry, functionName, data: raw });
    };
    const rec = await view("agentRecord", [wallet]);
    const [bond, , exitAt, agentId, adapter, externalId, revoked] = rec;
    const debtLocked = await view("isDebtLocked", [wallet]);
    const now = BigInt(Math.floor(Date.now() / 1000));
    const exitAtBig = BigInt(exitAt.toString());
    const bonded = bond > 0n;
    const exitPending = exitAtBig > 0n && exitAtBig > now;
    const exitLapsed = exitAtBig > 0n && exitAtBig <= now;

    if (!bonded) {
      return {
        content: [{
          type: "text",
          text: JSON.stringify({
            wallet,
            bonded: false,
            verdict: "NOT BONDED — nothing to unbond. You are not registered on AgentRegistry. To become bonded, follow agent_bond_status.nextSteps (usdc_approve_tx + bond_in_tx), then rerun agent_bond_status until bonded:true.",
            exitPending: false,
            nextStep: null,
          }, null, 2),
        }],
      };
    }

    if (debtLocked) {
      return {
        content: [{
          type: "text",
          text: JSON.stringify({
            wallet,
            bonded: true,
            bondUSDC: formatUnits(bond, 6),
            debtLocked: true,
            exitPending: exitPending || exitLapsed,
            exitAt: exitAt.toString(),
            verdict: "BONDED but DEBT-LOCKED — you cannot exit while credit debt is outstanding (the registry blocks requestExit). Settle the debt first (the credit line clears the debt lock); then call agent_unbond() again.",
            nextStep: "resolve the debt lock, then call agent_unbond() again",
          }, null, 2),
        }],
      };
    }

    if (exitPending) {
      return {
        content: [{
          type: "text",
          text: JSON.stringify({
            wallet,
            bonded: true,
            bondUSDC: formatUnits(bond, 6),
            debtLocked: false,
            exitPending: true,
            exitAt: exitAt.toString(),
            verdict: "EXIT PENDING — you already requested to unbond; the bond is locked until unlockAt lapses. Do NOT call requestExit again (it reverts). Call agent_unbond() again (or completeExit_tx + sign_and_send(sender=\"agent\")) AFTER unlockAt <= now to receive the bond back.",
            nextStep: "wait until unlockAt has lapsed, then call agent_unbond() again (or completeExit_tx + sign_and_send(sender=\"agent\"))",
          }, null, 2),
        }],
      };
    }

    if (exitLapsed) {
      const data = encodeFunctionData({ abi: abis.registry, functionName: "completeExit", args: [] });
      const res = await signAndSend(ADDR.registry, data, "0", "agent");
      return {
        content: [{
          type: "text",
          text: JSON.stringify({
            wallet,
            bonded: true,
            bondUSDC: formatUnits(bond, 6),
            debtLocked: false,
            exitPending: false,
            exitAt: exitAt.toString(),
            verdict: "EXIT LAPSED — completeExit executed; your bond has been returned and the exit cleared.",
            nextStep: "call agent_bond_status to confirm bonded:false (fully unbonded)",
            txHash: res.txHash,
            status: res.status,
          }, null, 2),
        }],
      };
    }

    // no pending exit and not lapsed -> begin the exit now
    const data = encodeFunctionData({ abi: abis.registry, functionName: "requestExit", args: [] });
    const res = await signAndSend(ADDR.registry, data, "0", "agent");
    const [, , newExitAt] = await view("agentRecord", [wallet]);
    return {
      content: [{
        type: "text",
        text: JSON.stringify({
          wallet,
          bonded: true,
          bondUSDC: formatUnits(bond, 6),
          debtLocked: false,
          exitPending: true,
          exitAt: newExitAt.toString(),
          verdict: "EXIT REQUESTED — requestExit executed. Your bond is now locked until unlockAt lapses; call agent_unbond() again (or completeExit_tx + sign_and_send(sender=\"agent\")) AFTER that time to receive the bond back. You may be unable to take new jobs while the exit is pending — verify with agent_bond_status.",
          nextStep: "wait until unlockAt has lapsed, then call agent_unbond() again (or completeExit_tx + sign_and_send(sender=\"agent\"))",
          txHash: res.txHash,
          status: res.status,
        }, null, 2),
      }],
    };
  }
);

async function jobCountAtHead() {
  const raw = await rpc("eth_call", [{
    to: ADDR.router,
    data: encodeFunctionData({ abi: abis.router, functionName: "jobCount" }),
  }, "latest"]);
  return BigInt(raw ?? 0);
}

// Approve is only broadcast when the current allowance is short; otherwise the
// estimate race (allowance not yet visible) can never happen here.
async function ensureAllowance(sender, spender, amountAtomic) {
  const account = privateKeyToAccount(signerKeyFor(sender));
  const raw = await rpc("eth_call", [{
    to: USDC_ADDR,
    data: encodeFunctionData({
      abi: [{
        type: "function", name: "allowance",
        inputs: [{ type: "address" }, { type: "address" }], outputs: [{ type: "uint256" }],
        stateMutability: "view",
      }],
      functionName: "allowance", args: [account.address, spender],
    }),
  }, "latest"]);
  if (BigInt(raw ?? 0) >= amountAtomic) return { approved: false };
  const res = await signAndSend(
    USDC_ADDR,
    encodeFunctionData({
      abi: [{
        type: "function", name: "approve",
        inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "bool" }],
        stateMutability: "nonpayable",
      }],
      functionName: "approve", args: [spender, amountAtomic],
    }),
    "0", sender
  );
  return { approved: true, txHash: res.txHash, status: res.status };
}

server.tool(
  "originator_post_job",
  "Atomic originator action: (1) top up the router escrow allowance only if short, then (2) createJob as a DIRECT HIRE to the designated wallet and wait for the receipt. Uses the regime-default split (9000/500/500) and execDeadline = now + 86400. One call — no separate approve or calldata. Returns txHash + jobId.",
  {
    specHash: z.string(),
    paymentUSDC: z.string(),
    designatedAssignee: z.string(),
    approvalWindow: z.string().default("7200"),
    opsBudgetUSDC: z.string().default("0"),
  },
  async (a) => {
    if (!signerKeyFor("originator")) throw new Error("no originator key in server env");
    const before = await jobCountAtHead();
    const payment = parseUnits(a.paymentUSDC, 6);
    const approval = await ensureAllowance("originator", ADDR.router, payment);
    const data = encodeFunctionData({
      abi: abis.router,
      functionName: "createJob",
      args: [
        payment,
        a.specHash,
        { executorBps: 0, lpBps: 0, treasuryBps: 0 },
        BigInt(Math.floor(Date.now() / 1000) + 86400),
        BigInt(a.approvalWindow),
        a.designatedAssignee,
        parseUnits(a.opsBudgetUSDC, 6),
      ],
    });
    const res = await signAndSend(ADDR.router, data, "0", "originator");
    const after = await jobCountAtHead();
    return {
      content: [{
        type: "text",
        text: JSON.stringify({ jobId: String(after), ...res, allowance: approval }, null, 2),
      }],
    };
  }
);

server.tool(
  "originator_settle",
  "Atomic originator action: settle a SUBMITTED job you originated — approve(jobId). Build, sign, send, wait. Returns txHash/status.",
  { jobId: z.string() },
  async ({ jobId }) => {
    const res = await signAndSend(
      ADDR.router, encodeFunctionData({ abi: abis.router, functionName: "approve", args: [BigInt(jobId)] }), "0", "originator"
    );
    return { content: [{ type: "text", text: JSON.stringify(res, null, 2) }] };
  }
);

server.tool(
  "originator_cancel",
  "Atomic originator action: cancel a POSTED job YOU posted that was never assigned — full refund minus the treasury cancel fee. Build, sign, send, wait. Returns txHash/status. Only the job's originator may cancel; a POSTED job that is not yours cannot be removed (see originator_expire for assigned-and-overdue only).",
  { jobId: z.string() },
  async ({ jobId }) => {
    const res = await signAndSend(
      ADDR.router, encodeFunctionData({ abi: abis.router, functionName: "cancel", args: [BigInt(jobId)] }), "0", "originator"
    );
    return { content: [{ type: "text", text: JSON.stringify(res, null, 2) }] };
  }
);

server.tool(
  "originator_expire",
  "Atomic originator action: expire an ASSIGNED job whose execDeadline has passed without a submission — refund minus cancel fee, outcome FAILURE. Build, sign, send, wait. Returns txHash/status. ONLY valid for already-assigned overdue jobs; a POSTED (never-accepted) job uses originator_cancel.",
  { jobId: z.string() },
  async ({ jobId }) => {
    const res = await signAndSend(
      ADDR.router, encodeFunctionData({ abi: abis.router, functionName: "expire", args: [BigInt(jobId)] }), "0", "originator"
    );
    return { content: [{ type: "text", text: JSON.stringify(res, null, 2) }] };
  }
);

server.tool(
  "originator_reject",
  "Atomic originator action: reject a SUBMITTED result you received and do not approve — only valid while the approval window is still open (before approvalDeadline), only for jobs YOU originated. Rejection is final: escrow splits 90% refund / 5% executor / 2.5% pool / 2.5% treasury and FAILURE is recorded on the agent. reasonHash is optional (defaults to keccak256('originator-reject:<jobId>')); a snapshot of the offchain reason. Build, sign, send, wait. Returns txHash/status.",
  { jobId: z.string(), reasonHash: z.string().optional() },
  async ({ jobId, reasonHash }) => {
    const reason = reasonHash || keccak256(toBytes(`originator-reject:${jobId}`));
    const res = await signAndSend(
      ADDR.router, encodeFunctionData({ abi: abis.router, functionName: "reject", args: [BigInt(jobId), reason] }), "0", "originator"
    );
    return { content: [{ type: "text", text: JSON.stringify({ ...res, reasonHash: reason }, null, 2) }] };
  }
);

server.tool(
  "agent_accept",
  "Atomic agent action: accept(jobId) — build, sign, send, wait. Returns txHash/status. "
  + "You must be BONDED first: run agent_bond_status and confirm bonded:true (and not revoked/debt-locked) "
  + "before accepting — an unbonded accept reverts. If bonded:false, follow agent_bond_status.nextSteps, "
  + "rerun agent_bond_status until bonded:true, then accept.",
  { jobId: z.string() },
  async ({ jobId }) => {
    const res = await signAndSend(
      ADDR.router, encodeFunctionData({ abi: abis.router, functionName: "accept", args: [BigInt(jobId)] }), "0", "agent"
    );
    return { content: [{ type: "text", text: JSON.stringify(res, null, 2) }] };
  }
);

server.tool(
  "agent_poke_and_submit",
  "Atomic worker action: do the work for jobId and submit it in ONE call. (1) poke the oracle feed (env ORACLE_ADDRESS or oracleAddress) with the agent key, (2) read lastUpdated, (3) resultHash = keccak256('<pokeTx-no-0x>:<lastUpdated>') — same commitment as the shell loop, (4) submitResult(jobId, resultHash). Without an oracle it defaults to keccak('keeper-demo-result-<jobId>'). Call agent_accept first. Returns txHash/status/resultHash.",
  { jobId: z.string(), oracleAddress: z.string().optional(), pokeValue: z.string().default("420000") },
  async ({ jobId, oracleAddress, pokeValue }) => {
    const oracle = oracleAddress || process.env.ORACLE_ADDRESS;
    const sub = (resultHash) =>
      signAndSend(
        ADDR.router, encodeFunctionData({ abi: abis.router, functionName: "submitResult", args: [BigInt(jobId), resultHash] }), "0", "agent"
      );
    if (!oracle) {
      const resultHash = keccak256(toBytes(`keeper-demo-result-${jobId}`));
      const res = await sub(resultHash);
      return { content: [{ type: "text", text: JSON.stringify({ ...res, resultHash }, null, 2) }] };
    }
    const poke = await signAndSend(
      oracle,
      encodeFunctionData({
        abi: [{
          type: "function", name: "poke",
          inputs: [{ type: "uint256" }], outputs: [], stateMutability: "nonpayable",
        }],
        functionName: "poke", args: [BigInt(pokeValue)],
      }),
      "0", "agent"
    );
    const raw = await rpc("eth_call", [{
      to: oracle,
      data: encodeFunctionData({
        abi: [{
          type: "function", name: "lastUpdated", outputs: [{ type: "uint256" }], stateMutability: "view",
        }],
        functionName: "lastUpdated",
      }),
    }, "latest"]);
    const ts = BigInt(raw ?? 0);
    const resultHash = keccak256(toBytes(String(poke.txHash).replace(/^0x/, "") + ":" + ts.toString()));
    const res = await sub(resultHash);
    return {
      content: [{
        type: "text",
        text: JSON.stringify({
          ...res, resultHash, pokeTx: poke.txHash,
          feedAgeSec: Math.max(0, Math.floor(Date.now() / 1000) - Number(ts)),
        }, null, 2),
      }],
    };
  }
);

server.tool(
  "wallet_balances",
  "Tiny recovery read: one role's native gas balance (Arc gas IS USDC) and ERC-20 USDC balance. Use this FIRST when a tx reverts — it pinpoints out-of-gas vs out-of-funds in one micro-call, before any job/tx scanning.",
  { sender: z.enum(["agent", "originator"]).default("originator") },
  async ({ sender }) => {
    const key = signerKeyFor(sender);
    if (!key) throw new Error(`no ${sender} key in server env`);
    const account = privateKeyToAccount(key);
    const gas = await rpc("eth_getBalance", [account.address, "latest"]);
    const raw = await rpc("eth_call", [{
      to: USDC_ADDR,
      data: encodeFunctionData({
        abi: [{
          type: "function", name: "balanceOf",
          inputs: [{ type: "address" }], outputs: [{ type: "uint256" }], stateMutability: "view",
        }],
        functionName: "balanceOf", args: [account.address],
      }),
    }, "latest"]);
    return {
      content: [{
        type: "text",
        text: JSON.stringify({
          sender, address: account.address,
          nativeGasUSDC: formatUnits(BigInt(gas ?? 0), 18),
          usdcBalance: formatUnits(BigInt(raw ?? 0), 6),
        }, null, 2),
      }],
    };
  }
);

server.tool(
  "checksum_address",
  "Return the canonical form of any address or tx hash WITHOUT you counting hex digits. For an address (40 hex after 0x) returns the EIP-55 checksummed form; for a tx hash (64 hex) returns lowercase — the only form two hashes can be compared in. NEVER compare addresses/hashes by eye: paste the pasted value here, take `canonical` back verbatim, and compare `valid` + `hexChars` instead of counting.",
  { hex: z.string() },
  async ({ hex }) => {
    const clean = hex.trim().startsWith("0x") ? hex.trim() : `0x${hex.trim()}`;
    const body = clean.slice(2);
    let kind = "other", canonical = null, valid = false;
    if (/^[0-9a-fA-F]{40}$/.test(body)) {
      try { canonical = getAddress(`0x${body.toLowerCase()}`); kind = "address"; valid = true; }
      catch { kind = "address"; }
    } else if (/^[0-9a-fA-F]{64}$/.test(body)) {
      canonical = `0x${body.toLowerCase()}`; kind = "txHash"; valid = true;
    }
    return {
      content: [{
        type: "text",
        text: JSON.stringify({
          input: hex.trim(), kind, valid, hexBytes: valid ? (kind === "address" ? 20 : 32) : null,
          hexChars: body.length, canonical,
        }, null, 2),
      }],
    };
  }
);

// packs (domain tooling, conditional)

if (PACKS.includes("keeper")) {
  const { registerKeeperTools } = await import("./keeper.js");
  const agentAddress = () => {
    const key = signerKeyFor("agent");
    if (!key) return null;
    return privateKeyToAccount(key).address;
  };
  registerKeeperTools(server, { gql, rpc, signAndSend, CHAIN_ID, abis, ADDR, agentAddress });
}

const transport = new StdioServerTransport();
await server.connect(transport);
