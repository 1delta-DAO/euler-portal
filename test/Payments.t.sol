// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Payments} from "../contracts/Payments.sol";
import {EthereumVaultConnector} from "ethereum-vault-connector/EthereumVaultConnector.sol";
import {IEVC} from "ethereum-vault-connector/interfaces/IEthereumVaultConnector.sol";
import {IERC20} from "../contracts/interfaces/IERC20.sol";
import {IPermit2} from "../contracts/interfaces/IPermit2.sol";

// ============ Mock Contracts ============

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient balance");
        if (msg.sender != from) {
            require(allowance[from][msg.sender] >= amount, "insufficient allowance");
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Returns false on transferFrom (USDT-like behavior)
contract MockERC20NoReturnValue {
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
        // no return value
    }

    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount);
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        // no return value
    }

    function transferFrom(address from, address to, uint256 amount) external {
        require(balanceOf[from] >= amount);
        if (msg.sender != from) {
            require(allowance[from][msg.sender] >= amount);
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        // no return value
    }
}

contract MockWETH {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient balance");
        if (msg.sender != from) {
            require(allowance[from][msg.sender] >= amount, "insufficient allowance");
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

/// @dev Mock Permit2 that implements transferFrom
contract MockPermit2 {
    mapping(address => mapping(address => mapping(address => uint160))) public allowance;

    function permit(address owner, IPermit2.PermitSingle memory permitSingle, bytes calldata) external {
        allowance[permitSingle.details.token][owner][permitSingle.spender] = permitSingle.details.amount;
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        uint160 currentAllowance = allowance[token][from][msg.sender];
        require(currentAllowance >= amount, "MockPermit2: insufficient allowance");
        allowance[token][from][msg.sender] = currentAllowance - amount;

        // Do the actual transfer
        (bool success,) =
            token.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, uint256(amount)));
        require(success, "MockPermit2: transfer failed");
    }

    function approve(address token, address from, address spender, uint160 amount) external {
        allowance[token][from][spender] = amount;
    }
}

/// @dev ETH receiver that rejects incoming ETH
contract RejectETH {
    receive() external payable {
        revert("no ETH");
    }
}

