import "dotenv/config";
import * as readline from "readline";
import {
  listJobs,
  getJob,
  listAgents,
  poolStats,
  bondInTx,
  createJobTx,
  acceptJobTx,
  submitResultTx,
  disconnectMCP,
} from "./agent-grid-tools.js";
import { readSpec, listSpecs } from "./spec-reader.js";
import { sendTransaction, waitForReceipt, getBalance, getAccount } from "./wallet.js";
import { encodeAbiParameters, keccak256, toBytes } from "viem";

const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
const prompt = (q: string): Promise<string> => new Promise((resolve) => rl.question(q, resolve));

const HELP = `
Commands:
  list                  List available jobs (POSTED)
  agents                List bonded agents
  pool                  Show pool stats
  spec <jobId>          Show job spec
  accept <jobId>        Accept a job (sign + submit)
  submit <jobId> <msg>  Submit result for an assigned job
  balance               Show wallet balance
  help                  Show this help
  exit                  Disconnect and exit
`;

async function main() {
  const account = getAccount();
  const balance = await getBalance();

  console.log("\nAgentGrid Agent v0.1.0");
  console.log(`Wallet: ${account.address}`);
  console.log(`Balance: ${Number(balance) / 1e6} USDC`);
  console.log(`Chain: Arc Testnet (5042002)`);
  console.log(HELP);

  while (true) {
    const input = await prompt("> ");
    const parts = input.trim().split(/\s+/);
    const cmd = parts[0]?.toLowerCase();
    const arg1 = parts[1];
    const arg2 = parts.slice(2).join(" ");

    try {
      switch (cmd) {
        case "list": {
          const jobs = await listJobs("POSTED");
          if (jobs.length === 0) {
            console.log("No POSTED jobs found.");
          } else {
            console.log(`\n${jobs.length} POSTED job(s):`);
            for (const j of jobs) {
              const spec = readSpec(j.id);
              const title = spec?.title || "(no spec)";
              console.log(`  #${j.id} "${title}" — ${j.payment} USDC — deadline: ${j.execDeadline}`);
            }
          }
          break;
        }

        case "agents": {
          const agents = await listAgents();
          if (agents.length === 0) {
            console.log("No bonded agents found.");
          } else {
            console.log(`\n${agents.length} bonded agent(s):`);
            for (const a of agents) {
              console.log(`  ${a.id.slice(0, 10)}... bond: ${a.bond} USDC — jobs: ${a.jobsAssigned}`);
            }
          }
          break;
        }

        case "pool": {
          const stats = await poolStats();
          console.log(`\nPool stats:`);
          console.log(`  Principal: ${stats.totalPrincipal} USDC`);
          console.log(`  Revenue: ${stats.revenueTotal} USDC`);
          console.log(`  Losses: ${stats.lossTotal} USDC`);
          break;
        }

        case "spec": {
          if (!arg1) { console.log("Usage: spec <jobId>"); break; }
          const spec = readSpec(arg1);
          if (!spec) { console.log(`No spec found for job #${arg1}`); break; }
          console.log(`\nJob #${arg1}: ${spec.title}`);
          console.log(`Description: ${spec.description}`);
          console.log(`Requirements: ${spec.requirements.join(", ")}`);
          console.log(`Deliverables: ${spec.deliverables.join(", ")}`);
          console.log(`Payment: ${spec.payment}`);
          console.log(`Deadline: ${spec.deadline}`);
          console.log(`Context: ${spec.context}`);
          break;
        }

        case "accept": {
          if (!arg1) { console.log("Usage: accept <jobId>"); break; }
          const job = await getJob(arg1);
          if (!job) { console.log(`Job #${arg1} not found`); break; }
          if (job.state !== "POSTED") { console.log(`Job #${arg1} is ${job.state}, not POSTED`); break; }

          console.log(`Accepting job #${arg1}...`);
          const tx = await acceptJobTx(arg1);
          console.log(`Signing transaction...`);
          const hash = await sendTransaction({
            to: tx.to as `0x${string}`,
            data: tx.data as `0x${string}`,
          });
          console.log(`Submitted: ${hash}`);
          const receipt = await waitForReceipt(hash);
          console.log(`Confirmed in block ${receipt.blockNumber}`);
          break;
        }

        case "submit": {
          if (!arg1 || !arg2) { console.log("Usage: submit <jobId> <result message>"); break; }
          const job = await getJob(arg1);
          if (!job) { console.log(`Job #${arg1} not found`); break; }
          if (job.state !== "ASSIGNED") { console.log(`Job #${arg1} is ${job.state}, not ASSIGNED`); break; }

          const resultHash = keccak256(toBytes(arg2));
          console.log(`Submitting result for job #${arg1}...`);
          console.log(`Result hash: ${resultHash}`);
          const tx = await submitResultTx(arg1, resultHash);
          console.log(`Signing transaction...`);
          const hash = await sendTransaction({
            to: tx.to as `0x${string}`,
            data: tx.data as `0x${string}`,
          });
          console.log(`Submitted: ${hash}`);
          const receipt = await waitForReceipt(hash);
          console.log(`Confirmed in block ${receipt.blockNumber}`);
          break;
        }

        case "balance": {
          const bal = await getBalance();
          console.log(`Balance: ${Number(bal) / 1e6} USDC`);
          break;
        }

        case "help":
          console.log(HELP);
          break;

        case "exit":
        case "quit":
          await disconnectMCP();
          console.log("Disconnected.");
          rl.close();
          process.exit(0);

        default:
          if (cmd) console.log(`Unknown command: ${cmd}. Type "help" for commands.`);
      }
    } catch (err: any) {
      console.error(`Error: ${err.message || err}`);
    }
  }
}

main().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});
