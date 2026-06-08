// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Index, AssetConfig} from "src/Index.sol";
import {IIndex, AssetBalance} from "src/interfaces/IIndex.sol";
import {ZeroAmount} from "src/utils/CommonErrors.sol";

import {BaseTest} from "./utils/BaseTest.sol";

contract IndexTest is BaseTest {
    using SafeERC20 for IERC20;
    Index public index;

    address defaultAdmin;

    function setUp() public {
        defaultAdmin = makeAddr("defaultAdmin");
        index = _deployIndex(defaultAdmin);

        bytes32 hookRole = index.HOOK_ROLE();
        vm.prank(defaultAdmin);
        index.grantRole(hookRole, address(this));
    }

    // region - Deploy -

    function test_deploy() external view {
        assertEq(index.name(), "Test Index");
        assertEq(index.symbol(), "TSTIDX");

        address[] memory tokens = index.getTokens();
        AssetConfig[] memory assetConfigs = _getAssetConfigs();

        for (uint256 i = 0; i < assetConfigs.length; i++) {
            assertEq(tokens[i], assetConfigs[i].token, "Invalid token");
            assertEq(index.getAsset(tokens[i]).dataFeed, assetConfigs[i].dataFeed);
            assertEq(index.getAsset(tokens[i]).targetWeightBps, assetConfigs[i].targetWeightBps);
            assertEq(index.getAsset(tokens[i]).toleranceBps, assetConfigs[i].toleranceBps);
            assertEq(index.getAsset(tokens[i]).maxPriceStaleness, assetConfigs[i].maxPriceStaleness);
            assertEq(IERC20(tokens[i]).balanceOf(address(index)), assetConfigs[i].amount, "Invalid asset amount");
        }
    }

    // endregion

    // region - Mint -

    function _beforeEachMint() private returns (address user) {
        user = makeAddr("user");

        deal(weth, user, 1_000e18);
        deal(usdt, user, 1_000_000e18);

        vm.startPrank(user);

        IERC20(weth).approve(address(index), type(uint256).max);
        IERC20(usdt).approve(address(index), type(uint256).max);

        vm.stopPrank();
    }

    function test_mint(uint256 shares) external {
        shares = bound(shares, 1, 1_000e18);

        address user = _beforeEachMint();

        uint256 indexBalWethBefore = IERC20(weth).balanceOf(address(index));
        uint256 indexBalUsdtBefore = IERC20(usdt).balanceOf(address(index));

        uint256 userBalWethBefore = IERC20(weth).balanceOf(user);
        uint256 userBalUsdtBefore = IERC20(usdt).balanceOf(user);

        uint256 totalSupplyBefore = index.totalSupply();

        AssetBalance[] memory assetBalances = index.toAssets(shares, Math.Rounding.Ceil);
        assertEq(assetBalances.length, index.getTokens().length, "All assets returned");

        vm.prank(user);
        index.mint(shares, user);

        uint256 indexBalWethAfter = IERC20(weth).balanceOf(address(index));
        uint256 indexBalUsdtAfter = IERC20(usdt).balanceOf(address(index));

        uint256 userBalWethAfter = IERC20(weth).balanceOf(user);
        uint256 userBalUsdtAfter= IERC20(usdt).balanceOf(user);

        assertEq(IERC20(index).balanceOf(user), shares);

        for (uint256 i = 0; i < assetBalances.length; i++) {
            AssetBalance memory assetBalance = assetBalances[i];

            if (assetBalance.token == weth) {
                assertEq(assetBalance.amount, indexBalWethAfter - indexBalWethBefore);
                assertEq(userBalWethBefore - userBalWethAfter, assetBalance.amount, "User WETH debited");
            }

            if (assetBalance.token == usdt) {
                assertEq(assetBalance.amount, indexBalUsdtAfter - indexBalUsdtBefore);
                assertEq(userBalUsdtBefore - userBalUsdtAfter, assetBalance.amount, "User USDT debited");
            }
        }

        assertEq(index.totalSupply(), totalSupplyBefore + shares);
    }

    function test_mint_emitTransfer(uint256 shares) external {
        shares = bound(shares, 1, 1_000e18);

        address user = _beforeEachMint();

        vm.expectEmit(true, true, true, true, address(index));
        emit IERC20.Transfer(address(0), user, shares);

        vm.prank(user);
        index.mint(shares, user);
    }

    function test_mint_revertIfSharesIsZero() external {
        address user = _beforeEachMint();

        vm.expectRevert(ZeroAmount.selector);

        vm.prank(user);
        index.mint(0, user);
    }

    function test_mint_revertIfReceiverIsZero(uint256 shares) external {
        shares = bound(shares, 1, 1_000e18);

        address user = _beforeEachMint();

        vm.expectRevert(IIndex.InvalidReceiver.selector);

        vm.prank(user);
        index.mint(shares, address(0));
    }

    function test_mint_revertIfReceiverIsIndex(uint256 shares) external {
        shares = bound(shares, 1, 1_000e18);

        address user = _beforeEachMint();

        vm.expectRevert(IIndex.InvalidReceiver.selector);

        vm.prank(user);
        index.mint(shares, address(index));
    }

    function test_mint_revertWhenJitActive(uint256 shares) external {
        shares = bound(shares, 1, 1_000e18);

        address user = _beforeEachMint();

        index.lendAssets(weth, 1e18, usdt, 1);

        vm.expectRevert(IIndex.JitIsActive.selector);

        vm.prank(user);
        index.mint(shares, user);
    }

    // endregion

    // region - Collect Assets -

    function test_collectAssets_revertsOnWeightOutOfBounds() external {
        index.lendAssets(weth, 200_000e18, usdt, 1);

        // Don't transfer anything back. collectAssets must revert via Variant B assertion.
        try index.collectAssets(weth, usdt) {
            assertTrue(false, "Expected revert but collectAssets succeeded");
        } catch (bytes memory err) {
            _assertRevertContainsSelector(err, IIndex.WeightOutOfBounds.selector);
        }
    }

    // TODO: continue

    // endregion
}
