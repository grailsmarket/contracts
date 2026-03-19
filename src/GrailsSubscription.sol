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
     * @notice Emitted when a user upgrades their subscription tier
     * @param subscriber The address that upgraded
     * @param oldTierId The previous tier
     * @param newTierId The new (higher) tier
     * @param expiry The new expiry timestamp after conversion
     * @param amount The ETH amount paid for additional days (0 if pure conversion)
     */
    event Upgraded(address indexed subscriber, uint256 indexed oldTierId, uint256 indexed newTierId, uint256 expiry, uint256 amount);

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

    /**
     * @notice Thrown when upgrading with no active (non-expired) subscription
     */
    error NoActiveSubscription();

    /**
     * @notice Thrown when the target tier rate is not strictly higher than the current tier rate
     */
    error NotAnUpgrade();

    /**
     * @notice Thrown when the target tier is not configured (rate == 0)
     */
    error TierNotConfigured();

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
     * @notice Upgrade an active subscription to a higher tier.
     *         Remaining time is proportionally converted based on attoUSD/sec rates.
     *         Optionally pay ETH for additional days on the new tier.
     * @param newTierId The tier to upgrade to (must have a strictly higher rate).
     * @param extraDays Additional days to purchase on the new tier (can be 0).
     */
    function upgrade(uint256 newTierId, uint256 extraDays) external payable {
        Subscription storage sub = subscriptions[msg.sender];

        if (sub.expiry <= block.timestamp) revert NoActiveSubscription();

        uint256 currentRate = pricing.tierPrices(sub.tierId);
        uint256 newRate = pricing.tierPrices(newTierId);

        if (newRate == 0) revert TierNotConfigured();
        if (newRate <= currentRate) revert NotAnUpgrade();

        uint256 remainingSeconds = sub.expiry - block.timestamp;
        uint256 convertedSeconds = (remainingSeconds * currentRate) / newRate;

        uint256 extraSeconds = extraDays * 1 days;
        if (extraDays > 0) {
            uint256 requiredWei = pricing.price(newTierId, extraSeconds);
            if (msg.value < requiredWei) revert InsufficientPayment();

            uint256 excess = msg.value - requiredWei;
            if (excess > 0) {
                (bool sent,) = msg.sender.call{value: excess}("");
                if (!sent) revert RefundFailed();
            }
        } else if (msg.value > 0) {
            (bool sent,) = msg.sender.call{value: msg.value}("");
            if (!sent) revert RefundFailed();
        }

        uint256 oldTierId = sub.tierId;
        uint256 newExpiry = block.timestamp + convertedSeconds + extraSeconds;
        sub.expiry = newExpiry;
        sub.tierId = newTierId;

        emit Upgraded(msg.sender, oldTierId, newTierId, newExpiry, msg.value);
    }

    /**
     * @notice Preview what expiry a user would get if they upgraded to a new tier (no extra days).
     * @param subscriber The address to check.
     * @param newTierId The target tier.
     * @return newExpiry The projected new expiry timestamp (0 if not upgradeable).
     * @return convertedSeconds The number of seconds that would remain on the new tier.
     */
    function previewUpgrade(address subscriber, uint256 newTierId) external view returns (uint256 newExpiry, uint256 convertedSeconds) {
        Subscription memory sub = subscriptions[subscriber];
        if (sub.expiry <= block.timestamp) return (0, 0);

        uint256 currentRate = pricing.tierPrices(sub.tierId);
        uint256 newRate = pricing.tierPrices(newTierId);
        if (newRate == 0 || newRate <= currentRate) return (0, 0);

        uint256 remainingSeconds = sub.expiry - block.timestamp;
        convertedSeconds = (remainingSeconds * currentRate) / newRate;
        newExpiry = block.timestamp + convertedSeconds;
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
     * @param _pricing The new pricing contract address
     */
    function setPricing(IGrailsPricing _pricing) external onlyOwner {
        address oldPricing = address(pricing);
        pricing = _pricing;
        emit PricingUpdated(oldPricing, address(_pricing));
    }
}
