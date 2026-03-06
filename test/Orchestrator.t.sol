// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Orchestrator} from "../contracts/Orchestrator.sol";
import {IOrchestrator} from "../contracts/interfaces/IOrchestrator.sol";
import {SafeERC20Lib} from "../contracts/lib/SafeERC20Lib.sol";
import {Erc20Lib} from "../contracts/lib/Erc20Lib.sol";

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

contract OrchestratorTest is Test {
    Orchestrator public orchestrator;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockSwapTarget public swapTarget;
    MockVault public vault;

    address public user = makeAddr("user");
    address public receiver = makeAddr("receiver");

    function setUp() public {
        orchestrator = new Orchestrator();
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

    function _fundOrchestratorWithTokenA(uint256 amount) internal {
        tokenA.mint(address(orchestrator), amount);
    }

    function _fundOrchestratorWithTokenB(uint256 amount) internal {
        tokenB.mint(address(orchestrator), amount);
    }

    /// @dev Approve tokenIn to swapTarget and tokenOut to vault (common setup for swap+vault tests)
    function _approveSwapAndVault() internal {
        orchestrator.approve(address(tokenA), address(swapTarget));
        orchestrator.approve(address(tokenB), address(vault));
    }

    // ==========================
    // swapSimple tests
    // ==========================

    function test_swapSimple_basic() public {
        uint256 amountIn = 100e18;
        _fundOrchestratorWithTokenA(amountIn);
        orchestrator.approve(address(tokenA), address(swapTarget));

        orchestrator.swapSimple(0, _makeSwapData(amountIn));

        assertEq(tokenB.balanceOf(address(orchestrator)), 100e18);
        assertEq(tokenA.balanceOf(address(orchestrator)), 0);
    }

    function test_swapSimple_revertsOnFailedSwap() public {
        MockSwapTargetReverting badTarget = new MockSwapTargetReverting();
        bytes memory data = abi.encode(address(badTarget), abi.encodeCall(MockSwapTargetReverting.swap, (100)));

        vm.expectRevert();
        orchestrator.swapSimple(0, data);
    }

    function test_swapSimple_revertsOnNoCodeTarget() public {
        address noCode = makeAddr("noCode");
        bytes memory data = abi.encode(noCode, bytes(""));

        vm.expectRevert();
        orchestrator.swapSimple(0, data);
    }

    // ==========================
    // deposit tests
    // ==========================

    function test_deposit_basic() public {
        _fundOrchestratorWithTokenB(100e18);
        orchestrator.approve(address(tokenB), address(vault));

        orchestrator.deposit(address(tokenB), address(vault), 0, user);

        assertEq(vault.deposits(user), 100e18);
        assertEq(tokenB.balanceOf(address(orchestrator)), 0);
    }

    function test_deposit_revertsIfBelowMin() public {
        _fundOrchestratorWithTokenB(50e18);

        vm.expectRevert(Erc20Lib.InsufficientBalance.selector);
        orchestrator.deposit(address(tokenB), address(vault), 100e18, user);
    }

    function test_deposit_noOpWhenZeroBalance() public {
        orchestrator.deposit(address(tokenB), address(vault), 0, user);
        assertEq(vault.deposits(user), 0);
    }

    function test_deposit_withSlippageCheck() public {
        _fundOrchestratorWithTokenB(100e18);
        orchestrator.approve(address(tokenB), address(vault));

        orchestrator.deposit(address(tokenB), address(vault), 99e18, user);
        assertEq(vault.deposits(user), 100e18);
    }

    // ==========================
    // repay tests
    // ==========================

    function test_repay_basic() public {
        _fundOrchestratorWithTokenB(100e18);
        orchestrator.approve(address(tokenB), address(vault));
        vault.setDebt(user, 100e18);

        orchestrator.repay(address(tokenB), address(vault), type(uint256).max, 0, user);

        assertEq(vault.debtOf(user), 0);
    }

    function test_repay_capsToBalance() public {
        _fundOrchestratorWithTokenB(50e18);
        orchestrator.approve(address(tokenB), address(vault));
        vault.setDebt(user, 100e18);

        orchestrator.repay(address(tokenB), address(vault), 80e18, 0, user);

        assertEq(vault.debtOf(user), 50e18);
    }

    function test_repay_capsToDebt() public {
        _fundOrchestratorWithTokenB(100e18);
        orchestrator.approve(address(tokenB), address(vault));
        vault.setDebt(user, 30e18);

        // repayAmount (80) > debt (30) — capped to debt, no revert
        orchestrator.repay(address(tokenB), address(vault), 80e18, 0, user);

        assertEq(vault.debtOf(user), 0);
        // 70 tokens remain in orchestrator (100 - 30)
        assertEq(tokenB.balanceOf(address(orchestrator)), 70e18);
    }

    function test_repayAndDeposit_capsToDebt() public {
        _fundOrchestratorWithTokenB(100e18);
        orchestrator.approve(address(tokenB), address(vault));
        vault.setDebt(user, 30e18);

        // repayAmount (80) > debt (30) — capped to debt, remainder deposited
        orchestrator.repayAndDeposit(address(tokenB), address(vault), 80e18, 0, user);

        assertEq(vault.debtOf(user), 0);
        assertEq(vault.deposits(user), 70e18);
    }

    function test_repay_revertsIfBelowMin() public {
        _fundOrchestratorWithTokenB(10e18);

        vm.expectRevert(Erc20Lib.InsufficientBalance.selector);
        orchestrator.repay(address(tokenB), address(vault), 10e18, 50e18, user);
    }

    function test_repay_noOpWhenZeroBalance() public {
        vault.setDebt(user, 100e18);
        orchestrator.repay(address(tokenB), address(vault), type(uint256).max, 0, user);
        assertEq(vault.debtOf(user), 100e18);
    }

    // ==========================
    // repayAndDeposit tests
    // ==========================

    function test_repayAndDeposit_basic() public {
        _fundOrchestratorWithTokenB(100e18);
        orchestrator.approve(address(tokenB), address(vault));
        vault.setDebt(user, 60e18);

        orchestrator.repayAndDeposit(address(tokenB), address(vault), type(uint256).max, 0, user);

        assertEq(vault.debtOf(user), 0);
        assertEq(vault.deposits(user), 40e18);
    }

    function test_repayAndDeposit_revertsIfBelowMin() public {
        _fundOrchestratorWithTokenB(10e18);

        vm.expectRevert(Erc20Lib.InsufficientBalance.selector);
        orchestrator.repayAndDeposit(address(tokenB), address(vault), type(uint256).max, 50e18, user);
    }

    function test_repayAndDeposit_partialRepay() public {
        _fundOrchestratorWithTokenB(100e18);
        orchestrator.approve(address(tokenB), address(vault));
        vault.setDebt(user, 200e18);

        orchestrator.repayAndDeposit(address(tokenB), address(vault), 70e18, 0, user);

        assertEq(vault.debtOf(user), 130e18);
        assertEq(vault.deposits(user), 30e18);
    }

    // ==========================
    // sweep tests
    // ==========================

    function test_sweep_basic() public {
        _fundOrchestratorWithTokenA(100e18);

        orchestrator.sweep(address(tokenA), 0, receiver);

        assertEq(tokenA.balanceOf(receiver), 100e18);
        assertEq(tokenA.balanceOf(address(orchestrator)), 0);
    }

    function test_sweep_revertsIfBelowMin() public {
        _fundOrchestratorWithTokenA(50e18);

        vm.expectRevert(Erc20Lib.InsufficientBalance.selector);
        orchestrator.sweep(address(tokenA), 100e18, receiver);
    }

    function test_sweep_noOpWhenZeroBalance() public {
        orchestrator.sweep(address(tokenA), 0, receiver);
        assertEq(tokenA.balanceOf(receiver), 0);
    }

    function test_sweep_withSlippageCheck() public {
        _fundOrchestratorWithTokenA(100e18);

        orchestrator.sweep(address(tokenA), 99e18, receiver);
        assertEq(tokenA.balanceOf(receiver), 100e18);
    }

    // ==========================
    // multicall tests
    // ==========================

    function test_multicall_swapAndDeposit() public {
        uint256 amountIn = 100e18;
        _fundOrchestratorWithTokenA(amountIn);

        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(Orchestrator.approve, (address(tokenA), address(swapTarget)));
        calls[1] = abi.encodeCall(Orchestrator.approve, (address(tokenB), address(vault)));
        calls[2] = abi.encodeCall(Orchestrator.swapSimple, (0, _makeSwapData(amountIn)));
        calls[3] = abi.encodeCall(Orchestrator.deposit, (address(tokenB), address(vault), 99e18, user));

        orchestrator.multicall(calls);

        assertEq(vault.deposits(user), 100e18);
        assertEq(tokenB.balanceOf(address(orchestrator)), 0);
    }

    function test_multicall_swapAndSweep() public {
        uint256 amountIn = 100e18;
        _fundOrchestratorWithTokenA(amountIn);

        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(Orchestrator.approve, (address(tokenA), address(swapTarget)));
        calls[1] = abi.encodeCall(Orchestrator.swapSimple, (0, _makeSwapData(amountIn)));
        calls[2] = abi.encodeCall(Orchestrator.sweep, (address(tokenB), 99e18, receiver));

        orchestrator.multicall(calls);

        assertEq(tokenB.balanceOf(receiver), 100e18);
    }

    function test_multicall_revertBubblesUp() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Orchestrator.swapSimple, (0, _makeSwapData(0)));
        calls[1] = abi.encodeCall(Orchestrator.deposit, (address(tokenB), address(vault), 100e18, user));

        vm.expectRevert();
        orchestrator.multicall(calls);
    }

    function test_multicall_multiSwapMultiDeposit() public {
        MockERC20 tokenC = new MockERC20("Token C", "TKNC", 18);
        MockSwapTarget swapTarget2 = new MockSwapTarget(tokenA, tokenC, 2e18);
        MockVault vault2 = new MockVault(tokenC);

        _fundOrchestratorWithTokenA(200e18);

        bytes memory swapData1 =
            abi.encode(address(swapTarget), abi.encodeCall(MockSwapTarget.swap, (100e18)));
        bytes memory swapData2 =
            abi.encode(address(swapTarget2), abi.encodeCall(MockSwapTarget.swap, (100e18)));

        bytes[] memory calls = new bytes[](8);
        calls[0] = abi.encodeCall(Orchestrator.approve, (address(tokenA), address(swapTarget)));
        calls[1] = abi.encodeCall(Orchestrator.approve, (address(tokenA), address(swapTarget2)));
        calls[2] = abi.encodeCall(Orchestrator.approve, (address(tokenB), address(vault)));
        calls[3] = abi.encodeCall(Orchestrator.approve, (address(tokenC), address(vault2)));
        calls[4] = abi.encodeCall(Orchestrator.swapSimple, (0, swapData1));
        calls[5] = abi.encodeCall(Orchestrator.deposit, (address(tokenB), address(vault), 0, user));
        calls[6] = abi.encodeCall(Orchestrator.swapSimple, (0, swapData2));
        calls[7] = abi.encodeCall(Orchestrator.deposit, (address(tokenC), address(vault2), 0, user));

        orchestrator.multicall(calls);

        assertEq(vault.deposits(user), 100e18);
        assertEq(vault2.deposits(user), 200e18);
    }

    // ==========================
    // reentrancy tests
    // ==========================

    function test_reentrancy_blocksExternalReentry() public {
        ReentrantToken malicious = new ReentrantToken();
        malicious.setTarget(orchestrator);
        malicious.mint(address(orchestrator), 100e18);

        vm.expectRevert(SafeERC20Lib.E_TransferFailed.selector);
        orchestrator.sweep(address(malicious), 0, receiver);
    }

    // ==========================
    // USDT-style approval tests
    // ==========================

    function test_approval_usdtStyleToken() public {
        MockERC20RequiresZeroAllowance usdtToken = new MockERC20RequiresZeroAllowance();
        usdtToken.mint(address(orchestrator), 100e6);

        orchestrator.sweep(address(usdtToken), 0, receiver);
        assertEq(usdtToken.balanceOf(receiver), 100e6);
    }

    // ==========================
    // approve tests
    // ==========================

    function test_approve_basic() public {
        orchestrator.approve(address(tokenA), address(swapTarget));

        assertEq(tokenA.allowance(address(orchestrator), address(swapTarget)), type(uint256).max);
    }

    function test_approve_cachedSkipsRedundantCall() public {
        orchestrator.approve(address(tokenA), address(swapTarget));
        assertEq(tokenA.allowance(address(orchestrator), address(swapTarget)), type(uint256).max);

        // Verify cache by using a USDT-style token that would revert on non-zero-to-non-zero approve
        MockERC20RequiresZeroAllowance usdtToken = new MockERC20RequiresZeroAllowance();
        usdtToken.mint(address(orchestrator), 200e6);

        // First approve works
        orchestrator.approve(address(usdtToken), address(vault));

        // Second approve should be a no-op (cached), so it won't hit the USDT revert
        orchestrator.approve(address(usdtToken), address(vault));
    }

    function test_approve_separateSpenderFromRouter() public {
        address separateRouter = makeAddr("separateRouter");
        orchestrator.approve(address(tokenA), separateRouter);

        assertEq(tokenA.allowance(address(orchestrator), separateRouter), type(uint256).max);
    }

    function test_approve_usedInMulticall() public {
        uint256 amountIn = 100e18;
        _fundOrchestratorWithTokenA(amountIn);

        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(Orchestrator.approve, (address(tokenA), address(swapTarget)));
        calls[1] = abi.encodeCall(Orchestrator.swapSimple, (0, _makeSwapData(amountIn)));
        calls[2] = abi.encodeCall(Orchestrator.sweep, (address(tokenB), 99e18, receiver));

        orchestrator.multicall(calls);

        assertEq(tokenB.balanceOf(receiver), 100e18);
    }

    function test_approve_swapReusesCachedApproval() public {
        // Pre-approve tokenA to swapTarget
        orchestrator.approve(address(tokenA), address(swapTarget));

        uint256 amountIn = 100e18;
        _fundOrchestratorWithTokenA(amountIn);

        orchestrator.swapSimple(0, _makeSwapData(amountIn));

        assertEq(tokenB.balanceOf(address(orchestrator)), 100e18);
        assertEq(tokenA.balanceOf(address(orchestrator)), 0);
    }

    // ==========================
    // wrap tests
    // ==========================

    function test_wrap_basic() public {
        MockWETH weth = new MockWETH();

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(Orchestrator.wrap, (address(weth), type(uint256).max));

        orchestrator.multicall{value: 1 ether}(calls);

        assertEq(weth.balanceOf(address(orchestrator)), 1 ether);
        assertEq(address(orchestrator).balance, 0);
    }

    function test_wrap_payable() public {
        MockWETH weth = new MockWETH();

        orchestrator.wrap{value: 2 ether}(address(weth), type(uint256).max);

        assertEq(weth.balanceOf(address(orchestrator)), 2 ether);
    }

    function test_wrap_specificAmount() public {
        MockWETH weth = new MockWETH();

        orchestrator.wrap{value: 3 ether}(address(weth), 2 ether);

        assertEq(weth.balanceOf(address(orchestrator)), 2 ether);
        assertEq(address(orchestrator).balance, 1 ether);
    }

    function test_wrap_noOpWhenZeroBalance() public {
        MockWETH weth = new MockWETH();

        orchestrator.wrap(address(weth), type(uint256).max);
        assertEq(weth.balanceOf(address(orchestrator)), 0);
    }

    // ==========================
    // wrapTo tests
    // ==========================

    function test_wrapTo_basic() public {
        MockWETH weth = new MockWETH();

        orchestrator.wrapTo{value: 1 ether}(address(weth), type(uint256).max, receiver);

        assertEq(weth.balanceOf(receiver), 1 ether);
        assertEq(weth.balanceOf(address(orchestrator)), 0);
        assertEq(address(orchestrator).balance, 0);
    }

    function test_wrapTo_specificAmount() public {
        MockWETH weth = new MockWETH();

        orchestrator.wrapTo{value: 3 ether}(address(weth), 2 ether, receiver);

        assertEq(weth.balanceOf(receiver), 2 ether);
        assertEq(weth.balanceOf(address(orchestrator)), 0);
        assertEq(address(orchestrator).balance, 1 ether);
    }

    function test_wrapTo_noOpWhenZeroBalance() public {
        MockWETH weth = new MockWETH();

        orchestrator.wrapTo(address(weth), type(uint256).max, receiver);
        assertEq(weth.balanceOf(receiver), 0);
    }

    function test_wrapTo_inMulticall() public {
        MockWETH weth = new MockWETH();

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(Orchestrator.wrapTo, (address(weth), type(uint256).max, receiver));

        orchestrator.multicall{value: 1 ether}(calls);

        assertEq(weth.balanceOf(receiver), 1 ether);
        assertEq(address(orchestrator).balance, 0);
    }

    // ==========================
    // unwrap tests
    // ==========================

    function test_unwrap_basic() public {
        MockWETH weth = new MockWETH();

        orchestrator.wrap{value: 3 ether}(address(weth), type(uint256).max);
        orchestrator.unwrap(address(weth), 1 ether);

        assertEq(weth.balanceOf(address(orchestrator)), 2 ether);
        assertEq(address(orchestrator).balance, 1 ether);
    }

    function test_unwrap_maxAmount() public {
        MockWETH weth = new MockWETH();

        orchestrator.wrap{value: 5 ether}(address(weth), type(uint256).max);
        orchestrator.unwrap(address(weth), type(uint256).max);

        assertEq(weth.balanceOf(address(orchestrator)), 0);
        assertEq(address(orchestrator).balance, 5 ether);
    }

    function test_unwrap_noOpWhenZero() public {
        MockWETH weth = new MockWETH();

        orchestrator.unwrap(address(weth), 0);
        assertEq(address(orchestrator).balance, 0);
    }

    // ==========================
    // unwrapTo tests
    // ==========================

    function test_unwrapTo_basic() public {
        MockWETH weth = new MockWETH();

        orchestrator.wrap{value: 3 ether}(address(weth), type(uint256).max);

        uint256 receiverBalBefore = receiver.balance;
        orchestrator.unwrapTo(address(weth), 1 ether, receiver);

        assertEq(receiver.balance - receiverBalBefore, 1 ether);
        assertEq(weth.balanceOf(address(orchestrator)), 2 ether);
    }

    function test_unwrapTo_maxAmount() public {
        MockWETH weth = new MockWETH();

        orchestrator.wrap{value: 5 ether}(address(weth), type(uint256).max);

        uint256 receiverBalBefore = receiver.balance;
        orchestrator.unwrapTo(address(weth), type(uint256).max, receiver);

        assertEq(receiver.balance - receiverBalBefore, 5 ether);
        assertEq(weth.balanceOf(address(orchestrator)), 0);
        assertEq(address(orchestrator).balance, 0);
    }

    function test_unwrapTo_noOpWhenZero() public {
        MockWETH weth = new MockWETH();

        orchestrator.unwrapTo(address(weth), type(uint256).max, receiver);
        assertEq(receiver.balance, 0);
    }

    function test_unwrapTo_revertsOnFailedTransfer() public {
        MockWETH weth = new MockWETH();
        RejectETH rejectETH = new RejectETH();

        orchestrator.wrap{value: 1 ether}(address(weth), type(uint256).max);

        vm.expectRevert(IOrchestrator.Orchestrator_NativeTransferFailed.selector);
        orchestrator.unwrapTo(address(weth), type(uint256).max, address(rejectETH));
    }

    function test_unwrapTo_inMulticall() public {
        MockWETH weth = new MockWETH();
        vm.deal(address(this), 10 ether);

        weth.deposit{value: 1 ether}();
        MockERC20(address(weth)).transfer(address(orchestrator), 1 ether);

        uint256 receiverBalBefore = receiver.balance;

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(Orchestrator.unwrapTo, (address(weth), type(uint256).max, receiver));

        orchestrator.multicall(calls);

        assertEq(receiver.balance - receiverBalBefore, 1 ether);
        assertEq(address(orchestrator).balance, 0);
    }

    // ==========================
    // sweepNative tests
    // ==========================

    function test_sweepNative_basic() public {
        MockWETH weth = new MockWETH();
        orchestrator.wrap{value: 1 ether}(address(weth), type(uint256).max);
        orchestrator.unwrap(address(weth), type(uint256).max);

        uint256 receiverBalBefore = receiver.balance;
        orchestrator.sweepNative(0, receiver);

        assertEq(receiver.balance - receiverBalBefore, 1 ether);
        assertEq(address(orchestrator).balance, 0);
    }

    function test_sweepNative_revertsIfBelowMin() public {
        vm.deal(address(orchestrator), 0.5 ether);

        vm.expectRevert(Erc20Lib.InsufficientBalance.selector);
        orchestrator.sweepNative(1 ether, receiver);
    }

    function test_sweepNative_noOpWhenZeroBalance() public {
        orchestrator.sweepNative(0, receiver);
        // No revert, no transfer
    }

    function test_sweepNative_revertsOnFailedTransfer() public {
        RejectETH rejectETH = new RejectETH();
        vm.deal(address(orchestrator), 1 ether);

        vm.expectRevert(IOrchestrator.Orchestrator_NativeTransferFailed.selector);
        orchestrator.sweepNative(0, address(rejectETH));
    }

    // ==========================
    // Native swap tests
    // ==========================

    function test_swapSimple_native() public {
        MockSwapTargetETH ethTarget = new MockSwapTargetETH(tokenB, 1e18); // 1:1 rate
        bytes memory payload = abi.encodeCall(MockSwapTargetETH.swap, ());
        bytes memory data = abi.encode(address(ethTarget), payload);

        orchestrator.swapSimple{value: 1 ether}(1 ether, data);

        assertEq(tokenB.balanceOf(address(orchestrator)), 1 ether);
        assertEq(address(orchestrator).balance, 0);
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
        calls[0] = abi.encodeCall(Orchestrator.wrap, (address(weth), type(uint256).max));
        calls[1] = abi.encodeCall(Orchestrator.approve, (address(weth), address(wethSwapTarget)));
        calls[2] = abi.encodeCall(Orchestrator.approve, (address(tokenB), address(vault)));
        calls[3] = abi.encodeCall(Orchestrator.swapSimple, (0, swapData));
        calls[4] = abi.encodeCall(Orchestrator.deposit, (address(tokenB), address(vault), 0, user));

        orchestrator.multicall{value: 1 ether}(calls);

        assertEq(vault.deposits(user), 1 ether);
        assertEq(address(orchestrator).balance, 0);
    }

    function test_multicall_nativeSwapDeposit() public {
        MockSwapTargetETH ethTarget = new MockSwapTargetETH(tokenB, 1e18);
        bytes memory payload = abi.encodeCall(MockSwapTargetETH.swap, ());
        bytes memory data = abi.encode(address(ethTarget), payload);

        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(Orchestrator.approve, (address(tokenB), address(vault)));
        calls[1] = abi.encodeCall(Orchestrator.swapSimple, (1 ether, data));
        calls[2] = abi.encodeCall(Orchestrator.deposit, (address(tokenB), address(vault), 0, user));

        orchestrator.multicall{value: 1 ether}(calls);

        assertEq(vault.deposits(user), 1 ether);
        assertEq(address(orchestrator).balance, 0);
    }

    function test_multicall_swapUnwrapSweepNative() public {
        MockWETH weth = new MockWETH();
        vm.deal(address(this), 10 ether);

        weth.deposit{value: 1 ether}();
        MockERC20(address(weth)).transfer(address(orchestrator), 1 ether);

        uint256 receiverBalBefore = receiver.balance;

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Orchestrator.unwrap, (address(weth), type(uint256).max));
        calls[1] = abi.encodeCall(Orchestrator.sweepNative, (0.9 ether, receiver));

        orchestrator.multicall(calls);

        assertEq(receiver.balance - receiverBalBefore, 1 ether);
        assertEq(address(orchestrator).balance, 0);
    }

}
