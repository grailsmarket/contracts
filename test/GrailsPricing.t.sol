// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GrailsPricing, AggregatorInterface} from "../src/GrailsPricing.sol";
import {DummyOracle} from "./mocks/DummyOracle.sol";

contract GrailsPricingTest is Test {
    GrailsPricing public gp;
    DummyOracle public oracle;

    address owner;
    address user = address(0xBEEF);

    // ETH/USD = $2000 (Chainlink returns 8-decimal price)
    int256 constant ORACLE_PRICE = 2000_00000000;

    // Tier 1: ~$10/month → $10 / (30 * 86400) * 1e18 ≈ 3_858_024_691_358 attoUSD/sec
    uint256 constant TIER1_RATE = 3_858_024_691_358;

    // Tier 2: ~$30/month
    uint256 constant TIER2_RATE = 11_574_074_074_074;

    function setUp() public {
        owner = address(this);
        oracle = new DummyOracle(ORACLE_PRICE);
        gp = new GrailsPricing(AggregatorInterface(address(oracle)), owner);
        gp.setTierPrice(1, TIER1_RATE);
        gp.setTierPrice(2, TIER2_RATE);
    }

    // -----------------------------------------------------------------------
    // setTierPrice
    // -----------------------------------------------------------------------

    function test_setTierPrice_setsPrice() public view {
        assertEq(gp.tierPrices(1), TIER1_RATE);
        assertEq(gp.tierPrices(2), TIER2_RATE);
    }

    function test_setTierPrice_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit GrailsPricing.TierPriceUpdated(3, 0, 1000);
        gp.setTierPrice(3, 1000);
    }

    function test_setTierPrice_updateExisting() public {
        uint256 newRate = 5_000_000_000_000;
        vm.expectEmit(true, false, false, true);
        emit GrailsPricing.TierPriceUpdated(1, TIER1_RATE, newRate);
        gp.setTierPrice(1, newRate);
        assertEq(gp.tierPrices(1), newRate);
    }

    function test_setTierPrice_removeTier() public {
        gp.setTierPrice(1, 0);
        assertEq(gp.tierPrices(1), 0);
    }

    function test_setTierPrice_revertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        gp.setTierPrice(1, 1000);
    }

    // -----------------------------------------------------------------------
    // price
    // -----------------------------------------------------------------------

    function test_price_basicConversion() public view {
        // 30 days at tier 1: TIER1_RATE * 30 * 86400 attoUSD, converted to wei
        uint256 durationSec = 30 days;
        uint256 attoUSDTotal = TIER1_RATE * durationSec;
        uint256 expectedWei = (attoUSDTotal * 1e8) / uint256(ORACLE_PRICE);

        uint256 weiPrice = gp.price(1, durationSec);
        assertEq(weiPrice, expectedWei);
    }

    function test_price_tier2() public view {
        uint256 durationSec = 30 days;
        uint256 attoUSDTotal = TIER2_RATE * durationSec;
        uint256 expectedWei = (attoUSDTotal * 1e8) / uint256(ORACLE_PRICE);

        assertEq(gp.price(2, durationSec), expectedWei);
    }

    function test_price_revertsOnUnconfiguredTier() public {
        vm.expectRevert(GrailsPricing.TierNotConfigured.selector);
        gp.price(99, 30 days);
    }

    function test_price_changesWithOracle() public {
        uint256 durationSec = 30 days;
        uint256 priceBefore = gp.price(1, durationSec);

        // Double ETH price → half the wei cost
        oracle.set(ORACLE_PRICE * 2);
        uint256 priceAfter = gp.price(1, durationSec);

        assertEq(priceAfter, priceBefore / 2);
    }

    // -----------------------------------------------------------------------
    // weiToAttoUSD
    // -----------------------------------------------------------------------

    function test_weiToAttoUSD_roundTrip() public view {
        uint256 durationSec = 30 days;
        uint256 weiPrice = gp.price(1, durationSec);
        uint256 attoUSD = gp.weiToAttoUSD(weiPrice);

        // Should approximately equal TIER1_RATE * durationSec (within rounding)
        uint256 expected = TIER1_RATE * durationSec;
        // Allow 1 attoUSD rounding error per wei
        assertApproxEqAbs(attoUSD, expected, uint256(ORACLE_PRICE) / 1e8);
    }
}
