// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockFeed} from "./MockFeed.sol";

/// @title Your keeper job — the thing an assigned AgentGrid worker does.
/// @notice This is a SCAFFOLD. In the live protocol the JobRouter never executes
///         your code: the assigned agent performs the work offchain and commits
///         to a re-derivable `resultHash` onchain. So the contract you ship is
///         (a) documentation of what "done" means and (b) the exact claim scheme
///         the worker must reproduce. Keep every claim deterministic from chain
///         state — that is what makes the job checkable by anyone before settling.
/// @custom:modify Adapt `perform`/`resultCommitment` to your own spec, and mirror
///         them in specs/spec.json's `verification` block (same `resultCommitment`
///         string must appear there). The spec's keccak256(bytes) becomes the
///         onchain specHash that gates `keeper_jobs`.
contract KeeperJob {
    /// The external world object this job keeps fresh.
    address public immutable feed;

    /// How fresh "fresh enough" is, in seconds (mirrors specs stalenessThresholdSec).
    uint256 public constant STALENESS_THRESHOLD = 3600;

    constructor(address _feed) {
        feed = _feed;
    }

    /// The work, restated as an onchain predicate: one job = one poke that brings
    /// the feed back within tolerance. Not called by the router — it exists so a
    /// verified claim is meaningful against a contract that AGREES what done is.
    function isDone(MockFeed _feed) external view returns (bool) {
        return !_feed.isStale(STALENESS_THRESHOLD);
    }

    /// The protocol-mandated claim format for a poke job.
    ///    resultHash = keccak256(abi.encodePacked(<pokeTxHash-no-0x>, ":", <postUpdateTimestamp>))
    /// The router stores only this hash; the originator re-derives it from the
    /// sender's poke transaction receipt. If you change the format here, change
    /// specs/spec.json's `verification.resultCommitment` to the same string.
    function resultCommitment(bytes32 pokeTxHash, uint256 postUpdateTimestamp)
        external
        pure
        returns (bytes32)
    {
        bytes memory body =
            abi.encodePacked(bytes32ToString(pokeTxHash), ":", uint256ToString(postUpdateTimestamp));
        return keccak256(body);
    }

    // -- tiny bytes32→string/uint→string helpers (documentational, no ABI parsing) --

    function bytes32ToString(bytes32 b) public pure returns (string memory) {
        bytes memory out = new bytes(64);
        for (uint256 i; i < 32; ++i) {
            bytes1 hi = bytes1(b[i] >> 4);
            bytes1 lo = bytes1(b[i] & 0x0F);
            out[2 * i] = nibbleToAscii(hi);
            out[2 * i + 1] = nibbleToAscii(lo);
        }
        return string(out);
    }

    function uint256ToString(uint256 n) public pure returns (string memory) {
        if (n == 0) return "0";
        uint256 tmp = n;
        uint256 len;
        while (tmp != 0) { tmp /= 10; ++len; }
        bytes memory buf = new bytes(len);
        while (n != 0) { buf[--len] = bytes1(uint8(48 + n % 10)); n /= 10; }
        return string(buf);
    }

    function nibbleToAscii(bytes1 nib) internal pure returns (bytes1) {
        uint8 v = uint8(nib);
        if (v < 10) return bytes1(uint8(48 + v));
        return bytes1(uint8(97 + v - 10)); // lowercase hex
    }
}