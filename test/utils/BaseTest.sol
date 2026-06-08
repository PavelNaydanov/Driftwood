// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {Index, AssetConfig} from "src/Index.sol";
import {IndexFactory} from "src/IndexFactory.sol";
import {DriftwoodHook} from "src/DriftwoodHook.sol";

import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockAggregator} from "test/mocks/MockAggregator.sol";

import {UniswapDeployers} from "./UniswapDeployers.sol";
import {EasyPosm} from "./libraries/EasyPosm.sol";

abstract contract BaseTest is Test, UniswapDeployers {
    using SafeERC20 for IERC20;
    using EasyPosm for IPositionManager;
    using CurrencyLibrary for Currency;

    uint256 constant public INITIAL_WETH_AMOUNT = 1_000_000e18;
    uint256 constant public INITIAL_USDT_AMOUNT = 3_000_000_000e6;
    uint256 constant public INITIAL_SHARES = 6_000_000_000e18; // 1 shares = $1 based on INITIAL_WETH_AMOUNT and INITIAL_USDT_AMOUNT

    address public usdtFeed;
    address public ethFeed;

    address usdt;
    address weth;

    function _deployDriftwoodHook(address defaultAdmin)
        internal
        returns (DriftwoodHook createdHook, Index createdIndex, PoolKey memory poolKey)
    {
        _deployUniswapArtifactsAndLabel();
        createdIndex = _deployIndex(defaultAdmin);

        (Currency currency0, Currency currency1) =
            usdt < weth ? (Currency.wrap(usdt), Currency.wrap(weth)) : (Currency.wrap(weth), Currency.wrap(usdt));

        // Deploy the hook to an address with the correct flags
        address flags = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (0x4444 << 144));
        bytes memory constructorArgs = abi.encode(poolManager, address(createdIndex));

        deployCodeTo("DriftwoodHook.sol:DriftwoodHook", constructorArgs, flags);
        createdHook = DriftwoodHook(flags);

        // Create the pool
        poolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(createdHook)
        });

        uint160 sqrtPriceX96 = usdt > weth
            ? _encodeSqrtPriceX96(3000e6, 1e18)  // currency0=WETH, currency1=USDT
            : _encodeSqrtPriceX96(1e18, 3000e6); // currency0=USDT, currency1=WETH
        poolManager.initialize(poolKey, sqrtPriceX96);

        // Provide approves
        IERC20(weth).approve(address(permit2), type(uint256).max);
        IERC20(usdt).approve(address(permit2), type(uint256).max);

        permit2.approve(usdt, address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(weth, address(positionManager), type(uint160).max, type(uint48).max);

        IERC20(weth).approve(address(swapRouter), type(uint256).max);
        IERC20(usdt).approve(address(swapRouter), type(uint256).max);

        // Provide full-range liquidity to the pool (so swaps can execute)
        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        deal(weth, address(this), 20_000e18);
        deal(usdt, address(this), 50_000_000e6);

        uint128 liquidityAmount = 4.6e17;
        {
            (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(tickLower),
                TickMath.getSqrtPriceAtTick(tickUpper),
                liquidityAmount
            );

            positionManager.mint(
                poolKey,
                tickLower,
                tickUpper,
                liquidityAmount,
                amount0Expected + 1,
                amount1Expected + 1,
                address(this),
                block.timestamp,
                new bytes(0)
            );
        }

        // Grant hook role
        bytes32 hookRole = createdIndex.HOOK_ROLE();

        vm.prank(defaultAdmin);
        createdIndex.grantRole(hookRole, address(createdHook));
    }

    function _deployUniswapArtifactsAndLabel() internal {
        deployArtifacts();

        vm.label(address(permit2), "Permit2");
        vm.label(address(poolManager), "V4PoolManager");
        vm.label(address(positionManager), "V4PositionManager");
        vm.label(address(swapRouter), "V4SwapRouter");
    }

    function _deployIndexFactory() internal returns (IndexFactory createdIndexFactory) {
        address indexImpl = address(new Index());
        createdIndexFactory = new IndexFactory(indexImpl);
    }

    function _deployIndex(address defaultAdmin) internal returns (Index createdIndex) {
        _deployTokens();
        _deployFeeds();

        AssetConfig[] memory assetConfigs = _getAssetConfigs();

        address indexImpl = address(new Index());
        createdIndex = Index(Clones.clone(indexImpl));

        for (uint256 i = 0; i < assetConfigs.length; i++) {
            AssetConfig memory asset = assetConfigs[i];
            deal(asset.token, address(this), asset.amount);

            IERC20(asset.token).safeTransfer(address(createdIndex), asset.amount);
        }

        createdIndex.initialize("Test Index", "TSTIDX", assetConfigs, INITIAL_SHARES, defaultAdmin);
    }

    function _deployTokens() internal returns (address[] memory tokens) {
        usdt = address(new MockERC20(6));
        weth = address(new MockERC20(18));

        tokens = new address[](2);
        tokens[0] = usdt;
        tokens[1] = weth;

        vm.label(usdt, "USDT");
        vm.label(weth, "WETH");
    }

    function _deployFeeds() internal {
        usdtFeed = address(new MockAggregator(8, 1e8)); // $1.00 | feed decimals = 8
        ethFeed = address(new MockAggregator(8, 3000e8)); // $3000.00 | feed decimals = 8
    }

    function _getAssetConfigs() internal view returns (AssetConfig[] memory assetConfigs) {
        require(usdt != address(0) && weth != address(0), "Tokens should be deployed");
        require(usdtFeed != address(0) && ethFeed != address(0), "Data feeds should be deployed");

        assetConfigs = new AssetConfig[](2);
        assetConfigs[0] = AssetConfig({
            token: usdt,
            amount: INITIAL_USDT_AMOUNT,
            dataFeed: usdtFeed,
            maxPriceStaleness: 86400,
            targetWeightBps: 5_000, // 50%
            toleranceBps: 500 // 5%
        });

        assetConfigs[1] = AssetConfig({
            token: weth,
            amount: INITIAL_WETH_AMOUNT,
            dataFeed: ethFeed,
            maxPriceStaleness: 3600,
            targetWeightBps: 5_000, // 50%
            toleranceBps: 500 // 5%
        });
    }

    function _etch(address target, bytes memory bytecode) internal override {
        vm.etch(target, bytecode);
    }

    function _encodeSqrtPriceX96(uint256 amount1, uint256 amount0) internal pure returns (uint160) {
        return uint160(Math.sqrt(FullMath.mulDiv(amount1, 1 << 192, amount0)));
    }

    /// @dev Returns true if `err` contains `selector` anywhere in its bytes.
    /// V4 wraps hook reverts, so the original selector is nested inside the wrapping.
    function _revertContainsSelector(bytes memory err, bytes4 selector) internal pure returns (bool) {
        if (err.length < 4) return false;
        for (uint256 i = 0; i + 4 <= err.length; i++) {
            bytes4 chunk;
            assembly {
                chunk := mload(add(add(err, 0x20), i))
            }
            if (chunk == selector) return true;
        }
        return false;
    }

    /// @dev Asserts that `err` contains `selector` anywhere in its bytes.
    function _assertRevertContainsSelector(bytes memory err, bytes4 selector) internal pure {
        assertTrue(
            _revertContainsSelector(err, selector),
            "Expected selector not found in revert data"
        );
    }

    function test() external override {}
}
