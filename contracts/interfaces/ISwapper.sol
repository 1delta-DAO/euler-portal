// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.0;

/// @title ISwapper
/// @notice Interface for the Swapper contract — an untrusted helper for executing arbitrary swaps
/// via a generic handler and composable post-swap actions (deposit, repay, sweep) with slippage checks.
/// @dev The Swapper is entirely untrusted — it holds no persistent token balances and needs no authentication.
/// Tokens are transferred in (via Payments, vault.withdraw, vault.borrow, or direct transfer), processed
/// through a DEX swap, and moved out (via deposit, repay, sweep) within a single transaction.
///
/// **Generic handler pattern**: Swap data is `abi.encode(target, payload)`. The Swapper calls
/// `target.call{value: value}(payload)`. This works with any DEX router or aggregator without requiring
/// protocol-specific handler code.
///
/// **Explicit approvals**: The Swapper does NOT auto-approve tokens. Callers must compose `approve()` calls
/// in their multicall sequence before operations that require spending (swaps, vault deposits, vault repays).
/// Approvals are cached per token+spender pair — once approved, subsequent calls are no-ops.
///
/// **Native currency**: Swap functions accept a `value` parameter — the native currency amount forwarded
/// to the swap target. This is drawn from `address(this).balance`, NOT `msg.value`, to prevent double-spend
/// in multicall. Use `wrap`/`unwrap`/`sweepNative` for native currency conversion.
///
/// **Composability**: All functions can be combined via `multicall` for complex flows. For cross-contract
/// orchestration (e.g., Payments pull + Swapper swap), use EVC batches where each batch item is an
/// external call and multicall handles Swapper-internal composition.
///
/// **Reentrancy**: The `externalLock` modifier blocks external reentrancy but allows self-calls,
/// which is required for multicall to invoke other Swapper functions.
interface ISwapper {
    // --- Errors ---

    /// @notice Thrown when an external caller attempts to enter while the reentrancy lock is held.
    /// Self-calls (from multicall) are allowed.
    error Swapper_Reentrancy();

    /// @notice Thrown when the swap target call fails or the target has no code.
    /// @param target The address that was called.
    /// @param result The revert data returned by the failed call (empty if target has no code).
    error Swapper_SwapError(address target, bytes result);

    /// @notice Thrown when the contract's token or native balance is below the required minimum (slippage check).
    /// Applies to: deposit, repay, repayAndDeposit, sweep, sweepNative.
    error Swapper_InsufficientBalance();

    /// @notice Thrown when a native currency transfer to a recipient fails (recipient rejected or out of gas).
    /// Applies to: sweepNative.
    error Swapper_NativeTransferFailed();

    // ==========================
    // Core Swap Function
    // ==========================

    /// @notice Execute an arbitrary swap with no post-processing.
    /// @dev Output tokens remain in the contract and must be handled separately — either via subsequent
    /// multicall steps (deposit, sweep, etc.) or via a separate EVC batch item.
    ///
    /// The caller must ensure the swap target has been approved to spend the input token via `approve()`.
    ///
    /// For ERC20 swaps, set `value = 0`. The swap target pulls tokens from the Swapper via the
    /// pre-configured allowance.
    ///
    /// For native currency swaps, set `value` to the native amount to forward. The swap target receives
    /// native currency via `target.call{value: value}(payload)`. No token approval is needed.
    ///
    /// @param value Native currency amount to forward to the swap target. Set to 0 for ERC20 swaps.
    ///        Drawn from `address(this).balance`, not `msg.value`.
    /// @param data ABI-encoded swap instruction: `abi.encode(address target, bytes callData)`.
    function swapSimple(uint256 value, bytes calldata data) external payable;

    // ==========================
    // Approval
    // ==========================

