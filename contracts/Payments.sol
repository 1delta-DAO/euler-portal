// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.24;

import {EVCUtil} from "ethereum-vault-connector/utils/EVCUtil.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";

import {IPayments} from "./interfaces/IPayments.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IPermit2} from "./interfaces/IPermit2.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IERC20Permit} from "./interfaces/IERC20Permit.sol";
import {IDaiPermit} from "./interfaces/IDaiPermit.sol";
import {SafeERC20Lib} from "./lib/SafeERC20Lib.sol";

/// @title Payments
/// @notice EVC-authenticated payment pass-through contract.
/// Pulls ERC20 tokens from an authenticated sender and forwards them to a receiver.
/// Supports ERC-2612 permits, Dai permits, Permit2 signature permits, and WETH wrap/unwrap flows.
/// Designed to be used in EVC batches for atomic multi-step flows (e.g., transfer + swap + deposit).
contract Payments is IPayments, EVCUtil {
    using SafeERC20Lib for IERC20;

    // --- Immutables ---

    address public immutable permit2;

    // --- Reentrancy guard ---

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _reentrancyStatus = _NOT_ENTERED;

    error ReentrancyGuardReentrantCall();

    modifier nonReentrant() {
        if (_reentrancyStatus == _ENTERED) revert ReentrancyGuardReentrantCall();
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    // --- Constructor ---

    constructor(address _evc, address _permit2) EVCUtil(_evc) {
        permit2 = _permit2;
    }

    // --- Receive ---

    /// @dev Required to receive ETH from WETH.withdraw()
    receive() external payable {}

    // ==========================
    // Core Transfer
    // ==========================

    /// @notice Transfer ERC20 tokens from the authenticated sender to a receiver.
    /// @dev The sender must have approved this contract (or Permit2) to spend the token.
    /// @param token The ERC20 token address.
    /// @param receiver The recipient address.
    /// @param amount The amount to transfer.
    function transfer(address token, address receiver, uint256 amount) external callThroughEVC nonReentrant {
        _validateReceiver(receiver);
        _validateAmount(amount);

        address sender = _msgSender();
        IERC20(token).safeTransferFrom(sender, receiver, amount, permit2);

        emit Transfer(token, sender, receiver, amount);
    }

    // ==========================
    // Permit + Transfer
    // ==========================

    /// @notice Execute an ERC-2612 permit, then transfer tokens.
    /// @dev The permit grants this contract an allowance, then the transfer executes immediately.
    ///      Uses try/catch on the permit call to handle front-running or pre-existing approvals gracefully.
    /// @param token The ERC20 token (must implement ERC-2612).
    /// @param receiver The recipient address.
    /// @param amount The amount to transfer.
    /// @param deadline Permit deadline.
    /// @param v Signature v component.
    /// @param r Signature r component.
    /// @param s Signature s component.
    function transferWithPermit(
        address token,
        address receiver,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        callThroughEVC
        nonReentrant
    {
        _validateReceiver(receiver);
        _validateAmount(amount);

        address sender = _msgSender();

        // Execute the ERC-2612 permit: owner approves this contract.
        // try/catch so a front-run or pre-existing approval doesn't revert the whole tx.
        try IERC20Permit(token).permit(sender, address(this), amount, deadline, v, r, s) {} catch {}

        IERC20(token).safeTransferFrom(sender, receiver, amount, permit2);

        emit Transfer(token, sender, receiver, amount);
    }

    /// @notice Execute a Dai-style permit, then transfer tokens.
    /// @dev Dai permits use a different signature scheme (nonce, expiry, allowed) instead of (value, deadline).
    /// @param token The Dai token address.
    /// @param receiver The recipient address.
    /// @param amount The amount to transfer.
    /// @param nonce The Dai permit nonce.
    /// @param expiry The Dai permit expiry.
    /// @param allowed Whether to allow or disallow.
    /// @param v Signature v component.
    /// @param r Signature r component.
    /// @param s Signature s component.
    function transferWithDaiPermit(
        address token,
        address receiver,
        uint256 amount,
        uint256 nonce,
        uint256 expiry,
        bool allowed,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        callThroughEVC
        nonReentrant
    {
        _validateReceiver(receiver);
        _validateAmount(amount);

        address sender = _msgSender();

        // Execute the Dai-style permit: holder approves this contract.
        try IDaiPermit(token).permit(sender, address(this), nonce, expiry, allowed, v, r, s) {} catch {}

        IERC20(token).safeTransferFrom(sender, receiver, amount, permit2);

        emit Transfer(token, sender, receiver, amount);
    }

    /// @notice Execute a Permit2 signature-based permit, then transfer tokens.
    /// @dev First sets a Permit2 allowance for this contract via signature, then transfers via Permit2.
    /// @param token The ERC20 token address.
    /// @param receiver The recipient address.
    /// @param amount The amount to transfer.
    /// @param nonce Permit2 nonce.
    /// @param deadline Permit2 deadline.
    /// @param signature The Permit2 signature bytes.
    function transferWithPermit2(
        address token,
        address receiver,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    )
        external
        callThroughEVC
        nonReentrant
    {
        _validateReceiver(receiver);
        _validateAmount(amount);

        address sender = _msgSender();

        // Execute Permit2 AllowanceTransfer.permit to set allowance for this contract.
        if (permit2 != address(0)) {
            IPermit2.PermitSingle memory permitSingle = IPermit2.PermitSingle({
                details: IPermit2.PermitDetails({
                    token: token, amount: uint160(amount), expiration: uint48(deadline), nonce: uint48(nonce)
                }),
                spender: address(this),
                sigDeadline: deadline
            });
            try IPermit2(permit2).permit(sender, permitSingle, signature) {} catch {}
        }

        IERC20(token).safeTransferFrom(sender, receiver, amount, permit2);

        emit Transfer(token, sender, receiver, amount);
    }

    // ==========================
    // Native ETH / WETH
    // ==========================

    /// @notice Wrap sent ETH into WETH and transfer WETH to receiver.
    /// @param weth The WETH contract address.
    /// @param receiver The recipient of the WETH.
    /// @param amount The amount of ETH to wrap (must be <= msg.value).
    function wrapAndTransfer(address weth, address receiver, uint256 amount) external payable callThroughEVC nonReentrant {
        _validateReceiver(receiver);
        _validateAmount(amount);
        if (msg.value < amount) revert E_InsufficientMsgValue();

        IWETH(weth).deposit{value: amount}();
        IWETH(weth).transfer(receiver, amount);

        // Refund excess ETH
        uint256 excess = msg.value - amount;
        if (excess > 0) {
            _transferNativeETH(_msgSender(), excess);
        }

        emit WrapAndTransfer(weth, _msgSender(), receiver, amount);
    }

    /// @notice Pull WETH from authenticated sender, unwrap to ETH, send native ETH to receiver.
    /// @param weth The WETH contract address.
    /// @param receiver The recipient of the native ETH.
    /// @param amount The amount of WETH to unwrap.
    function unwrapAndTransfer(address weth, address receiver, uint256 amount) external callThroughEVC nonReentrant {
        _validateReceiver(receiver);
        _validateAmount(amount);

        address sender = _msgSender();

        // Pull WETH from sender to this contract
        IERC20(weth).safeTransferFrom(sender, address(this), amount, permit2);

        // Unwrap WETH -> ETH
        IWETH(weth).withdraw(amount);

        // Send native ETH to receiver
        _transferNativeETH(receiver, amount);

        emit UnwrapAndTransfer(weth, sender, receiver, amount);
    }

    /// @notice Send native ETH (msg.value) directly to receiver.
    /// @param receiver The recipient of the native ETH.
    function transferNative(address receiver) external payable callThroughEVC nonReentrant {
        _validateReceiver(receiver);
        if (msg.value == 0) revert E_InvalidAmount();

        _transferNativeETH(receiver, msg.value);

        emit NativeTransfer(_msgSender(), receiver, msg.value);
    }

    // ==========================
    // Internal Helpers
    // ==========================

    /// @dev Validate that the receiver is not address(0) and not a known EVC non-owner sub-account.
    function _validateReceiver(address receiver) internal view {
        if (receiver == address(0)) revert E_InvalidReceiver();

        // Prevent sending tokens to EVC sub-accounts whose private keys are unknown.
        // Same pattern as EVK's pushAssets: if EVC recognizes an owner for this address
        // and that owner differs from the address itself, it's a sub-account.
        address owner = evc.getAccountOwner(receiver);
        if (owner != address(0) && owner != receiver) {
            revert E_InvalidReceiver();
        }
    }

    /// @dev Validate that the amount is non-zero.
    function _validateAmount(uint256 amount) internal pure {
        if (amount == 0) revert E_InvalidAmount();
    }

    /// @dev Transfer native ETH to a recipient. Reverts on failure.
    function _transferNativeETH(address to, uint256 amount) internal {
        (bool success,) = to.call{value: amount}("");
        if (!success) revert E_NativeTransferFailed();
    }
}
