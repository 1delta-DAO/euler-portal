// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PriceLens} from "../contracts/PriceLens.sol";

/// @title DeployPriceLens
/// @notice Deploys the PriceLens contract (no constructor args).
/// @dev Usage:
///   forge script script/DeployPriceLens.s.sol --rpc-url <rpc> --broadcast --private-key $PK
contract DeployPriceLens is Script {
    function run() external {
        console.log("=== PriceLens Deployment ===");

        vm.startBroadcast();

        PriceLens priceLens = new PriceLens();

        vm.stopBroadcast();

        console.log("PriceLens:", address(priceLens));
    }
}
