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
/// Standalone permit utilities (`permit`, `permitDai`, `permit2Permit`) set allowances without
/// transferring tokens. They are unauthenticated — the signature is the authorization. Designed
/// to be composed as a preceding batch item before `transfer()`.
///
/// Transfer methods try Permit2 first, then fall back to standard `transferFrom`. This means the
/// sender can approve either this contract directly or the Permit2 contract.
///
/// Permit calls use try/catch so that front-running or pre-existing approvals do not revert the batch.
///
/// Receiver validation rejects `address(0)` and EVC sub-accounts whose private keys are unknown,
/// preventing tokens from being permanently locked.
interface IPayments {
    // --- Errors ---

    /// @notice Thrown when the receiver is address(0) or a non-owner EVC sub-account.
    error E_InvalidReceiver();

    /// @notice Thrown when the transfer amount is zero.
    error E_InvalidAmount();

    /// @notice Thrown when a native currency transfer to a recipient fails (recipient rejected or out of gas).
    error E_NativeTransferFailed();

    /// @notice Thrown when msg.value is less than the requested wrap amount in `wrapAndTransfer`.
    error E_InsufficientMsgValue();

    // --- Events ---

    /// @notice Emitted on every successful ERC20 transfer.
    /// @param token The ERC20 token transferred.
    /// @param from The authenticated sender whose tokens were pulled.
    /// @param receiver The recipient who received the tokens.
    /// @param amount The amount transferred.
    event Transfer(address indexed token, address indexed from, address indexed receiver, uint256 amount);

    /// @notice Emitted when native currency is forwarded via `transferNative`.
    /// @param from The authenticated sender.
    /// @param receiver The recipient who received the native currency.
    /// @param amount The amount of native currency sent (equals msg.value).
    event NativeTransfer(address indexed from, address indexed receiver, uint256 amount);

    /// @notice Emitted when native currency is wrapped to WETH and transferred via `wrapAndTransfer`.
    /// @param weth The wrapped native token contract used.
    /// @param from The authenticated sender who provided the native currency.
    /// @param receiver The recipient who received the wrapped native tokens.
    /// @param amount The amount wrapped and transferred.
    event WrapAndTransfer(address indexed weth, address indexed from, address indexed receiver, uint256 amount);

    /// @notice Emitted when WETH is pulled, unwrapped, and sent as native currency via `unwrapAndTransfer`.
    /// @param weth The wrapped native token contract used.
    /// @param from The authenticated sender whose WETH was pulled.
    /// @param receiver The recipient who received native currency.
    /// @param amount The amount unwrapped and transferred.
    event UnwrapAndTransfer(address indexed weth, address indexed from, address indexed receiver, uint256 amount);

    // ==========================
    // Core Transfer
    // ==========================

    /// @notice Transfer ERC20 tokens from the authenticated sender to a receiver.
    /// @dev Tries Permit2 first, falls back to standard `transferFrom`. The sender must have approved
    /// either this contract or the Permit2 contract to spend the token.
    ///
    /// Typical usage in an EVC batch: pull tokens from the user to a Orchestrator or vault address.
    ///
    /// Reverts with `E_InvalidReceiver` if receiver is address(0) or a non-owner sub-account.
    /// Reverts with `E_InvalidAmount` if amount is 0.
    ///
    /// @param token The ERC20 token address to transfer.
    /// @param receiver The recipient address. Must not be address(0) or an EVC sub-account.
    /// @param amount The amount of tokens to transfer. Must be non-zero.
    function transfer(address token, address receiver, uint256 amount) external;

    // ==========================
    // Permit Utilities
    // ==========================

    /// @notice Execute an ERC-2612 permit to grant this contract an allowance.
    /// @dev The permit call is wrapped in try/catch — if it fails (front-run, already approved,
    /// non-compliant token), the function silently succeeds so that a subsequent `transfer()` in
    /// the same EVC batch can proceed using any existing allowance.
    ///
    /// This function is unauthenticated — the permit signature is the authorization.
    /// The spender is always `address(this)`.
    ///
    /// @param token The ERC20 token address. Must implement ERC-2612 `permit()`.
    /// @param owner The token owner who signed the permit.
    /// @param amount The approval amount.
    /// @param deadline The permit signature deadline.
    /// @param v The recovery byte of the permit signature.
    /// @param r The first 32 bytes of the permit signature.
    /// @param s The second 32 bytes of the permit signature.
    function permit(
        address token,
        address owner,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /// @notice Execute a Dai-style permit to grant this contract an allowance.
    /// @dev Same try/catch resilience as `permit()`. The spender is always `address(this)`.
    ///
    /// @param token The Dai token address (or any token implementing the Dai permit interface).
    /// @param owner The token owner who signed the permit.
    /// @param nonce The Dai permit nonce.
    /// @param expiry The Dai permit expiry timestamp.
    /// @param allowed Whether to allow (true) or disallow (false) spending.
    /// @param v The recovery byte of the permit signature.
    /// @param r The first 32 bytes of the permit signature.
    /// @param s The second 32 bytes of the permit signature.
    function permitDai(
        address token,
        address owner,
        uint256 nonce,
        uint256 expiry,
        bool allowed,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /// @notice Execute a Permit2 AllowanceTransfer permit to grant this contract a Permit2 allowance.
    /// @dev Same try/catch resilience as `permit()`. The spender is always `address(this)`.
    ///
    /// @param token The ERC20 token address.
    /// @param owner The token owner who signed the Permit2 permit.
    /// @param amount The allowance amount.
    /// @param nonce The Permit2 nonce.
    /// @param deadline The Permit2 signature deadline.
    /// @param signature The Permit2 signature bytes.
    function permit2Permit(
        address token,
        address owner,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external;

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
    // Permit2 Batch Transfer
    // ==========================

    /// @notice Pull tokens via Permit2 SignatureTransfer (batch) and forward to specified recipients.
    /// @dev The user signs a single off-chain EIP-712 signature authorising the transfer of multiple tokens.
    /// Each `transferDetails` entry specifies a recipient and amount. Uses the contract's hard-coded
    /// Permit2 address.
    ///
    /// The token owner is resolved via `_msgSender()` (EVC-authenticated), consistent with other
    /// transfer functions. The Permit2 signature must be from the authenticated sender.
    ///
    /// This enables batch token pulls in a single EVC batch item — e.g., pull USDC + WETH to an
    /// Orchestrator in one step, then swap and deposit in the next.
    ///
    /// @param permit The batch permit parameters (tokens, nonce, deadline).
    /// @param transferDetails Per-token transfer instructions (recipient, amount).
    /// @param signature The EIP-712 signature from the authenticated sender.
    function permit2TransferFrom(
        IPermit2.PermitBatchTransferFrom memory permit,
        IPermit2.SignatureTransferDetails[] calldata transferDetails,
        bytes calldata signature
    ) external;

    // ==========================
    // View
    // ==========================

    /// @notice The Permit2 contract address used for Permit2-based transfers.
    /// @return The Permit2 contract address. May be address(0) if Permit2 is not configured.
    function permit2() external view returns (address);
}
