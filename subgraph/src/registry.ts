// AgentRegistry mappings — bonding + outcome events fold into one Agent row
// per agentId. Tier/score stay client-side (pure formula over these counters).
//
// Keying: BondedIn carries both wallet and agentId and writes the WalletLink.
// Every other registry event is wallet-keyed and resolves through that link,
// so top-ups, exits, slashes, and outcomes all land on the right Agent row.
import { BigInt, Bytes } from "@graphprotocol/graph-ts";
import {
  BondedIn,
  BondAdded,
  ExitRequested,
  Exited,
  Slashed,
  OutcomeRecorded,
} from "../generated/AgentRegistry/AgentRegistry";
import { Agent, WalletLink } from "../generated/schema";

function blankAgent(id: string, at: BigInt): Agent {
  let a = new Agent(id);
  a.wallet = Bytes.fromHexString("0x0000000000000000000000000000000000000000");
  a.bond = BigInt.fromI32(0);
  a.registeredAt = at;
  a.unlockAt = BigInt.fromI32(0);
  a.adapter = Bytes.fromHexString("0x0000000000000000000000000000000000000000");
  a.externalId = BigInt.fromI32(0);
  a.debtLocked = false;
  a.success = 0;
  a.failure = 0;
  a.neutral = 0;
  a.fraud = 0;
  a.volume = BigInt.fromI32(0);
  a.jobsAssigned = 0;
  a.score = BigInt.fromString("500000000000000000"); // DEFAULT_REP 0.5e18 — no outcomes yet
  a.jobsCompleted = 0;
  a.acceptLatencyTotal = BigInt.fromI32(0);
  a.submitLatencyTotal = BigInt.fromI32(0);
  a.settleLatencyTotal = BigInt.fromI32(0);
  a.updatedAt = at;
  return a;
}

function resolve(wallet: Bytes): Agent | null {
  let link = WalletLink.load(wallet.toHexString());
  if (link == null) return null;
  return Agent.load(link.agent);
}

export function handleBondedIn(event: BondedIn): void {
  let id = event.params.agentId.toHexString();
  let a = Agent.load(id);
  if (a == null) a = blankAgent(id, event.block.timestamp);
  a.wallet = event.params.agent;
  a.bond = event.params.amount;
  a.registeredAt = event.block.timestamp;
  a.unlockAt = BigInt.fromI32(0);
  a.adapter = event.params.adapter;
  a.updatedAt = event.block.timestamp;
  a.save();
  let link = new WalletLink(event.params.agent.toHexString());
  link.agent = id;
  link.save();
}

export function handleBondAdded(event: BondAdded): void {
  let a = resolve(event.params.agent);
  if (a == null) return;
  a.bond = event.params.newTotal;
  a.updatedAt = event.block.timestamp;
  a.save();
}

export function handleExitRequested(event: ExitRequested): void {
  let a = resolve(event.params.agent);
  if (a == null) return;
  a.unlockAt = event.params.unlockAt;
  a.updatedAt = event.block.timestamp;
  a.save();
}

export function handleExited(event: Exited): void {
  let a = resolve(event.params.agent);
  if (a == null) return;
  a.bond = BigInt.fromI32(0);
  a.unlockAt = BigInt.fromI32(0);
  a.updatedAt = event.block.timestamp;
  a.save();
}

export function handleSlashed(event: Slashed): void {
  let a = resolve(event.params.agent);
  if (a == null) return;
  a.bond = a.bond.minus(event.params.amount);
  if (a.bond.lt(BigInt.fromI32(0))) a.bond = BigInt.fromI32(0);
  a.updatedAt = event.block.timestamp;
  a.save();
}

export function handleOutcomeRecorded(event: OutcomeRecorded): void {
  let a = resolve(event.params.agent);
  if (a == null) return;
  let o = event.params.outcome;
  if (o == 0) a.success += 1;
  else if (o == 1) a.neutral += 1;
  else if (o == 2) a.failure += 1;
  else a.fraud += 1;
  a.volume = a.volume.plus(event.params.volume);
  a.score = event.params.ewmaAfter; // exact onchain EWMA — leaderboard tier math is bit-for-bit
  a.updatedAt = event.block.timestamp;
  a.save();
}
