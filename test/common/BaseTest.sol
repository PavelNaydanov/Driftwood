// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {Index, Asset} from "src/Index.sol";
import {IndexFactory} from "src/IndexFactory.sol";

import {MockERC20} from "test/mocks/MockERC20.sol";

abstract contract BaseTest is Test {
    using SafeERC20 for IERC20;

    address usdt;
    address weth;

    function _deployIndexFactory() internal returns (IndexFactory createdIndexFactory) {
        address indexImpl = address(new Index());
        createdIndexFactory = new IndexFactory(indexImpl);
    }

    function _deployIndex() internal returns (Index createdIndex) {
        address[] memory tokensToDeploy = _deployTokens();
        Asset[] memory assets = _getAssets(tokensToDeploy);

        address indexImpl = address(new Index());
        createdIndex = Index(Clones.clone(indexImpl));

        for (uint256 i = 0; i < assets.length; i++) {
            Asset memory asset = assets[i];
            deal(asset.token, address(this), asset.amount);

            IERC20(asset.token).safeTransfer(address(createdIndex), asset.amount);
        }

        createdIndex.initialize("Test Index", "TSTIDX", assets);
    }

    function _deployTokens() internal returns (address[] memory tokens) {
        usdt = address(new MockERC20(6));
        weth = address(new MockERC20(18));

        tokens = new address[](2);
        tokens[0] = usdt;
        tokens[1] = weth;
    }

    function _getAssets(address[] memory tokens) internal view returns (Asset[] memory assets) {
        uint256 numberOfTokens = tokens.length;

        assets = new Asset[](numberOfTokens);

        for (uint256 i = 0; i < numberOfTokens; i++) {
            address token = tokens[i];

            assets[i] = Asset({token: token, amount: 1 * 10 ** IERC20Metadata(token).decimals()});
        }
    }
}
