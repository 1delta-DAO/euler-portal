// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.0;

interface IPermit2 {
    struct PermitDetails {
        address token;
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    struct PermitSingle {
        PermitDetails details;
        address spender;
        uint256 sigDeadline;
    }

    function transferFrom(address from, address to, uint160 amount, address token) external;
    function permit(address owner, PermitSingle memory permitSingle, bytes calldata signature) external;
}
