// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ENS} from "ens-contracts/registry/ENS.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GrailsSubscription} from "../src/GrailsSubscription.sol";
import {GrailsPricing, AggregatorInterface} from "../src/GrailsPricing.sol";
import {IGrailsPricing} from "../src/IGrailsPricing.sol";
import {DummyOracle} from "./mocks/DummyOracle.sol";

// ---------------------------------------------------------------------------
// Fork tests — validates ReverseClaimer + oracle integration against mainnet
// ---------------------------------------------------------------------------

contract GrailsSubscriptionForkTest is Test {
    GrailsSubscription public sub;
    GrailsPricing public gp;

    address constant ENS_REGISTRY = 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e;
    address constant CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    // ~$10/month
    uint256 constant TIER1_RATE = 3_858_024_691_358;

    address owner = address(this);

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));

        gp = new GrailsPricing(AggregatorInterface(CHAINLINK_ETH_USD), owner);
        gp.setTierPrice(1, TIER1_RATE);

        sub = new GrailsSubscription(IGrailsPricing(address(gp)), ENS(ENS_REGISTRY), owner);
    }

    function test_constructor_setsOwner() public view {
        assertEq(sub.owner(), owner);
    }

    function test_constructor_setsPricing() public view {
        assertEq(address(sub.pricing()), address(gp));
    }

    function test_constructor_deploySucceeds() public view {
        assertTrue(address(sub) != address(0));
    }

    function test_getPrice_returnsSensibleValue() public view {
        // 30-day subscription at tier 1 should cost between 0.001 and 1 ETH
        // (reasonable range for ~$10/month at typical ETH prices)
        uint256 weiCost = sub.getPrice(1, 30);
        assertTrue(weiCost > 0.001 ether, "Price too low");
        assertTrue(weiCost < 1 ether, "Price too high");
    }

    receive() external payable {}
}

// ---------------------------------------------------------------------------
// Unit tests — no fork required, ENS calls are mocked
// ---------------------------------------------------------------------------

