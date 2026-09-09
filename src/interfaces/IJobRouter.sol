// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// @title IJobRouter
/// @notice Onchain coordination engine for escrowed agent jobs.
interface IJobRouter {
    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    /// @notice Lifecycle states of a job.
    enum State {
        NONE, // job id unused
        POSTED, // escrowed and open for claims via access windows
        ASSIGNED, // exactly one agent has locked the job
        SUBMITTED, // agent posted a result hash before the deadline
        SETTLED, // terminal: payment distributed per the split table
        CANCELLED, // terminal: originator refunded (solo or mutual cancel)
        EXPIRED, // terminal: agent missed the execution deadline
        DISPUTED // originator rejected the submission; arbiter must resolve
    }

    /// @notice Severity-graded failure rulings.
    enum Severity {
        OOPS, // arbiter-ruled mutual "didn't work out" — NEUTRAL, weight-zero
        AGENT_FAULT, // honest but botched — FAILURE
        ORIGINATOR_FAULT, // vague spec / moving goalposts — FAILURE against originator
        MALICE // either party forfeits fully — FRAUD (5x weight)
    }

    /// @notice Per-job fee split in basis points. Must sum to 10_000.
    /// @param executorBps Share of remaining payment paid to the executing agent.
    /// @param lpBps Share paid to capital providers via the pool.
    /// @param treasuryBps Share accrued to the protocol accumulator.
    struct Split {
        uint16 executorBps;
        uint16 lpBps;
        uint16 treasuryBps;
    }

    /// @notice Full onchain record of a job.
    /// @param originator Address that created and funded the job.
    /// @param designatedAssignee Wallet exclusively permitted to accept this job;
    ///        address(0) for an open post (access windows apply), non-zero for a
    ///        direct hire (windows skipped entirely).
    /// @param specHash Content hash of the offchain job specification.
    /// @param payment USDC amount escrowed at creation.
    /// @param createdAt Timestamp of creation; access windows are measured from here.
    /// @param execDeadline Latest timestamp for submitResult to be callable.
    /// @param approvalWindow Length of the originator approve/reject window after
    ///                      submission; silent expiry auto-settles in the agent's favor.
    /// @param acceptedAt Timestamp the assigned agent accepted; anchors the 2h
    ///                   mutual-cancel free window. Zero until assigned.
    /// @param approvalDeadline Absolute deadline for originator approve/reject
    ///                         (set at submission; zero before).
    /// @param disputeDeadline Absolute deadline for the arbiter to rule (set at
    ///                        reject; zero otherwise). Silence past it auto-refunds.
    /// @param split Immutable fee distribution table validated at creation.
    /// @param assignedAgent Canonical agent identifier of the assigned agent (bytes32(0) until assigned).
    /// @param resultHash Content hash of the delivered result, set at submission.
    /// @param drawnForJob Working capital (USDC) the agent drew against this job.
    ///        [gated] 0 on every v1 settlement path — draw gates are OFF.
    /// @param opsBudget Optional declared operating budget for the assignee
    ///        (0 = undeclared). [gated] Tightens the job's settleable ceiling below
    ///        its default; never loosens it. Validated at creation:
    ///        opsBudget <= payment - SPLIT_FLOOR.
    /// @param state Current lifecycle state.
    struct Job {
        address originator;
        address designatedAssignee;
        bytes32 specHash;
        uint128 payment;
        uint64 createdAt;
        uint64 execDeadline;
        uint64 approvalWindow;
        uint64 acceptedAt;
        uint64 approvalDeadline;
        uint64 disputeDeadline;
        Split split;
        bytes32 assignedAgent;
        bytes32 resultHash;
        uint96 drawnForJob;
        uint96 opsBudget;
        State state;
    }

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    /// @notice Job id does not exist.
    error JobNotFound(uint256 jobId);
    /// @notice Action not permitted in the job's current state.
    error InvalidState(uint256 jobId, State current);
    /// @notice Caller is not the job's originator.
    error NotOriginator(uint256 jobId);
    /// @notice Caller is not the assigned agent.
    error NotAssignedAgent(uint256 jobId);
    /// @notice Caller is bonded but outside every access window for its tier.
    error WindowClosed(uint256 jobId);
    /// @notice Job is a direct hire and caller is not its designated assignee.
    error NotDesignatedAssignee(uint256 jobId);
    /// @notice Caller is not a bonded, unlocked, non-revoked agent.
    error NotEligibleAgent();
    /// @notice Submission arrived after the execution deadline.
    error DeadlinePassed(uint256 jobId);
    /// @notice Originator action while the approval window is still open.
    error ApprovalWindowOpen(uint256 jobId);
    /// @notice Split table violates sum-to-10_000 or hard bound rules.
    error InvalidSplit();
    /// @notice Payment violates protocol bounds.
    error InvalidPayment();
    /// @notice Draws would exceed the settleable ceiling. [gated] Unreachable in v1.
    error ExceedsSettleable(uint256 jobId);
    /// @notice Execution deadline is not in the future.
    error InvalidDeadline();
    /// @notice Only the arbiter may perform this action.
    error NotArbiter();
    /// @notice Mutual cancel: proposal terms outside free-window bounds.
    error InvalidCancelTerms(uint256 jobId);
    /// @notice Mutual cancel attempted by the party that already proposed.
    error NotCounterparty(uint256 jobId);
    /// @notice No standing mutual-cancel proposal to confirm.
    error NoPendingCancellation(uint256 jobId);
    /// @notice Agent's bond cannot absorb this job's worst-case failure fees.
    error BondCapacityShortfall(uint256 jobId);
    /// @notice Arbiter attempted to rule after the dispute window elapsed.
    error DisputeWindowElapsed(uint256 jobId);

