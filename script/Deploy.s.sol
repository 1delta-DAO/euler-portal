// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Orchestrator} from "../contracts/Orchestrator.sol";
import {Payments} from "../contracts/Payments.sol";

/// @title Deploy
/// @notice Deployment script for Payments and Orchestrator.
/// Deploy with the same EOA at the same nonce on every chain to get identical addresses.
/// @dev Usage:
///   EVC=0x... forge script script/Deploy.s.sol --rpc-url <rpc> --broadcast --private-key $PK
contract Deploy is Script {
    function run() external {
        address evc = vm.envAddress("EVC");
        console.log("=== Euler Portal Deployment ===");
        console.log("EVC:     ", evc);

        vm.startBroadcast();

        Orchestrator orchestrator = new Orchestrator();
        Payments payments = new Payments(evc);

        vm.stopBroadcast();

        console.log("Orchestrator: ", address(orchestrator));
        console.log("Payments:     ", address(payments));
    }
}
