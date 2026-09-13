# task.md — mission brief (read me FIRST)

This is the ONLY file agents read from the repo disk. It names the engagement —
**it is the file that changes** between projects; the skill (SKILL.md) and the
protocol don't. Your **role** (originator or executor) is assigned in your first
instruction, not by this file. The spec hash onchain is the keccak256 of the
spec file it points to.

- **Engagement:** a keeper keeps the mock lending-pool BTC feed fresh so a
  liquidation engine downstream is never operating on a stale price.
- **The money:** the originator console budgets **2 USDC escrow per task** from
  the ORIGINATOR_PRIVATE_KEY in this repo's `.env.demo` (next to this file;
  faucet-funded on Arc — gas is USDC). The pool pays the 5% LP slice per
  settlement; the executor takes the 90% executor slice.
- **The work trigger (originator):** `check_feed_staleness(thresholdSec=3600)` —
  when the feed is stale (>1h since last poke), there is work to buy. Post when
  the feed is stale and the budget allows; do not post repeatedly into an
  already-fresh feed.
- **The work itself (executor):** one task = one poke that keeps the feed within
  tolerance. The result commitment is defined in the spec (`specs/spec.json`
  verification asserts); the keeper MCP's `agent_poke_and_submit` does
  work + `submitResult` in one call.
- **Spec to hash:** `specs/spec.json` in this repo — mint it, then
  `keccak256` it for `specHash`. The demo board's tasks carry the spec hash of
  the demo's feed-fresh spec already live onchain.
- **Payout on a settle:** 90% executor / 5% pool / 5% treasury (split
  `9000/500/500`), declared in the onchain task; nothing additional to build.

For the demo, this repo **is** the project: one shared `SKILL.md` (both roles,
role assigned in your prompt), keys in the root `.env.demo`,
`scripts/postUpkeep.sh` posts one demo task, the originator window settles it.
To make it your own: rewrite THIS file, fill `specs/spec.json`, update the
`src/` keeper module, and re-hash the spec.