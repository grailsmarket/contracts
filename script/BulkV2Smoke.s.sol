// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BulkRegistrationV2} from "../src/BulkRegistrationV2.sol";
import {GrailsETHRouter} from "../src/GrailsETHRouter.sol";
import {IV4QuoterMinimal} from "./SepoliaETHPool.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/**
 * @dev Sepolia smoke test for BulkRegistrationV2: bulk commit, register and renew from a test
 *      wallet, paying in MockUSDC (which has a public mint, so the wallet is topped up as needed).
 *
 *      Env: SENDER (the broadcasting wallet, also the names' owner), LABELS (comma-separated,
 *      no ".eth"), SECRET (bytes32, the same for commit and register).
 *      Optional: BULK (default: the 2026-10-13 Sepolia deployment), DURATION (seconds, default
 *      365 days; the registrar minimum is 28 days), RESOLVER (default: none).
 *
 *      1. forge script script/BulkV2Smoke.s.sol --sig "commit()" --rpc-url sepolia --account <keystore> --broadcast
 *      2. wait at least 60s (the registrar's MIN_COMMITMENT_AGE)
 *      3. forge script script/BulkV2Smoke.s.sol --sig "register()" --rpc-url sepolia --account <keystore> --broadcast
 *      4. forge script script/BulkV2Smoke.s.sol --sig "renew()" --rpc-url sepolia --account <keystore> --broadcast
 *
 *      renew() takes any names (anyone can renew), so LABELS can mix v2 names with unmigrated v1
 *      names to exercise both renewers. Drop --broadcast for a dry run.
 *
 *      Paying with ETH through GrailsETHRouter (needs ROUTER; optional HEADROOM_BPS, default 50):
 *      3. forge script script/BulkV2Smoke.s.sol --sig "registerETH()" --rpc-url sepolia --account <keystore> --broadcast
 *      4. forge script script/BulkV2Smoke.s.sol --sig "renewETH()" --rpc-url sepolia --account <keystore> --broadcast
 */
contract BulkV2Smoke is Script {
    address constant SEPOLIA_BULK = 0x3C549e0FFdD3951afB95B7be97bf4D844d8C3244;
    address constant SEPOLIA_USDC = 0x240b0316Df57887DBBE58b586508b19e633a14aa; // MockUSDC
    address constant SEPOLIA_V4_QUOTER = 0x61B3f2011A92d183C7dbaDBdA940a7555Ccf9227;

    function commit() external {
        (BulkRegistrationV2 bulk, address sender, string[] memory labels, uint64[] memory durations) = _setup();
        bytes32[] memory commitments = bulk.makeCommitments(labels, sender, durations, vm.envBytes32("SECRET"), address(0), _resolver());

        vm.startBroadcast(sender);
        bulk.multiCommit(commitments);
        vm.stopBroadcast();

        console.log("Committed %s names; run register() after 60s", labels.length);
    }

    function register() external {
        (BulkRegistrationV2 bulk, address sender, string[] memory labels, uint64[] memory durations) = _setup();
        IERC20 usdc = IERC20(SEPOLIA_USDC);
        (, uint256 total) = bulk.registerQuote(labels, durations, usdc);
        require(total > 0, "nothing registrable (taken, invalid or too short a duration)");

        vm.startBroadcast(sender);
        _fund(usdc, sender, address(bulk), total);
        uint256[] memory tokenIds =
            bulk.multiRegister(labels, sender, durations, vm.envBytes32("SECRET"), address(0), _resolver(), usdc, total);
        vm.stopBroadcast();

        for (uint256 i = 0; i < labels.length; i++) {
            console.log("%s.eth -> token %s", labels[i], tokenIds[i]);
        }
    }

    function renew() external {
        (BulkRegistrationV2 bulk, address sender, string[] memory labels, uint64[] memory durations) = _setup();
        IERC20 usdc = IERC20(SEPOLIA_USDC);
        (, uint256 total, uint256[] memory v1Bitmap) = bulk.renewQuote(labels, durations, usdc);
        require(total > 0, "nothing renewable");

        vm.startBroadcast(sender);
        _fund(usdc, sender, address(bulk), total);
        bool[] memory renewed = bulk.multiRenew(labels, durations, v1Bitmap, usdc, total);
        vm.stopBroadcast();

        for (uint256 i = 0; i < labels.length; i++) {
            bool viaV1 = (v1Bitmap[i >> 8] >> (i & 255)) & 1 == 1;
            console.log("%s.eth renewed=%s via %s", labels[i], renewed[i], viaV1 ? "ETHRenewerV1" : "ETHRegistrar");
        }
    }

    function registerETH() external {
        (BulkRegistrationV2 bulk, address sender, string[] memory labels, uint64[] memory durations) = _setup();
        GrailsETHRouter router = GrailsETHRouter(vm.envAddress("ROUTER"));
        (, uint256 total) = bulk.registerQuote(labels, durations, IERC20(SEPOLIA_USDC));
        require(total > 0, "nothing registrable (taken, invalid or too short a duration)");
        (uint256 ethQuote, uint256 ethValue) = _ethValue(router, total);

        uint256 ethBefore = sender.balance;
        vm.startBroadcast(sender);
        uint256[] memory tokenIds = router.multiRegisterWithETH{value: ethValue}(
            labels, sender, durations, vm.envBytes32("SECRET"), address(0), _resolver(), total, block.timestamp + 10 minutes, address(0)
        );
        vm.stopBroadcast();

        _logETH(total, ethQuote, ethValue, ethBefore - sender.balance);
        for (uint256 i = 0; i < labels.length; i++) {
            console.log("%s.eth -> token %s", labels[i], tokenIds[i]);
        }
    }

    function renewETH() external {
        (BulkRegistrationV2 bulk, address sender, string[] memory labels, uint64[] memory durations) = _setup();
        GrailsETHRouter router = GrailsETHRouter(vm.envAddress("ROUTER"));
        (, uint256 total, uint256[] memory v1Bitmap) = bulk.renewQuote(labels, durations, IERC20(SEPOLIA_USDC));
        require(total > 0, "nothing renewable");
        (uint256 ethQuote, uint256 ethValue) = _ethValue(router, total);

        uint256 ethBefore = sender.balance;
        vm.startBroadcast(sender);
        bool[] memory renewed =
            router.multiRenewWithETH{value: ethValue}(labels, durations, v1Bitmap, total, block.timestamp + 10 minutes, address(0));
        vm.stopBroadcast();

        _logETH(total, ethQuote, ethValue, ethBefore - sender.balance);
        for (uint256 i = 0; i < labels.length; i++) {
            console.log("%s.eth renewed=%s", labels[i], renewed[i]);
        }
    }

    // Quote the ETH for `usdcAmount` on the router's pool and add HEADROOM_BPS
    function _ethValue(GrailsETHRouter router, uint256 usdcAmount) internal returns (uint256 ethQuote, uint256 ethValue) {
        (ethQuote,) = IV4QuoterMinimal(SEPOLIA_V4_QUOTER)
            .quoteExactOutputSingle(
                IV4QuoterMinimal.QuoteExactSingleParams({
                    poolKey: router.poolKey(), zeroForOne: true, exactAmount: uint128(usdcAmount), hookData: ""
                })
            );
        ethValue = ethQuote * (10_000 + vm.envOr("HEADROOM_BPS", uint256(50))) / 10_000;
    }

    // Gas is not included in the spent figure when simulating; on broadcast it includes gas
    function _logETH(uint256 usdcAmount, uint256 ethQuote, uint256 ethValue, uint256 ethSpent) internal pure {
        console.log("USDC bought:", usdcAmount);
        console.log("ETH quoted:", ethQuote);
        console.log("ETH sent:", ethValue);
        console.log("ETH spent (sender balance change):", ethSpent);
    }

    function _setup() internal view returns (BulkRegistrationV2 bulk, address sender, string[] memory labels, uint64[] memory durations) {
        require(block.chainid == 11155111, "Sepolia only");
        bulk = BulkRegistrationV2(vm.envOr("BULK", SEPOLIA_BULK));
        sender = vm.envAddress("SENDER");
        labels = vm.envString("LABELS", ",");
        uint64 duration = uint64(vm.envOr("DURATION", uint256(365 days)));
        durations = new uint64[](labels.length);
        for (uint256 i = 0; i < labels.length; i++) {
            durations[i] = duration;
        }
    }

    function _resolver() internal view returns (address) {
        return vm.envOr("RESOLVER", address(0));
    }

    // Mint any MockUSDC shortfall to the sender and approve the bulk contract for `amount`
    function _fund(IERC20 token, address sender, address spender, uint256 amount) internal {
        uint256 balance = token.balanceOf(sender);
        if (balance < amount) {
            IMintable(address(token)).mint(sender, amount - balance);
        }
        token.approve(spender, amount);
    }
}
