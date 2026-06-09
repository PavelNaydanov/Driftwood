// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

struct ActivePosition {
    address token0;
    address token1;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
}

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

interface IDriftwoodHook {
    // TODO: add interface
}
