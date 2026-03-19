// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IGrailsPricing {
    /**
     * @notice Returns the price in wei for a given tier and duration.
     * @param tierId The subscription tier identifier.
     * @param duration The subscription duration in seconds.
     * @return weiPrice The price in wei.
     */
    function price(uint256 tierId, uint256 duration) external view returns (uint256 weiPrice);

    /**
     * @notice Returns the raw attoUSD-per-second rate for a tier.
     * @param tierId The subscription tier identifier.
     * @return attoUSDPerSecond The tier's price rate (0 if not configured).
     */
    function tierPrices(uint256 tierId) external view returns (uint256 attoUSDPerSecond);
}
