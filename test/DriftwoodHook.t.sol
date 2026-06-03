// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console} from "forge-std/Test.sol"; // TODO: remove
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {Index} from "src/Index.sol";
import {DriftwoodHook} from "src/DriftwoodHook.sol";

import {BaseTest} from "./utils/BaseTest.sol";

contract DriftwoodHookTest is BaseTest {
    DriftwoodHook public hook;
    Index public index;
    PoolKey public poolKey;

    function setUp() public {
        (hook, index, poolKey) = _deployDriftwoodHook();

        vm.label(address(hook), "DriftwoodHook");
        vm.label(address(index), "Index");
    }

    // region - Deploy -

    function test_deploy() external view {
        assertNotEq(address(hook), address(0), "Hook should be deployed");
        assertEq(address(hook.poolManager()), address(poolManager));
    }

    // endregion

    function test_swap() public {
        uint256 bal0Before = IERC20(usdt).balanceOf(address(index));
        uint256 bal1Before = IERC20(weth).balanceOf(address(index));
        console.log("Balance index before swap: ", bal0Before, bal1Before);

        swapRouter.swapExactTokensForTokens({
            amountIn: 1e2,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: new bytes(0),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        uint256 bal0After = IERC20(usdt).balanceOf(address(index));
        uint256 bal1After = IERC20(weth).balanceOf(address(index));
        console.log("Balance index after swap: ", bal0After, bal1After);

        // TODO: check that assets were transferred from index to hook and back, and that the swap was executed correctly
        // assertTrue(hookTotal > 90e18, "Hook should retain most of its deposited tokens");

        // // Active position should be cleared after each swap
        // JITLiquidityHook.ActivePosition memory pos = hook.getActivePosition(poolKey);
        // assertEq(pos.liquidity, 0, "Active position should be cleared");
    }
}