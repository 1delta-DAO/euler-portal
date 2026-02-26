# Euler Portal — Supported Operations

Reference for all composable flows supported by Payments + Orchestrator + EVC batching.

## Primitives

**Payments** (EVC-authenticated transfers):
- `transfer(token, receiver, amount)` — pull ERC20 from user, send to receiver
- `wrapAndTransfer(weth, receiver, amount)` — wrap native → WETH, send to receiver
- `unwrapAndTransfer(weth, receiver, amount)` — pull WETH, unwrap, send native
- `transferNative(receiver)` — forward `msg.value` as native
- `permit2TransferFrom(permit, transferDetails, signature)` — batch-pull tokens via Permit2 SignatureTransfer

**Payments** (permit utilities — unauthenticated, signature-based):
- `permit(token, owner, amount, deadline, v, r, s)` — ERC-2612 permit to this contract
- `permitDai(token, owner, nonce, expiry, allowed, v, r, s)` — Dai-style permit to this contract
- `permit2Permit(token, owner, amount, nonce, deadline, signature)` — Permit2 AllowanceTransfer permit to this contract

**Orchestrator** (untrusted, composable via multicall):
- `approve(token, spender)` — max-approve with cache (must precede any pull-based operation)
- `swapSimple(value, data)` — execute swap, leave output in contract
- `deposit(token, vault, amountMin, account)` — deposit full balance to vault
- `repay(token, vault, repayAmount, amountMin, account)` — repay debt
- `repayAndDeposit(token, vault, repayAmount, amountMin, account)` — repay + deposit remainder
- `sweep(token, amountMin, to)` — send full ERC20 balance to recipient
- `sweepNative(amountMin, to)` — send full native balance to recipient
- `wrap(wrappedNative, amount)` — wrap native balance → wrapped native (`type(uint256).max` = all)
- `wrapTo(wrappedNative, amount, to)` — wrap native and transfer wrapped tokens to recipient
- `unwrap(wrappedNative, amount)` — unwrap wrapped native → native
- `unwrapTo(wrappedNative, amount, to)` — unwrap and send native currency to recipient
- `multicall(calls)` — compose any of the above in sequence

**Vault** (called directly via EVC batch):
- `deposit(amount, receiver)` — supply assets
- `withdraw(amount, receiver, owner)` — withdraw collateral
- `borrow(amount, receiver)` — borrow assets
- `repay(amount, receiver)` — repay debt

**Key design points:**
- Approvals are explicit — compose `approve()` in multicall before operations that need them
- All balance-based operations use `balanceOf(address(this))`, so pre-existing balances from earlier batch items are naturally included
- EVC defers account health checks until end of batch, allowing temporarily unhealthy states
- Native currency uses explicit `value` parameter (not `msg.value`) to prevent double-spend in multicall

---

## 1. Swap and Deposit

Swap any input asset (including native) and deposit the output into any vault.

### ERC20 → ERC20 → vault

```solidity
// EVC batch
items[0] = Payments.transfer(tokenIn, orchestrator, amount);
items[1] = Orchestrator.multicall([
    approve(tokenIn, router),
    approve(tokenOut, vault),
    swapSimple(0, data),
    deposit(tokenOut, vault, minOut, account)
]);
```

### Native → ERC20 → vault

```solidity
// EVC batch
items[0] = Orchestrator.multicall{value: X}([
    approve(tokenOut, vault),
    swapSimple(X, data),
    deposit(tokenOut, vault, minOut, account)
]);
```

No tokenIn approval needed for native. The `value` parameter forwards native currency to the DEX.

---

## 2. Swap and Repay

Swap any input asset (including native) and repay debt on any vault. Remainder is deposited.

### ERC20 → ERC20 → repay

```solidity
// EVC batch
items[0] = Payments.transfer(tokenIn, orchestrator, amount);
items[1] = Orchestrator.multicall([
    approve(tokenIn, router),
    approve(debtToken, debtVault),
    swapSimple(0, data),
    repayAndDeposit(debtToken, debtVault, type(uint256).max, minOut, account)
]);
```

### Native → ERC20 → repay

```solidity
// EVC batch
items[0] = Orchestrator.multicall{value: X}([
    approve(debtToken, debtVault),
    swapSimple(X, data),
    repayAndDeposit(debtToken, debtVault, type(uint256).max, minOut, account)
]);
```

Use `type(uint256).max` as `repayAmount` to repay all debt. Any specific value repays exactly that amount (capped to balance and debt). Surplus after repay is automatically deposited.

---

## 3. Withdraw and Swap

Withdraw from any vault and swap to any output asset (including native).

### Vault → ERC20

```solidity
// EVC batch
items[0] = vault.withdraw(amount, orchestrator, account);
items[1] = Orchestrator.multicall([
    approve(withdrawnToken, router),
    swapSimple(0, data),
    sweep(tokenOut, minOut, user)
]);
```

### Vault → native

```solidity
// EVC batch
items[0] = vault.withdraw(amount, orchestrator, account);
items[1] = Orchestrator.multicall([
    approve(withdrawnToken, router),
    swapSimple(0, data),                          // → wrapped native
    unwrap(WETH, type(uint256).max),
    sweepNative(minOut, user)
]);
```

The vault's `withdraw` is called directly via EVC batch — the Orchestrator never invokes it.

---

## 4. Borrow and Swap

Borrow from any vault and swap to any output asset (including native).

### Borrow → ERC20

