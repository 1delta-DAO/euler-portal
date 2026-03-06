// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";

/// @title Erc20Lib
/// @notice Library for ERC20 helpers: slippage checks and safe approve with retry.
library Erc20Lib {
    /// @notice Thrown when the account's token balance is below the required minimum.
    error InsufficientBalance();

    /// @notice Returns the token balance of `account` and reverts if it is below `amountMin`.
    function slippageCheck(IERC20 token, address account, uint256 amountMin) internal view returns (uint256 balance) {
        balance = token.balanceOf(account);
        if (balance < amountMin) revert InsufficientBalance();
        return balance;
    }

    /// @notice Reverts if `balance` is below `amountMin`. Use for native balance or pre-fetched balance.
    function requireMin(uint256 balance, uint256 amountMin) internal pure returns (uint256) {
        if (balance < amountMin) revert InsufficientBalance();
        return balance;
    }

    /// @notice Thrown when approve or approve-with-retry fails (e.g. non-standard token).
    error ApproveFailed();

    /// @notice Attempts a single approve call; returns (success, returnData). Handles tokens that return bool or nothing.
    function trySafeApprove(IERC20 token, address spender, uint256 value) internal returns (bool success, bytes memory data) {
        (success, data) = address(token).call(abi.encodeWithSelector(IERC20.approve.selector, spender, value));
        success = success && (data.length == 0 || abi.decode(data, (bool)));
        return (success, data);
    }

    /// @notice Approve `value` to `spender` with USDT-safe retry: if the first approve fails, resets to 0 then retries.
    /// Reverts with ApproveFailed() if both attempts fail.
    function safeApproveWithRetry(IERC20 token, address spender, uint256 value) internal {
        if (!trySafeApproveWithRetry(token, spender, value)) revert ApproveFailed();
    }

    /// @notice Same as safeApproveWithRetry but returns false instead of reverting. Caller can revert with custom error.
    function trySafeApproveWithRetry(IERC20 token, address spender, uint256 value) internal returns (bool success) {
        (success,) = trySafeApprove(token, spender, value);

        if (!success) {
            (success,) = trySafeApprove(token, spender, 0);
            if (success) {
                (success,) = trySafeApprove(token, spender, value);
            }
        }

        return success;
    }
}
