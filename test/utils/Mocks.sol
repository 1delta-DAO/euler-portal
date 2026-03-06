// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.24;

import {IERC20} from "../../contracts/interfaces/IERC20.sol";
import {IPermit2} from "../../contracts/interfaces/IPermit2.sol";
import {Orchestrator} from "../../contracts/Orchestrator.sol";

// ============ Token Mocks ============

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
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

/// @dev Token that returns no value on transfer/approve (USDT-style)
contract MockERC20NoReturnValue {
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount);
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        require(balanceOf[from] >= amount);
        if (msg.sender != from) {
            require(allowance[from][msg.sender] >= amount);
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Token that requires allowance to be 0 before setting a new value (USDT-style)
contract MockERC20RequiresZeroAllowance {
    string public name = "USDT Mock";
    string public symbol = "USDTM";
    uint8 public decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        require(amount == 0 || allowance[msg.sender][spender] == 0, "reset allowance first");
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
        require(allowance[from][msg.sender] >= amount, "insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// ============ WETH Mock ============

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

// ============ Permit2 Mock ============

contract MockPermit2 {
    mapping(address => mapping(address => mapping(address => uint160))) public allowance;
    bool public shouldRevertBatch;

    function transferFrom(address from, address to, uint160 amount, address token) external {
        uint160 currentAllowance = allowance[token][from][msg.sender];
        require(currentAllowance >= amount, "MockPermit2: insufficient allowance");
        allowance[token][from][msg.sender] = currentAllowance - amount;

        (bool success,) = token.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, uint256(amount)));
        require(success, "MockPermit2: transfer failed");
    }

    function approve(address token, address from, address spender, uint160 amount) external {
        allowance[token][from][spender] = amount;
    }

    function setShouldRevertBatch(bool _shouldRevert) external {
        shouldRevertBatch = _shouldRevert;
    }

    function permitTransferFrom(
        IPermit2.PermitTransferFrom memory permit,
        IPermit2.SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata
    )
        external
    {
        if (shouldRevertBatch) revert("MockPermit2: reverted");

        (bool success,) = permit.permitted.token
            .call(
                abi.encodeWithSignature(
                    "transferFrom(address,address,uint256)", owner, transferDetails.to, transferDetails.requestedAmount
                )
            );
        require(success, "MockPermit2: transfer failed");
    }

    function permitTransferFrom(
        IPermit2.PermitBatchTransferFrom memory permit,
        IPermit2.SignatureTransferDetails[] calldata transferDetails,
        address owner,
        bytes calldata
    )
        external
    {
        if (shouldRevertBatch) revert("MockPermit2: batch reverted");

        require(permit.permitted.length == transferDetails.length, "MockPermit2: length mismatch");

        for (uint256 i; i < transferDetails.length; i++) {
            address token = permit.permitted[i].token;
            uint256 amount = transferDetails[i].requestedAmount;
            address to = transferDetails[i].to;

            (bool success,) = token.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", owner, to, amount));
            require(success, "MockPermit2: transfer failed");
        }
    }
}

/// @dev Mock for Permit2 SignatureTransfer batch — transfers tokens from owner on permitTransferFrom
contract MockPermit2SignatureTransfer {
    bool public shouldRevert;

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function permitTransferFrom(
        IPermit2.PermitBatchTransferFrom memory permit,
        IPermit2.SignatureTransferDetails[] calldata transferDetails,
        address owner,
        bytes calldata
    )
        external
    {
        if (shouldRevert) revert("MockPermit2SignatureTransfer: reverted");

        require(permit.permitted.length == transferDetails.length, "MockPermit2SignatureTransfer: length mismatch");

        for (uint256 i; i < transferDetails.length; i++) {
            address token = permit.permitted[i].token;
            uint256 amount = transferDetails[i].requestedAmount;
            address to = transferDetails[i].to;

            (bool success,) = token.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", owner, to, amount));
            require(success, "MockPermit2SignatureTransfer: transfer failed");
        }
    }
}

// ============ Vault Mock ============

contract MockVault {
    MockERC20 public asset;

    mapping(address => uint256) public deposits;
    mapping(address => uint256) public debts;

    constructor(MockERC20 _asset) {
        asset = _asset;
    }

    function setDebt(address account, uint256 amount) external {
        debts[account] = amount;
    }

    function debtOf(address account) external view returns (uint256) {
        return debts[account];
    }

    function deposit(uint256 amount, address receiver) external returns (uint256) {
        if (amount == type(uint256).max) {
            amount = IERC20(address(asset)).balanceOf(msg.sender);
        }
        asset.transferFrom(msg.sender, address(this), amount);
        deposits[receiver] += amount;
        return amount;
    }

    function repay(uint256 amount, address account) external returns (uint256) {
        uint256 debt = debts[account];
        if (amount > debt) amount = debt;

        uint256 balance = IERC20(address(asset)).balanceOf(msg.sender);
        if (amount > balance) amount = balance;

        asset.transferFrom(msg.sender, address(this), amount);
        debts[account] -= amount;
        return amount;
    }
}

// ============ Swap Target Mocks ============

/// @dev Takes tokenIn from caller, mints tokenOut to caller at a configurable rate
contract MockSwapTarget {
    MockERC20 public tokenIn;
    MockERC20 public tokenOut;
    uint256 public rate; // tokenOut per tokenIn (1:1 = 1e18)

    constructor(MockERC20 _tokenIn, MockERC20 _tokenOut, uint256 _rate) {
        tokenIn = _tokenIn;
        tokenOut = _tokenOut;
        rate = _rate;
    }

    function swap(uint256 amountIn) external {
        tokenIn.transferFrom(msg.sender, address(this), amountIn);
        uint256 amountOut = amountIn * rate / 1e18;
        tokenOut.mint(msg.sender, amountOut);
    }
}

/// @dev Takes native ETH from caller via msg.value, mints tokenOut to caller at a configurable rate
contract MockSwapTargetETH {
    MockERC20 public tokenOut;
    uint256 public rate; // tokenOut per ETH (1:1 = 1e18)

    constructor(MockERC20 _tokenOut, uint256 _rate) {
        tokenOut = _tokenOut;
        rate = _rate;
    }

    function swap() external payable {
        uint256 amountOut = msg.value * rate / 1e18;
        tokenOut.mint(msg.sender, amountOut);
    }
}

/// @dev Swap target that always reverts
contract MockSwapTargetReverting {
    function swap(uint256) external pure {
        revert("swap failed");
    }
}

// ============ Utility Mocks ============

/// @dev ETH receiver that rejects incoming ETH
contract RejectETH {
    receive() external payable {
        revert("no ETH");
    }
}

/// @dev Malicious token that reenters the orchestrator on transfer
contract ReentrantToken {
    Orchestrator public target;
    bool public attacking;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function setTarget(Orchestrator _target) external {
        target = _target;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;

        if (!attacking && address(target) != address(0)) {
            attacking = true;
            target.sweep(address(this), 0, msg.sender);
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
