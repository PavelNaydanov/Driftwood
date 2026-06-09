// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickBitmap} from "@uniswap/v4-core/src/libraries/TickBitmap.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {SimulationContext} from "../interfaces/IDriftwoodHook.sol";

library SimulationMath {
    /// @dev Compute single-cell tick range covering `currentTick`. For `zeroForOne`
    /// on the lower boundary the range is shifted one cell down so `SwapMath` can move price.
    function resolveTickRange(int24 currentTick, int24 tickSpacing, bool zeroForOne)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        tickLower = TickBitmap.compress(currentTick, tickSpacing) * tickSpacing;
        if (zeroForOne && currentTick == tickLower) {
            tickLower -= tickSpacing;
        }

        tickUpper = tickLower + tickSpacing;
    }

    /// @dev Mirrors v4-core LiquidityAmounts.getAmountsForLiquidity with rounding=false
    function getAmountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceLowerX96,
        uint160 sqrtPriceUpperX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceX96 <= sqrtPriceLowerX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity, false);
        } else if (sqrtPriceX96 < sqrtPriceUpperX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtPriceUpperX96, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtPriceLowerX96, sqrtPriceX96, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity, false);
        }
    }

    /// @dev Predict hook token balances after the upcoming swap: partial-fill at the boundary,
    /// proportional fee share of the combined liquidity, and residual `unused` amounts from index.
    function simulateHookBalances(SimulationContext memory context, uint24 fee, SwapParams calldata params)
        internal
        pure
        returns (uint256 predictedReturn0, uint256 predictedReturn1)
    {
        uint160 sqrtPriceTargetX96 = params.zeroForOne
            ? (params.sqrtPriceLimitX96 > context.sqrtPriceLowerX96
                    ? params.sqrtPriceLimitX96
                    : context.sqrtPriceLowerX96)
            : (params.sqrtPriceLimitX96 < context.sqrtPriceUpperX96
                    ? params.sqrtPriceLimitX96
                    : context.sqrtPriceUpperX96);

        (uint160 sqrtPriceNextX96,,, uint256 feeAmount) = SwapMath.computeSwapStep(
            context.sqrtPriceX96, sqrtPriceTargetX96, context.totalLiquidity, params.amountSpecified, fee
        );

        (uint256 withdraw0, uint256 withdraw1) = getAmountsForLiquidity(
            sqrtPriceNextX96, context.sqrtPriceLowerX96, context.sqrtPriceUpperX96, context.hookLiquidity
        );

        uint256 hookFeeShare = Math.mulDiv(feeAmount, context.hookLiquidity, context.totalLiquidity);

        predictedReturn0 = context.unused0 + withdraw0 + (params.zeroForOne ? hookFeeShare : 0);
        predictedReturn1 = context.unused1 + withdraw1 + (params.zeroForOne ? 0 : hookFeeShare);
    }
}
