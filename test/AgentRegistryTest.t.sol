// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {IAgentIdentity} from "../src/interfaces/IAgentIdentity.sol";
import {IAgentRegistry} from "../src/interfaces/IAgentRegistry.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockERC8004} from "./mocks/MockERC8004.sol";
import {ERC8004Adapter} from "../src/ERC8004Adapter.sol";

contract AgentRegistryTest is Test {
    MockUSDC internal usdc;
    AgentRegistry internal registry;
    address public user = address(1234);

    uint256 constant MIN_BOND = 100e6;
    uint64 constant DELAY = 7 days;
    address internal router = makeAddr("router");
    address internal pool = makeAddr("pool"); // R6: slash destination (assert target)

    function setUp() public {
        usdc = new MockUSDC();
        registry = new AgentRegistry(address(usdc), MIN_BOND, DELAY, router, pool, user);
        usdc.mint(address(this), 10_000e6);
        usdc.approve(address(registry), type(uint256).max);
    }

    function test_bondIn_BareMode_MintsMinBond() public {
        vm.startPrank(user);
        usdc.mint(user, MIN_BOND);
        usdc.approve(address(registry), MIN_BOND);

        registry.bondIn(IAgentIdentity(address(0)), 0, MIN_BOND);
        vm.stopPrank();

        assertEq(registry.bondOf(address(user)), MIN_BOND);
        assertEq(usdc.balanceOf(address(registry)), MIN_BOND);
        assertEq(registry.agentIdOf(address(user)), bytes32(uint256(uint160(address(user)))));
    }

    function test_bondIn_Twice_Reverts() public {
        vm.startPrank(user);
        usdc.mint(user, MIN_BOND);
        usdc.approve(address(registry), MIN_BOND);

        registry.bondIn(IAgentIdentity(address(0)), 0, MIN_BOND);
        vm.stopPrank();
        vm.expectRevert(IAgentRegistry.AlreadyBonded.selector);
        vm.startPrank(user);
        registry.bondIn(IAgentIdentity(address(0)), 0, MIN_BOND);
        vm.stopPrank();
    }

    function test_bondIn_UnverifiedExternalId_Reverts() public _bondedAgent {
        vm.startPrank(user);
        usdc.mint(user, MIN_BOND);
        usdc.approve(address(registry), MIN_BOND);
        vm.stopPrank();

        MockERC8004 source = new MockERC8004();
        ERC8004Adapter adapter = new ERC8004Adapter(address(source));
        vm.expectRevert(IAgentRegistry.UnverifiedIdentity.selector);

        vm.startPrank(user);
        registry.bondIn(IAgentIdentity(address(adapter)), 1, MIN_BOND);
        vm.stopPrank();
    }

    function test_requestExit_SetsUnlockAt() public {
        vm.startPrank(user);
        usdc.mint(user, MIN_BOND);
        usdc.approve(address(registry), MIN_BOND);

        registry.bondIn(IAgentIdentity(address(0)), 0, MIN_BOND);
        registry.requestExit();
        assertEq(registry.unlockAt(user), block.timestamp + DELAY);
        vm.stopPrank();
    }

    function test_completeExit_Early_Reverts() public {
        vm.startPrank(user);
        usdc.mint(user, MIN_BOND);
        usdc.approve(address(registry), MIN_BOND);

        registry.bondIn(IAgentIdentity(address(0)), 0, MIN_BOND);
        registry.requestExit();
        vm.expectRevert(IAgentRegistry.UnlockPending.selector);
        registry.completeExit();
        vm.stopPrank();
    }

    function test_slash_RouterOnly() public _bondedAgent {
        address adversary = makeAddr("villain");
        vm.expectRevert(IAgentRegistry.UnauthorizedCaller.selector);
        vm.prank(adversary);
        // casting to 'bytes32' is safe: short string literals fit in 256 bits, no truncation
        // forge-lint: disable-next-line(unsafe-typecast)
        registry.slash(address(6969), MIN_BOND, bytes32("evidence"));
    }

    function test_slash_happy_path() public _bondedAgent {
        vm.prank(router);
        // casting to 'bytes32' is safe: short string literals fit in 256 bits, no truncation
        // forge-lint: disable-next-line(unsafe-typecast)
        registry.slash(address(6969), MIN_BOND / 2, bytes32("test"));
        assertEq(registry.bondOf(address(6969)), MIN_BOND / 2);
        assertEq(usdc.balanceOf(pool), MIN_BOND / 2, "R6: seizure lands in the pool");
    }

    function test_recordOutcome_EWMA_Streaming() public _bondedAgent {
        // After 1 SUCCESS: num=W, den=W → ewma=1.0
        vm.prank(router);
        registry.recordOutcome(address(6969), 1, IAgentRegistry.Outcome.SUCCESS, 100e6);
        vm.stopPrank();
        // vf = 100e6 * 1e18 / 100_000e6 = 1e15
        // score = 1e18 * 1e15 / 1e18 = 1e15
        assertEq(registry.repScore(address(6969)), 1e15);

        // After 1 EXPIRED: num=W*ALPHA, den=W*ALPHA+W → ewma = ALPHA/(ALPHA+1)
        vm.prank(router);
        registry.recordOutcome(address(6969), 2, IAgentRegistry.Outcome.FAILURE, 100e6);
        vm.stopPrank();
        // vf = 200e6 * 1e18 / 100_000e6 = 2e15
        // ewma = ALPHA/(ALPHA+BASE_WEIGHT) ≈ 0.492e18
        // score = ewma * vf / 1e18 ≈ 9.84e14
        assertEq(registry.repScore(address(6969)), 984771573604060);

        // Volume factor not zero but score is small
        assertGt(registry.repScore(address(6969)), 0);
    }

    function test_volumeFactor_Linear_And_Saturates() public {
        address half = makeAddr("agentHalf");
        address sat = makeAddr("agentSat");
        _bondAgent(half);
        _bondAgent(sat);

        vm.startPrank(router);
        for (uint256 i = 0; i < 5; i++) {
            registry.recordOutcome(half, i, IAgentRegistry.Outcome.SUCCESS, 10_000e6);
        }
        for (uint256 i = 0; i < 120; i++) {
            registry.recordOutcome(sat, i, IAgentRegistry.Outcome.SUCCESS, 10_000e6);
        }
        vm.stopPrank();

        assertEq(registry.volumeFactor(half), 5e17, "$50k of $100k cap = 0.5");
        assertEq(registry.volumeFactor(sat), 1e18, "volume at/above cap saturates to 1.0");
    }

    function test_tier_Thresholds() public {
        address a1 = makeAddr("tier3"); // clean record + volume → tier 3
        address a2 = makeAddr("tier2"); // 0.8 score + volume → tier 2
        address a3 = makeAddr("tier1"); // ~0.52 score + volume → tier 1
        address a4 = makeAddr("tier0"); // ~0.44 score + volume → tier 0

        _bondAgent(a1);
        _bondAgent(a2);
        _bondAgent(a3);
        _bondAgent(a4);

        // Each gets $80k volume → vf = 0.8
        for (uint256 i = 0; i < 8; i++) {
            vm.startPrank(router);
            registry.recordOutcome(a1, i, IAgentRegistry.Outcome.SUCCESS, 10_000e6);
            registry.recordOutcome(a2, i, IAgentRegistry.Outcome.SUCCESS, 10_000e6);
            registry.recordOutcome(a3, i, IAgentRegistry.Outcome.SUCCESS, 10_000e6);
            registry.recordOutcome(a4, i, IAgentRegistry.Outcome.SUCCESS, 10_000e6);
            vm.stopPrank();
        }

        // a1: add 8 more SUCCESS → 16 total, vf=1.0, ewma≈1.0 → tier 3
        vm.startPrank(router);
        for (uint256 i = 8; i < 16; i++) {
            registry.recordOutcome(a1, i, IAgentRegistry.Outcome.SUCCESS, 10_000e6);
        }
        vm.stopPrank();

        // a3: add 4 EXPIRED → 8S/4E, vf=1.0, ewma~0.52 → tier 1
        vm.startPrank(router);
        for (uint256 i = 8; i < 12; i++) {
            registry.recordOutcome(a3, i, IAgentRegistry.Outcome.FAILURE, 10_000e6);
        }
        vm.stopPrank();

        // a4: add 8 EXPIRED → 8S/8E, vf=1.0, ewma~0.44 → tier 0
        vm.startPrank(router);
        for (uint256 i = 8; i < 16; i++) {
            registry.recordOutcome(a4, i, IAgentRegistry.Outcome.FAILURE, 10_000e6);
        }
        vm.stopPrank();

        // a2: 8S/0E, vf=0.8, ewma=1.0 → score=0.8 → tier 2
        // a3: 8S/4E, vf=1.0, ewma~0.52 → tier 1
        // a4: 8S/8E, vf=1.0, ewma~0.44 → tier 0
        assertEq(registry.tier(a1), 3, "clean record + volume = tier 3");
        assertEq(registry.tier(a2), 2, "score 0.8 = tier 2");
        assertEq(registry.tier(a3), 1, "8S/4E ewma ~0.52e18 tier 1");
        assertEq(registry.tier(a4), 0, "8S/8E ewma ~0.44e18 tier 0");
    }

    function test_isEligible_TruthTable() public {
        address bonded = makeAddr("bonded");
        address pending = makeAddr("pending");
        address debtLocked = makeAddr("debtLocked");

        _bondAgent(bonded);
        _bondAgent(pending);
        _bondAgent(debtLocked);

        assertTrue(registry.isEligible(bonded));

        vm.startPrank(pending);
        registry.requestExit();
        vm.stopPrank();
        assertFalse(registry.isEligible(pending));

        vm.prank(router);
        registry.setDebtLock(debtLocked, true);
        assertFalse(registry.isEligible(debtLocked));
    }

    function _bondAgent(address who) internal {
        vm.startPrank(who);
        usdc.mint(who, MIN_BOND);
        usdc.approve(address(registry), MIN_BOND);
        registry.bondIn(IAgentIdentity(address(0)), 0, MIN_BOND);
        vm.stopPrank();
    }

    modifier _bondedAgent() {
        address addr_mock_user = address(6969);
        vm.startPrank(addr_mock_user);
        usdc.mint(addr_mock_user, MIN_BOND);
        usdc.approve(address(registry), MIN_BOND);
        registry.bondIn(IAgentIdentity(address(0)), 0, MIN_BOND);
        vm.stopPrank();
        _;
    }
}
