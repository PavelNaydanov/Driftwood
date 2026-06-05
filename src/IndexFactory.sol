// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IIndexFactory} from "./interfaces/IIndexFactory.sol";
import {IIndex, AssetConfig} from "./interfaces/IIndex.sol";

contract IndexFactory is IIndexFactory {
    using SafeERC20 for IERC20;

    address private _indexImplementation;

    constructor(address indexImplementation) {
        if (indexImplementation == address(0)) {
            revert ZeroAddress();
        }

        _indexImplementation = indexImplementation;
    }

    function createIndex(
        string calldata name,
        string calldata symbol,
        AssetConfig[] calldata assets,
        address defaultAdmin
    ) external returns (address index) {
        index = Clones.clone(_indexImplementation);

        for (uint256 i = 0; i < assets.length; i++) {
            AssetConfig memory asset = assets[i];

            if (asset.token == address(0)) {
                revert ZeroAddress();
            }

            if (asset.amount == 0) {
                revert ZeroAmount();
            }

            IERC20(asset.token).safeTransferFrom(msg.sender, index, asset.amount);
        }

        IIndex(index).initialize(name, symbol, assets, defaultAdmin);

        emit IndexCreated(index, name, symbol);
    }

    function getIndexImplementation() external view returns (address) {
        return _indexImplementation;
    }
}
