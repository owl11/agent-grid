// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockFeed} from "../src/MockFeed.sol";
import {KeeperJob} from "../src/KeeperJob.sol";

/// @title Tests that pin the AgentGrid keeper contract, standalone.
/// @notice These encode the exact expectations AgentGrid's onchain loop enforces
///         (see scripts/postUpkeep.sh / the keeper MCP pack), so a job module is
///         validated against the protocol BEFORE it ever posts escrow:
///           1. one job = one poke that brings the feed within tolerance
///           2. the submitted resultHash is keccak256("<pokeTx-no-0x>:<timestamp>"),
///              re-derivable from the poke tx receipt + post-update timestamp
///           3. the staleness predicate is a plain threshold (<, honest at 0)
///         No AgentGrid imports — green out of the box with `forge test`.
contract KeeperFlowTest is Test {
    MockFeed internal feed;
    KeeperJob internal job;

    uint256 internal constant THRESHOLD = 3600;

    address internal constant EXECUTOR = address(0xA11CE);
    uint256 internal constant POKE_VALUE = 87654; // e.g. BTC price (0dp demo)

    function setUp() public {
        feed = new MockFeed();
        job = new KeeperJob(address(feed));

        vm.deal(EXECUTOR, 1 ether);
        vm.warp(1_700_000_000);
    }

    // ---- 1. one poke = fresh -------------------------------------------------

    /// A brand-new feed is STALE (nothing has ever written a round).
    function test_FreshFeedIsStaleUntilFirstPoke() public view {
        assertTrue(feed.isStale(THRESHOLD));
    }

    /// One poke satisfies the whole job: the feed is no longer stale.
    function test_OnePokeBringsFeedWithinTolerance() public {
        vm.prank(EXECUTOR);
        uint256 ts = feed.poke(POKE_VALUE);

        assertEq(ts, block.timestamp);
        assertEq(feed.lastUpdated(), block.timestamp);
        assertTrue(!feed.isStale(THRESHOLD));
        // and the job contract agrees "done"
        assertTrue(job.isDone(feed));
    }

    /// The claim is bound to THAT poke: a later warp makes the same claim stale.
    function test_ClaimIsOnlyValidForThePokeThatSatisfiedIt() public {
        vm.prank(EXECUTOR);
        feed.poke(POKE_VALUE);

        vm.warp(block.timestamp + THRESHOLD + 1);
        assertTrue(feed.isStale(THRESHOLD));
        assertTrue(!job.isDone(feed));
    }

    // ---- 2. commitment is re-derivable — the whole verification premise -------

    /// The worker's claim must equal exactly keccak("<pokeTx-no-0x>:<postUpdatedAt>").
    /// The originator re-derives this from the poke tx receipt without trusting
    /// the worker at all.
    function test_ResultHashIsExactKeccakPokeColonTimestamp() public {
        // Simulate: EXECUTOR pokes at T; their poke tx receipt hash is known.
        vm.prank(EXECUTOR);
        feed.poke(POKE_VALUE);
        uint256 postUpdatedAt = feed.lastUpdated();

        bytes32 fakePokeTxHash = keccak256(abi.encodePacked("poke-receipt-bytes"));
        bytes32 claimed = job.resultCommitment(fakePokeTxHash, postUpdatedAt);

        // Re-derivation, unambiguously: the verifier takes the receipt's tx hash
        // WITHOUT 0x, appends ":" + the postUpdateTimestamp (seconds), then keccak.
        bytes32 rederived = keccak256(
            abi.encodePacked(
                job.bytes32ToString(fakePokeTxHash), ":", job.uint256ToString(postUpdatedAt)
            )
        );
        assertEq(claimed, rederived);
        assertTrue(claimed != bytes32(0));
    }

    /// Two different poke txs can never collide on the same commit.
    function test_DifferentPokeTxsYieldDifferentClaims() public {
        vm.prank(EXECUTOR);
        feed.poke(POKE_VALUE);
        bytes32 a = job.resultCommitment(bytes32(uint256(1)), feed.lastUpdated());
        bytes32 b = job.resultCommitment(bytes32(uint256(2)), feed.lastUpdated());
        assertTrue(a != b);
    }

    // ---- 3. staleness predicate is an honest threshold ------------------------

    /// Exactly at the threshold is NOT stale (comparison is strict >).
    function test_StalenessThresholdIsStrictGreater() public {
        vm.prank(EXECUTOR);
        feed.poke(POKE_VALUE);
        vm.warp(block.timestamp + THRESHOLD);
        assertTrue(!feed.isStale(THRESHOLD));
        vm.warp(block.timestamp + 1);
        assertTrue(feed.isStale(THRESHOLD));
        assertTrue(!job.isDone(feed));
    }

    // -- helpers ----------------------------------------------------------------

    // (none) — the test derives claims through the job contract's own functions,
    // so the byte-level scheme stays in ONE place (src/KeeperJob.sol).
}