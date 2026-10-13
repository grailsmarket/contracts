// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Test, console} from "forge-std/Test.sol";
import {ENS} from "ens-contracts/registry/ENS.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BulkRegistrationV2} from "../src/BulkRegistrationV2.sol";
import {IETHRegistrarV2, IETHRenewer, RenewData} from "../src/IETHRegistrarV2.sol";

/**
 * @dev Gas benchmarks on the ENSv2 Sepolia deployment. Each batch is compared against the same
 *      names registered/renewed by calling the ETHRegistrar directly in a loop, so the
 *      difference is the bulk contract's own overhead (token pull, try/catch, refund).
 *      Results are written to snapshots/multiRegisterV2.json and snapshots/multiRenewV2.json.
 */
contract BulkRegistrationV2GasTest is Test {
    BulkRegistrationV2 public bulk;

    IETHRegistrarV2 constant REGISTRAR = IETHRegistrarV2(0xf633e7FC17e2bbE0D0965D18ec1821dcB754a3d3);
    IETHRenewer constant RENEWER_V1 = IETHRenewer(0xf2ece44980778966b8a0FccB3A9E339440f6e045);
    IERC20 constant USDC = IERC20(0x240b0316Df57887DBBE58b586508b19e633a14aa);
    address constant ENS_REGISTRY = 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e;
    address constant RESOLVER = 0xdC4a563d00F5c3012b699794eB9e13A561Be386F;

    uint256 constant FORK_BLOCK = 11_903_000;
    bytes32 constant REFERRER = bytes32(uint256(uint160(0xdead)));
    bytes32 constant SECRET = bytes32(uint256(1));
    uint64 constant DURATION = 365 days;

    address user;

    function setUp() public {
        vm.createSelectFork(vm.envOr("SEPOLIA_RPC_URL", string("https://ethereum-sepolia-rpc.publicnode.com")), FORK_BLOCK);
        user = makeAddr("grails-bulk-v2-user");

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = USDC;
        bulk = new BulkRegistrationV2(REGISTRAR, RENEWER_V1, REFERRER, ENS(ENS_REGISTRY), address(this), tokens);

        deal(address(USDC), user, 10_000_000e6);
        vm.startPrank(user);
        USDC.approve(address(bulk), type(uint256).max);
        USDC.approve(address(REGISTRAR), type(uint256).max);
        vm.stopPrank();
    }

    function _labels(string memory prefix, uint256 count) internal pure returns (string[] memory labels) {
        labels = new string[](count);
        for (uint256 i = 0; i < count; i++) {
            // 10-char names: prefix + 3-digit suffix
            bytes memory name = bytes(string.concat(prefix, "000"));
            uint256 n = name.length;
            name[n - 3] = bytes1(uint8(48 + (i / 100) % 10));
            name[n - 2] = bytes1(uint8(48 + (i / 10) % 10));
            name[n - 1] = bytes1(uint8(48 + i % 10));
            labels[i] = string(name);
        }
    }

    function _durations(uint256 count) internal pure returns (uint64[] memory d) {
        d = new uint64[](count);
        for (uint256 i = 0; i < count; i++) {
            d[i] = DURATION;
        }
    }

    function _commit(string[] memory labels) internal {
        bytes32[] memory c = bulk.makeCommitments(labels, user, _durations(labels.length), SECRET, address(0), RESOLVER);
        vm.prank(user);
        bulk.multiCommit(c);
    }

    function _benchmarkRegister(uint256 count) internal {
        string[] memory bulkLabels = _labels("qxzbnch", count);
        string[] memory directLabels = _labels("qxzdrct", count);
        _commit(bulkLabels);
        _commit(directLabels);
        vm.warp(block.timestamp + 61);
        (, uint256 total) = bulk.registerQuote(bulkLabels, _durations(count), USDC);

        vm.startPrank(user);
        vm.startSnapshotGas("multiRegisterV2", string.concat("batch_", vm.toString(count)));
        uint256 g = gasleft();
        uint256[] memory ids = bulk.multiRegister(bulkLabels, user, _durations(count), SECRET, address(0), RESOLVER, USDC, total);
        uint256 bulkGas = g - gasleft();
        vm.stopSnapshotGas();

        g = gasleft();
        for (uint256 i = 0; i < count; i++) {
            REGISTRAR.register(directLabels[i], user, SECRET, address(0), RESOLVER, DURATION, USDC, REFERRER);
        }
        uint256 directGas = g - gasleft();
        vm.stopPrank();

        for (uint256 i = 0; i < count; i++) {
            assertTrue(ids[i] != 0);
        }
        _log("register", count, bulkGas, directGas);
    }

    function _benchmarkRenew(uint256 count) internal {
        string[] memory bulkLabels = _labels("qxzbnch", count);
        string[] memory directLabels = _labels("qxzdrct", count);
        _commit(bulkLabels);
        _commit(directLabels);
        vm.warp(block.timestamp + 61);
        (, uint256 regTotal) = bulk.registerQuote(bulkLabels, _durations(count), USDC);
        vm.startPrank(user);
        bulk.multiRegister(bulkLabels, user, _durations(count), SECRET, address(0), RESOLVER, USDC, regTotal);
        bulk.multiRegister(directLabels, user, _durations(count), SECRET, address(0), RESOLVER, USDC, regTotal);
        vm.stopPrank();

        (, uint256 total, uint256[] memory bitmap) = bulk.renewQuote(bulkLabels, _durations(count), USDC);

        vm.startPrank(user);
        vm.startSnapshotGas("multiRenewV2", string.concat("batch_", vm.toString(count)));
        uint256 g = gasleft();
        bool[] memory ok = bulk.multiRenew(bulkLabels, _durations(count), bitmap, USDC, total);
        uint256 bulkGas = g - gasleft();
        vm.stopSnapshotGas();

        g = gasleft();
        for (uint256 i = 0; i < count; i++) {
            REGISTRAR.renew(RenewData(directLabels[i], DURATION, REFERRER), USDC);
        }
        uint256 directGas = g - gasleft();
        vm.stopPrank();

        for (uint256 i = 0; i < count; i++) {
            assertTrue(ok[i]);
        }
        _log("renew", count, bulkGas, directGas);
    }

    function _log(string memory kind, uint256 count, uint256 bulkGas, uint256 directGas) internal pure {
        console.log(string.concat("=== ", kind, " batch: ", vm.toString(count), " ==="));
        console.log("  bulk execution gas:     ", bulkGas);
        console.log("  direct loop gas:        ", directGas);
        console.log("  bulk per name:          ", bulkGas / count);
        console.log("  direct per name:        ", directGas / count);
        if (bulkGas > directGas) console.log("  overhead per name:      ", (bulkGas - directGas) / count);
    }

    function test_gas_register_10() public {
        _benchmarkRegister(10);
    }

    function test_gas_register_50() public {
        _benchmarkRegister(50);
    }

    function test_gas_register_100() public {
        _benchmarkRegister(100);
    }

    function test_gas_renew_10() public {
        _benchmarkRenew(10);
    }

    function test_gas_renew_50() public {
        _benchmarkRenew(50);
    }

    function test_gas_renew_100() public {
        _benchmarkRenew(100);
    }
}
