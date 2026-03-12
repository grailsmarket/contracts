// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReverseClaimer} from "ens-contracts/reverseRegistrar/ReverseClaimer.sol";
import {ENS} from "ens-contracts/registry/ENS.sol";
import {IGrailsPricing} from "./IGrailsPricing.sol";

/**
 * @custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVM MEVM
 * @title GrailsSubscription
 * @author 0xthrpw
 * @notice Subscription contract for Grails with USD-priced tiers.
 *         Users send ETH to subscribe for a given number of days at a chosen tier.
 *         Pricing is delegated to an IGrailsPricing implementation (oracle-based).
 *         No auto-renewal; call subscribe() again to extend.
 */
contract GrailsSubscription is Ownable2Step, ReverseClaimer {
    IGrailsPricing public pricing;

    struct Subscription {
        uint256 expiry;
        uint256 tierId;
    }

    mapping(address => Subscription) public subscriptions;

    /**
     * @notice Emitted when a user subscribes or re-subscribes
     * @param subscriber The address that subscribed
     * @param tierId The subscription tier selected
     * @param expiry The new expiry timestamp
     * @param amount The ETH amount paid
     */
    event Subscribed(address indexed subscriber, uint256 indexed tierId, uint256 expiry, uint256 amount);

    /**
     * @notice Emitted when the pricing contract is swapped
     * @param oldPricing The previous pricing contract address
     * @param newPricing The new pricing contract address
     */
    event PricingUpdated(address oldPricing, address newPricing);

    /**
     * @notice Emitted when the owner withdraws collected funds
     * @param to The address that received the funds
     * @param amount The amount withdrawn in wei
     */
    event Withdrawn(address indexed to, uint256 amount);

    /**
     * @notice Thrown when subscribing for zero days
     */
    error MinimumOneDayRequired();

    /**
     * @notice Thrown when msg.value is less than the required payment
     */
    error InsufficientPayment();

    /**
     * @notice Thrown when withdrawing with zero contract balance
     */
    error NoBalance();

    /**
     * @notice Thrown when the ETH transfer to the owner fails
     */
    error WithdrawFailed();

    /**
     * @notice Thrown when the excess ETH refund to the subscriber fails
     */
    error RefundFailed();

    constructor(IGrailsPricing _pricing, ENS _ens, address _owner) Ownable(_owner) ReverseClaimer(_ens, _owner) {
        pricing = _pricing;
    }

    /**
     * @notice Subscribe or re-subscribe for `durationDays` days at `tierId`.
     *         Always starts from block.timestamp (replaces any existing subscription).
     *         Excess ETH is refunded automatically.
     */
    function subscribe(uint256 tierId, uint256 durationDays) external payable {
        if (durationDays < 1) revert MinimumOneDayRequired();

        uint256 requiredWei = pricing.price(tierId, durationDays * 1 days);
        if (msg.value < requiredWei) revert InsufficientPayment();

        uint256 newExpiry = block.timestamp + (durationDays * 1 days);
        subscriptions[msg.sender] = Subscription(newExpiry, tierId);

        emit Subscribed(msg.sender, tierId, newExpiry, msg.value);

        uint256 excess = msg.value - requiredWei;
        if (excess > 0) {
            (bool sent,) = msg.sender.call{value: excess}("");
            if (!sent) revert RefundFailed();
        }
    }

    /**
     * @notice Check subscription expiry for an address.
     * @return expiry The unix timestamp when the subscription expires (0 if never subscribed).
     */
    function getSubscription(address subscriber) external view returns (uint256 expiry) {
        return subscriptions[subscriber].expiry;
    }

    /**
     * @notice Convenience view for frontends — returns wei cost for a tier and duration.
     */
    function getPrice(uint256 tierId, uint256 durationDays) external view returns (uint256) {
        return pricing.price(tierId, durationDays * 1 days);
    }

    /**
     * @notice Owner-only: withdraw collected funds.
     */
    function withdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NoBalance();
        (bool sent,) = owner().call{value: balance}("");
        if (!sent) revert WithdrawFailed();
        emit Withdrawn(owner(), balance);
    }

    /**
     * @notice Owner-only: swap the pricing contract.
     */
    function setPricing(IGrailsPricing _pricing) external onlyOwner {
        address oldPricing = address(pricing);
        pricing = _pricing;
        emit PricingUpdated(oldPricing, address(_pricing));
    }
}
