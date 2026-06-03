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
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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
        SwapParams calldata,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        _addLiquidity(key);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        _removeLiquidity(key);
        return (BaseHook.afterSwap.selector, 0);
    }

    function _addLiquidity(PoolKey calldata key) private {
        PoolId poolId = key.toId();

        // Get current pool state
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolId);

        // Calculate tick range: [roundedTick, roundedTick + tickSpacing]
        int24 tickSpacing = key.tickSpacing;
        int24 tickLower = TickBitmap.compress(currentTick, tickSpacing) * tickSpacing;
        int24 tickUpper = tickLower + tickSpacing;

        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        // Get balances held by index
        uint256 balance0 = IERC20(token0).balanceOf(_index);
        uint256 balance1 = IERC20(token1).balanceOf(_index);

        if (balance0 == 0 && balance1 == 0) return;

        // Get assets from index
        IIndex(_index).lendAsset(token0, balance0);
        IIndex(_index).lendAsset(token1, balance1);

        // Calculate max liquidity from available balances
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            balance0,
            balance1
        );

        if (liquidity == 0) return;

        // Add liquidity to the pool
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: 0
            }),
            ""
        );

        // Settle the amounts owed to the pool
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());

        // Store active position for removal in afterSwap
        _activePositions[poolId] = ActivePosition({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity
        });
    }

    function _removeLiquidity(PoolKey calldata key) private {
        PoolId poolId = key.toId();
        ActivePosition memory pos = _activePositions[poolId];

        if (pos.liquidity == 0) return;

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
        delete _activePositions[poolId];

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