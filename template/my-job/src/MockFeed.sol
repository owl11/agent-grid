// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title A small onchain feed — the "external world" a keeper job keeps fresh.
/// @notice Stand-in for a real price/proto oracle. AgentGrid (the protocol this
///         template pairs with) ships an equivalent live on Arc testnet; here it
///         exists so the keeper flow is testable locally with no network.
contract MockFeed {
    /// Timestamp of the last successfully-written round (0 until the first poke).
    uint256 public lastUpdated;

    /// The current value of the feed (whatever the updater last wrote).
    uint256 public latestValue;

    event Poked(uint256 indexed value, uint256 indexed at);

    /// One keeper action = one poke. Updates the value and stamps the round.
    function poke(uint256 value) external returns (uint256) {
        latestValue = value;
        lastUpdated = block.timestamp;
        emit Poked(value, lastUpdated);
        return lastUpdated;
    }

    /// Feed is stale if its freshest round is older than `thresholdSec`.
    /// This is the predicate the protocol's originator checks before posting.
    function isStale(uint256 thresholdSec) public view returns (bool) {
        return block.timestamp - lastUpdated > thresholdSec;
    }
}