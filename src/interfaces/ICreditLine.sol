// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// @title ICreditLine
/// @notice Working capital for bonded agents, drawn against the CapitalPool.
interface ICreditLine {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NotEligible();
    /// @notice Draw exceeds utilization-scaled limit.
    error ExceedsLimit();
    /// @notice Agent has outstanding bad debt; no new draws.
    error DebtLocked();
    error NotRouter();
    /// @notice `draw()` called while the credit-line lending gate is OFF.
    error LendingDisabled();
    error NothingOwed();

    // ---------------------------------------------------------------------
    // Drawing (per-agent; job-tagging lives in the router)
    // ---------------------------------------------------------------------

    /// @notice Draw working capital against the agent's bond-based credit limit.
    /// @param agentId Bonded agent drawing; validated against its own utilization
    ///                 cap before any USDC leaves the pool.
    /// @param amount USDC to borrow; reverts via {ExceedsLimit}.
    function draw(bytes32 agentId, uint256 amount) external;

    /// @notice Repay outstanding principal directly.
    /// @param agentId Agent whose principal is being repaid.
    /// @param amount USDC to apply to principal.
    function repay(bytes32 agentId, uint256 amount) external;

    /// @notice Apply slash coverage to a defaulted agent's principal.
    function applySlashCoverage(bytes32 agentId, uint256 coverage) external;

    function shortfallOf(bytes32 agentId) external view returns (uint256);

    // ---------------------------------------------------------------------
    // Reading
    // ---------------------------------------------------------------------

    /// @notice Max total principal for this agent.
    function limitOf(address agent) external view returns (uint256);
    /// @notice Utilization-scaled spendable headroom.
    function availableOf(address agent) external view returns (uint256);
    /// @notice Outstanding principal owed by the agent (principal-only).
    function debtOf(address agent) external view returns (uint256 principal);
    /// @notice Credit-line half of the dual gate. Defaults OFF in v1.
    function lendingEnabled() external view returns (bool);
    function absoluteCap() external view returns (uint256);

    // ---------------------------------------------------------------------
    // Parameters (timelocked owner)
    // ---------------------------------------------------------------------

    /// @notice Flip the credit-line lending gate. Timelocked.
    function setLendingEnabled(bool enabled) external;

    /// @notice Absolute per-agent principal ceiling. Raisable only to >= 2x current.
    function setAbsoluteCap(uint256 cap) external;

    function setRouter(address router_) external;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event Drawn(bytes32 indexed agentId, uint256 principal);
    event Repaid(bytes32 indexed agentId, uint256 principal, uint256 remainingPrincipal);
    event Slashed(bytes32 indexed agentId, uint256 coveredBySlash, uint256 remainingDebt);
}
