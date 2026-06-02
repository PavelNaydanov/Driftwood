// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Index, Asset} from "src/Index.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract IndexTest is Test {
    using SafeERC20 for IERC20;

    Index public index;

    address usdt;
    address weth;

    function setUp() public {
        usdt = address(new MockERC20(6));
        weth = address(new MockERC20(18));

        Asset[] memory assets = _getAssets();

        address indexImpl = address(new Index());
        index = Index(Clones.clone(indexImpl));

        for (uint256 i = 0; i < assets.length; i++) {
            Asset memory asset = assets[i];
            deal(asset.token, address(this), asset.amount);

            IERC20(asset.token).safeTransfer(address(index), asset.amount);
        }

        index.initialize("Test Index", "TSTIDX", assets);
    }

    // region - Deploy -

    function test_deploy() external view {
        assertEq(index.name(), "Test Index");
        assertEq(index.symbol(), "TSTIDX");

        Asset[] memory assets = _getAssets();
        address[] memory tokens = index.getTokens();

        for (uint256 i = 0; i < assets.length; i++) {
            assertEq(tokens[i], assets[i].token, "Invalid token");
            assertEq(IERC20(tokens[i]).balanceOf(address(index)), assets[i].amount, "Invalid asset amount");
        }
    }

    // endregion

    function _getAssets() internal view returns (Asset[] memory assets) {
        assets = new Asset[](2);

        assets[0] = Asset({token: usdt, amount: 1e6});
        assets[1] = Asset({token: weth, amount: 1e18});
    }
}