contract GrailsSubscriptionTest is Test {
    GrailsSubscription public sub;
    GrailsPricing public gp;
    DummyOracle public oracle;

    // ETH/USD = $2000
    int256 constant ORACLE_PRICE = 2000_00000000;

    // ~$10/month tier
    uint256 constant TIER1_RATE = 3_858_024_691_358;
    // ~$30/month tier
    uint256 constant TIER2_RATE = 11_574_074_074_074;

    address owner;
    address user = address(0xBEEF);

    // ENS mock addresses
    address constant ENS_REGISTRY = 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e;
    address constant REVERSE_REGISTRAR = address(0xA11CE);
    bytes32 constant ADDR_REVERSE_NODE = 0x91d1777781884d03a6757a803996e38de2a42967fb37eeaca72729271025a9e2;

    function setUp() public {
        owner = address(this);

        // Mock ENS
        vm.mockCall(ENS_REGISTRY, abi.encodeWithSignature("owner(bytes32)", ADDR_REVERSE_NODE), abi.encode(REVERSE_REGISTRAR));
        vm.mockCall(REVERSE_REGISTRAR, abi.encodeWithSignature("claim(address)", owner), abi.encode(bytes32(0)));

        // Deploy oracle + pricing
        oracle = new DummyOracle(ORACLE_PRICE);
        gp = new GrailsPricing(AggregatorInterface(address(oracle)), owner);
        gp.setTierPrice(1, TIER1_RATE);
        gp.setTierPrice(2, TIER2_RATE);

        // Deploy subscription
        sub = new GrailsSubscription(IGrailsPricing(address(gp)), ENS(ENS_REGISTRY), owner);

        vm.deal(user, 100 ether);
    }

    /// @dev Helper: get the expected wei price for a tier and duration in days
    function _expectedWei(uint256 tierId, uint256 durationDays) internal view returns (uint256) {
        return gp.price(tierId, durationDays * 1 days);
    }

    // -----------------------------------------------------------------------
    // subscribe
    // -----------------------------------------------------------------------

    function test_subscribe_singleDay() public {
        uint256 cost = _expectedWei(1, 1);
        vm.prank(user);
        sub.subscribe{value: cost}(1, 1);

        uint256 expiry = sub.getSubscription(user);
        assertEq(expiry, block.timestamp + 1 days);
    }

    function test_subscribe_multipleDays() public {
        uint256 cost = _expectedWei(1, 30);
        vm.prank(user);
        sub.subscribe{value: cost}(1, 30);

        uint256 expiry = sub.getSubscription(user);
        assertEq(expiry, block.timestamp + 30 days);
    }

    function test_subscribe_replacesExistingFromNow() public {
        uint256 cost1 = _expectedWei(1, 10);
        vm.prank(user);
        sub.subscribe{value: cost1}(1, 10);

        // Warp to midway — subscription still active
        vm.warp(block.timestamp + 5 days);
        uint256 nowTs = block.timestamp;

        uint256 cost2 = _expectedWei(1, 5);
        vm.prank(user);
        sub.subscribe{value: cost2}(1, 5);

        // Should start from now, not extend from old expiry
        assertEq(sub.getSubscription(user), nowTs + 5 days);
    }

    function test_subscribe_replacesExpiredFromNow() public {
        uint256 cost = _expectedWei(1, 1);
        vm.prank(user);
        sub.subscribe{value: cost}(1, 1);

        vm.warp(block.timestamp + 10 days);
        uint256 nowTs = block.timestamp;

        uint256 cost2 = _expectedWei(1, 3);
        vm.prank(user);
        sub.subscribe{value: cost2}(1, 3);

        assertEq(sub.getSubscription(user), nowTs + 3 days);
    }

    function test_subscribe_emitsEvent() public {
        uint256 cost = _expectedWei(1, 1);
        vm.prank(user);
        vm.expectEmit(true, true, false, true);
        emit GrailsSubscription.Subscribed(user, 1, block.timestamp + 1 days, cost);
        sub.subscribe{value: cost}(1, 1);
    }

    function test_subscribe_revertsOnZeroDays() public {
        vm.prank(user);
        vm.expectRevert(GrailsSubscription.MinimumOneDayRequired.selector);
        sub.subscribe{value: 1 ether}(1, 0);
    }

    function test_subscribe_revertsOnInsufficientPayment() public {
        uint256 cost = _expectedWei(1, 1);
        vm.prank(user);
        vm.expectRevert(GrailsSubscription.InsufficientPayment.selector);
        sub.subscribe{value: cost - 1}(1, 1);
    }

    function test_subscribe_refundsExcess() public {
        uint256 cost = _expectedWei(1, 1);
        uint256 overpay = cost * 10;
        uint256 balBefore = user.balance;

        vm.prank(user);
        sub.subscribe{value: overpay}(1, 1);

        // User should get refunded: overpay - cost
        assertEq(user.balance, balBefore - cost);
        // Contract should only hold the exact cost
        assertEq(address(sub).balance, cost);
    }

    function test_subscribe_revertsOnUnconfiguredTier() public {
        vm.prank(user);
        vm.expectRevert(GrailsPricing.TierNotConfigured.selector);
        sub.subscribe{value: 1 ether}(99, 1);
    }

    // -----------------------------------------------------------------------
    // Tier switching
    // -----------------------------------------------------------------------

    function test_subscribe_switchTier() public {
        uint256 cost1 = _expectedWei(1, 30);
        vm.prank(user);
        sub.subscribe{value: cost1}(1, 30);

        (, uint256 tier1) = sub.subscriptions(user);
        assertEq(tier1, 1);

        vm.warp(block.timestamp + 5 days);
        uint256 nowTs = block.timestamp;

        uint256 cost2 = _expectedWei(2, 30);
        vm.prank(user);
        sub.subscribe{value: cost2}(2, 30);

        (uint256 expiry, uint256 tier2) = sub.subscriptions(user);
        assertEq(tier2, 2);
        assertEq(expiry, nowTs + 30 days);
    }

    function test_subscribe_differentTiersDifferentPrices() public {
        uint256 cost1 = _expectedWei(1, 30);
        uint256 cost2 = _expectedWei(2, 30);

        // Tier 2 is ~3x tier 1
        assertTrue(cost2 > cost1 * 2);
        assertTrue(cost2 < cost1 * 4);
    }

    // -----------------------------------------------------------------------
    // getPrice
    // -----------------------------------------------------------------------

    function test_getPrice_matchesPricingContract() public view {
        uint256 fromSub = sub.getPrice(1, 30);
        uint256 fromPricing = gp.price(1, 30 days);
        assertEq(fromSub, fromPricing);
    }

    // -----------------------------------------------------------------------
    // getSubscription
    // -----------------------------------------------------------------------

    function test_getSubscription_returnsZeroForNonSubscriber() public view {
        assertEq(sub.getSubscription(address(0xDEAD)), 0);
    }

    function test_getSubscription_returnsExpiryAfterSubscribe() public {
        uint256 cost = _expectedWei(1, 7);
        vm.prank(user);
        sub.subscribe{value: cost}(1, 7);
        assertEq(sub.getSubscription(user), block.timestamp + 7 days);
    }

    // -----------------------------------------------------------------------
    // withdraw
    // -----------------------------------------------------------------------

    function test_withdraw_sendsBalanceToOwner() public {
        uint256 cost = _expectedWei(1, 1);
        vm.prank(user);
        sub.subscribe{value: cost}(1, 1);

        uint256 contractBal = address(sub).balance;
        uint256 ownerBefore = owner.balance;
        sub.withdraw();
        assertEq(owner.balance, ownerBefore + contractBal);
        assertEq(address(sub).balance, 0);
    }

    function test_withdraw_emitsEvent() public {
        uint256 cost = _expectedWei(1, 1);
        vm.prank(user);
        sub.subscribe{value: cost}(1, 1);

        uint256 contractBal = address(sub).balance;
        vm.expectEmit(true, false, false, true);
        emit GrailsSubscription.Withdrawn(owner, contractBal);
        sub.withdraw();
    }

    function test_withdraw_revertsOnNoBalance() public {
        if (address(sub).balance > 0) {
            sub.withdraw();
        }
        vm.expectRevert(GrailsSubscription.NoBalance.selector);
        sub.withdraw();
    }

    function test_withdraw_revertsForNonOwner() public {
        uint256 cost = _expectedWei(1, 1);
        vm.prank(user);
        sub.subscribe{value: cost}(1, 1);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        sub.withdraw();
    }

    function test_withdraw_revertsOnFailedTransfer() public {
        NoReceiveOwner noReceive = new NoReceiveOwner();
        vm.mockCall(ENS_REGISTRY, abi.encodeWithSignature("owner(bytes32)", ADDR_REVERSE_NODE), abi.encode(REVERSE_REGISTRAR));
        vm.mockCall(REVERSE_REGISTRAR, abi.encodeWithSignature("claim(address)", address(noReceive)), abi.encode(bytes32(0)));

        GrailsSubscription sub2 = new GrailsSubscription(IGrailsPricing(address(gp)), ENS(ENS_REGISTRY), address(noReceive));

        uint256 cost = _expectedWei(1, 1);
        vm.prank(user);
        sub2.subscribe{value: cost}(1, 1);

        vm.prank(address(noReceive));
        vm.expectRevert(GrailsSubscription.WithdrawFailed.selector);
        sub2.withdraw();
    }

    // -----------------------------------------------------------------------
    // setPricing
    // -----------------------------------------------------------------------

    function test_setPricing_swapsPricingContract() public {
        DummyOracle oracle2 = new DummyOracle(3000_00000000);
        GrailsPricing gp2 = new GrailsPricing(AggregatorInterface(address(oracle2)), owner);
        gp2.setTierPrice(1, TIER1_RATE);

        vm.expectEmit(false, false, false, true);
        emit GrailsSubscription.PricingUpdated(address(gp), address(gp2));
        sub.setPricing(IGrailsPricing(address(gp2)));

        assertEq(address(sub.pricing()), address(gp2));
    }

    function test_setPricing_revertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        sub.setPricing(IGrailsPricing(address(0x1)));
    }

    // -----------------------------------------------------------------------
    // Ownership (Ownable2Step)
    // -----------------------------------------------------------------------

    function test_transferOwnership_setsPending() public {
        address newOwner = address(0xCAFE);
        sub.transferOwnership(newOwner);
        assertEq(sub.pendingOwner(), newOwner);
    }

    function test_transferOwnership_doesNotChangeOwnerImmediately() public {
        address newOwner = address(0xCAFE);
        sub.transferOwnership(newOwner);
        assertEq(sub.owner(), owner);
    }

    function test_acceptOwnership_completesTransfer() public {
        address newOwner = address(0xCAFE);
        sub.transferOwnership(newOwner);

        vm.prank(newOwner);
        sub.acceptOwnership();

        assertEq(sub.owner(), newOwner);
        assertEq(sub.pendingOwner(), address(0));
    }

    function test_acceptOwnership_revertsForNonPending() public {
        address newOwner = address(0xCAFE);
        sub.transferOwnership(newOwner);

        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        sub.acceptOwnership();
    }

    function test_transferOwnership_revertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        sub.transferOwnership(address(0xCAFE));
    }

    function test_renounceOwnership() public {
        sub.renounceOwnership();
        assertEq(sub.owner(), address(0));
    }

    // Allow receiving ETH (for withdraw tests)
    receive() external payable {}
}

/// @dev Helper contract with no receive/fallback — triggers WithdrawFailed
contract NoReceiveOwner {
    // No receive() or fallback() — ETH transfers will fail

    }
