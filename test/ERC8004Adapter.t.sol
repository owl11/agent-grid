// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC8004Adapter} from "../src/ERC8004Adapter.sol";
import {MockERC8004} from "./mocks/MockERC8004.sol";

contract ERC8004AdapterTest is Test {
    /// Live-fork tests: SKIPPED unless BASE_API holds a Base RPC endpoint.
    /// Run explicitly:  BASE_API="$RPC" forge test --match-path test/ERC8004Adapter.t.sol -vvv
    string constant RPC_ENV = "BASE_API";

    /// @dev Forks Base when RPC is configured; otherwise skips the test
    ///      cleanly instead of reverting on a missing env var.
    function _forkBaseIfConfigured() internal returns (bool configured) {
        string memory url = vm.envOr(RPC_ENV, string(""));
        configured = bytes(url).length > 0;
        if (!configured) {
            vm.skip(true); // halts here; reported as SKIP, suite stays green
            return false;
        }
        vm.createSelectFork(url);
        return true;
    }

    function testFork_VerifyAgainstLiveRegistry() public {
        // fork mainnet (Base) at a block
        if (!_forkBaseIfConfigured()) return;

        // real deployed registry + a real agent id we confirm exists
        ERC8004Adapter adapter = new ERC8004Adapter(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432);

        // pick a REAL registered agent + its owner (see below how to source)
        uint24 AGENT_ID = 55985;
        address OWNER = 0xe84ff92197C45e1974920143CE281Ec9fDdE3AE6;
        (bool owned) = adapter.verifyOwnership(AGENT_ID, OWNER);
        assertTrue(owned);
    }

    function testFork_NonexistentId_FailsClosed() public {
        if (!_forkBaseIfConfigured()) return;

        ERC8004Adapter adapter = new ERC8004Adapter(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432);

        // a tokenId that certainly doesn't exist on the live registry -> ownerOf reverts
        uint256 bogus = 1_000_000_000;

        assertFalse(adapter.verifyOwnership(bogus, address(this))); // revert -> fail closed
        assertTrue(adapter.isRevoked(bogus)); // burned/nonexistent
    }
}

/// Offline suite: same fail-closed paths as fork tests, no network.
contract ERC8004AdapterOfflineTest is Test {
    MockERC8004 internal registry;
    ERC8004Adapter internal adapter;

    uint256 constant ID = 42;
    address constant OWNER = address(0xA11CE);

    function setUp() public {
        registry = new MockERC8004();
        adapter = new ERC8004Adapter(address(registry));
    }

    /// Mock must produce identical revert data to the live registry.
    function test_mockRevert_MatchesLiveSignature() public view {
        bytes4 expected = bytes4(keccak256("ERC721NonexistentToken(uint256)"));
        (bool ok, bytes memory returndata) =
            address(registry).staticcall(abi.encodeCall(MockERC8004.ownerOf, (123_456)));
        assertFalse(ok);
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(bytes4(returndata), expected);
    }

    function test_mint_VerifyOwnershipTrue() public {
        registry.mint(ID, OWNER);
        assertTrue(adapter.verifyOwnership(ID, OWNER));
    }

    function test_wrongWallet_False() public {
        registry.mint(ID, OWNER);
        assertFalse(adapter.verifyOwnership(ID, address(0xB0B)));
    }

    function test_burn_FailsClosed() public {
        registry.mint(ID, OWNER);
        registry.burn(ID);
        assertFalse(adapter.verifyOwnership(ID, OWNER)); // revert -> false
        assertTrue(adapter.isRevoked(ID)); // burned -> revoked
    }

    function test_neverExisted_FailsClosed() public view {
        assertFalse(adapter.verifyOwnership(999_999, OWNER));
        assertTrue(adapter.isRevoked(999_999));
    }
}
