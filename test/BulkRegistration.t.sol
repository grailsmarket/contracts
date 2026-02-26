// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {ENS} from "ens-contracts/registry/ENS.sol";
import {Resolver} from "ens-contracts/resolvers/Resolver.sol";
import {BulkRegistration} from "../src/BulkRegistration.sol";
import {IETHRegistrarController} from "../src/IETHRegistrarController.sol";

contract BulkRegistrationTest is Test, IERC1155Receiver {
    BulkRegistration public bulk;
    IETHRegistrarController public controller;

    address constant CONTROLLER = 0x253553366Da8546fC250F225fe3d25d0C782303b;
    address constant ENS_REGISTRY = 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e;
    address constant PUBLIC_RESOLVER = 0xF29100983E058B709F3D539b0c765937B804AC15;

    bytes32 constant REFERRER = bytes32(uint256(uint160(0xdead)));
    bytes32 constant SECRET = bytes32(uint256(1));
    uint256 constant DURATION = 365 days;

    address owner = address(this);

    // Test names of varying lengths
    string name3 = "qxz"; // 3 chars - most expensive
    string name4 = "qxzw"; // 4 chars
    string name5 = "qxzwv"; // 5+ chars - cheapest

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        controller = IETHRegistrarController(CONTROLLER);
        bulk = new BulkRegistration(CONTROLLER, REFERRER, ENS(ENS_REGISTRY), owner);
        vm.deal(owner, 100 ether);
        Resolver(PUBLIC_RESOLVER).setApprovalForAll(CONTROLLER, true);
    }

    function _name1(string memory a) internal pure returns (string[] memory) {
        string[] memory n = new string[](1);
        n[0] = a;
        return n;
    }

    function _names(string memory a, string memory b) internal pure returns (string[] memory) {
        string[] memory n = new string[](2);
        n[0] = a;
        n[1] = b;
        return n;
    }

    function _names3() internal view returns (string[] memory) {
        string[] memory n = new string[](3);
        n[0] = name3;
        n[1] = name4;
        n[2] = name5;
        return n;
    }

    function _emptyData(uint256 count) internal pure returns (bytes[][] memory) {
        bytes[][] memory d = new bytes[][](count);
        for (uint256 i = 0; i < count; i++) {
            d[i] = new bytes[](0);
        }
        return d;
    }

    function _commitAndWait(string[] memory names) internal {
        bytes32[] memory commitments =
            bulk.makeCommitments(names, owner, DURATION, SECRET, PUBLIC_RESOLVER, _emptyData(names.length), false, 0);
        bulk.multiCommit(commitments);
        vm.warp(block.timestamp + 61);
    }

    function test_constructor_setsController() public view {
        assertEq(address(bulk.CONTROLLER()), CONTROLLER);
    }

    function test_constructor_setsReferrer() public view {
        assertEq(bulk.REFERRER(), REFERRER);
    }

    function test_available_emptyArray() public view {
        string[] memory names = new string[](0);
        bool[] memory results = bulk.available(names);
        assertEq(results.length, 0);
    }

    function test_available_singleName() public view {
        string[] memory names = _name1(name5);
        bool[] memory results = bulk.available(names);
        assertEq(results.length, 1);
        assertTrue(results[0]);
    }

    function test_rentPrices_emptyArray() public view {
        string[] memory names = new string[](0);
        uint256[] memory prices = bulk.rentPrices(names, DURATION);
        assertEq(prices.length, 0);
    }

    function test_rentPrices_singleName() public view {
        string[] memory names = _name1(name5);
        uint256[] memory prices = bulk.rentPrices(names, DURATION);
        assertEq(prices.length, 1);
        assertGt(prices[0], 0);
    }

    function test_totalPrice_emptyArray() public view {
        string[] memory names = new string[](0);
        uint256 total = bulk.totalPrice(names, DURATION);
        assertEq(total, 0);
    }

    function test_totalPrice_singleName() public view {
        string[] memory names = _name1(name5);
        uint256 total = bulk.totalPrice(names, DURATION);
        uint256[] memory prices = bulk.rentPrices(names, DURATION);
        assertEq(total, prices[0]);
    }

    function test_makeCommitments_singleName() public view {
        string[] memory names = _name1(name5);
        bytes32[] memory commitments =
            bulk.makeCommitments(names, owner, DURATION, SECRET, PUBLIC_RESOLVER, _emptyData(1), false, 0);
        assertEq(commitments.length, 1);
        assertTrue(commitments[0] != bytes32(0));
    }

    function test_multiRegister_singleName() public {
        string[] memory names = _name1(name5);

        _commitAndWait(names);

        uint256 total = bulk.totalPrice(names, DURATION);
        bulk.multiRegister{value: total + 1 ether}(names, owner, DURATION, SECRET, PUBLIC_RESOLVER, _emptyData(1), false, 0);

        bool[] memory avail = bulk.available(names);
        assertFalse(avail[0]);
    }

    function test_multiRegister_emptyArray() public {
        string[] memory names = new string[](0);

        uint256 balanceBefore = owner.balance;
        bulk.multiRegister{value: 1 ether}(names, owner, DURATION, SECRET, PUBLIC_RESOLVER, _emptyData(0), false, 0);

        // All ETH should be refunded (balance at least what it was before)
        assertGe(owner.balance, balanceBefore);
        assertEq(address(bulk).balance, 0);
    }

    function test_available() public view {
        string[] memory names = _names(name5, name4);
        bool[] memory results = bulk.available(names);
        assertEq(results.length, 2);
        assertTrue(results[0]);
        assertTrue(results[1]);
    }

    function test_rentPrices() public view {
        string[] memory names = _names3();
        uint256[] memory prices = bulk.rentPrices(names, DURATION);
        assertEq(prices.length, 3);
        // 3-char names should be most expensive, 5+ cheapest
        assertGt(prices[0], prices[1]);
        assertGt(prices[1], prices[2]);
        // All prices should be non-zero
        assertGt(prices[0], 0);
        assertGt(prices[1], 0);
        assertGt(prices[2], 0);
    }

    function test_totalPrice() public view {
        string[] memory names = _names3();
        uint256[] memory prices = bulk.rentPrices(names, DURATION);
        uint256 total = bulk.totalPrice(names, DURATION);
        assertEq(total, prices[0] + prices[1] + prices[2]);
    }

    function test_makeCommitments() public view {
        string[] memory names = _names(name5, name4);
        bytes32[] memory commitments =
            bulk.makeCommitments(names, owner, DURATION, SECRET, PUBLIC_RESOLVER, _emptyData(names.length), false, 0);
        assertEq(commitments.length, 2);
        // Commitments should be unique
        assertTrue(commitments[0] != commitments[1]);
        // Commitments should be deterministic
        bytes32[] memory commitments2 =
            bulk.makeCommitments(names, owner, DURATION, SECRET, PUBLIC_RESOLVER, _emptyData(names.length), false, 0);
        assertEq(commitments[0], commitments2[0]);
        assertEq(commitments[1], commitments2[1]);
    }

    function test_multiCommit() public {
        string[] memory names = _names(name5, name4);
        bytes32[] memory commitments =
            bulk.makeCommitments(names, owner, DURATION, SECRET, PUBLIC_RESOLVER, _emptyData(names.length), false, 0);
        // Should not revert
        bulk.multiCommit(commitments);
    }

    function test_multiRegister() public {
        string[] memory names = _names(name5, name4);

        // Verify names are available before
        bool[] memory avail = bulk.available(names);
        assertTrue(avail[0]);
        assertTrue(avail[1]);

        _commitAndWait(names);

        uint256 total = bulk.totalPrice(names, DURATION);
        bulk.multiRegister{value: total + 1 ether}(names, owner, DURATION, SECRET, PUBLIC_RESOLVER, _emptyData(names.length), false, 0);

        // Names should no longer be available
        avail = bulk.available(names);
        assertFalse(avail[0]);
        assertFalse(avail[1]);
    }

    function test_multiRegister_mixedLengths() public {
        string[] memory names = _names3();

        _commitAndWait(names);

        uint256 total = bulk.totalPrice(names, DURATION);
        bulk.multiRegister{value: total + 1 ether}(names, owner, DURATION, SECRET, PUBLIC_RESOLVER, _emptyData(names.length), false, 0);

        // All names should be registered
        bool[] memory avail = bulk.available(names);
        assertFalse(avail[0]);
        assertFalse(avail[1]);
        assertFalse(avail[2]);
    }

    function test_multiRegister_refundsExcess() public {
        string[] memory names = _names(name5, name4);

        _commitAndWait(names);

        uint256 total = bulk.totalPrice(names, DURATION);
        uint256 excess = 5 ether;
        uint256 balanceBefore = owner.balance;

        bulk.multiRegister{value: total + excess}(names, owner, DURATION, SECRET, PUBLIC_RESOLVER, _emptyData(names.length), false, 0);

        // Balance should be approximately balanceBefore - total (gas costs aside)
        uint256 balanceAfter = owner.balance;
        // The excess should have been refunded, so spent should be close to total
        uint256 spent = balanceBefore - balanceAfter;
        assertLt(spent, total + 0.01 ether); // Allow small margin for rounding
    }

    function test_multiRegister_insufficientFunds() public {
        string[] memory names = _names(name5, name4);

        _commitAndWait(names);

        // Send way too little ETH
        vm.expectRevert();
        bulk.multiRegister{value: 0.0001 ether}(names, owner, DURATION, SECRET, PUBLIC_RESOLVER, _emptyData(names.length), false, 0);
    }

    function test_multiRegister_emitsEvents() public {
        string[] memory names = _names(name5, name4);

        _commitAndWait(names);

        uint256[] memory prices = bulk.rentPrices(names, DURATION);
        uint256 total = prices[0] + prices[1];

        vm.expectEmit(true, true, true, true);
        emit BulkRegistration.NameRegistered(name5, keccak256(bytes(name5)), owner, prices[0], DURATION, REFERRER);
        vm.expectEmit(true, true, true, true);
        emit BulkRegistration.NameRegistered(name4, keccak256(bytes(name4)), owner, prices[1], DURATION, REFERRER);

        bulk.multiRegister{value: total + 1 ether}(names, owner, DURATION, SECRET, PUBLIC_RESOLVER, _emptyData(names.length), false, 0);
    }

    function test_multiRegister_exactPayment() public {
        string[] memory names = _names(name5, name4);

        _commitAndWait(names);

        uint256 total = bulk.totalPrice(names, DURATION);
        uint256 balanceBefore = owner.balance;

        bulk.multiRegister{value: total}(names, owner, DURATION, SECRET, PUBLIC_RESOLVER, _emptyData(names.length), false, 0);

        // Contract should have zero balance (any controller refund is forwarded back)
        assertEq(address(bulk).balance, 0);
        // Spent should be at most total (controller may refund a small amount)
        uint256 spent = balanceBefore - owner.balance;
        assertLe(spent, total);
    }

    function test_multiRegister_perNameData() public {
        string[] memory names = _names(name5, name4);

        // Compute namehashes: namehash(name.eth) = keccak256(ETH_NODE, keccak256(label))
        bytes32 ethNode = 0x93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae;
        bytes32 node0 = keccak256(abi.encodePacked(ethNode, keccak256(bytes(name5))));
        bytes32 node1 = keccak256(abi.encodePacked(ethNode, keccak256(bytes(name4))));

        // Build per-name resolver data: distinct text records per name
        bytes[][] memory data = new bytes[][](2);
        data[0] = new bytes[](1);
        data[0][0] = abi.encodeWithSignature("setText(bytes32,string,string)", node0, "url", "https://alpha.example");
        data[1] = new bytes[](1);
        data[1][0] = abi.encodeWithSignature("setText(bytes32,string,string)", node1, "url", "https://bravo.example");

        // Commit with per-name data (commitment includes data hash)
        bytes32[] memory commitments = bulk.makeCommitments(names, owner, DURATION, SECRET, PUBLIC_RESOLVER, data, false, 0);
        bulk.multiCommit(commitments);
        vm.warp(block.timestamp + 61);

        uint256 total = bulk.totalPrice(names, DURATION);
        bulk.multiRegister{value: total + 1 ether}(names, owner, DURATION, SECRET, PUBLIC_RESOLVER, data, false, 0);

        // Verify each name got its own text record
        (bool ok0, bytes memory ret0) = PUBLIC_RESOLVER.staticcall(abi.encodeWithSignature("text(bytes32,string)", node0, "url"));
        assertTrue(ok0);
        assertEq(abi.decode(ret0, (string)), "https://alpha.example");

        (bool ok1, bytes memory ret1) = PUBLIC_RESOLVER.staticcall(abi.encodeWithSignature("text(bytes32,string)", node1, "url"));
        assertTrue(ok1);
        assertEq(abi.decode(ret1, (string)), "https://bravo.example");
    }

    // ERC1155 receiver (NameWrapper mints ERC1155 tokens to the owner)
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId;
    }

    // Allow receiving ETH refunds
    receive() external payable {}
}
