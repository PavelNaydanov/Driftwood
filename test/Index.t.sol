// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Index, AssetConfig} from "src/Index.sol";
import {IIndex} from "src/interfaces/IIndex.sol";
import {BaseTest} from "./utils/BaseTest.sol";

contract IndexTest is BaseTest {
    Index public index;

    address defaultAdmin;

    function setUp() public {
        defaultAdmin = makeAddr("defaultAdmin");
        index = _deployIndex(defaultAdmin);

        bytes32 hookRole = index.HOOK_ROLE();
        vm.prank(defaultAdmin);
        index.grantRole(hookRole, address(this));
    }

    // region - Deploy -

    function test_deploy() external view {
        assertEq(index.name(), "Test Index");
        assertEq(index.symbol(), "TSTIDX");

        address[] memory tokens = index.getTokens();
        AssetConfig[] memory assetConfigs = _getAssetConfigs();

        for (uint256 i = 0; i < assetConfigs.length; i++) {
            assertEq(tokens[i], assetConfigs[i].token, "Invalid token");
            assertEq(index.getAsset(tokens[i]).dataFeed, assetConfigs[i].dataFeed);
            assertEq(index.getAsset(tokens[i]).targetWeightBps, assetConfigs[i].targetWeightBps);
            assertEq(index.getAsset(tokens[i]).toleranceBps, assetConfigs[i].toleranceBps);
            assertEq(index.getAsset(tokens[i]).maxPriceStaleness, assetConfigs[i].maxPriceStaleness);
            assertEq(IERC20(tokens[i]).balanceOf(address(index)), assetConfigs[i].amount, "Invalid asset amount");
        }
    }

    // endregion

    // region - Collect Assets -

    function test_collectAssets_revertsOnWeightOutOfBounds() external {
        index.lendAssets(weth, 200_000e18, usdt, 1);

        // Don't transfer anything back. collectAssets must revert via Variant B assertion.
        try index.collectAssets(weth, usdt) {
            assertTrue(false, "Expected revert but collectAssets succeeded");
        } catch (bytes memory err) {
            _assertRevertContainsSelector(err, IIndex.WeightOutOfBounds.selector);
        }
    }

    // TODO: continue

    // endregion
}
