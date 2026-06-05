// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IIndex, AssetConfig, Asset, AssetBalance, JitDebt} from "./interfaces/IIndex.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

contract Index is IIndex, ERC20Upgradeable, AccessControlUpgradeable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint16 public constant MAX_BPS = 10_000;
    bytes32 public constant HOOK_ROLE = keccak256("HOOK_ROLE");

    EnumerableSet.AddressSet private _tokenSet;
    mapping(address token => Asset asset) private _assets;

    JitDebt private _jitDebt;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string calldata name,
        string calldata symbol,
        AssetConfig[] calldata assetConfigs,
        address defaultAdmin
    ) external initializer {
        __ERC20_init(name, symbol);
        __AccessControl_init();

        _initAssets(assetConfigs);
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
    }

    function mint(uint256 shares, address receiver) external {
        if (shares == 0) {
            revert ZeroAmount();
        }

        if (receiver == address(0) || receiver == address(this)) {
            revert InvalidReceiver();
        }

        AssetBalance[] memory assetBalances = _toAssets(shares, Math.Rounding.Ceil);
        for (uint256 i = 0; i < assetBalances.length; i++) {
            AssetBalance memory assetBalance = assetBalances[i];

            if (assetBalance.amount != 0) {
                SafeERC20.safeTransferFrom(IERC20(assetBalance.token), msg.sender, address(this), assetBalance.amount);
            }
        }

        _mint(receiver, shares);
    }

    function redeem(uint256 shares, address receiver, uint256[] calldata minAmountsOut) external {
        if (shares == 0) {
            revert ZeroAmount();
        }

        if (receiver == address(0) || receiver == address(this)) {
            revert InvalidReceiver();
        }

        AssetBalance[] memory assetBalances = _toAssets(shares, Math.Rounding.Floor);

        uint256 numberOfAssets = assetBalances.length;
        if (numberOfAssets != minAmountsOut.length) {
            revert InvalidNumberOfMinAmountsOut();
        }

        _burn(msg.sender, shares);

        for (uint256 i = 0; i < numberOfAssets; i++) {
            AssetBalance memory assetBalance = assetBalances[i];
            if (assetBalance.amount < minAmountsOut[i]) {
                revert InsufficientAmountOut(assetBalance.token, assetBalance.amount, minAmountsOut[i]);
            }

            if (assetBalance.amount != 0) {
                SafeERC20.safeTransfer(IERC20(assetBalance.token), receiver, assetBalance.amount);
            }
        }
    }

    function lendAssets(address token0, uint256 amount0, address token1, uint256 amount1) external onlyRole(HOOK_ROLE) {
        if (_jitDebt.hook != address(0)) {
            revert JitIsActive();
        }

        if (token0 == address(0) || token1 == address(0)) {
            revert ZeroAddress();
        }
        if (amount0 == 0 || amount1 == 0) {
            revert ZeroAmount();
        }

        if (!_tokenSet.contains(token0)) {
            revert InvalidAsset(token0);
        }

        if (!_tokenSet.contains(token1)) {
            revert InvalidAsset(token1);
        }

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        if (balance0 < amount0) {
            revert InsufficientAssetBalance(token0, amount0);
        }

        if (balance1 < amount1) {
            revert InsufficientAssetBalance(token1, amount1);
        }

        _jitDebt = JitDebt({token0: token0, token1: token1, hook: msg.sender});
        IERC20(token0).safeTransfer(msg.sender, amount0);
        IERC20(token1).safeTransfer(msg.sender, amount1);

        emit AssetsLent(msg.sender, token0, amount0, balance0, token1, amount1, balance1);
    }

    function collectAssets(address token0, address token1) external onlyRole(HOOK_ROLE) {
        JitDebt memory jitDebt = _jitDebt;

        if (jitDebt.hook == address(0)) {
            revert JitIsNotActive();
        }

        if (token0 != jitDebt.token0 || token1 != jitDebt.token1) {
            revert TokensMismatch();
        }

        if (msg.sender != jitDebt.hook) {
            revert InvalidCollector();
        }

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        if (!_previewBoundsCheck(token0, balance0, token1, balance1)) {
            revert WeightOutOfBounds(token0, balance0, token1, balance1);
        }

        delete _jitDebt;

        emit AssetsCollected(msg.sender, token0, balance0, token1, balance1);
    }

    function getTokens() external view returns (address[] memory) {
        return _tokenSet.values();
    }

    function getAsset(address token) external view returns (Asset memory) {
        return _assets[token];
    }

    function _initAssets(AssetConfig[] memory assetConfigs) private {
        uint256 numberOfAssets = assetConfigs.length;
        if (numberOfAssets < 2) {
            revert InvalidNumberOfAssets();
        }

        uint256 totalWeightBps;
        for (uint256 i = 0; i < numberOfAssets; i++) {
            AssetConfig memory config = assetConfigs[i];

            if (config.token == address(0) || config.dataFeed == address(0)) {
                revert ZeroAddress();
            }

            if (config.amount == 0) {
                revert ZeroAmount();
            }

            if (config.targetWeightBps == 0 || config.targetWeightBps > MAX_BPS) {
                revert InvalidWeightBps(config.token);
            }

            if (config.toleranceBps >= config.targetWeightBps) {
                revert InvalidToleranceBps(config.token);
            }

            if (config.maxPriceStaleness == 0) {
                revert InvalidMaxPriceStaleness(config.token);
            }

            totalWeightBps += config.targetWeightBps;

            _tokenSet.add(config.token);
            _assets[config.token] = Asset({
                dataFeed: config.dataFeed,
                targetWeightBps: config.targetWeightBps,
                toleranceBps: config.toleranceBps,
                maxPriceStaleness: config.maxPriceStaleness
            });

            if (IERC20(config.token).balanceOf(address(this)) != config.amount) {
                revert InvalidAssetAmount(config.token, config.amount);
            }
        }

        if (totalWeightBps != MAX_BPS) {
            revert InvalidTotalWeightBps();
        }
    }

    function _toAssets(uint256 shares, Math.Rounding rounding) private view returns (AssetBalance[] memory assetBalances) {
        uint256 numberOfAssets = _tokenSet.length();
        assetBalances = new AssetBalance[](numberOfAssets);

        for (uint256 i = 0; i < numberOfAssets; i++) {
            address token = _tokenSet.at(i);

            assetBalances[i] = AssetBalance({
                token: token,
                amount: Math.mulDiv(shares, IERC20(token).balanceOf(address(this)), totalSupply(), rounding)
            });
        }
    }

    function previewBoundsCheck(address token0, uint256 newBalance0, address token1, uint256 newBalance1)
        external
        view
        returns (bool)
    {
        return _previewBoundsCheck(token0, newBalance0, token1, newBalance1);
    }

    function _previewBoundsCheck(address token0, uint256 newBalance0, address token1, uint256 newBalance1)
        private
        view
        returns (bool)
    {
        if (token0 == token1) {
            revert SameAssets();
        }

        if (!_tokenSet.contains(token0)) {
            revert InvalidAsset(token0);
        }

        if (!_tokenSet.contains(token1)) {
            revert InvalidAsset(token1);
        }

        uint256 numberOfTokens = _tokenSet.length();
        uint256[] memory values = new uint256[](numberOfTokens);
        uint256 total;

        for (uint256 i = 0; i < numberOfTokens; i++) {
            address token = _tokenSet.at(i);

            uint256 balance;
            if (token == token0) {
                balance = newBalance0;
            } else if (token == token1) {
                balance = newBalance1;
            } else {
                balance = IERC20(token).balanceOf(address(this));
            }

            uint256 value = _snapshotUsdValue(token, balance);

            values[i] = value;
            total += value;
        }

        if (total == 0) {
            return false;
        }

        for (uint256 i = 0; i < numberOfTokens; i++) {
            Asset memory asset = _assets[_tokenSet.at(i)];

            uint256 actualBps = Math.mulDiv(values[i], MAX_BPS, total);
            uint16 targetBps = asset.targetWeightBps;

            uint256 diff = actualBps > targetBps
                ? actualBps - targetBps
                : targetBps - actualBps;

            if (diff > asset.toleranceBps) {
                return false;
            }
        }

        return true;
    }

    function _snapshotUsdValue(address token, uint256 balance) private view returns (uint256 value) {
        uint256 priceInUsd = _readPriceInUsd(token);

        uint256 tokenUnit = 10 ** IERC20Metadata(token).decimals();
        value = Math.mulDiv(balance, priceInUsd, tokenUnit);
    }

    function _readPriceInUsd(address token) private view returns (uint256) {
        Asset memory asset = _assets[token];

        uint8 feedDecimals = AggregatorV3Interface(asset.dataFeed).decimals();
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(asset.dataFeed).latestRoundData();

        if (answer <= 0) {
            revert InvalidPrice(token);
        }

        if (block.timestamp - updatedAt > asset.maxPriceStaleness) {
            revert StalePrice(token);
        }

        uint256 price = uint256(answer);

        if (feedDecimals < 18) {
            return price * (10 ** (18 - feedDecimals));
        } else if (feedDecimals > 18) {
            return price / (10 ** (feedDecimals - 18));
        }

        return price;
    }
}
