// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {Index, AssetConfig, JitDebt} from "src/Index.sol";
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
        uint256 userBalUsdtAfter = IERC20(usdt).balanceOf(user);

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

    // region - Redeem -

    function _beforeEachRedeem(uint256 shares) private returns (address user) {
        user = makeAddr("user");

        deal(weth, user, 1_000e18);
        deal(usdt, user, 1_000_000e18);

        vm.startPrank(user);

        IERC20(weth).approve(address(index), type(uint256).max);
        IERC20(usdt).approve(address(index), type(uint256).max);

        vm.stopPrank();

        vm.prank(user);
        index.mint(shares, user);
    }

    function test_redeem(uint256 shares) external {
        shares = bound(shares, 1, 1_000e18);

        address user = _beforeEachRedeem(shares);

        uint256 indexBalWethBefore = IERC20(weth).balanceOf(address(index));
        uint256 indexBalUsdtBefore = IERC20(usdt).balanceOf(address(index));

        uint256 userBalWethBefore = IERC20(weth).balanceOf(user);
        uint256 userBalUsdtBefore = IERC20(usdt).balanceOf(user);

        uint256 totalSupplyBefore = index.totalSupply();

        AssetBalance[] memory assetBalances = index.toAssets(shares, Math.Rounding.Floor);
        assertEq(assetBalances.length, index.getTokens().length, "All assets returned");

        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[0] = 0;
        minAmountsOut[1] = 0;

        vm.prank(user);
        index.redeem(shares, user, minAmountsOut);

        uint256 indexBalWethAfter = IERC20(weth).balanceOf(address(index));
        uint256 indexBalUsdtAfter = IERC20(usdt).balanceOf(address(index));

        uint256 userBalWethAfter = IERC20(weth).balanceOf(user);
        uint256 userBalUsdtAfter = IERC20(usdt).balanceOf(user);

        assertEq(IERC20(index).balanceOf(user), 0);

        for (uint256 i = 0; i < assetBalances.length; i++) {
            AssetBalance memory assetBalance = assetBalances[i];

            if (assetBalance.token == weth) {
                assertEq(assetBalance.amount, indexBalWethBefore -indexBalWethAfter);
                assertEq(assetBalance.amount, userBalWethAfter - userBalWethBefore);
            }

            if (assetBalance.token == usdt) {
                assertEq(assetBalance.amount, indexBalUsdtBefore - indexBalUsdtAfter);
                assertEq(assetBalance.amount, userBalUsdtAfter - userBalUsdtBefore);
            }
        }

        assertEq(index.totalSupply(), totalSupplyBefore - shares);
    }

    function test_redeem_emitTransfer(uint256 shares) external {
        shares = bound(shares, 1, 1_000e18);

        address user = _beforeEachRedeem(shares);

        uint256[] memory minAmountsOut = new uint256[](2);

        vm.expectEmit(true, true, true, true, address(index));
        emit IERC20.Transfer(user, address(0), shares);

        vm.prank(user);
        index.redeem(shares, user, minAmountsOut);
    }

    function test_redeem_revertIfSharesIsZero() external {
        address user = _beforeEachRedeem(1e18);

        uint256[] memory minAmountsOut = new uint256[](2);

        vm.expectRevert(ZeroAmount.selector);

        vm.prank(user);
        index.redeem(0, user, minAmountsOut);
    }

    function test_redeem_revertIfReceiverIsZero(uint256 shares) external {
        shares = bound(shares, 1, 1_000e18);

        address user = _beforeEachRedeem(shares);

        uint256[] memory minAmountsOut = new uint256[](2);

        vm.expectRevert(IIndex.InvalidReceiver.selector);

        vm.prank(user);
        index.redeem(shares, address(0), minAmountsOut);
    }

    function test_redeem_revertIfReceiverIsIndex(uint256 shares) external {
        shares = bound(shares, 1, 1_000e18);

        address user = _beforeEachRedeem(shares);

        uint256[] memory minAmountsOut = new uint256[](2);

        vm.expectRevert(IIndex.InvalidReceiver.selector);

        vm.prank(user);
        index.redeem(shares, address(index), minAmountsOut);
    }

    function test_redeem_revertIfMinAmountsOutLengthMismatch(uint256 shares) external {
        shares = bound(shares, 1, 1_000e18);

        address user = _beforeEachRedeem(shares);

        // Index has 2 assets — pass length 1 to trigger mismatch.
        uint256[] memory minAmountsOut = new uint256[](1);

        vm.expectRevert(IIndex.InvalidNumberOfMinAmountsOut.selector);

        vm.prank(user);
        index.redeem(shares, user, minAmountsOut);
    }

    function test_redeem_revertOnInsufficientAmountOut(uint256 shares) external {
        shares = bound(shares, 1, 1_000e18);

        address user = _beforeEachRedeem(shares);

        AssetBalance[] memory assetBalances = index.toAssets(shares, Math.Rounding.Floor);

        // Demand 1 more than what redeem would give for the first asset → slippage trigger.
        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[0] = assetBalances[0].amount + 1;
        minAmountsOut[1] = 0;

        vm.expectRevert(
            abi.encodeWithSelector(
                IIndex.InsufficientAmountOut.selector,
                assetBalances[0].token,
                assetBalances[0].amount,
                assetBalances[0].amount + 1
            )
        );

        vm.prank(user);
        index.redeem(shares, user, minAmountsOut);
    }

    function test_redeem_revertWhenJitActive(uint256 shares) external {
        shares = bound(shares, 1, 1_000e18);

        address user = _beforeEachRedeem(shares);

        index.lendAssets(weth, 1e18, usdt, 1);

        uint256[] memory minAmountsOut = new uint256[](2);

        vm.expectRevert(IIndex.JitIsActive.selector);

        vm.prank(user);
        index.redeem(shares, user, minAmountsOut);
    }

    // endregion

    // region - Lend assets -

    function _beforeEachLendAssets() private returns (address borrower) {
        borrower = makeAddr("borrower");
        bytes32 hookRole = index.HOOK_ROLE();

        vm.prank(defaultAdmin);
        index.grantRole(hookRole, borrower);
    }

    function test_lendAssets(uint256 amount0, uint256 amount1) external {
        address borrower = _beforeEachLendAssets();

        uint256 indexWethBalBefore = IERC20(weth).balanceOf(address(index));
        uint256 indexUsdtBalBefore = IERC20(usdt).balanceOf(address(index));

        amount0 = bound(amount0, 1, indexWethBalBefore);
        amount1 = bound(amount1, 1, indexUsdtBalBefore);

        vm.prank(borrower);
        index.lendAssets(weth, amount0, usdt, amount1);

        assertEq(IERC20(weth).balanceOf(borrower), amount0);
        assertEq(IERC20(usdt).balanceOf(borrower), amount1);

        assertEq(IERC20(weth).balanceOf(address(index)), indexWethBalBefore - amount0);
        assertEq(IERC20(usdt).balanceOf(address(index)), indexUsdtBalBefore - amount1);

        JitDebt memory debt = index.getJitDebt();
        assertEq(debt.token0, weth);
        assertEq(debt.token1, usdt);
        assertEq(debt.hook, borrower);
    }

    function test_lendAssets_emitAssetsLent(uint256 amount0, uint256 amount1) external {
        address borrower = _beforeEachLendAssets();

        uint256 indexWethBalBefore = IERC20(weth).balanceOf(address(index));
        uint256 indexUsdtBalBefore = IERC20(usdt).balanceOf(address(index));

        amount0 = bound(amount0, 1, indexWethBalBefore);
        amount1 = bound(amount1, 1, indexUsdtBalBefore);

        vm.expectEmit(true, true, true, true);
        emit IIndex.AssetsLent(borrower, weth, amount0, indexWethBalBefore, usdt, amount1, indexUsdtBalBefore);

        vm.prank(borrower);
        index.lendAssets(weth, amount0, usdt, amount1);
    }

    function test_lendAssets_revertIfInvalidAsset(uint256 amount0, uint256 amount1) external {
        address borrower = _beforeEachLendAssets();
        address invalidToken = makeAddr("invalidToken");

        uint256 indexWethBalBefore = IERC20(weth).balanceOf(address(index));
        uint256 indexUsdtBalBefore = IERC20(usdt).balanceOf(address(index));

        amount0 = bound(amount0, 1, indexWethBalBefore);
        amount1 = bound(amount1, 1, indexUsdtBalBefore);

        vm.expectRevert(abi.encodeWithSelector(IIndex.InvalidAsset.selector, invalidToken));

        vm.prank(borrower);
        index.lendAssets(invalidToken, amount0, usdt, amount1);

        vm.expectRevert(abi.encodeWithSelector(IIndex.InvalidAsset.selector, invalidToken));

        vm.prank(borrower);
        index.lendAssets(weth, amount0, invalidToken, amount1);
    }

    function test_lendAssets_revertIfZeroAmount(uint256 amount0, uint256 amount1) external {
        address borrower = _beforeEachLendAssets();

        uint256 indexWethBalBefore = IERC20(weth).balanceOf(address(index));
        uint256 indexUsdtBalBefore = IERC20(usdt).balanceOf(address(index));

        amount0 = bound(amount0, 1, indexWethBalBefore);
        amount1 = bound(amount1, 1, indexUsdtBalBefore);

        vm.expectRevert(ZeroAmount.selector);

        vm.prank(borrower);
        index.lendAssets(weth, 0, usdt, amount1);

        vm.expectRevert(ZeroAmount.selector);

        vm.prank(borrower);
        index.lendAssets(weth, amount0, usdt, 0);
    }

    function test_lendAssets_revertIfInsufficientAssetBalance0(uint256 amount0, uint256 amount1) external {
        address borrower = _beforeEachLendAssets();

        uint256 indexWethBalBefore = IERC20(weth).balanceOf(address(index));
        uint256 indexUsdtBalBefore = IERC20(usdt).balanceOf(address(index));

        amount0 = bound(amount0, indexWethBalBefore + 1, type(uint128).max);
        amount1 = bound(amount1, 1, indexUsdtBalBefore);

        vm.expectRevert(abi.encodeWithSelector(IIndex.InsufficientAssetBalance.selector, weth, amount0));

        vm.prank(borrower);
        index.lendAssets(weth, amount0, usdt, amount1);
    }

    function test_lendAssets_revertIfInsufficientAssetBalance1(uint256 amount0, uint256 amount1) external {
        address borrower = _beforeEachLendAssets();

        uint256 indexWethBalBefore = IERC20(weth).balanceOf(address(index));
        uint256 indexUsdtBalBefore = IERC20(usdt).balanceOf(address(index));

        amount0 = bound(amount0, 1, indexWethBalBefore);
        amount1 = bound(amount1, indexUsdtBalBefore + 1, type(uint128).max);

        vm.expectRevert(abi.encodeWithSelector(IIndex.InsufficientAssetBalance.selector, usdt, amount1));

        vm.prank(borrower);
        index.lendAssets(weth, amount0, usdt, amount1);
    }

    function test_lendAssets_revertIfNotHook(uint256 amount0, uint256 amount1) external {
        address notHook = makeAddr("notHook");

        uint256 indexWethBalBefore = IERC20(weth).balanceOf(address(index));
        uint256 indexUsdtBalBefore = IERC20(usdt).balanceOf(address(index));

        amount0 = bound(amount0, 1, indexWethBalBefore);
        amount1 = bound(amount1, 1, indexUsdtBalBefore);

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, notHook, index.HOOK_ROLE()));

        vm.prank(notHook);
        index.lendAssets(weth, amount0, usdt, amount1);
    }

    function test_lendAssets_revertWhenJitActive(uint256 amount0, uint256 amount1) external {
        address borrower = _beforeEachLendAssets();

        uint256 indexWethBalBefore = IERC20(weth).balanceOf(address(index));
        uint256 indexUsdtBalBefore = IERC20(usdt).balanceOf(address(index));

        amount0 = bound(amount0, 1, indexWethBalBefore);
        amount1 = bound(amount1, 1, indexUsdtBalBefore);

        vm.prank(borrower);
        index.lendAssets(weth, amount0, usdt, amount1);

        vm.expectRevert(IIndex.JitIsActive.selector);

        vm.prank(borrower);
        index.lendAssets(weth, amount0, usdt, amount1);
    }

    // endregion

    // region - Collect Assets -

    function _beforeEachCollectAssets(uint256 amount0, uint256 amount1) private returns (address borrower) {
        borrower = _beforeEachLendAssets();

        vm.prank(borrower);
        index.lendAssets(weth, amount0, usdt, amount1);

        vm.startPrank(borrower);
        IERC20(weth).transfer(address(index), amount0);
        IERC20(usdt).transfer(address(index), amount1);
        vm.stopPrank();
    }

    function test_collectAssets(uint256 amount0, uint256 amount1) external {
        uint256 indexWethBalBefore = IERC20(weth).balanceOf(address(index));
        uint256 indexUsdtBalBefore = IERC20(usdt).balanceOf(address(index));

        amount0 = bound(amount0, 1, indexWethBalBefore);
        amount1 = bound(amount1, 1, indexUsdtBalBefore);

        address borrower = _beforeEachCollectAssets(amount0, amount1);

        vm.prank(borrower);
        index.collectAssets();

        JitDebt memory debt = index.getJitDebt();
        assertEq(debt.hook, address(0));
        assertEq(debt.token0, address(0));
        assertEq(debt.token1, address(0));

        assertEq(IERC20(weth).balanceOf(address(index)), indexWethBalBefore);
        assertEq(IERC20(usdt).balanceOf(address(index)), indexUsdtBalBefore);
    }

    function test_collectAssets_emitAssetsCollected(uint256 amount0, uint256 amount1) external {
        uint256 indexWethBalBefore = IERC20(weth).balanceOf(address(index));
        uint256 indexUsdtBalBefore = IERC20(usdt).balanceOf(address(index));

        amount0 = bound(amount0, 1, indexWethBalBefore);
        amount1 = bound(amount1, 1, indexUsdtBalBefore);

        address borrower = _beforeEachCollectAssets(amount0, amount1);

        vm.expectEmit(true, true, true, true, address(index));
        emit IIndex.AssetsCollected(borrower, weth, indexWethBalBefore, usdt, indexUsdtBalBefore);

        vm.prank(borrower);
        index.collectAssets();
    }

    function test_collectAssets_revertIfNotHook() external {
        address notHook = makeAddr("notHook");

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, notHook, index.HOOK_ROLE())
        );

        vm.prank(notHook);
        index.collectAssets();
    }

    function test_collectAssets_revertWhenJitInactive() external {
        address borrower = _beforeEachLendAssets();

        vm.expectRevert(IIndex.JitIsNotActive.selector);

        vm.prank(borrower);
        index.collectAssets();
    }

    function test_collectAssets_revertIfInvalidCollector(uint256 amount0, uint256 amount1) external {
        uint256 indexWethBalBefore = IERC20(weth).balanceOf(address(index));
        uint256 indexUsdtBalBefore = IERC20(usdt).balanceOf(address(index));

        amount0 = bound(amount0, 1, indexWethBalBefore);
        amount1 = bound(amount1, 1, indexUsdtBalBefore);

        _beforeEachCollectAssets(amount0, amount1);

        address otherBorrower = makeAddr("otherBorrower");
        bytes32 hookRole = index.HOOK_ROLE();

        vm.prank(defaultAdmin);
        index.grantRole(hookRole, otherBorrower);

        vm.expectRevert(IIndex.InvalidCollector.selector);

        vm.prank(otherBorrower);
        index.collectAssets();
    }

    function test_collectAssets_revertsOnWeightOutOfBounds() external {
        address borrower = _beforeEachLendAssets();

        vm.prank(borrower);
        index.lendAssets(weth, 200_000e18, usdt, 1);

        vm.prank(borrower);
        try index.collectAssets() {
            assertTrue(false, "Expected revert but collectAssets succeeded");
        } catch (bytes memory err) {
            _assertRevertContainsSelector(err, IIndex.WeightOutOfBounds.selector);
        }
    }

    // endregion
}
