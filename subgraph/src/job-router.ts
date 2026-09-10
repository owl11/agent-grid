// JobRouter mappings — every lifecycle event folds into one Job row + an
// append-only JobEvent audit trail (the frontend's Router Events tab).
import { BigInt, Bytes } from "@graphprotocol/graph-ts";
import {
  JobPosted,
  JobAccepted,
  ResultSubmitted,
  JobSettled,
  JobCancelled,
  JobExpired,
  TimeoutSettled,
  DisputeOpened,
  DisputeResolved,
  DisputeExpired,
  MutualCancelProposed,
  MutualCancelled,
  WorkingCapitalDrawn,
} from "../generated/JobRouter/JobRouter";
import { Job, Agent, JobEvent } from "../generated/schema";

function logEvent(jobId: BigInt, kind: string, at: BigInt, tx: Bytes): void {
  let id = tx.toHexString().concat("-").concat(kind);
  let e = new JobEvent(id);
  e.jobId = jobId;
  e.kind = kind;
  e.at = at;
  e.txHash = tx;
  e.save();
}

function touch(j: Job, at: BigInt): void {
  j.updatedAt = at;
  j.save();
}

export function handleJobPosted(event: JobPosted): void {
  let j = new Job(event.params.jobId.toString());
  j.originator = event.params.originator;
  j.designatedAssignee = Bytes.fromHexString("0x0000000000000000000000000000000000000000");
  j.specHash = event.params.specHash;
  j.payment = event.params.payment;
  j.createdAt = event.block.timestamp;
  j.execDeadline = event.params.execDeadline;
  j.approvalWindow = BigInt.fromI32(0);
  j.acceptedAt = BigInt.fromI32(0);
  j.approvalDeadline = BigInt.fromI32(0);
  j.submittedAt = BigInt.fromI32(0);
  j.settledAt = BigInt.fromI32(0);
  // Split table + designatedAssignee are validated at creation but NOT emitted
  // in JobPosted — the zero-sentinel default (9000/500/500 inert) is the common
  // case; exact custom rows and direct-hire status resolve client-side via a
  // single jobs(jobId) call per job. Documented indexing limit, not a gap.
  j.executorBps = 9000;
  j.lpBps = 500;
  j.treasuryBps = 500;
  j.assignedAgent = Bytes.fromHexString("0x0000000000000000000000000000000000000000000000000000000000000000");
  j.assignedWallet = Bytes.fromHexString("0x0000000000000000000000000000000000000000");
  j.resultHash = Bytes.fromHexString("0x0000000000000000000000000000000000000000000000000000000000000000");
  j.drawnForJob = BigInt.fromI32(0);
  j.opsBudget = event.params.opsBudget;
  j.state = "POSTED";
  j.executorPaid = BigInt.fromI32(0);
  j.lpPaid = BigInt.fromI32(0);
  j.treasuryPaid = BigInt.fromI32(0);
  j.debtRepaid = BigInt.fromI32(0);
  j.outcome = null;
  j.updatedAt = event.block.timestamp;
  j.save();
  logEvent(event.params.jobId, "Posted", event.block.timestamp, event.transaction.hash);
}

export function handleJobAccepted(event: JobAccepted): void {
  let j = Job.load(event.params.jobId.toString());
  if (j == null) return;
  j.assignedAgent = event.params.agent;
  // Resolve agentId -> wallet for the frontend's assignedWallet read. Falls
  // back to zero-addr when no BondedIn row exists for this agentId.
  let a = Agent.load(event.params.agent.toHexString());
  j.assignedWallet = a != null
    ? a.wallet
    : Bytes.fromHexString("0x0000000000000000000000000000000000000000");
  j.acceptedAt = event.params.acceptedAt;
  j.state = "ASSIGNED";
  touch(j, event.block.timestamp);
  if (a != null) {
    a.jobsAssigned += 1;
    a.updatedAt = event.block.timestamp;
    a.save();
  }
  logEvent(event.params.jobId, "Accepted", event.block.timestamp, event.transaction.hash);
}

export function handleResultSubmitted(event: ResultSubmitted): void {
  let j = Job.load(event.params.jobId.toString());
  if (j == null) return;
  j.resultHash = event.params.resultHash;
  j.submittedAt = event.block.timestamp;
  // approvalDeadline isn't emitted — derive exactly as the contract does
  // (submit time + approvalWindow) so the indexed field is truthful.
  j.approvalDeadline = event.block.timestamp.plus(j.approvalWindow);
  j.state = "SUBMITTED";
  touch(j, event.block.timestamp);
  logEvent(event.params.jobId, "ResultSubmitted", event.block.timestamp, event.transaction.hash);
}