    /// @notice Max-approve a token for a spender, with result caching.
    /// @dev Sets `type(uint256).max` allowance from this contract to the spender. The approval is cached
    /// in storage — subsequent calls for the same token+spender pair are no-ops (zero gas overhead).
    ///
    /// Uses USDT-safe approve-with-retry: if the initial approve fails (e.g., USDT requires resetting
    /// allowance to 0 first), it automatically resets to 0 and retries.
    ///
    /// **This must be called before any operation where an external contract pulls tokens from the Swapper:**
    /// - Before `swapSimple`: approve the DEX router to spend tokenIn.
    /// - Before `deposit` / `repay` / `repayAndDeposit`: approve the vault to spend the token.
    ///
    /// Typical usage in multicall:
    /// ```
    /// calls[0] = abi.encodeCall(ISwapper.approve, (tokenIn, router));
    /// calls[1] = abi.encodeCall(ISwapper.approve, (tokenOut, vault));
    /// calls[2] = abi.encodeCall(ISwapper.swapSimple, (0, swapData));
    /// calls[3] = abi.encodeCall(ISwapper.deposit, (tokenOut, vault, minOut, account));
    /// ```
    ///
    /// @param token The ERC20 token to approve.
    /// @param spender The address to grant spending allowance to (e.g., DEX router, vault).
    function approve(address token, address spender) external;

    // ==========================
    // Native Currency / Wrapped Native
    // ==========================

    /// @notice Wrap the contract's entire native currency balance into a wrapped native token (e.g., WETH, WBNB).
    /// @dev Wraps `address(this).balance` — never `msg.value` — making it safe inside multicall where
    /// `msg.value` is the same for all sub-calls. If the balance is zero, this is a no-op (no revert).
    ///
    /// Payable so it works both standalone (`wrap{value: X}(wrappedNative)`) and inside a multicall
    /// where native currency was already deposited to the contract.
    ///
    /// @param wrappedNative The wrapped native token contract address (e.g., WETH on Ethereum, WBNB on BSC).
    function wrap(address wrappedNative) external payable;

    /// @notice Unwrap a wrapped native token back to native currency.
    /// @dev The native currency remains in the contract after unwrapping — use `sweepNative` to send it
    /// to a recipient. If the resolved amount is zero, this is a no-op (no revert).
    ///
    /// @param wrappedNative The wrapped native token contract address.
    /// @param amount The amount of wrapped native tokens to unwrap. Use `type(uint256).max` to unwrap
    ///        the contract's entire wrapped native balance.
    function unwrap(address wrappedNative, uint256 amount) external;

    /// @notice Send the contract's entire native currency balance to a recipient.
    /// @dev Acts as the native currency equivalent of `sweep`. Includes a slippage check: reverts with
    /// `Swapper_InsufficientBalance` if the balance is below `amountMin`. If the balance is zero
    /// (and amountMin is 0), this is a no-op.
    ///
    /// Reverts with `Swapper_NativeTransferFailed` if the recipient rejects the transfer (e.g., a
    /// contract without a receive/fallback function or one that reverts).
    ///
    /// @param amountMin Minimum native balance required. Reverts if `address(this).balance < amountMin`.
    ///        Set to 0 to skip the slippage check.
    /// @param to Recipient address for the native currency.
    function sweepNative(uint256 amountMin, address to) external;

    // ==========================
    // Standalone Post-Swap Actions
    // ==========================

    /// @notice Deposit the contract's full token balance into an Euler vault.
    /// @dev Queries `token.balanceOf(address(this))` and deposits the entire amount into the vault
    /// on behalf of `account`. The vault must have been pre-approved via `approve(token, vault)`.
    ///
    /// Includes a slippage check: reverts with `Swapper_InsufficientBalance` if balance < amountMin.
    /// If balance is zero (and amountMin is 0), this is a no-op.
    ///
    /// This function deposits the FULL balance, including any tokens that were already in the contract
    /// from prior batch items (e.g., Payments.transfer). This is by design for the zap flow where
    /// user-provided collateral and swap output are deposited together.
    ///
    /// @param token The ERC20 token to deposit.
    /// @param vault The Euler vault to deposit into.
    /// @param amountMin Minimum balance required. Set to 0 to skip the slippage check.
    /// @param account The account that receives the vault shares.
    function deposit(address token, address vault, uint256 amountMin, address account) external;

