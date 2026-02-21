// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {IVault} from "./interfaces/IVault.sol";
import {SafeERC20Lib} from "./lib/SafeERC20Lib.sol";

/// @title Swapper
/// @custom:security-contact security@euler.xyz
/// @author Euler Labs (https://www.eulerlabs.com/)
/// @notice Untrusted helper contract for executing arbitrary swaps via a generic handler
/// and composable post-swap actions (deposit, repay, sweep) with slippage checks.
/// @dev This contract is entirely untrusted — it holds no persistent token balances and needs no authentication.
/// Tokens are transferred in, processed, and moved out within a single transaction.
/// The `externalLock` modifier allows self-calls (for multicall) but blocks external reentrancy.
contract Swapper {
    using SafeERC20Lib for IERC20;

    // --- Structs ---

    struct SwapParams {
        address tokenIn; // Token sold — approved to the swap target
        address tokenOut; // Token bought — approved to vault for repay/deposit
        address vault; // Vault for repay and deposit
        address account; // Account for debt queries and repay/deposit receiver
        uint256 targetDebt; // Target debt after repay. 0 = repay all debt.
        bytes data; // abi.encode(target, callData) for generic swap
    }

    // --- Reentrancy lock ---

    uint256 internal constant REENTRANCYLOCK_UNLOCKED = 1;
    uint256 internal constant REENTRANCYLOCK_LOCKED = 2;

    uint256 private reentrancyLock;

    /// @dev In the locked state, allow the contract to call itself (for multicall), but block all external calls
    modifier externalLock() {
        bool isExternal = msg.sender != address(this);

        if (isExternal) {
            if (reentrancyLock == REENTRANCYLOCK_LOCKED) revert Swapper_Reentrancy();
            reentrancyLock = REENTRANCYLOCK_LOCKED;
        }

        _;

        if (isExternal) reentrancyLock = REENTRANCYLOCK_UNLOCKED;
    }

    // --- Errors ---

    error Swapper_Reentrancy();
    error Swapper_SwapError(address target, bytes result);
    error Swapper_InsufficientBalance();
    error Swapper_TargetDebt();

    // ==========================
    // Core Swap Functions
    // ==========================

    /// @notice Execute an arbitrary swap with no post-processing.
    /// @dev Output tokens remain in the contract and must be handled separately
    /// (e.g., via multicall with deposit/sweep, or via an external batch step).
    /// @param tokenIn The token to approve to the swap target.
    /// @param data ABI-encoded tuple: (address target, bytes callData).
    function swapSimple(address tokenIn, bytes calldata data) public externalLock {
        _swapGeneric(tokenIn, data);
    }

    /// @notice Execute a swap then deposit the full output balance to a vault.
    /// @param params Swap parameters. The `targetDebt` field is ignored.
    function swapAndDeposit(SwapParams memory params) public externalLock {
        _swapGeneric(params.tokenIn, params.data);

        uint256 balance = IERC20(params.tokenOut).balanceOf(address(this));
        if (balance > 0) {
            _setMaxAllowance(params.tokenOut, params.vault);
            IVault(params.vault).deposit(balance, params.account);
        }
    }

    /// @notice Execute a swap then repay debt and deposit the remainder to a vault.
    /// @dev If `targetDebt` is 0, repays all debt. Otherwise repays `currentDebt - targetDebt`.
    /// @param params Swap parameters.
    function swapAndRepay(SwapParams memory params) public externalLock {
        // Resolve repay amount from target debt
        uint256 repayAmount;
        if (params.targetDebt == 0) {
            repayAmount = type(uint256).max;
        } else {
            uint256 debt = IVault(params.vault).debtOf(params.account);
            if (params.targetDebt > debt) revert Swapper_TargetDebt();
            unchecked {
                repayAmount = debt - params.targetDebt;
            }
        }

        _swapGeneric(params.tokenIn, params.data);

        _repayAndDeposit(params.tokenOut, params.vault, repayAmount, params.account);
    }

    // ==========================
    // Standalone Post-Swap Actions
    // ==========================

    /// @notice Deposit the contract's full token balance into a vault.
    /// @dev Reverts if balance < amountMin (slippage check).
    /// @param token Asset to deposit.
    /// @param vault Vault to deposit into.
    /// @param amountMin Minimum balance required. Reverts if not met.
    /// @param account Receiver of the vault shares.
    function deposit(address token, address vault, uint256 amountMin, address account) public externalLock {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < amountMin) revert Swapper_InsufficientBalance();
        if (balance == 0) return;

        _setMaxAllowance(token, vault);
        IVault(vault).deposit(balance, account);
    }

    /// @notice Repay debt using the contract's token balance.
    /// @dev Reverts if balance < amountMin (slippage check). Caps repayAmount to balance.
    /// @param token The borrowed asset.
    /// @param vault The lending vault where debt is tracked.
    /// @param repayAmount Amount of debt to repay. Use type(uint256).max to repay all.
    /// @param amountMin Minimum balance required. Reverts if not met.
    /// @param account Account whose debt is repaid.
    function repay(address token, address vault, uint256 repayAmount, uint256 amountMin, address account)
        public
        externalLock
    {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < amountMin) revert Swapper_InsufficientBalance();
        if (balance == 0) return;

        _setMaxAllowance(token, vault);
        repayAmount = _capRepayToBalance(repayAmount, balance);
        IVault(vault).repay(repayAmount, account);
    }

    /// @notice Repay debt then deposit the remainder into the same vault.
    /// @dev Reverts if balance < amountMin (slippage check). Caps repayAmount to balance.
    /// @param token The borrowed asset.
    /// @param vault The lending vault.
    /// @param repayAmount Amount of debt to repay. Use type(uint256).max to repay all.
    /// @param amountMin Minimum balance required. Reverts if not met.
    /// @param account Account whose debt is repaid and who receives deposit shares.
    function repayAndDeposit(address token, address vault, uint256 repayAmount, uint256 amountMin, address account)
        public
        externalLock
    {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < amountMin) revert Swapper_InsufficientBalance();
        if (balance == 0) return;

        _repayAndDeposit(token, vault, repayAmount, account);
    }

    /// @notice Transfer all of the contract's token balance to a recipient.
    /// @dev Reverts if balance < amountMin (slippage check).
    /// @param token Token to transfer.
    /// @param amountMin Minimum balance required. Reverts if not met.
    /// @param to Recipient address.
    function sweep(address token, uint256 amountMin, address to) public externalLock {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < amountMin) revert Swapper_InsufficientBalance();
        if (balance == 0) return;

        IERC20(token).safeTransfer(to, balance);
    }

    // ==========================
    // Multicall
    // ==========================

    /// @notice Call multiple functions on this contract in a single transaction.
    /// @dev Each call is executed via `address(this).call()`, which re-enters through `externalLock`
    /// as a self-call (allowed). Reverts bubble up from inner calls.
    /// @param calls Array of ABI-encoded function calls.
    function multicall(bytes[] memory calls) public externalLock {
        for (uint256 i; i < calls.length; i++) {
            (bool success, bytes memory result) = address(this).call(calls[i]);
            if (!success) {
                // Bubble up the revert reason
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }
        }
    }

    // ==========================
    // Internal Helpers
    // ==========================

    /// @dev Execute an arbitrary swap via the generic handler pattern.
    function _swapGeneric(address tokenIn, bytes memory data) internal {
        (address target, bytes memory payload) = abi.decode(data, (address, bytes));

        _setMaxAllowance(tokenIn, target);

        (bool success, bytes memory result) = target.call(payload);
        if (!success || (result.length == 0 && target.code.length == 0)) {
            revert Swapper_SwapError(target, result);
        }
    }

    /// @dev Repay debt then deposit any remaining balance into the same vault.
    function _repayAndDeposit(address token, address vault, uint256 repayAmount, address account) internal {
        _setMaxAllowance(token, vault);
        uint256 balance = IERC20(token).balanceOf(address(this));
        repayAmount = _capRepayToBalance(repayAmount, balance);

        repayAmount = IVault(vault).repay(repayAmount, account);

        if (balance > repayAmount) {
            IVault(vault).deposit(type(uint256).max, account);
        }
    }

    /// @dev Cap repay amount to the available balance.
    function _capRepayToBalance(uint256 repayAmount, uint256 balance) internal pure returns (uint256) {
        if (repayAmount != type(uint256).max && repayAmount > balance) {
            repayAmount = balance;
        }
        return repayAmount;
    }

    /// @dev Approve max allowance to spender, with USDT-safe retry (reset to 0 first if needed).
    function _setMaxAllowance(address token, address spender) internal {
        _safeApproveWithRetry(token, spender, type(uint256).max);
    }

    function _safeApproveWithRetry(address token, address spender, uint256 value) internal {
        (bool success,) = _trySafeApprove(token, spender, value);

        // Some tokens (e.g. USDT) require allowance to be set to 0 first
        if (!success) {
            (success,) = _trySafeApprove(token, spender, 0);
            if (success) {
                (success,) = _trySafeApprove(token, spender, value);
            }
        }

        if (!success) revert Swapper_SwapError(token, "");
    }

    function _trySafeApprove(address token, address spender, uint256 value)
        internal
        returns (bool, bytes memory)
    {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, value));
        return (success && (data.length == 0 || abi.decode(data, (bool))), data);
    }
}
