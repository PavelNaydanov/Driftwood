// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Index} from "src/Index.sol";

contract IndexTest is Test {
    Index public index;

    function setUp() public {
        index = new Index();
    }
}
