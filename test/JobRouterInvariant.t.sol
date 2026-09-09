// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {JobRouter} from "../src/JobRouter.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {CapitalPool} from "../src/CapitalPool.sol";
import {IJobRouter} from "../src/interfaces/IJobRouter.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {JobHandler} from "./mocks/JobHandler.sol";

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 25
/// forge-config: default.invariant.fail-on-revert = true

/// Stateful fuzz over random JobRouter lifecycles. Handler drives bond→create→accept→submit→approve/timeout/cancel/expire
/// with random payments, splits, deadlines, and a warping clock.
contract JobRouterInvariantTest is Test {
    JobHandler internal handler;
    JobRouter internal router;
    AgentRegistry internal registry;
    CapitalPool internal pool;
    MockUSDC internal usdc;
    address internal treasury;

    function setUp() external {
        handler = new JobHandler();
        router = handler.router();
        registry = handler.registry();
        pool = handler.pool();
        usdc = handler.usdc();
        treasury = handler.treasury();
        targetContract(address(handler));
    }

    /// I7: router USDC == sum of open job escrows (no over/under-escrow).
    function invariant_routerHoldsExactlyOpenEscrow() public view {
        assertEq(usdc.balanceOf(address(router)), handler.ghostOpenEscrow(), "I7: escrow drift");
    }

    /// I7 global: all minted USDC accounted for across actors, pool, treasury, registry, and router.
    function invariant_globalConservation() public view {
        uint256 held = usdc.balanceOf(address(pool)) + usdc.balanceOf(treasury) + usdc.balanceOf(address(registry))
            + usdc.balanceOf(address(router));
        for (uint256 i; i < handler.actorCount(); ++i) {
            held += usdc.balanceOf(handler.actorAt(i));
        }
        assertEq(held, handler.ghostMinted(), "I7: USDC leaked or created (or ghost mint drift)");
    }

    /// LP revenue: the pool's balance is exactly the accumulated lp slices —
    /// nothing else may move pool funds in this fuzz.
    function invariant_poolHoldsExactlyLpRevenue() public view {
        assertEq(usdc.balanceOf(address(pool)), handler.ghostPoolRevenue(), "pool revenue drift");
    }

    /// Treasury: exactly the cancel/expire fees plus the settle treasury slices.
    function invariant_treasuryHoldsExactlyProtocolCuts() public view {
        assertEq(usdc.balanceOf(treasury), handler.ghostTreasury(), "treasury drift");
    }

    /// Registry: exactly the bonds currently posted (no slash, no exit in v1 fuzz).
    function invariant_registryHoldsExactlyBonds() public view {
        assertEq(usdc.balanceOf(address(registry)), handler.ghostBondsHeld(), "bond drift");
    }

    /// v1: draw stub always reverts; drawnForJob must stay 0.
    function invariant_noDrawEverSucceeded() public view {
        for (uint256 i; i < handler.jobCount(); ++i) {
            IJobRouter.Job memory j = router.jobs(handler.jobIdAt(i));
            assertEq(j.drawnForJob, 0, "v1: drawnForJob must stay 0 (draw stub always reverts)");
        }
    }

    /// Handler ghost state must match on-chain state.
    function invariant_handlerMirrorMatchesChain() public view {
        for (uint256 i; i < handler.jobCount(); ++i) {
            IJobRouter.Job memory j = router.jobs(handler.jobIdAt(i));
            assertEq(uint8(handler.jobStateAt(i)), uint8(j.state), "handler state mirror drifted from chain");
        }
        assertEq(router.jobCount(), handler.ghostCreates(), "job count drift");
    }
}
