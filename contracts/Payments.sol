// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.24;

import {EVCUtil} from "ethereum-vault-connector/utils/EVCUtil.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";

import {IPayments} from "./interfaces/IPayments.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IPermit2} from "./interfaces/IPermit2.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {SafeERC20Lib} from "./lib/SafeERC20Lib.sol";

/// @title Payments
/// @notice EVC-authenticated payment pass-through contract.
/// Pulls ERC20 tokens from an authenticated sender and forwards them to a receiver.
/// Designed to be used in EVC batches for atomic multi-step flows (e.g., transfer + swap + deposit).
contract Payments is IPayments, EVCUtil {
    using SafeERC20Lib for IERC20;

    // --- Immutables ---

    address public immutable permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

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

    constructor(address _evc) EVCUtil(_evc) {}

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

        IERC20(token).safeTransferFrom(_msgSender(), receiver, amount, permit2);
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
    }

    /// @notice Pull WETH from authenticated sender, unwrap to ETH, send native ETH to receiver.
    /// @param weth The WETH contract address.
    /// @param receiver The recipient of the native ETH.
    /// @param amount The amount of WETH to unwrap.
    function unwrapAndTransfer(address weth, address receiver, uint256 amount) external callThroughEVC nonReentrant {
        _validateReceiver(receiver);
        _validateAmount(amount);

        // Pull WETH from sender to this contract
        IERC20(weth).safeTransferFrom(_msgSender(), address(this), amount, permit2);

        // Unwrap WETH -> ETH
        IWETH(weth).withdraw(amount);

        // Send native ETH to receiver
        _transferNativeETH(receiver, amount);
    }

    /// @notice Send native ETH (msg.value) directly to receiver.
    /// @param receiver The recipient of the native ETH.
    function transferNative(address receiver) external payable callThroughEVC nonReentrant {
        _validateReceiver(receiver);
        if (msg.value == 0) revert E_InvalidAmount();

        _transferNativeETH(receiver, msg.value);
    }

    // ==========================
    // Permit2 SignatureTransfer
    // ==========================

    /// @notice Pull a single token via Permit2 SignatureTransfer and forward to a recipient.
    /// @dev The token owner is resolved via `_msgSender()` (EVC-authenticated).
    /// @param permit The permit parameters (token, nonce, deadline).
    /// @param transferDetails Transfer instruction (recipient, amount).
    /// @param signature The EIP-712 signature from the authenticated sender.
    function permit2TransferFrom(
        IPermit2.PermitTransferFrom memory permit,
        IPermit2.SignatureTransferDetails calldata transferDetails,
        bytes calldata signature
    )
        external
        callThroughEVC
        nonReentrant
    {
        IPermit2(permit2).permitTransferFrom(permit, transferDetails, _msgSender(), signature);
    }

    /// @notice Pull tokens via Permit2 SignatureTransfer (batch) and forward to specified recipients.
    /// @dev The token owner is resolved via `_msgSender()` (EVC-authenticated).
    /// @param permit The batch permit parameters (tokens, nonce, deadline).
    /// @param transferDetails Per-token transfer instructions (recipient, amount).
    /// @param signature The EIP-712 signature from the authenticated sender.
    function permit2TransferFrom(
        IPermit2.PermitBatchTransferFrom memory permit,
        IPermit2.SignatureTransferDetails[] calldata transferDetails,
        bytes calldata signature
    )
        external
        callThroughEVC
        nonReentrant
    {
        IPermit2(permit2).permitTransferFrom(permit, transferDetails, _msgSender(), signature);
    }

    // ==========================
    // Internal Helpers
    // ==========================

    /// @dev Validate that the receiver is not address(0).
    function _validateReceiver(address receiver) internal pure {
        if (receiver == address(0)) revert E_InvalidReceiver();
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
