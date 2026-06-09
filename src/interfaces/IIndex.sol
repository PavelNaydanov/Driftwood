// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Initial config for a single asset in the index.
/// @param token Asset token address.
/// @param amount Amount required during initialization.
/// @param dataFeed Chainlink price feed (token / USD).
/// @param maxPriceStaleness How long a price stays valid, in seconds.
/// @param targetWeightBps Target portfolio weight in basis points (10000 = 100%).
/// @param toleranceBps Allowed deviation around the target weight.
struct AssetConfig {
    address token;
    uint256 amount;
    address dataFeed;
    uint32 maxPriceStaleness; // sec
    uint16 targetWeightBps; // 4000 = 40%
    uint16 toleranceBps; // 500 = 5pp
}

/// @notice Stored asset state.
struct Asset {
    address dataFeed;
    uint8 feedDecimals;
    uint8 tokenDecimals;
    uint32 maxPriceStaleness;
    uint16 targetWeightBps;
    uint16 toleranceBps;
}

/// @notice Token amount pair returned by share-to-asset math.
struct AssetBalance {
    address token;
    uint256 amount;
}

/// @notice Token weight data. One entry per token in the index.
struct AssetWeight {
    address token;
    uint16 targetWeightBps;
    uint16 toleranceBps;
}

/// @notice Active JIT loan tracked by the index.
struct JitDebt {
    address hook;
    address token0;
    address token1;
}

/// @title IIndex
/// @notice Index fund that issues ERC20 shares backed by a fixed set of tokens.
/// Users mint and redeem shares. A registered hook can borrow two assets
/// for the duration of a swap and must return them within bounds.
interface IIndex {
    /// @notice Emitted when the hook borrows assets for a JIT cycle.
    event AssetsLent(
        address indexed hook,
        address indexed token0,
        uint256 amount0,
        uint256 balanceBefore0,
        address indexed token1,
        uint256 amount1,
        uint256 balanceBefore1
    );
    /// @notice Emitted when the hook returns assets and the bounds check passes.
    event AssetsCollected(
        address indexed hook,
        address indexed token0,
        uint256 balanceAfter0,
        address indexed token1,
        uint256 balanceAfter1
    );
    /// @notice Emitted on every oracle config write (init and admin update).
    event OracleConfigSet(address indexed token, address dataFeed, uint32 maxPriceStaleness);
    /// @notice Emitted on every target/tolerance write (init and admin update).
    event AssetWeightSet(address indexed token, uint16 targetWeightBps, uint16 toleranceBps);

    error InvalidNumberOfAssets();
    error InvalidReceiver();
    error InvalidNumberOfMinAmountsOut();
    error InsufficientAmountOut(address token, uint256 amountOut, uint256 minAmountOut);
    error InvalidAssetAmount(address token, uint256 amount);
    error SameAssets();
    error InvalidAsset(address token);
    error InsufficientAssetBalance(address token, uint256 amount);
    error JitIsActive();
    error JitIsNotActive();
    error InvalidCollector();
    error WeightOutOfBounds(address token0, uint256 balance0, address token1, uint256 balance1);
    error InvalidWeightBps(address token);
    error InvalidTotalWeightBps();
    error InvalidToleranceBps(address token);
    error InvalidPrice(address token);
    error StalePrice(address token);
    error InvalidMaxPriceStaleness(address token);
    error IncompleteTokenSet();

    /// @notice Index initialization. Called by the factory right after the proxy is created
    /// and the assets are transferred in. Mints `initialShares` to `defaultAdmin`.
    /// @dev The caller must transfer each `assets[i].amount` to this contract before calling.
    function initialize(
        string calldata name,
        string calldata symbol,
        AssetConfig[] calldata assets,
        uint256 initialShares,
        address defaultAdmin
    ) external;

    /// @notice Mint `shares` to `receiver`.
    function mint(uint256 shares, address receiver) external;

    /// @notice Burn `shares` from `msg.sender` and send the matching set of assets to `receiver`.
    /// @param minAmountsOut Slippage guard per asset, in the order returned by `getTokens()`.
    function redeem(uint256 shares, address receiver, uint256[] calldata minAmountsOut) external;

    /// @notice Transfer `amount0` of `token0` and `amount1` of `token1` to the caller (hook).
    /// Opens a JIT loan that must be closed via `collectAssets` in the same swap.
    function lendAssets(address token0, uint256 amount0, address token1, uint256 amount1) external;

    /// @notice Close the active JIT loan. Checks current balances against weight bounds.
    /// @dev Must be called by the same hook that opened the loan, after returning the tokens.
    function collectAssets() external;

    /// @notice Update the price feed for one asset.
    function setOracleConfig(address token, address dataFeed, uint32 maxPriceStaleness) external;

    /// @notice Replace target weights and tolerances for all assets in a single call.
    /// @dev The input must cover every token; sum of target weights must equal MAX_BPS.
    function setAssetWeights(AssetWeight[] calldata assetWeights) external;

    /// @notice Tokens in the index, in insertion order.
    function getTokens() external view returns (address[] memory);

    /// @notice Stored Asset record for one token.
    function getAsset(address token) external view returns (Asset memory);

    /// @notice Current JIT loan (zero hook means no active loan).
    function getJitDebt() external view returns (JitDebt memory);

    /// @notice Pro-rata asset amounts for a given share count.
    /// @param rounding Use `Ceil` for deposit math, `Floor` for withdrawal math.
    function toAssets(uint256 shares, Math.Rounding rounding) external view returns (AssetBalance[] memory);

    /// @notice True if a candidate post-swap balance for token0/token1 keeps every asset within its tolerance.
    /// @dev Other assets are read live from the contract balance.
    function previewBoundsCheck(address token0, uint256 newBalance0, address token1, uint256 newBalance1)
        external
        view
        returns (bool);
}
