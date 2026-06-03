// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {IIndex, AssetConfig, Asset} from "./interfaces/IIndex.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

contract Index is IIndex, ERC20Upgradeable, AccessControlUpgradeable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 public constant HOOK_ROLE = keccak256("HOOK_ROLE");

    EnumerableSet.AddressSet private _tokenSet;
    mapping(address token => address dataFeed) private _dataFeeds;
    mapping(address token => uint256 amount) private _balanceBeforeLend;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string calldata name,
        string calldata symbol,
        AssetConfig[] calldata assets,
        address defaultAdmin
    )
        external
        initializer
    {
        __ERC20_init(name, symbol);
        __AccessControl_init();

        _initAssets(assets);
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
    }

    function mint(uint256 shares, address receiver) external {
        if (shares == 0) {
            revert ZeroAmount();
        }

        if (receiver == address(0) || receiver == address(this)) {
            revert InvalidReceiver();
        }

        Asset[] memory assets = _toAssets(shares, Math.Rounding.Ceil);
        for (uint256 i = 0; i < assets.length; i++) {
            Asset memory asset = assets[i];

            if (asset.amount != 0) {
                SafeERC20.safeTransferFrom(IERC20(asset.token), msg.sender, address(this), asset.amount);
            }
        }

        _mint(receiver, shares);
    }

    function redeem(
        uint256 shares,
        address receiver,
        uint256[] calldata minAmountsOut
    ) external {
        if (shares == 0) {
            revert ZeroAmount();
        }

        if (receiver == address(0) || receiver == address(this)) {
            revert InvalidReceiver();
        }

        Asset[] memory assets = _toAssets(shares, Math.Rounding.Floor);

        uint256 numberOfAssets = assets.length;
        if (numberOfAssets != minAmountsOut.length) {
            revert InvalidNumberOfMinAmountsOut();
        }

        _burn(msg.sender, shares);

        for (uint256 i = 0; i < numberOfAssets; i++) {
            Asset memory asset = assets[i];
            if (asset.amount < minAmountsOut[i]) {
                revert InsufficientAmountOut(asset.token, asset.amount, minAmountsOut[i]);
            }

            if (asset.amount != 0) {
                SafeERC20.safeTransfer(IERC20(asset.token), receiver, asset.amount);
            }
        }
    }

    function lendAsset(address token, uint256 amount) external onlyRole(HOOK_ROLE) {
        if (amount == 0) {
            revert ZeroAmount();
        }

        if (token == address(0)) {
            revert ZeroAddress();
        }

        if (!_tokenSet.contains(token)) {
            revert InvalidAsset(token);
        }

        if (IERC20(token).balanceOf(address(this)) < amount) {
            revert InsufficientAssetBalance(token, amount);
        }

        if (_balanceBeforeLend[token] > 0) {
            revert OutstandingDebt(msg.sender, token, _balanceBeforeLend[token]);
        }

        _balanceBeforeLend[token] = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(msg.sender, amount);

        emit AssetLent(msg.sender, token, amount);
    }

    function collectAsset(address token) external onlyRole(HOOK_ROLE) {
        uint256 balanceBeforeLend = _balanceBeforeLend[token];
        if (IERC20(token).balanceOf(address(this)) < balanceBeforeLend) {
            revert InsufficientCollectAmount(token, balanceBeforeLend);
        }

        uint256 collectedAmount = IERC20(token).balanceOf(address(this)) - balanceBeforeLend;
        delete _balanceBeforeLend[token];

        emit AssetCollected(msg.sender, token, collectedAmount);
    }

    function getTokens() external view returns (address[] memory) {
        return _tokenSet.values();
    }

    function getDataFeed(address token) external view returns (address) {
        return _dataFeeds[token];
    }

    function _initAssets(AssetConfig[] memory assets) private {
        uint256 numberOfAssets = assets.length;
        if (numberOfAssets < 2) {
            revert InvalidNumberOfAssets();
        }

        for (uint256 i = 0; i < numberOfAssets; i++) {
            AssetConfig memory asset = assets[i];

            if (asset.token == address(0) || asset.dataFeed == address(0)) {
                revert ZeroAddress();
            }

            if (asset.amount == 0) {
                revert ZeroAmount();
            }

            _tokenSet.add(asset.token);
            _dataFeeds[asset.token] = asset.dataFeed;

            if (IERC20(asset.token).balanceOf(address(this)) != asset.amount) {
                revert InvalidAssetAmount(asset.token, asset.amount);
            }
        }
    }

    function _toAssets(uint256 shares, Math.Rounding rounding)
        private
        view
        returns (Asset[] memory assets)
{
        uint256 numberOfAssets = _tokenSet.values().length;
        assets = new Asset[](numberOfAssets);

        for (uint256 i = 0; i < numberOfAssets; i++) {
            address token = _tokenSet.at(i);

            assets[i] = Asset({
                token: token,
                amount: Math.mulDiv(shares, IERC20(token).balanceOf(address(this)), totalSupply(), rounding)
            });
        }
    }
}