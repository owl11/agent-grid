// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ValueSplit, InvalidSplit, AmountTooLow} from "../src/libraries/ValueSplit.sol";

/// @dev Thin external shim so `validate` reverts at a *nested* call depth.
///      Library `internal` functions are inlined into the caller, so an inline
///      revert stays at cheatcode depth 0 and `vm.expectRevert` can't catch it.
contract ValueSplitHost {
    using ValueSplit for ValueSplit.Split;

    function validate(ValueSplit.Split memory split) external pure {
        split.validate();
    }

    function amounts(ValueSplit.Split memory split, uint256 total) external pure returns (uint256, uint256, uint256) {
        return split.amounts(total);
    }
}

contract ValueSplitTest is Test {
    using ValueSplit for ValueSplit.Split;

    ValueSplitHost internal host;

    function setUp() public {
        host = new ValueSplitHost();
    }

    function test_defaultSplitValidates() public pure {
        ValueSplit.Split memory s = ValueSplit.defaultsactive();
        s.validate();
    }

    function test_default_INACTIVE_SplitValidates() public pure {
        ValueSplit.Split memory s = ValueSplit.defaultsInactive();
        s.validate();
    }

    // sum 9999 (< 10_000); every field in-bounds, so this isolates the sum check
    function test_sumTooLowReverts() public {
        ValueSplit.Split memory s = ValueSplit.Split({
            executorBps: ValueSplit.DEFAULT_EXECUTOR - 1, // 8499 ∈ [7000,9500]
            lpBps: ValueSplit.DEFAULT_LP, // 1000 ∈ [300,1500]
            treasuryBps: ValueSplit.DEFAULT_TREASURY // 500 ∈ [100,500]
        }); // 8499+1000+500 = 9999 ✗ only the sum is violated
        vm.expectRevert(InvalidSplit.selector);
        host.validate(s); // external call → inner revert at lower depth
    }

    // sum 10001 (> 10_000); same fields, isolates the sum check
    function test_sumTooHighReverts() public {
        ValueSplit.Split memory s = ValueSplit.Split({
            executorBps: ValueSplit.DEFAULT_EXECUTOR + 1, // 8501 ∈ [7000,9500]
            lpBps: ValueSplit.DEFAULT_LP,
            treasuryBps: ValueSplit.DEFAULT_TREASURY
        }); // 8501+1000+500 = 10001 ✗ only the sum is violated
        vm.expectRevert(InvalidSplit.selector);
        host.validate(s); // external call → inner revert at lower depth
    }

    // sum is valid (10_000); executor 9600 > MAX_EXECUTOR 9500 → must revert
    function test_boundViolation_ExecutorTooHigh() public {
        ValueSplit.Split memory s = ValueSplit.Split({
            executorBps: 9_600, // above MAX_EXECUTOR
            lpBps: 300, // MIN_LP
            treasuryBps: 100 // MIN_TREASURY
        }); // 9600+300+100 = 10_000 ✓ valid sum, bad bound
        vm.expectRevert(InvalidSplit.selector);
        host.validate(s);
    }

    function test_Amounts_BelowFloor_Reverts() public {
        ValueSplit.Split memory s = ValueSplit.defaultsactive();
        // 0 and just-below the 0.1 USDC floor (100_000 atomic) both revert.
        vm.expectRevert(AmountTooLow.selector);
        host.amounts(s, 0);
        vm.expectRevert(AmountTooLow.selector);
        host.amounts(s, ValueSplit.MIN_TOTAL - 1);
    }

    function test_Amounts_AtFloor_Passes() public view {
        ValueSplit.Split memory s = ValueSplit.defaultsactive();
        (uint256 exec, uint256 lp, uint256 treas) = host.amounts(s, ValueSplit.MIN_TOTAL);
        // exact total, so passive roles split cleanly and I4 holds
        assertEq(exec + lp + treas, ValueSplit.MIN_TOTAL);
    }

    // sum is valid (10_000); lp 299 < MIN_LP 300 → must revert on the LP bound
    function test_boundViolation_LpTooLow() public {
        ValueSplit.Split memory s = ValueSplit.Split({
            executorBps: 9_400, // ∈ [7000,9500]
            lpBps: 299, // < MIN_LP 300
            treasuryBps: 301 // ∈ [100,500]
        }); // 9400+299+301 = 10_000 ✓ valid sum, bad LP bound
        vm.expectRevert(InvalidSplit.selector);
        host.validate(s);
    }

    // sum is valid (10_000); lp 1501 > MAX_LP 1500 → must revert on the LP bound
    function test_boundViolation_LpTooHigh() public {
        ValueSplit.Split memory s = ValueSplit.Split({
            executorBps: 8_000, // ∈ [7000,9500]
            lpBps: 1_501, // > MAX_LP 1500
            treasuryBps: 499 // ∈ [100,500]
        }); // 8000+1501+499 = 10_000 ✓ valid sum, bad LP bound
        vm.expectRevert(InvalidSplit.selector);
        host.validate(s);
    }

    // sum is valid (10_000); treasury 99 < MIN_TREASURY 100 → must revert on the treasury bound
    function test_boundViolation_TreasuryTooLow() public {
        ValueSplit.Split memory s = ValueSplit.Split({
            executorBps: 9_300, // ∈ [7000,9500]
            lpBps: 601, // ∈ [300,1500]
            treasuryBps: 99 // < MIN_TREASURY 100
        }); // 9300+601+99 = 10_000 ✓ valid sum, bad treasury bound
        vm.expectRevert(InvalidSplit.selector);
        host.validate(s);
    }

    // sum is valid (10_000); treasury 501 > MAX_TREASURY 500 → must revert on the treasury bound
    function test_boundViolation_TreasuryTooHigh() public {
        ValueSplit.Split memory s = ValueSplit.Split({
            executorBps: 8_500, // ∈ [7000,9500]
            lpBps: 999, // ∈ [300,1500]
            treasuryBps: 501 // > MAX_TREASURY 500
        }); // 8500+999+501 = 10_000 ✓ valid sum, bad treasury bound
        vm.expectRevert(InvalidSplit.selector);
        host.validate(s);
    }
}
