// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.0;

/// @title IVault
/// @notice Minimal vault interface for deposit, repay, and debt queries
interface IVault {
    function deposit(uint256 amount, address receiver) external returns (uint256);
    function repay(uint256 amount, address receiver) external returns (uint256);
    function debtOf(address account) external view returns (uint256);
}
