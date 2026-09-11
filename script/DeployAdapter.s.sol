// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {ERC8004Adapter} from "../src/ERC8004Adapter.sol";

/// @title Deploy ERC8004Adapter pointed at Arc's IdentityRegistry
/// @notice Standalone and permissionless: holds no state, needs no privileges,
///         requires NO protocol redeploy (AgentRegistry takes the adapter
///         per-bond via bondIn(adapter, externalId, amount)).
///         Run:  forge script script/DeployAdapter.s.sol \
///                 --rpc-url arc_testnet --broadcast

contract DeployAdapter is Script {
    /// @notice Arc testnet ERC-8004 IdentityRegistry (agent NFTs).
    address constant ARC_IDENTITY_REGISTRY = 0x8004A818BFB912233c491871b3d84c89A494BD9e;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        // Override only to point at a different source registry (e.g. another chain).
        address source = vm.envOr("IDENTITY_REGISTRY", ARC_IDENTITY_REGISTRY);

        console2.log("=== ERC8004Adapter deploy - Arc testnet (5042002) ===");
        console2.log("deployer:", deployer);
        console2.log("source registry:", source);

        vm.startBroadcast(pk);
        ERC8004Adapter adapter = new ERC8004Adapter(source);
        vm.stopBroadcast();

        console2.log("");
        console2.log("=== FILL clients (ARC_8004.adapter) ===");
        console2.log("ERC8004Adapter :", address(adapter));
    }
}
