// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Index, Asset} from "src/Index.sol";
import {BaseTest} from "./utils/BaseTest.sol";

contract IndexTest is BaseTest {
    Index public index;

    function setUp() public {
        index = _deployIndex();
    }

    // region - Deploy -

    function test_deploy() external view {
        assertEq(index.name(), "Test Index");
        assertEq(index.symbol(), "TSTIDX");

        address[] memory tokens = index.getTokens();
        Asset[] memory assets = _getAssets(tokens);

        for (uint256 i = 0; i < assets.length; i++) {
            assertEq(tokens[i], assets[i].token, "Invalid token");
            assertEq(IERC20(tokens[i]).balanceOf(address(index)), assets[i].amount, "Invalid asset amount");
        }
    }

    // endregion
}
