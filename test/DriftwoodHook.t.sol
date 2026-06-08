// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {Index, JitDebt} from "src/Index.sol";
import {IIndex} from "src/interfaces/IIndex.sol";
import {DriftwoodHook} from "src/DriftwoodHook.sol";
import {IDriftwoodHook, ActivePosition} from "src/interfaces/IDriftwoodHook.sol";
import {AggregatorV3Interface} from "src/interfaces/AggregatorV3Interface.sol";
import {ZeroAddress} from "src/utils/CommonErrors.sol";

import {MockAggregator} from "test/mocks/MockAggregator.sol";
import {BaseTest} from "test/utils/BaseTest.sol";

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

    function test_swap_jitSkippedOnHugeSwap() external {
        uint256 hugeAmount = 1e23; // 100,000 WETH — way more than native LP can absorb
        deal(weth, address(this), hugeAmount);

        uint256 indexBal0Before = IERC20(weth).balanceOf(address(index));
        uint256 indexBal1Before = IERC20(usdt).balanceOf(address(index));

        // Swap (should NOT revert — Variant D skips JIT, swap fills against native LP only)
        swapRouter.swapExactTokensForTokens({
            amountIn: hugeAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: new bytes(0),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertEq(
            IERC20(weth).balanceOf(address(index)),
            indexBal0Before,
            "Index WETH must be unchanged (JIT skipped)"
        );
        assertEq(
            IERC20(usdt).balanceOf(address(index)),
            indexBal1Before,
            "Index USDT must be unchanged (JIT skipped)"
        );

        ActivePosition memory pos = hook.getActivePosition(poolKey.toId());
        assertEq(pos.liquidity, 0, "No JIT position should be created");

        JitDebt memory debt = index.getJitDebt();
        assertEq(debt.hook, address(0), "JitDebt must be unset (no lendAssets call)");

        assertEq(IERC20(weth).balanceOf(address(hook)), 0, "Hook must not retain WETH");
        assertEq(IERC20(usdt).balanceOf(address(hook)), 0, "Hook must not retain USDT");
    }

    function test_swap_jitSkippedOnEthPump() external {
        // Pump ETH price $3000 → $5000 (Chainlink).
        // After pump, composition by Chainlink prices is 3750/6250 vs target 5000/5000.
        // Diff 1250bps > tolerance 500bps → previewBoundsCheck returns false.
        MockAggregator(ethFeed).setAnswer(5000e8);

        uint256 indexBal0Before = IERC20(weth).balanceOf(address(index));
        uint256 indexBal1Before = IERC20(usdt).balanceOf(address(index));

        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: new bytes(0),
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        assertEq(IERC20(weth).balanceOf(address(index)), indexBal0Before, "Index WETH must be unchanged");
        assertEq(IERC20(usdt).balanceOf(address(index)), indexBal1Before, "Index USDT must be unchanged");

        ActivePosition memory pos = hook.getActivePosition(poolKey.toId());
        assertEq(pos.liquidity, 0, "No JIT position");

        JitDebt memory debt = index.getJitDebt();
        assertEq(debt.hook, address(0), "JitDebt unset");

        assertEq(IERC20(weth).balanceOf(address(hook)), 0, "Hook holds no WETH");
        assertEq(IERC20(usdt).balanceOf(address(hook)), 0, "Hook holds no USDT");
    }

    function test_swap_revertsOnStalePrice() external {
        // ETH feed maxStaleness = 3600 (1h). Warp 2h forward → ETH feed is stale.
        // USDT feed maxStaleness = 86400 (24h) — still fresh.
        vm.warp(block.timestamp + 7200);

        try swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: new bytes(0),
            receiver: address(this),
            deadline: block.timestamp + 1
        }) {
            assertTrue(false, "Expected revert but swap succeeded");
        } catch (bytes memory err) {
            _assertRevertContainsSelector(err, IIndex.StalePrice.selector);
        }
    }

    function test_swap_revertsOnZeroPrice() external {
        // Simulate broken/zero oracle response for ETH
        MockAggregator(ethFeed).setAnswer(0);

        try swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: new bytes(0),
            receiver: address(this),
            deadline: block.timestamp + 1
        }) {
            assertTrue(false, "Expected revert but swap succeeded");
        } catch (bytes memory err) {
            _assertRevertContainsSelector(err, IIndex.InvalidPrice.selector);
        }
    }

    function test_swap_revertsOnAssertion() external {
        // Simulate Chainlink price diverging between predicate (in _beforeSwap) and
        // assertion (in _afterSwap → collectAssets):
        //   1st latestRoundData() call: $3000 → predicate computes 50/50 composition → JIT proceeds.
        //   2nd latestRoundData() call: $5000 → assertion sees ~6250/3750 → out of tolerance → revert.
        // Proves Variant B assertion catches divergence between predicted and actual state.
        bytes memory feedCalldata = abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector);

        bytes[] memory responses = new bytes[](2);
        responses[0] = abi.encode(uint80(1), int256(3000e8), block.timestamp, block.timestamp, uint80(1));
        responses[1] = abi.encode(uint80(2), int256(5000e8), block.timestamp, block.timestamp, uint80(2));

        vm.mockCalls(ethFeed, feedCalldata, responses);

        try swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: new bytes(0),
            receiver: address(this),
            deadline: block.timestamp + 1
        }) {
            assertTrue(false, "Expected revert but swap succeeded");
        } catch (bytes memory err) {
            _assertRevertContainsSelector(err, IIndex.WeightOutOfBounds.selector);
        }
    }

    // endregion
}
