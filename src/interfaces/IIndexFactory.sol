// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {AssetConfig} from "./IIndex.sol";

/// @title IIndexFactory
/// @notice Deploys minimal-proxy Index clones and seeds them with the initial set of assets.
interface IIndexFactory {
    /// @notice Emitted when a new Index clone is deployed and initialized.
    event IndexCreated(address index, string name, string symbol);

    /// @notice Deploy a new Index clone, transfer the initial set of assets in, and call `initialize`.
    /// @dev The caller must have approved this factory to pull each `assets[i].amount`.
    /// @return index Address of the new Index proxy.
    function createIndex(
        string calldata name,
        string calldata symbol,
        AssetConfig[] calldata assets,
        uint256 initialShares,
        address defaultAdmin
    ) external returns (address index);

    /// @notice Index implementation used as the template for all clones.
    function getIndexImplementation() external view returns (address);
}
