// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Swapper} from "../contracts/Swapper.sol";
import {Payments} from "../contracts/Payments.sol";

/// @title Deploy
/// @notice Deployment script for Payments and Swapper.
/// Deploy with the same EOA at the same nonce on every chain to get identical addresses.
/// @dev Usage:
///   EVC=0x... forge script script/Deploy.s.sol --rpc-url <rpc> --broadcast --private-key $PK
///   Optional env vars: PERMIT2 (default canonical address)
contract Deploy is Script {
    /// @dev Canonical Permit2 address (same on all chains).
    address constant DEFAULT_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() external {
        address evc = vm.envAddress("EVC");
        address permit2 = vm.envOr("PERMIT2", DEFAULT_PERMIT2);

        console.log("=== Euler Portal Deployment ===");
        console.log("EVC:     ", evc);
        console.log("Permit2: ", permit2);

        vm.startBroadcast();

        Swapper swapper = new Swapper();
        Payments payments = new Payments(evc, permit2);

        vm.stopBroadcast();

        console.log("Swapper:  ", address(swapper));
        console.log("Payments: ", address(payments));
    }
}
