// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Stored JIT position for one pool.
/// @dev Only one active position per pool at a time; cleared at the end of `afterSwap`.
struct ActivePosition {
    address token0;
    address token1;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
}

/// @notice Per-swap simulation state shared between `_prepareSimulation`,
/// `SimulationMath.simulateHookBalances` and `_openJitPosition`.
/// @dev `unused0`/`unused1` are the parts of index balances that did not fit into the LP range.
struct SimulationContext {
    address token0;
    address token1;
    int24 tickLower;
    int24 tickUpper;
    uint160 sqrtPriceX96;
    uint160 sqrtPriceLowerX96;
    uint160 sqrtPriceUpperX96;
    uint128 hookLiquidity;
    uint128 totalLiquidity;
    uint256 unused0;
    uint256 unused1;
}

/// @title IDriftwoodHook
/// @notice Uniswap v4 hook that uses the index assets as JIT liquidity for each swap.
interface IDriftwoodHook {
    /// @notice Active JIT position for `poolId`, or a zeroed struct if none.
    function getActivePosition(PoolId poolId) external view returns (ActivePosition memory);
}
