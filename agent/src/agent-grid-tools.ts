import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { resolve } from "path";

type MCPContent = { type: string; text?: string };
type MCPResult = { content?: MCPContent[] };

let client: Client | null = null;
let transport: StdioClientTransport | null = null;

function extractText(result: MCPResult, fallback: string): string {
  const content = result.content;
  if (Array.isArray(content) && content[0]?.type === "text" && content[0].text) {
    return content[0].text;
  }
  return fallback;
}

export async function connectMCP(serverPath?: string): Promise<Client> {
  if (client) return client;

  const cwd = resolve(import.meta.dirname, "..", "..");
  const path = serverPath || process.env.MCP_SERVER_PATH || "../subgraph/mcp/src/index.js";
  const absPath = resolve(cwd, path);

  transport = new StdioClientTransport({
    command: "node",
    args: [absPath],
    env: { ...process.env } as Record<string, string>,
  });

  client = new Client({ name: "agent-grid-agent", version: "0.1.0" });
  await client.connect(transport);
  return client;
}

export async function disconnectMCP(): Promise<void> {
  if (client) {
    await client.close();
    client = null;
    transport = null;
  }
}

export interface Job {
  id: string;
  originator: string;
  payment: string;
  state: string;
  assignedAgent: string;
  resultHash: string;
  execDeadline: string;
  createdAt: string;
  split: { executorBps: number; lpBps: number; treasuryBps: number };
}

export interface Agent {
  id: string;
  wallet: string;
  bond: string;
  jobsAssigned: number;
}

export interface PoolStats {
  totalPrincipal: string;
  revenueTotal: string;
  lossTotal: string;
}

export async function listJobs(state?: string): Promise<Job[]> {
  const c = await connectMCP();
  const args: Record<string, string> = {};
  if (state) args.state = state;
  const result = (await c.callTool({ name: "list_jobs", arguments: args })) as MCPResult;
  return JSON.parse(extractText(result, "[]"));
}

export async function getJob(jobId: string): Promise<Job | null> {
  const c = await connectMCP();
  const result = (await c.callTool({ name: "get_job", arguments: { jobId } })) as MCPResult;
  return JSON.parse(extractText(result, "null"));
}

export async function listAgents(): Promise<Agent[]> {
  const c = await connectMCP();
  const result = (await c.callTool({ name: "list_agents", arguments: {} })) as MCPResult;
  return JSON.parse(extractText(result, "[]"));
}

export async function poolStats(): Promise<PoolStats> {
  const c = await connectMCP();
  const result = (await c.callTool({ name: "pool_stats", arguments: {} })) as MCPResult;
  return JSON.parse(extractText(result, "{}"));
}

export async function recentEvents(jobId?: string): Promise<any[]> {
  const c = await connectMCP();
  const args: Record<string, string> = {};
  if (jobId) args.jobId = jobId;
  const result = (await c.callTool({ name: "recent_events", arguments: args })) as MCPResult;
  return JSON.parse(extractText(result, "[]"));
}

export async function bondInTx(amount: string): Promise<{ to: string; data: string; value: string }> {
  const c = await connectMCP();
  const result = (await c.callTool({ name: "bond_in_tx", arguments: { amount } })) as MCPResult;
  return JSON.parse(extractText(result, "{}"));
}

export async function createJobTx(
  payment: string,
  specHash: string,
  split: { executorBps: number; lpBps: number; treasuryBps: number },
  execDeadline: string,
  approvalWindow: string,
  designatedAssignee: string,
  opsBudget: string
): Promise<{ to: string; data: string; value: string }> {
  const c = await connectMCP();
  const result = (await c.callTool({
    name: "create_job_tx",
    arguments: { payment, specHash, split: JSON.stringify(split), execDeadline, approvalWindow, designatedAssignee, opsBudget },
  })) as MCPResult;
  return JSON.parse(extractText(result, "{}"));
}

export async function acceptJobTx(jobId: string): Promise<{ to: string; data: string; value: string }> {
  const c = await connectMCP();
  const result = (await c.callTool({ name: "accept_job_tx", arguments: { jobId } })) as MCPResult;
  return JSON.parse(extractText(result, "{}"));
}

export async function submitResultTx(
  jobId: string,
  resultHash: string
): Promise<{ to: string; data: string; value: string }> {
  const c = await connectMCP();
  const result = (await c.callTool({ name: "submit_result_tx", arguments: { jobId, resultHash } })) as MCPResult;
  return JSON.parse(extractText(result, "{}"));
}
