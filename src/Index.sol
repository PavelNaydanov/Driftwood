// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IIndex} from "./interfaces/IIndex.sol";

contract Index is IIndex, ERC20 {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private _assetSet;

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(uint256 shares, address receiver) external returns (address[] memory assets, uint256[] memory amounts) {
        if (shares == 0) {
            revert InvalidShares();
        }

        if (receiver == address(0)) {
            revert InvalidReceiver();
        }

        (assets, amounts) = _toAssets(shares, Math.Rounding.Ceil);

        for (uint256 i = 0; i < assets.length; i++) {
            if (amounts[i] != 0) {
                SafeERC20.safeTransferFrom(IERC20(assets[i]), msg.sender, address(this), amounts[i]);
            }
        }

        _mint(receiver, shares);
    }

    function redeem(
        uint256 shares,
        address receiver,
        uint256[] calldata minAmountsOut
    ) external returns (address[] memory assets, uint256[] memory amounts) {
        if (shares == 0) {
            revert InvalidShares();
        }

        if (receiver == address(0) || receiver == address(this)) {
            revert InvalidReceiver();
        }

        (assets, amounts) = _toAssets(shares, Math.Rounding.Floor);

        uint256 numberOfAssets = assets.length;
        if (numberOfAssets != minAmountsOut.length) {
            revert InvalidNumberOfMinAmountsOut();
        }

        _burn(msg.sender, shares);

        for (uint256 i = 0; i < numberOfAssets; i++) {
            if (amounts[i] < minAmountsOut[i]) {
                revert InsufficientAmountOut(assets[i], amounts[i], minAmountsOut[i]);
            }

            if (amounts[i] != 0) {
                SafeERC20.safeTransfer(IERC20(assets[i]), receiver, amounts[i]);
            }
        }
    }

    function _toAssets(uint256 shares, Math.Rounding rounding)
        private
        view
        returns (address[] memory assets, uint256[] memory amounts)
{
        (assets, amounts) = _totalAssets();

        uint256 numberOfAssets = assets.length;
        for (uint256 i = 0; i < numberOfAssets; i++) {
            amounts[i] = Math.mulDiv(shares, amounts[i], totalSupply(), rounding);
        }
    }

    function _totalAssets() private view returns (address[] memory assets, uint256[] memory amounts) {
        assets = _assetSet.values();

        uint256 numberOfAssets = assets.length;
        amounts = new uint256[](numberOfAssets);

        for (uint256 i = 0; i < numberOfAssets; i++) {
            amounts[i] = IERC20(assets[i]).balanceOf(address(this));
        }
    }
}