export function handleJobSettled(event: JobSettled): void {
  let j = Job.load(event.params.jobId.toString());
  if (j == null) return;
  let amounts = event.params.amounts;
  j.debtRepaid = event.params.debtRepaid;
  j.executorPaid = amounts[0];
  j.lpPaid = amounts[1];
  j.treasuryPaid = amounts[2];
  j.state = "SETTLED";
  j.outcome = "SUCCESS";
  j.settledAt = event.block.timestamp;
  // Per-agent latency aggregates — sums only (averages stay client-side).
  // TimeoutSettled flows through here too (same JobSettled event).
  let a = Agent.load(j.assignedAgent.toHexString());
  if (a != null) {
    a.jobsCompleted += 1;
    a.acceptLatencyTotal = a.acceptLatencyTotal.plus(j.acceptedAt.minus(j.createdAt));
    a.submitLatencyTotal = a.submitLatencyTotal.plus(j.submittedAt.minus(j.acceptedAt));
    a.settleLatencyTotal = a.settleLatencyTotal.plus(event.block.timestamp.minus(j.submittedAt));
    a.updatedAt = event.block.timestamp;
    a.save();
  }
  touch(j, event.block.timestamp);
  logEvent(event.params.jobId, "Settled", event.block.timestamp, event.transaction.hash);
}

export function handleJobCancelled(event: JobCancelled): void {
  let j = Job.load(event.params.jobId.toString());
  if (j == null) return;
  j.state = "CANCELLED";
  j.treasuryPaid = event.params.fee;
  touch(j, event.block.timestamp);
  logEvent(event.params.jobId, "Cancelled", event.block.timestamp, event.transaction.hash);
}

export function handleJobExpired(event: JobExpired): void {
  let j = Job.load(event.params.jobId.toString());
  if (j == null) return;
  j.state = "EXPIRED";
  j.outcome = "FAILURE";
  touch(j, event.block.timestamp);
  logEvent(event.params.jobId, "Expired", event.block.timestamp, event.transaction.hash);
}

export function handleTimeoutSettled(event: TimeoutSettled): void {
  // TimeoutSettled fires immediately before JobSettled in the same tx — record
  // the audit row; the state flip lands in handleJobSettled.
  let j = Job.load(event.params.jobId.toString());
  if (j == null) return;
  logEvent(event.params.jobId, "TimeoutSettled", event.block.timestamp, event.transaction.hash);
}

export function handleDisputeOpened(event: DisputeOpened): void {
  let j = Job.load(event.params.jobId.toString());
  if (j == null) return;
  j.state = "DISPUTED";
  touch(j, event.block.timestamp);
  logEvent(event.params.jobId, "DisputeOpened", event.block.timestamp, event.transaction.hash);
}

export function handleDisputeResolved(event: DisputeResolved): void {
  let j = Job.load(event.params.jobId.toString());
  if (j == null) return;
  let ruling = event.params.ruling;
  if (ruling == 0) {
    j.state = "CANCELLED";
    j.outcome = "NEUTRAL";
  } else if (ruling == 1 || ruling == 2) {
    j.state = "EXPIRED";
    j.outcome = "FAILURE";
  } else {
    j.state = "CANCELLED";
    j.outcome = "FRAUD";
  }
  touch(j, event.block.timestamp);
  logEvent(event.params.jobId, "DisputeResolved", event.block.timestamp, event.transaction.hash);
}

export function handleDisputeExpired(event: DisputeExpired): void {
  let j = Job.load(event.params.jobId.toString());
  if (j == null) return;
  j.state = "CANCELLED";
  touch(j, event.block.timestamp);
  logEvent(event.params.jobId, "DisputeExpired", event.block.timestamp, event.transaction.hash);
}

export function handleMutualCancelProposed(event: MutualCancelProposed): void {
  let j = Job.load(event.params.jobId.toString());
  if (j == null) return;
  logEvent(event.params.jobId, "MutualCancelProposed", event.block.timestamp, event.transaction.hash);
}

export function handleMutualCancelled(event: MutualCancelled): void {
  let j = Job.load(event.params.jobId.toString());
  if (j == null) return;
  j.state = "CANCELLED";
  j.outcome = "NEUTRAL";
  touch(j, event.block.timestamp);
  logEvent(event.params.jobId, "MutualCancelled", event.block.timestamp, event.transaction.hash);
}

export function handleWorkingCapitalDrawn(event: WorkingCapitalDrawn): void {
  let j = Job.load(event.params.jobId.toString());
  if (j == null) return;
  j.drawnForJob = event.params.amount;
  touch(j, event.block.timestamp);
  logEvent(event.params.jobId, "WorkingCapitalDrawn", event.block.timestamp, event.transaction.hash);
}
