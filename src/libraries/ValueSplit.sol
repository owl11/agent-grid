// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// @dev Standalone pure library.
library ValueSplit {
    //what's a split?
    struct Split {
        uint16 executorBps;
        uint16 lpBps;
        uint16 treasuryBps;
    }
    // --- unit & bounds (value-type constants — legal in a library) ---

    uint16 constant BPS = 10_000;

    // prevents the executor-ratio skew on sub-floor totals.

    uint256 constant MIN_TOTAL = 100_000;
    uint16 constant MIN_EXECUTOR = 7_000;

    uint16 constant MAX_EXECUTOR = 9_500;
    uint16 constant MIN_LP = 300;
    uint16 constant MAX_LP = 1_500;
    uint16 constant MIN_TREASURY = 100;
    uint16 constant MAX_TREASURY = 500;

    // --- default table (constants resolve the magic numbers) ---
    uint16 constant DEFAULT_EXECUTOR = 8_500;
    uint16 constant DEFAULT_LP = 1000;
    uint16 constant DEFAULT_TREASURY = 500;
    // --- default table (constants resolve the magic numbers) ---
    uint16 constant DEFAULT_EXECUTOR_INACTIVE = 9_000;
    uint16 constant DEFAULT_LP_INACTIVE = 500;
    uint16 constant DEFAULT_TREASURY_INACTIVE = 500;

    // struct can't be a constant (reference type), so DEFAULT is a pure getter
    // that assembles the table from the named constants above.
    function defaultsactive() internal pure returns (Split memory split) {
        split = Split({executorBps: DEFAULT_EXECUTOR, lpBps: DEFAULT_LP, treasuryBps: DEFAULT_TREASURY});
    }

    function defaultsInactive() internal pure returns (Split memory split) {
        split = Split({
            executorBps: DEFAULT_EXECUTOR_INACTIVE, lpBps: DEFAULT_LP_INACTIVE, treasuryBps: DEFAULT_TREASURY_INACTIVE
        });
    }

    function validate(Split memory split) internal pure {
        uint32 sum = uint32(split.executorBps) + uint32(split.lpBps) + uint32(split.treasuryBps);
        if (sum != BPS) revert InvalidSplit();
        if (split.executorBps < MIN_EXECUTOR || split.executorBps > MAX_EXECUTOR) revert InvalidSplit();
        if (split.lpBps < MIN_LP || split.lpBps > MAX_LP) revert InvalidSplit();
        if (split.treasuryBps < MIN_TREASURY || split.treasuryBps > MAX_TREASURY) revert InvalidSplit();
    }

    function _scale(uint256 total, uint256 bps) private pure returns (uint256 result) {
        // total * bps / BPS, computed overflow-free for arbitrary total:
        //   total * bps / BPS == (total / BPS) * bps + ((total % BPS) * bps) / BPS
        //   (total % BPS) * bps <= BPS * MAX_BPS (<= 1.5e7) and
        //   (total / BPS) * bps <= MAX_BPS * total / BPS, both < 2^256.
        // Deliberate divide-before-multiply: naive `total * bps` overflows 2^256
        // for large totals, so we trade precision to stay overflow-free.
        // forge-lint: disable-next-line(divide-before-multiply)
        result = (total / BPS) * bps + ((total % BPS) * bps) / BPS;
    }

    function amounts(Split memory split, uint256 total)
        internal
        pure
        returns (uint256 executor, uint256 lp, uint256 treasury)
    {
        // reject sub-floor totals (min 0.1 USDC in atomic units) — not just zero,
        // so the tiny-total executor skew on 6-decimal USDC is closed.
        if (total < MIN_TOTAL) revert AmountTooLow();
        lp = _scale(total, split.lpBps);
        treasury = _scale(total, split.treasuryBps);
        executor = total - lp - treasury; // remainder → no dust (I4)
    }
}
error InvalidSplit();
error AmountTooLow();

