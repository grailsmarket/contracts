// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IGrailsPricing} from "./IGrailsPricing.sol";

interface AggregatorInterface {
    function latestAnswer() external view returns (int256);
}

/**
 * @custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVM MEVM
 * @title GrailsPricing
 * @author 0xthrpw
 * @notice USD-based subscription pricing using a Chainlink ETH/USD oracle.
 *         Tier prices are stored as attoUSD-per-second (18-decimal USD).
 *         Follows the ENS StablePriceOracle pattern for USD→Wei conversion.
 */
contract GrailsPricing is IGrailsPricing, Ownable2Step {
    AggregatorInterface public usdOracle;

    /// @notice Tier ID → attoUSD-per-second rate
    mapping(uint256 => uint256) public tierPrices;

    error TierNotConfigured();

    event TierPriceUpdated(uint256 indexed tierId, uint256 oldPrice, uint256 newPrice);

    constructor(AggregatorInterface _oracle, address _owner) Ownable(_owner) {
        usdOracle = _oracle;
    }

    /// @inheritdoc IGrailsPricing
    function price(uint256 tierId, uint256 duration) external view returns (uint256 weiPrice) {
        uint256 rate = tierPrices[tierId];
        if (rate == 0) revert TierNotConfigured();
        return attoUSDToWei(rate * duration);
    }

    /// @notice Set or update a tier's USD rate.
    /// @param tierId The tier identifier.
    /// @param pricePerSecond The price in attoUSD per second (18-decimal USD).
    function setTierPrice(uint256 tierId, uint256 pricePerSecond) external onlyOwner {
        uint256 oldPrice = tierPrices[tierId];
        tierPrices[tierId] = pricePerSecond;
        emit TierPriceUpdated(tierId, oldPrice, pricePerSecond);
    }

    /// @notice Convert attoUSD to wei using the oracle's ETH/USD price.
    /// @dev Identical to ENS StablePriceOracle (line 83-86).
    function attoUSDToWei(uint256 amount) internal view returns (uint256) {
        uint256 ethPrice = uint256(usdOracle.latestAnswer());
        return (amount * 1e8) / ethPrice;
    }

    /// @notice Convert wei to attoUSD — view helper for frontends.
    function weiToAttoUSD(uint256 amount) external view returns (uint256) {
        uint256 ethPrice = uint256(usdOracle.latestAnswer());
        return (amount * ethPrice) / 1e8;
    }
}
