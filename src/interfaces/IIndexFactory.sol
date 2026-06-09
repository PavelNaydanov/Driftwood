// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {AssetConfig} from "./IIndex.sol";

interface IIndexFactory {
    event IndexCreated(address index, string name, string symbol);

    function createIndex(
        string calldata name,
        string calldata symbol,
        AssetConfig[] calldata assets,
        uint256 initialShares,
        address defaultAdmin
    ) external returns (address index);
    function getIndexImplementation() external view returns (address);
}
