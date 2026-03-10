// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ENS} from "ens-contracts/registry/ENS.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GrailsSubscription} from "../src/GrailsSubscription.sol";

// ---------------------------------------------------------------------------
// Fork tests — validates ReverseClaimer integration against mainnet ENS
// ---------------------------------------------------------------------------

contract GrailsSubscriptionForkTest is Test {
    GrailsSubscription public sub;

    address constant ENS_REGISTRY = 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e;
    uint256 constant PRICE_PER_DAY = 0.001 ether;
    address owner = address(this);

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        sub = new GrailsSubscription(PRICE_PER_DAY, ENS(ENS_REGISTRY), owner);
    }

    function test_constructor_setsOwner() public view {
        assertEq(sub.owner(), owner);
    }

    function test_constructor_setsPricePerDay() public view {
        assertEq(sub.pricePerDay(), PRICE_PER_DAY);
    }

    function test_constructor_deploySucceeds() public view {
        // If we got here, the ReverseClaimer constructor didn't revert
        assertTrue(address(sub) != address(0));
    }
}

// ---------------------------------------------------------------------------
// Unit tests — no fork required, ENS calls are mocked
// ---------------------------------------------------------------------------

contract GrailsSubscriptionTest is Test {
    GrailsSubscription public sub;

    uint256 constant PRICE_PER_DAY = 0.001 ether;
    address owner;
    address user = address(0xBEEF);

    // ENS mock addresses
    address constant ENS_REGISTRY = 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e;
    address constant REVERSE_REGISTRAR = address(0xA11CE);
    bytes32 constant ADDR_REVERSE_NODE = 0x91d1777781884d03a6757a803996e38de2a42967fb37eeaca72729271025a9e2;

    function setUp() public {
        owner = address(this);

        // Mock ENS.owner(ADDR_REVERSE_NODE) → REVERSE_REGISTRAR
        vm.mockCall(ENS_REGISTRY, abi.encodeWithSignature("owner(bytes32)", ADDR_REVERSE_NODE), abi.encode(REVERSE_REGISTRAR));

        // Mock IReverseRegistrar.claim(owner) → node
        vm.mockCall(REVERSE_REGISTRAR, abi.encodeWithSignature("claim(address)", owner), abi.encode(bytes32(0)));

        sub = new GrailsSubscription(PRICE_PER_DAY, ENS(ENS_REGISTRY), owner);

        vm.deal(user, 100 ether);
    }

    // -----------------------------------------------------------------------
    // subscribe
    // -----------------------------------------------------------------------

    function test_subscribe_singleDay() public {
        vm.prank(user);
        sub.subscribe{value: PRICE_PER_DAY}(1);

        uint256 expiry = sub.getSubscription(user);
        assertEq(expiry, block.timestamp + 1 days);
    }

    function test_subscribe_multipleDays() public {
        vm.prank(user);
        sub.subscribe{value: PRICE_PER_DAY * 30}(30);

        uint256 expiry = sub.getSubscription(user);
        assertEq(expiry, block.timestamp + 30 days);
    }

    function test_subscribe_extendsFromExpiry() public {
        vm.prank(user);
        sub.subscribe{value: PRICE_PER_DAY * 10}(10);
        uint256 firstExpiry = sub.getSubscription(user);

        // Warp to midway — subscription still active
        vm.warp(block.timestamp + 5 days);

        vm.prank(user);
        sub.subscribe{value: PRICE_PER_DAY * 5}(5);
        uint256 secondExpiry = sub.getSubscription(user);

        // Should extend from the first expiry, not from now
        assertEq(secondExpiry, firstExpiry + 5 days);
    }

    function test_subscribe_extendsFromNowIfExpired() public {
        vm.prank(user);
        sub.subscribe{value: PRICE_PER_DAY}(1);

        // Warp past expiry
        vm.warp(block.timestamp + 10 days);
        uint256 nowTs = block.timestamp;

        vm.prank(user);
        sub.subscribe{value: PRICE_PER_DAY * 3}(3);

        uint256 expiry = sub.getSubscription(user);
        assertEq(expiry, nowTs + 3 days);
    }

    function test_subscribe_emitsEvent() public {
        vm.prank(user);
        vm.expectEmit(true, false, false, true);
        emit GrailsSubscription.Subscribed(user, block.timestamp + 1 days, PRICE_PER_DAY);
        sub.subscribe{value: PRICE_PER_DAY}(1);
    }

    function test_subscribe_revertsOnZeroDays() public {
        vm.prank(user);
        vm.expectRevert(GrailsSubscription.MinimumOneDayRequired.selector);
        sub.subscribe{value: PRICE_PER_DAY}(0);
    }

    function test_subscribe_revertsOnInsufficientPayment() public {
        vm.prank(user);
        vm.expectRevert(GrailsSubscription.InsufficientPayment.selector);
        sub.subscribe{value: PRICE_PER_DAY - 1}(1);
    }

    function test_subscribe_acceptsOverpayment() public {
        vm.prank(user);
        sub.subscribe{value: PRICE_PER_DAY * 10}(1);

        uint256 expiry = sub.getSubscription(user);
        assertEq(expiry, block.timestamp + 1 days);
        assertEq(address(sub).balance, PRICE_PER_DAY * 10);
    }

    // -----------------------------------------------------------------------
    // getSubscription
    // -----------------------------------------------------------------------

    function test_getSubscription_returnsZeroForNonSubscriber() public view {
        assertEq(sub.getSubscription(address(0xDEAD)), 0);
    }

    function test_getSubscription_returnsExpiryAfterSubscribe() public {
        vm.prank(user);
        sub.subscribe{value: PRICE_PER_DAY * 7}(7);
        assertEq(sub.getSubscription(user), block.timestamp + 7 days);
    }

    // -----------------------------------------------------------------------
    // withdraw
    // -----------------------------------------------------------------------

    function test_withdraw_sendsBalanceToOwner() public {
        vm.prank(user);
        sub.subscribe{value: 1 ether}(1);

        uint256 ownerBefore = owner.balance;
        sub.withdraw();
        assertEq(owner.balance, ownerBefore + 1 ether);
        assertEq(address(sub).balance, 0);
    }

    function test_withdraw_emitsEvent() public {
        vm.prank(user);
        sub.subscribe{value: 1 ether}(1);

        vm.expectEmit(true, false, false, true);
        emit GrailsSubscription.Withdrawn(owner, 1 ether);
        sub.withdraw();
    }

    function test_withdraw_revertsOnNoBalance() public {
        vm.expectRevert(GrailsSubscription.NoBalance.selector);
        sub.withdraw();
    }

    function test_withdraw_revertsForNonOwner() public {
        vm.prank(user);
        sub.subscribe{value: 1 ether}(1);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        sub.withdraw();
    }

    function test_withdraw_revertsOnFailedTransfer() public {
        // Deploy with a NoReceiveOwner as owner
        NoReceiveOwner noReceive = new NoReceiveOwner();
        vm.mockCall(ENS_REGISTRY, abi.encodeWithSignature("owner(bytes32)", ADDR_REVERSE_NODE), abi.encode(REVERSE_REGISTRAR));
        vm.mockCall(REVERSE_REGISTRAR, abi.encodeWithSignature("claim(address)", address(noReceive)), abi.encode(bytes32(0)));

        GrailsSubscription sub2 = new GrailsSubscription(PRICE_PER_DAY, ENS(ENS_REGISTRY), address(noReceive));

        vm.prank(user);
        sub2.subscribe{value: 1 ether}(1);

        vm.prank(address(noReceive));
        vm.expectRevert(GrailsSubscription.WithdrawFailed.selector);
        sub2.withdraw();
    }

    // -----------------------------------------------------------------------
    // setPrice
    // -----------------------------------------------------------------------

    function test_setPrice_updatesPrice() public {
        uint256 newPrice = 0.002 ether;
        sub.setPrice(newPrice);
        assertEq(sub.pricePerDay(), newPrice);
    }

    function test_setPrice_emitsEvent() public {
        uint256 newPrice = 0.002 ether;
        vm.expectEmit(false, false, false, true);
        emit GrailsSubscription.PriceUpdated(PRICE_PER_DAY, newPrice);
        sub.setPrice(newPrice);
    }

    function test_setPrice_revertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        sub.setPrice(0.002 ether);
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
