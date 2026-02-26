// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Payments} from "../contracts/Payments.sol";
import {IPayments} from "../contracts/interfaces/IPayments.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {IERC20} from "../contracts/interfaces/IERC20.sol";
import {IPermit2} from "../contracts/interfaces/IPermit2.sol";

import {
    MockERC20,
    MockERC20NoReturnValue,
    MockERC20Permit,
    MockDaiPermit,
    MockERC20PermitReverting,
    MockDaiPermitReverting,
    MockWETH,
    MockPermit2,
    RejectETH
} from "./utils/Mocks.sol";

contract PaymentsTest is Test {
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

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

        // Deploy mock permit2 code at the canonical address
        MockPermit2 permit2Impl = new MockPermit2();
        vm.etch(PERMIT2, address(permit2Impl).code);
        permit2Mock = MockPermit2(PERMIT2);

        payments = new Payments(address(evc));
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
    // Permit Utility Tests
    // ==============================

    function test_permit_setsAllowance() public {
        MockERC20Permit permitToken = new MockERC20Permit("Permit Token", "PT", 18);
        permitToken.mint(user, 1000e18);

        payments.permit(address(permitToken), user, 100e18, block.timestamp + 1 hours, 0, bytes32(0), bytes32(0));

        assertEq(permitToken.allowance(user, address(payments)), 100e18);
    }

    function test_permitDai_setsAllowance() public {
        MockDaiPermit daiToken = new MockDaiPermit("Dai Permit", "DAI", 18);
        daiToken.mint(user, 1000e18);

        payments.permitDai(address(daiToken), user, 0, block.timestamp + 1 hours, true, 0, bytes32(0), bytes32(0));

        assertEq(daiToken.allowance(user, address(payments)), type(uint256).max);
    }

    function test_permit2Permit_setsAllowance() public {
        vm.prank(user);
        token.approve(PERMIT2, type(uint256).max);

        payments.permit2Permit(address(token), user, 100e18, 0, block.timestamp + 1 hours, "");

        // MockPermit2 stores allowance[token][owner][spender]
        assertEq(permit2Mock.allowance(address(token), user, address(payments)), 100e18);
    }

    function test_permit_tryCatch_doesNotRevert() public {
        MockERC20PermitReverting revertingToken = new MockERC20PermitReverting();

        // Should not revert despite the permit call reverting
        payments.permit(address(revertingToken), user, 100e18, block.timestamp + 1 hours, 0, bytes32(0), bytes32(0));
    }

    function test_permitDai_tryCatch_doesNotRevert() public {
        MockDaiPermitReverting revertingDai = new MockDaiPermitReverting();

        // Should not revert despite the permit call reverting
        payments.permitDai(address(revertingDai), user, 0, block.timestamp + 1 hours, true, 0, bytes32(0), bytes32(0));
    }

    function test_permit2Permit_tryCatch_doesNotRevert() public {
        // Call with an address that doesn't implement permit — the try/catch should absorb it
        payments.permit2Permit(address(token), user, 100e18, 0, block.timestamp + 1 hours, "");
    }

    function test_permit_thenTransfer() public {
        MockERC20Permit permitToken = new MockERC20Permit("Permit Token", "PT", 18);
        permitToken.mint(user, 1000e18);

        // Step 1: permit (anyone can call — signature is the auth)
        payments.permit(address(permitToken), user, 100e18, block.timestamp + 1 hours, 0, bytes32(0), bytes32(0));

        // Step 2: transfer (EVC-authenticated)
        vm.prank(user);
        payments.transfer(address(permitToken), receiver, 100e18);

        assertEq(permitToken.balanceOf(receiver), 100e18);
    }

    function test_permit2Permit_thenTransfer() public {
        vm.prank(user);
        token.approve(PERMIT2, type(uint256).max);

        // Step 1: permit2Permit (anyone can call — signature is the auth)
        payments.permit2Permit(address(token), user, 100e18, 0, block.timestamp + 1 hours, "");

        // Step 2: transfer (EVC-authenticated, uses Permit2 fallback)
        vm.prank(user);
        payments.transfer(address(token), receiver, 100e18);

        assertEq(token.balanceOf(receiver), 100e18);
    }

    function test_permit_thenTransfer_inBatch() public {
        MockERC20Permit permitToken = new MockERC20Permit("Permit Token", "PT", 18);
        permitToken.mint(user, 1000e18);

        // Permit is called outside the EVC batch (unauthenticated)
        payments.permit(address(permitToken), user, 100e18, block.timestamp + 1 hours, 0, bytes32(0), bytes32(0));

        // Transfer via EVC batch (authenticated)
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(payments),
            onBehalfOfAccount: user,
            value: 0,
            data: abi.encodeCall(Payments.transfer, (address(permitToken), receiver, 100e18))
        });

        vm.prank(user);
        evc.batch(items);

        assertEq(permitToken.balanceOf(receiver), 100e18);
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
        assertEq(payments.permit2(), PERMIT2);
    }

    function test_constructor_revertsOnZeroEVC() public {
        vm.expectRevert();
        new Payments(address(0));
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
    // Permit2 Batch Transfer Tests
    // ==============================

    function test_permit2TransferFrom_basic() public {
        MockERC20 tokenB = new MockERC20("Token B", "TKNB", 18);

        // Fund user with both tokens and approve permit2 to spend them
        vm.startPrank(user);
        token.approve(PERMIT2, type(uint256).max);
        tokenB.approve(PERMIT2, type(uint256).max);
        vm.stopPrank();
        tokenB.mint(user, 50e18);

        // Build batch permit
        IPermit2.TokenPermissions[] memory permitted = new IPermit2.TokenPermissions[](2);
        permitted[0] = IPermit2.TokenPermissions({token: address(token), amount: 100e18});
        permitted[1] = IPermit2.TokenPermissions({token: address(tokenB), amount: 50e18});

        IPermit2.PermitBatchTransferFrom memory batchPermit = IPermit2.PermitBatchTransferFrom({
            permitted: permitted,
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });

        IPermit2.SignatureTransferDetails[] memory details = new IPermit2.SignatureTransferDetails[](2);
        details[0] = IPermit2.SignatureTransferDetails({to: receiver, requestedAmount: 100e18});
        details[1] = IPermit2.SignatureTransferDetails({to: receiver, requestedAmount: 50e18});

        // EVC-authenticated: owner derived from _msgSender()
        vm.prank(user);
        payments.permit2TransferFrom(batchPermit, details, "");

        assertEq(token.balanceOf(receiver), 100e18);
        assertEq(tokenB.balanceOf(receiver), 50e18);
    }

    function test_permit2TransferFrom_revertsOnFailure() public {
        // Set the mock to revert on batch calls
        permit2Mock.setShouldRevertBatch(true);

        IPermit2.TokenPermissions[] memory permitted = new IPermit2.TokenPermissions[](1);
        permitted[0] = IPermit2.TokenPermissions({token: address(token), amount: 100e18});

        IPermit2.PermitBatchTransferFrom memory batchPermit = IPermit2.PermitBatchTransferFrom({
            permitted: permitted,
            nonce: 0,
            deadline: block.timestamp + 1 hours
        });

        IPermit2.SignatureTransferDetails[] memory details = new IPermit2.SignatureTransferDetails[](1);
        details[0] = IPermit2.SignatureTransferDetails({to: receiver, requestedAmount: 100e18});

        vm.prank(user);
        vm.expectRevert();
        payments.permit2TransferFrom(batchPermit, details, "");
    }
}
