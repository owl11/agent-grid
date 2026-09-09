// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IAgentIdentity} from "./IAgentIdentity.sol";

/// @title IAgentRegistry
/// @notice Bonding, identity binding, and append-only reputation for agents.
interface IAgentRegistry {
    /// @notice Settlement outcomes recorded at job terminal states.
    enum Outcome {
        SUCCESS, // work approved or timeout-settled in the agent's favor
        NEUTRAL, // friendly exit (mutual cancel, OOPS) — WEIGHT-ZERO in the score
        FAILURE, // expiry or AGENT_FAULT/ORIGINATOR_FAULT ruling — scores 0
        FRAUD // MALICE ruling — enters the score at 5x a failure's weight
    }

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error AlreadyBonded();
    error NotBonded();
    error BelowMinBond();
    /// @notice Ownership of `externalId` could not be verified.
    error UnverifiedIdentity();
    error AgentIdAlreadyBound(bytes32 agentId);
    /// @notice Exit requested but the unlock delay has not elapsed.
    error UnlockPending();
    /// @notice Outstanding credit debt blocks exit.
    error ExitBlockedByDebt();
    error SlashExceedsBond();
    /// @notice Caller is not the address authorized for this action.
    error UnauthorizedCaller();

    // ---------------------------------------------------------------------
    // Bonding
    // ---------------------------------------------------------------------

    /// @notice Become a bonded agent: escrow USDC and bind an identity.
    /// @param adapter Identity adapter verifying ownership; pass `IAgentIdentity(0)`
    ///                for bare-address mode (wallet == identity, externalId ignored).
    /// @param externalId Token id on the SOURCE registry; unused in bare mode.
    /// @param amount USDC to escrow; must be >= minBond. Top up later via addBond.
    function bondIn(IAgentIdentity adapter, uint256 externalId, uint256 amount) external;

    /// @notice Increase the bond. Raises the credit floor immediately.
    function addBond(uint256 amount) external;

    /// @notice Begin the exit process; blocked while credit debt is outstanding.
    function requestExit() external;

    /// @notice Complete an unlocked exit: return bond, clear identity binding.
    function completeExit() external;

    // ---------------------------------------------------------------------
    // Enforcement and recording (coordination engine / credit line only)
    // ---------------------------------------------------------------------

    /// @notice Seize bond and forward to the CapitalPool.
    /// @param agent Address whose bond is seized.
    /// @param amount USDC to seize.
    /// @param reasonHash Content hash of offchain evidence for the slash.
    function slash(address agent, uint256 amount, bytes32 reasonHash) external;

    /// @notice Append a reputation event at job terminal state.
    function recordOutcome(address agent, uint256 jobId, Outcome outcome, uint256 volume) external;

    /// @notice Toggle the debt lock that prevents exit while credit is owed.
    ///         Called by the credit line when debt is created or cleared.
    function setDebtLock(address agent, bool locked) external;

    // ---------------------------------------------------------------------
    // Reading
    // ---------------------------------------------------------------------

    /// @notice Current bonded amount in USDC.
    function bondOf(address agent) external view returns (uint256);

    /// @notice Canonical agent identifier bound to this address.
    function agentIdOf(address agent) external view returns (bytes32);

    /// @notice Wallet owning a canonical agent identifier.
    function agentIdOwnerOf(bytes32 agentId) external view returns (address);

    /// @notice Deterministic reputation score, scaled 1e18 = perfect.
    function repScore(address agent) external view returns (uint256);

    /// @notice Reputation tier 0–3 derived from repScore thresholds.
    function tier(address agent) external view returns (uint8);

    /// @notice Timestamp when a requested exit becomes completable.
    function unlockAt(address agent) external view returns (uint64);

    /// @notice True while outstanding credit debt forbids exit.
    function isDebtLocked(address agent) external view returns (bool);

    /// @notice True if agent is bonded, not exit-pending, not debt-locked, and not revoked.
    function isEligible(address wallet) external view returns (bool);

    /// @notice Volume factor for reputation scoring.
    function volumeFactor(address agent) external view returns (uint256);

    function minBond() external view returns (uint256);
    function unlockDelay() external view returns (uint64);

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event BondedIn(address indexed agent, bytes32 indexed agentId, address adapter, uint256 amount);
    event BondAdded(address indexed agent, uint256 newTotal);
    event ExitRequested(address indexed agent, uint64 unlockAt);
    event Exited(address indexed agent, uint256 returned);
    event Slashed(address indexed agent, uint256 amount, bytes32 indexed reasonHash);
    event OutcomeRecorded(
        uint256 indexed jobId, address indexed agent, Outcome outcome, uint256 volume, uint256 ewmaAfter
    );
}
