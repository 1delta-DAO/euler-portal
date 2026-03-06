// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.0;

import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {AccountLens} from "evk-periphery/Lens/AccountLens.sol";
import "evk-periphery/Lens/LensTypes.sol";

struct VaultPositionInfo {
    address vault;
    address asset;
    uint256 shares;
    uint256 assets;
    uint256 borrowed;
    bool isController;
    bool isCollateral;
    AccountLiquidityInfo liquidityInfo;
}

struct AccountPositionInfo {
    address account;
    VaultPositionInfo[] vaults;
}

contract AccountPositionLens is AccountLens {
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

    function _getAccountPosition(address evc, address account) internal view returns (bool, AccountPositionInfo memory) {
        AccountPositionInfo memory result;
        result.account = account;

        // Skip accounts that never interacted with any vault. Check the timestamp first
        // (single SLOAD) since most sub-accounts will be inactive. The timestamp persists
        // even after all controllers are removed, so it catches historical borrowers.
        // Fall back to checking collaterals for deposit-only accounts.
        bool hadController = IEVC(evc).getLastAccountStatusCheckTimestamp(account) != 0;
        address[] memory collaterals = IEVC(evc).getCollaterals(account);
        if (!hadController && collaterals.length == 0) return (false, result);

        address[] memory controllers = IEVC(evc).getControllers(account);

        // Count unique vaults: all collaterals + controllers that are not also collaterals
        uint256 vaultCount = collaterals.length;
        for (uint256 j = 0; j < controllers.length; ++j) {
            if (!IEVC(evc).isCollateralEnabled(account, controllers[j])) {
                ++vaultCount;
            }
        }

        if (vaultCount == 0) return (false, result);

        result.vaults = new VaultPositionInfo[](vaultCount);
        bool hasPosition;

        // Controllers first
        for (uint256 j = 0; j < controllers.length; ++j) {
            result.vaults[j] = _getVaultPositionInfo(evc, account, controllers[j]);
            if (result.vaults[j].shares > 0 || result.vaults[j].borrowed > 0) hasPosition = true;
        }

        // Collaterals that are not also controllers
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
