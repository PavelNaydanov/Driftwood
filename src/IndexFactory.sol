// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IIndexFactory} from "./interfaces/IIndexFactory.sol";
import {IIndex, Asset} from "./interfaces/IIndex.sol";

contract IndexFactory is IIndexFactory {
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
        Asset[] calldata assets
    ) external returns (address index) {
        index = Clones.clone(_indexImplementation);
        IIndex(index).initialize(name, symbol, assets);

        emit IndexCreated(index, name, symbol);
    }
}