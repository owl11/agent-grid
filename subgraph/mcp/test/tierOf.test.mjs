// Parity harness: MCP tierOf() vs the deployed AgentRegistry.
// Golden values read live from Arc testnet (registry 0x9f5405afFda2Ba5A47851a8a9A30b7F9DFAE4A50):
//   cast call $R 'repScore(address)(uint256)' 0x571b9a8d32c5a5f39f8e0dad1dc77de91a1bd7a2 → 500000000000000000  (tier → 1)
//   cast call $R 'repScore(address)(uint256)' 0x8a13a54672f23e6ad751b1706dceda63313ba4f2 → 120000000000000     (tier → 0)
// Run from subgraph/mcp:  node test/tierOf.test.mjs
import assert from "node:assert/strict";
import { tierOf } from "../src/reputation.js";

const E18 = 10n ** 18n;

const CASES = [
  {
    name: "fresh agent (den==0): DEFAULT_REP flat, tier 1 — onchain tier(0x571b…)=1",
    score: 5n * E18, volume: 0n, hasOutcomes: false,
    want: { score: "500000000000000000", volumeFactor: "0", tier: 1 },
  },
  {
    name: "proven agent: ewma 1e18 × vf(12 USDC / 100k cap) = 1.2e14, tier 0 — onchain repScore(0x8a13…)=1.2e14",
    score: 1n * E18, volume: 12000000n, hasOutcomes: true,
    want: { score: "120000000000000", volumeFactor: "120000000000000", tier: 0 },
  },
  {
    name: "neutral-only agent: NEUTRAL is weight-zero onchain → still den==0 → flat default path",
    score: 5n * E18, volume: 0n, hasOutcomes: false,
    want: { score: "500000000000000000", volumeFactor: "0", tier: 1 },
  },
  {
    name: "volume above cap clamps to vf=1e18; perfect record + $75k+ volume → tier 3",
    score: 1n * E18, volume: 1000000000000n, hasOutcomes: true,
    want: { score: "1000000000000000000", volumeFactor: "1000000000000000000", tier: 3 },
  },
  {
    name: "imperfect record: ewma 0.6e18 × vf($100k cap)=1e18 → tier 1 (0.6e18 ≥ 0.5e18, < 0.75e18)",
    score: 6n * E18 / 10n, volume: 100000000000n, hasOutcomes: true,
    want: { score: "600000000000000000", volumeFactor: "1000000000000000000", tier: 1 },
  },
];

for (const c of CASES) {
  const got = tierOf(c.score, c.volume, c.hasOutcomes);
  assert.equal(got.score, c.want.score, `${c.name}: repScore (got ${got.score})`);
  assert.equal(got.volumeFactor, c.want.volumeFactor, `${c.name}: volumeFactor (got ${got.volumeFactor})`);
  assert.equal(got.tier, c.want.tier, `${c.name}: tier (got ${got.tier})`);
  console.log(`ok - ${c.name}`);
}
console.log("tierOf parity: all cases match AgentRegistry onchain behavior");
