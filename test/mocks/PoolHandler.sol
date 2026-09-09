// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import "../../src/CapitalPool.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

/// Fuzz handler for CapitalPoolInvariantTest. Deliberately NOT a Test subclass
/// (mocks/ precedent) so forge never collects it as a suite. The handler IS the
/// router, creditLine and emergencyOps (it deploys the pool), so every privileged
/// path is exercisable while the pool stays live between calls.
contract PoolHandler is CommonBase, StdUtils {
    MockUSDC public usdc;
    CapitalPool public pool;

    uint256 internal constant N_ACTORS = 20; // funded LPs (kept small: invariants loop over them)
    address[] public actors;

    // ghost telemetry — readable on failure traces
    uint256 public ghostDeposits;
    uint256 public ghostRedeems;
    uint256 public ghostRevenue;
    mapping(address => uint256) public ghostDeposited;
    mapping(address => uint256) public ghostRedeemed;

    constructor() {
        usdc = new MockUSDC();
        pool = new CapitalPool(IERC20(address(usdc)), address(this), address(this));
        usdc.mint(address(this), 10_000_000e6); // donation fuel

        for (uint256 i; i < N_ACTORS; ++i) {
            address lp = vm.addr(uint256(keccak256(abi.encode("pool-handler/lp", i))));
            actors.push(lp);
            usdc.mint(lp, 1_000e6);
            vm.prank(lp);
            usdc.approve(address(pool), type(uint256).max);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function deposit(uint256 lpIdx, uint256 amount) external {
        address lp = actors[bound(lpIdx, 0, actors.length - 1)];
        amount = bound(amount, 1e6, 5e6); // 1–5 USDC tiny positions
        vm.prank(lp);
        pool.deposit(amount);
        ghostDeposits += 1;
        ghostDeposited[lp] += amount;
    }

    function withdraw(uint256 lpIdx, uint256 shares) external {
        address lp = actors[bound(lpIdx, 0, actors.length - 1)];
        shares = bound(shares, 0, pool.maxRedeem(lp)); // entry-only pause: exit always live
        if (shares == 0) return;
        vm.prank(lp);
        uint256 out = pool.withdraw(shares);
        ghostRedeems += 1;
        ghostRedeemed[lp] += out;
    }

    function donateRevenue(uint256 amount) external {
        amount = bound(amount, 1e6, 100e6);
        usdc.transfer(address(pool), amount); // funds land FIRST — router trust boundary
        pool.receiveRevenue(amount); // router == handler
        ghostRevenue += amount;
    }

    function pauseUnpause() external {
        pool.pause(); // emergencyOps == handler
        pool.unpause(); // same call: entry is never wedged mid-sequence
    }
}
