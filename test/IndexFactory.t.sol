// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IndexFactory} from "src/IndexFactory.sol";
import {BaseTest} from "./utils/BaseTest.sol";

contract IndexFactoryTest is BaseTest {
    IndexFactory public factory;

    function setUp() public {
        factory = _deployIndexFactory();
    }

    // region - Deploy -

    function test_deploy() external view {
        assertNotEq(factory.getIndexImplementation(), address(0), "Invalid index implementation");
    }

    // endregion
}
