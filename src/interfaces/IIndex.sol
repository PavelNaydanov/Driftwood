// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

struct Asset {
    address token;
    uint256 amount;
}

interface IIndex {
    error InvalidNumberOfAssets();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidReceiver();
    error InvalidNumberOfMinAmountsOut();
    error InsufficientAmountOut(address token, uint256 amountOut, uint256 minAmountOut);
    error InvalidAssetAmount(address token, uint256 amount);

    function initialize(string calldata name, string calldata symbol, Asset[] calldata assets) external;
}
