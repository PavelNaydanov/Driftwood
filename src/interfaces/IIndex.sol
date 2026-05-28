// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

interface IIndex {
    error InvalidShares();
    error InvalidReceiver();
    error InvalidNumberOfMinAmountsOut();
    error InsufficientAmountOut(address token, uint256 amountOut, uint256 minAmountOut);
}
