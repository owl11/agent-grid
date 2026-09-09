// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ICapitalPool} from "../src/interfaces/ICapitalPool.sol";
import "../src/CapitalPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

/// Populated-state property tests: 50 LPs with $10–$50 balances, 2–5 deposits each, mid-life revenue.
contract CapitalPoolSeededTest is Test {
    CapitalPool internal pool;
    MockUSDC internal usdc;

    uint256 internal constant N_ACTORS = 50; // LPs
    uint256 internal constant WALLET = 100e6; // seed funding per LP
    uint256 internal constant MIN_TOTAL = 10e6; // per-LP TOTAL floor ($10)
    uint256 internal constant MAX_TOTAL = 50e6; // per-LP TOTAL cap ($50)
    uint256 internal constant MIN_SLICE = 1e6; // every position >= 1 USDC

    address[] internal actors;
    uint256[] internal depositedOf; // per-LP USDC deposited (atomic)

    uint256 internal _rngState = 0xC0FFEE20260904; // fixed seed => reproducible failures

    function setUp() external {
        usdc = new MockUSDC();
        // router + creditLine == this test contract (receiveRevenue caller)
        pool = new CapitalPool(IERC20(address(usdc)), address(this), address(this));
        usdc.mint(address(this), 1_000_000e6); // revenue fuel
        _seedPool();
    }

    // --- Seeding ---

    function _rnd(uint256 modulus) internal returns (uint256 r) {
        _rngState = uint256(keccak256(abi.encodePacked(_rngState)));
        r = modulus == 0 ? 0 : _rngState % modulus;
    }

    function _seedPool() internal {
        for (uint256 i; i < N_ACTORS; ++i) {
            address lp = vm.addr(uint256(keccak256(abi.encode("capital-pool-seeded/lp", i))));
            vm.label(lp, string.concat("lp-", vm.toString(i)));
            actors.push(lp);
            depositedOf.push(0);
            usdc.mint(lp, WALLET);
            vm.prank(lp);
            usdc.approve(address(pool), type(uint256).max);

            uint256 target = MIN_TOTAL + _rnd(MAX_TOTAL - MIN_TOTAL + 1); // $10–$50 total
            uint256 slices = 2 + _rnd(4); // 2–5 tiny positions
            for (uint256 j; j < slices; ++j) {
                uint256 left = slices - j; // remaining slices incl. this one
                uint256 room = target - depositedOf[i] - (left - 1) * MIN_SLICE;
                uint256 slice = j == slices - 1 ? room : MIN_SLICE + _rnd(room - MIN_SLICE + 1);
                vm.prank(lp);
                pool.deposit(slice);
                depositedOf[i] += slice;
            }

            if (i == 15 || i == 35) _landRevenue(10e6 + _rnd(91e6)); // mid-life revenue
        }
        _landRevenue(25e6); // and once, fully seeded
    }

    function _landRevenue(uint256 amount) internal {
        usdc.transfer(address(pool), amount); // funds land FIRST (router trust boundary)
        pool.receiveRevenue(amount); // router == this contract
    }

    function _claims() internal view returns (uint256[] memory c, uint256 sum) {
        // True per-LP claim == previewRedeem(balanceOf): floor(b*(A+1)/(S+offset)).
        // Computed from live reads directly — NOT via the pps view, which
        // double-floors and can shift per-LP claims by tens of atomic units.
        uint256 num = pool.totalAssets() + 1; // totalAssets() + 1 (derived: balance + principal)
        uint256 den = pool.totalSupply() + 1e12; // totalSupply() + 10**_decimalsOffset()
        c = new uint256[](N_ACTORS);
        for (uint256 i; i < N_ACTORS; ++i) {
            c[i] = pool.balanceOf(actors[i]) * num / den;
            sum += c[i];
        }
    }

    // ------------------------------------------------------------------
    // Properties against the populated pool
    // ------------------------------------------------------------------

    /// P7: revenue mints nothing, raises pps, no LP loses, aggregate claims absorb ~all revenue.
    function test_Seeded_proRataRevenue() external {
        (uint256[] memory claimsBefore, uint256 sumBefore) = _claims();
        uint256 supplyBefore = pool.totalSupply();
        uint256 ppsBefore = pool.pricePerShare();

        uint256 r = 40e6;
        usdc.transfer(address(pool), r); // funds land FIRST
        // pps read at emit time == convertToAssets(1e18) with the new balance
        uint256 priceAfter = (1e18 * (usdc.balanceOf(address(pool)) + 1)) / (pool.totalSupply() + 1e12);
        vm.expectEmit(false, false, false, true, address(pool));
        emit ICapitalPool.RevenueReceived(r, priceAfter);
        pool.receiveRevenue(r); // router == this contract

        assertEq(pool.totalSupply(), supplyBefore, "P7: revenue mints nothing");
        assertGt(pool.pricePerShare(), ppsBefore, "P7: revenue strictly raises pps");

        (uint256[] memory claimsAfter, uint256 sumAfter) = _claims();
        uint256 gained = sumAfter - sumBefore;
        // +N_ACTORS: each per-LP floor can sit on a boundary (+1 atomic of luck)
        assertLe(gained, r + N_ACTORS, "claims grow by at most revenue + per-LP floor luck");
        assertLe(r - gained, N_ACTORS + 10, "pro-rata: aggregate claims absorb ~all revenue");
        for (uint256 i; i < N_ACTORS; ++i) {
            assertGe(claimsAfter[i], claimsBefore[i], "no LP ever loses from revenue");
        }
        assertLe(sumAfter, usdc.balanceOf(address(pool)), "P9: claims <= real balance");
    }

    /// P5/P9: partial redeems pay exactly previewRedeem, are atomic, and conserve pool balance.
    function test_Seeded_partialRedeems() external {
        uint256 poolBal0 = usdc.balanceOf(address(pool));
        uint256 paidOut;

        for (uint256 i; i < N_ACTORS; ++i) {
            address lp = actors[i];
            uint256 half = pool.balanceOf(lp) / 2;
            uint256 wallet0 = usdc.balanceOf(lp);

            vm.prank(lp);
            uint256 out = pool.withdraw(half);

            assertEq(out, pool.previewRedeem(half), "P5: payout == previewRedeem, exact");
            // Integer form of payout <= floor(shares*pps), avoiding pps double-floor.
            assertLe(
                out * (pool.totalSupply() + 1e12),
                half * (usdc.balanceOf(address(pool)) + out + 1),
                "P9: payout never overprices the pool"
            );
            assertEq(usdc.balanceOf(lp), wallet0 + out, "withdraw is atomic to the wallet");
            paidOut += out;
        }

        assertEq(paidOut + usdc.balanceOf(address(pool)), poolBal0, "conservation: paid + remaining == pool before");
    }

    /// P1: deposit→full-redeem round-trips within dust on a populated pool.
    function test_Seeded_roundTripPerUser() external {
        for (uint256 i; i < N_ACTORS; ++i) {
            address lp = actors[i];
            uint256 x = 3e6 + _rnd(6e6); // 3–8 USDC fresh on top
            usdc.mint(lp, x);
            uint256 sharesHeld = pool.balanceOf(lp);
            uint256 wallet0 = usdc.balanceOf(lp);

            vm.startPrank(lp);
            uint256 sh = pool.deposit(x);
            uint256 back = pool.withdraw(sh);
            vm.stopPrank();

            assertGt(sh, 0, "P6: populated pool never zero-mints");
            assertEq(pool.balanceOf(lp), sharesHeld, "only the fresh slice moved");
            assertEq(usdc.balanceOf(lp), wallet0 - x + back, "wallet delta == back - x");
            assertApproxEqAbs(back, x, 2, "P1: round-trip vs populated pool (double-floor dust only)");
        }
    }

    /// P5: full wind-down — every LP exits >= deposited, supply → 0, pool drains to dust.
    function test_Seeded_fullWindDown() external {
        uint256 poolBal0 = usdc.balanceOf(address(pool));
        uint256 paidOut;

        for (uint256 i; i < N_ACTORS; ++i) {
            address lp = actors[i];
            uint256 wallet0 = usdc.balanceOf(lp);

            // Read BEFORE vm.prank: an external call in withdraw's argument
            // position would consume the prank and execute as this test contract.
            uint256 maxSh = pool.maxRedeem(lp);
            assertEq(maxSh, pool.balanceOf(lp), "idle pool: liquidity cap == full balance");
            vm.prank(lp);
            uint256 out = pool.withdraw(maxSh);

            assertEq(pool.balanceOf(lp), 0, "full redeem zeroes the LP");
            assertGe(out, depositedOf[i], "revenue only ever added: exit >= deposits");
            assertEq(usdc.balanceOf(lp), wallet0 + out, "wallet delta == payout");
            paidOut += out;
        }

        assertEq(paidOut + usdc.balanceOf(address(pool)), poolBal0, "conservation");
        assertEq(pool.totalSupply(), 0, "supply returns to zero");
        assertLe(usdc.balanceOf(address(pool)), N_ACTORS + 10, "drained to ghost dust only");
    }
}
