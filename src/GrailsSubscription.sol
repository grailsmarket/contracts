// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReverseClaimer} from "ens-contracts/reverseRegistrar/ReverseClaimer.sol";
import {ENS} from "ens-contracts/registry/ENS.sol";

/**
 * @custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVM MEVM
 * @title GrailsSubscription
 * @author 0xthrpw
 * @notice Minimal subscription contract for Grails PRO tier.
 *         Users send ETH to subscribe for a given number of days.
 *         No auto-renewal; call subscribe() again to extend.
 */
contract GrailsSubscription is Ownable2Step, ReverseClaimer {
    /**
     * @notice Wei charged per day of subscription
     */
    uint256 public pricePerDay;

    struct Subscription {
        uint256 expiry;
    }

    mapping(address => Subscription) public subscriptions;

    /**
     * @notice Emitted when a user subscribes or extends their subscription
     * @param subscriber The address that subscribed
     * @param expiry The new expiry timestamp
     * @param amount The ETH amount paid
     */
    event Subscribed(address indexed subscriber, uint256 expiry, uint256 amount);

    /**
     * @notice Emitted when the price per day is updated
     * @param oldPrice The previous price per day in wei
     * @param newPrice The new price per day in wei
     */
    event PriceUpdated(uint256 oldPrice, uint256 newPrice);

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
     * @param _pricePerDay The initial price per day in wei
     * @param _ens Address of the ENS registry (for reverse resolution)
     * @param _owner Address to set as contract owner and reverse ENS claimant
     */
    constructor(uint256 _pricePerDay, ENS _ens, address _owner) Ownable(_owner) ReverseClaimer(_ens, _owner) {
        pricePerDay = _pricePerDay;
    }

    /**
     * @notice Subscribe or extend subscription for `durationDays` days.
     * @param durationDays Number of days to subscribe for (minimum 1).
     */
    function subscribe(uint256 durationDays) external payable {
        if (durationDays < 1) revert MinimumOneDayRequired();
        if (msg.value < pricePerDay * durationDays) revert InsufficientPayment();

        uint256 currentExpiry = subscriptions[msg.sender].expiry;
        uint256 startFrom = block.timestamp > currentExpiry ? block.timestamp : currentExpiry;
        uint256 newExpiry = startFrom + (durationDays * 1 days);

        subscriptions[msg.sender].expiry = newExpiry;

        emit Subscribed(msg.sender, newExpiry, msg.value);
    }

    /**
     * @notice Check subscription expiry for an address.
     * @param subscriber The address to query.
     * @return expiry The unix timestamp when the subscription expires (0 if never subscribed).
     */
    function getSubscription(address subscriber) external view returns (uint256 expiry) {
        return subscriptions[subscriber].expiry;
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
     * @notice Owner-only: update the price per day.
     * @param _pricePerDay The new price per day in wei.
     */
    function setPrice(uint256 _pricePerDay) external onlyOwner {
        uint256 oldPrice = pricePerDay;
        pricePerDay = _pricePerDay;
        emit PriceUpdated(oldPrice, _pricePerDay);
    }
}
