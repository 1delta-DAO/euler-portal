// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.24;

import {ISwapper} from "./interfaces/ISwapper.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {SafeERC20Lib} from "./lib/SafeERC20Lib.sol";
import {Erc20Lib} from "./lib/Erc20Lib.sol";

/// @title Swapper
/// @custom:security-contact security@euler.xyz
/// @author Euler Labs (https://www.eulerlabs.com/)
/// @notice Untrusted helper contract for executing arbitrary swaps via a generic handler
/// and composable post-swap actions (deposit, repay, sweep) with slippage checks.
/// @dev This contract is entirely untrusted — it holds no persistent token balances and needs no authentication.
/// Tokens are transferred in, processed, and moved out within a single transaction.
/// The `externalLock` modifier allows self-calls (for multicall) but blocks external reentrancy.
contract Swapper is ISwapper {
    using SafeERC20Lib for IERC20;
    using Erc20Lib for IERC20;

    // --- Reentrancy lock ---

    uint256 internal constant REENTRANCYLOCK_UNLOCKED = 1;
    uint256 internal constant REENTRANCYLOCK_LOCKED = 2;

    uint256 private reentrancyLock;

    /// @dev Tracks token+spender pairs that have already been max-approved, to skip redundant approve calls.
    mapping(address => mapping(address => bool)) private _approved;

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

    // ==========================
    // Core Swap Function
    // ==========================

    /// @notice Execute an arbitrary swap with no post-processing.
    /// @dev Output tokens remain in the contract and must be handled separately
    /// (e.g., via multicall with deposit/sweep, or via an external batch step).
    /// Caller must pre-approve tokenIn to the swap target via `approve()`.
    /// @param value Native currency value to forward to the swap target (0 for ERC20 swaps).
    /// @param data ABI-encoded tuple: (address target, bytes callData).
    function swapSimple(uint256 value, bytes calldata data) public payable externalLock {
        _swapGeneric(value, data);
    }

    // ==========================
    // Approval
    // ==========================

    /// @notice Max-approve a token for a spender and cache the result.
    /// @dev Use when the approval target differs from the swap router (e.g., a separate permit2 contract).
    /// Subsequent calls to internal approval helpers will skip the approve if already cached.
    /// @param token The token to approve.
    /// @param spender The address to approve for spending.
    function approve(address token, address spender) public {
        _setMaxAllowance(token, spender);
    }

    // ==========================
    // Native / Wrapped Native
    // ==========================

    /// @notice Wrap the contract's entire native currency balance into wrapped native (e.g., WETH, WBNB).
    /// @dev Payable so it works both standalone (`wrap{value: X}(wrappedNative)`) and inside multicall
    /// (native currency already in contract). Uses `address(this).balance`, never `msg.value`.
    /// @param wrappedNative The wrapped native token contract address (e.g., WETH, WBNB).
    function wrap(address wrappedNative) public payable externalLock {
        uint256 amount = address(this).balance;
        if (amount == 0) return;
        IWETH(wrappedNative).deposit{value: amount}();
    }

    /// @notice Unwrap wrapped native token to native currency.
    /// The native currency stays in the contract for subsequent sweepNative.
    /// @param wrappedNative The wrapped native token contract address.
    /// @param amount Amount to unwrap. Use type(uint256).max to unwrap all.
    function unwrap(address wrappedNative, uint256 amount) public externalLock {
        if (amount == type(uint256).max) {
            amount = IERC20(wrappedNative).balanceOf(address(this));
        }
        if (amount == 0) return;
        IWETH(wrappedNative).withdraw(amount);
    }

    /// @notice Send the contract's native currency balance to a recipient.
    /// @dev Reverts if balance < amountMin (slippage check).
    /// @param amountMin Minimum native balance required. Reverts if not met.
    /// @param to Recipient address.
    function sweepNative(uint256 amountMin, address to) public externalLock {
        uint256 balance = Erc20Lib.requireMin(address(this).balance, amountMin);
        if (balance == 0) return;
        (bool success,) = to.call{value: balance}("");
        if (!success) revert Swapper_NativeTransferFailed();
    }

    /// @dev Accept native currency. Required for wrapped native withdraw() and payable multicall.
    receive() external payable {}

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
        uint256 balance = IERC20(token).slippageCheck(address(this), amountMin);
        if (balance == 0) return;

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
        uint256 balance = IERC20(token).slippageCheck(address(this), amountMin);
        if (balance == 0) return;

        repayAmount = _capRepay(repayAmount, balance, IVault(vault).debtOf(account));
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
        uint256 balance = IERC20(token).slippageCheck(address(this), amountMin);
        if (balance == 0) return;

        _repayAndDeposit(token, vault, repayAmount, account);
    }

    /// @notice Transfer all of the contract's token balance to a recipient.
    /// @dev Reverts if balance < amountMin (slippage check).
    /// @param token Token to transfer.
    /// @param amountMin Minimum balance required. Reverts if not met.
    /// @param to Recipient address.
    function sweep(address token, uint256 amountMin, address to) public externalLock {
        uint256 balance = IERC20(token).slippageCheck(address(this), amountMin);
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
    function multicall(bytes[] memory calls) public payable externalLock {
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
    /// Forwards `value` as native currency to the swap target.
    function _swapGeneric(uint256 value, bytes memory data) internal {
        (address target, bytes memory payload) = abi.decode(data, (address, bytes));

        (bool success, bytes memory result) = target.call{value: value}(payload);
        if (!success || (result.length == 0 && target.code.length == 0)) {
            revert Swapper_SwapError(target, result);
        }
    }

    /// @dev Repay debt then deposit any remaining balance into the same vault.
    function _repayAndDeposit(address token, address vault, uint256 repayAmount, address account) internal {
        uint256 balance = IERC20(token).balanceOf(address(this));
        repayAmount = _capRepay(repayAmount, balance, IVault(vault).debtOf(account));

        repayAmount = IVault(vault).repay(repayAmount, account);

        if (balance > repayAmount) {
            IVault(vault).deposit(type(uint256).max, account);
        }
    }

    /// @dev Cap repay amount to the minimum of the available balance and the outstanding debt.
    /// Passes through type(uint256).max unchanged — the vault resolves it to the full debt.
    function _capRepay(uint256 repayAmount, uint256 balance, uint256 debt) internal pure returns (uint256) {
        if (repayAmount == type(uint256).max) return repayAmount;
        if (repayAmount > debt) repayAmount = debt;
        if (repayAmount > balance) repayAmount = balance;
        return repayAmount;
    }

    /// @dev Approve max allowance to spender, with USDT-safe retry (reset to 0 first if needed). Cached per token+spender.
    function _setMaxAllowance(address token, address spender) internal {
        if (_approved[token][spender]) return;

        if (!Erc20Lib.trySafeApproveWithRetry(IERC20(token), spender, type(uint256).max)) {
            revert Swapper_SwapError(token, "");
        }
        _approved[token][spender] = true;
    }
}
