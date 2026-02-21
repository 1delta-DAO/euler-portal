// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Payments} from "../contracts/Payments.sol";
import {IPayments} from "../contracts/interfaces/IPayments.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {IERC20} from "../contracts/interfaces/IERC20.sol";

import {MockERC20, MockERC20NoReturnValue, MockWETH, MockPermit2, RejectETH} from "./utils/Mocks.sol";

contract PaymentsTest is Test {
    EthereumVaultConnector evc;
    Payments payments;
    MockPermit2 permit2Mock;
    MockERC20 token;
    MockWETH weth;

    address user;
    uint256 userPk;
    address receiver;

    function setUp() public {
        evc = new EthereumVaultConnector();
        permit2Mock = new MockPermit2();
        payments = new Payments(address(evc), address(permit2Mock));
        token = new MockERC20("Test Token", "TST", 18);
        weth = new MockWETH();

        (user, userPk) = makeAddrAndKey("user");
        receiver = makeAddr("receiver");

        token.mint(user, 1000e18);
    }

    // ==============================
    // Core Transfer Tests
    // ==============================

    function test_transfer_basic() public {
        vm.prank(user);
        token.approve(address(payments), 100e18);

        vm.prank(user);
        evc.call(address(payments), user, 0, abi.encodeCall(Payments.transfer, (address(token), receiver, 100e18)));

        assertEq(token.balanceOf(receiver), 100e18);
        assertEq(token.balanceOf(user), 900e18);
    }

    function test_transfer_directCall() public {
        vm.prank(user);
        token.approve(address(payments), 100e18);

        vm.prank(user);
        payments.transfer(address(token), receiver, 100e18);

        assertEq(token.balanceOf(receiver), 100e18);
    }

    function test_transfer_viaPermit2() public {
        vm.prank(user);
        token.approve(address(permit2Mock), type(uint256).max);

        permit2Mock.approve(address(token), user, address(payments), type(uint160).max);

        vm.prank(user);
        payments.transfer(address(token), receiver, 100e18);

        assertEq(token.balanceOf(receiver), 100e18);
    }

    function test_transfer_inEVCBatch() public {
        address receiver2 = makeAddr("receiver2");

        vm.prank(user);
        token.approve(address(payments), 200e18);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: address(payments),
            onBehalfOfAccount: user,
            value: 0,
            data: abi.encodeCall(Payments.transfer, (address(token), receiver, 100e18))
        });
        items[1] = IEVC.BatchItem({
            targetContract: address(payments),
            onBehalfOfAccount: user,
            value: 0,
            data: abi.encodeCall(Payments.transfer, (address(token), receiver2, 50e18))
        });

        vm.prank(user);
        evc.batch(items);

        assertEq(token.balanceOf(receiver), 100e18);
        assertEq(token.balanceOf(receiver2), 50e18);
        assertEq(token.balanceOf(user), 850e18);
    }

    function test_transfer_revertsOnZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(IPayments.E_InvalidAmount.selector);
        payments.transfer(address(token), receiver, 0);
    }

    function test_transfer_revertsOnZeroReceiver() public {
        vm.prank(user);
        vm.expectRevert(IPayments.E_InvalidReceiver.selector);
        payments.transfer(address(token), address(0), 100e18);
    }

    function test_transfer_revertsOnSubAccountReceiver() public {
        vm.prank(user);
        evc.enableCollateral(user, address(payments));

        address subAccount = address(uint160(user) ^ 1);

        vm.prank(user);
        token.approve(address(payments), 100e18);

        vm.prank(user);
        vm.expectRevert(IPayments.E_InvalidReceiver.selector);
        payments.transfer(address(token), subAccount, 100e18);
    }

    function test_transfer_revertsOnInsufficientApproval() public {
        vm.prank(user);
        vm.expectRevert();
        payments.transfer(address(token), receiver, 100e18);
    }

    function test_transfer_noReturnValueToken() public {
        MockERC20NoReturnValue noReturnToken = new MockERC20NoReturnValue();
        noReturnToken.mint(user, 1000e6);

        vm.prank(user);
        noReturnToken.approve(address(payments), 100e6);

        vm.prank(user);
        payments.transfer(address(noReturnToken), receiver, 100e6);

        assertEq(noReturnToken.balanceOf(receiver), 100e6);
    }

    // ==============================
    // Permit2 Signature Transfer Tests
    // ==============================

    function test_transferWithPermit2() public {
        vm.prank(user);
        token.approve(address(permit2Mock), type(uint256).max);

        vm.prank(user);
        payments.transferWithPermit2(address(token), receiver, 100e18, 0, block.timestamp + 1 hours, "");

        assertEq(token.balanceOf(receiver), 100e18);
    }

    // ==============================
    // WETH Wrap/Unwrap Tests
    // ==============================

    function test_wrapAndTransfer_basic() public {
        vm.deal(user, 10 ether);

        vm.prank(user);
        payments.wrapAndTransfer{value: 1 ether}(address(weth), receiver, 1 ether);

        assertEq(weth.balanceOf(receiver), 1 ether);
    }

    function test_wrapAndTransfer_refundsExcess() public {
        vm.deal(user, 10 ether);

        uint256 balBefore = user.balance;
        vm.prank(user);
        payments.wrapAndTransfer{value: 3 ether}(address(weth), receiver, 1 ether);

        assertEq(weth.balanceOf(receiver), 1 ether);
        assertEq(user.balance, balBefore - 1 ether);
    }

    function test_wrapAndTransfer_revertsOnInsufficientValue() public {
        vm.deal(user, 10 ether);

        vm.prank(user);
        vm.expectRevert(IPayments.E_InsufficientMsgValue.selector);
        payments.wrapAndTransfer{value: 0.5 ether}(address(weth), receiver, 1 ether);
    }

    function test_unwrapAndTransfer_basic() public {
        vm.deal(user, 10 ether);
        vm.prank(user);
        weth.deposit{value: 5 ether}();

        vm.prank(user);
        MockERC20(address(weth)).approve(address(payments), 1 ether);

        uint256 receiverBalBefore = receiver.balance;

        vm.prank(user);
        payments.unwrapAndTransfer(address(weth), receiver, 1 ether);

        assertEq(receiver.balance - receiverBalBefore, 1 ether);
        assertEq(weth.balanceOf(user), 4 ether);
    }

    function test_transferNative_basic() public {
        vm.deal(user, 10 ether);

        uint256 receiverBalBefore = receiver.balance;

        vm.prank(user);
        payments.transferNative{value: 1 ether}(receiver);

        assertEq(receiver.balance - receiverBalBefore, 1 ether);
    }

    function test_transferNative_revertsOnZeroValue() public {
        vm.prank(user);
        vm.expectRevert(IPayments.E_InvalidAmount.selector);
        payments.transferNative{value: 0}(receiver);
    }

    function test_transferNative_revertsOnRejectingReceiver() public {
        RejectETH rejectETH = new RejectETH();
        vm.deal(user, 10 ether);

        vm.prank(user);
        vm.expectRevert(IPayments.E_NativeTransferFailed.selector);
        payments.transferNative{value: 1 ether}(address(rejectETH));
    }

    // ==============================
    // WETH in EVC Batch
    // ==============================

    function test_wrapAndTransfer_inBatch() public {
        vm.deal(user, 10 ether);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(payments),
            onBehalfOfAccount: user,
            value: 2 ether,
            data: abi.encodeCall(Payments.wrapAndTransfer, (address(weth), receiver, 2 ether))
        });

        vm.prank(user);
        evc.batch{value: 2 ether}(items);

        assertEq(weth.balanceOf(receiver), 2 ether);
    }

    // ==============================
    // Events
    // ==============================

    function test_transfer_emitsEvent() public {
        vm.prank(user);
        token.approve(address(payments), 100e18);

        vm.expectEmit(true, true, true, true);
        emit IPayments.Transfer(address(token), user, receiver, 100e18);

        vm.prank(user);
        payments.transfer(address(token), receiver, 100e18);
    }

    function test_transferNative_emitsEvent() public {
        vm.deal(user, 10 ether);

        vm.expectEmit(true, true, true, true);
        emit IPayments.NativeTransfer(user, receiver, 1 ether);

        vm.prank(user);
        payments.transferNative{value: 1 ether}(receiver);
    }

    // ==============================
    // Constructor
    // ==============================

    function test_constructor_setsImmutables() public view {
        assertEq(payments.EVC(), address(evc));
        assertEq(payments.permit2(), address(permit2Mock));
    }

    function test_constructor_revertsOnZeroEVC() public {
        vm.expectRevert();
        new Payments(address(0), address(permit2Mock));
    }

    // ==============================
    // EVC Authentication Tests
    // ==============================

    function test_auth_attackerCannotStealViaDirectCall() public {
        address attacker = makeAddr("attacker");

        vm.prank(user);
        token.approve(address(payments), 1000e18);

        vm.prank(attacker);
        vm.expectRevert();
        payments.transfer(address(token), attacker, 100e18);

        assertEq(token.balanceOf(user), 1000e18);
        assertEq(token.balanceOf(attacker), 0);
    }

    function test_auth_attackerCannotStealViaEVCCall() public {
        address attacker = makeAddr("attacker");

        vm.prank(user);
        token.approve(address(payments), 1000e18);

        vm.prank(attacker);
        vm.expectRevert();
        evc.call(address(payments), user, 0, abi.encodeCall(Payments.transfer, (address(token), attacker, 100e18)));

        assertEq(token.balanceOf(user), 1000e18);
        assertEq(token.balanceOf(attacker), 0);
    }

    function test_auth_attackerCannotStealViaBatch() public {
        address attacker = makeAddr("attacker");

        vm.prank(user);
        token.approve(address(payments), 1000e18);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(payments),
            onBehalfOfAccount: user,
            value: 0,
            data: abi.encodeCall(Payments.transfer, (address(token), attacker, 100e18))
        });

        vm.prank(attacker);
        vm.expectRevert();
        evc.batch(items);

        assertEq(token.balanceOf(user), 1000e18);
        assertEq(token.balanceOf(attacker), 0);
    }

    function test_auth_attackerCannotStealNativeViaDirectCall() public {
        address attacker = makeAddr("attacker");
        vm.deal(user, 10 ether);

        uint256 receiverBalBefore = attacker.balance;

        vm.prank(attacker);
        vm.expectRevert(IPayments.E_InvalidAmount.selector);
        payments.transferNative(attacker);

        assertEq(attacker.balance, receiverBalBefore);
    }

    function test_auth_attackerCannotStealWETHViaUnwrap() public {
        address attacker = makeAddr("attacker");

        vm.deal(user, 10 ether);
        vm.prank(user);
        weth.deposit{value: 5 ether}();
        vm.prank(user);
        MockERC20(address(weth)).approve(address(payments), 5 ether);

        vm.prank(attacker);
        vm.expectRevert();
        payments.unwrapAndTransfer(address(weth), attacker, 1 ether);

        assertEq(weth.balanceOf(user), 5 ether);
    }

    function test_auth_authorizedOperatorCanTransfer() public {
        address operator = makeAddr("operator");

        vm.prank(user);
        token.approve(address(payments), 100e18);

        vm.prank(user);
        evc.setAccountOperator(user, operator, true);

        vm.prank(operator);
        evc.call(address(payments), user, 0, abi.encodeCall(Payments.transfer, (address(token), receiver, 100e18)));

        assertEq(token.balanceOf(receiver), 100e18);
        assertEq(token.balanceOf(user), 900e18);
        assertEq(token.balanceOf(operator), 0);
    }

    function test_auth_revokedOperatorCannotTransfer() public {
        address operator = makeAddr("operator");

        vm.prank(user);
        token.approve(address(payments), 100e18);

        vm.prank(user);
        evc.setAccountOperator(user, operator, true);
        vm.prank(user);
        evc.setAccountOperator(user, operator, false);

        vm.prank(operator);
        vm.expectRevert();
        evc.call(address(payments), user, 0, abi.encodeCall(Payments.transfer, (address(token), receiver, 100e18)));

        assertEq(token.balanceOf(user), 1000e18);
    }

    function test_auth_operatorCannotTransferForNonAuthorizedAccount() public {
        address operator = makeAddr("operator");
        address otherUser = makeAddr("otherUser");
        token.mint(otherUser, 500e18);

        vm.prank(otherUser);
        token.approve(address(payments), 500e18);

        vm.prank(user);
        evc.setAccountOperator(user, operator, true);

        vm.prank(operator);
        vm.expectRevert();
        evc.call(
            address(payments), otherUser, 0, abi.encodeCall(Payments.transfer, (address(token), operator, 100e18))
        );

        assertEq(token.balanceOf(otherUser), 500e18);
    }

    // ==============================
    // Permit2 disabled (address(0))
    // ==============================

    function test_transfer_withoutPermit2() public {
        Payments paymentsNoPermit2 = new Payments(address(evc), address(0));

        vm.prank(user);
        token.approve(address(paymentsNoPermit2), 100e18);

        vm.prank(user);
        paymentsNoPermit2.transfer(address(token), receiver, 100e18);

        assertEq(token.balanceOf(receiver), 100e18);
    }
}
