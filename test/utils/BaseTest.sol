// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {Index, AssetConfig} from "src/Index.sol";
import {IndexFactory} from "src/IndexFactory.sol";
import {DriftwoodHook} from "src/DriftwoodHook.sol";

import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockAggregator} from "test/mocks/MockAggregator.sol";

import {UniswapDeployers} from "./UniswapDeployers.sol";

abstract contract BaseTest is Test, UniswapDeployers {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    address public usdtFeed;
    address public ethFeed;

    address usdt;
    address weth;

    function _deployDriftwoodHook(address defaultAdmin) internal returns (DriftwoodHook createdHook, Index createdIndex, PoolKey memory poolKey) {
        _deployUniswapArtifactsAndLabel();
        createdIndex = _deployIndex(defaultAdmin);

        (Currency currency0, Currency currency1) = usdt < weth
            ? (Currency.wrap(usdt), Currency.wrap(weth))
            : (Currency.wrap(weth), Currency.wrap(usdt));

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (0x4444 << 144)
        );
        bytes memory constructorArgs = abi.encode(poolManager, address(createdIndex));

        deployCodeTo("DriftwoodHook.sol:DriftwoodHook", constructorArgs, flags);
        createdHook = DriftwoodHook(flags);

        // Create the pool
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(createdHook)
        });

        uint160 sqrtPriceX96 = usdt > weth
            ? _encodeSqrtPriceX96(3000e6, 1e18)  // currency0=WETH, currency1=USDT
            : _encodeSqrtPriceX96(1e18, 3000e6); // currency0=USDT, currency1=WETH
        poolManager.initialize(poolKey, sqrtPriceX96);

        bytes32 hookRole = createdIndex.HOOK_ROLE();

        vm.prank(defaultAdmin);
        createdIndex.grantRole(hookRole, address(createdHook));
    }

    function _deployUniswapArtifactsAndLabel() internal {
        deployArtifacts();

        vm.label(address(permit2), "Permit2");
        vm.label(address(poolManager), "V4PoolManager");
        vm.label(address(positionManager), "V4PositionManager");
        vm.label(address(swapRouter), "V4SwapRouter");
    }

    function _deployIndexFactory() internal returns (IndexFactory createdIndexFactory) {
        address indexImpl = address(new Index());
        createdIndexFactory = new IndexFactory(indexImpl);
    }

    function _deployIndex(address defaultAdmin) internal returns (Index createdIndex) {
        _deployTokens();
        _deployFeeds();

        AssetConfig[] memory assets = _getAssets();

        address indexImpl = address(new Index());
        createdIndex = Index(Clones.clone(indexImpl));

        for (uint256 i = 0; i < assets.length; i++) {
            AssetConfig memory asset = assets[i];
            deal(asset.token, address(this), asset.amount);

            IERC20(asset.token).safeTransfer(address(createdIndex), asset.amount);
        }

        createdIndex.initialize("Test Index", "TSTIDX", assets, defaultAdmin);
    }

    function _deployTokens() internal returns (address[] memory tokens) {
        usdt = address(new MockERC20(6));
        weth = address(new MockERC20(18));

        tokens = new address[](2);
        tokens[0] = usdt;
        tokens[1] = weth;

        vm.label(usdt, "USDT");
        vm.label(weth, "WETH");
    }

    function _deployFeeds() internal {
        usdtFeed = address(new MockAggregator(8, 1e8)); // $1.00 | feed decimals = 8
        ethFeed  = address(new MockAggregator(8, 3000e8)); // $3000.00 | feed decimals = 8
    }

    function _getAssets() internal view returns (AssetConfig[] memory assets) {
        require(usdt != address(0) && weth != address(0), "Tokens should be deployed");
        require(usdtFeed != address(0) && ethFeed != address(0), "Data feeds should be deployed");

        assets = new AssetConfig[](2);
        assets[0] = AssetConfig({
            token: usdt,
            dataFeed: usdtFeed,
            amount: 3_000_000_000e6,
            targetWeightBps: 5_000, // 50%
            toleranceBps: 500, // 5%
            maxPriceStaleness: 86400
        });

        assets[1] = AssetConfig({
            token: weth,
            dataFeed: ethFeed,
            amount: 1_000_000e18,
            targetWeightBps: 5_000, // 50%
            toleranceBps: 500, // 5%
            maxPriceStaleness: 3600
        });
    }

    function _etch(address target, bytes memory bytecode) internal override {
        vm.etch(target, bytecode);
    }

    function _encodeSqrtPriceX96(uint256 amount1, uint256 amount0) internal pure returns (uint160) {
        return uint160(Math.sqrt(FullMath.mulDiv(amount1, 1 << 192, amount0)));
    }
}
