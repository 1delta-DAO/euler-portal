// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.0;

/// @title IPayments
/// @notice Interface for the Payments contract — an EVC-authenticated payment pass-through.
/// @dev Payments pulls ERC20 tokens from an EVC-authenticated sender and forwards them to a receiver.
/// It is stateless (no stored balances, no admin) and designed to be composed in EVC batches alongside
/// the Swapper for atomic multi-step flows (e.g., pull tokens → swap → deposit into vault).
///
/// All functions route through the EVC via `callThroughEVC`, meaning the sender is always resolved
/// as the EVC-authenticated account (owner or authorized operator), never raw `msg.sender`.
///
/// Transfer methods try Permit2 first, then fall back to standard `transferFrom`. This means the
/// sender can approve either this contract directly or the Permit2 contract.
///
/// Permit calls (`transferWithPermit`, `transferWithDaiPermit`, `transferWithPermit2`) use try/catch
/// so that front-running or pre-existing approvals do not revert the transaction.
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

    /// @notice Emitted on every successful ERC20 transfer (including permit variants).
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
    /// Typical usage in an EVC batch: pull tokens from the user to a Swapper or vault address.
    ///
    /// Reverts with `E_InvalidReceiver` if receiver is address(0) or a non-owner sub-account.
    /// Reverts with `E_InvalidAmount` if amount is 0.
    ///
    /// @param token The ERC20 token address to transfer.
    /// @param receiver The recipient address. Must not be address(0) or an EVC sub-account.
    /// @param amount The amount of tokens to transfer. Must be non-zero.
    function transfer(address token, address receiver, uint256 amount) external;

    // ==========================
    // Permit + Transfer
    // ==========================

    /// @notice Execute an ERC-2612 permit to grant this contract an allowance, then transfer tokens.
    /// @dev The permit call is wrapped in try/catch — if it fails (front-run, already approved, non-compliant
    /// token), the function still attempts the transfer using any existing allowance.
    ///
    /// Use this to enable gasless approvals: the user signs a permit off-chain, and the relayer
    /// submits the permit + transfer in a single EVC batch item.
    ///
    /// @param token The ERC20 token address. Must implement ERC-2612 `permit()`.
    /// @param receiver The recipient address.
    /// @param amount The amount to transfer (also used as the permit approval amount).
    /// @param deadline The permit signature deadline (block.timestamp must be <= deadline).
    /// @param v The recovery byte of the permit signature.
    /// @param r The first 32 bytes of the permit signature.
    /// @param s The second 32 bytes of the permit signature.
    function transferWithPermit(
        address token,
        address receiver,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /// @notice Execute a Dai-style permit, then transfer tokens.
    /// @dev Dai uses a different permit signature scheme: `(holder, spender, nonce, expiry, allowed)`
    /// instead of the standard ERC-2612 `(owner, spender, value, deadline)`.
    ///
    /// The permit call is wrapped in try/catch for the same resilience as `transferWithPermit`.
    ///
    /// @param token The Dai token address (or any token implementing the Dai permit interface).
    /// @param receiver The recipient address.
    /// @param amount The amount to transfer.
    /// @param nonce The Dai permit nonce for the sender.
    /// @param expiry The Dai permit expiry timestamp.
    /// @param allowed Whether to allow (true) or disallow (false) spending.
    /// @param v The recovery byte of the permit signature.
    /// @param r The first 32 bytes of the permit signature.
    /// @param s The second 32 bytes of the permit signature.
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
    ) external;

    /// @notice Execute a Permit2 signature-based permit, then transfer tokens.
    /// @dev Sets a Permit2 `AllowanceTransfer` allowance for this contract via the provided signature,
    /// then transfers via Permit2. If the Permit2 address is zero, skips the permit step and attempts
    /// a direct transfer.
    ///
    /// The permit call is wrapped in try/catch for the same resilience as `transferWithPermit`.
    ///
    /// @param token The ERC20 token address.
    /// @param receiver The recipient address.
    /// @param amount The amount to transfer.
    /// @param nonce The Permit2 nonce.
    /// @param deadline The Permit2 signature deadline.
    /// @param signature The Permit2 signature bytes (EIP-712 signed by the token owner).
    function transferWithPermit2(
        address token,
        address receiver,
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
    /// Typical usage: in an EVC batch, wrap user's native currency and send to the Swapper contract
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
    // View
    // ==========================

    /// @notice The Permit2 contract address used for Permit2-based transfers.
    /// @return The Permit2 contract address. May be address(0) if Permit2 is not configured.
    function permit2() external view returns (address);
}
