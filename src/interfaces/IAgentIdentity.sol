// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// @title IAgentIdentity
/// @notice Pluggable identity verification ("depends on the agent"). The protocol
///         never assumes what an agent IS — an adapter verifies an agent's claim
///         to an EXTERNAL identity token on some source registry (e.g. the Base
///         ERC-8004 Identity Registry singleton).
/// @dev    Verify-model, not resolve-model: source registries may be
///         non-enumerable, so no adapter can resolve address -> id on its own.
///         The CALLER supplies the external id; the registry binds it at bond
///         time after an ownership check, and re-checks revocation lazily.
///
///         Bare-address mode is NOT an adapter: passing `IAgentIdentity(0)` to
///         AgentRegistry.bondIn means wallet == identity, with canonical id
///         bytes32(uint256(uint160(wallet))).
///
///         Implementations must fail CLOSED: any upstream revert, malformed
///         return data, or burned/nonexistent token reads as unowned/revoked.
///         Proven against the live Base registry — see test/ERC8004Adapter.t.sol.
interface IAgentIdentity {
    /// @notice True if `wallet` currently owns live external identity `externalId`.
    /// @param agentId Token id on the SOURCE registry this adapter wraps.
    /// @param wallet Address claiming ownership (typically msg.sender of registry ops).
    /// @return owned True only for a live, currently-owned token.
    function verifyOwnership(uint256 agentId, address wallet) external view returns (bool owned);

    /// @notice True if `externalId` is revoked upstream: burned, nonexistent,
    ///         or otherwise invalid on the source registry.
    /// @param agentId Token id on the SOURCE registry this adapter wraps.
    function isRevoked(uint256 agentId) external view returns (bool);
}
