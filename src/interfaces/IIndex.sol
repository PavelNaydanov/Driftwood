// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

struct AssetConfig {
    address token;
    uint256 amount;
    address dataFeed;
    uint32 maxPriceStaleness; // sec
    uint16 targetWeightBps; // 4000 = 40%
    uint16 toleranceBps; // 500 = 5pp
}

struct Asset {
    address dataFeed;
    uint8 feedDecimals;
    uint8 tokenDecimals;
    uint32 maxPriceStaleness;
    uint16 targetWeightBps;
    uint16 toleranceBps;
}

struct AssetBalance {
    address token;
    uint256 amount;
}

struct JitDebt {
    address hook;
    address token0;
    address token1;
}

interface IIndex {
    event AssetsLent(
        address indexed hook,
        address indexed token0,
        uint256 amount0,
        uint256 balanceBefore0,
        address indexed token1,
        uint256 amount1,
        uint256 balanceBefore1
    );
    event AssetsCollected(
        address indexed hook,
        address indexed token0,
        uint256 balanceAfter0,
        address indexed token1,
        uint256 balanceAfter1
    );

    error InvalidNumberOfAssets();
    error InvalidReceiver();
    error InvalidNumberOfMinAmountsOut();
    error InsufficientAmountOut(address token, uint256 amountOut, uint256 minAmountOut);
    error InvalidAssetAmount(address token, uint256 amount);
    error SameAssets();
    error TokensMismatch();
    error InvalidAsset(address token);
    error InsufficientAssetBalance(address token, uint256 amount);
    error JitIsActive();
    error JitIsNotActive();
    error InvalidCollector();
    error WeightOutOfBounds(address token0, uint256 balance0, address token1, uint256 balance1);
    error InvalidWeightBps(address token);
    error InvalidTotalWeightBps();
    error InvalidToleranceBps(address token);
    error InvalidPrice(address token);
    error StalePrice(address token);
    error InvalidMaxPriceStaleness(address token);

    function initialize(
        string calldata name,
        string calldata symbol,
        AssetConfig[] calldata assets,
        address defaultAdmin
    ) external;
    function lendAssets(address token0, uint256 amount0, address token1, uint256 amount1) external;
    function collectAssets(address token0, address token1) external;
    function previewBoundsCheck(address token0, uint256 newBalance0, address token1, uint256 newBalance1)
        external
        view
        returns (bool);
    // TODO: add interface
}