// ============ Tests ============

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
        token = new MockERC20("Test Token", "TST");
        weth = new MockWETH();

        (user, userPk) = makeAddrAndKey("user");
        receiver = makeAddr("receiver");

        // Fund user with tokens
        token.mint(user, 1000e18);
    }

    // ==============================
    // Core Transfer Tests
    // ==============================

    function test_transfer_basic() public {
        // User approves Payments contract directly
        vm.prank(user);
        token.approve(address(payments), 100e18);

        // Transfer via EVC call
        vm.prank(user);
        evc.call(
            address(payments), user, 0, abi.encodeCall(Payments.transfer, (address(token), receiver, 100e18))
        );

        assertEq(token.balanceOf(receiver), 100e18);
        assertEq(token.balanceOf(user), 900e18);
    }

    function test_transfer_directCall() public {
        // User approves Payments contract
        vm.prank(user);
        token.approve(address(payments), 100e18);

        // Direct call (should route through EVC via callThroughEVC)
        vm.prank(user);
        payments.transfer(address(token), receiver, 100e18);

        assertEq(token.balanceOf(receiver), 100e18);
    }

    function test_transfer_viaPermit2() public {
        // User approves Permit2 to spend tokens
        vm.prank(user);
        token.approve(address(permit2Mock), type(uint256).max);

        // Set Permit2 allowance for Payments contract
        permit2Mock.approve(address(token), user, address(payments), type(uint160).max);

        // Transfer should go via Permit2 path
        vm.prank(user);
        payments.transfer(address(token), receiver, 100e18);

        assertEq(token.balanceOf(receiver), 100e18);
    }

    function test_transfer_inEVCBatch() public {
        address receiver2 = makeAddr("receiver2");

        vm.prank(user);
        token.approve(address(payments), 200e18);

        // Batch: two transfers atomically
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
        vm.expectRevert(Payments.E_InvalidAmount.selector);
        payments.transfer(address(token), receiver, 0);
    }

    function test_transfer_revertsOnZeroReceiver() public {
        vm.prank(user);
        vm.expectRevert(Payments.E_InvalidReceiver.selector);
        payments.transfer(address(token), address(0), 100e18);
    }

    function test_transfer_revertsOnSubAccountReceiver() public {
        // Register user's owner on EVC by enabling a collateral (this registers the owner prefix)
        vm.prank(user);
        evc.enableCollateral(user, address(payments));

        // Create a sub-account address (XOR user with non-zero account ID)
        address subAccount = address(uint160(user) ^ 1);

        vm.prank(user);
        token.approve(address(payments), 100e18);

        // Transfer to sub-account should revert
        vm.prank(user);
        vm.expectRevert(Payments.E_InvalidReceiver.selector);
        payments.transfer(address(token), subAccount, 100e18);
    }

    function test_transfer_revertsOnInsufficientApproval() public {
        // No approval given, no permit2 allowance
        vm.prank(user);
        vm.expectRevert(); // SafeERC20Lib.E_TransferFromFailed
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
        // User approves Permit2 to spend tokens (for the underlying transferFrom)
        vm.prank(user);
        token.approve(address(permit2Mock), type(uint256).max);

        // Call transferWithPermit2 — the MockPermit2.permit will set the allowance
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
        // User should get 2 ether back (minus gas, approximately)
        assertEq(user.balance, balBefore - 1 ether);
    }

    function test_wrapAndTransfer_revertsOnInsufficientValue() public {
        vm.deal(user, 10 ether);

        vm.prank(user);
        vm.expectRevert(Payments.E_InsufficientMsgValue.selector);
        payments.wrapAndTransfer{value: 0.5 ether}(address(weth), receiver, 1 ether);
    }

    function test_unwrapAndTransfer_basic() public {
        // Give user some WETH
        vm.deal(user, 10 ether);
        vm.prank(user);
        weth.deposit{value: 5 ether}();

        // User approves Payments to pull WETH
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
        vm.expectRevert(Payments.E_InvalidAmount.selector);
        payments.transferNative{value: 0}(receiver);
    }

    function test_transferNative_revertsOnRejectingReceiver() public {
        RejectETH rejectETH = new RejectETH();
        vm.deal(user, 10 ether);

        vm.prank(user);
        vm.expectRevert(Payments.E_NativeTransferFailed.selector);
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
        emit Payments.Transfer(address(token), user, receiver, 100e18);

        vm.prank(user);
        payments.transfer(address(token), receiver, 100e18);
    }

    function test_transferNative_emitsEvent() public {
        vm.deal(user, 10 ether);

        vm.expectEmit(true, true, true, true);
        emit Payments.NativeTransfer(user, receiver, 1 ether);

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

        // User approves Payments contract to spend their tokens
        vm.prank(user);
        token.approve(address(payments), 1000e18);

        // Attacker calls transfer directly — callThroughEVC routes through EVC,
        // _msgSender() resolves to attacker (not user), so transferFrom pulls from attacker who has no tokens
        vm.prank(attacker);
        vm.expectRevert(); // transferFrom fails: attacker has no balance
        payments.transfer(address(token), attacker, 100e18);

        // User's funds are untouched
        assertEq(token.balanceOf(user), 1000e18);
        assertEq(token.balanceOf(attacker), 0);
    }

    function test_auth_attackerCannotStealViaEVCCall() public {
        address attacker = makeAddr("attacker");

        // User approves Payments contract
        vm.prank(user);
        token.approve(address(payments), 1000e18);

        // Attacker tries to call via EVC with onBehalfOfAccount = user
        // EVC rejects: attacker is not the owner or operator of user's account
        vm.prank(attacker);
        vm.expectRevert(); // EVC: not authorized
        evc.call(
            address(payments), user, 0, abi.encodeCall(Payments.transfer, (address(token), attacker, 100e18))
        );

        assertEq(token.balanceOf(user), 1000e18);
        assertEq(token.balanceOf(attacker), 0);
    }

    function test_auth_attackerCannotStealViaBatch() public {
        address attacker = makeAddr("attacker");

        // User approves Payments contract
        vm.prank(user);
        token.approve(address(payments), 1000e18);

        // Attacker tries a batch with onBehalfOfAccount = user
        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](1);
        items[0] = IEVC.BatchItem({
            targetContract: address(payments),
            onBehalfOfAccount: user,
            value: 0,
            data: abi.encodeCall(Payments.transfer, (address(token), attacker, 100e18))
        });

        vm.prank(attacker);
        vm.expectRevert(); // EVC: not authorized
        evc.batch(items);

        assertEq(token.balanceOf(user), 1000e18);
        assertEq(token.balanceOf(attacker), 0);
    }

    function test_auth_attackerCannotStealNativeViaDirectCall() public {
        address attacker = makeAddr("attacker");
        vm.deal(user, 10 ether);

        uint256 receiverBalBefore = attacker.balance;

        // Attacker calls transferNative — even though they send 0 value, they can't drain user's ETH
        // because msg.value comes from the caller (attacker), not from the authenticated sender
        vm.prank(attacker);
        vm.expectRevert(Payments.E_InvalidAmount.selector); // msg.value == 0
        payments.transferNative(attacker);

        assertEq(attacker.balance, receiverBalBefore);
    }

    function test_auth_attackerCannotStealWETHViaUnwrap() public {
        address attacker = makeAddr("attacker");

        // User wraps ETH and approves Payments
        vm.deal(user, 10 ether);
        vm.prank(user);
        weth.deposit{value: 5 ether}();
        vm.prank(user);
        MockERC20(address(weth)).approve(address(payments), 5 ether);

        // Attacker tries unwrapAndTransfer directly — _msgSender() = attacker, who has no WETH
        vm.prank(attacker);
        vm.expectRevert(); // transferFrom fails: attacker has no WETH balance
        payments.unwrapAndTransfer(address(weth), attacker, 1 ether);

        assertEq(weth.balanceOf(user), 5 ether);
    }

    function test_auth_authorizedOperatorCanTransfer() public {
        address operator = makeAddr("operator");

        // User approves Payments contract
        vm.prank(user);
        token.approve(address(payments), 100e18);

        // User authorizes operator on EVC
        vm.prank(user);
        evc.setAccountOperator(user, operator, true);

        // Operator can now call transfer on behalf of user via EVC
        vm.prank(operator);
        evc.call(
            address(payments), user, 0, abi.encodeCall(Payments.transfer, (address(token), receiver, 100e18))
        );

        // Transfer succeeded — operator legitimately moved user's funds to receiver
        assertEq(token.balanceOf(receiver), 100e18);
        assertEq(token.balanceOf(user), 900e18);
        // Operator did NOT receive the funds — they went to receiver
        assertEq(token.balanceOf(operator), 0);
    }

    function test_auth_revokedOperatorCannotTransfer() public {
        address operator = makeAddr("operator");

        // User approves Payments contract
        vm.prank(user);
        token.approve(address(payments), 100e18);

        // User authorizes then revokes operator
        vm.prank(user);
        evc.setAccountOperator(user, operator, true);
        vm.prank(user);
        evc.setAccountOperator(user, operator, false);

        // Revoked operator can no longer call on behalf of user
        vm.prank(operator);
        vm.expectRevert(); // EVC: not authorized
        evc.call(
            address(payments), user, 0, abi.encodeCall(Payments.transfer, (address(token), receiver, 100e18))
        );

        assertEq(token.balanceOf(user), 1000e18);
    }

    function test_auth_operatorCannotTransferForNonAuthorizedAccount() public {
        address operator = makeAddr("operator");
        address otherUser = makeAddr("otherUser");
        token.mint(otherUser, 500e18);

        // otherUser approves Payments
        vm.prank(otherUser);
        token.approve(address(payments), 500e18);

        // User authorizes operator, but otherUser does NOT
        vm.prank(user);
        evc.setAccountOperator(user, operator, true);

        // Operator tries to transfer on behalf of otherUser — should fail
        vm.prank(operator);
        vm.expectRevert(); // EVC: not authorized for otherUser
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
