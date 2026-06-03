// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Index, AssetConfig} from "src/Index.sol";
import {BaseTest} from "./utils/BaseTest.sol";

contract IndexTest is BaseTest {
    Index public index;

    address defaultAdmin;

    function setUp() public {
        defaultAdmin = makeAddr("defaultAdmin");
        index = _deployIndex(defaultAdmin);
    }

    // region - Deploy -

    function test_deploy() external view {
        assertEq(index.name(), "Test Index");
        assertEq(index.symbol(), "TSTIDX");

        address[] memory tokens = index.getTokens();
        AssetConfig[] memory assets = _getAssets();

        for (uint256 i = 0; i < assets.length; i++) {
            assertEq(tokens[i], assets[i].token, "Invalid token");
            assertEq(index.getDataFeed(tokens[i]), assets[i].dataFeed);
            assertEq(IERC20(tokens[i]).balanceOf(address(index)), assets[i].amount, "Invalid asset amount");
        }
    }

    // endregion
}
