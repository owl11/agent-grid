// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IAgentIdentity} from "./interfaces/IAgentIdentity.sol";

interface IRegistry {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice Verifies ERC-8004 identity state against the non-enumerable Base registry.
///         No stored link, no reverse-lookup. Caller supplies the agentId; we verify
///         ownership + revocation, failing closed on burn/transfer.
contract ERC8004Adapter is IAgentIdentity {
    IRegistry public immutable registry;

    constructor(address registry_) {
        registry = IRegistry(registry_);
    }

    /// @notice True if `wallet` owns a live (non-burned, non-transferred) agentId.
    ///         Fails closed: ownerOf reverting (burned/nonexistent) -> not owned.
    function verifyOwnership(uint256 agentId, address wallet) external view returns (bool) {
        return _ownerOrZero(agentId) == wallet;
    }

    /// @notice True if the agentId is burned or nonexistent (ownerOf reverts).
    function isRevoked(uint256 agentId) external view returns (bool) {
        return _ownerOrZero(agentId) == address(0);
    }

    /// @dev Fails closed: ownerOf revert (burned/nonexistent) or malformed data -> 0.
    function _ownerOrZero(uint256 id) internal view returns (address owner_) {
        (bool ok, bytes memory data) = address(registry).staticcall(abi.encodeCall(IRegistry.ownerOf, (id)));
        if (!ok || data.length != 32) return address(0);
        owner_ = abi.decode(data, (address));
    }
}
