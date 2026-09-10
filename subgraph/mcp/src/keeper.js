// Keeper pack — domain tooling for verifiable-jobs agents (oracle-poke,
// upkeep). Mounted by index.js when AGENTGRID_PACKS includes "keeper"
// (default on). Nothing here knows about contracts beyond read-only calls;
// settlement, reputation, and escrow stay in the protocol + core tools.
//
// Pack boundary: core reads protocol state and receipts and resolves files
// mechanically. THIS module interprets domain semantics: feed freshness
// (latestRoundData), staleness thresholds, and spec-typed market views.
import { z } from "zod";
import { loadLocalSpecs } from "./specs.js";

// Chainlink AggregatorV3 latestRoundData() selector. Returns updatedAt
// (unix seconds) or throws {supported:false} for non-feed contracts.
export async function feedTimestamp(feed, rpcUrl, rpc) {
  let raw;
  try {
    raw = await rpc("eth_call", [{ to: feed, data: "0xfeaf968c" }, "latest"], rpcUrl);
  } catch (e) {
    throw { supported: false, reason: "eth_call failed: " + e.message };
  }
  const hex = String(raw || "").replace(/^0x/, "");
  if (hex.length < 320) throw { supported: false, reason: "unexpected return length (not latestRoundData-shaped)" };
  const updatedAt = Number(BigInt("0x" + hex.slice(192, 256)));
  if (!updatedAt) throw { supported: false, reason: "round not initialized (updatedAt 0)" };
  return updatedAt;
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

export function registerKeeperTools(server, { gql, rpc }) {
  server.tool(
    "check_feed_staleness",
    "[keeper pack] Read a Chainlink-style feed's latest round timestamp via read-only eth_call and compare its age against a staleness threshold. No keys, no writes. Returns {supported:false} for contracts without latestRoundData.",
    {
      feed: z.string(),
      thresholdSec: z.number().min(0),
      rpcUrl: z.string().optional(),
    },
    async ({ feed, thresholdSec, rpcUrl }) => {
      try {
        const updatedAt = await feedTimestamp(feed, rpcUrl, rpc);
        const age = Math.floor(Date.now() / 1000) - updatedAt;
        return { content: [{ type: "text", text: JSON.stringify({
          feed, updatedAt, ageSec: age, thresholdSec, stale: age > thresholdSec,
        }, null, 2) }] };
      } catch (e) {
        return { content: [{ type: "text", text: JSON.stringify({
          feed, supported: false, reason: e.reason || e.message,
        }, null, 2) }] };
      }
    }
  );

  server.tool(
    "keeper_jobs",
    "[keeper pack] POSTED jobs annotated by spec match: resolves each job's onchain specHash against local specs/*.json (keccak256 of file bytes). Matched rows carry {specTitle, verificationType}; the rest are plain market work. Keeper loop starts here.",
    { limit: z.number().min(1).max(100).default(20) },
    async ({ limit }) => {
      const byHash = loadLocalSpecs();
      const data = await gql(`{ jobs(where: {state: "POSTED"}, orderBy: createdAt, orderDirection: asc, first: ${limit}) {
        id originator payment createdAt execDeadline designatedAssignee specHash } }`);
      const keeper = [];
      let plain = 0;
      for (const j of data.jobs) {
        const hit = byHash[String(j.specHash).toLowerCase()];
        if (hit) keeper.push({ ...j, specTitle: hit.spec.title, verificationType: hit.spec.verification?.type ?? "generic" });
        else plain += 1;
      }
      return { content: [{ type: "text", text: JSON.stringify({ keeper, plainMarketJobs: plain }, null, 2) }] };
    }
  );
}
