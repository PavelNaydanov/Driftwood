// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {Index, AssetConfig, JitDebt} from "src/Index.sol";
import {IIndex, AssetBalance, AssetWeight} from "src/interfaces/IIndex.sol";
import {ZeroAmount, ZeroAddress} from "src/utils/CommonErrors.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

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

    function test_deploy_revertIfLessThanTwoAssets() external {
        Index newIndex = Index(Clones.clone(address(new Index())));

        AssetConfig[] memory configs = new AssetConfig[](1);
        configs[0] = AssetConfig({
            token: usdt,
            amount: 1e15,
            dataFeed: usdtFeed,
            maxPriceStaleness: 86400,
            targetWeightBps: 10000,
            toleranceBps: 500
        });

        vm.expectRevert(IIndex.InvalidNumberOfAssets.selector);
        newIndex.initialize("Test", "TST", configs, INITIAL_SHARES, defaultAdmin);
    }

    function test_deploy_revertIfTokenIsZero() external {
        Index newIndex = Index(Clones.clone(address(new Index())));

        AssetConfig[] memory configs = new AssetConfig[](2);
        configs[0] = AssetConfig({
            token: address(0),
            amount: 1e15,
            dataFeed: usdtFeed,
            maxPriceStaleness: 86400,
            targetWeightBps: 5000,
            toleranceBps: 500
        });
        configs[1] = AssetConfig({
            token: weth,
            amount: 1e24,
            dataFeed: ethFeed,
            maxPriceStaleness: 3600,
            targetWeightBps: 5000,
            toleranceBps: 500
        });

        vm.expectRevert(ZeroAddress.selector);
        newIndex.initialize("Test", "TST", configs, INITIAL_SHARES, defaultAdmin);
    }

    function test_deploy_revertIfAmountIsZero() external {
        Index newIndex = Index(Clones.clone(address(new Index())));

        AssetConfig[] memory configs = new AssetConfig[](2);
        configs[0] = AssetConfig({
            token: usdt,
            amount: 0,
            dataFeed: usdtFeed,
            maxPriceStaleness: 86400,
            targetWeightBps: 5000,
            toleranceBps: 500
        });
        configs[1] = AssetConfig({
            token: weth,
            amount: 1e24,
            dataFeed: ethFeed,
            maxPriceStaleness: 3600,
            targetWeightBps: 5000,
            toleranceBps: 500
        });

        vm.expectRevert(ZeroAmount.selector);
        newIndex.initialize("Test", "TST", configs, INITIAL_SHARES, defaultAdmin);
    }

    function test_deploy_revertIfAssetBalanceMismatch() external {
        Index newIndex = Index(Clones.clone(address(new Index())));

        AssetConfig[] memory configs = new AssetConfig[](2);
        configs[0] = AssetConfig({
            token: usdt,
            amount: 1e15,
            dataFeed: usdtFeed,
            maxPriceStaleness: 86400,
            targetWeightBps: 5000,
            toleranceBps: 500
        });
        configs[1] = AssetConfig({
            token: weth,
            amount: 1e24,
            dataFeed: ethFeed,
            maxPriceStaleness: 3600,
            targetWeightBps: 5000,
            toleranceBps: 500
        });

        // No transfer to newIndex → balance == 0, doesn't match expected amount.
        vm.expectRevert(abi.encodeWithSelector(IIndex.InvalidAssetAmount.selector, usdt, 1e15));
        newIndex.initialize("Test", "TST", configs, INITIAL_SHARES, defaultAdmin);
    }

    function test_deploy_revertIfInvalidTotalWeight() external {
        Index newIndex = Index(Clones.clone(address(new Index())));

        AssetConfig[] memory configs = new AssetConfig[](2);
        configs[0] = AssetConfig({
            token: usdt,
            amount: 1e15,
            dataFeed: usdtFeed,
            maxPriceStaleness: 86400,
            targetWeightBps: 4000, // sum = 4000 + 5000 = 9000 != MAX_BPS
            toleranceBps: 500
        });
        configs[1] = AssetConfig({
            token: weth,
            amount: 1e24,
            dataFeed: ethFeed,
            maxPriceStaleness: 3600,
            targetWeightBps: 5000,
            toleranceBps: 500
        });

        deal(usdt, address(newIndex), 1e15);
        deal(weth, address(newIndex), 1e24);

        vm.expectRevert(IIndex.InvalidTotalWeightBps.selector);
        newIndex.initialize("Test", "TST", configs, INITIAL_SHARES, defaultAdmin);
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
                assertEq(assetBalance.amount, indexBalWethBefore - indexBalWethAfter);
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

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, notHook, index.HOOK_ROLE())
        );

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

    // region - Set oracle config -

    function test_setOracleConfig(uint32 maxPriceStaleness) external {
        vm.assume(maxPriceStaleness != 0);

        uint8 dataFeedDecimals = 10;
        MockAggregator dataFeed = new MockAggregator(dataFeedDecimals, 3000e8);
        uint16 targetBpsBefore = index.getAsset(usdt).targetWeightBps;
        uint16 toleranceBpsBefore = index.getAsset(usdt).toleranceBps;

        vm.prank(defaultAdmin);
        index.setOracleConfig(usdt, address(dataFeed), maxPriceStaleness);

        assertEq(index.getAsset(usdt).dataFeed, address(dataFeed));
        assertEq(index.getAsset(usdt).feedDecimals, dataFeedDecimals);
        assertEq(index.getAsset(usdt).maxPriceStaleness, maxPriceStaleness);

        assertEq(index.getAsset(usdt).targetWeightBps, targetBpsBefore);
        assertEq(index.getAsset(usdt).toleranceBps, toleranceBpsBefore);
    }

    function test_setOracleConfig_emitOracleConfigSet(uint32 maxPriceStaleness) external {
        MockAggregator dataFeed = new MockAggregator(8, 3000e8);
        vm.assume(maxPriceStaleness != 0);

        vm.expectEmit(true, true, true, true, address(index));
        emit IIndex.OracleConfigSet(usdt, address(dataFeed), maxPriceStaleness);

        vm.prank(defaultAdmin);
        index.setOracleConfig(usdt, address(dataFeed), maxPriceStaleness);
    }

    function test_setOracleConfig_revertIfNotDefaultAdmin(uint32 maxPriceStaleness) external {
        MockAggregator dataFeed = new MockAggregator(8, 3000e8);
        address notDefaultAdmin = makeAddr("notDefaultAdmin");

        vm.assume(maxPriceStaleness != 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, notDefaultAdmin, index.DEFAULT_ADMIN_ROLE()
            )
        );

        vm.prank(notDefaultAdmin);
        index.setOracleConfig(usdt, address(dataFeed), maxPriceStaleness);
    }

    function test_setOracleConfig_revertWhenJitActive(uint32 maxPriceStaleness) external {
        MockAggregator dataFeed = new MockAggregator(8, 3000e8);

        vm.assume(maxPriceStaleness != 0);

        index.lendAssets(weth, 1, usdt, 1);

        vm.expectRevert(IIndex.JitIsActive.selector);

        vm.prank(defaultAdmin);
        index.setOracleConfig(usdt, address(dataFeed), maxPriceStaleness);
    }

    function test_setOracleConfig_revertIfInvalidAsset(uint32 maxPriceStaleness) external {
        MockAggregator dataFeed = new MockAggregator(8, 3000e8);
        address invalidAsset = makeAddr("invalidAsset");

        vm.assume(maxPriceStaleness != 0);

        vm.expectRevert(abi.encodeWithSelector(IIndex.InvalidAsset.selector, invalidAsset));

        vm.prank(defaultAdmin);
        index.setOracleConfig(invalidAsset, address(dataFeed), maxPriceStaleness);
    }

    function test_setOracleConfig_revertIfDataFeedZero(uint32 maxPriceStaleness) external {
        vm.assume(maxPriceStaleness != 0);

        vm.expectRevert(ZeroAddress.selector);

        vm.prank(defaultAdmin);
        index.setOracleConfig(usdt, address(0), maxPriceStaleness);
    }

    function test_setOracleConfig_revertIfMaxPriceStalenessZero() external {
        MockAggregator dataFeed = new MockAggregator(8, 3000e8);

        vm.expectRevert(abi.encodeWithSelector(IIndex.InvalidMaxPriceStaleness.selector, usdt));

        vm.prank(defaultAdmin);
        index.setOracleConfig(usdt, address(dataFeed), 0);
    }

    // endregion

    // region - Set asset weights -

    function _makeAssetWeights(uint16 usdtTarget, uint16 usdtTolerance, uint16 wethTarget, uint16 wethTolerance)
        private
        view
        returns (AssetWeight[] memory weights)
    {
        weights = new AssetWeight[](2);
        weights[0] = AssetWeight({token: usdt, targetWeightBps: usdtTarget, toleranceBps: usdtTolerance});
        weights[1] = AssetWeight({token: weth, targetWeightBps: wethTarget, toleranceBps: wethTolerance});
    }

    function test_setAssetWeights() external {
        AssetWeight[] memory newWeights = _makeAssetWeights(6000, 400, 4000, 300);

        address usdtFeedBefore = index.getAsset(usdt).dataFeed;
        uint32 usdtStalenessBefore = index.getAsset(usdt).maxPriceStaleness;
        address wethFeedBefore = index.getAsset(weth).dataFeed;
        uint32 wethStalenessBefore = index.getAsset(weth).maxPriceStaleness;

        vm.prank(defaultAdmin);
        index.setAssetWeights(newWeights);

        assertEq(index.getAsset(usdt).targetWeightBps, 6000);
        assertEq(index.getAsset(usdt).toleranceBps, 400);
        assertEq(index.getAsset(weth).targetWeightBps, 4000);
        assertEq(index.getAsset(weth).toleranceBps, 300);

        assertEq(index.getAsset(usdt).dataFeed, usdtFeedBefore);
        assertEq(index.getAsset(usdt).maxPriceStaleness, usdtStalenessBefore);
        assertEq(index.getAsset(weth).dataFeed, wethFeedBefore);
        assertEq(index.getAsset(weth).maxPriceStaleness, wethStalenessBefore);
    }

    function test_setAssetWeights_emitAssetWeightSet() external {
        AssetWeight[] memory newWeights = _makeAssetWeights(6000, 400, 4000, 300);

        vm.expectEmit(true, true, true, true, address(index));
        emit IIndex.AssetWeightSet(usdt, 6000, 400);

        vm.expectEmit(true, true, true, true, address(index));
        emit IIndex.AssetWeightSet(weth, 4000, 300);

        vm.prank(defaultAdmin);
        index.setAssetWeights(newWeights);
    }

    function test_setAssetWeights_revertIfNotDefaultAdmin() external {
        address notAdmin = makeAddr("notAdmin");
        AssetWeight[] memory newWeights = _makeAssetWeights(5000, 500, 5000, 500);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, notAdmin, index.DEFAULT_ADMIN_ROLE()
            )
        );

        vm.prank(notAdmin);
        index.setAssetWeights(newWeights);
    }

    function test_setAssetWeights_revertWhenJitActive() external {
        index.lendAssets(weth, 1, usdt, 1);

        AssetWeight[] memory newWeights = _makeAssetWeights(5000, 500, 5000, 500);

        vm.expectRevert(IIndex.JitIsActive.selector);

        vm.prank(defaultAdmin);
        index.setAssetWeights(newWeights);
    }

    function test_setAssetWeights_revertIfIncompleteTokenSet() external {
        AssetWeight[] memory newWeights = new AssetWeight[](1);
        newWeights[0] = AssetWeight({token: usdt, targetWeightBps: 10000, toleranceBps: 500});

        vm.expectRevert(IIndex.IncompleteTokenSet.selector);

        vm.prank(defaultAdmin);
        index.setAssetWeights(newWeights);
    }

    function test_setAssetWeights_revertIfInvalidAsset() external {
        address invalidToken = makeAddr("invalidToken");
        AssetWeight[] memory newWeights = new AssetWeight[](2);
        newWeights[0] = AssetWeight({token: invalidToken, targetWeightBps: 5000, toleranceBps: 500});
        newWeights[1] = AssetWeight({token: weth, targetWeightBps: 5000, toleranceBps: 500});

        vm.expectRevert(abi.encodeWithSelector(IIndex.InvalidAsset.selector, invalidToken));

        vm.prank(defaultAdmin);
        index.setAssetWeights(newWeights);
    }

    function test_setAssetWeights_revertIfTargetZero() external {
        AssetWeight[] memory newWeights = _makeAssetWeights(0, 0, 5000, 500);

        vm.expectRevert(abi.encodeWithSelector(IIndex.InvalidWeightBps.selector, usdt));

        vm.prank(defaultAdmin);
        index.setAssetWeights(newWeights);
    }

    function test_setAssetWeights_revertIfTargetExceedsMaxBps() external {
        AssetWeight[] memory newWeights = _makeAssetWeights(10001, 500, 5000, 500);

        vm.expectRevert(abi.encodeWithSelector(IIndex.InvalidWeightBps.selector, usdt));

        vm.prank(defaultAdmin);
        index.setAssetWeights(newWeights);
    }

    function test_setAssetWeights_revertIfToleranceGteTarget() external {
        AssetWeight[] memory newWeights = _makeAssetWeights(5000, 5000, 5000, 500);

        vm.expectRevert(abi.encodeWithSelector(IIndex.InvalidToleranceBps.selector, usdt));

        vm.prank(defaultAdmin);
        index.setAssetWeights(newWeights);
    }

    function test_setAssetWeights_revertIfInvalidTotalWeight() external {
        AssetWeight[] memory newWeights = _makeAssetWeights(4000, 300, 5000, 500);

        vm.expectRevert(IIndex.InvalidTotalWeightBps.selector);

        vm.prank(defaultAdmin);
        index.setAssetWeights(newWeights);
    }

    // endregion

    // region - Preview Bounds Check -

    function test_previewBoundsCheck_returnsTrueAtTarget() external view {
        uint256 currentUsdtBal = IERC20(usdt).balanceOf(address(index));
        uint256 currentWethBal = IERC20(weth).balanceOf(address(index));

        assertTrue(index.previewBoundsCheck(usdt, currentUsdtBal, weth, currentWethBal));
    }

    function test_previewBoundsCheck_returnsTrueWithinTolerance() external view {
        uint256 currentUsdtBal = IERC20(usdt).balanceOf(address(index));
        uint256 currentWethBal = IERC20(weth).balanceOf(address(index));

        assertTrue(index.previewBoundsCheck(usdt, currentUsdtBal * 105 / 100, weth, currentWethBal));
    }

    function test_previewBoundsCheck_returnsFalseAboveTolerance() external view {
        uint256 currentWethBal = IERC20(weth).balanceOf(address(index));

        assertFalse(index.previewBoundsCheck(usdt, 6_000_000_000e6, weth, currentWethBal));
    }

    function test_previewBoundsCheck_returnsFalseBelowTolerance() external view {
        uint256 currentWethBal = IERC20(weth).balanceOf(address(index));

        assertFalse(index.previewBoundsCheck(usdt, 1_000_000_000e6, weth, currentWethBal));
    }

    function test_previewBoundsCheck_returnsFalseOnZeroTotal() external view {
        assertFalse(index.previewBoundsCheck(usdt, 0, weth, 0));
    }

    function test_previewBoundsCheck_revertIfSameAssets() external {
        vm.expectRevert(IIndex.SameAssets.selector);
        index.previewBoundsCheck(usdt, 1, usdt, 1);
    }

    function test_previewBoundsCheck_revertIfInvalidToken() external {
        address invalidToken = makeAddr("invalidToken");

        vm.expectRevert(abi.encodeWithSelector(IIndex.InvalidAsset.selector, invalidToken));
        index.previewBoundsCheck(invalidToken, 1, weth, 1);

        vm.expectRevert(abi.encodeWithSelector(IIndex.InvalidAsset.selector, invalidToken));
        index.previewBoundsCheck(usdt, 1, invalidToken, 1);
    }

    function test_previewBoundsCheck_revertOnInvalidPrice() external {
        MockAggregator(ethFeed).setAnswer(0);

        uint256 currentUsdtBal = IERC20(usdt).balanceOf(address(index));
        uint256 currentWethBal = IERC20(weth).balanceOf(address(index));

        vm.expectRevert(abi.encodeWithSelector(IIndex.InvalidPrice.selector, weth));
        index.previewBoundsCheck(usdt, currentUsdtBal, weth, currentWethBal);
    }

    function test_previewBoundsCheck_revertOnStalePrice() external {
        // Warp 2h forward — ETH (maxStaleness 1h) becomes stale, USDT (24h) stays fresh.
        vm.warp(block.timestamp + 7200);

        uint256 currentUsdtBal = IERC20(usdt).balanceOf(address(index));
        uint256 currentWethBal = IERC20(weth).balanceOf(address(index));

        vm.expectRevert(abi.encodeWithSelector(IIndex.StalePrice.selector, weth));
        index.previewBoundsCheck(usdt, currentUsdtBal, weth, currentWethBal);
    }

    function test_previewBoundsCheck_withFeedDecimalsEqual18() external {
        MockAggregator feed18 = new MockAggregator(18, 1e18);

        vm.prank(defaultAdmin);
        index.setOracleConfig(usdt, address(feed18), 86400);

        uint256 currentUsdtBal = IERC20(usdt).balanceOf(address(index));
        uint256 currentWethBal = IERC20(weth).balanceOf(address(index));

        assertTrue(index.previewBoundsCheck(usdt, currentUsdtBal, weth, currentWethBal));
    }

    function test_previewBoundsCheck_withFeedDecimalsAbove18() external {
        MockAggregator feed20 = new MockAggregator(20, 1e20);

        vm.prank(defaultAdmin);
        index.setOracleConfig(usdt, address(feed20), 86400);

        uint256 currentUsdtBal = IERC20(usdt).balanceOf(address(index));
        uint256 currentWethBal = IERC20(weth).balanceOf(address(index));

        assertTrue(index.previewBoundsCheck(usdt, currentUsdtBal, weth, currentWethBal));
    }

    function test_previewBoundsCheck_withThreeAssets() external {
        address dai = address(new MockERC20(18));
        MockAggregator daiFeed = new MockAggregator(8, 1e8);

        AssetConfig[] memory configs = new AssetConfig[](3);
        configs[0] = AssetConfig({
            token: usdt,
            amount: 1_000_000_000e6,
            dataFeed: usdtFeed,
            maxPriceStaleness: 86400,
            targetWeightBps: 3333,
            toleranceBps: 500
        });
        configs[1] = AssetConfig({
            token: weth,
            amount: 333_334e18,
            dataFeed: ethFeed,
            maxPriceStaleness: 3600,
            targetWeightBps: 3333,
            toleranceBps: 500
        });
        configs[2] = AssetConfig({
            token: dai,
            amount: 1_000_000_000e18,
            dataFeed: address(daiFeed),
            maxPriceStaleness: 86400,
            targetWeightBps: 3334,
            toleranceBps: 500
        });

        Index threeAssetIndex = Index(Clones.clone(address(new Index())));

        deal(usdt, address(threeAssetIndex), 1_000_000_000e6);
        deal(weth, address(threeAssetIndex), 333_334e18);
        deal(dai, address(threeAssetIndex), 1_000_000_000e18);

        threeAssetIndex.initialize("3A", "3A", configs, INITIAL_SHARES, defaultAdmin);

        assertTrue(threeAssetIndex.previewBoundsCheck(usdt, 1_000_000_000e6, weth, 333_334e18));
    }

    // endregion

    // region - Collect Assets -

    function _beforeEachCollectAssets(uint256 amount0, uint256 amount1) private returns (address borrower) {
        borrower = _beforeEachLendAssets();

        vm.prank(borrower);
        index.lendAssets(weth, amount0, usdt, amount1);

        vm.startPrank(borrower);
        IERC20(weth).safeTransfer(address(index), amount0);
        IERC20(usdt).safeTransfer(address(index), amount1);
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
