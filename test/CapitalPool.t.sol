// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, console, StdAssertions} from "forge-std/Test.sol";
import "../src/CapitalPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

contract CapitalPoolTest is Test {
    CapitalPool pool;
    MockUSDC internal usdc;
    address public user = vm.addr(1234);
    address public router;
    address public credLine;
    address public user_1 = vm.addr(12345);
    address public user_2 = vm.addr(54321);

    function setUp() external {
        usdc = new MockUSDC();
        pool = new CapitalPool(IERC20(address(usdc)), user, user);
        usdc.mint(user, 10_000e6);
        usdc.mint(user_1, 10_000e6);
        usdc.mint(user_2, 10_000e6);
    }

    function testDepositWithdrawInverse() external {
        uint256 amount = 1000e6; // 1,000 USDC (6 dp
        uint256 balance = usdc.balanceOf(user);
        vm.startPrank(user);
        usdc.approve(address(pool), amount);
        uint256 shares = pool.deposit(amount); // 1e21 shares (1:1e12 offset
        uint256 amountOut = pool.withdraw(shares); // redeem ALL shares, NOT “amount”
        vm.stopPrank();
        assertEq(amountOut, amount);
        assertEq(usdc.balanceOf(user), balance);
    }

    function testDepositMonotonePps() external {
        vm.startPrank(user_1);
        usdc.approve(address(pool), 1000e6);
        pool.deposit(1000e6);
        vm.stopPrank();
        uint256 pps1 = pool.pricePerShare();

        vm.startPrank(user_2);
        usdc.approve(address(pool), 2000e6);
        pool.deposit(2000e6);
        vm.stopPrank();
        assertGe(pool.pricePerShare(), pps1, "deposit never lowers pps");

        vm.startPrank(user);
        usdc.transfer(address(pool), 500e6); // revenue lands (router-funded)
        pool.receiveRevenue(500e6);
        vm.stopPrank();
        assertGe(pool.pricePerShare(), pps1, "revenue only raises pps");
    }

    function testWithdrawNeverExceedsBalance() external {
        uint256 depositAmount = 1000e6; // 1000 USDC (6 dp）
        uint256 balanceBefore = usdc.balanceOf(user);
        vm.startPrank(user);
        usdc.approve(address(pool), depositAmount);
        uint256 shares = pool.deposit(depositAmount);
        vm.stopPrank();

        uint256 maxShares = pool.maxRedeem(user); // min(balance, liquidity-backed shares)
        assertEq(maxShares, shares, "idle pool: liquidity cap == balance cap");

        vm.expectRevert(ICapitalPool.InsufficientShares.selector);
        pool.withdraw(maxShares + 1);

        // atomicity: nothing moved on the failed withdraw
        assertEq(usdc.balanceOf(user), balanceBefore - depositAmount, "no USDC left the pool");
        assertEq(pool.balanceOf(user), shares, "no shares burned");
    }

    function testFirstDepositNonZeroShare() external {
        uint256 depositAmount = 1 wei; // 1e-6 USDC — the smallest possible deposit
        vm.startPrank(user);
        usdc.approve(address(pool), depositAmount);
        uint256 shares = pool.deposit(depositAmount);
        vm.stopPrank();

        assertGt(shares, 0, "first deposit can never round to zero");
        assertEq(shares, 1e12, "1 wei maps to exactly 1e12 shares via the offset");
        assertEq(shares, pool.maxRedeem(user));
    }

    function testMegaDonationCannotFreezeFirst() external {
        uint256 depositAmount = 1000e6;
        // attacker donates BEFORE any LP: pool holds 10_000 USDC, supply == 0
        vm.startPrank(user);
        usdc.transfer(address(pool), 10_000e6);
        vm.stopPrank();

        // victim's FIRST deposit must not zero-round (the inflation attack)
        vm.startPrank(user_2);
        usdc.approve(address(pool), depositAmount);
        uint256 shares = pool.deposit(depositAmount); // 1e9·1e12/(1e10+1) ≈ 9.09e10
        assertGt(shares, 0, "donation cannot zero out the first deposit");

        uint256 back = pool.withdraw(shares);
        vm.stopPrank();
        assertApproxEqAbs(back, depositAmount, 10, "victim round-trips; donation soaked by ghost shares");
        assertGe(usdc.balanceOf(address(pool)), 10_000e6, "donation never leaves the pool");
    }

    /// P6: pin the exact donation bound where zero-rounding kicks in (v * 1e12).
    function testInflationAttackCostBound() external {
        uint256 v = 1e6; // victim deposits 1 USDC (atomic)
        uint256 bound = v * 1e12; // minimum donation able to zero-round the deposit

        // --- just below the bound: victim mints exactly 1 share, redeems exactly v ---
        CapitalPool fresh = new CapitalPool(IERC20(address(usdc)), address(this), address(this));
        usdc.mint(address(this), bound + v);
        usdc.transfer(address(fresh), bound - 1); // donation lands, NO shares minted
        assertEq(fresh.totalSupply(), 0, "donation mints nothing (P7)");
        usdc.approve(address(fresh), v);

        uint256 shares = fresh.deposit(v);
        assertEq(shares, 1, "at bound-1 the victim still mints exactly 1 share");
        assertEq(fresh.totalSupply(), 1, "victim's share is the whole real supply");

        uint256 back = fresh.withdraw(shares);
        assertEq(back, v, "worst non-zeroing donation still round-trips exactly");
        assertEq(fresh.totalSupply(), 0, "supply back to zero");
        assertEq(usdc.balanceOf(address(fresh)), bound - 1, "donation is locked, never leaves");

        // --- at the bound: deposit reverts ZeroShares BEFORE any USDC is pulled ---
        CapitalPool fresh2 = new CapitalPool(IERC20(address(usdc)), address(this), address(this));
        usdc.mint(address(this), bound);
        usdc.transfer(address(fresh2), bound); // exactly the zeroing donation

        uint256 victimBal = usdc.balanceOf(address(this));
        vm.expectRevert(ICapitalPool.ZeroShares.selector);
        fresh2.deposit(v);
        assertEq(usdc.balanceOf(address(this)), victimBal, "ZeroShares fires before transferFrom");
        assertEq(fresh2.balanceOf(address(this)), 0, "no shares minted on the reverted deposit");
    }

    function testRevenueNotsMint() external {
        vm.startPrank(user_2);
        usdc.approve(address(pool), 1000e6);
        uint256 shares = pool.deposit(1000e6);
        vm.stopPrank();

        uint256 supplyBefore = pool.totalSupply();
        uint256 ppsBefore = pool.pricePerShare();

        vm.prank(user); // router == user in setUp
        pool.receiveRevenue(100e6); // bell rings, NO USDC landed — router's trust boundary

        assertEq(pool.totalSupply(), supplyBefore, "revenue must NOT mint (P7)");
        assertEq(pool.sharesOf(user_2), shares, "LP shares untouched");
        assertEq(pool.pricePerShare(), ppsBefore, "no funds landed -> no fabricated pps (I8)");
    }

    function testPauseBlocksEntryOnly() external {
        vm.startPrank(user_2);
        usdc.approve(address(pool), 1000e6);
        uint256 shares = pool.deposit(1000e6);
        vm.stopPrank();

        pool.pause(); // emergencyOps == test contract (deployer)

        vm.prank(user);
        vm.expectRevert(ICapitalPool.Paused.selector);
        pool.deposit(100e6);

        vm.prank(user_2); // open-exit: existing LP can still leave
        assertGt(pool.withdraw(shares), 0, "exit stays open while paused");

        pool.unpause();
        vm.startPrank(user);
        usdc.approve(address(pool), 1000e6);
        pool.deposit(100e6); // entry re-enabled
    }

    function testPauseCheckBeforeTransfer() external {
        uint256 amount = 1000e6;
        vm.startPrank(user_2);
        usdc.approve(address(pool), amount);
        vm.stopPrank();

        pool.pause();

        uint256 balBefore = usdc.balanceOf(user_2);
        uint256 allowBefore = usdc.allowance(user_2, address(pool));

        vm.prank(user_2);
        vm.expectRevert(ICapitalPool.Paused.selector);
        pool.deposit(amount);

        assertEq(usdc.balanceOf(user_2), balBefore, "no USDC pulled while paused");
        assertEq(usdc.allowance(user_2, address(pool)), allowBefore, "allowance not consumed");
        assertEq(usdc.balanceOf(address(pool)), 0);
    }

    function testSolvencySum() external {
        uint256 s0 = _sumBalances(); // 30_000e6

        vm.startPrank(user_2);
        usdc.approve(address(pool), 1000e6);
        pool.deposit(1000e6);
        vm.stopPrank();
        assertEq(_sumBalances(), s0, "deposit conserves");

        vm.startPrank(user);
        usdc.transfer(address(pool), 100e6);
        pool.receiveRevenue(100e6);
        vm.stopPrank();
        assertEq(_sumBalances(), s0, "revenue conserves");

        vm.startPrank(user_2);
        pool.withdraw(pool.maxRedeem(user_2));
        assertEq(_sumBalances(), s0, "withdraw conserves");

        assertEq(pool.totalAssets(), usdc.balanceOf(address(pool)) + pool.outstandingPrincipal());
    }

    function testFullRedeemEqualsBalance() external {
        uint256 depositAmount = 1000e6;
        vm.startPrank(user_2);
        usdc.approve(address(pool), depositAmount);
        uint256 shares = pool.deposit(depositAmount);
        vm.stopPrank();

        vm.startPrank(user);
        usdc.transfer(address(pool), 100e6);
        pool.receiveRevenue(100e6);
        vm.stopPrank();
        vm.prank(user_2);
        uint256 amtBack = pool.withdraw(shares);

        assertGt(amtBack, depositAmount, "revenue flows to LP pro-rata");
        assertEq(pool.balanceOf(user_2), 0, "full redeem zeroes shares");
        assertEq(pool.totalSupply(), 0, "supply back to zero");
        assertApproxEqAbs(usdc.balanceOf(address(pool)), 0, 10, "pool drained (ghost-share dust only)");
    }

    function _sumBalances() internal view returns (uint256) {
        return usdc.balanceOf(user) + usdc.balanceOf(user_1) + usdc.balanceOf(user_2) + usdc.balanceOf(address(pool));
    }
    modifier usersDeposited() {
        uint256 depositAmount = 1000e6; // 1000 USDC (6 dp）
        vm.startPrank(user_1);
        usdc.approve(address(pool), depositAmount);
        uint256 shares = pool.deposit(depositAmount);
        vm.stopPrank();
        _;
    }
}
