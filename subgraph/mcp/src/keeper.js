// Keeper pack — domain tooling for verifiable-jobs agents (oracle-poke,
// upkeep). Mounted by index.js when AGENTGRID_PACKS includes "keeper"
// (default on). Nothing here knows about contracts beyond read-only calls;
// settlement, reputation, and escrow stay in the protocol + core tools.
//
// Pack boundary: core reads protocol state and receipts and resolves files
// mechanically. THIS module interprets domain semantics: feed freshness
// (latestRoundData, mock lastUpdated), staleness thresholds, and spec-typed
// market views.
import { z } from "zod";
import { encodeFunctionData } from "viem";
import { loadLocalSpecs } from "./specs.js";

// Feed read mechanisms, tried in order:
//   latestRoundData() : Chainlink AggregatorV3 (0xfeaf968c) — 5 return words,
//                       updatedAt is the 4th word (bytes 192..256).
//   lastUpdated()     : plain mock oracle (0xd0b06f5d) — single uint256 unix.
// Returns unix seconds, or throws {supported:false} when no mechanism answers.
const LATEST_ROUND = "0xfeaf968c";
const LAST_UPDATED = "0xd0b06f5d";

export async function feedTimestamp(feed, rpcUrl, rpc) {
  for (const selector of [LATEST_ROUND, LAST_UPDATED]) {
    let raw;
    try {
      raw = await rpc("eth_call", [{ to: feed, data: selector }, "latest"], rpcUrl);
    } catch {
      continue; // reverts on this selector — try the next mechanism
    }
    const hex = String(raw || "").replace(/^0x/, "");
    let ts = 0;
    if (selector === LATEST_ROUND) {
      if (hex.length < 320) continue;
      ts = Number(BigInt("0x" + hex.slice(192, 256)));
    } else {
      if (hex.length !== 64) continue;
      ts = Number(BigInt("0x" + hex));
    }
    if (ts) return ts;
  }
  throw { supported: false, reason: "no readable feed timestamp (latestRoundData / lastUpdated)" };
}

// Live feed measurements for a spec's asserts. Returns {measured, manual}:
// measured values where computable, plain checklist otherwise. Never throws.
export async function feedEvidence(spec, rpcUrl, rpc) {
  const measured = {};
  const manual = [];
  const v = spec?.verification;
  const ZERO_ADDR = "0x0000000000000000000000000000000000000000";
  if (v && (v.type === "oracle-poke" || v.type === "upkeep") && v.contract && v.contract !== ZERO_ADDR) {
    try {
      const updatedAt = await feedTimestamp(v.contract, rpcUrl, rpc);
      const age = Math.floor(Date.now() / 1000) - updatedAt;
      measured.feed = v.contract;
      measured.feedUpdatedAt = updatedAt;
      measured.feedAgeSec = age;
      const threshold = Number(v.params?.stalenessThresholdSec ?? NaN);
      if (Number.isFinite(threshold)) measured.staleVsThreshold = age > threshold;
    } catch (e) {
      measured.feedError = e.reason || e.message || "feed read failed";
    }
  }
  if (v?.asserts) {
    for (const a of v.asserts) manual.push({ assert: a, evidence: measured });
  }
  return { measured, manual };
}

