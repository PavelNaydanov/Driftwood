// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {Index, AssetConfig, Asset} from "src/Index.sol";
import {IndexFactory} from "src/IndexFactory.sol";
import {DriftwoodHook} from "src/DriftwoodHook.sol";

import {MockERC20} from "test/mocks/MockERC20.sol";
import {UniswapDeployers} from "./UniswapDeployers.sol";

abstract contract BaseTest is Test, UniswapDeployers {
    address constant public USDT_DATA_FEED = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address constant public ETH_DATA_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    address usdt;
    address weth;

    function _deployDriftwoodHook(address defaultAdmin) internal returns (DriftwoodHook createdHook, Index createdIndex, PoolKey memory poolKey) {
        _deployUniswapArtifactsAndLabel();
        createdIndex = _deployIndex(defaultAdmin);

        Currency currency0;
        Currency currency1;
        if (usdt > weth) {
            (currency0, currency1) = (Currency.wrap(address(weth)), Currency.wrap(address(usdt)));
        }

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
        PoolId poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

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
    }

    function _getAssets() internal view returns (AssetConfig[] memory assets) {
        assets = new AssetConfig[](2);
        assets[0] = AssetConfig({
            token: usdt,
            dataFeed: USDT_DATA_FEED,
            amount: 1_000_0000e6
        });

        assets[1] = AssetConfig({
            token: weth,
            dataFeed: ETH_DATA_FEED,
            amount: 1_000_0000e18
        });
    }

    function _etch(address target, bytes memory bytecode) internal override {
        vm.etch(target, bytecode);
    }
}
