// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {Index} from "src/Index.sol";
import {DriftwoodHook} from "src/DriftwoodHook.sol";
import {MockAggregator} from "test/mocks/MockAggregator.sol";
import {BaseTest} from "test/utils/BaseTest.sol";

/// @notice Economic simulation of Driftwood. Not a unit test — it drives the real hook
/// end-to-end through realistic swap flow and reports the numbers used in the README
/// "Economics" section.
///
/// Index TVL at start: 1,000,000 WETH + 3,000,000,000 USDT = $6,000,000,000 at $3000/ETH,
/// 50/50 target weights, ±5% tolerance.
contract EconomicsTest is BaseTest {
    using StateLibrary for IPoolManager;

    DriftwoodHook hook;
    Index index;
    PoolKey poolKey;
    address defaultAdmin;

    // Buying WETH is zeroForOne only when WETH is currency1 of the pool.
    bool BUY_WETH_ZFO;
    uint256 jitFires;

    function setUp() public {
        defaultAdmin = makeAddr("defaultAdmin");
        (hook, index, poolKey) = _deployDriftwoodHook(defaultAdmin);
        BUY_WETH_ZFO = (weth == Currency.unwrap(poolKey.currency1));
    }

    // region - Scenario 1: yield from organic flow (flat market) -

    /// @dev Range-bound market: ETH price starts and ends at $3000. Volume flows through the
    /// pool as round-trip swaps (a sell immediately followed by an equal buy), so price stays
    /// flat and any surplus over the starting basket value is pure swap-fee yield.
    function test_econ_yieldFromOrganicFlow() external {
        uint256 P = 3000;
        uint256 valueStart = _indexValueUsd(P);

        uint256 DAYS = 30;
        uint256 PAIRS_PER_DAY = 10;
        uint256 wethLeg = 5_000e18; // $15M per leg @ $3000 (within the JIT capacity threshold)
        uint256 usdtLeg = 15_000_000e6; // $15M per leg

        uint256 volumeUsd;
        for (uint256 d = 0; d < DAYS; d++) {
            for (uint256 k = 0; k < PAIRS_PER_DAY; k++) {
                _sellWeth(wethLeg);
                _buyWeth(usdtLeg);
                volumeUsd += 2 * 15_000_000; // both legs, whole USD
            }
        }

        uint256 valueEnd = _indexValueUsd(P);
        uint256 surplus = valueEnd - valueStart;

        bool inBounds = index.previewBoundsCheck(
            weth, IERC20(weth).balanceOf(address(index)), usdt, IERC20(usdt).balanceOf(address(index))
        );

        console2.log("=== Scenario 1: yield from organic flow (flat $3000) ===");
        console2.log("TVL at start (USD):           ", valueStart / 1e6);
        console2.log("Total swap volume (USD):      ", volumeUsd);
        console2.log("Daily volume / TVL (bps):     ", (volumeUsd * 10_000) / (valueStart / 1e6) / DAYS);
        console2.log("Fee surplus over period (USD):", surplus / 1e6);
        console2.log("Period yield (bps):           ", (surplus * 10_000) / valueStart);
        console2.log("Annualized yield (bps):       ", (surplus * 10_000 * 365) / valueStart / DAYS);
        console2.log("JIT cycles fired:             ", jitFires);
        console2.log("Weights still in tolerance:   ", inBounds);

        assertGt(surplus, 0, "index must earn fee yield");
        assertTrue(inBounds, "weights must stay within tolerance");
    }

    // endregion

    // region - Scenario 2: trending market (rebalancing vs HODL) -

    /// @dev Trending market: ETH "market" price steps up to $3600 (+20%). At that price the
    /// untouched 50/50 basket drifts to ~54.5% WETH — within the ±5% tolerance, so the hook
    /// keeps lending. Arbitrageurs buy the now-cheap WETH out of the pool; the index sells WETH,
    /// rebalancing back toward 50/50 and pocketing a fee on every trade. We then compare the
    /// rebalanced index against a passive HODL of the same starting basket, valued at $3600.
    function test_econ_trendingVsHodl() external {
        uint256 P0 = 3000;
        uint256 weth0 = IERC20(weth).balanceOf(address(index));
        uint256 usdt0 = IERC20(usdt).balanceOf(address(index));

        uint256 P = 3600;
        MockAggregator(ethFeed).setAnswer(int256(P * 1e8));

        // Arbitrageurs buy WETH (≤ JIT capacity per trade) until the index is rebalanced back
        // to ~50/50 at the new price, or we hit the iteration cap.
        for (uint256 i = 0; i < 60; i++) {
            uint256 wBps = _wethWeightBps(P);
            if (wBps <= 5_010) break; // back at target (±0.1%)
            _buyWeth(18_000_000e6); // ~5000 WETH @ $3600, within capacity
        }

        uint256 wethEnd = IERC20(weth).balanceOf(address(index));
        uint256 usdtEnd = IERC20(usdt).balanceOf(address(index));

        uint256 startValue = usdt0 + (weth0 * P0) / 1e12;
        uint256 hodlValue = usdt0 + (weth0 * P) / 1e12;
        uint256 driftValue = usdtEnd + (wethEnd * P) / 1e12;

        bool inBounds = index.previewBoundsCheck(weth, wethEnd, usdt, usdtEnd);

        console2.log("=== Scenario 2: trending market $3000 -> $3600 (+20%) ===");
        console2.log("Start value @ $3000 (USD):    ", startValue / 1e6);
        console2.log("HODL  value @ $3600 (USD):    ", hodlValue / 1e6);
        console2.log("Driftwood   @ $3600 (USD):    ", driftValue / 1e6);
        console2.log("WETH sold while rebalancing:  ", (weth0 - wethEnd) / 1e18);
        console2.log("WETH weight after (bps):      ", _wethWeightBps(P));
        console2.log("JIT cycles fired:             ", jitFires);
        console2.log("Weights in tolerance:         ", inBounds);
        if (hodlValue >= driftValue) {
            console2.log("Driftwood vs HODL (bps gap):  ", ((hodlValue - driftValue) * 10_000) / hodlValue);
        } else {
            console2.log("Driftwood OVER HODL (bps):    ", ((driftValue - hodlValue) * 10_000) / hodlValue);
        }
        // Fee income earned during the rebalance, isolated from the price move: value the
        // rebalanced basket back at the START price and compare to the start value.
        uint256 valueAtP0 = usdtEnd + (wethEnd * P0) / 1e12;
        console2.log("Fee income (valued @ $3000):  ", (valueAtP0 - startValue) / 1e6);

        assertTrue(inBounds, "weights must stay within tolerance");
    }

    // endregion

    // region - Helpers -

    function _sellWeth(uint256 wethAmount) internal {
        _swap(!BUY_WETH_ZFO, weth, wethAmount);
    }

    function _buyWeth(uint256 usdtAmount) internal {
        _swap(BUY_WETH_ZFO, usdt, usdtAmount);
    }

    function _swap(bool zeroForOne, address tokenIn, uint256 amountIn) internal {
        uint256 before = IERC20(weth).balanceOf(address(index));
        deal(tokenIn, address(this), amountIn);
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: new bytes(0),
            receiver: address(this),
            deadline: block.timestamp + 1
        });
        if (IERC20(weth).balanceOf(address(index)) != before) {
            jitFires++;
        }
    }

    /// @dev Index value in USD, scaled to 1e6 (USDT units). priceUsd is whole dollars.
    function _indexValueUsd(uint256 priceUsd) internal view returns (uint256) {
        uint256 wethBal = IERC20(weth).balanceOf(address(index));
        uint256 usdtBal = IERC20(usdt).balanceOf(address(index));
        return usdtBal + (wethBal * priceUsd) / 1e12;
    }

    function _wethWeightBps(uint256 priceUsd) internal view returns (uint256) {
        uint256 wethVal = (IERC20(weth).balanceOf(address(index)) * priceUsd) / 1e12;
        return (wethVal * 10_000) / _indexValueUsd(priceUsd);
    }

    // endregion
}