    // ---------------------------------------------------------------------
    // Lifecycle — writing
    // ---------------------------------------------------------------------

    /// @notice Post a new job and escrow its USDC payment.
    /// @param payment USDC amount to escrow.
    /// @param specHash Content hash of the offchain job specification.
    /// @param split Fee distribution table, immutable after creation.
    /// @param execDeadline Absolute timestamp after which the job expires unfulfilled.
    /// @param approvalWindow Length of the originator approve/reject window after
    ///        submission; bounds [10 min, 7 days]. Silent expiry auto-settles in
    ///        the agent's favor.
    /// @param designatedAssignee Exclusive acceptor, or address(0) for an open post.
    /// @param opsBudget Optional declared operating budget for the assignee
    ///        (0 = undeclared → ceiling defaults to the settlement floor).
    /// @return jobId Id of the newly created job.
    function createJob(
        uint128 payment,
        bytes32 specHash,
        Split calldata split,
        uint64 execDeadline,
        uint64 approvalWindow,
        address designatedAssignee,
        uint96 opsBudget
    ) external returns (uint256 jobId);

    /// @notice Cancel a POSTED job before assignment; refunds originator minus fee.
    function cancel(uint256 jobId) external;

    /// @notice Claim a posted job as a bonded agent.
    function accept(uint256 jobId) external;

    /// @notice Draw working capital from the credit line against an assigned job.
    ///         [GATED] Both gates must be ON; reverts in v1.
    function drawWorkingCapital(uint256 jobId, uint256 amount) external;

    /// @notice Submit the deliverable for an assigned job before its deadline.
    function submitResult(uint256 jobId, bytes32 resultHash) external;

    /// @notice Originator accepts the submitted work; settles successfully.
    function approve(uint256 jobId) external;

    /// @notice Originator contests the submitted work; moves to DISPUTED.
    function reject(uint256 jobId, bytes32 reasonHash) external;

    /// @notice Auto-settle after silent originator approval timeout.
    function timeoutSettle(uint256 jobId) external;

    /// @notice Expire a job whose execution deadline passed without submission.
    function expire(uint256 jobId) external;

    /// @notice Arbiter rules a severity-graded resolution for a disputed job.
    function resolveDispute(uint256 jobId, Severity ruling) external;

    /// @notice Propose a mutual cancellation during ASSIGNED or SUBMITTED.
    function proposeMutualCancel(uint256 jobId, uint16 originatorBps, uint16 agentBps) external;

