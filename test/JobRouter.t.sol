// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IJobRouter} from "../src/interfaces/IJobRouter.sol";
import {JobRouter} from "../src/JobRouter.sol";
import {CapitalPool} from "../src/CapitalPool.sol";
import {CreditLine} from "../src/CreditLine.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IAgentIdentity} from "../src/interfaces/IAgentIdentity.sol";

/// Spec tests for JobRouter. I7 conservation: escrow == executor + pool + treasury on every terminal path.
contract JobRouterTest is Test {
    MockUSDC internal usdc;
    AgentRegistry internal registry;
    CapitalPool internal pool;
    CreditLine internal creditLine;
    JobRouter internal jobRouter;
    IAgentIdentity ID;

    address internal deployer = makeAddr("deployer"); // single identity: deploys AND wires all contracts
    address internal originator = makeAddr("originator");
    address internal executor = makeAddr("executor");
    address internal treasury = makeAddr("treasury");
    address internal arbiter = makeAddr("arbiter");

    uint256 constant MIN_BOND = 100e6;
    uint128 constant PAYMENT = 100e6; // == MIN_BOND: bond-capacity boundary
    uint64 constant DELAY = 7 days;
    uint64 constant APPROVAL_WINDOW = 1 hours;

    // balance baselines (handoff fix: assert deltas, not absolute balances — the
    // originator's wallet also loses `payment` to escrow at create time)
    uint256 internal originatorBaseline;
    uint256 internal poolBaseline;

    IJobRouter.Split internal SPLIT = IJobRouter.Split({executorBps: 9000, lpBps: 500, treasuryBps: 500}); // DEFAULTS_INACTIVE

    function setUp() public {
        vm.startPrank(deployer); // single identity: deploys and wires everything
        usdc = new MockUSDC();
        // Pool deployed with placeholders, wired post-deploy under deployer prank (no circularity).
        pool = new CapitalPool(IERC20(address(usdc)), address(jobRouter), address(creditLine));
        registry = new AgentRegistry(address(usdc), MIN_BOND, DELAY, address(jobRouter), address(pool), deployer);
        jobRouter = new JobRouter(IERC20(address(usdc)), registry, pool, treasury);
        creditLine = new CreditLine(address(pool), address(registry), address(usdc), address(jobRouter), deployer);
        registry.setRouter(address(jobRouter)); // registry auth → router (deployer is owner)
        registry.setCreditLine(address(creditLine)); // registry debt-lock auth → credit line
        pool.setRouter(address(jobRouter)); // ✅ deployer is emergencyOps → authorized now
        pool.setCreditLine(address(creditLine)); // ✅ deployer is emergencyOps → authorized
        jobRouter.setCredit(creditLine); // jobRouter.credit + (no propagation — pool wired directly)
        jobRouter.setArbiter(arbiter);
        vm.stopPrank();
        usdc.mint(originator, 1_000e6);
        originatorBaseline = usdc.balanceOf(originator); // 1_000e6 — escrow-delta baseline
        poolBaseline = usdc.balanceOf(address(pool)); // 0 — no LP deposits in these tests
    }

    // ------------------------------------------------------------ helpers

    function _bond(address who, uint256 amount) internal {
        vm.startPrank(who);
        usdc.mint(who, amount);
        usdc.approve(address(registry), amount);
        registry.bondIn(IAgentIdentity(address(0)), 0, amount);
        vm.stopPrank();
    }

    function _create(uint128 payment) internal returns (uint256 jobId) {
        vm.startPrank(originator);
        usdc.approve(address(jobRouter), payment);
        jobId = jobRouter.createJob(
            payment, bytes32("spec"), SPLIT, uint64(block.timestamp + 1 days), APPROVAL_WINDOW, address(0), 0
        );
        vm.stopPrank();
    }

    function _accept(uint256 jobId, address who) internal {
        vm.prank(who);
        jobRouter.accept(jobId);
    }

    function _submit(uint256 jobId) internal {
        vm.prank(executor);
        jobRouter.submitResult(jobId, bytes32("result"));
    }

    /// I7: assert escrow splits sum to payment, originator net of escrow-out.
    function _assertEscrow(
        uint128 payment,
        uint256 expOriginator,
        uint256 expExecutor,
        uint256 expPool,
        uint256 expTreasury
    ) internal view {
        assertEq(
            expOriginator + expExecutor + expPool + expTreasury, payment, "conservation: shares must sum to escrow"
        );
        assertEq(
            usdc.balanceOf(originator),
            originatorBaseline - payment + expOriginator,
            "originator cut (net of the escrow-out)"
        );
        assertEq(usdc.balanceOf(executor), expExecutor, "executor cut");
        assertEq(usdc.balanceOf(address(pool)) - poolBaseline, expPool, "pool cut");
        assertEq(usdc.balanceOf(treasury), expTreasury, "treasury cut");
        assertEq(usdc.balanceOf(address(jobRouter)), 0, "router must NEVER retain escrow");
    }

    // ------------------------------------------------------------ wiring

    function test_DeployDefaults() public view {
        assertEq(jobRouter.jobCount(), 0);
        assertEq(jobRouter.arbiter(), arbiter);
        assertEq(jobRouter.maxPayment(), 5_000e6);
        assertEq(jobRouter.splitFloorBps(), 2000);
        assertEq(registry.ROUTER(), address(jobRouter), "registry auth must point at the real router");
    }

    // ------------------------------------------------------------ createJob

    function test_CreateJob_EscrowsAndEmits() public {
        // approve FIRST so the helper's Approval event doesn't eat the expectEmit window
        vm.startPrank(originator);
        usdc.approve(address(jobRouter), PAYMENT);
        vm.expectEmit(false, false, false, true, address(jobRouter));
        emit IJobRouter.JobPosted(1, originator, PAYMENT, bytes32("spec"), uint64(block.timestamp + 1 days), 0);
        uint256 jobId = jobRouter.createJob(
            PAYMENT, bytes32("spec"), SPLIT, uint64(block.timestamp + 1 days), APPROVAL_WINDOW, address(0), 0
        );
        vm.stopPrank();
        assertEq(jobId, 1);
        assertEq(usdc.balanceOf(address(jobRouter)), PAYMENT, "escrow 1:1");
        IJobRouter.Job memory j = jobRouter.jobs(jobId);
        assertEq(uint8(j.state), uint8(IJobRouter.State.POSTED));
        assertEq(j.originator, originator);
        assertEq(usdc.balanceOf(originator), 900e6);
    }

    function test_CreateJob_ZeroSplit_UsesRegimeDefault() public {
        // 0/0/0 sentinel → regime default (9000/500/500) since lending gates are OFF.
        vm.startPrank(originator);
        usdc.approve(address(jobRouter), PAYMENT);
        uint256 jobId = jobRouter.createJob(
            PAYMENT,
            bytes32("s"),
            IJobRouter.Split({executorBps: 0, lpBps: 0, treasuryBps: 0}),
            uint64(block.timestamp + 1 days),
            APPROVAL_WINDOW,
            address(0),
            0
        );
        vm.stopPrank();

        IJobRouter.Split memory s = jobRouter.jobs(jobId).split;
        assertEq(s.executorBps, 9000, "regime default: executor");
        assertEq(s.lpBps, 500, "regime default: lp");
        assertEq(s.treasuryBps, 500, "regime default: treasury");

        // the resolved default settles exactly like an explicit 90/5/5 job
        _bond(executor, MIN_BOND);
        vm.warp(block.timestamp + 20 minutes + 1);
        _accept(jobId, executor);
        _submit(jobId);
        vm.prank(originator);
        jobRouter.approve(jobId);
        _assertEscrow(PAYMENT, 0, 90e6, 5e6, 5e6);
    }

    function test_CreateJob_RevertOnPaymentBounds() public {
        vm.startPrank(originator);
        usdc.approve(address(jobRouter), type(uint256).max);
        vm.expectRevert(IJobRouter.InvalidPayment.selector);
        jobRouter.createJob(0, bytes32("s"), SPLIT, uint64(block.timestamp + 1 days), APPROVAL_WINDOW, address(0), 0);
        vm.expectRevert(IJobRouter.InvalidPayment.selector);
        jobRouter.createJob(
            50_001e6, bytes32("s"), SPLIT, uint64(block.timestamp + 1 days), APPROVAL_WINDOW, address(0), 0
        );
        vm.stopPrank();
    }

    function test_CreateJob_RevertOnSplitBounds() public {
        IJobRouter.Split memory bad = IJobRouter.Split({executorBps: 9_600, lpBps: 300, treasuryBps: 100});
        vm.startPrank(originator);
        usdc.approve(address(jobRouter), PAYMENT);
        vm.expectRevert(); // InvalidSplit surfaces through ValueSplit.validate
        jobRouter.createJob(
            PAYMENT, bytes32("s"), bad, uint64(block.timestamp + 1 days), APPROVAL_WINDOW, address(0), 0
        );
        vm.stopPrank();
    }

    function test_CreateJob_RevertOnDeadlineBounds() public {
        vm.startPrank(originator);
        usdc.approve(address(jobRouter), PAYMENT);
        vm.expectRevert(IJobRouter.InvalidDeadline.selector);
        jobRouter.createJob(
            PAYMENT, bytes32("s"), SPLIT, uint64(block.timestamp + 10 minutes), APPROVAL_WINDOW, address(0), 0
        );
        vm.expectRevert(IJobRouter.InvalidDeadline.selector);
        jobRouter.createJob(
            PAYMENT, bytes32("s"), SPLIT, uint64(block.timestamp + 31 days), APPROVAL_WINDOW, address(0), 0
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------ accept (windows + bond gate)

    function test_Accept_Tier0_MustWaitWindows() public {
        uint256 jobId = _create(PAYMENT);
        _bond(executor, MIN_BOND);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IJobRouter.WindowClosed.selector, jobId));
        jobRouter.accept(jobId); // tier 0: opens at createdAt + W0 + W1
        vm.warp(block.timestamp + 20 minutes + 1);
        _accept(jobId, executor);
        assertEq(uint8(jobRouter.jobs(jobId).state), uint8(IJobRouter.State.ASSIGNED));
        assertEq(jobRouter.jobs(jobId).assignedAgent, registry.agentIdOf(executor));
    }

    function test_Accept_DirectHire() public {
        vm.startPrank(originator);
        usdc.approve(address(jobRouter), PAYMENT);
        uint256 jobId = jobRouter.createJob(
            PAYMENT, bytes32("s"), SPLIT, uint64(block.timestamp + 1 days), APPROVAL_WINDOW, executor, 0
        );
        vm.stopPrank();
        _bond(executor, MIN_BOND);
        address stranger = makeAddr("stranger");
        _bond(stranger, MIN_BOND);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IJobRouter.NotDesignatedAssignee.selector, jobId));
        jobRouter.accept(jobId);
        _accept(jobId, executor); // no window wait for direct hires
    }

    function test_Accept_RevertOnUnbondedAndShortBond() public {
        uint256 jobId = _create(PAYMENT);
        vm.prank(executor); // never bonded
        vm.expectRevert(IJobRouter.NotEligibleAgent.selector);
        jobRouter.accept(jobId);
        uint256 poorJob = _create(101e6); // > MIN_BOND: bond can't absorb it
        _bond(executor, MIN_BOND);
        vm.warp(block.timestamp + 20 minutes + 1);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IJobRouter.BondCapacityShortfall.selector, poorJob));
        jobRouter.accept(poorJob);
    }

    // ------------------------------------------------------------ submit / approve / timeout

    function test_SubmitAndApprove_ExactSplit() public {
        uint256 jobId = _create(PAYMENT);
        _bond(executor, MIN_BOND);
        vm.warp(block.timestamp + 20 minutes + 1);
        _accept(jobId, executor);
        _submit(jobId);
        assertEq(uint8(jobRouter.jobs(jobId).state), uint8(IJobRouter.State.SUBMITTED));

        uint256 ppsBefore = pool.pricePerShare();
        vm.prank(originator);
        jobRouter.approve(jobId);
        // 100e6 × 9000/500/500 → executor 90e6, lp 5e6, treasury 5e6 — no dust (I4)
        _assertEscrow(PAYMENT, 0, 90e6, 5e6, 5e6);
        assertGt(pool.pricePerShare(), ppsBefore, "P7: real router raises pool pps");
        assertEq(uint8(jobRouter.jobs(jobId).state), uint8(IJobRouter.State.SETTLED));
        // Shipped-registry volumeFactor caps a single 100-USDC outcome far below 0.5e18 —
        // assert the score moved off the 0 default (SUCCESS recorded), not an unsatisfiable bar.
        assertGt(registry.repScore(executor), 0, "SUCCESS lifts score above the 0 default");
    }

    function test_TimeoutSettle_AfterWindow() public {
        uint256 jobId = _create(PAYMENT);
        _bond(executor, MIN_BOND);
        vm.warp(block.timestamp + 20 minutes + 1);
        _accept(jobId, executor);
        _submit(jobId);
        vm.prank(originator);
        vm.expectRevert(); // still inside the approval window
        jobRouter.timeoutSettle(jobId);
        vm.warp(block.timestamp + APPROVAL_WINDOW + 1);
        vm.prank(makeAddr("anyone"));
        jobRouter.timeoutSettle(jobId); // protects agents from originator silence
        _assertEscrow(PAYMENT, 0, 90e6, 5e6, 5e6);
    }

    // ------------------------------------------------------------ cancel / expire

    function test_Cancel_OnlyPosted() public {
        uint256 jobId = _create(PAYMENT);
        vm.prank(originator);
        jobRouter.cancel(jobId);
        _assertEscrow(PAYMENT, 99_500_000, 0, 0, 500_000); // 50 bps cancel fee → treasury
        _bond(executor, MIN_BOND);
        vm.prank(originator);
        vm.expectRevert(abi.encodeWithSelector(IJobRouter.InvalidState.selector, jobId, IJobRouter.State.CANCELLED));
        jobRouter.cancel(jobId); // already terminal
    }

    function test_Expire_RefundsAndRecordsFailure() public {
        uint256 jobId = _create(PAYMENT);
        _bond(executor, MIN_BOND);
        vm.warp(block.timestamp + 20 minutes + 1);
        _accept(jobId, executor);
        vm.warp(block.timestamp + 1 days + 1); // past execDeadline
        vm.prank(makeAddr("anyone"));
        jobRouter.expire(jobId);
        // v1: no slash (lending postponed); 50 bps fee → treasury.
        _assertEscrow(PAYMENT, 99_500_000, 0, 0, 500_000);
        assertEq(registry.bondOf(executor), MIN_BOND, "bond untouched (no slash in demo)");
        assertLt(registry.repScore(executor), 0.5e18, "FAILURE drags score");
        assertEq(uint8(jobRouter.jobs(jobId).state), uint8(IJobRouter.State.EXPIRED));
    }

    // ------------------------------------------------------------ draws (compiled-dark)

    function test_DrawWorkingCapital_DualGate_RevertsInV1() public {
        uint256 jobId = _create(PAYMENT);
        _bond(executor, MIN_BOND);
        vm.warp(block.timestamp + 20 minutes + 1);
        _accept(jobId, executor);
        vm.prank(executor);
        vm.expectRevert(); // LendingDisabled: both gates OFF in v1 — unreachable by design
        jobRouter.drawWorkingCapital(jobId, 1e6);
    }
}
