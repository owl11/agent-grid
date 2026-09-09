// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {JobRouter} from "../../src/JobRouter.sol";
import {AgentRegistry} from "../../src/AgentRegistry.sol";
import {CapitalPool} from "../../src/CapitalPool.sol";
import {CreditLine} from "../../src/CreditLine.sol";
import {IJobRouter} from "../../src/interfaces/IJobRouter.sol";
import {IAgentIdentity} from "../../src/interfaces/IAgentIdentity.sol";
import {ValueSplit} from "../../src/libraries/ValueSplit.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

/// @notice Fuzz handler for JobRouterInvariantTest — drives RANDOM job lifecycles
///         (bond → create → accept → submit → approve/timeout/cancel/expire) over a
///         fully wired protocol, mirroring script/Deploy.s.sol's deploy graph.
///         Deliberately NOT a Test subclass (mocks/ precedent) so forge never
///         collects it as a suite.
///
/// @dev Success-oriented: every action PRE-CHECKS the exact gate that would revert
///      (the router's own canAccept view is the accept-gate mirror) and skips when
///      the action would revert-by-design. Combined with fail-on-revert = true, any
///      revert that does surface is a real bug, not a gate. Time is driven by
///      warpTick so windows, approval deadlines, and exec deadlines all get crossed
///      in both directions.
///
///      Ghosts track every USDC flow exactly; the invariant contract asserts the
///      router holds EXACTLY the open escrow and that global conservation holds.
contract JobHandler is CommonBase, StdUtils, StdAssertions {
    MockUSDC public usdc;
    AgentRegistry public registry;
    CapitalPool public pool;
    CreditLine public creditLine;
    JobRouter public router;
    address public treasury;

    uint256 internal constant N_ACTORS = 12;
    uint256 internal constant FUEL = 250_000e6; // per-actor posting fuel (never exhausts)
    uint256 internal constant MAX_PAYMENT = 2_500e6; // < router maxPayment 5_000e6
    uint256 internal constant WAGE_CAP_BPS = 9000; // JobRouter._executorCap() (pure, v1)

    address[] public actors;
    address[] public bondedActors;
    mapping(address => bool) public pendingExit;

    struct JobRec {
        uint256 id;
        address originator;
        address designated; // direct-hire target (0 = open post)
        address assignee; // set on accept
        uint128 payment;
        uint64 execDeadline;
        uint64 approvalDeadline; // 0 until SUBMITTED
        uint16 executorBps; // RESOLVED table (sentinel already unfolded)
        uint16 lpBps;
        uint16 treasuryBps;
        uint256 executorPaid;
        uint256 lpPaid;
        uint256 treasuryPaid;
        IJobRouter.State state;
    }
    JobRec[] internal jobRecs;

    // ghost telemetry — readable on failure traces, exact for invariant checks
    uint256 public ghostMinted;
    uint256 public ghostOpenEscrow;
    uint256 public ghostBondsHeld;
    uint256 public ghostTreasury;
    uint256 public ghostPoolRevenue;
    uint256 public ghostExecutorPaid;
    uint256 public ghostRefunded;
    uint256 public ghostCreates;
    uint256 public ghostAccepts;
    uint256 public ghostSubmits;
    uint256 public ghostSettles;
    uint256 public ghostTimeouts;
    uint256 public ghostCancels;
    uint256 public ghostExpires;
    uint256 public ghostExits;

    constructor() {
        treasury = vm.addr(uint256(keccak256("job-handler/treasury")));
        usdc = new MockUSDC();

        // circular deploy graph — placeholders first, wired second (Deploy.s.sol order)
        pool = new CapitalPool(IERC20(address(usdc)), address(this), address(0));
        registry = new AgentRegistry(address(usdc), 100e6, 7 days, address(0), address(pool), address(this));
        router = new JobRouter(IERC20(address(usdc)), registry, pool, treasury);
        creditLine = new CreditLine(address(pool), address(registry), address(usdc), address(router), address(this));
        registry.setRouter(address(router)); // registry auth → router
        registry.setCreditLine(address(creditLine)); // debt-lock writes → credit line
        pool.setRouter(address(router)); // revenue routing → router
        pool.setCreditLine(address(creditLine)); // draws/repayments → credit line (dark)
        router.setCredit(creditLine); // router draws → credit line (dark)

        for (uint256 i; i < N_ACTORS; ++i) {
            address a = vm.addr(uint256(keccak256(abi.encode("job-handler/actor", i))));
            actors.push(a);
            bondedActors.push(a);
            uint256 bond = 2_000e6 + i * 500e6; // 2000..7500 USDC — covers all payment sizes
            usdc.mint(a, FUEL);
            ghostMinted += FUEL;
            vm.startPrank(a);
            usdc.approve(address(registry), type(uint256).max);
            usdc.approve(address(router), type(uint256).max);
            registry.bondIn(IAgentIdentity(address(0)), 0, bond);
            vm.stopPrank();
            ghostBondsHeld += bond;
        }
    }

    // ------------------------------------------------------------------
    // accessors for the invariant contract
    // ------------------------------------------------------------------

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function jobCount() external view returns (uint256) {
        return jobRecs.length;
    }

    function jobIdAt(uint256 i) external view returns (uint256) {
        return jobRecs[i].id;
    }

    function jobStateAt(uint256 i) external view returns (IJobRouter.State) {
        return jobRecs[i].state;
    }

    // ------------------------------------------------------------------
    // time — the lifecycle driver
    // ------------------------------------------------------------------

    /// @notice Advances the clock: mostly small ticks (windows open), sometimes
    ///         hours (approval windows lapse), sometimes days (exec deadlines pass).
    function warpTick(uint256 seed) external {
        uint256 r = seed % 100;
        uint256 delta;
        if (r < 50) delta = bound(seed, 1 minutes, 45 minutes);
        else if (r < 85) delta = bound(seed, 1 hours, 6 hours);
        else delta = bound(seed, 8 hours, 4 days);
        vm.warp(block.timestamp + delta);
    }

    // ------------------------------------------------------------------
    // registry actions
    // ------------------------------------------------------------------

    function addBond(uint256 actorSeed, uint256 amountSeed) external {
        address a = bondedActors[bound(actorSeed, 0, bondedActors.length - 1)];
        if (pendingExit[a]) return; // exiting actor's bond is frozen — keep ghosts exact
        uint256 amount = bound(amountSeed, 1e6, 1_000e6);
        usdc.mint(a, amount);
        ghostMinted += amount;
        vm.prank(a);
        registry.addBond(amount);
        ghostBondsHeld += amount;
    }

    /// @notice One-way in v1 (completeExit is registry-fuzz territory, P2): a
    ///         pending exit permanently drops the actor from the accept pool —
    ///         which is exactly why accepts re-check canAccept every time.
    function requestExit(uint256 actorSeed) external {
        address a = bondedActors[bound(actorSeed, 0, bondedActors.length - 1)];
        if (pendingExit[a]) return;
        pendingExit[a] = true;
        vm.prank(a);
        registry.requestExit();
        ghostExits += 1;
    }

    // ------------------------------------------------------------------
    // job lifecycle
    // ------------------------------------------------------------------

    function createJob(
        uint256 originatorSeed,
        uint256 paymentSeed,
        uint256 splitSeed,
        uint256 execSeed,
        uint256 windowSeed,
        uint256 directSeed
    ) external {
        address originator = bondedActors[bound(originatorSeed, 0, bondedActors.length - 1)];
        uint128 payment = uint128(bound(paymentSeed, 1e6, MAX_PAYMENT));

        // ~half sentinel rows (regime default), half custom valid rows — including
        // executor > 9000 rows that exercise the wage cap on settlement.
        uint16 e;
        uint16 l;
        uint16 t;
        if (splitSeed % 2 == 0) {
            e = 0;
            l = 0;
            t = 0; // sentinel → defaultsInactive 9000/500/500 (gates OFF)
        } else {
            e = uint16(bound(splitSeed % 1_000_003, ValueSplit.MIN_EXECUTOR, ValueSplit.MAX_EXECUTOR));
            l = uint16(bound(splitSeed % 777_769, ValueSplit.MIN_LP, ValueSplit.MAX_LP));
            // Check BEFORE subtraction to avoid arithmetic underflow
            if (uint256(e) + uint256(l) > 9_900) {
                e = 0; // would leave treasury out of bounds → sentinel
                l = 0;
                t = 0;
            } else {
                t = uint16(10_000 - uint256(e) - uint256(l));
                if (t < ValueSplit.MIN_TREASURY || t > ValueSplit.MAX_TREASURY) {
                    e = 0; // out-of-band treasury → sentinel fallback
                    l = 0;
                    t = 0;
                }
            }
        }

        uint64 execDeadline = uint64(block.timestamp + bound(execSeed, 2 hours, 3 days));
        uint64 approvalWindow = uint64(bound(windowSeed, 10 minutes, 2 days));

        // ~1 in 4 is a direct hire to a random bonded actor
        address designated = address(0);
        if (directSeed % 4 == 0) {
            designated = bondedActors[bound(directSeed, 0, bondedActors.length - 1)];
        }

        uint256 routerBefore = usdc.balanceOf(address(router));
        uint256 originatorBefore = usdc.balanceOf(originator);
        vm.prank(originator);
        uint256 id = router.createJob(
            payment,
            bytes32(uint256(keccak256(abi.encodePacked("spec", ghostCreates)))),
            IJobRouter.Split({executorBps: e, lpBps: l, treasuryBps: t}),
            execDeadline,
            approvalWindow,
            designated,
            0
        );

        // escrow moved 1:1 originator → router, atomically
        assertEq(usdc.balanceOf(originator), originatorBefore - payment, "create: escrow delta");
        assertEq(usdc.balanceOf(address(router)), routerBefore + payment, "create: router holds escrow");

        // mirror the RESOLVED table from chain state (sentinel already unfolded)
        IJobRouter.Job memory j = router.jobs(id);
        jobRecs.push(
            JobRec({
                id: id,
                originator: j.originator,
                designated: j.designatedAssignee,
                assignee: address(0),
                payment: j.payment,
                execDeadline: j.execDeadline,
                approvalDeadline: 0,
                executorBps: j.split.executorBps,
                lpBps: j.split.lpBps,
                treasuryBps: j.split.treasuryBps,
                executorPaid: 0,
                lpPaid: 0,
                treasuryPaid: 0,
                state: j.state
            })
        );
        ghostOpenEscrow += payment;
        ghostCreates += 1;
    }

    /// @notice Random claimant attempts a POSTED job; canAccept is the EXACT gate
    ///         mirror (state, designation, eligibility, window, bond capacity), so a
    ///         skipped call is by-design and a performed call cannot revert.
    function accept(uint256 jobSeed, uint256 actorSeed) external {
        if (jobRecs.length == 0) return;
        JobRec storage rec = jobRecs[bound(jobSeed, 0, jobRecs.length - 1)];
        if (rec.state != IJobRouter.State.POSTED) return;

        address claimant =
            rec.designated != address(0) ? rec.designated : bondedActors[bound(actorSeed, 0, bondedActors.length - 1)];
        if (!router.canAccept(rec.id, claimant)) return;

        vm.prank(claimant);
        router.accept(rec.id);
        rec.assignee = claimant;
        rec.state = IJobRouter.State.ASSIGNED;
        ghostAccepts += 1;
    }

    function submitResult(uint256 jobSeed, uint256 hashSeed) external {
        if (jobRecs.length == 0) return;
        JobRec storage rec = jobRecs[bound(jobSeed, 0, jobRecs.length - 1)];
        if (rec.state != IJobRouter.State.ASSIGNED) return;
        if (block.timestamp > rec.execDeadline) return; // DeadlinePassed — expire() path

        vm.prank(rec.assignee);
        router.submitResult(rec.id, bytes32(hashSeed));
        rec.approvalDeadline = router.jobs(rec.id).approvalDeadline; // zero-drift mirror
        rec.state = IJobRouter.State.SUBMITTED;
        ghostSubmits += 1;
    }

    /// @notice Originator approves inside the window — the demo's primary settle path.
    function approve(uint256 jobSeed) external {
        if (jobRecs.length == 0) return;
        JobRec storage rec = jobRecs[bound(jobSeed, 0, jobRecs.length - 1)];
        if (rec.state != IJobRouter.State.SUBMITTED) return;
        if (block.timestamp > rec.approvalDeadline) return; // window lapsed — timeoutSettle path

        vm.prank(rec.originator);
        router.approve(rec.id);
        _postSettle(rec);
        ghostSettles += 1;
    }

    /// @notice Permissionless auto-settle after the approval window lapses silently.
    function timeoutSettle(uint256 jobSeed) external {
        if (jobRecs.length == 0) return;
        JobRec storage rec = jobRecs[bound(jobSeed, 0, jobRecs.length - 1)];
        if (rec.state != IJobRouter.State.SUBMITTED) return;
        if (block.timestamp <= rec.approvalDeadline) return; // still open — approve() path

        router.timeoutSettle(rec.id);
        _postSettle(rec);
        ghostTimeouts += 1;
    }

    function cancel(uint256 jobSeed) external {
        if (jobRecs.length == 0) return;
        JobRec storage rec = jobRecs[bound(jobSeed, 0, jobRecs.length - 1)];
        if (rec.state != IJobRouter.State.POSTED) return;

        uint256 fee = (uint256(rec.payment) * router.cancelFeeBps()) / 10_000;
        uint256 originatorBefore = usdc.balanceOf(rec.originator);
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 routerBefore = usdc.balanceOf(address(router));

        vm.prank(rec.originator);
        router.cancel(rec.id);

        assertEq(usdc.balanceOf(rec.originator), originatorBefore + rec.payment - fee, "cancel: refund");
        assertEq(usdc.balanceOf(treasury), treasuryBefore + fee, "cancel: fee");
        assertEq(usdc.balanceOf(address(router)), routerBefore - rec.payment, "cancel: escrow released");

        rec.state = IJobRouter.State.CANCELLED;
        ghostOpenEscrow -= rec.payment;
        ghostTreasury += fee;
        ghostRefunded += rec.payment - fee;
        ghostCancels += 1;
    }

    /// @notice ASSIGNED-only expiry (POSTED jobs are cancel()'s) — anyone may call.
    function expire(uint256 jobSeed) external {
        if (jobRecs.length == 0) return;
        JobRec storage rec = jobRecs[bound(jobSeed, 0, jobRecs.length - 1)];
        if (rec.state != IJobRouter.State.ASSIGNED) return;
        if (block.timestamp <= rec.execDeadline) return; // still live — submit() path

        uint256 fee = (uint256(rec.payment) * router.cancelFeeBps()) / 10_000;
        uint256 originatorBefore = usdc.balanceOf(rec.originator);
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 routerBefore = usdc.balanceOf(address(router));

        router.expire(rec.id); // permissionless

        assertEq(usdc.balanceOf(rec.originator), originatorBefore + rec.payment - fee, "expire: refund");
        assertEq(usdc.balanceOf(treasury), treasuryBefore + fee, "expire: fee");
        assertEq(usdc.balanceOf(address(router)), routerBefore - rec.payment, "expire: escrow released");

        rec.state = IJobRouter.State.EXPIRED;
        ghostOpenEscrow -= rec.payment;
        ghostTreasury += fee;
        ghostRefunded += rec.payment - fee;
        ghostExpires += 1;
    }

    // ------------------------------------------------------------------
    // internals
    // ------------------------------------------------------------------

    /// @dev Per-settle exactness: replicates _settleSuccess's split math (incl. the
    ///      wage cap) and asserts every delta — executor → wallet, lp → pool
    ///      (revenue), treasury → treasury, escrow released 1:1. Ghosts update
    ///      only after the assertions pass.
    function _postSettle(JobRec storage rec) internal {
        (uint256 executor, uint256 lp, uint256 treasuryAmt) =
            _expectedSplit(rec.payment, rec.executorBps, rec.lpBps, rec.treasuryBps);
        assertEq(executor + lp + treasuryAmt, rec.payment, "I4: split must sum to payment exactly");

        uint256 walletBefore = usdc.balanceOf(rec.assignee);
        uint256 poolBefore = usdc.balanceOf(address(pool));
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 routerBefore = usdc.balanceOf(address(router));

        assertEq(usdc.balanceOf(rec.assignee), walletBefore + executor, "settle: executor paid");
        assertEq(usdc.balanceOf(address(pool)), poolBefore + lp, "settle: lp to pool");
        assertEq(usdc.balanceOf(treasury), treasuryBefore + treasuryAmt, "settle: treasury cut");
        assertEq(usdc.balanceOf(address(router)), routerBefore - rec.payment, "settle: escrow released");

        rec.executorPaid = executor;
        rec.lpPaid = lp;
        rec.treasuryPaid = treasuryAmt;
        rec.state = IJobRouter.State.SETTLED;
        ghostOpenEscrow -= rec.payment;
        ghostPoolRevenue += lp;
        ghostTreasury += treasuryAmt;
        ghostExecutorPaid += executor;
    }

    /// @dev mirrors JobRouter._settleSuccess: ValueSplit.amounts (passive floor +
    ///      executor remainder) then the wage-cap redistribution (v1 cap 9000).
    function _expectedSplit(uint128 payment, uint16 e, uint16 l, uint16 t)
        internal
        pure
        returns (uint256 executor, uint256 lp, uint256 treasuryAmt)
    {
        (executor, lp, treasuryAmt) =
            ValueSplit.amounts(ValueSplit.Split({executorBps: e, lpBps: l, treasuryBps: t}), payment);
        if (uint256(e) > WAGE_CAP_BPS) {
            uint256 capped = (uint256(payment) * WAGE_CAP_BPS) / 10_000;
            uint256 delta = executor - capped;
            executor = capped;
            uint256 passiveBps = uint256(l) + uint256(t);
            lp += (delta * l) / passiveBps;
            treasuryAmt = uint256(payment) - executor - lp; // remainder → no dust (I4)
        }
    }
}
