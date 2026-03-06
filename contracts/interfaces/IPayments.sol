// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.0;

import {IPermit2} from "./IPermit2.sol";

/// @title IPayments
/// @notice Interface for the Payments contract — an EVC-authenticated payment pass-through.
/// @dev Payments pulls ERC20 tokens from an EVC-authenticated sender and forwards them to a receiver.
/// It is stateless (no stored balances, no admin) and designed to be composed in EVC batches alongside
/// the Orchestrator for atomic multi-step flows (e.g., pull tokens → swap → deposit into vault).
///
/// Transfer functions route through the EVC via `callThroughEVC`, meaning the sender is always resolved
/// as the EVC-authenticated account (owner or authorized operator), never raw `msg.sender`.
///
/// Transfer methods try Permit2 first, then fall back to standard `transferFrom`. This means the
/// sender can approve either this contract directly or the Permit2 contract.
///
/// Receiver validation rejects `address(0)`.
interface IPayments {
    // --- Errors ---

    /// @notice Thrown when the receiver is address(0).
    error E_InvalidReceiver();

    /// @notice Thrown when the transfer amount is zero.
    error E_InvalidAmount();

    /// @notice Thrown when a native currency transfer to a recipient fails (recipient rejected or out of gas).
    error E_NativeTransferFailed();

    /// @notice Thrown when msg.value is less than the requested wrap amount in `wrapAndTransfer`.
    error E_InsufficientMsgValue();

    // ==========================
    // Core Transfer
    // ==========================

    /// @notice Transfer ERC20 tokens from the authenticated sender to a receiver.
    /// @dev Tries Permit2 first, falls back to standard `transferFrom`. The sender must have approved
    /// either this contract or the Permit2 contract to spend the token.
    ///
    /// Typical usage in an EVC batch: pull tokens from the user to a Orchestrator or vault address.
    ///
    /// Reverts with `E_InvalidReceiver` if receiver is address(0).
    /// Reverts with `E_InvalidAmount` if amount is 0.
    ///
    /// @param token The ERC20 token address to transfer.
    /// @param receiver The recipient address. Must not be address(0).
    /// @param amount The amount of tokens to transfer. Must be non-zero.
    function transfer(address token, address receiver, uint256 amount) external;

    // ==========================
    // Native Currency / Wrapped Native
    // ==========================

    /// @notice Wrap native currency (ETH, BNB, etc.) into its wrapped ERC20 form and transfer to receiver.
    /// @dev Wraps exactly `amount` of native currency into WETH/WBNB and sends the wrapped tokens to
    /// the receiver. Any excess `msg.value` beyond `amount` is refunded to the authenticated sender.
    ///
    /// Typical usage: in an EVC batch, wrap user's native currency and send to the Orchestrator contract
    /// so it can be used in a swap.
    ///
    /// Reverts with `E_InsufficientMsgValue` if `msg.value < amount`.
    ///
    /// @param weth The wrapped native token contract address (e.g., WETH on Ethereum, WBNB on BSC).
    /// @param receiver The recipient of the wrapped native tokens.
    /// @param amount The exact amount of native currency to wrap. Must be <= msg.value.
    function wrapAndTransfer(address weth, address receiver, uint256 amount) external payable;

    /// @notice Pull wrapped native tokens from the authenticated sender, unwrap to native currency,
    /// and send the native currency to the receiver.
    /// @dev The sender must have approved this contract (or Permit2) to spend the wrapped native token.
    /// Pulls WETH from sender → unwraps to native → sends native to receiver.
    ///
    /// @param weth The wrapped native token contract address.
    /// @param receiver The recipient of the native currency.
    /// @param amount The amount of wrapped native tokens to pull, unwrap, and send.
    function unwrapAndTransfer(address weth, address receiver, uint256 amount) external;

    /// @notice Forward the full msg.value as native currency to a receiver.
    /// @dev Simple native currency forwarding. The entire msg.value is sent to the receiver.
    ///
    /// Reverts with `E_InvalidAmount` if msg.value is 0.
    /// Reverts with `E_NativeTransferFailed` if the recipient rejects the transfer.
    ///
    /// @param receiver The recipient of the native currency.
    function transferNative(address receiver) external payable;

    // ==========================
    // Permit2 SignatureTransfer
    // ==========================

    /// @notice Pull a single token via Permit2 SignatureTransfer and forward to a recipient.
    /// @dev The user signs an off-chain EIP-712 signature authorising the transfer of a single token.
    /// The token owner is resolved via `_msgSender()` (EVC-authenticated).
    /// @param permit The permit parameters (token, nonce, deadline).
    /// @param transferDetails Transfer instruction (recipient, amount).
    /// @param signature The EIP-712 signature from the authenticated sender.
    function permit2TransferFrom(
        IPermit2.PermitTransferFrom memory permit,
        IPermit2.SignatureTransferDetails calldata transferDetails,
        bytes calldata signature
    )
        external;

    /// @notice Pull tokens via Permit2 SignatureTransfer (batch) and forward to specified recipients.
    /// @dev The user signs a single off-chain EIP-712 signature authorising the transfer of multiple tokens.
    /// Each `transferDetails` entry specifies a recipient and amount.
    ///
    /// The token owner is resolved via `_msgSender()` (EVC-authenticated), consistent with other
    /// transfer functions. The Permit2 signature must be from the authenticated sender.
    ///
    /// @param permit The batch permit parameters (tokens, nonce, deadline).
    /// @param transferDetails Per-token transfer instructions (recipient, amount).
    /// @param signature The EIP-712 signature from the authenticated sender.
    function permit2TransferFrom(
        IPermit2.PermitBatchTransferFrom memory permit,
        IPermit2.SignatureTransferDetails[] calldata transferDetails,
        bytes calldata signature
    )
        external;

    // ==========================
    // View
    // ==========================

    /// @notice The Permit2 contract address used for Permit2-based transfers.
    /// @return The Permit2 contract address. May be address(0) if Permit2 is not configured.
    function permit2() external view returns (address);
}
