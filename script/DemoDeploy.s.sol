// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Index, AssetConfig} from "src/Index.sol";
import {IndexFactory} from "src/IndexFactory.sol";
import {DriftwoodHook} from "src/DriftwoodHook.sol";

import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockAggregator} from "test/mocks/MockAggregator.sol";

contract DemoDeployScript is Script {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    uint256 constant public INITIAL_WETH_AMOUNT = 1e18;
    uint256 constant public INITIAL_USDT_AMOUNT = 3_000e6;
    uint256 constant public INITIAL_SHARES = 6_000e18;

    address public indexImpl;
    IndexFactory public indexFactory;
    address public index;
    DriftwoodHook public hook;

    function run(address poolManager) public {
        vm.startBroadcast();

        // The actual broadcaster (the key from --interactives/--private-key/--sender),
        // NOT msg.sender, which inside a script defaults to 0x1804...
        (, address deployer,) = vm.readCallers();

        // Deploy tokens
        address weth = address(new MockERC20(18));
        address usdt = address(new MockERC20(6));

        // Deploy dataFeeds
        address ethFeed = address(new MockAggregator(8, 3000e8)); // $3000.00 | feed decimals = 8
        address usdtFeed = address(new MockAggregator(8, 1e8)); // $1.00 | feed decimals = 8

        // Simulate tokens to deployer
        MockERC20(weth).mint(deployer, INITIAL_WETH_AMOUNT);
        MockERC20(usdt).mint(deployer, INITIAL_USDT_AMOUNT);

        // Deploy factory
        indexImpl = address(new Index());
        indexFactory = new IndexFactory(indexImpl);

        // Approve factory to pull initial assets
        IERC20(weth).approve(address(indexFactory), INITIAL_WETH_AMOUNT);
        IERC20(usdt).approve(address(indexFactory), INITIAL_USDT_AMOUNT);

        // Create index
        AssetConfig[] memory assetConfigs = _generateAssetConfigs(weth, usdt, ethFeed, usdtFeed);
        index = indexFactory.createIndex("Demo index", "DT", assetConfigs, INITIAL_SHARES, deployer);

        // Deploy hook
        (Currency currency0, Currency currency1) =
            usdt < weth ? (Currency.wrap(usdt), Currency.wrap(weth)) : (Currency.wrap(weth), Currency.wrap(usdt));

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory constructorArgs = abi.encode(poolManager, index);

        (address hookAddress, bytes32 salt) =
        HookMiner.find(CREATE2_FACTORY, flags, type(DriftwoodHook).creationCode, constructorArgs);
        hook = new DriftwoodHook{salt: salt}(IPoolManager(poolManager), index);

        require(address(hook) == hookAddress, "DemoDeploy: Hook Address Mismatch");

        // Grant Hook role
        bytes32 hookRole = Index(index).HOOK_ROLE();
        Index(index).grantRole(hookRole, address(hook));

        // Create the pool
        PoolKey memory poolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(hook)
        });

        uint160 sqrtPriceX96 = usdt > weth
            ? _encodeSqrtPriceX96(3000e6, 1e18)  // currency0=WETH, currency1=USDT
            : _encodeSqrtPriceX96(1e18, 3000e6); // currency0=USDT, currency1=WETH

        IPoolManager(poolManager).initialize(poolKey, sqrtPriceX96);

        vm.stopBroadcast();

        console.log("Deployments");
        console.log("Weth: ", weth);
        console.log("Usdt: ", usdt);
        console.log("Index factory: ", address(indexFactory));
        console.log("Index: ", index);
        console.log("Hook: ", address(hook));

        console.log("PoolId: ");
        console.logBytes32(PoolId.unwrap(poolKey.toId()));
    }

    function _generateAssetConfigs(address weth, address usdt, address ethFeed, address usdtFeed) private pure returns (AssetConfig[] memory assetConfigs) {
        assetConfigs = new AssetConfig[](2);

        assetConfigs[0] = AssetConfig({
            token: usdt,
            amount: INITIAL_USDT_AMOUNT,
            dataFeed: usdtFeed,
            maxPriceStaleness: type(uint32).max, // only for demo stand
            targetWeightBps: 5_000, // 50%
            toleranceBps: 500 // 5%
        });

        assetConfigs[1] = AssetConfig({
            token: weth,
            amount: INITIAL_WETH_AMOUNT,
            dataFeed: ethFeed,
            maxPriceStaleness: type(uint32).max, // only for demo stand,
            targetWeightBps: 5_000, // 50%
            toleranceBps: 500 // 5%
        });
    }

    function _encodeSqrtPriceX96(uint256 amount1, uint256 amount0) internal pure returns (uint160) {
        return uint160(Math.sqrt(FullMath.mulDiv(amount1, 1 << 192, amount0)));
    }

    function test() external {}
}
