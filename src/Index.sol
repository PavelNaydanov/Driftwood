// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IIndex, AssetConfig, Asset, AssetBalance, AssetWeight, JitDebt} from "./interfaces/IIndex.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {ZeroAddress, ZeroAmount} from "./utils/CommonErrors.sol";

contract Index is IIndex, ERC20Upgradeable, AccessControlUpgradeable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint16 public constant MAX_BPS = 10_000;
    bytes32 public constant HOOK_ROLE = keccak256("HOOK_ROLE");

    EnumerableSet.AddressSet private _tokenSet;
    mapping(address token => Asset asset) private _assets;

    JitDebt private _jitDebt;

    modifier whenJitActive() {
        _checkJitActive();
        _;
    }

    modifier whenJitInactive() {
        _checkJitInactive();
        _;
    }

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

    function mint(uint256 shares, address receiver) external whenJitInactive {
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

    function redeem(uint256 shares, address receiver, uint256[] calldata minAmountsOut) external whenJitInactive {
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

    function lendAssets(address token0, uint256 amount0, address token1, uint256 amount1) external onlyRole(HOOK_ROLE) whenJitInactive {
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

    function collectAssets(address token0, address token1) external onlyRole(HOOK_ROLE) whenJitActive {
        JitDebt memory jitDebt = _jitDebt;

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

    function setOracleConfig(address token, address dataFeed, uint32 maxPriceStaleness) external onlyRole(DEFAULT_ADMIN_ROLE) whenJitInactive {
        if (!_tokenSet.contains(token)) {
            revert InvalidAsset(token);
        }

        _checkOracleConfig(token, dataFeed, maxPriceStaleness);
        _setOracleConfig(token, dataFeed, maxPriceStaleness);
    }

    function _setOracleConfig(address token, address dataFeed, uint32 maxPriceStaleness) private {
        _assets[token].dataFeed = dataFeed;
        _assets[token].feedDecimals = AggregatorV3Interface(dataFeed).decimals();
        _assets[token].maxPriceStaleness = maxPriceStaleness;

        emit OracleConfigSet(token, dataFeed, maxPriceStaleness);
    }

    function _checkOracleConfig(address token, address dataFeed, uint32 maxPriceStaleness) private pure {
        if (dataFeed == address(0)) {
            revert ZeroAddress();
        }

        if (maxPriceStaleness == 0) {
            revert InvalidMaxPriceStaleness(token);
        }
    }

    /// @dev Caller responsible for no duplicates; if violated, sum invariant can drift
    function setAssetWeights(AssetWeight[] calldata assetWeights) external onlyRole(DEFAULT_ADMIN_ROLE) whenJitInactive {
        if (assetWeights.length != _tokenSet.length()) {
            revert IncompleteTokenSet();
        }

        uint256 totalWeightBps;
        for (uint256 i = 0; i < assetWeights.length; i++) {
            AssetWeight memory assetWeight = assetWeights[i];

            if (!_tokenSet.contains(assetWeight.token)) {
                revert InvalidAsset(assetWeight.token);
            }

            _checkAssetWeight(assetWeight.token, assetWeight.targetWeightBps, assetWeight.toleranceBps);
            _setAssetWeight(assetWeight.token, assetWeight.targetWeightBps, assetWeight.toleranceBps);

            totalWeightBps += assetWeight.targetWeightBps;
        }

        if (totalWeightBps != MAX_BPS) {
            revert InvalidTotalWeightBps();
        }
    }

    function _setAssetWeight(address token, uint16 targetWeightBps, uint16 toleranceBps) private {
        _assets[token].targetWeightBps = targetWeightBps;
        _assets[token].toleranceBps = toleranceBps;

        emit AssetWeightSet(token, targetWeightBps, toleranceBps);
    }

    function _checkAssetWeight(address token, uint16 targetWeightBps, uint16 toleranceBps) private pure {
        if (targetWeightBps == 0 || targetWeightBps > MAX_BPS) {
            revert InvalidWeightBps(token);
        }

        if (toleranceBps >= targetWeightBps) {
            revert InvalidToleranceBps(token);
        }
    }

    function _checkJitActive() private view {
        if (_jitDebt.hook == address(0)) {
            revert JitIsNotActive();
        }
    }

    function _checkJitInactive() private view {
        if (_jitDebt.hook != address(0)) {
            revert JitIsActive();
        }
    }

    function _initAssets(AssetConfig[] memory assetConfigs) private {
        uint256 numberOfAssets = assetConfigs.length;
        if (numberOfAssets < 2) {
            revert InvalidNumberOfAssets();
        }

        uint256 totalWeightBps;
        for (uint256 i = 0; i < numberOfAssets; i++) {
            AssetConfig memory config = assetConfigs[i];

            if (config.token == address(0)) {
                revert ZeroAddress();
            }

            if (config.amount == 0) {
                revert ZeroAmount();
            }

            _checkOracleConfig(config.token, config.dataFeed, config.maxPriceStaleness);
            _checkAssetWeight(config.token, config.targetWeightBps, config.toleranceBps);

            totalWeightBps += config.targetWeightBps;

            _tokenSet.add(config.token);
            _assets[config.token] = Asset({
                dataFeed: config.dataFeed,
                feedDecimals: AggregatorV3Interface(config.dataFeed).decimals(),
                tokenDecimals: IERC20Metadata(config.token).decimals(),
                maxPriceStaleness: config.maxPriceStaleness,
                targetWeightBps: config.targetWeightBps,
                toleranceBps: config.toleranceBps
            });

            if (IERC20(config.token).balanceOf(address(this)) != config.amount) {
                revert InvalidAssetAmount(config.token, config.amount);
            }

            emit OracleConfigSet(config.token, config.dataFeed, config.maxPriceStaleness);
            emit AssetWeightSet(config.token, config.targetWeightBps, config.toleranceBps);
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
        Asset memory asset = _assets[token];

        uint256 priceInUsd = _readPriceInUsd(token, asset);

        uint256 tokenUnit = 10 ** asset.tokenDecimals;
        value = Math.mulDiv(balance, priceInUsd, tokenUnit);
    }

    function _readPriceInUsd(address token, Asset memory asset) private view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(asset.dataFeed).latestRoundData();

        if (answer <= 0) {
            revert InvalidPrice(token);
        }

        if (block.timestamp - updatedAt > asset.maxPriceStaleness) {
            revert StalePrice(token);
        }

        uint256 price = SafeCast.toUint256(answer);

        if (asset.feedDecimals < 18) {
            return price * (10 ** (18 - asset.feedDecimals));
        } else if (asset.feedDecimals > 18) {
            return price / (10 ** (asset.feedDecimals - 18));
        }

        return price;
    }
}