    /// @notice Confirm a standing mutual-cancel proposal (the OTHER party).
    function confirmMutualCancel(uint256 jobId) external;

    // ---------------------------------------------------------------------
    // Lifecycle — reading
    // ---------------------------------------------------------------------

    /// @notice Full onchain record of a job. Reverts if the id does not exist.
    function jobs(uint256 jobId) external view returns (Job memory);

    /// @notice Number of jobs ever created; ids are sequential from 1.
    function jobCount() external view returns (uint256);

    /// @notice True if `agent` may currently call accept() on this job.
    function canAccept(uint256 jobId, address agent) external view returns (bool);

    /// @notice Timestamp when the next wider access window opens for this job.
    function nextWindowAt(uint256 jobId) external view returns (uint64);

    /// @notice Address empowered to rule on disputed jobs (multisig in v1).
    function arbiter() external view returns (address);

    // ---------------------------------------------------------------------
    // Parameters (timelocked owner; every value bounded per architecture §7)
    // ---------------------------------------------------------------------

    /// @notice Set the two staggered window offsets (minutes-scale defaults).
    function setAccessWindows(uint64 w0, uint64 w1) external;

    /// @notice Set the cancel/expire fee in basis points (hard capped at 100).
    function setCancelFeeBps(uint16 bps) external;

    /// @notice Upper bound on per-job payment. Bribe-resistance guardrail.
    function maxPayment() external view returns (uint128);

    /// @notice Set the per-job payment ceiling. Hard-capped at 50_000 USDC.
    function setMaxPayment(uint128 newMax) external;

    /// @notice Settlement-floor fraction of payment backing the per-job draw ceiling,
    ///         in bps. Default 2000; hard-bounded [500, 3000].
    function splitFloorBps() external view returns (uint16);

    /// @notice Set the settlement-floor fraction. Hard-bounded [500, 3000].
    function setSplitFloorBps(uint16 bps) external;

    /// @notice Transfer arbiter authority to a new address.
    function setArbiter(address newArbiter) external;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice A job was created and funded. Windows start ticking.
    event JobPosted(
        uint256 indexed jobId,
        address indexed originator,
        uint128 payment,
        bytes32 specHash,
        uint64 execDeadline,
        uint96 opsBudget
    );
    /// @notice An agent locked the job exclusively.
    event JobAccepted(uint256 indexed jobId, bytes32 indexed agent, uint64 acceptedAt);
    /// @notice Working capital drawn from the credit line against this job. [gated]
    event WorkingCapitalDrawn(uint256 indexed jobId, uint256 amount);
    /// @notice Deliverable committed before the deadline; approval window started.
    event ResultSubmitted(uint256 indexed jobId, bytes32 resultHash);
    /// @notice Job settled successfully.
    event JobSettled(uint256 indexed jobId, bytes32 indexed agent, uint256 debtRepaid, uint256[3] amounts);
    /// @notice Originator cancelled before assignment; refund after cancel fee.
    event JobCancelled(uint256 indexed jobId, uint256 refunded, uint256 fee);
    /// @notice Agent missed the deadline; refund after fee, slash applied.
    event JobExpired(uint256 indexed jobId, uint256 refunded, uint256 slashed);
    /// @notice Originator contested the submission.
    event DisputeOpened(uint256 indexed jobId, bytes32 indexed reasonHash);
    /// @notice Arbiter ruled a severity; reflects resolveDispute's {Severity} parameter.
    event DisputeResolved(uint256 indexed jobId, Severity ruling);
    /// @notice Approval window elapsed silently; settled in the agent's favor.
    event TimeoutSettled(uint256 indexed jobId);
    /// @notice Arbiter was silent past the dispute deadline; escrow auto-refunded.
    event DisputeExpired(uint256 indexed jobId, uint256 refunded);
    /// @notice A mutual-cancel offer was posted; counterparty must confirm.
    event MutualCancelProposed(uint256 indexed jobId, address proposer, uint16 originatorBps, uint16 agentBps);
    /// @notice A mutual-cancel proposal was confirmed; job wound down as NEUTRAL.
    event MutualCancelled(uint256 indexed jobId);
}
