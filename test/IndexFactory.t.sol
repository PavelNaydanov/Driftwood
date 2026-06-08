// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IndexFactory} from "src/IndexFactory.sol";
import {Index} from "src/Index.sol";
import {AssetConfig} from "src/interfaces/IIndex.sol";
import {IIndexFactory} from "src/interfaces/IIndexFactory.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {ZeroAddress, ZeroAmount} from "src/utils/CommonErrors.sol";

contract IndexFactoryTest is BaseTest {
    using SafeERC20 for IERC20;

    IndexFactory public factory;

    address defaultAdmin;

    function setUp() public {
        defaultAdmin = makeAddr("defaultAdmin");

        factory = _deployIndexFactory();
    }

    // region - Deploy -

    function test_deploy() external view {
        assertNotEq(factory.getIndexImplementation(), address(0), "Invalid index implementation");
    }

    function test_deploy_revertIfZeroAddress() external {
        vm.expectRevert(ZeroAddress.selector);

        new IndexFactory(address(0));
    }

    // endregion

    // region - Create index -

    function _beforeEachCreateIndex() private returns (AssetConfig[] memory assetConfigs) {
        _deployTokens();
        _deployFeeds();

        assetConfigs = _getAssetConfigs();

        for (uint256 i = 0; i < assetConfigs.length; i++) {
            AssetConfig memory asset = assetConfigs[i];
            deal(asset.token, address(this), asset.amount);

            IERC20(asset.token).approve(address(factory), asset.amount);
        }
    }

    function test_createIndex() external {
        string memory name = "Test";
        string memory symbol = "TT";

        AssetConfig[] memory assetConfigs = _beforeEachCreateIndex();

        uint256 deployerWethBalBefore = IERC20(weth).balanceOf(address(this));
        uint256 deployerUsdtBalBefore = IERC20(usdt).balanceOf(address(this));

        address index = factory.createIndex(name, symbol, assetConfigs, INITIAL_SHARES, defaultAdmin);

        assertEq(IERC20Metadata(index).name(), name);
        assertEq(IERC20Metadata(index).symbol(), symbol);
        assertEq(IERC20(index).totalSupply(), INITIAL_SHARES);
        assertTrue(Index(index).hasRole(Index(index).DEFAULT_ADMIN_ROLE(), defaultAdmin));

        uint256 deployerWethBalAfter = IERC20(weth).balanceOf(address(this));
        uint256 deployerUsdtBalAfter = IERC20(usdt).balanceOf(address(this));

        for (uint256 i = 0; i < assetConfigs.length; i++) {
            AssetConfig memory assetConfig = assetConfigs[i];

            assertEq(IERC20(assetConfig.token).balanceOf(address(index)), assetConfig.amount);

            if (assetConfig.token == weth) {
                assertEq(deployerWethBalBefore - deployerWethBalAfter, assetConfig.amount);
            }

            if (assetConfig.token == usdt) {
                assertEq(deployerUsdtBalBefore - deployerUsdtBalAfter, assetConfig.amount);
            }
        }
    }

    function test_createIndex_emitIndexCreated() external {
        string memory name = "Test";
        string memory symbol = "TT";

        AssetConfig[] memory assetConfigs = _beforeEachCreateIndex();

        vm.expectEmit(true, true, true, false, address(factory));
        emit IIndexFactory.IndexCreated(address(0), name, symbol);

        factory.createIndex(name, symbol, assetConfigs, INITIAL_SHARES, defaultAdmin);
    }

    function test_createIndex_revertIfTokenZero() external {
        string memory name = "Test";
        string memory symbol = "TT";

        AssetConfig[] memory assetConfigs = _beforeEachCreateIndex();
        assetConfigs[0].token = address(0);

        vm.expectRevert(ZeroAddress.selector);

        factory.createIndex(name, symbol, assetConfigs, INITIAL_SHARES, defaultAdmin);
    }

    function test_createIndex_revertIfAmountZero() external {
        string memory name = "Test";
        string memory symbol = "TT";

        AssetConfig[] memory assetConfigs = _beforeEachCreateIndex();
        assetConfigs[0].amount = 0;

        vm.expectRevert(ZeroAmount.selector);

        factory.createIndex(name, symbol, assetConfigs, INITIAL_SHARES, defaultAdmin);
    }

    // endregion
}
