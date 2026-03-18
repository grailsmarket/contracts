// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17 <0.9.0;

import {Test, console} from "forge-std/Test.sol";
import {ENS} from "ens-contracts/registry/ENS.sol";
import {Resolver} from "ens-contracts/resolvers/Resolver.sol";
import {BulkRegistration} from "../src/BulkRegistration.sol";
import {IETHRegistrarController} from "../src/IETHRegistrarController.sol";

contract BulkRegistrationGasTest is Test {
    BulkRegistration public bulk;
    IETHRegistrarController public controller;

    address constant CONTROLLER = 0x59E16fcCd424Cc24e280Be16E11Bcd56fb0CE547;
    address constant ENS_REGISTRY = 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e;
    address constant PUBLIC_RESOLVER = 0xF29100983E058B709F3D539b0c765937B804AC15;

    bytes32 constant REFERRER = bytes32(uint256(uint160(0xdead)));
    bytes32 constant SECRET = bytes32(uint256(1));
    uint256 constant DURATION = 365 days;
    uint256 constant BLOCK_GAS_LIMIT = 36_000_000;

    address owner = address(this);

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        controller = IETHRegistrarController(CONTROLLER);
        bulk = new BulkRegistration(CONTROLLER, REFERRER, ENS(ENS_REGISTRY), owner);
        vm.deal(owner, 1000 ether);
        Resolver(PUBLIC_RESOLVER).setApprovalForAll(CONTROLLER, true);
    }

    function _generateNames(uint256 count) internal pure returns (string[] memory) {
        string[] memory names = new string[](count);
        for (uint256 i = 0; i < count; i++) {
            // Build 10-char names: "qxzbnch" + 3-digit suffix
            bytes memory name = bytes("qxzbnch000");
            name[7] = bytes1(uint8(48 + (i / 100) % 10));
            name[8] = bytes1(uint8(48 + (i / 10) % 10));
            name[9] = bytes1(uint8(48 + i % 10));
            names[i] = string(name);
        }
        return names;
    }

    function _durations(uint256 count) internal pure returns (uint256[] memory) {
        uint256[] memory d = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            d[i] = DURATION;
        }
        return d;
    }

    function _emptyData(uint256 count) internal pure returns (bytes[][] memory) {
        bytes[][] memory d = new bytes[][](count);
        for (uint256 i = 0; i < count; i++) {
            d[i] = new bytes[](0);
        }
        return d;
    }

    function _benchmarkBatch(uint256 count) internal {
        string[] memory names = _generateNames(count);
        uint256[] memory durations = _durations(count);

        // Commit and wait
        bytes32[] memory commitments =
            bulk.makeCommitments(names, owner, durations, SECRET, PUBLIC_RESOLVER, _emptyData(count), 0);
        bulk.multiCommit(commitments);
        vm.warp(block.timestamp + 61);

        // Price
        uint256 total = bulk.totalPrice(names, durations);

        // Measure multiRegister gas
        uint256 gasBefore = gasleft();
        bulk.multiRegister{value: total + 10 ether}(names, owner, durations, SECRET, PUBLIC_RESOLVER, _emptyData(count), 0);
        uint256 gasUsed = gasBefore - gasleft();

        // Estimate calldata cost: each name is ~10 bytes + ABI overhead
        // multiRegister signature (4) + 7 params * 32 (224) + array headers + name data
        // Rough estimate: 68 gas per non-zero calldata byte, 4 per zero byte
        // For simplicity, estimate ~100 bytes of calldata per name at ~68 gas avg
        uint256 calldataGasPerName = 6_800;
        uint256 calldataGasBase = 15_000; // function sig + fixed params
        uint256 intrinsicGas = 21_000;
        uint256 estimatedTxGas = gasUsed + intrinsicGas + calldataGasBase + (calldataGasPerName * count);

        uint256 perName = gasUsed / count;
        uint256 blockPct = (estimatedTxGas * 100) / BLOCK_GAS_LIMIT;
        uint256 estimatedMax = (BLOCK_GAS_LIMIT - intrinsicGas - calldataGasBase) / (perName + calldataGasPerName);

        console.log("=== Batch size:", count, "===");
        console.log("  multiRegister gas (execution):", gasUsed);
        console.log("  Estimated total tx gas:       ", estimatedTxGas);
        console.log("  Per-name execution gas:       ", perName);
        console.log("  Block % used:                 ", blockPct);
        console.log("  Estimated max names (100%):   ", estimatedMax);
        console.log("  Estimated max names (80%):    ", (estimatedMax * 80) / 100);
        console.log("  Estimated max names (50%):    ", (estimatedMax * 50) / 100);

        // Sanity check: all names registered
        bool[] memory avail = bulk.available(names);
        for (uint256 i = 0; i < count; i++) {
            assertFalse(avail[i], "Name should be registered");
        }
    }

    function test_gas_batch_10() public {
        _benchmarkBatch(10);
    }

    function test_gas_batch_25() public {
        _benchmarkBatch(25);
    }

    function test_gas_batch_50() public {
        _benchmarkBatch(50);
    }

    function test_gas_batch_75() public {
        _benchmarkBatch(75);
    }

    function test_gas_batch_100() public {
        _benchmarkBatch(100);
    }

    // Allow receiving ETH refunds
    receive() external payable {}
}