export function registerKeeperTools(server, { gql, rpc, signAndSend, CHAIN_ID, abis, ADDR, agentAddress }) {
  server.tool(
    "check_feed_staleness",
    "[keeper pack] Read a feed's latest round timestamp via read-only eth_call (latestRoundData, falling back to a mock oracle's lastUpdated) and compare its age against a staleness threshold. No keys, no writes. Returns {supported:false} for contracts with no readable timestamp. feed defaults to env ORACLE_ADDRESS.",
    {
      feed: z.string().optional(),
      thresholdSec: z.number().min(0),
      rpcUrl: z.string().optional(),
    },
    async ({ feed, thresholdSec, rpcUrl }) => {
      const target = feed || process.env.ORACLE_ADDRESS;
      if (!target) throw new Error("no feed given (pass feed or set ORACLE_ADDRESS in server env)");
      try {
        const updatedAt = await feedTimestamp(target, rpcUrl, rpc);
        const age = Math.floor(Date.now() / 1000) - updatedAt;
        return { content: [{ type: "text", text: JSON.stringify({
          feed: target, updatedAt, ageSec: age, thresholdSec, stale: age > thresholdSec,
        }, null, 2) }] };
      } catch (e) {
        return { content: [{ type: "text", text: JSON.stringify({
          feed: target, supported: false, reason: e.reason || e.message,
        }, null, 2) }] };
      }
    }
  );

  server.tool(
    "poke_feed_tx",
    "[keeper pack] Build the feed-update payload poke(uint256 value) for a mock-oracle feed (the work step of an oracle-poke job). Sign + send via sign_and_send(sender=agent). No keys on this side. feed defaults to env ORACLE_ADDRESS.",
    { feed: z.string().optional(), value: z.number().int().nonnegative().default(420000) },
    async ({ feed, value }) => {
      const target = feed || process.env.ORACLE_ADDRESS;
      if (!target) throw new Error("no feed given (pass feed or set ORACLE_ADDRESS in server env)");
      const data = encodeFunctionData({
        abi: [
          {
            type: "function", name: "poke",
            inputs: [{ type: "uint256" }], outputs: [], stateMutability: "nonpayable",
          },
        ],
        functionName: "poke", args: [BigInt(value)],
      });
      return { content: [{ type: "text", text: JSON.stringify({ to: target, data, value: "0", chainId: CHAIN_ID }, null, 2) }] };
    }
  );

  server.tool(
    "keeper_jobs",
    "[keeper pack] The keeper loop's entry point — POSTED keeper jobs only. LIMIT-PROOF: the subgraph query filters by specHash_in (keccak256 of local specs/*.json bytes), so seed floods and market work can never crowd a keeper job out of the first N rows — a freshly posted keeper job is always found regardless of how many unrelated POSTED jobs exist. Keeper rows carry {id, payment, specTitle, verificationType} plus an onchain canAccept gate against a wallet (default: this server's agent key; pass wallet= to override). If keeper is empty, report it and wait for the originator — do not scan further.",
    { wallet: z.string().optional(), limit: z.number().min(1).max(100).default(20) },
    async ({ wallet, limit }) => {
      const byHash = loadLocalSpecs();
      const hashes = Object.keys(byHash);
      const target = wallet || (ADDR && agentAddress ? agentAddress() : undefined);
      const keeper = [];
      if (hashes.length > 0) {
        const data = await gql(`{ jobs(
            where: {state: "POSTED", specHash_in: ["${hashes.join('", "')}"]},
            orderBy: createdAt, orderDirection: desc, first: ${limit}) {
          id payment execDeadline createdAt designatedAssignee specHash } }`);
        for (const j of data.jobs ?? []) {
          const hit = byHash[String(j.specHash).toLowerCase()];
          const row = {
            id: j.id, payment: j.payment, execDeadline: j.execDeadline,
            designatedAssignee: j.designatedAssignee,
            specTitle: hit?.spec.title ?? "keeper spec",
            verificationType: hit?.spec.verification?.type ?? "generic",
          };
          if (target) {
            const calldata = encodeFunctionData({
              abi: abis.router, functionName: "canAccept", args: [BigInt(j.id), target],
            });
            const raw = await rpc("eth_call", [{ to: ADDR.router, data: calldata }, "latest"]);
            const can = raw !== undefined && raw !== null && BigInt(raw) === 1n;
            row.acceptable = can;
            if (!can) {
              row.blockReason = "canAccept=false (window, bond, eligibility, or direct-hire mismatch)";
            }
          }
          keeper.push(row);
        }
      }
      return {
        content: [{
          type: "text",
          text: JSON.stringify({ keeper, gatedFor: target ?? null }, null, 2),
        }],
      };
    }
  );
}
