// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

struct AssetConfig {
    address token;
    uint256 amount;
    address dataFeed;
    uint16 targetWeightBps; // 4000 = 40%
    uint16 toleranceBps; // 500 = 5pp
    uint64 maxPriceStaleness; // sec
}

struct Asset {
    address token;
    uint256 amount;
}

interface IIndex {
    event AssetLent(address indexed hook, address indexed token, uint256 amount);
    event AssetCollected(address indexed hook, address indexed token, uint256 amount);

    error InvalidNumberOfAssets();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidReceiver();
    error InvalidNumberOfMinAmountsOut();
    error InsufficientAmountOut(address token, uint256 amountOut, uint256 minAmountOut);
    error InvalidAssetAmount(address token, uint256 amount);
    error InvalidAssets();
    error InvalidAsset(address token);
    error InsufficientAssetBalance(address token, uint256 amount);
    error OutstandingDebt(address hook, address token, uint256 amount);
    error InsufficientCollectAmount(address token, uint256 amount);
    error InvalidWeightBps(address token);
    error InvalidTotalWeightBps();
    error InvalidToleranceBps(address token);
    error InvalidPrice(address token);
    error StalePrice(address token);
    error InvalidMaxPriceStaleness(address token);

    function initialize(string calldata name, string calldata symbol, AssetConfig[] calldata assets, address defaultAdmin) external;
    function lendAsset(address token, uint256 amount) external;
    function collectAsset(address token) external;
    function previewBoundsCheck(
        address token0,
        uint256 newBalance0,
        address token1,
        uint256 newBalance1
    ) external view returns (bool);
}
