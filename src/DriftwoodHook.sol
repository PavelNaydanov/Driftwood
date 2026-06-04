// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {console} from "forge-std/Test.sol"; // TODO: remove
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IDriftwoodHook} from "./interfaces/IDriftwoodHook.sol";
import {IIndex} from "./interfaces/IIndex.sol";

contract DriftwoodHook is IDriftwoodHook, BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    struct ActivePosition {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    struct SimulationContext {
        int24 tickLower;
        int24 tickUpper;
        uint160 sqrtPriceX96;
        uint160 sqrtPriceLowerX96;
        uint160 sqrtPriceUpperX96;
        uint128 hookLiquidity;
        uint128 totalLiquidity;
        uint256 excess0;
        uint256 excess1;
    }

    address private _index;

    mapping(PoolId => ActivePosition) private _activePositions;

    constructor(IPoolManager _poolManager, address index) BaseHook(_poolManager) {
        if (index == address(0)) {
            revert ZeroAddress();
        }

        _index = index;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        (SimulationContext memory context, uint256 balance0, uint256 balance1) = _prepareSimulation(key, params);

        if (context.hookLiquidity == 0) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        (uint256 hookFinal0, uint256 hookFinal1) = _simulateHookBalances(context, key.fee, params);

        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        // Ensure the pool will physically have enough balance to settle our take
        // in afterSwap. At take time the pool holds (poolBalance + balance_i), since
        // hook deposits balance_i in beforeSwap and trader input is not yet settled.
        // Hook take amount equals (hookFinal_i - excess_i), which after cancelling
        // excess gives the simplified inequality below.
        if (!_poolHasCapacityForTake(token0, token1, balance0, balance1, hookFinal0, hookFinal1)) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        if (IIndex(_index).previewBoundsCheck(token0, hookFinal0, token1, hookFinal1)) {
            _addLiquidity(key, context, balance0, balance1);
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        ActivePosition memory pos = _activePositions[key.toId()];
        if (pos.liquidity > 0) {
            _removeLiquidity(key, pos);
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    function _prepareSimulation(PoolKey calldata key, SwapParams calldata params)
        private
        view
        returns (SimulationContext memory context, uint256 balance0, uint256 balance1)
    {
        PoolId poolId = key.toId();
        int24 currentTick;
        (context.sqrtPriceX96, currentTick,,) = poolManager.getSlot0(poolId);
        uint128 poolLiquidity = poolManager.getLiquidity(poolId);

        int24 tickLower = TickBitmap.compress(currentTick, key.tickSpacing) * key.tickSpacing;
        // Edge case: currentTick sits exactly on the lower grid boundary.
        // For zeroForOne (price moves down) this range yields sqrtPriceTarget == sqrtPriceCurrent
        // so SwapMath cannot move the price and JIT is useless.
        // Shift the range one cell down so the current price ends up at the upper boundary.
        if (params.zeroForOne && currentTick == tickLower) {
            tickLower -= key.tickSpacing;
        }
        int24 tickUpper = tickLower + key.tickSpacing;

        context.tickLower = tickLower;
        context.tickUpper = tickUpper;
        context.sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        context.sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        balance0 = IERC20(Currency.unwrap(key.currency0)).balanceOf(_index);
        balance1 = IERC20(Currency.unwrap(key.currency1)).balanceOf(_index);

        context.hookLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            context.sqrtPriceX96,
            context.sqrtPriceLowerX96,
            context.sqrtPriceUpperX96,
            balance0,
            balance1
        );

        if (context.hookLiquidity == 0) {
            return (context, balance0, balance1);
        }

        (uint256 deposit0, uint256 deposit1) = _getAmountsForLiquidity(
            context.sqrtPriceX96,
            context.sqrtPriceLowerX96,
            context.sqrtPriceUpperX96,
            context.hookLiquidity
        );

        context.excess0 = balance0 - deposit0;
        context.excess1 = balance1 - deposit1;
        context.totalLiquidity = poolLiquidity + context.hookLiquidity;
    }

    function _poolHasCapacityForTake(
        address token0,
        address token1,
        uint256 balance0,
        uint256 balance1,
        uint256 hookFinal0,
        uint256 hookFinal1
    ) private view returns (bool) {
        uint256 available0 = IERC20(token0).balanceOf(address(poolManager)) + balance0;
        uint256 available1 = IERC20(token1).balanceOf(address(poolManager)) + balance1;
        return hookFinal0 <= available0 && hookFinal1 <= available1;
    }

    function _simulateHookBalances(SimulationContext memory context, uint24 fee, SwapParams calldata params)
        private
        pure
        returns (uint256 hookFinal0, uint256 hookFinal1)
    {
        uint160 sqrtPriceTargetX96 = params.zeroForOne
            ? (params.sqrtPriceLimitX96 > context.sqrtPriceLowerX96 ? params.sqrtPriceLimitX96 : context.sqrtPriceLowerX96)
            : (params.sqrtPriceLimitX96 < context.sqrtPriceUpperX96 ? params.sqrtPriceLimitX96 : context.sqrtPriceUpperX96);

        (uint160 sqrtPriceNextX96,,, uint256 feeAmount) = SwapMath.computeSwapStep(
            context.sqrtPriceX96,
            sqrtPriceTargetX96,
            context.totalLiquidity,
            params.amountSpecified,
            fee
        );

        (uint256 withdraw0, uint256 withdraw1) = _getAmountsForLiquidity(
            sqrtPriceNextX96,
            context.sqrtPriceLowerX96,
            context.sqrtPriceUpperX96,
            context.hookLiquidity
        );

        uint256 hookFeeShare = Math.mulDiv(feeAmount, context.hookLiquidity, context.totalLiquidity);

        hookFinal0 = context.excess0 + withdraw0 + (params.zeroForOne ? hookFeeShare : 0);
        hookFinal1 = context.excess1 + withdraw1 + (params.zeroForOne ? 0 : hookFeeShare);
    }

    function _addLiquidity(
        PoolKey calldata key,
        SimulationContext memory context,
        uint256 balance0,
        uint256 balance1
    ) private {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        if (balance0 > 0) {
            IIndex(_index).lendAsset(token0, balance0);
        }
        if (balance1 > 0) {
            IIndex(_index).lendAsset(token1, balance1);
        }

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: context.tickLower,
                tickUpper: context.tickUpper,
                liquidityDelta: int256(uint256(context.hookLiquidity)),
                salt: 0
            }),
            ""
        );

        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());

        _activePositions[key.toId()] = ActivePosition({
            tickLower: context.tickLower,
            tickUpper: context.tickUpper,
            liquidity: context.hookLiquidity
        });
    }

    function _removeLiquidity(PoolKey calldata key, ActivePosition memory pos) private {
        // Remove liquidity from the pool
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: pos.tickLower,
                tickUpper: pos.tickUpper,
                liquidityDelta: -int256(uint256(pos.liquidity)),
                salt: 0
            }),
            ""
        );

        console.log("DeltaAmount0: ", delta.amount0());
        console.log("DeltaAmount1: ", delta.amount1());

        // Take back the tokens (principal + fees)
        _take(key.currency0, delta.amount0());
        _take(key.currency1, delta.amount1());

        // Clear active position
        delete _activePositions[key.toId()];

        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        // Get balances held by hook
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        IERC20(token0).safeTransfer(_index, balance0);
        IERC20(token1).safeTransfer(_index, balance1);

        IIndex(_index).collectAsset(token0);
        IIndex(_index).collectAsset(token1);
    }

    /// @dev Mirrors v4-core LiquidityAmounts.getAmountsForLiquidity (not exported in periphery).
    function _getAmountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceLowerX96,
        uint160 sqrtPriceUpperX96,
        uint128 liquidity
    ) private pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceX96 <= sqrtPriceLowerX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity, false);
        } else if (sqrtPriceX96 < sqrtPriceUpperX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtPriceUpperX96, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtPriceLowerX96, sqrtPriceX96, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity, false);
        }
    }

    /// @dev Settle a negative delta (transfer tokens to pool manager)
    function _settle(Currency currency, int128 delta) private {
        if (delta >= 0) {
                return;
        }

        uint256 amount = uint256(int256(-delta));
        CurrencySettler.settle(currency, poolManager, address(this), amount, false);
    }

    /// @dev Take a positive delta (receive tokens from pool manager)
    function _take(Currency currency, int128 delta) private {
        if (delta <= 0) {
            return;
        }

        uint256 amount = uint256(int256(delta));
        CurrencySettler.take(currency, poolManager, address(this), amount, false);
    }
}