    /// @notice Repay debt on an Euler vault using the contract's token balance.
    /// @dev Queries `token.balanceOf(address(this))` and repays up to `repayAmount` of debt for `account`.
    /// The vault must have been pre-approved via `approve(token, vault)`.
    ///
    /// The repay amount is capped to the minimum of the available balance and the outstanding debt
    /// (queried via `vault.debtOf(account)`). This prevents vault-level reverts when the caller
    /// overestimates the repay amount. Use `type(uint256).max` to repay all debt — it is passed
    /// through to the vault which resolves it to the exact outstanding amount.
    ///
    /// Includes a slippage check: reverts with `Swapper_InsufficientBalance` if balance < amountMin.
    ///
    /// @param token The borrowed asset (same as the vault's underlying).
    /// @param vault The Euler lending vault where debt is tracked.
    /// @param repayAmount Amount of debt to repay. Use `type(uint256).max` to repay all outstanding debt.
    /// @param amountMin Minimum balance required. Set to 0 to skip the slippage check.
    /// @param account The account whose debt is being repaid.
    function repay(address token, address vault, uint256 repayAmount, uint256 amountMin, address account) external;

    /// @notice Repay debt then deposit the remaining balance into the same vault.
    /// @dev Combines repay + deposit in a single call. After repaying, any leftover token balance is
    /// deposited into the same vault on behalf of the same account.
    ///
    /// This is useful when the swap output exceeds the debt — the surplus is automatically deposited
    /// as collateral rather than being left in the contract.
    ///
    /// The vault must have been pre-approved via `approve(token, vault)` (covers both repay and deposit).
    ///
    /// @param token The borrowed/deposited asset.
    /// @param vault The Euler vault for both repay and deposit.
    /// @param repayAmount Amount of debt to repay. Use `type(uint256).max` to repay all.
    /// @param amountMin Minimum balance required. Set to 0 to skip the slippage check.
    /// @param account The account whose debt is repaid and who receives deposit shares.
    function repayAndDeposit(
        address token,
        address vault,
        uint256 repayAmount,
        uint256 amountMin,
        address account
    ) external;

    /// @notice Transfer the contract's full ERC20 token balance to a recipient.
    /// @dev Sends the entire `token.balanceOf(address(this))` to `to`. Use this to extract swap output
    /// when the output should go directly to the user rather than into a vault.
    ///
    /// Includes a slippage check: reverts with `Swapper_InsufficientBalance` if balance < amountMin.
    /// If balance is zero (and amountMin is 0), this is a no-op.
    ///
    /// @param token The ERC20 token to transfer.
    /// @param amountMin Minimum balance required. Set to 0 to skip the slippage check.
    /// @param to Recipient address.
    function sweep(address token, uint256 amountMin, address to) external;

    // ==========================
    // Multicall
    // ==========================

    /// @notice Execute multiple Swapper functions in a single transaction.
    /// @dev Each element in `calls` is an ABI-encoded call to a Swapper function. Calls are executed
    /// sequentially via `address(this).call()`. If any call reverts, the entire multicall reverts with
    /// the inner revert reason.
    ///
    /// Payable to support native currency flows — send native currency with the multicall and use
    /// `wrap()` or `swapSimple(value, data)` inside to handle it.
    ///
    /// **Typical multicall pattern:**
    /// ```
    /// bytes[] memory calls = new bytes[](4);
    /// calls[0] = abi.encodeCall(ISwapper.approve, (tokenIn, router));
    /// calls[1] = abi.encodeCall(ISwapper.approve, (tokenOut, vault));
    /// calls[2] = abi.encodeCall(ISwapper.swapSimple, (0, swapData));
    /// calls[3] = abi.encodeCall(ISwapper.deposit, (tokenOut, vault, minOut, account));
    /// swapper.multicall(calls);
    /// ```
    ///
    /// **Native currency multicall:**
    /// ```
    /// bytes[] memory calls = new bytes[](2);
    /// calls[0] = abi.encodeCall(ISwapper.swapSimple, (1 ether, swapData));
    /// calls[1] = abi.encodeCall(ISwapper.deposit, (tokenOut, vault, minOut, account));
    /// swapper.multicall{value: 1 ether}(calls);
    /// ```
    ///
    /// @param calls Array of ABI-encoded function calls to execute on this contract.
    function multicall(bytes[] memory calls) external payable;
}
