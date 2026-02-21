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

The contract uses a **generic handler** pattern: swap calldata is `abi.encode(target, payload)`, where the Swapper approves `tokenIn` to the target address and executes `target.call(payload)`. This means it works with any DEX or aggregator without requiring protocol-specific handler code.

### Swap Functions

Three variants covering different post-swap flows:

- **`swapSimple(tokenIn, data)`** — Execute a swap, nothing else. Output tokens stay in the contract for manual handling via `multicall` or an external batch step.
- **`swapAndDeposit(params)`** — Swap, then deposit the entire output token balance into an Euler vault for a given account.
- **`swapAndRepay(params)`** — Swap, then repay debt on an Euler vault (with target debt resolution), then deposit the remainder.

For `swapAndRepay`, set `targetDebt = 0` to repay all debt. Any non-zero value is treated as the desired debt level after repay — the contract queries `vault.debtOf(account)` and repays the difference.

### Post-Swap Actions

Standalone functions for vault interactions, each with a **minimum amount that reverts on failure** (slippage check):

| Function | What it does |
|---|---|
| `deposit(token, vault, amountMin, account)` | Deposit full balance to vault |
| `repay(token, vault, repayAmount, amountMin, account)` | Repay debt (capped to balance) |
| `repayAndDeposit(token, vault, repayAmount, amountMin, account)` | Repay, then deposit remainder |
| `sweep(token, amountMin, to)` | Transfer full balance to recipient |

All functions revert with `Swapper_InsufficientBalance` if the contract's token balance is below `amountMin`. Pass `amountMin = 0` to skip the check.

### Multicall

`multicall(bytes[] calls)` executes multiple functions on the Swapper in sequence within a single external call. This enables composing any combination of swaps and post-actions:

```solidity
// Swap USDC -> WETH, then deposit with slippage check
bytes[] memory calls = new bytes[](2);
calls[0] = abi.encodeCall(Swapper.swapSimple, (USDC, swapData));
calls[1] = abi.encodeCall(Swapper.deposit, (WETH, wethVault, minWethOut, user));
swapper.multicall(calls);
```

Multi-swap, multi-deposit in one transaction:

```solidity
bytes[] memory calls = new bytes[](4);
calls[0] = abi.encodeCall(Swapper.swapSimple, (USDC, swap1Data));  // USDC -> WETH
calls[1] = abi.encodeCall(Swapper.deposit, (WETH, wethVault, minWeth, user));
calls[2] = abi.encodeCall(Swapper.swapSimple, (USDC, swap2Data));  // USDC -> DAI
calls[3] = abi.encodeCall(Swapper.deposit, (DAI, daiVault, minDai, user));
swapper.multicall(calls);
```

### Security

- **Untrusted** — No authentication, no stored allowances, no admin. Anyone can call any function.
- **Reentrancy protection** — `externalLock` blocks external reentrancy but allows self-calls (required for `multicall`).
- **USDT-safe approvals** — Approve-with-retry handles tokens requiring allowance reset to 0.
- **No persistent balance** — Tokens only reside in the contract during execution.

---

## Batching — Payments + Swapper

The two contracts are designed to work together inside EVC batches. A typical swap-and-deposit flow:

```solidity
IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);

// 1) Pull USDC from user to the swapper (EVC-authenticated)
items[0] = IEVC.BatchItem({
    targetContract: address(payments),
    onBehalfOfAccount: user,
    value: 0,
    data: abi.encodeCall(Payments.transfer, (USDC, address(swapper), usdcAmount))
});

// 2) Swapper: swap USDC -> WETH and deposit into vault
items[1] = IEVC.BatchItem({
    targetContract: address(swapper),
    onBehalfOfAccount: address(0),
    value: 0,
    data: abi.encodeCall(Swapper.swapAndDeposit, (swapParams))
});

evc.batch(items);
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
