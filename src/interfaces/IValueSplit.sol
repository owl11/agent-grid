// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// @title IValueSplit
/// @notice Fee-split validation and distribution math for three-role settlement.
interface IValueSplit {
    /// @notice Per-role shares in basis points of the distributed total.
    struct Split {
        uint16 executorBps; // executing agent
        uint16 lpBps; // capital providers (paid via CapitalPool)
        uint16 treasuryBps; // protocol accumulator
    }

    // ---------------------------------------------------------------------
    // Constants (compiled once; pure getters surface the regime defaults)
    // ---------------------------------------------------------------------

    /// @notice Minimum distributable total: 0.1 USDC in atomic units (100_000).
    ///         Below this, passive-role floor-rounding can skew the payout.
    function MIN_TOTAL() external pure returns (uint256);

    // ---- Regime-coupled defaults (draws inert) ----------------------------
    function DEFAULTS_INACTIVE() external pure returns (Split memory);

    // ---- Regime-coupled defaults (draws active) ---------------------------
    function DEFAULTS_ACTIVE() external pure returns (Split memory);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    /// @notice Split does not sum to exactly 10_000 bps or violates a hard bound.
    error InvalidSplit();
    /// @notice `total` is below the minimum distributable amount (MIN_TOTAL).
    error AmountTooLow();

    // ---------------------------------------------------------------------
    // Validation
    // ---------------------------------------------------------------------

    /// @notice Revert unless the table sums to 10_000 bps and every role is in bounds.
    function validate(Split calldata split) external pure;

    // ---------------------------------------------------------------------
    // Distribution math
    // ---------------------------------------------------------------------

    /// @notice Compute per-role amounts for `total`. Executor receives the remainder.
    /// @return executor Amount to the executing agent (remainder-inclusive).
    /// @return lp Amount routed to the CapitalPool for capital providers.
    /// @return treasury Amount accrued to the protocol accumulator.
    function amounts(Split calldata split, uint256 total)
        external
        pure
        returns (uint256 executor, uint256 lp, uint256 treasury);
}
