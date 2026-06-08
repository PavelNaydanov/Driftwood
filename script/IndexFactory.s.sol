// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";

import {Index} from "src/Index.sol";
import {IndexFactory} from "src/IndexFactory.sol";

contract IndexFactoryScript is Script {
    Index public index;
    IndexFactory public indexFactory;

    function run() public {
        vm.startBroadcast();

        index = new Index();

        indexFactory = new IndexFactory(address(index));

        vm.stopBroadcast();
    }

    function test() external {}
}
