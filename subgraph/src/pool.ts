// CapitalPool mappings — singleton Pool row ("1"). Deposits/withdrawals flow
// through the OZ ERC-4626 Deposit/Withdraw events (the legacy Deposited /
// Withdrawn events are commented out in the implementation and never fire).
// totalPrincipal is NOT tracked here: the current contract no longer emits
// TotalPrincipalChanged, so the outstanding-principal ledger is driven by the
// CreditLine datasource (Drawn/Repaid/Slashed) writing the same Pool row.
import { BigInt } from "@graphprotocol/graph-ts";
import {
  Deposit,
  Withdraw,
  RevenueReceived,
  LossReported,
  LendEnabled,
  EmergencyPaused,
  EmergencyResumed,
} from "../generated/CapitalPool/CapitalPool";
import { Pool } from "../generated/schema";

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

export function handleDeposit(event: Deposit): void {
  let p = pool(event.block.timestamp);
  p.updatedAt = event.block.timestamp;
  p.save();
}

export function handleWithdraw(event: Withdraw): void {
  let p = pool(event.block.timestamp);
  p.updatedAt = event.block.timestamp;
  p.save();
}

export function handleRevenueReceived(event: RevenueReceived): void {
  let p = pool(event.block.timestamp);
  p.revenueTotal = p.revenueTotal.plus(event.params.amount);
  p.updatedAt = event.block.timestamp;
  p.save();
}

export function handleLossReported(event: LossReported): void {
  let p = pool(event.block.timestamp);
  p.lossTotal = p.lossTotal.plus(event.params.shortfall);
  p.updatedAt = event.block.timestamp;
  p.save();
}

export function handleLendEnabled(event: LendEnabled): void {
  let p = pool(event.block.timestamp);
  p.lendEnabled = event.params.enabled;
  p.updatedAt = event.block.timestamp;
  p.save();
}

export function handleEmergencyPaused(event: EmergencyPaused): void {
  let p = pool(event.block.timestamp);
  p.paused = true;
  p.updatedAt = event.block.timestamp;
  p.save();
}

export function handleEmergencyResumed(event: EmergencyResumed): void {
  let p = pool(event.block.timestamp);
  p.paused = false;
  p.updatedAt = event.block.timestamp;
  p.save();
}
