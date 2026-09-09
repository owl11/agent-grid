// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;
import {IJobRouter} from "../src/interfaces/IJobRouter.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAgentRegistry} from "../src/interfaces/IAgentRegistry.sol";
import {ICreditLine} from "./interfaces/ICreditLine.sol";
import {ICapitalPool} from "../src/interfaces/ICapitalPool.sol";
import {ValueSplit} from "./libraries/ValueSplit.sol";

contract JobRouter is IJobRouter {
    using SafeERC20 for IERC20;
    IERC20 token;
    IAgentRegistry registry; // NOT IAgentIdentity — that's the adapter interface
    ICreditLine credit;
    ICapitalPool pool;
    address public arbiter;
    address public treasury;
    address public owner;
    uint256 public jobCount;
    mapping(uint256 => Job) internal jobLedger; // explicit jobs() below — name can't collide with the fn

    // params (owner-gated, bounded)
    uint64 public W0 = 10 minutes; // [1 min, 24 h]
    uint64 public W1 = 10 minutes; // [1 min, 24 h]
    uint16 public cancelFeeBps = 50; // hard ≤ 100
    uint128 public maxPayment = 5_000e6; // hard ≤ 50_000e6
    uint16 public splitFloorBps = 2000; // [500, 3000]

    // constants — happy-path only. The dispute/mutual-cancel/slash tables
    // (FREE_WINDOW, DISPUTE_WINDOW, OOPS_*/AF_*/OF_*) are POSTPONED with the lending
    // layer: lending is dual-gate OFF in the demo, so there is nothing to slash,
    // dispute, or friendly-unwind. The full table ships with the lending-era build;
    // it is not compiled into the v1 artifact.
    uint64 public constant MIN_EXEC = 15 minutes;
    uint64 public constant MAX_EXEC = 30 days;
    uint64 public constant MIN_APPROVAL = 10 minutes;
    uint64 public constant MAX_APPROVAL = 7 days;
    uint64 public constant MIN_PAYMENT = 1e6;

    constructor(IERC20 _token, IAgentRegistry _registry, ICapitalPool _pool, address _treasury) {
        token = _token;
        registry = _registry;
        pool = _pool;
        treasury = _treasury;
        arbiter = msg.sender;
        owner = msg.sender;
    }

    /// @dev Deploy-order setter: CreditLine binds to this router, so it must be
    ///      deployed first and wired second (pool.setRouter/setCreditLine likewise).
    function setCredit(ICreditLine _credit) external {
        if (msg.sender != owner) revert();
        credit = _credit;
    }

    function createJob(
        uint128 payment,
        bytes32 specHash,
        Split calldata split,
        uint64 execDeadline,
        uint64 approvalWindow,
        address designatedAssignee,
        uint96 opsBudget
    ) external returns (uint256 jobId) {
        // payment bounds — zero/min/max (bribe-resistance guardrail)
        if (payment == 0 || payment < MIN_PAYMENT || payment > maxPayment) revert InvalidPayment();
        // split table — sum-to-10_000 + hard bounds (I4). Zero-sentinel (0/0/0) means
        // "use the regime-coupled default": both lending gates OFF → inert row
        // (9000/500/500), both ON → active row (8500/1000/500). Custom splits are
        // validated exactly as before; the RESOLVED table is what the Job record
        // stamps and what settlement pays.
        Split memory resolved = split;
        if (resolved.executorBps == 0 && resolved.lpBps == 0 && resolved.treasuryBps == 0) {
            ValueSplit.Split memory d = _poolLendingOn() ? ValueSplit.defaultsactive() : ValueSplit.defaultsInactive();
            resolved = Split({executorBps: d.executorBps, lpBps: d.lpBps, treasuryBps: d.treasuryBps});
        }
        ValueSplit.validate(
            ValueSplit.Split({
                executorBps: resolved.executorBps, lpBps: resolved.lpBps, treasuryBps: resolved.treasuryBps
            })
        );

        // execution deadline — originator-set, within [15 min, 30 days]
        if (execDeadline < block.timestamp + MIN_EXEC || execDeadline > block.timestamp + MAX_EXEC) {
            revert InvalidDeadline();
        }
        // approval window — [10 min, 7 days]
        if (approvalWindow < MIN_APPROVAL || approvalWindow > MAX_APPROVAL) revert();

        // opsBudget — only bounded when declared (> 0); gate is OFF in v1 so the
        // per-job settleable ceiling is never tightened on a live path.
        if (opsBudget > 0) {
            uint256 floor = _splitFloor(payment);
            if (opsBudget > payment - floor) revert();
        }

        // escrow the payment 1:1 — the originator's own deposit backs the job.
        token.safeTransferFrom(msg.sender, address(this), payment);

        jobId = ++jobCount;
        jobLedger[jobId] = Job({
            originator: msg.sender,
            designatedAssignee: designatedAssignee,
            specHash: specHash,
            payment: payment,
            createdAt: uint64(block.timestamp),
            execDeadline: execDeadline,
            approvalWindow: approvalWindow,
            acceptedAt: 0,
            approvalDeadline: 0,
            disputeDeadline: 0,
            split: resolved,
            assignedAgent: bytes32(0),
            resultHash: bytes32(0),
            drawnForJob: 0,
            opsBudget: opsBudget,
            state: State.POSTED
        });
        emit JobPosted(jobId, msg.sender, payment, specHash, execDeadline, opsBudget);
    }

    /// @notice Originator cancels a job that was never assigned. Full refund minus the
    ///         treasury-directed cancel fee. I2 terminal path.
    function cancel(uint256 jobId) external {
        Job storage j = _fetch(jobId);
        if (msg.sender != j.originator) revert NotOriginator(jobId);
        if (j.state != State.POSTED) revert InvalidState(jobId, j.state);

        uint256 fee = _refundWithFee(j.originator, j.payment);
        j.state = State.CANCELLED;
        emit JobCancelled(jobId, j.payment - fee, fee);
    }

    /// @notice Claim a posted job. Open posts run tiered access windows; direct hires
    ///         are gated to the designated wallet only. Bond-capacity gate sizes
    ///         skin-in-the-game (bondOf >= payment).
    function accept(uint256 jobId) external {
        Job storage j = _fetch(jobId);
        if (j.state != State.POSTED) revert InvalidState(jobId, j.state);

        // direct hire: only the designated wallet (windows skipped entirely)
        if (j.designatedAssignee != address(0)) {
            if (msg.sender != j.designatedAssignee) revert NotDesignatedAssignee(jobId);
        }
        // eligibility: bonded, unlocked, non-debt-locked, non-revoked
        if (!registry.isEligible(msg.sender)) revert NotEligibleAgent();
        // (open posts only) tiered access windows — first eligible claimant wins
        if (j.designatedAssignee == address(0)) {
            if (!_windowOpen(j.createdAt, _tierOf(msg.sender))) revert WindowClosed(jobId);
        }
        // bond-capacity gate: worst-case failure fees must fit in the posted bond
        if (registry.bondOf(msg.sender) < j.payment) revert BondCapacityShortfall(jobId);

        j.assignedAgent = registry.agentIdOf(msg.sender);
        j.acceptedAt = uint64(block.timestamp);
        j.state = State.ASSIGNED;
        emit JobAccepted(jobId, j.assignedAgent, j.acceptedAt);
    }

    /// @notice Working capital draws are POSTPONED for the demo — lending is dual-gate
    ///         OFF (both CreditLine and CapitalPool gates default OFF in v1). The
    ///         signature is kept for ABI stability; it always reverts.
    function drawWorkingCapital(uint256, uint256) external pure {
        revert ICreditLine.LendingDisabled();
    }

    function submitResult(uint256 jobId, bytes32 resultHash) external {
        Job storage j = _fetch(jobId);
        if (j.state != State.ASSIGNED) revert InvalidState(jobId, j.state);
        address wallet = _agentWallet(jobId);
        if (msg.sender != wallet) revert NotAssignedAgent(jobId);
        if (block.timestamp > j.execDeadline) revert DeadlinePassed(jobId);

        j.resultHash = resultHash;
        j.approvalDeadline = uint64(block.timestamp) + j.approvalWindow;
        j.state = State.SUBMITTED;
        emit ResultSubmitted(jobId, resultHash);
    }

    /// @notice Originator approves the submitted work; settles successfully.
    ///         Settlement order (I3): repay [no-op v1] → wage-capped split → outcome.
    function approve(uint256 jobId) external {
        Job storage j = _fetch(jobId);
        if (j.state != State.SUBMITTED) revert InvalidState(jobId, j.state);
        if (msg.sender != j.originator) revert NotOriginator(jobId);
        if (block.timestamp > j.approvalDeadline) revert ApprovalWindowOpen(jobId);
        _settleSuccess(jobId);
    }

    /// @notice POSTPONED for the demo — disputes are deferred with the lending layer
    ///         (no loans ⇒ no borrowed funds to resolve ⇒ no dispute path). Restored
    ///         in the lending-era (testnet) build.
    function reject(uint256, bytes32) external pure {
        revert();
    }

    /// @notice Auto-settle in the agent's favor after the originator's approval
    ///         window elapsed silently.
    function timeoutSettle(uint256 jobId) external {
        Job storage j = _fetch(jobId);
        if (j.state != State.SUBMITTED) revert InvalidState(jobId, j.state);
        if (block.timestamp <= j.approvalDeadline) revert ApprovalWindowOpen(jobId); // still open
        emit TimeoutSettled(jobId);
        _settleSuccess(jobId);
    }

    /// @notice Expire a job whose execution deadline passed without submission.
    ///         Refund minus cancel fee; FAILURE recorded. NO bond slash in the demo —
    ///         slashing belongs to the lending-era (testnet) build.
    function expire(uint256 jobId) external {
        Job storage j = _fetch(jobId);
        if (j.state != State.ASSIGNED) revert InvalidState(jobId, j.state);
        if (block.timestamp <= j.execDeadline) revert DeadlinePassed(jobId);

        address wallet = _agentWallet(jobId);
        uint256 fee = _refundWithFee(j.originator, j.payment);
        j.state = State.EXPIRED;
        _recordOutcome(jobId, wallet, IAgentRegistry.Outcome.FAILURE, j.payment);
        emit JobExpired(jobId, j.payment - fee, 0);
    }

    /// @notice POSTPONED for the demo — same rationale as reject(). One-line revert
    ///         stub keeps the ABI stable for the graph indexer.
    function resolveDispute(uint256, Severity) external pure {
        revert();
    }

    function jobs(uint256 jobId) external view returns (Job memory) {
        return _fetch(jobId);
    }

    /// @notice True if `agent` may currently call accept() on this job.
    function canAccept(uint256 jobId, address agent) external view returns (bool) {
        Job storage j = _fetch(jobId);
        if (j.state != State.POSTED) return false;
        if (j.designatedAssignee != address(0)) {
            // direct hires pay the SAME gates as accept() — including the
            // bond-capacity check (view must not say yes where accept reverts)
            return agent == j.designatedAssignee && registry.isEligible(agent) && registry.bondOf(agent) >= j.payment;
        }
        return
            registry.isEligible(agent) && registry.bondOf(agent) >= j.payment
                && _windowOpen(j.createdAt, _tierOf(agent));
    }

    function nextWindowAt(uint256 jobId) external view returns (uint64) {
        Job storage j = _fetch(jobId);
        if (j.designatedAssignee != address(0)) return 0; // direct hire: no window gating
        uint64 base = uint64(block.timestamp);
        uint64 open = j.createdAt + W0; // W0 → tier ≥ 3
        if (base >= open + W1) return 0; // W2: every bonded agent (tier ≥ 0)
        if (base >= open) return open + W1; // W1 → tier ≥ 2
        return open; // W0 → tier ≥ 3
    }

    /// @notice POSTPONED for the demo — the two-tx consent unwind belongs to the
    ///         lending-era (testnet) build (restored there).
    function proposeMutualCancel(uint256, uint16, uint16) external pure {
        revert();
    }

    /// @notice POSTPONED for the demo — see proposeMutualCancel().
    function confirmMutualCancel(uint256) external pure {
        revert();
    }

    function setAccessWindows(uint64 w0, uint64 w1) external {
        if (msg.sender != owner) revert();
        // [1 min, 24 h]
        if (w0 < 1 minutes || w0 > 24 hours) revert();
        if (w1 < 1 minutes || w1 > 24 hours) revert();
        W0 = w0;
        W1 = w1;
    }

    function setCancelFeeBps(uint16 bps) external {
        if (msg.sender != owner) revert();
        // hard ≤ 100 bps (≤ 1%)
        if (bps > 100) revert();
        cancelFeeBps = bps;
    }

    function setMaxPayment(uint128 newMax) external {
        if (msg.sender != owner) revert();
        // hard cap 50_000 USDC (bribe-resistance guardrail)
        if (newMax > 50_000e6) revert();
        maxPayment = newMax;
    }

    function setSplitFloorBps(uint16 bps) external {
        if (msg.sender != owner) revert();
        // hard bounds [500, 3000]
        if (bps < 500 || bps > 3000) revert();
        splitFloorBps = bps;
    }

    function setArbiter(address newArbiter) external {
        if (msg.sender != owner) revert();
        arbiter = newArbiter;
    }

    // ---------------- internal helpers ----------------

    /// @dev Regime bit for the split-default table: BOTH halves of the lending dual
    ///      gate must be ON for the draws-active row; the demo ships both OFF, so
    ///      zero-split jobs resolve to the inert row. Unwired credit ⇒ treated as OFF.
    function _poolLendingOn() internal view returns (bool) {
        return address(credit) != address(0) && pool.lendEnabled() && credit.lendingEnabled();
    }

    /// @dev Storage-backed fetch of a job; reverts for unused ids.
    function _fetch(uint256 jobId) internal view returns (Job storage j) {
        j = jobLedger[jobId];
        if (j.originator == address(0)) revert JobNotFound(jobId);
    }

    function _agentWallet(uint256 jobId) internal view returns (address) {
        Job storage j = _fetch(jobId);
        return registry.agentIdOwnerOf(j.assignedAgent);
    }

    /// @dev Reputation tier of the caller, derived from the registry (used by the
    ///      tiered access windows). Registry is the single source of truth.
    function _tierOf(address who) internal view returns (uint8) {
        return registry.tier(who);
    }

    /// @dev Wage cap for an agent at settlement (experience-rated; wrapper omitted in
    ///      v1 — treated as a flat 9000 bps base). The network is a deterministic pure
    ///      function of the agent's settled-outcome count and mirrored client-side by
    ///      the demo frontend's `WAGE = { start: 9000, stepBps: 500, stepJobs: 10, floor: 7000 }`.
    function _executorCap() internal pure returns (uint16) {
        return 9000;
    }

    /// @dev Transfer `amount` out of escrow to `pool` and book it as settlement
    ///      revenue (raises pps WITHOUT minting — the v1 LP yield source).
    function _poolSlice(uint256 amount) internal {
        if (amount == 0) return;
        token.safeTransfer(address(pool), amount);
        pool.receiveRevenue(amount);
    }

    /// @dev Record an outcome with the registry (moved to a helper so every terminal
    ///      path applies the same auth/volume semantics).
    function _recordOutcome(uint256 jobId, address wallet, IAgentRegistry.Outcome o, uint256 volume) internal {
        registry.recordOutcome(wallet, jobId, o, volume);
    }

    /// @dev Fixed-point bps scale (no overflow for our sizes).
    function _bps(uint256 value, uint16 bps) internal pure returns (uint256) {
        return (value * uint256(bps)) / 10_000;
    }

    /// @dev Refund-vs-fee split shared by cancel()/expire(): transfers `amount − fee`
    ///      to the recipient and the cancel fee to the treasury. Returns the fee.
    function _refundWithFee(address recipient, uint256 amount) internal returns (uint256 fee) {
        fee = _bps(amount, cancelFeeBps);
        token.safeTransfer(recipient, amount - fee);
        token.safeTransfer(treasury, fee);
    }

    /// @dev SPLIT_FLOOR for the per-job draw ceiling:
    ///      max(MIN_TOTAL, payment × splitFloorBps / 10_000).
    function _splitFloor(uint256 payment) internal view returns (uint256) {
        uint256 scaled = _bps(payment, splitFloorBps);
        // MIN_TOTAL = 0.1 USDC (splittability minimum from ValueSplit)
        if (scaled < ValueSplit.MIN_TOTAL) scaled = ValueSplit.MIN_TOTAL;
        return scaled;
    }

    /// @dev Succeed-settlement path (shared by approve/timeoutSettle). Fixed order (I3):
    ///      repay [no-op v1] → wage-capped split → outcome. Escrow is distributed exactly
    ///      (I4): executor (capped) → agent wallet, lp → pool (revenue), treasury → treasury.
    function _settleSuccess(uint256 jobId) internal {
        Job storage j = _fetch(jobId);
        address wallet = _agentWallet(jobId);

        // 1) repay drawn principal (no-op in v1 — gates OFF, drawnForJob == 0)
        if (j.drawnForJob != 0) {
            if (address(credit) == address(0)) revert();
            credit.repay(j.assignedAgent, j.drawnForJob);
        }

        // 2) wage-capped split
        (uint256 executor, uint256 lp, uint256 treasuryAmt) = ValueSplit.amounts(
            ValueSplit.Split({
                executorBps: j.split.executorBps, lpBps: j.split.lpBps, treasuryBps: j.split.treasuryBps
            }),
            j.payment
        );
        uint16 cap = _executorCap();
        if (cap < j.split.executorBps) {
            // min(executorBps, cap) — delta redistributed pro rata to lp/treasury.
            uint256 cappedExecutor = _bps(j.payment, cap);
            uint256 delta = executor - cappedExecutor;
            executor = cappedExecutor;
            uint256 passiveBps = uint256(j.split.lpBps) + uint256(j.split.treasuryBps);
            lp += (delta * j.split.lpBps) / passiveBps;
            treasuryAmt = j.payment - executor - lp; // remainder → no dust (I4)
        }

        // 3) distribute
        if (executor > 0) token.safeTransfer(wallet, executor);
        _poolSlice(lp); // lp → pool (transfer-in + receiveRevenue)
        if (treasuryAmt > 0) token.safeTransfer(treasury, treasuryAmt);

        _recordOutcome(jobId, wallet, IAgentRegistry.Outcome.SUCCESS, j.payment);
        j.state = State.SETTLED;
        emit JobSettled(jobId, j.assignedAgent, j.drawnForJob, [executor, lp, treasuryAmt]);
    }

    /// @dev True if the tier's access window is currently open for a job created at
    ///      `createdAt`. Windows are pure priority (P5): tier ≥ 3 → W0
    ///      (createdAt+W0); tiers ≤ 2 → createdAt+W0+W1 (W1 and W2 coincide —
    ///      every bonded agent is eventually eligible; tiers buy earlier access).
    function _windowOpen(uint64 createdAt, uint8 tier) internal view returns (bool) {
        uint64 now_ = uint64(block.timestamp);
        // Two effective priority levels: tier ≥ 3 at W0 (createdAt+W0); tiers ≤ 2 at
        // createdAt+W0+W1 — W1 and W2 open at the same instant (the former tier==2
        // branch was a byte-identical duplicate of the fallback).
        if (tier >= 3) return now_ >= createdAt + W0;
        return now_ >= createdAt + W0 + W1;
    }

    /// @dev Mutual-cancel proposal storage was removed with the postponed feature
    ///      (demo); restored with the lending-era (testnet) build.
}
