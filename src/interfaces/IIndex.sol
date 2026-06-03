// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

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
    error InvalidAsset(address token);
    error InsufficientAssetBalance(address token, uint256 amount);
    error OutstandingDebt(address hook, address token, uint256 amount);
    error InsufficientCollectAmount(address token, uint256 amount);

    function initialize(string calldata name, string calldata symbol, Asset[] calldata assets, address defaultAdmin) external;
    function lendAsset(address token, uint256 amount) external;
    function collectAsset(address token) external;
}
