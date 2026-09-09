// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import "../src/CapitalPool.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {PoolHandler} from "./mocks/PoolHandler.sol";

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 25
/// forge-config: default.invariant.fail-on-revert = true

/// Stateful fuzz over deposit/withdraw/revenue/pause orderings with 20 LPs.
contract CapitalPoolInvariantTest is Test {
    PoolHandler internal handler;
    CapitalPool internal pool;
    MockUSDC internal usdc;

    function setUp() external {
        handler = new PoolHandler();
        pool = handler.pool();
        usdc = handler.usdc();
        targetContract(address(handler));
    }

    /// P9 aggregate: the whole supply can never claim more than the real balance.
    function invariant_SolvencySum() public view {
        assertLe(
            pool.totalSupply() * pool.pricePerShare() / 1e18,
            usdc.balanceOf(address(pool)),
            "supply claims exceed real balance"
        );
    }

    /// P9 strong form: per-LP floor claims also sum below the real balance.
    function invariant_PerActorClaimsSum() public view {
        uint256 pps = pool.pricePerShare();
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += pool.balanceOf(handler.actors(i)) * pps / 1e18;
        }
        assertLe(sum, usdc.balanceOf(address(pool)), "per-LP claims exceed real balance");
    }

    /// G1a: totalAssets == balance + outstandingPrincipal; principal stays 0 in v1.
    function invariant_TotalAssetsReconciles() public view {
        assertEq(
            pool.totalAssets(),
            usdc.balanceOf(address(pool)) + pool.outstandingPrincipal(),
            "totalAssets drifted from live reads"
        );
        assertEq(pool.outstandingPrincipal(), 0, "v1: lending gated off, principal must be 0");
    }

    /// Receipt-token reconciliation: no share exists outside the funded actor set.
    function invariant_SupplyReconciles() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += pool.balanceOf(handler.actors(i));
        }
        assertEq(sum, pool.totalSupply(), "stray shares exist outside the actor set");
    }
}
