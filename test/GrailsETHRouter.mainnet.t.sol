// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Test, console} from "forge-std/Test.sol";
import {ENS} from "ens-contracts/registry/ENS.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {GrailsETHRouter} from "../src/GrailsETHRouter.sol";
import {BulkRegistrationV2} from "../src/BulkRegistrationV2.sol";
import {IV4QuoterMinimal} from "../script/SepoliaETHPool.sol";

/**
 * @dev Mainnet fork tests: the real hook-free ETH/USDC 0.05% v4 pool and the deployed
 *      BulkRegistrationV2. Checks the quote-then-swap flow against real liquidity and measures
 *      the router's gas overhead over paying the bulk contract in USDC directly.
 *      Uses MAINNET_RPC_URL if set, otherwise a public endpoint. Pinned to a block for caching.
 *      Gas results are written to snapshots/ethRouter.json.
 */
contract GrailsETHRouterMainnetTest is Test {
    GrailsETHRouter public router;

    IPoolManager constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IV4QuoterMinimal constant V4_QUOTER = IV4QuoterMinimal(0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203);
    BulkRegistrationV2 constant BULK = BulkRegistrationV2(0x438edcB58703dfB2e1D4Bb5E54a280E75A95ad90);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address constant ENS_REGISTRY = 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e;

    uint256 constant FORK_BLOCK = 26_288_000;
    uint24 constant POOL_FEE = 500;
    int24 constant POOL_TICK_SPACING = 10;
    bytes32 constant SECRET = bytes32(uint256(1));
    uint64 constant DURATION = 365 days;

    // RESERVED (unmigrated v1) at FORK_BLOCK -> ETHRenewerV1; REGISTERED v2 -> ETHRegistrar
    string constant V1_NAME = "vitalik";
    string constant V2_NAME = "nick";
    string constant NEW_NAME = "qxzgrailsethrouter";

    address user;

    function setUp() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")), FORK_BLOCK);
        user = makeAddr("grails-eth-router-mainnet-user");
        vm.deal(user, 100 ether);
        router = new GrailsETHRouter(POOL_MANAGER, BULK, USDC, POOL_FEE, POOL_TICK_SPACING, ENS(ENS_REGISTRY), address(this));
        vm.deal(address(router), 0);
    }

    function _arr(string memory a, string memory b) internal pure returns (string[] memory n) {
        n = new string[](2);
        n[0] = a;
        n[1] = b;
    }

    function _durations(uint256 count) internal pure returns (uint64[] memory d) {
        d = new uint64[](count);
        for (uint256 i = 0; i < count; i++) {
            d[i] = DURATION;
        }
    }

    function _ethQuote(uint256 usdcAmount) internal returns (uint256 ethIn) {
        (ethIn,) = V4_QUOTER.quoteExactOutputSingle(
            IV4QuoterMinimal.QuoteExactSingleParams({
                poolKey: router.poolKey(), zeroForOne: true, exactAmount: uint128(usdcAmount), hookData: ""
            })
        );
    }

    function test_mainnet_multiRenewWithETH() public {
        string[] memory labels = _arr(V1_NAME, V2_NAME);
        (, uint256 usdcTotal, uint256[] memory bitmap) = BULK.renewQuote(labels, _durations(2), USDC);
        assertEq(bitmap[0], 1, "V1_NAME should route via ETHRenewerV1");
        uint256 ethQuote = _ethQuote(usdcTotal);
        uint256 ethBefore = user.balance;

        vm.prank(user);
        bool[] memory renewed =
            router.multiRenewWithETH{value: ethQuote * 1005 / 1000}(labels, _durations(2), bitmap, usdcTotal, block.timestamp, address(0));

        assertTrue(renewed[0]);
        assertTrue(renewed[1]);
        assertEq(ethBefore - user.balance, ethQuote, "user pays exactly the quoted ETH");
        assertEq(address(router).balance, 0);
        assertEq(USDC.balanceOf(address(router)), 0);
        console.log("USDC total:", usdcTotal);
        console.log("ETH paid (wei):", ethQuote);
    }

    function test_mainnet_multiRegisterWithETH() public {
        string[] memory labels = new string[](1);
        labels[0] = NEW_NAME;
        bytes32[] memory c = BULK.makeCommitments(labels, user, _durations(1), SECRET, address(0), address(0));
        vm.prank(user);
        BULK.multiCommit(c);
        vm.warp(block.timestamp + 61);

        (, uint256 usdcTotal) = BULK.registerQuote(labels, _durations(1), USDC);
        assertGt(usdcTotal, 0, "NEW_NAME must be available at FORK_BLOCK");
        uint256 ethQuote = _ethQuote(usdcTotal);

        vm.prank(user);
        uint256[] memory ids = router.multiRegisterWithETH{value: ethQuote * 1005 / 1000}(
            labels, user, _durations(1), SECRET, address(0), address(0), usdcTotal, block.timestamp, address(0)
        );

        assertTrue(ids[0] != 0);
        assertEq(address(router).balance, 0);
        assertEq(USDC.balanceOf(address(router)), 0);
    }

    /// @dev Router (ETH) vs bulk (USDC) for the same renewal, from the same state
    function test_mainnet_gas_routerOverhead() public {
        string[] memory labels = _arr(V1_NAME, V2_NAME);
        (, uint256 usdcTotal, uint256[] memory bitmap) = BULK.renewQuote(labels, _durations(2), USDC);
        uint256 ethValue = _ethQuote(usdcTotal) * 1005 / 1000;
        deal(address(USDC), user, usdcTotal);
        vm.prank(user);
        USDC.approve(address(BULK), usdcTotal);

        uint256 snap = vm.snapshotState();
        vm.prank(user);
        uint256 g = gasleft();
        BULK.multiRenew(labels, _durations(2), bitmap, USDC, usdcTotal);
        uint256 bulkGas = g - gasleft();

        vm.revertToState(snap);
        vm.prank(user);
        vm.startSnapshotGas("ethRouter", "multiRenewWithETH_2");
        g = gasleft();
        router.multiRenewWithETH{value: ethValue}(labels, _durations(2), bitmap, usdcTotal, block.timestamp, address(0));
        uint256 routerGas = g - gasleft();
        vm.stopSnapshotGas();

        console.log("bulk multiRenew (USDC):    ", bulkGas);
        console.log("router multiRenewWithETH:  ", routerGas);
        console.log("router overhead:           ", routerGas - bulkGas);
    }
}
