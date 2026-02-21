// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Swapper} from "../contracts/Swapper.sol";
import {SafeERC20Lib} from "../contracts/lib/SafeERC20Lib.sol";

import {
    MockERC20,
    MockERC20RequiresZeroAllowance,
    MockVault,
    MockSwapTarget,
    MockSwapTargetReverting,
    ReentrantToken
} from "./utils/Mocks.sol";

contract SwapperTest is Test {
    Swapper public swapper;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockSwapTarget public swapTarget;
    MockVault public vault;

    address public user = makeAddr("user");
    address public receiver = makeAddr("receiver");

    function setUp() public {
        swapper = new Swapper();
        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);
        swapTarget = new MockSwapTarget(tokenA, tokenB, 1e18); // 1:1 rate
        vault = new MockVault(tokenB);
    }

    // --- Helpers ---

    function _makeSwapData(uint256 amountIn) internal view returns (bytes memory) {
        bytes memory payload = abi.encodeCall(MockSwapTarget.swap, (amountIn));
        return abi.encode(address(swapTarget), payload);
    }

    function _fundSwapperWithTokenA(uint256 amount) internal {
        tokenA.mint(address(swapper), amount);
    }

    function _fundSwapperWithTokenB(uint256 amount) internal {
        tokenB.mint(address(swapper), amount);
    }

    // ==========================
    // swapSimple tests
    // ==========================

    function test_swapSimple_basic() public {
        uint256 amountIn = 100e18;
        _fundSwapperWithTokenA(amountIn);

        swapper.swapSimple(address(tokenA), _makeSwapData(amountIn));

        assertEq(tokenB.balanceOf(address(swapper)), 100e18);
        assertEq(tokenA.balanceOf(address(swapper)), 0);
    }

    function test_swapSimple_approvesTokenInToTarget() public {
        uint256 amountIn = 50e18;
        _fundSwapperWithTokenA(amountIn);

        swapper.swapSimple(address(tokenA), _makeSwapData(amountIn));

        assertGt(tokenA.allowance(address(swapper), address(swapTarget)), 0);
    }

    function test_swapSimple_revertsOnFailedSwap() public {
        MockSwapTargetReverting badTarget = new MockSwapTargetReverting();
        bytes memory data = abi.encode(address(badTarget), abi.encodeCall(MockSwapTargetReverting.swap, (100)));

        vm.expectRevert();
        swapper.swapSimple(address(tokenA), data);
    }

    function test_swapSimple_revertsOnNoCodeTarget() public {
        address noCode = makeAddr("noCode");
        bytes memory data = abi.encode(noCode, bytes(""));

        vm.expectRevert();
        swapper.swapSimple(address(tokenA), data);
    }

    // ==========================
    // swapAndDeposit tests
    // ==========================

    function test_swapAndDeposit_basic() public {
        uint256 amountIn = 100e18;
        _fundSwapperWithTokenA(amountIn);

        Swapper.SwapParams memory params = Swapper.SwapParams({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            vault: address(vault),
            account: user,
            targetDebt: 0,
            data: _makeSwapData(amountIn)
        });

        swapper.swapAndDeposit(params);

        assertEq(vault.deposits(user), 100e18);
        assertEq(tokenB.balanceOf(address(swapper)), 0);
    }

    function test_swapAndDeposit_noDepositWhenZeroOutput() public {
        MockSwapTarget zeroTarget = new MockSwapTarget(tokenA, tokenB, 0);
        uint256 amountIn = 100e18;
        _fundSwapperWithTokenA(amountIn);

        bytes memory payload = abi.encodeCall(MockSwapTarget.swap, (amountIn));
        bytes memory data = abi.encode(address(zeroTarget), payload);

        Swapper.SwapParams memory params = Swapper.SwapParams({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            vault: address(vault),
            account: user,
            targetDebt: 0,
            data: data
        });

        swapper.swapAndDeposit(params);

        assertEq(vault.deposits(user), 0);
    }

    // ==========================
    // swapAndRepay tests
    // ==========================

    function test_swapAndRepay_repayAll() public {
        uint256 amountIn = 100e18;
        _fundSwapperWithTokenA(amountIn);
        vault.setDebt(user, 80e18);

        Swapper.SwapParams memory params = Swapper.SwapParams({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            vault: address(vault),
            account: user,
            targetDebt: 0,
            data: _makeSwapData(amountIn)
        });

        swapper.swapAndRepay(params);

        assertEq(vault.debtOf(user), 0);
        assertEq(vault.deposits(user), 20e18);
        assertEq(tokenB.balanceOf(address(swapper)), 0);
    }

    function test_swapAndRepay_targetDebt() public {
        uint256 amountIn = 100e18;
        uint256 targetDebt = 30e18;
        _fundSwapperWithTokenA(amountIn);
        vault.setDebt(user, 80e18);

        Swapper.SwapParams memory params = Swapper.SwapParams({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            vault: address(vault),
            account: user,
            targetDebt: targetDebt,
            data: _makeSwapData(amountIn)
        });

        swapper.swapAndRepay(params);

        assertEq(vault.debtOf(user), targetDebt);
        assertEq(vault.deposits(user), 50e18);
    }

    function test_swapAndRepay_revertsIfTargetDebtExceedsDebt() public {
        uint256 amountIn = 100e18;
        uint256 initialDebt = 50e18;
        _fundSwapperWithTokenA(amountIn);
        vault.setDebt(user, initialDebt);

        Swapper.SwapParams memory params = Swapper.SwapParams({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            vault: address(vault),
            account: user,
            targetDebt: initialDebt + 1,
            data: _makeSwapData(amountIn)
        });

        vm.expectRevert(Swapper.Swapper_TargetDebt.selector);
        swapper.swapAndRepay(params);
    }

    function test_swapAndRepay_capsRepayToBalance() public {
        uint256 amountIn = 50e18;
        _fundSwapperWithTokenA(amountIn);
        vault.setDebt(user, 100e18);

        Swapper.SwapParams memory params = Swapper.SwapParams({
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            vault: address(vault),
            account: user,
            targetDebt: 0,
            data: _makeSwapData(amountIn)
        });

        swapper.swapAndRepay(params);

        assertEq(vault.debtOf(user), 50e18);
        assertEq(vault.deposits(user), 0);
    }

    // ==========================
    // deposit tests
    // ==========================

    function test_deposit_basic() public {
        _fundSwapperWithTokenB(100e18);

        swapper.deposit(address(tokenB), address(vault), 0, user);

        assertEq(vault.deposits(user), 100e18);
        assertEq(tokenB.balanceOf(address(swapper)), 0);
    }

    function test_deposit_revertsIfBelowMin() public {
        _fundSwapperWithTokenB(50e18);

        vm.expectRevert(Swapper.Swapper_InsufficientBalance.selector);
        swapper.deposit(address(tokenB), address(vault), 100e18, user);
    }

    function test_deposit_noOpWhenZeroBalance() public {
        swapper.deposit(address(tokenB), address(vault), 0, user);
        assertEq(vault.deposits(user), 0);
    }

    function test_deposit_withSlippageCheck() public {
        _fundSwapperWithTokenB(100e18);

        swapper.deposit(address(tokenB), address(vault), 99e18, user);
        assertEq(vault.deposits(user), 100e18);
    }

    // ==========================
    // repay tests
    // ==========================

    function test_repay_basic() public {
        _fundSwapperWithTokenB(100e18);
        vault.setDebt(user, 100e18);

        swapper.repay(address(tokenB), address(vault), type(uint256).max, 0, user);

        assertEq(vault.debtOf(user), 0);
    }

    function test_repay_capsToBalance() public {
        _fundSwapperWithTokenB(50e18);
        vault.setDebt(user, 100e18);

        swapper.repay(address(tokenB), address(vault), 80e18, 0, user);

        assertEq(vault.debtOf(user), 50e18);
    }

    function test_repay_revertsIfBelowMin() public {
        _fundSwapperWithTokenB(10e18);

        vm.expectRevert(Swapper.Swapper_InsufficientBalance.selector);
        swapper.repay(address(tokenB), address(vault), 10e18, 50e18, user);
    }

    function test_repay_noOpWhenZeroBalance() public {
        vault.setDebt(user, 100e18);
        swapper.repay(address(tokenB), address(vault), type(uint256).max, 0, user);
        assertEq(vault.debtOf(user), 100e18);
    }

    // ==========================
    // repayAndDeposit tests
    // ==========================

    function test_repayAndDeposit_basic() public {
        _fundSwapperWithTokenB(100e18);
        vault.setDebt(user, 60e18);

        swapper.repayAndDeposit(address(tokenB), address(vault), type(uint256).max, 0, user);

        assertEq(vault.debtOf(user), 0);
        assertEq(vault.deposits(user), 40e18);
    }

    function test_repayAndDeposit_revertsIfBelowMin() public {
        _fundSwapperWithTokenB(10e18);

        vm.expectRevert(Swapper.Swapper_InsufficientBalance.selector);
        swapper.repayAndDeposit(address(tokenB), address(vault), type(uint256).max, 50e18, user);
    }

    function test_repayAndDeposit_partialRepay() public {
        _fundSwapperWithTokenB(100e18);
        vault.setDebt(user, 200e18);

        swapper.repayAndDeposit(address(tokenB), address(vault), 70e18, 0, user);

        assertEq(vault.debtOf(user), 130e18);
        assertEq(vault.deposits(user), 30e18);
    }

    // ==========================
    // sweep tests
    // ==========================

    function test_sweep_basic() public {
        _fundSwapperWithTokenA(100e18);

        swapper.sweep(address(tokenA), 0, receiver);

        assertEq(tokenA.balanceOf(receiver), 100e18);
        assertEq(tokenA.balanceOf(address(swapper)), 0);
    }

    function test_sweep_revertsIfBelowMin() public {
        _fundSwapperWithTokenA(50e18);

        vm.expectRevert(Swapper.Swapper_InsufficientBalance.selector);
        swapper.sweep(address(tokenA), 100e18, receiver);
    }

    function test_sweep_noOpWhenZeroBalance() public {
        swapper.sweep(address(tokenA), 0, receiver);
        assertEq(tokenA.balanceOf(receiver), 0);
    }

    function test_sweep_withSlippageCheck() public {
        _fundSwapperWithTokenA(100e18);

        swapper.sweep(address(tokenA), 99e18, receiver);
        assertEq(tokenA.balanceOf(receiver), 100e18);
    }

    // ==========================
    // multicall tests
    // ==========================

    function test_multicall_swapAndDeposit() public {
        uint256 amountIn = 100e18;
        _fundSwapperWithTokenA(amountIn);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Swapper.swapSimple, (address(tokenA), _makeSwapData(amountIn)));
        calls[1] = abi.encodeCall(Swapper.deposit, (address(tokenB), address(vault), 99e18, user));

        swapper.multicall(calls);

        assertEq(vault.deposits(user), 100e18);
        assertEq(tokenB.balanceOf(address(swapper)), 0);
    }

    function test_multicall_swapAndSweep() public {
        uint256 amountIn = 100e18;
        _fundSwapperWithTokenA(amountIn);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Swapper.swapSimple, (address(tokenA), _makeSwapData(amountIn)));
        calls[1] = abi.encodeCall(Swapper.sweep, (address(tokenB), 99e18, receiver));

        swapper.multicall(calls);

        assertEq(tokenB.balanceOf(receiver), 100e18);
    }

    function test_multicall_revertBubblesUp() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Swapper.swapSimple, (address(tokenA), _makeSwapData(0)));
        calls[1] = abi.encodeCall(Swapper.deposit, (address(tokenB), address(vault), 100e18, user));

        vm.expectRevert();
        swapper.multicall(calls);
    }

    function test_multicall_multiSwapMultiDeposit() public {
        MockERC20 tokenC = new MockERC20("Token C", "TKNC", 18);
        MockSwapTarget swapTarget2 = new MockSwapTarget(tokenA, tokenC, 2e18);
        MockVault vault2 = new MockVault(tokenC);

        _fundSwapperWithTokenA(200e18);

        bytes memory swapData1 =
            abi.encode(address(swapTarget), abi.encodeCall(MockSwapTarget.swap, (100e18)));
        bytes memory swapData2 =
            abi.encode(address(swapTarget2), abi.encodeCall(MockSwapTarget.swap, (100e18)));

        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(Swapper.swapSimple, (address(tokenA), swapData1));
        calls[1] = abi.encodeCall(Swapper.deposit, (address(tokenB), address(vault), 0, user));
        calls[2] = abi.encodeCall(Swapper.swapSimple, (address(tokenA), swapData2));
        calls[3] = abi.encodeCall(Swapper.deposit, (address(tokenC), address(vault2), 0, user));

        swapper.multicall(calls);

        assertEq(vault.deposits(user), 100e18);
        assertEq(vault2.deposits(user), 200e18);
    }

    // ==========================
    // reentrancy tests
    // ==========================

    function test_reentrancy_blocksExternalReentry() public {
        ReentrantToken malicious = new ReentrantToken();
        malicious.setTarget(swapper);
        malicious.mint(address(swapper), 100e18);

        vm.expectRevert(SafeERC20Lib.E_TransferFailed.selector);
        swapper.sweep(address(malicious), 0, receiver);
    }

    // ==========================
    // USDT-style approval tests
    // ==========================

    function test_approval_usdtStyleToken() public {
        MockERC20RequiresZeroAllowance usdtToken = new MockERC20RequiresZeroAllowance();
        usdtToken.mint(address(swapper), 100e6);

        swapper.sweep(address(usdtToken), 0, receiver);
        assertEq(usdtToken.balanceOf(receiver), 100e6);
    }
}
