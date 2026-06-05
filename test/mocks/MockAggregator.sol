// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {AggregatorV3Interface} from "src/interfaces/AggregatorV3Interface.sol";

/// @dev Minimal Chainlink AggregatorV3 mock for tests. Allows setting price and updatedAt
contract MockAggregator is AggregatorV3Interface {
    uint8 private immutable _DECIMALS;

    uint80 private _roundId;
    int256 private _answer;
    uint256 private _startedAt;
    uint256 private _updatedAt;
    uint80 private _answeredInRound;

    constructor(uint8 initialDecimals, int256 initialAnswer) {
        _DECIMALS = initialDecimals;
        _roundId = 1;
        _answer = initialAnswer;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
        _answeredInRound = 1;
    }

    /// @dev Bumps round, sets answer, updatedAt = now
    function setAnswer(int256 answer) external {
        _roundId += 1;
        _answer = answer;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
        _answeredInRound = _roundId;
    }

    /// @dev Overrides updatedAt only
    function setUpdatedAt(uint256 updatedAt) external {
        _updatedAt = updatedAt;
    }

    /// @dev Full control: bumps round, sets both answer and updatedAt
    function setAnswerAt(int256 answer, uint256 updatedAt) external {
        _roundId += 1;
        _answer = answer;
        _startedAt = updatedAt;
        _updatedAt = updatedAt;
        _answeredInRound = _roundId;
    }

    function decimals() external view returns (uint8) {
        return _DECIMALS;
    }

    function description() external pure returns (string memory) {
        return "MockAggregator";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }
}