```solidity
// EVC batch
items[0] = debtVault.borrow(amount, orchestrator);
items[1] = Orchestrator.multicall([
    approve(debtToken, router),
    swapSimple(0, data),
    sweep(tokenOut, minOut, user)
]);
```

### Borrow → native

```solidity
// EVC batch
items[0] = debtVault.borrow(amount, orchestrator);
items[1] = Orchestrator.multicall([
    approve(debtToken, router),
    swapSimple(0, data),                          // → wrapped native
    unwrap(WETH, type(uint256).max),
    sweepNative(minOut, user)
]);
```

EVC deferred status checks allow the borrow to proceed even though collateral may not yet be posted — health is verified at the end of the batch.

---

## 5. Leverage

Combine borrow/withdraw with swap and deposit/repay for leveraged position management.

### Leverage up (borrow → swap → deposit collateral)

```solidity
// EVC batch
items[0] = debtVault.borrow(amount, orchestrator);
items[1] = Orchestrator.multicall([
    approve(debtToken, router),
    approve(collateralToken, collateralVault),
    swapSimple(0, data),
    deposit(collateralToken, collateralVault, minOut, account)
]);
```

### Deleverage (withdraw collateral → swap → repay debt)

```solidity
// EVC batch
items[0] = collateralVault.withdraw(amount, orchestrator, account);
items[1] = Orchestrator.multicall([
    approve(collateralToken, router),
    approve(debtToken, debtVault),
    swapSimple(0, data),
    repayAndDeposit(debtToken, debtVault, type(uint256).max, minOut, account)
]);
```

EVC deferred checks are critical — the account is temporarily unhealthy between borrow and deposit, but the batch is atomic and health is checked only at the end.

---

## 6. Zap — Deposit Margin

Open a leveraged position by depositing margin in either the collateral or debt currency. Supports native currency when either side is wrapped native.

### Case A: User pays with the debt (borrow) currency

The Orchestrator receives both the user's payment and the borrowed amount of the same token. Swap the entire balance `(payAmount + borrowAmount)` to collateral in one swap.

```solidity
// EVC batch
items[0] = Payments.transfer(debtToken, orchestrator, payAmount);
items[1] = debtVault.borrow(borrowAmount, orchestrator);
items[2] = Orchestrator.multicall([
    approve(debtToken, router),
    approve(collateralToken, collateralVault),
    swapSimple(0, data),
    deposit(collateralToken, collateralVault, minOut, account)
]);
```

After steps 0+1, the Orchestrator holds `payAmount + borrowAmount` of debtToken. The swap converts ALL of it to collateralToken and deposit picks up the full balance.

**With native (debt = wrapped native, user pays native):**

```solidity
// EVC batch
items[0] = Payments.wrapAndTransfer{value: payAmount}(WETH, orchestrator, payAmount);
items[1] = debtVault.borrow(borrowAmount, orchestrator);
items[2] = Orchestrator.multicall([
    approve(WETH, router),
    approve(collateralToken, collateralVault),
    swapSimple(0, data),
    deposit(collateralToken, collateralVault, minOut, account)
]);
```

### Case B: User pays with the collateral currency

The Orchestrator receives the user's collateralToken AND the borrowed debtToken. Swap ONLY the debtToken to collateralToken, then deposit the full collateralToken balance (user's original + swap output).

```solidity
// EVC batch
items[0] = Payments.transfer(collateralToken, orchestrator, payAmount);
items[1] = debtVault.borrow(borrowAmount, orchestrator);
items[2] = Orchestrator.multicall([
    approve(debtToken, router),
    approve(collateralToken, collateralVault),
    swapSimple(0, data),                                         // swap ONLY debtToken → collateralToken
    deposit(collateralToken, collateralVault, minOut, account)   // deposit FULL balance
]);
```

After steps 0+1, the Orchestrator holds `payAmount` of collateralToken + `borrowAmount` of debtToken. The swap data encodes swapping only the debtToken. After swapSimple, the Orchestrator holds `payAmount + swapOutput` of collateralToken. `deposit()` picks up the full balance.

**With native (collateral = wrapped native, user pays native):**

```solidity
// EVC batch
items[0] = Payments.wrapAndTransfer{value: payAmount}(WETH, orchestrator, payAmount);
items[1] = debtVault.borrow(borrowAmount, orchestrator);
items[2] = Orchestrator.multicall([
    approve(debtToken, router),
    approve(WETH, collateralVault),
    swapSimple(0, data),                                         // debtToken → WETH
    deposit(WETH, collateralVault, minOut, account)
]);
```

---

## Summary

| Scenario | Native in | Native out | Key functions |
|---|---|---|---|
| Swap and deposit | Yes (via `value`) | N/A | swapSimple + deposit |
| Swap and repay | Yes (via `value`) | N/A | swapSimple + repayAndDeposit |
| Withdraw and swap | N/A | Yes (unwrap + sweepNative) | swapSimple + sweep/sweepNative |
| Borrow and swap | N/A | Yes (unwrap + sweepNative) | swapSimple + sweep/sweepNative |
| Leverage up | Yes (wrapAndTransfer) | N/A | borrow + swapSimple + deposit |
| Deleverage | N/A | Yes (unwrap + sweepNative) | withdraw + swapSimple + repayAndDeposit |
| Zap (pay with debt) | Yes (wrapAndTransfer) | N/A | transfer/borrow + swapSimple + deposit |
| Zap (pay with collateral) | Yes (wrapAndTransfer) | N/A | transfer/borrow + swapSimple + deposit |

All scenarios are composable from existing Payments + Orchestrator + EVC batch primitives with no code changes required.
