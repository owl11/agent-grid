// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {AgentRegistry} from "../src/AgentRegistry.sol";
import {CapitalPool} from "../src/CapitalPool.sol";
import {CreditLine} from "../src/CreditLine.sol";
import {JobRouter} from "../src/JobRouter.sol";

/// @title AgentGrid Arc-testnet deploy
/// @notice Deploys the full protocol and wires the circular deploy graph
///         post-construction, exactly like test/JobRouter.t.sol does:
///           1. CapitalPool(router=0, creditLine=0)      — placeholders
///           2. AgentRegistry(router=0, pool=real)        — router placeholder
///           3. JobRouter(registry, pool)                 — real refs
///           4. CreditLine(pool, registry, router)        — real refs
///           5. setRouter/setCreditLine/setCredit/setArbiter — closes the circle
/// @dev    Run:  forge script script/Deploy.s.sol \
///                --rpc-url arc_testnet --broadcast --verify
///         Arc testnet native-USDC gas is 18 decimals; the ERC-20 USDC below
///         is 6 — never mix raw values (docs.arc.io EVM differences).
contract Deploy is Script {
    /// @notice Arc testnet predeployed USDC (ERC-20, 6 decimals).
    address constant ARC_USDC = 0x3600000000000000000000000000000000000000;

    /// @notice Bond floor: 5 USDC (6 dp) — sized for the Arc testnet faucet
    ///         (~20 USDC per drop): allows 4 bonds, leaving room for job escrow.
    uint256 constant MIN_BOND = 5e6;
    /// @notice Exit delay: 7 days.
    uint64 constant EXIT_DELAY = 7 days;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        // Arbiter defaults to the deployer (timelocked multisig in prod —
        // reassign via jobRouter.setArbiter after the safe is up).
        address arbiter = vm.envOr("ARBITER", deployer);
        address treasury = vm.envOr("TREASURY", deployer);

        console2.log("=== AgentGrid deploy - Arc testnet (5042002) ===");
        console2.log("deployer:", deployer);
        console2.log("arbiter :", arbiter);
        console2.log("treasury:", treasury);
        console2.log("USDC    :", ARC_USDC);

        vm.startBroadcast(pk);

        IERC20 usdc = IERC20(ARC_USDC);

        // ---- 1) pool with placeholder router/creditLine (wired below) ----
        CapitalPool pool = new CapitalPool(usdc, address(0), address(0));

        // ---- 2) registry with placeholder router (wired below) ----
        AgentRegistry registry =
            new AgentRegistry(address(usdc), MIN_BOND, EXIT_DELAY, address(0), address(pool), deployer);

        // ---- 3) router: now that registry + pool exist, refs are real ----
        JobRouter router = new JobRouter(usdc, registry, pool, treasury);

        // ---- 4) credit line binds pool + registry + router ----
        CreditLine creditLine =
            new CreditLine(address(pool), address(registry), address(usdc), address(router), deployer);

        // ---- 5) close the circular graph (all owner-gated) ----
        registry.setRouter(address(router)); // registry auth → router
        registry.setCreditLine(address(creditLine)); // debt-lock writes → credit line
        pool.setRouter(address(router)); // revenue routing → router
        pool.setCreditLine(address(creditLine)); // draws/repayments/losses → credit line
        router.setCredit(creditLine); // router draws → credit line
        router.setArbiter(arbiter); // dispute rulings

        vm.stopBroadcast();

        // ---- addresses for subgraph/subgraph.yaml + front-end + MCP env ----
        console2.log("");
        console2.log("=== FILL subgraph subgraph.yaml + clients ===");
        console2.log("JobRouter     :", address(router));
        console2.log("AgentRegistry :", address(registry));
        console2.log("CapitalPool   :", address(pool));
        console2.log("CreditLine    :", address(creditLine));
        console2.log("startBlock: use each contract's deploy tx block (forge report above)");
    }
}
