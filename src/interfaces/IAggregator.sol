// SPDX-License-Identifier: MIT

pragma solidity 0.8.34;

/**
 * @title IAggregator
 * @notice Minimal interface for a Chainlink-compatible price feed aggregator.
 */
interface IAggregator {

    /**
     * @notice Returns the latest price round data from the aggregator.
     * @return roundId The ID of the latest round.
     * @return answer The latest price (8 decimals for ETH/USD).
     * @return startedAt Timestamp when the round started.
     * @return updatedAt Timestamp when the round was last updated.
     * @return answeredInRound The round in which the answer was computed.
     */
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

}
