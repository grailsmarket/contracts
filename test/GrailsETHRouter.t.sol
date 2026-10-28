// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {ENS} from "ens-contracts/registry/ENS.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {GrailsETHRouter} from "../src/GrailsETHRouter.sol";
import {BulkRegistrationV2} from "../src/BulkRegistrationV2.sol";
import {IETHRegistrarV2} from "../src/IETHRegistrarV2.sol";
import {SepoliaETHPool, IV4QuoterMinimal} from "../script/SepoliaETHPool.sol";

interface IPermissionedRegistryOwner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @dev Refund recipient that rejects ETH
contract RejectsETH {}

/**
 * @dev Fork tests on Sepolia against the deployed BulkRegistrationV2 and the live ENSv2 registrar.
 *      ENS's MockUSDC has no Uniswap pool, so setUp creates and funds one (the same way
 *      script/SetupSepoliaPool.s.sol does). Uses SEPOLIA_RPC_URL if set, otherwise a public
 *      endpoint. Pinned to a block for caching.
 */
contract GrailsETHRouterTest is Test, SepoliaETHPool {
    GrailsETHRouter public router;

    BulkRegistrationV2 constant BULK = BulkRegistrationV2(0x3C549e0FFdD3951afB95B7be97bf4D844d8C3244);
    IETHRegistrarV2 constant REGISTRAR = IETHRegistrarV2(0xf633e7FC17e2bbE0D0965D18ec1821dcB754a3d3);
    IPermissionedRegistryOwner constant ETH_REGISTRY = IPermissionedRegistryOwner(0xD4eBcbBdF463C9c45784603Db0dDD499BC44A8B4);
    IERC20 constant USDC = IERC20(SEPOLIA_MOCK_USDC);
    address constant ENS_REGISTRY = 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e;
    address constant RESOLVER = 0xdC4a563d00F5c3012b699794eB9e13A561Be386F; // PublicResolverV2

    uint256 constant FORK_BLOCK = 12_009_000;
    uint256 constant USDC_PER_ETH = 2500;
    uint256 constant POOL_ETH = 10 ether;
    bytes32 constant SECRET = bytes32(uint256(1));
    uint64 constant DURATION = 365 days;

    // RESERVED (pre-migrated v1) at FORK_BLOCK -> renews via ETHRenewerV1
    string constant V1_NAME = "agentic";
    // Registered in setUp, so REGISTERED on v2 -> renews via ETHRegistrar
    string constant V2_NAME = "qxzgrailsv2";
    // Unregistered at FORK_BLOCK
    string constant NEW1 = "qxzethrouter1";
    string constant NEW2 = "qxzethrouter2";

    address user;

    event PaidWithETH(address indexed payer, uint256 ethSpent, uint256 usdcBought, uint256 usdcRefunded);

    // PositionManager sweeps excess ETH back here when seeding the pool
    receive() external payable {}

    function setUp() public {
        vm.createSelectFork(vm.envOr("SEPOLIA_RPC_URL", string("https://ethereum-sepolia-rpc.publicnode.com")), FORK_BLOCK);
        user = makeAddr("grails-eth-router-user");
        vm.deal(user, 100 ether);

        vm.deal(address(this), POOL_ETH);
        _seedSepoliaPool(address(this), USDC_PER_ETH, POOL_ETH);

        router = new GrailsETHRouter(SEPOLIA_POOL_MANAGER, BULK, USDC, POOL_FEE, POOL_TICK_SPACING, ENS(ENS_REGISTRY), address(this));
        // The router lands at forge's default CREATE address, which holds real Sepolia ETH from
        // other people's deployments. The router would (correctly) pass it to the first caller.
        vm.deal(address(router), 0);

        // REGISTERED fixture: register V2_NAME directly with the ETHRegistrar (paid by this contract)
        REGISTRAR.commit(REGISTRAR.makeCommitment(V2_NAME, user, SECRET, address(0), RESOLVER, DURATION, BULK.REFERRER()));
        vm.warp(block.timestamp + 61);
        (uint256 base, uint256 premium) = REGISTRAR.getRegisterPrice(V2_NAME, DURATION, USDC);
        deal(address(USDC), address(this), base + premium);
        USDC.approve(address(REGISTRAR), base + premium);
        REGISTRAR.register(V2_NAME, user, SECRET, address(0), RESOLVER, DURATION, USDC, BULK.REFERRER());
    }

    // ------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------

    function _arr(string memory a) internal pure returns (string[] memory n) {
        n = new string[](1);
        n[0] = a;
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
        (ethIn,) = IV4QuoterMinimal(SEPOLIA_V4_QUOTER)
            .quoteExactOutputSingle(
                IV4QuoterMinimal.QuoteExactSingleParams({
                    poolKey: router.poolKey(), zeroForOne: true, exactAmount: uint128(usdcAmount), hookData: ""
                })
            );
    }

    function _commitAndWait(string[] memory labels) internal {
        bytes32[] memory c = BULK.makeCommitments(labels, user, _durations(labels.length), SECRET, address(0), RESOLVER);
        vm.prank(user);
        BULK.multiCommit(c);
        vm.warp(block.timestamp + 61);
    }

    function _renew(string[] memory labels, uint256 ethValue, address refundTo)
        internal
        returns (bool[] memory renewed, uint256 usdcTotal, uint256[] memory prices)
    {
        uint256[] memory bitmap;
        (prices, usdcTotal, bitmap) = BULK.renewQuote(labels, _durations(labels.length), USDC);
        vm.prank(user);
        renewed = router.multiRenewWithETH{value: ethValue}(labels, _durations(labels.length), bitmap, usdcTotal, block.timestamp, refundTo);
    }

    function _assertRouterEmpty() internal view {
        assertEq(address(router).balance, 0, "router holds ETH");
        assertEq(USDC.balanceOf(address(router)), 0, "router holds USDC");
    }

    // ------------------------------------------------------------------------------------
    // Constructor / config
    // ------------------------------------------------------------------------------------

    function test_constructor_setsImmutables() public view {
        assertEq(address(router.POOL_MANAGER()), address(SEPOLIA_POOL_MANAGER));
        assertEq(address(router.BULK()), address(BULK));
        assertEq(address(router.USDC()), address(USDC));
        assertEq(router.POOL_FEE(), POOL_FEE);
        assertEq(router.POOL_TICK_SPACING(), POOL_TICK_SPACING);
    }

    function test_poolKey_isNativeETHAndHookFree() public view {
        PoolKey memory key = router.poolKey();
        assertEq(Currency.unwrap(key.currency0), address(0));
        assertEq(Currency.unwrap(key.currency1), address(USDC));
        assertEq(address(key.hooks), address(0));
    }

    function test_constructor_approvesBulk() public view {
        assertEq(USDC.allowance(address(router), address(BULK)), type(uint256).max);
    }

    function test_constructor_revertsIfPoolNotInitialized() public {
        vm.expectRevert(GrailsETHRouter.PoolNotInitialized.selector);
        new GrailsETHRouter(SEPOLIA_POOL_MANAGER, BULK, USDC, 3000, 60, ENS(ENS_REGISTRY), address(this));
    }

    // ------------------------------------------------------------------------------------
    // Renew
    // ------------------------------------------------------------------------------------

    function test_multiRenewWithETH_mixedV1AndV2() public {
        string[] memory labels = _arr(V1_NAME, V2_NAME);
        (, uint256 usdcTotal, uint256[] memory bitmap) = BULK.renewQuote(labels, _durations(2), USDC);
        assertEq(bitmap[0], 1, "V1_NAME should route via ETHRenewerV1");
        uint256 ethQuote = _ethQuote(usdcTotal);
        uint256 ethBefore = user.balance;

        vm.expectEmit(true, false, false, true, address(router));
        emit PaidWithETH(user, ethQuote, usdcTotal, 0);
        vm.prank(user);
        bool[] memory renewed =
            router.multiRenewWithETH{value: ethQuote * 101 / 100}(labels, _durations(2), bitmap, usdcTotal, block.timestamp, address(0));

        assertTrue(renewed[0]);
        assertTrue(renewed[1]);
        assertEq(ethBefore - user.balance, ethQuote, "user pays exactly the quoted ETH");
        assertEq(USDC.balanceOf(user), 0);
        _assertRouterEmpty();
    }

    function test_multiRenewWithETH_exactValueNoRefund() public {
        (, uint256 usdcTotal,) = BULK.renewQuote(_arr(V1_NAME), _durations(1), USDC);
        uint256 ethQuote = _ethQuote(usdcTotal);
        (bool[] memory renewed,,) = _renew(_arr(V1_NAME), ethQuote, address(0));
        assertTrue(renewed[0]);
        _assertRouterEmpty();
    }

    function test_multiRenewWithETH_failedNameRefundsUSDC() public {
        string[] memory labels = _arr(V1_NAME, V2_NAME);
        (uint256[] memory prices, uint256 usdcTotal,) = BULK.renewQuote(labels, _durations(2), USDC);
        uint256 ethQuote = _ethQuote(usdcTotal);

        // Empty bitmap misroutes V1_NAME to the ETHRegistrar, so it fails
        vm.expectEmit(true, false, false, true, address(router));
        emit PaidWithETH(user, ethQuote, usdcTotal, prices[0]);
        vm.prank(user);
        bool[] memory renewed =
            router.multiRenewWithETH{value: ethQuote}(labels, _durations(2), new uint256[](0), usdcTotal, block.timestamp, address(0));

        assertFalse(renewed[0]);
        assertTrue(renewed[1]);
        assertEq(USDC.balanceOf(user), prices[0], "failed name refunded in USDC");
        _assertRouterEmpty();
    }

    function test_multiRenewWithETH_refundToReceivesLeftovers() public {
        address recipient = makeAddr("refund-recipient");
        string[] memory labels = _arr(V1_NAME, V2_NAME);
        (uint256[] memory prices, uint256 usdcTotal,) = BULK.renewQuote(labels, _durations(2), USDC);
        uint256 ethQuote = _ethQuote(usdcTotal);
        uint256 userBefore = user.balance;

        vm.prank(user);
        router.multiRenewWithETH{value: ethQuote + 1 ether}(labels, _durations(2), new uint256[](0), usdcTotal, block.timestamp, recipient);

        assertEq(userBefore - user.balance, ethQuote + 1 ether, "caller sends msg.value");
        assertEq(recipient.balance, 1 ether, "unused ETH to refundTo");
        assertEq(USDC.balanceOf(recipient), prices[0], "failed name's USDC to refundTo");
        assertEq(USDC.balanceOf(user), 0);
        _assertRouterEmpty();
    }

    function testFuzz_multiRenewWithETH_noLeftovers(uint256 extra) public {
        extra = bound(extra, 0, 50 ether);
        (, uint256 usdcTotal,) = BULK.renewQuote(_arr(V1_NAME), _durations(1), USDC);
        uint256 ethQuote = _ethQuote(usdcTotal);
        uint256 ethBefore = user.balance;

        _renew(_arr(V1_NAME), ethQuote + extra, address(0));

        assertEq(ethBefore - user.balance, ethQuote);
        _assertRouterEmpty();
    }

    // ------------------------------------------------------------------------------------
    // Register
    // ------------------------------------------------------------------------------------

    function test_multiRegisterWithETH() public {
        string[] memory labels = _arr(NEW1, NEW2);
        _commitAndWait(labels);
        (, uint256 usdcTotal) = BULK.registerQuote(labels, _durations(2), USDC);
        uint256 ethQuote = _ethQuote(usdcTotal);
        uint256 ethBefore = user.balance;

        vm.prank(user);
        uint256[] memory ids = router.multiRegisterWithETH{value: ethQuote * 101 / 100}(
            labels, user, _durations(2), SECRET, address(0), RESOLVER, usdcTotal, block.timestamp, address(0)
        );

        for (uint256 i = 0; i < 2; i++) {
            assertTrue(ids[i] != 0);
            assertEq(ETH_REGISTRY.ownerOf(ids[i]), user, "name owned by committed owner, not the router");
        }
        assertEq(ethBefore - user.balance, ethQuote);
        _assertRouterEmpty();
    }

    function test_multiRegisterWithETH_uncommittedNameRefundsUSDC() public {
        _commitAndWait(_arr(NEW1));
        string[] memory labels = _arr(NEW1, NEW2);
        (uint256[] memory prices, uint256 usdcTotal) = BULK.registerQuote(labels, _durations(2), USDC);
        uint256 ethQuote = _ethQuote(usdcTotal);

        vm.prank(user);
        uint256[] memory ids = router.multiRegisterWithETH{value: ethQuote}(
            labels, user, _durations(2), SECRET, address(0), RESOLVER, usdcTotal, block.timestamp, address(0)
        );

        assertTrue(ids[0] != 0);
        assertEq(ids[1], 0);
        assertEq(USDC.balanceOf(user), prices[1]);
        _assertRouterEmpty();
    }

    // ------------------------------------------------------------------------------------
    // Reverts
    // ------------------------------------------------------------------------------------

    function test_insufficientETH_reverts() public {
        (, uint256 usdcTotal, uint256[] memory bitmap) = BULK.renewQuote(_arr(V1_NAME), _durations(1), USDC);
        uint256 ethQuote = _ethQuote(usdcTotal);

        vm.expectRevert(abi.encodeWithSelector(GrailsETHRouter.InsufficientETH.selector, ethQuote, ethQuote - 1));
        vm.prank(user);
        router.multiRenewWithETH{value: ethQuote - 1}(_arr(V1_NAME), _durations(1), bitmap, usdcTotal, block.timestamp, address(0));
    }

    function test_noETH_reverts() public {
        (, uint256 usdcTotal, uint256[] memory bitmap) = BULK.renewQuote(_arr(V1_NAME), _durations(1), USDC);
        vm.expectRevert(abi.encodeWithSelector(GrailsETHRouter.InsufficientETH.selector, _ethQuote(usdcTotal), 0));
        vm.prank(user);
        router.multiRenewWithETH(_arr(V1_NAME), _durations(1), bitmap, usdcTotal, block.timestamp, address(0));
    }

    function test_deadlineExpired_reverts() public {
        (, uint256 usdcTotal, uint256[] memory bitmap) = BULK.renewQuote(_arr(V1_NAME), _durations(1), USDC);
        vm.expectRevert(GrailsETHRouter.DeadlineExpired.selector);
        vm.prank(user);
        router.multiRenewWithETH{value: 1 ether}(_arr(V1_NAME), _durations(1), bitmap, usdcTotal, block.timestamp - 1, address(0));
    }

    function test_insufficientLiquidity_reverts() public {
        // More USDC than the whole pool holds
        uint256 tooMuch = POOL_ETH * USDC_PER_ETH * 1e6 * 2;
        vm.expectRevert(GrailsETHRouter.InsufficientLiquidity.selector);
        vm.prank(user);
        router.multiRenewWithETH{value: 1 ether}(_arr(V1_NAME), _durations(1), new uint256[](0), tooMuch, block.timestamp, address(0));
    }

    function test_refundToRejectingETH_reverts() public {
        address rejecter = address(new RejectsETH());
        (, uint256 usdcTotal, uint256[] memory bitmap) = BULK.renewQuote(_arr(V1_NAME), _durations(1), USDC);
        uint256 ethQuote = _ethQuote(usdcTotal);

        vm.expectRevert(GrailsETHRouter.ETHRefundFailed.selector);
        vm.prank(user);
        router.multiRenewWithETH{value: ethQuote + 1}(_arr(V1_NAME), _durations(1), bitmap, usdcTotal, block.timestamp, rejecter);
    }

    function test_unlockCallback_onlyPoolManager() public {
        vm.expectRevert(GrailsETHRouter.NotPoolManager.selector);
        router.unlockCallback(abi.encode(uint256(1e6), uint256(1 ether)));
    }

    function test_rejectsDirectETH() public {
        vm.prank(user);
        (bool ok,) = address(router).call{value: 1 ether}("");
        assertFalse(ok);
    }
}
