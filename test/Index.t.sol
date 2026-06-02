// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Index, Asset} from "src/Index.sol";
import {BaseTest} from "./common/BaseTest.sol";

contract IndexTest is BaseTest {
    Index public index;

    function setUp() public {
        index = _deployIndex();
    }
}
