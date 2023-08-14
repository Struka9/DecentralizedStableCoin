// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleLib
 * @author Oscar Flores
 * @notice This is a library to check for alongside Chainlink's AggregatorV3Interface, it checks the last updated time of the price
 * and reverts if more than 3 hours have passed since, otherwise returns the same data as the latestRoundData function in the Aggregator.
 */
library OracleLib {
    error OracleLib__TimeoutOfPrices();

    uint256 public constant TIMEOUT = 3 hours;

    function checkForStalePrices(AggregatorV3Interface _oracle)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (roundId, answer, startedAt, updatedAt, answeredInRound) = _oracle.latestRoundData();
        uint256 timeSinceUpdate = block.timestamp - updatedAt;
        if (timeSinceUpdate > TIMEOUT) {
            revert OracleLib__TimeoutOfPrices();
        }
    }
}
