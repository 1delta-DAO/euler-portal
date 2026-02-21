# Euler Portal — Payments & Swapper

EVC-integrated periphery contracts for the Euler ecosystem. Provides two building blocks for atomic multi-step flows:

- **Payments** — EVC-authenticated token transfers (pull from user, push to receiver)
- **Swapper** — Untrusted swap execution with composable post-swap actions (deposit, repay, sweep)

Together they enable flows like: pull tokens from user → swap on any DEX → deposit into Euler vault — all in a single atomic EVC batch.

---

## Payments

A stateless pass-through contract secured by the [Ethereum Vault Connector (EVC)](https://github.com/euler-xyz/ethereum-vault-connector). Pulls ERC20 tokens from an EVC-authenticated sender and forwards them to a receiver. No mutable storage beyond the reentrancy lock.

### Functions

**Core transfer:**
- `transfer(token, receiver, amount)` — Pull tokens from sender, send to receiver. Tries [Permit2](https://github.com/Uniswap/permit2) first, falls back to standard `transferFrom`.

**Permit + transfer (gasless approvals):**
- `transferWithPermit(...)` — ERC-2612 permit, then transfer.
- `transferWithDaiPermit(...)` — Dai-style permit, then transfer.
- `transferWithPermit2(...)` — Permit2 signature permit, then transfer.

**Native ETH / WETH:**
- `wrapAndTransfer(weth, receiver, amount)` — Wrap ETH into WETH, transfer to receiver. Refunds excess.
- `unwrapAndTransfer(weth, receiver, amount)` — Pull WETH from sender, unwrap, send native ETH.
- `transferNative(receiver)` — Forward `msg.value` as native ETH.

All permit calls use `try/catch` so front-running or pre-existing approvals don't revert the transaction.

### Security

- **EVC authentication** — Every function uses `callThroughEVC`. The `_msgSender()` resolves the EVC-authenticated account (owner or authorized operator), never raw `msg.sender`. Same authentication model as Euler vault deposits.
- **Approval-gated** — Cannot move tokens without the sender having approved this contract, Permit2, or provided a valid permit signature.
- **Sub-account protection** — Rejects transfers to EVC sub-accounts whose private keys are unknown.
- **Reentrancy guard** — All external functions protected by `nonReentrant`.
- **No held state** — Pure pass-through. Two immutables (`evc`, `permit2`), no token balances, no admin.

---

## Swapper

An untrusted helper contract for executing arbitrary token swaps and composable post-swap vault interactions. It holds no persistent state and needs no authentication — tokens are transferred in, processed, and moved out within a single transaction.

The contract uses a **generic handler** pattern: swap calldata is `abi.encode(target, payload)`, and the Swapper executes `target.call{value: value}(payload)`. This means it works with any DEX or aggregator without requiring protocol-specific handler code.

### Explicit Approvals

The Swapper does **not** auto-approve tokens. Callers must explicitly compose `approve()` calls as part of their `multicall` sequence before any operation that requires token spending. This keeps the swap path minimal and makes approval flow transparent:

```solidity
// approve() max-approves a token for a spender and caches the result.
// Subsequent calls for the same token+spender pair are no-ops (skipped via cache).
function approve(address token, address spender) public
```

Typical multicall with approvals:

```solidity
bytes[] memory calls = new bytes[](4);
// 1) Approve the swap router to spend tokenIn
calls[0] = abi.encodeCall(Swapper.approve, (USDC, swapRouter));
// 2) Approve the vault to spend tokenOut (for deposit)
calls[1] = abi.encodeCall(Swapper.approve, (WETH, wethVault));
// 3) Execute the swap
calls[2] = abi.encodeCall(Swapper.swapSimple, (0, swapData));
// 4) Deposit output into vault
calls[3] = abi.encodeCall(Swapper.deposit, (WETH, wethVault, minWethOut, user));
swapper.multicall(calls);
```

The approval cache persists across transactions — once a token+spender pair is approved, future multicalls can omit that `approve()` step. The cache uses USDT-safe approve-with-retry (resets to 0 first if needed).

### Swap Function

- **`swapSimple(value, data)`** — Execute a swap, nothing else. Output tokens stay in the contract for handling via subsequent `multicall` steps (deposit, repay, sweep, etc.) or an external batch step. `value` is the native currency amount forwarded to the swap target (0 for ERC20 swaps).

All post-swap actions (deposit, repay, sweep) are composed via `multicall`. This keeps `swapSimple` minimal and lets integrators build any flow from the same primitives.

### Native Currency Support

The Swapper supports native currency (ETH, BNB, etc.) for omni-chain deployment. Swap functions accept a `value` parameter — the native currency amount forwarded to the swap target. This is drawn from `address(this).balance`, not `msg.value`, to avoid double-spend issues in multicall.

**Utility functions:**

| Function | What it does |
|---|---|
| `wrap(wrappedNative)` | Wrap contract's full native balance into wrapped native token (e.g., WETH, WBNB) |
| `unwrap(wrappedNative, amount)` | Unwrap wrapped native to native currency. `type(uint256).max` = unwrap all |
| `sweepNative(amountMin, to)` | Send native currency balance to recipient with slippage check |

All three are payable. The contract has a `receive()` fallback to accept native currency.

**Native swap via multicall (direct forwarding):**

```solidity
bytes[] memory calls = new bytes[](2);
// Swap native currency -> USDC via DEX router that accepts native
calls[0] = abi.encodeCall(Swapper.swapSimple, (1 ether, swapData));
calls[1] = abi.encodeCall(Swapper.deposit, (USDC, usdcVault, minUsdc, user));
swapper.multicall{value: 1 ether}(calls);
```

**Native swap via multicall (wrap-first):**

```solidity
bytes[] memory calls = new bytes[](4);
calls[0] = abi.encodeCall(Swapper.wrap, (WETH));                           // ETH -> WETH
calls[1] = abi.encodeCall(Swapper.approve, (WETH, swapRouter));            // Approve router
calls[2] = abi.encodeCall(Swapper.swapSimple, (0, swapData));              // Swap WETH -> USDC
calls[3] = abi.encodeCall(Swapper.deposit, (USDC, usdcVault, minUsdc, user));
swapper.multicall{value: 1 ether}(calls);
```

**Unwrap flow (token -> native currency):**

```solidity
bytes[] memory calls = new bytes[](4);
calls[0] = abi.encodeCall(Swapper.approve, (USDC, swapRouter));
calls[1] = abi.encodeCall(Swapper.swapSimple, (0, swapData));              // USDC -> WETH
calls[2] = abi.encodeCall(Swapper.unwrap, (WETH, type(uint256).max));      // WETH -> native
calls[3] = abi.encodeCall(Swapper.sweepNative, (minNativeOut, user));
swapper.multicall(calls);
```

### Post-Swap Actions

Standalone functions for vault interactions, each with a **minimum amount that reverts on failure** (slippage check):

| Function | What it does |
|---|---|
| `deposit(token, vault, amountMin, account)` | Deposit full balance to vault |
| `repay(token, vault, repayAmount, amountMin, account)` | Repay debt (capped to balance) |
| `repayAndDeposit(token, vault, repayAmount, amountMin, account)` | Repay, then deposit remainder |
| `sweep(token, amountMin, to)` | Transfer full ERC20 balance to recipient |
| `sweepNative(amountMin, to)` | Transfer full native currency balance to recipient |

All functions revert with `Swapper_InsufficientBalance` if the contract's balance is below `amountMin`. Pass `amountMin = 0` to skip the check.

### Multicall

`multicall(bytes[] calls)` executes multiple functions on the Swapper in sequence within a single external call. It is `payable` to support native currency flows. This enables composing any combination of approvals, swaps, and post-actions:

```solidity
bytes[] memory calls = new bytes[](4);
calls[0] = abi.encodeCall(Swapper.approve, (USDC, swapRouter));
calls[1] = abi.encodeCall(Swapper.approve, (WETH, wethVault));
calls[2] = abi.encodeCall(Swapper.swapSimple, (0, swapData));
calls[3] = abi.encodeCall(Swapper.deposit, (WETH, wethVault, minWeth, user));
swapper.multicall(calls);
```

### Security

- **Untrusted** — No authentication, no admin. Anyone can call any function.
- **Explicit approvals** — Callers compose `approve()` steps in multicall. Approvals are cached per token+spender pair with USDT-safe retry.
- **Reentrancy protection** — `externalLock` blocks external reentrancy but allows self-calls (required for `multicall`).
- **Native currency safety** — Swap functions use an explicit `value` parameter drawn from `address(this).balance`, not `msg.value`, preventing double-spend in multicall.
- **No persistent balance** — Tokens only reside in the contract during execution.

---

## Batching — Payments + Swapper

The two contracts are designed to work together inside EVC batches. A typical swap-and-deposit flow:

```solidity
// Build a multicall that approves, swaps, and deposits
bytes[] memory calls = new bytes[](4);
calls[0] = abi.encodeCall(Swapper.approve, (USDC, swapRouter));
calls[1] = abi.encodeCall(Swapper.approve, (WETH, wethVault));
calls[2] = abi.encodeCall(Swapper.swapSimple, (0, swapData));
calls[3] = abi.encodeCall(Swapper.deposit, (WETH, wethVault, minWeth, user));

IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

// 1) Pull USDC from user to the swapper (EVC-authenticated)
items[0] = IEVC.BatchItem({
    targetContract: address(payments),
    onBehalfOfAccount: user,
    value: 0,
    data: abi.encodeCall(Payments.transfer, (USDC, address(swapper), usdcAmount))
});

// 2) Swapper: approve, swap USDC -> WETH, and deposit into vault
items[1] = IEVC.BatchItem({
    targetContract: address(swapper),
    onBehalfOfAccount: address(0),
    value: 0,
    data: abi.encodeCall(Swapper.multicall, (calls))
});

evc.batch(items);
```

**Native currency via EVC batch:**

```solidity
// Swap native currency -> USDC -> vault
bytes[] memory calls = new bytes[](2);
calls[0] = abi.encodeCall(Swapper.swapSimple, (1 ether, swapData));
calls[1] = abi.encodeCall(Swapper.deposit, (USDC, usdcVault, minUsdc, user));

IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
items[0] = IEVC.BatchItem({
    targetContract: address(swapper),
    onBehalfOfAccount: address(0),
    value: 1 ether,
    data: abi.encodeCall(Swapper.multicall, (calls))
});

evc.batch{value: 1 ether}(items);
```

### Direct Deposit via Skim

Euler vaults support `skim()` — tokens transferred directly to a vault can be credited as a deposit:

```solidity
IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

// 1) Transfer tokens directly to the vault address
items[0] = IEVC.BatchItem({
    targetContract: address(payments),
    onBehalfOfAccount: user,
    value: 0,
    data: abi.encodeCall(Payments.transfer, (USDC, address(usdcVault), depositAmount))
});

// 2) Skim to credit the deposit
items[1] = IEVC.BatchItem({
    targetContract: address(usdcVault),
    onBehalfOfAccount: user,
    value: 0,
    data: abi.encodeCall(IEVault.skim, (depositAmount, user))
});

evc.batch(items);
```

### Other Patterns
- **Split payments** — one batch transferring to multiple receivers atomically.
- **Permit + transfer** — sign approval off-chain, include as a batch item alongside the transfer.
- **Multi-swap** — use Swapper multicall to chain multiple swaps and deposits.

---

## TransferFromSender vs Payments

The evk-periphery includes a `TransferFromSender` contract. Comparison:

| Feature | TransferFromSender | Payments |
|---|---|---|
| EVC authentication | `_msgSender()` via EVCUtil | `_msgSender()` via EVCUtil + `callThroughEVC` |
| Transfer method | Permit2-first via SafeERC20Permit2Lib | Permit2-first via SafeERC20Lib |
| Receiver validation | None | Rejects `address(0)` and EVC sub-accounts |
| Amount validation | None | Rejects zero amounts |
| Permit support | None (pre-existing approval required) | ERC-2612, Dai-style, Permit2 signature |
| WETH/Native ETH | None | wrap+transfer, unwrap+transfer, native ETH |
| Reentrancy guard | None | Storage-based reentrancy guard |
| Events | None | Emits transfer events |

TransferFromSender is a minimal pull-tokens helper embedded in SwapVerifier. Payments is the full-featured replacement.

---

## Building

```bash
git submodule update --init --recursive
forge build
forge test
```

## License

GPL-2.0-or-later
