// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.24;

import {EVaultTestBase} from "euler-vault-kit/test/unit/evault/EVaultTestBase.t.sol";
import {AccountPositionLens, AccountPositionInfo, VaultPositionInfo} from "../contracts/AccountPositionLens.sol";
import {IEVault} from "evk/EVault/IEVault.sol";

contract AccountPositionLensTest is EVaultTestBase {
    AccountPositionLens lens;

    address user1;
    address user2;
    address user3;

    function setUp() public override {
        super.setUp();

        lens = new AccountPositionLens();

        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        // Set oracle prices for both vault shares
        oracle.setPrice(address(eTST), unitOfAccount, 1e18);
        oracle.setPrice(address(eTST2), unitOfAccount, 1e18);

        // Configure LTV so eTST2 can be collateral for borrowing from eTST
        eTST.setLTV(address(eTST2), 0.9e4, 0.9e4, 0);
    }

    // --- helpers ---

    function _queryBatch(address[] memory accounts) internal view returns (AccountPositionInfo[] memory) {
        return lens.getAccountPositionsBatch(address(evc), accounts);
    }

    function _singleQuery(address account) internal view returns (AccountPositionInfo[] memory) {
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        return _queryBatch(accounts);
    }

    function _setupCollateral(address user, uint256 amount) internal {
        assetTST2.mint(user, amount);
        vm.startPrank(user);
        assetTST2.approve(address(eTST2), type(uint256).max);
        evc.enableCollateral(user, address(eTST2));
        eTST2.deposit(amount, user);
        vm.stopPrank();
    }

    function _setupBorrower(address user, uint256 collateralAmount, uint256 borrowAmount) internal {
        // Deposit collateral
        _setupCollateral(user, collateralAmount);

        // Seed vault with liquidity for borrowing
        assetTST.mint(address(this), borrowAmount);
        assetTST.approve(address(eTST), type(uint256).max);
        eTST.deposit(borrowAmount, address(this));

        // Borrow
        vm.startPrank(user);
        evc.enableController(user, address(eTST));
        eTST.borrow(borrowAmount, user);
        vm.stopPrank();
    }

    // --- tests ---

    function test_emptyBatch() public view {
        address[] memory accounts = new address[](0);
        AccountPositionInfo[] memory results = _queryBatch(accounts);
        assertEq(results.length, 0);
    }

    function test_accountWithNoEnabledVaults() public view {
        AccountPositionInfo[] memory results = _singleQuery(user1);
        assertEq(results.length, 0);
    }

    function test_accountWithEnabledVaultButZeroBalance() public {
        // Enable collateral but don't deposit
        vm.prank(user1);
        evc.enableCollateral(user1, address(eTST2));

        AccountPositionInfo[] memory results = _singleQuery(user1);
        assertEq(results.length, 0, "zero-balance account should be filtered out");
    }

    function test_collateralOnly() public {
        _setupCollateral(user1, 100e18);

        AccountPositionInfo[] memory results = _singleQuery(user1);

        assertEq(results.length, 1);
        assertEq(results[0].account, user1);
        assertEq(results[0].vaults.length, 1);

        VaultPositionInfo memory v = results[0].vaults[0];
        assertEq(v.vault, address(eTST2));
        assertEq(v.asset, address(assetTST2));
        assertEq(v.shares, 100e18);
        assertEq(v.assets, 100e18);
        assertEq(v.borrowed, 0);
        assertFalse(v.isController);
        assertTrue(v.isCollateral);
    }

    function test_borrowerHasControllerAndCollateral() public {
        _setupBorrower(user1, 100e18, 10e18);

        AccountPositionInfo[] memory results = _singleQuery(user1);

        assertEq(results.length, 1);
        assertEq(results[0].account, user1);
        assertEq(results[0].vaults.length, 2, "should have controller + collateral");

        // Controllers come first in the array
        VaultPositionInfo memory controller = results[0].vaults[0];
        assertEq(controller.vault, address(eTST));
        assertTrue(controller.isController);
        assertEq(controller.borrowed, 10e18);

        // Collateral second
        VaultPositionInfo memory collateral = results[0].vaults[1];
        assertEq(collateral.vault, address(eTST2));
        assertTrue(collateral.isCollateral);
        assertEq(collateral.shares, 100e18);
    }

    function test_liquidityInfoOnlyForControllers() public {
        _setupBorrower(user1, 100e18, 10e18);

        AccountPositionInfo[] memory results = _singleQuery(user1);

        VaultPositionInfo memory controller = results[0].vaults[0];
        VaultPositionInfo memory collateral = results[0].vaults[1];

        // Controller should have liquidity info populated
        assertTrue(controller.isController);
        assertTrue(
            controller.liquidityInfo.collateralValueBorrowing > 0 || controller.liquidityInfo.liabilityValueBorrowing > 0,
            "controller should have liquidity info"
        );

        // Collateral-only vault should have empty liquidity info
        assertFalse(collateral.isController);
        assertEq(collateral.liquidityInfo.liabilityValueBorrowing, 0);
        assertEq(collateral.liquidityInfo.collateralValueBorrowing, 0);
    }

    function test_batchFiltersEmptyAccounts() public {
        _setupCollateral(user1, 50e18);
        // user2 has nothing
        _setupBorrower(user3, 200e18, 20e18);

        address[] memory accounts = new address[](3);
        accounts[0] = user1;
        accounts[1] = user2;
        accounts[2] = user3;

        AccountPositionInfo[] memory results = _queryBatch(accounts);

        assertEq(results.length, 2, "user2 should be filtered out");
        assertEq(results[0].account, user1);
        assertEq(results[1].account, user3);
    }

    function test_reverseIndexMapping() public {
        _setupCollateral(user1, 10e18);
        _setupCollateral(user2, 20e18);
        _setupBorrower(user3, 30e18, 5e18);

        address[] memory accounts = new address[](3);
        accounts[0] = user1;
        accounts[1] = user2;
        accounts[2] = user3;

        AccountPositionInfo[] memory results = _queryBatch(accounts);

        assertEq(results.length, 3);

        // Build reverse index: for each input account, find its result
        for (uint256 i = 0; i < accounts.length; ++i) {
            bool found;
            for (uint256 j = 0; j < results.length; ++j) {
                if (results[j].account == accounts[i]) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "every active account should be findable by its address");
        }
    }

    function test_vaultBothControllerAndCollateral_noDuplicate() public {
        // Enable eTST as both collateral and controller for user1
        assetTST.mint(user1, 100e18);
        vm.startPrank(user1);
        assetTST.approve(address(eTST), type(uint256).max);
        evc.enableCollateral(user1, address(eTST));
        evc.enableController(user1, address(eTST));
        eTST.deposit(100e18, user1);
        vm.stopPrank();

        AccountPositionInfo[] memory results = _singleQuery(user1);

        assertEq(results.length, 1);
        // Should appear exactly once (in the controllers slot), not duplicated
        assertEq(results[0].vaults.length, 1);
        assertEq(results[0].vaults[0].vault, address(eTST));
        assertTrue(results[0].vaults[0].isController);
        assertTrue(results[0].vaults[0].isCollateral);
    }

    function test_allAccountsEmpty_returnsEmptyArray() public view {
        address[] memory accounts = new address[](3);
        accounts[0] = user1;
        accounts[1] = user2;
        accounts[2] = user3;

        AccountPositionInfo[] memory results = _queryBatch(accounts);
        assertEq(results.length, 0);
    }

    function test_sharesToAssetsConversion() public {
        _setupCollateral(user1, 100e18);

        AccountPositionInfo[] memory results = _singleQuery(user1);

        VaultPositionInfo memory v = results[0].vaults[0];
        // With no interest accrued, shares == assets
        assertEq(v.shares, v.assets);
        // And both equal the deposited amount
        assertEq(v.assets, 100e18);
    }

    function test_subAccountPositions() public {
        address sub1 = getSubAccount(user1, 1);

        assetTST2.mint(sub1, 50e18);
        vm.startPrank(sub1);
        assetTST2.approve(address(eTST2), type(uint256).max);
        evc.enableCollateral(sub1, address(eTST2));
        eTST2.deposit(50e18, sub1);
        vm.stopPrank();

        // Query both primary and sub-account
        address[] memory accounts = new address[](2);
        accounts[0] = user1;
        accounts[1] = sub1;

        AccountPositionInfo[] memory results = _queryBatch(accounts);

        // Only sub-account has a position
        assertEq(results.length, 1);
        assertEq(results[0].account, sub1);
        assertEq(results[0].vaults[0].shares, 50e18);
    }
}
