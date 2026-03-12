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

    event Subscribed(address indexed subscriber, uint256 indexed tierId, uint256 expiry, uint256 amount);
    event PricingUpdated(address oldPricing, address newPricing);
    event Withdrawn(address indexed to, uint256 amount);

    error MinimumOneDayRequired();
    error InsufficientPayment();
    error NoBalance();
    error WithdrawFailed();
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
