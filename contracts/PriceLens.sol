// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.0;

import {IEVault} from "evk/EVault/IEVault.sol";
import {IPriceOracle} from "euler-price-oracle/interfaces/IPriceOracle.sol";

struct VaultPriceInfo {
    address asset;
    address unitOfAccount;
    uint8 unitOfAccountDecimals;
    uint256 amountOutMid;
    bool queryFailure;
}

contract PriceLens {
    function getVaultPrice(address vault) external view returns (VaultPriceInfo memory result) {
        result.asset = IEVault(vault).asset();
        result.unitOfAccount = IEVault(vault).unitOfAccount();
        result.unitOfAccountDecimals = _getDecimals(result.unitOfAccount);

        address oracle = IEVault(vault).oracle();
        if (oracle == address(0)) {
            result.queryFailure = true;
            return result;
        }

        uint256 amountIn = 10 ** _getDecimals(result.asset);

        (bool success, bytes memory data) =
            oracle.staticcall(abi.encodeCall(IPriceOracle.getQuote, (amountIn, result.asset, result.unitOfAccount)));

        if (success && data.length >= 32) {
            result.amountOutMid = abi.decode(data, (uint256));
        } else {
            result.queryFailure = true;
        }
    }

    function getVaultPrices(address[] calldata vaults) external view returns (VaultPriceInfo[] memory results) {
        results = new VaultPriceInfo[](vaults.length);
        for (uint256 i; i < vaults.length; ++i) {
            results[i] = this.getVaultPrice(vaults[i]);
        }
    }

    function _getDecimals(address token) internal view returns (uint8) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeCall(IEVault(token).decimals, ()));
        return success && data.length >= 32 ? abi.decode(data, (uint8)) : 18;
    }
}
