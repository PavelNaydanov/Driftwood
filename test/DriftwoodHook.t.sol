// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {Index, JitDebt} from "src/Index.sol";
import {DriftwoodHook} from "src/DriftwoodHook.sol";
import {IDriftwoodHook, ActivePosition} from "src/interfaces/IDriftwoodHook.sol";
import {ZeroAddress} from "src/utils/CommonErrors.sol";

import {BaseTest} from "./utils/BaseTest.sol";

contract DriftwoodHookTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    DriftwoodHook public hook;
    Index public index;
    PoolKey public poolKey;

    address defaultAdmin;

    function setUp() public {
        defaultAdmin = makeAddr("defaultAdmin");
        (hook, index, poolKey) = _deployDriftwoodHook(defaultAdmin);

        vm.label(address(hook), "DriftwoodHook");
        vm.label(address(index), "Index");
    }

    // region - Deploy -

    function test_deploy() external view {
        assertNotEq(address(hook), address(0), "Hook should be deployed");
        assertEq(address(hook.poolManager()), address(poolManager));
    }

    // endregion

    // region - Swap -

    function test_swap_reference() public {
        uint256 indexBal0Before = IERC20(weth).balanceOf(address(index));
        uint256 indexBal1Before = IERC20(usdt).balanceOf(address(index));

        uint256 userBal0Before = IERC20(weth).balanceOf(address(this));
        uint256 userBal1Before = IERC20(usdt).balanceOf(address(this));

        (uint160 sqrtPriceBefore,,,) = poolManager.getSlot0(poolKey.toId());

        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: new bytes(0),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        uint256 indexBal0After = IERC20(weth).balanceOf(address(index));
        uint256 indexBal1After = IERC20(usdt).balanceOf(address(index));

        uint256 userBal0After = IERC20(weth).balanceOf(address(this));
        uint256 userBal1After = IERC20(usdt).balanceOf(address(this));

        assertGt(indexBal0After, indexBal0Before, "Index should has weth more than before swap");
        assertLt(indexBal1After, indexBal1Before, "Index should has usdt less than before swap");

        assertGt(userBal0Before, userBal0After, "User should has weth less than before swap");
        assertLt(userBal1Before, userBal1After, "User should has usdt more than before swap");

        ActivePosition memory pos = hook.getActivePosition(poolKey.toId());
        assertEq(pos.liquidity, 0, "Active position should be cleared");

        assertEq(IERC20(weth).balanceOf(address(hook)), 0, "Hook should not retain WETH");
        assertEq(IERC20(usdt).balanceOf(address(hook)), 0, "Hook should not retain USDT");

        JitDebt memory debt = index.getJitDebt();
        assertEq(debt.hook, address(0), "JIT debt should be cleared");

        bool stillInBounds = index.previewBoundsCheck(weth, indexBal0After, usdt, indexBal1After);
        assertTrue(stillInBounds, "Weights should remain within tolerance after JIT");

        (uint160 sqrtPriceAfter,,,) = poolManager.getSlot0(poolKey.toId());
        assertLt(sqrtPriceAfter, sqrtPriceBefore, "ZeroForOne should decrease sqrtPrice");
    }

    // endregion
}
