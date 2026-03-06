// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {AccountPositionLens, AccountPositionInfo, VaultPositionInfo} from "../contracts/AccountPositionLens.sol";
import {AccountLens} from "evk-periphery/Lens/AccountLens.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import "evk-periphery/Lens/LensTypes.sol";

/// @dev Old lens without the timestamp shortcut, for gas comparison.
contract AccountPositionLensOld is AccountLens {
    function getAccountPositionsBatch(
        address evc,
        address[] calldata accounts
    )
        public
        view
        returns (AccountPositionInfo[] memory)
    {
        AccountPositionInfo[] memory results = new AccountPositionInfo[](accounts.length);
        uint256 resultCount;

        for (uint256 i = 0; i < accounts.length; ++i) {
            (bool hasPosition, AccountPositionInfo memory info) = _getAccountPosition(evc, accounts[i]);

            if (hasPosition) {
                results[resultCount] = info;
                ++resultCount;
            }
        }

        assembly {
            mstore(results, resultCount)
        }

        return results;
    }

    /// @dev Original logic: no timestamp shortcut, always queries controllers + collaterals.
    function _getAccountPosition(address evc, address account) internal view returns (bool, AccountPositionInfo memory) {
        AccountPositionInfo memory result;
        result.account = account;

        address[] memory controllers = IEVC(evc).getControllers(account);
        address[] memory collaterals = IEVC(evc).getCollaterals(account);

        uint256 vaultCount = collaterals.length;
        for (uint256 j = 0; j < controllers.length; ++j) {
            if (!IEVC(evc).isCollateralEnabled(account, controllers[j])) {
                ++vaultCount;
            }
        }

        if (vaultCount == 0) return (false, result);

        result.vaults = new VaultPositionInfo[](vaultCount);
        bool hasPosition;

        for (uint256 j = 0; j < controllers.length; ++j) {
            result.vaults[j] = _getVaultPositionInfo(evc, account, controllers[j]);
            if (result.vaults[j].shares > 0 || result.vaults[j].borrowed > 0) hasPosition = true;
        }

        uint256 idx = controllers.length;
        for (uint256 j = 0; j < collaterals.length; ++j) {
            if (!IEVC(evc).isControllerEnabled(account, collaterals[j])) {
                result.vaults[idx] = _getVaultPositionInfo(evc, account, collaterals[j]);
                if (result.vaults[idx].shares > 0 || result.vaults[idx].borrowed > 0) hasPosition = true;
                ++idx;
            }
        }

        return (hasPosition, result);
    }

    function _getVaultPositionInfo(address evc, address account, address vault) internal view returns (VaultPositionInfo memory) {
        VaultPositionInfo memory result;

        result.vault = vault;

        (bool success, bytes memory data) = vault.staticcall(abi.encodeCall(IEVault(vault).asset, ()));

        if (!success || data.length < 32) {
            return result;
        }

        result.asset = abi.decode(data, (address));

        (success, data) = vault.staticcall(abi.encodeCall(IEVault(vault).balanceOf, (account)));

        if (success && data.length >= 32) {
            result.shares = abi.decode(data, (uint256));
        }

        (success, data) = vault.staticcall(abi.encodeCall(IEVault(vault).convertToAssets, (result.shares)));

        if (success && data.length >= 32) {
            result.assets = abi.decode(data, (uint256));
        }

        (success, data) = vault.staticcall(abi.encodeCall(IEVault(vault).debtOf, (account)));

        if (success && data.length >= 32) {
            result.borrowed = abi.decode(data, (uint256));
        }

        result.isController = IEVC(evc).isControllerEnabled(account, vault);
        result.isCollateral = IEVC(evc).isCollateralEnabled(account, vault);

        if (result.isController) {
            result.liquidityInfo = getAccountLiquidityInfo(account, vault);
        }

        return result;
    }
}

contract AccountPositionLensForkTest is Test {
    address constant EVC = 0xb2E5a73CeE08593d1a076a2AE7A6e02925a640ea;
    address constant OWNER = 0x6577Fd2A1782FdB0EA1B4eeFd72f42AcdeA0a9a3;

    AccountPositionLens newLens;
    AccountPositionLensOld oldLens;

    function setUp() public {
        vm.createSelectFork("https://bsc-dataseed.binance.org");

        newLens = new AccountPositionLens();
        oldLens = new AccountPositionLensOld();
    }

    function _buildSubAccounts(address owner) internal pure returns (address[] memory) {
        address[] memory accounts = new address[](256);
        for (uint256 i = 0; i < 256; ++i) {
            accounts[i] = address(uint160(uint160(owner) ^ i));
        }
        return accounts;
    }

    function test_forkBsc_subAccountDiscovery_gasComparison() public {
        address[] memory accounts = _buildSubAccounts(OWNER);

        // --- Old lens (no timestamp shortcut) ---
        uint256 gasOld = gasleft();
        AccountPositionInfo[] memory oldResults = oldLens.getAccountPositionsBatch(EVC, accounts);
        gasOld = gasOld - gasleft();

        // --- New lens (with timestamp shortcut) ---
        uint256 gasNew = gasleft();
        AccountPositionInfo[] memory newResults = newLens.getAccountPositionsBatch(EVC, accounts);
        gasNew = gasNew - gasleft();

        // Results must match
        assertEq(newResults.length, oldResults.length, "result count mismatch");
        for (uint256 i = 0; i < newResults.length; ++i) {
            assertEq(newResults[i].account, oldResults[i].account, "account mismatch");
            assertEq(newResults[i].vaults.length, oldResults[i].vaults.length, "vault count mismatch");
        }

        // Log results
        console.log("--- BSC Fork: Sub-Account Discovery Gas Comparison ---");
        console.log("Owner:              ", OWNER);
        console.log("Sub-accounts scanned:", accounts.length);
        console.log("Active sub-accounts: ", newResults.length);
        console.log("Gas OLD (no shortcut):", gasOld);
        console.log("Gas NEW (w/ shortcut):", gasNew);
        console.log("Gas saved:           ", gasOld - gasNew);
        console.log("Savings:             ", ((gasOld - gasNew) * 100) / gasOld, "%");

        // Log which sub-accounts are active
        for (uint256 i = 0; i < newResults.length; ++i) {
            console.log("  Active sub-account:", newResults[i].account, "| vaults:", newResults[i].vaults.length);
        }

        // Sanity: new method should be cheaper
        assertGt(gasOld, gasNew, "new method should use less gas");
    }
}
