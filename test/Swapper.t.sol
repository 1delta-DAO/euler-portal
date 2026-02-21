// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Swapper} from "../contracts/Swapper.sol";
import {ISwapper} from "../contracts/interfaces/ISwapper.sol";
import {SafeERC20Lib} from "../contracts/lib/SafeERC20Lib.sol";

import {
    MockERC20,
    MockERC20RequiresZeroAllowance,
    MockVault,
    MockWETH,
    MockSwapTarget,
    MockSwapTargetETH,
    MockSwapTargetReverting,
    RejectETH,
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

    /// @dev Approve tokenIn to swapTarget and tokenOut to vault (common setup for swap+vault tests)
    function _approveSwapAndVault() internal {
        swapper.approve(address(tokenA), address(swapTarget));
        swapper.approve(address(tokenB), address(vault));
    }

    // ==========================
    // swapSimple tests
    // ==========================

    function test_swapSimple_basic() public {
        uint256 amountIn = 100e18;
        _fundSwapperWithTokenA(amountIn);
        swapper.approve(address(tokenA), address(swapTarget));

        swapper.swapSimple(0, _makeSwapData(amountIn));

        assertEq(tokenB.balanceOf(address(swapper)), 100e18);
        assertEq(tokenA.balanceOf(address(swapper)), 0);
    }

    function test_swapSimple_revertsOnFailedSwap() public {
        MockSwapTargetReverting badTarget = new MockSwapTargetReverting();
        bytes memory data = abi.encode(address(badTarget), abi.encodeCall(MockSwapTargetReverting.swap, (100)));

        vm.expectRevert();
        swapper.swapSimple(0, data);
    }

    function test_swapSimple_revertsOnNoCodeTarget() public {
        address noCode = makeAddr("noCode");
        bytes memory data = abi.encode(noCode, bytes(""));

        vm.expectRevert();
        swapper.swapSimple(0, data);
    }

    // ==========================
    // deposit tests
    // ==========================

    function test_deposit_basic() public {
        _fundSwapperWithTokenB(100e18);
        swapper.approve(address(tokenB), address(vault));

        swapper.deposit(address(tokenB), address(vault), 0, user);

        assertEq(vault.deposits(user), 100e18);
        assertEq(tokenB.balanceOf(address(swapper)), 0);
    }

    function test_deposit_revertsIfBelowMin() public {
        _fundSwapperWithTokenB(50e18);

        vm.expectRevert(ISwapper.Swapper_InsufficientBalance.selector);
        swapper.deposit(address(tokenB), address(vault), 100e18, user);
    }

    function test_deposit_noOpWhenZeroBalance() public {
        swapper.deposit(address(tokenB), address(vault), 0, user);
        assertEq(vault.deposits(user), 0);
    }

    function test_deposit_withSlippageCheck() public {
        _fundSwapperWithTokenB(100e18);
        swapper.approve(address(tokenB), address(vault));

        swapper.deposit(address(tokenB), address(vault), 99e18, user);
        assertEq(vault.deposits(user), 100e18);
    }

    // ==========================
    // repay tests
    // ==========================

    function test_repay_basic() public {
        _fundSwapperWithTokenB(100e18);
        swapper.approve(address(tokenB), address(vault));
        vault.setDebt(user, 100e18);

        swapper.repay(address(tokenB), address(vault), type(uint256).max, 0, user);

        assertEq(vault.debtOf(user), 0);
    }

    function test_repay_capsToBalance() public {
        _fundSwapperWithTokenB(50e18);
        swapper.approve(address(tokenB), address(vault));
        vault.setDebt(user, 100e18);

        swapper.repay(address(tokenB), address(vault), 80e18, 0, user);

        assertEq(vault.debtOf(user), 50e18);
    }

    function test_repay_capsToDebt() public {
        _fundSwapperWithTokenB(100e18);
        swapper.approve(address(tokenB), address(vault));
        vault.setDebt(user, 30e18);

        // repayAmount (80) > debt (30) — capped to debt, no revert
        swapper.repay(address(tokenB), address(vault), 80e18, 0, user);

        assertEq(vault.debtOf(user), 0);
        // 70 tokens remain in swapper (100 - 30)
        assertEq(tokenB.balanceOf(address(swapper)), 70e18);
    }

    function test_repayAndDeposit_capsToDebt() public {
        _fundSwapperWithTokenB(100e18);
        swapper.approve(address(tokenB), address(vault));
        vault.setDebt(user, 30e18);

        // repayAmount (80) > debt (30) — capped to debt, remainder deposited
        swapper.repayAndDeposit(address(tokenB), address(vault), 80e18, 0, user);

        assertEq(vault.debtOf(user), 0);
        assertEq(vault.deposits(user), 70e18);
    }

    function test_repay_revertsIfBelowMin() public {
        _fundSwapperWithTokenB(10e18);

        vm.expectRevert(ISwapper.Swapper_InsufficientBalance.selector);
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
        swapper.approve(address(tokenB), address(vault));
        vault.setDebt(user, 60e18);

        swapper.repayAndDeposit(address(tokenB), address(vault), type(uint256).max, 0, user);

        assertEq(vault.debtOf(user), 0);
        assertEq(vault.deposits(user), 40e18);
    }

    function test_repayAndDeposit_revertsIfBelowMin() public {
        _fundSwapperWithTokenB(10e18);

        vm.expectRevert(ISwapper.Swapper_InsufficientBalance.selector);
        swapper.repayAndDeposit(address(tokenB), address(vault), type(uint256).max, 50e18, user);
    }

    function test_repayAndDeposit_partialRepay() public {
        _fundSwapperWithTokenB(100e18);
        swapper.approve(address(tokenB), address(vault));
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

        vm.expectRevert(ISwapper.Swapper_InsufficientBalance.selector);
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

        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(Swapper.approve, (address(tokenA), address(swapTarget)));
        calls[1] = abi.encodeCall(Swapper.approve, (address(tokenB), address(vault)));
        calls[2] = abi.encodeCall(Swapper.swapSimple, (0, _makeSwapData(amountIn)));
        calls[3] = abi.encodeCall(Swapper.deposit, (address(tokenB), address(vault), 99e18, user));

        swapper.multicall(calls);

        assertEq(vault.deposits(user), 100e18);
        assertEq(tokenB.balanceOf(address(swapper)), 0);
    }

    function test_multicall_swapAndSweep() public {
        uint256 amountIn = 100e18;
        _fundSwapperWithTokenA(amountIn);

        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(Swapper.approve, (address(tokenA), address(swapTarget)));
        calls[1] = abi.encodeCall(Swapper.swapSimple, (0, _makeSwapData(amountIn)));
        calls[2] = abi.encodeCall(Swapper.sweep, (address(tokenB), 99e18, receiver));

        swapper.multicall(calls);

        assertEq(tokenB.balanceOf(receiver), 100e18);
    }

    function test_multicall_revertBubblesUp() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Swapper.swapSimple, (0, _makeSwapData(0)));
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

        bytes[] memory calls = new bytes[](8);
        calls[0] = abi.encodeCall(Swapper.approve, (address(tokenA), address(swapTarget)));
        calls[1] = abi.encodeCall(Swapper.approve, (address(tokenA), address(swapTarget2)));
        calls[2] = abi.encodeCall(Swapper.approve, (address(tokenB), address(vault)));
        calls[3] = abi.encodeCall(Swapper.approve, (address(tokenC), address(vault2)));
        calls[4] = abi.encodeCall(Swapper.swapSimple, (0, swapData1));
        calls[5] = abi.encodeCall(Swapper.deposit, (address(tokenB), address(vault), 0, user));
        calls[6] = abi.encodeCall(Swapper.swapSimple, (0, swapData2));
        calls[7] = abi.encodeCall(Swapper.deposit, (address(tokenC), address(vault2), 0, user));

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

    // ==========================
    // approve tests
    // ==========================

    function test_approve_basic() public {
        swapper.approve(address(tokenA), address(swapTarget));

        assertEq(tokenA.allowance(address(swapper), address(swapTarget)), type(uint256).max);
    }

    function test_approve_cachedSkipsRedundantCall() public {
        swapper.approve(address(tokenA), address(swapTarget));
        assertEq(tokenA.allowance(address(swapper), address(swapTarget)), type(uint256).max);

        // Verify cache by using a USDT-style token that would revert on non-zero-to-non-zero approve
        MockERC20RequiresZeroAllowance usdtToken = new MockERC20RequiresZeroAllowance();
        usdtToken.mint(address(swapper), 200e6);

        // First approve works
        swapper.approve(address(usdtToken), address(vault));

        // Second approve should be a no-op (cached), so it won't hit the USDT revert
        swapper.approve(address(usdtToken), address(vault));
    }

    function test_approve_separateSpenderFromRouter() public {
        address separateRouter = makeAddr("separateRouter");
        swapper.approve(address(tokenA), separateRouter);

        assertEq(tokenA.allowance(address(swapper), separateRouter), type(uint256).max);
    }

    function test_approve_usedInMulticall() public {
        uint256 amountIn = 100e18;
        _fundSwapperWithTokenA(amountIn);

        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(Swapper.approve, (address(tokenA), address(swapTarget)));
        calls[1] = abi.encodeCall(Swapper.swapSimple, (0, _makeSwapData(amountIn)));
        calls[2] = abi.encodeCall(Swapper.sweep, (address(tokenB), 99e18, receiver));

        swapper.multicall(calls);

        assertEq(tokenB.balanceOf(receiver), 100e18);
    }

    function test_approve_swapReusesCachedApproval() public {
        // Pre-approve tokenA to swapTarget
        swapper.approve(address(tokenA), address(swapTarget));

        uint256 amountIn = 100e18;
        _fundSwapperWithTokenA(amountIn);

        swapper.swapSimple(0, _makeSwapData(amountIn));

        assertEq(tokenB.balanceOf(address(swapper)), 100e18);
        assertEq(tokenA.balanceOf(address(swapper)), 0);
    }

    // ==========================
    // wrap tests
    // ==========================

    function test_wrap_basic() public {
        MockWETH weth = new MockWETH();

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(Swapper.wrap, (address(weth)));

        swapper.multicall{value: 1 ether}(calls);

        assertEq(weth.balanceOf(address(swapper)), 1 ether);
        assertEq(address(swapper).balance, 0);
    }

    function test_wrap_payable() public {
        MockWETH weth = new MockWETH();

        swapper.wrap{value: 2 ether}(address(weth));

        assertEq(weth.balanceOf(address(swapper)), 2 ether);
    }

    function test_wrap_noOpWhenZeroBalance() public {
        MockWETH weth = new MockWETH();

        swapper.wrap(address(weth));
        assertEq(weth.balanceOf(address(swapper)), 0);
    }

    // ==========================
    // unwrap tests
    // ==========================

    function test_unwrap_basic() public {
        MockWETH weth = new MockWETH();

        swapper.wrap{value: 3 ether}(address(weth));
        swapper.unwrap(address(weth), 1 ether);

        assertEq(weth.balanceOf(address(swapper)), 2 ether);
        assertEq(address(swapper).balance, 1 ether);
    }

    function test_unwrap_maxAmount() public {
        MockWETH weth = new MockWETH();

        swapper.wrap{value: 5 ether}(address(weth));
        swapper.unwrap(address(weth), type(uint256).max);

        assertEq(weth.balanceOf(address(swapper)), 0);
        assertEq(address(swapper).balance, 5 ether);
    }

    function test_unwrap_noOpWhenZero() public {
        MockWETH weth = new MockWETH();

        swapper.unwrap(address(weth), 0);
        assertEq(address(swapper).balance, 0);
    }

    // ==========================
    // sweepNative tests
    // ==========================

    function test_sweepNative_basic() public {
        MockWETH weth = new MockWETH();
        swapper.wrap{value: 1 ether}(address(weth));
        swapper.unwrap(address(weth), type(uint256).max);

        uint256 receiverBalBefore = receiver.balance;
        swapper.sweepNative(0, receiver);

        assertEq(receiver.balance - receiverBalBefore, 1 ether);
        assertEq(address(swapper).balance, 0);
    }

    function test_sweepNative_revertsIfBelowMin() public {
        vm.deal(address(swapper), 0.5 ether);

        vm.expectRevert(ISwapper.Swapper_InsufficientBalance.selector);
        swapper.sweepNative(1 ether, receiver);
    }

    function test_sweepNative_noOpWhenZeroBalance() public {
        swapper.sweepNative(0, receiver);
        // No revert, no transfer
    }

    function test_sweepNative_revertsOnFailedTransfer() public {
        RejectETH rejectETH = new RejectETH();
        vm.deal(address(swapper), 1 ether);

        vm.expectRevert(ISwapper.Swapper_NativeTransferFailed.selector);
        swapper.sweepNative(0, address(rejectETH));
    }

    // ==========================
    // Native swap tests
    // ==========================

    function test_swapSimple_native() public {
        MockSwapTargetETH ethTarget = new MockSwapTargetETH(tokenB, 1e18); // 1:1 rate
        bytes memory payload = abi.encodeCall(MockSwapTargetETH.swap, ());
        bytes memory data = abi.encode(address(ethTarget), payload);

        swapper.swapSimple{value: 1 ether}(1 ether, data);

        assertEq(tokenB.balanceOf(address(swapper)), 1 ether);
        assertEq(address(swapper).balance, 0);
    }

    // ==========================
    // Multicall native flow tests
    // ==========================

    function test_multicall_wrapSwapDeposit() public {
        MockWETH weth = new MockWETH();
        MockSwapTarget wethSwapTarget = new MockSwapTarget(MockERC20(address(weth)), tokenB, 1e18);

        bytes memory swapPayload = abi.encodeCall(MockSwapTarget.swap, (1 ether));
        bytes memory swapData = abi.encode(address(wethSwapTarget), swapPayload);

        bytes[] memory calls = new bytes[](5);
        calls[0] = abi.encodeCall(Swapper.wrap, (address(weth)));
        calls[1] = abi.encodeCall(Swapper.approve, (address(weth), address(wethSwapTarget)));
        calls[2] = abi.encodeCall(Swapper.approve, (address(tokenB), address(vault)));
        calls[3] = abi.encodeCall(Swapper.swapSimple, (0, swapData));
        calls[4] = abi.encodeCall(Swapper.deposit, (address(tokenB), address(vault), 0, user));

        swapper.multicall{value: 1 ether}(calls);

        assertEq(vault.deposits(user), 1 ether);
        assertEq(address(swapper).balance, 0);
    }

    function test_multicall_nativeSwapDeposit() public {
        MockSwapTargetETH ethTarget = new MockSwapTargetETH(tokenB, 1e18);
        bytes memory payload = abi.encodeCall(MockSwapTargetETH.swap, ());
        bytes memory data = abi.encode(address(ethTarget), payload);

        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(Swapper.approve, (address(tokenB), address(vault)));
        calls[1] = abi.encodeCall(Swapper.swapSimple, (1 ether, data));
        calls[2] = abi.encodeCall(Swapper.deposit, (address(tokenB), address(vault), 0, user));

        swapper.multicall{value: 1 ether}(calls);

        assertEq(vault.deposits(user), 1 ether);
        assertEq(address(swapper).balance, 0);
    }

    function test_multicall_swapUnwrapSweepNative() public {
        MockWETH weth = new MockWETH();
        vm.deal(address(this), 10 ether);

        weth.deposit{value: 1 ether}();
        MockERC20(address(weth)).transfer(address(swapper), 1 ether);

        uint256 receiverBalBefore = receiver.balance;

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Swapper.unwrap, (address(weth), type(uint256).max));
        calls[1] = abi.encodeCall(Swapper.sweepNative, (0.9 ether, receiver));

        swapper.multicall(calls);

        assertEq(receiver.balance - receiverBalBefore, 1 ether);
        assertEq(address(swapper).balance, 0);
    }
}
