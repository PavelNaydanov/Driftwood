// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IIndex, Asset} from "./interfaces/IIndex.sol";

contract Index is IIndex, ERC20 {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private _tokenSet;

    constructor(string memory name, string memory symbol, Asset[] memory assets) ERC20(name, symbol) {
        _initAssets(assets);
    }

    function mint(uint256 shares, address receiver) external {
        if (shares == 0) {
            revert ZeroAmount();
        }

        if (receiver == address(0) || receiver == address(this)) {
            revert InvalidReceiver();
        }

        Asset[] memory assets = _toAssets(shares, Math.Rounding.Ceil);
        for (uint256 i = 0; i < assets.length; i++) {
            Asset memory asset = assets[i];

            if (asset.amount != 0) {
                SafeERC20.safeTransferFrom(IERC20(asset.token), msg.sender, address(this), asset.amount);
            }
        }

        _mint(receiver, shares);
    }

    function redeem(
        uint256 shares,
        address receiver,
        uint256[] calldata minAmountsOut
    ) external {
        if (shares == 0) {
            revert ZeroAmount();
        }

        if (receiver == address(0) || receiver == address(this)) {
            revert InvalidReceiver();
        }

        Asset[] memory assets = _toAssets(shares, Math.Rounding.Floor);

        uint256 numberOfAssets = assets.length;
        if (numberOfAssets != minAmountsOut.length) {
            revert InvalidNumberOfMinAmountsOut();
        }

        _burn(msg.sender, shares);

        for (uint256 i = 0; i < numberOfAssets; i++) {
            Asset memory asset = assets[i];
            if (asset.amount < minAmountsOut[i]) {
                revert InsufficientAmountOut(asset.token, asset.amount, minAmountsOut[i]);
            }

            if (asset.amount != 0) {
                SafeERC20.safeTransfer(IERC20(asset.token), receiver, asset.amount);
            }
        }
    }

    function _initAssets(Asset[] memory assets) private {
        uint256 numberOfAssets = assets.length;
        if (numberOfAssets < 2) {
            revert InvalidNumberOfAssets();
        }

        for (uint256 i = 0; i < numberOfAssets; i++) {
            Asset memory asset = assets[i];

            if (asset.token == address(0)) {
                revert ZeroAddress();
            }

            if (asset.amount == 0) {
                revert ZeroAmount();
            }

            _tokenSet.add(asset.token);

            SafeERC20.safeTransferFrom(IERC20(asset.token), msg.sender, address(this), asset.amount);
        }
    }

    function _toAssets(uint256 shares, Math.Rounding rounding)
        private
        view
        returns (Asset[] memory assets)
{
        uint256 numberOfAssets = _tokenSet.values().length;
        assets = new Asset[](numberOfAssets);

        for (uint256 i = 0; i < numberOfAssets; i++) {
            address token = _tokenSet.at(i);

            assets[i] = Asset({
                token: token,
                amount: Math.mulDiv(shares, IERC20(token).balanceOf(address(this)), totalSupply(), rounding)
            });
        }
    }
}