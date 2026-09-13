// Reputation math — bit-for-bit mirror of the deployed AgentRegistry
// (repScore() + tier()). Own module so tests can import it without booting
// the MCP stdio server.
//
// repScore (AgentRegistry.sol:203):
//   den == 0  → DEFAULT_REP (0.5e18) FLAT — the early return skips the
//               volumeFactor multiply, so a fresh agent is tier 1 onchain
//   else      → ewma = num·1e18/den, scaled by volumeFactor
//   volumeFactor (sol:210) → totalVolume·1e18 / VOL_CAP ($100k cap)
// tier (sol:214): s ≥ 0.9e18 (and vf ≥ 0.75e18) → 3; s ≥ 0.75e18 → 2;
//                 s ≥ 0.5e18 → 1; else 0.
//
// hasOutcomes == the contract's den != 0: any non-NEUTRAL outcome recorded.
// NEUTRAL is weight-zero (R5), so a neutral-only agent still has den == 0 and
// must take the flat default path — pass (success + failure + fraud) > 0.

const DEFAULT_REP = 5n * 10n ** 17n; // AgentRegistry.sol:17 — 0.5e18 for new agents
// AgentRegistry.sol:18 — $100k USDC cap for volume factor. Env-overridable
// so a redeploy with a new cap doesn't need a code change here.
const VOL_CAP = BigInt(process.env.VOL_CAP ?? "100000000000");
const E18 = 10n ** 18n;

export function tierOf(score, volume, hasOutcomes) {
  const vf = (volume > VOL_CAP ? VOL_CAP : volume) * E18 / VOL_CAP;
  // repScore: ewma × volumeFactor — except den == 0, where the registry
  // returns DEFAULT_REP flat (AgentRegistry.sol:205 early return).
  const s = hasOutcomes ? score * vf / E18 : DEFAULT_REP;
  const tier = (s >= 9n * 10n ** 17n && vf >= 75n * 10n ** 16n) ? 3
    : s >= 75n * 10n ** 16n ? 2
    : s >= 5n * 10n ** 17n ? 1 : 0;
  return { score: s.toString(), volumeFactor: vf.toString(), tier };
}
