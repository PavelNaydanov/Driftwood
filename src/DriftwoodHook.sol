// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

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
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IDriftwoodHook, ActivePosition, SimulationContext} from "./interfaces/IDriftwoodHook.sol";
import {IIndex} from "./interfaces/IIndex.sol";
import {SimulationMath} from "./libraries/SimulationMath.sol";
import {ZeroAddress} from "./utils/CommonErrors.sol";

/// @title DriftwoodHook
/// @notice Uniswap v4 hook that wraps each swap with a JIT liquidity cycle backed by
/// the Index assets. Before the swap it borrows assets and adds a single-tick position;
/// after the swap it removes liquidity, returns everything to the index, and asserts
/// portfolio weights stay within tolerance.
contract DriftwoodHook is IDriftwoodHook, BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    mapping(PoolId poolId => ActivePosition activePosition) private _activePositions;
    address private _index;

    /// @param _poolManager Uniswap v4 PoolManager.
    /// @param index Backing Index contract.
    constructor(IPoolManager _poolManager, address index) BaseHook(_poolManager) {
        if (index == address(0)) {
            revert ZeroAddress();
        }

        _index = index;
    }

    // region - Hook -

    /// @dev Simulates the swap, runs capacity and weight checks, and opens a JIT position
    /// if both pass. Skips silently (no swap revert) when any check fails.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (SimulationContext memory context, uint256 balance0, uint256 balance1) = _prepareSimulation(key, params);

        if (context.hookLiquidity == 0) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        (uint256 predictedReturn0, uint256 predictedReturn1) =
            SimulationMath.simulateHookBalances(context, key.fee, params);

        // Ensure the pool will physically have enough balance to settle our take
        // in afterSwap. At take time the pool holds (poolBalance + balance_i), since
        // hook deposits balance_i in beforeSwap and trader input is not yet settled.
        // Hook take amount equals (hookFinal_i - excess_i), which after cancelling
        // excess gives the simplified inequality below.
        if (!_poolHasCapacityForTake(context.token0, context.token1, balance0, balance1, predictedReturn0, predictedReturn1)) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        if (IIndex(_index).previewBoundsCheck(context.token0, predictedReturn0, context.token1, predictedReturn1)) {
            _openJitPosition(key, context, balance0, balance1);
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev Closes the JIT position if one was opened in `_beforeSwap`.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        ActivePosition memory pos = _activePositions[key.toId()];
        if (pos.liquidity > 0) {
            _closeJitPosition(key, pos);
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    // endregion

    // region - View functions -

    /// @notice Hook flags: `beforeSwap` and `afterSwap` are active.
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

    /// @inheritdoc IDriftwoodHook
    function getActivePosition(PoolId poolId) external view returns (ActivePosition memory) {
        return _activePositions[poolId];
    }

    // endregion

    // region - Internal functions -

    /// @dev Collects pool state and index balances, picks a tick range, and computes
    /// the liquidity the hook can add. Returns `hookLiquidity == 0` when JIT is impossible.
    function _prepareSimulation(PoolKey calldata key, SwapParams calldata params)
        private
        view
        returns (SimulationContext memory context, uint256 balance0, uint256 balance1)
    {
        PoolId poolId = key.toId();
        int24 currentTick;
        (context.sqrtPriceX96, currentTick,,) = poolManager.getSlot0(poolId);
        uint128 poolLiquidity = poolManager.getLiquidity(poolId);
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        (int24 tickLower, int24 tickUpper) =
            SimulationMath.resolveTickRange(currentTick, key.tickSpacing, params.zeroForOne);

        context.token0 = token0;
        context.token1 = token1;
        context.tickLower = tickLower;
        context.tickUpper = tickUpper;
        context.sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        context.sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        balance0 = IERC20(token0).balanceOf(_index);
        balance1 = IERC20(token1).balanceOf(_index);

        context.hookLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            context.sqrtPriceX96, context.sqrtPriceLowerX96, context.sqrtPriceUpperX96, balance0, balance1
        );

        if (context.hookLiquidity == 0) {
            return (context, balance0, balance1);
        }

        (uint256 deposit0, uint256 deposit1) = SimulationMath.getAmountsForLiquidity(
            context.sqrtPriceX96, context.sqrtPriceLowerX96, context.sqrtPriceUpperX96, context.hookLiquidity
        );

        context.unused0 = balance0 - deposit0;
        context.unused1 = balance1 - deposit1;
        context.totalLiquidity = poolLiquidity + context.hookLiquidity;
    }

    /// @dev Makes sure the pool will hold enough tokens.
    function _poolHasCapacityForTake(
        address token0,
        address token1,
        uint256 balance0,
        uint256 balance1,
        uint256 predictedReturn0,
        uint256 predictedReturn1
    ) private view returns (bool) {
        uint256 available0 = IERC20(token0).balanceOf(address(poolManager)) + balance0;
        uint256 available1 = IERC20(token1).balanceOf(address(poolManager)) + balance1;

        return predictedReturn0 <= available0 && predictedReturn1 <= available1;
    }

    /// @dev Borrows from the index, adds liquidity to the pool, and records the position.
    /// Skips when one side of the index balance is zero.
    function _openJitPosition(
        PoolKey calldata key,
        SimulationContext memory context,
        uint256 balance0,
        uint256 balance1
    ) private {
        if (balance0 == 0 || balance1 == 0) {
            return;
        }

        // Create hook position in liquidity pool
        _activePositions[key.toId()] = ActivePosition({
            token0: context.token0,
            token1: context.token1,
            tickLower: context.tickLower,
            tickUpper: context.tickUpper,
            liquidity: context.hookLiquidity
        });

        // Lend assets from index
        IIndex(_index).lendAssets(context.token0, balance0, context.token1, balance1);

        // Add liquidity to the pool
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
    }

    /// @dev Removes liquidity, returns all token balances back to the index, and asserts
    /// the resulting portfolio weights via `IIndex.collectAssets`.
    function _closeJitPosition(PoolKey calldata key, ActivePosition memory pos) private {
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

        // Take back the tokens (principal + fees)
        _take(key.currency0, delta.amount0());
        _take(key.currency1, delta.amount1());

        // Clear active position
        delete _activePositions[key.toId()];

        IERC20(pos.token0).safeTransfer(_index, IERC20(pos.token0).balanceOf(address(this)));
        IERC20(pos.token1).safeTransfer(_index, IERC20(pos.token1).balanceOf(address(this)));

        // Callback call to the index
        IIndex(_index).collectAssets();
    }

    /// @dev Settle a negative delta (transfer tokens to pool manager).
    function _settle(Currency currency, int128 delta) private {
        if (delta >= 0) {
            return;
        }

        uint256 amount = SafeCast.toUint256(-int256(delta));
        CurrencySettler.settle(currency, poolManager, address(this), amount, false);
    }

    /// @dev Take a positive delta (receive tokens from pool manager).
    function _take(Currency currency, int128 delta) private {
        if (delta <= 0) {
            return;
        }

        uint256 amount = SafeCast.toUint256(int256(delta));
        CurrencySettler.take(currency, poolManager, address(this), amount, false);
    }

    // endregion
}
