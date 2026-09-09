// CreditLine mappings — the principal ledger is now driven purely by
// Drawn/Repaid/Slashed (the old DebtUpdated event was removed from the
// contract). Each event carries its own amount, so the per-agent
// CreditPosition row and the shared Pool.totalPrincipal aggregate stay in
// sync incrementally:
//   Drawn  += principal        (credit extended)
//   Repaid -= principal        (remainingPrincipal is authoritative per-agent)
//   Slashed -= coveredBySlash  (remainingDebt is authoritative per-agent)
// Always zero while both lending gates are OFF, but the entity exists so
// activation needs no schema migration.
import { BigInt, Bytes } from "@graphprotocol/graph-ts";
import {
  Drawn,
  Repaid,
  Slashed,
} from "../generated/CreditLine/CreditLine";
import { CreditPosition, Agent, Pool } from "../generated/schema";

function position(agentId: Bytes, at: BigInt, txFrom: Bytes): CreditPosition {
  let id = agentId.toHexString();
  let c = CreditPosition.load(id);
  if (c == null) {
    c = new CreditPosition(id);
    c.agent = id;
    c.principal = BigInt.fromI32(0);
    c.updatedAt = at;
    let a = Agent.load(id);
    if (a == null) {
      // Debt before any indexed BondedIn (e.g. reindex from a later block):
      // create a placeholder row the registry handlers fill in on next touch.
      a = new Agent(id);
      a.wallet = txFrom;
      a.bond = BigInt.fromI32(0);
      a.registeredAt = at;
      a.unlockAt = BigInt.fromI32(0);
      a.adapter = txFrom;
      a.externalId = BigInt.fromI32(0);
      a.debtLocked = true;
      a.success = 0;
      a.failure = 0;
      a.neutral = 0;
      a.fraud = 0;
      a.volume = BigInt.fromI32(0);
      a.jobsAssigned = 0;
      a.updatedAt = at;
      a.save();
    }
  }
  return c;
}

function pool(at: BigInt): Pool {
  let p = Pool.load("1");
  if (p == null) {
    p = new Pool("1");
    p.totalPrincipal = BigInt.fromI32(0);
    p.lendEnabled = false;
    p.paused = false;
    p.revenueTotal = BigInt.fromI32(0);
    p.lossTotal = BigInt.fromI32(0);
    p.updatedAt = at;
  }
  return p;
}

/// @dev Delta-form: Drawn extends credit, Repaid/Slashed retire it. Both
///      retirement events carry the authoritative per-agent remaining, but the
///      delta is what keeps the shared Pool.totalPrincipal aggregate exact
///      across many agents without a second read of every position.
function adjustPrincipal(agentId: Bytes, delta: BigInt, at: BigInt, txFrom: Bytes): void {
  let c = position(agentId, at, txFrom);
  c.principal = c.principal.plus(delta);
  c.updatedAt = at;
  c.save();

  let p = pool(at);
  p.totalPrincipal = p.totalPrincipal.plus(delta);
  p.updatedAt = at;
  p.save();
}

export function handleDrawn(event: Drawn): void {
  // Drawn carries the drawn amount (credit extended this draw).
  adjustPrincipal(event.params.agentId, event.params.principal, event.block.timestamp, event.transaction.from);
}

export function handleRepaid(event: Repaid): void {
  // Repaid carries the repaid principal; the aggregate retires by the same
  // amount (the event's remainingPrincipal is per-agent, not global).
  adjustPrincipal(event.params.agentId, event.params.principal.neg(), event.block.timestamp, event.transaction.from);
}

export function handleSlashCoverage(event: Slashed): void {
  // Slash coverage retires the covered slice of the principal.
  adjustPrincipal(event.params.agentId, event.params.coveredBySlash.neg(), event.block.timestamp, event.transaction.from);
}
