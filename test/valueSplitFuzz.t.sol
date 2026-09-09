// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ValueSplit} from "../src/libraries/ValueSplit.sol";

contract ValueSplitTest is Test {
    using ValueSplit for ValueSplit.Split; // internal fns become callable on Split

    function testFuzz_Amounts_SumEqualsTotal(uint256 l, uint256 t, uint256 total) public pure {
        // exclude sub-floor totals (amounts reverts AmountTooLow below MIN_TOTAL)
        vm.assume(total >= ValueSplit.MIN_TOTAL);

        // build a valid Split (bound, then force executor = remainder of 10_000)
        l = bound(l, ValueSplit.MIN_LP, ValueSplit.MAX_LP);
        t = bound(t, ValueSplit.MIN_TREASURY, ValueSplit.MAX_TREASURY);
        // casts are safe: bound() keeps l,o,t <= 1500 < 65536, and e derives
        // from 10_000 minus in-range values, so none can truncate.
        // forge-lint: disable-start(unsafe-typecast)
        uint16 e = uint16(10_000) - uint16(l) - uint16(t);
        vm.assume(e >= ValueSplit.MIN_EXECUTOR && e <= ValueSplit.MAX_EXECUTOR);

        ValueSplit.Split memory s = ValueSplit.Split({executorBps: e, lpBps: uint16(l), treasuryBps: uint16(t)});
        // forge-lint: disable-end(unsafe-typecast)

        s.validate(); // inlined internal call
        (uint256 exec, uint256 lpAmt, uint256 treas) = s.amounts(total);

        assertEq(exec + lpAmt + treas, total); // I4: no dust
    }

    /// Executor absorbs floor-rounding dust; sum == total.
    function testFuzz_Executor_IsRemainder(uint256 l, uint256 t, uint256 total) public pure {
        // same valid-Split construction as testFuzz_Amounts_SumEqualsTotal
        vm.assume(total >= ValueSplit.MIN_TOTAL);
        l = bound(l, ValueSplit.MIN_LP, ValueSplit.MAX_LP);
        t = bound(t, ValueSplit.MIN_TREASURY, ValueSplit.MAX_TREASURY);
        // forge-lint: disable-start(unsafe-typecast)
        uint16 e = uint16(10_000) - uint16(l) - uint16(t);
        vm.assume(e >= ValueSplit.MIN_EXECUTOR && e <= ValueSplit.MAX_EXECUTOR);
        ValueSplit.Split memory s = ValueSplit.Split({executorBps: e, lpBps: uint16(l), treasuryBps: uint16(t)});
        // forge-lint: disable-end(unsafe-typecast)

        s.validate();
        (uint256 exec, uint256 lpAmt, uint256 treas) = s.amounts(total);

        assertEq(exec, total - lpAmt - treas);
    }

    function _split(uint16 e, uint16 l, uint16 t) internal pure returns (ValueSplit.Split memory s) {
        s = ValueSplit.Split({executorBps: e, lpBps: l, treasuryBps: t});
    }

    function testFuzz_Monotonicity_bps(uint256 total, uint256 lp) public pure {
        total = bound(total, ValueSplit.MIN_TOTAL, 1_000_000); // atomic units, above 0.1 USDC floor

        lp = bound(lp, ValueSplit.MIN_LP, ValueSplit.MAX_LP - 1);

        // from 10_000 minus in-range values, so none can truncate.
        // forge-lint: disable-start(unsafe-typecast)
        uint16 e = uint16(10_000) - uint16(lp) - uint16(ValueSplit.DEFAULT_TREASURY);
        vm.assume(e >= ValueSplit.MIN_EXECUTOR && e <= ValueSplit.MAX_EXECUTOR);

        ValueSplit.Split memory before_ = _split(e, uint16(lp), ValueSplit.DEFAULT_TREASURY);
        ValueSplit.Split memory after_ = _split(uint16(e - 1), uint16(lp + 1), ValueSplit.DEFAULT_TREASURY);
        // forge-lint: disable-end(unsafe-typecast)

        before_.validate();
        after_.validate();

        (, uint256 lpBefore,) = before_.amounts(total);
        (, uint256 lpAfter,) = after_.amounts(total);

        assertGe(lpAfter, lpBefore); // bumped  → payout not decreased
    }
}
