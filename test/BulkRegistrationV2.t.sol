// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Test, Vm} from "forge-std/Test.sol";
import {ENS} from "ens-contracts/registry/ENS.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BulkRegistrationV2} from "../src/BulkRegistrationV2.sol";
import {IETHRegistrarV2, IETHRenewer} from "../src/IETHRegistrarV2.sol";

interface IPermissionedRegistryView {
    function getStatus(uint256 anyId) external view returns (uint8);
    function getExpiry(uint256 anyId) external view returns (uint64);
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IBaseRegistrarView {
    function nameExpires(uint256 id) external view returns (uint256);
    function owner() external view returns (address);
    function addController(address controller) external;
}

interface IERC20PermitFull {
    function nonces(address owner) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @dev Renewer that burns every unit of gas it is given, to exercise the out-of-gas guard.
contract GasBurningRenewer {
    function renew(string calldata, uint64, IERC20, bytes32) external pure {
        while (true) {}
    }
}

/**
 * @dev Fork tests against the live ENSv2 Sepolia deployment (contracts-v2 `deployments/sepolia`).
 *      Uses SEPOLIA_RPC_URL if set, otherwise a public endpoint. Pinned to a block for caching.
 */
contract BulkRegistrationV2Test is Test {
    BulkRegistrationV2 public bulk;

    IETHRegistrarV2 constant REGISTRAR = IETHRegistrarV2(0xa4449a0dD2b83007553D9b1d28b583A46A805a30);
    IETHRenewer constant RENEWER_V1 = IETHRenewer(0x1BE516Ae1B72765aE55bD5e9ca628c9058a1C622);
    IPermissionedRegistryView constant ETH_REGISTRY = IPermissionedRegistryView(0x67b728a792e789a8978b30cF1b3b641f19354b43);
    IBaseRegistrarView constant BASE_REGISTRAR = IBaseRegistrarView(0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85);
    IERC20 constant USDC = IERC20(0xD3322B29a7BdEe707D1684676f149bf41Aa3422f); // MockUSDC, 6 decimals, EIP-2612
    IERC20 constant DAI = IERC20(0xE33a01a41eE4a68616B5278183aa88808326ED8E); // MockDAI, 18 decimals
    address constant BENEFICIARY = 0x84D3a426D4E12E955d1DF95db0B24fe26afE39D3;
    address constant ENS_REGISTRY = 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e;
    address constant RESOLVER = 0xd25f66Dd4fF61486c2c5c1E6201A23576698D3df; // PublicResolverV2

    uint256 constant FORK_BLOCK = 11_874_550;
    bytes32 constant REFERRER = bytes32(uint256(uint160(0xdead)));
    bytes32 constant SECRET = bytes32(uint256(1));
    uint64 constant DURATION = 365 days;

    // Unregistered labels of varying length
    string constant NAME3 = "qxz";
    string constant NAME4 = "qxzw";
    string constant NAME5 = "qxzwvgrails";
    // REGISTERED on v2 -> renews via ETHRegistrar
    string constant V2_NAME = "vitalik";
    // RESERVED (pre-migrated v1) -> renews via ETHRenewerV1
    string constant V1_NAME = "agentic";
    string constant V1_NAME2 = "brown";

    address user;
    uint256 userKey;

    function setUp() public {
        vm.createSelectFork(vm.envOr("SEPOLIA_RPC_URL", string("https://ethereum-sepolia-rpc.publicnode.com")), FORK_BLOCK);
        (user, userKey) = makeAddrAndKey("grails-bulk-v2-user");
        assertEq(user.code.length, 0, "user must be an EOA to receive ERC1155 mints");

        // Sepolia's fresh v2 deployment has not run migration phase 4 (authorize ETHRenewerV1
        // as a v1 BaseRegistrar controller), so RESERVED renewals would revert. Simulate it.
        vm.prank(BASE_REGISTRAR.owner());
        BASE_REGISTRAR.addController(address(RENEWER_V1));

        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = USDC;
        tokens[1] = DAI;
        bulk = new BulkRegistrationV2(REGISTRAR, RENEWER_V1, REFERRER, ENS(ENS_REGISTRY), address(this), tokens);

        deal(address(USDC), user, 100_000e6);
        deal(address(DAI), user, 100_000e18);
        vm.startPrank(user);
        USDC.approve(address(bulk), type(uint256).max);
        DAI.approve(address(bulk), type(uint256).max);
        vm.stopPrank();
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

    function _arr(string memory a, string memory b, string memory c) internal pure returns (string[] memory n) {
        n = new string[](3);
        n[0] = a;
        n[1] = b;
        n[2] = c;
    }

    function _durations(uint256 count) internal pure returns (uint64[] memory d) {
        d = new uint64[](count);
        for (uint256 i = 0; i < count; i++) {
            d[i] = DURATION;
        }
    }

    function _commitAndWait(string[] memory labels) internal {
        bytes32[] memory c = bulk.makeCommitments(labels, user, _durations(labels.length), SECRET, address(0), RESOLVER);
        vm.prank(user);
        bulk.multiCommit(c);
        vm.warp(block.timestamp + 61);
    }

    function _register(string[] memory labels, uint256 maxAmount) internal returns (uint256[] memory) {
        vm.prank(user);
        return bulk.multiRegister(labels, user, _durations(labels.length), SECRET, address(0), RESOLVER, USDC, maxAmount);
    }

    function _id(string memory label) internal pure returns (uint256) {
        return uint256(keccak256(bytes(label)));
    }

    function _signPermit(IERC20 token, uint256 value, uint256 deadline) internal view returns (BulkRegistrationV2.Permit memory p) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                user,
                address(bulk),
                value,
                IERC20PermitFull(address(token)).nonces(user),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IERC20PermitFull(address(token)).DOMAIN_SEPARATOR(), structHash));
        (p.v, p.r, p.s) = vm.sign(userKey, digest);
        p.deadline = deadline;
    }

    function _countFailures(Vm.Log[] memory logs, bytes32 sig) internal view returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(bulk) && logs[i].topics[0] == sig) count++;
        }
    }

    // ------------------------------------------------------------------------------------
    // Constructor / config
    // ------------------------------------------------------------------------------------

    function test_constructor_setsImmutables() public view {
        assertEq(address(bulk.REGISTRAR()), address(REGISTRAR));
        assertEq(address(bulk.RENEWER_V1()), address(RENEWER_V1));
        assertEq(bulk.REFERRER(), REFERRER);
    }

    function test_constructor_approvesTokens() public view {
        assertEq(USDC.allowance(address(bulk), address(REGISTRAR)), type(uint256).max);
        assertEq(USDC.allowance(address(bulk), address(RENEWER_V1)), type(uint256).max);
        assertEq(DAI.allowance(address(bulk), address(REGISTRAR)), type(uint256).max);
        assertEq(DAI.allowance(address(bulk), address(RENEWER_V1)), type(uint256).max);
    }

    function test_approveToken_isPermissionless() public {
        IERC20[] memory none = new IERC20[](0);
        BulkRegistrationV2 b = new BulkRegistrationV2(REGISTRAR, RENEWER_V1, REFERRER, ENS(ENS_REGISTRY), address(this), none);
        assertEq(USDC.allowance(address(b), address(REGISTRAR)), 0);
        vm.prank(makeAddr("anyone"));
        b.approveToken(USDC);
        assertEq(USDC.allowance(address(b), address(REGISTRAR)), type(uint256).max);
        assertEq(USDC.allowance(address(b), address(RENEWER_V1)), type(uint256).max);
    }

    // ------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------

    function test_available() public view {
        bool[] memory a = bulk.available(_arr(NAME5, V2_NAME, V1_NAME));
        assertTrue(a[0]);
        assertFalse(a[1]);
        assertFalse(a[2]);
    }

    function test_registerQuote_mixedLengthsAndUnavailable() public view {
        (uint256[] memory prices, uint256 total) = bulk.registerQuote(_arr(NAME3, NAME5, V2_NAME), _durations(3), USDC);
        assertGt(prices[0], prices[1], "3-char costs more than 5+");
        assertGt(prices[1], 0);
        assertEq(prices[2], 0, "registered name quotes 0");
        assertEq(total, prices[0] + prices[1]);

        (uint256 base, uint256 premium) = REGISTRAR.getRegisterPrice(NAME5, DURATION, USDC);
        assertEq(prices[1], base + premium);
    }

    function test_registerQuote_tooShortDurationQuotesZero() public view {
        uint64[] memory d = new uint64[](1);
        d[0] = 1 days;
        (uint256[] memory prices, uint256 total) = bulk.registerQuote(_arr(NAME5), d, USDC);
        assertEq(prices[0], 0);
        assertEq(total, 0);
    }

    function test_renewQuote_routesV1AndV2() public view {
        (uint256[] memory prices, uint256 total, uint256[] memory bitmap) =
            bulk.renewQuote(_arr(V2_NAME, V1_NAME, NAME5), _durations(3), USDC);
        assertEq(prices[0], REGISTRAR.getRenewPrice(V2_NAME, DURATION, USDC));
        assertEq(prices[1], RENEWER_V1.getRenewPrice(V1_NAME, DURATION, USDC));
        assertEq(prices[2], 0, "unregistered name quotes 0");
        assertEq(total, prices[0] + prices[1]);
        assertEq(bitmap.length, 1);
        assertEq(bitmap[0], 1 << 1, "only index 1 routes to RENEWER_V1");
    }

    function test_renewQuote_bitmapSpansWords() public view {
        uint256 n = 300;
        string[] memory labels = new string[](n);
        for (uint256 i = 0; i < n; i++) {
            labels[i] = V2_NAME;
        }
        labels[257] = V1_NAME;
        (,, uint256[] memory bitmap) = bulk.renewQuote(labels, _durations(n), USDC);
        assertEq(bitmap.length, 2);
        assertEq(bitmap[0], 0);
        assertEq(bitmap[1], 1 << 1);
    }

    function test_makeCommitments_matchesRegistrar() public view {
        bytes32[] memory c = bulk.makeCommitments(_arr(NAME5), user, _durations(1), SECRET, address(0), RESOLVER);
        assertEq(c[0], REGISTRAR.makeCommitment(NAME5, user, SECRET, address(0), RESOLVER, DURATION, REFERRER));
    }

    function test_lengthMismatch_reverts() public {
        vm.expectRevert(BulkRegistrationV2.LengthMismatch.selector);
        bulk.registerQuote(_arr(NAME3, NAME4), _durations(1), USDC);

        vm.expectRevert(BulkRegistrationV2.LengthMismatch.selector);
        vm.prank(user);
        bulk.multiRenew(_arr(V2_NAME), _durations(2), new uint256[](0), USDC, 0);
    }

    // ------------------------------------------------------------------------------------
    // Register
    // ------------------------------------------------------------------------------------

    function test_multiCommit_recordsCommitments() public {
        bytes32[] memory c = bulk.makeCommitments(_arr(NAME3, NAME4), user, _durations(2), SECRET, address(0), RESOLVER);
        vm.prank(user);
        bulk.multiCommit(c);
        assertEq(REGISTRAR.commitmentAt(c[0]), block.timestamp);
        assertEq(REGISTRAR.commitmentAt(c[1]), block.timestamp);
    }

    function test_multiRegister_mixedLengths() public {
        string[] memory labels = _arr(NAME3, NAME4, NAME5);
        _commitAndWait(labels);
        (, uint256 total) = bulk.registerQuote(labels, _durations(3), USDC);

        uint256 userBefore = USDC.balanceOf(user);
        uint256 beneficiaryBefore = USDC.balanceOf(BENEFICIARY);
        uint256[] memory ids = _register(labels, total);

        for (uint256 i = 0; i < 3; i++) {
            assertTrue(ids[i] != 0);
            assertEq(ETH_REGISTRY.ownerOf(ids[i]), user);
            assertEq(ETH_REGISTRY.getExpiry(ids[i]), block.timestamp + DURATION);
        }
        assertEq(userBefore - USDC.balanceOf(user), total);
        assertEq(USDC.balanceOf(BENEFICIARY) - beneficiaryBefore, total);
        assertEq(USDC.balanceOf(address(bulk)), 0);
    }

    function test_multiRegister_refundsOverpayment() public {
        string[] memory labels = _arr(NAME5);
        _commitAndWait(labels);
        (, uint256 total) = bulk.registerQuote(labels, _durations(1), USDC);

        uint256 userBefore = USDC.balanceOf(user);
        _register(labels, total + 50e6);
        assertEq(userBefore - USDC.balanceOf(user), total);
        assertEq(USDC.balanceOf(address(bulk)), 0);
    }

    function test_multiRegister_skipsFailuresAndRefunds() public {
        // NAME3 committed; V2_NAME is taken; NAME4 never committed
        _commitAndWait(_arr(NAME3, V2_NAME));
        string[] memory labels = _arr(NAME3, V2_NAME, NAME4);
        (uint256[] memory prices,) = bulk.registerQuote(_arr(NAME3, NAME4), _durations(2), USDC);
        uint256 maxAmount = prices[0] + prices[1];

        uint256 userBefore = USDC.balanceOf(user);
        vm.recordLogs();
        uint256[] memory ids = _register(labels, maxAmount);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(ids[0] != 0);
        assertEq(ids[1], 0);
        assertEq(ids[2], 0);
        assertEq(_countFailures(logs, BulkRegistrationV2.NameRegistrationFailed.selector), 2);
        assertEq(userBefore - USDC.balanceOf(user), prices[0], "only the successful name is paid for");
        assertEq(USDC.balanceOf(address(bulk)), 0);
    }

    function test_multiRegister_failureEventCarriesReason() public {
        _commitAndWait(_arr(NAME5));
        // register NAME5 for someone else first so ours fails with NameNotAvailable
        string[] memory labels = _arr(NAME5);
        (, uint256 total) = bulk.registerQuote(labels, _durations(1), USDC);
        _register(labels, total);

        _commitAndWait(labels); // fresh commitment (the old one was consumed)
        vm.expectEmit(true, false, false, true, address(bulk));
        emit BulkRegistrationV2.NameRegistrationFailed(
            0, NAME5, abi.encodeWithSelector(bytes4(keccak256("NameNotAvailable(string)")), NAME5)
        );
        _register(labels, total);
    }

    function test_multiRegister_underfundedLaterNamesFail() public {
        string[] memory labels = _arr(NAME5, NAME4);
        _commitAndWait(labels);
        (uint256[] memory prices,) = bulk.registerQuote(labels, _durations(2), USDC);

        uint256[] memory ids = _register(labels, prices[0]); // only enough for the first
        assertTrue(ids[0] != 0);
        assertEq(ids[1], 0);
        assertEq(USDC.balanceOf(address(bulk)), 0);
    }

    function test_multiRegister_withDAI() public {
        string[] memory labels = _arr(NAME5);
        _commitAndWait(labels);
        (, uint256 total) = bulk.registerQuote(labels, _durations(1), DAI);
        (, uint256 totalUsdc) = bulk.registerQuote(labels, _durations(1), USDC);
        assertApproxEqRel(total, totalUsdc * 1e12, 1e12, "DAI quote ~ USDC quote scaled by decimals");

        uint256 before = DAI.balanceOf(user);
        vm.prank(user);
        uint256[] memory ids = bulk.multiRegister(labels, user, _durations(1), SECRET, address(0), RESOLVER, DAI, total);
        assertTrue(ids[0] != 0);
        assertEq(before - DAI.balanceOf(user), total);
    }

    function test_multiRegisterWithPermit() public {
        string[] memory labels = _arr(NAME5);
        _commitAndWait(labels);
        (, uint256 total) = bulk.registerQuote(labels, _durations(1), USDC);

        vm.prank(user);
        USDC.approve(address(bulk), 0);
        BulkRegistrationV2.Permit memory p = _signPermit(USDC, total, block.timestamp + 1 hours);

        vm.prank(user);
        uint256[] memory ids = bulk.multiRegisterWithPermit(labels, user, _durations(1), SECRET, address(0), RESOLVER, USDC, total, p);
        assertTrue(ids[0] != 0);
        assertEq(ETH_REGISTRY.ownerOf(ids[0]), user);
    }

    function test_multiRegisterWithPermit_frontRunPermitStillWorks() public {
        string[] memory labels = _arr(NAME5);
        _commitAndWait(labels);
        (, uint256 total) = bulk.registerQuote(labels, _durations(1), USDC);

        vm.prank(user);
        USDC.approve(address(bulk), 0);
        BulkRegistrationV2.Permit memory p = _signPermit(USDC, total, block.timestamp + 1 hours);

        // attacker submits the permit first
        (bool ok,) = address(USDC)
            .call(
                abi.encodeWithSignature(
                    "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)", user, address(bulk), total, p.deadline, p.v, p.r, p.s
                )
            );
        assertTrue(ok);

        vm.prank(user);
        uint256[] memory ids = bulk.multiRegisterWithPermit(labels, user, _durations(1), SECRET, address(0), RESOLVER, USDC, total, p);
        assertTrue(ids[0] != 0);
    }

    function test_multiRegisterWithPermit_badSignatureReverts() public {
        string[] memory labels = _arr(NAME5);
        _commitAndWait(labels);
        (, uint256 total) = bulk.registerQuote(labels, _durations(1), USDC);

        vm.prank(user);
        USDC.approve(address(bulk), 0);
        BulkRegistrationV2.Permit memory p = _signPermit(USDC, total - 1, block.timestamp + 1 hours); // wrong value

        vm.prank(user);
        vm.expectRevert(); // ERC20InsufficientAllowance on the pull
        bulk.multiRegisterWithPermit(labels, user, _durations(1), SECRET, address(0), RESOLVER, USDC, total, p);
    }

    // ------------------------------------------------------------------------------------
    // Renew
    // ------------------------------------------------------------------------------------

    function test_multiRenew_mixedV1AndV2() public {
        string[] memory labels = _arr(V2_NAME, V1_NAME, V1_NAME2);
        (, uint256 total, uint256[] memory bitmap) = bulk.renewQuote(labels, _durations(3), USDC);

        uint64 v2Before = ETH_REGISTRY.getExpiry(_id(V2_NAME));
        uint64 v1Before = ETH_REGISTRY.getExpiry(_id(V1_NAME));
        uint256 v1BaseBefore = BASE_REGISTRAR.nameExpires(_id(V1_NAME));
        uint256 userBefore = USDC.balanceOf(user);

        vm.prank(user);
        bool[] memory ok = bulk.multiRenew(labels, _durations(3), bitmap, USDC, total);

        assertTrue(ok[0] && ok[1] && ok[2]);
        assertEq(ETH_REGISTRY.getExpiry(_id(V2_NAME)), v2Before + DURATION);
        assertEq(ETH_REGISTRY.getExpiry(_id(V1_NAME)), v1Before + DURATION);
        assertEq(BASE_REGISTRAR.nameExpires(_id(V1_NAME)), v1BaseBefore + DURATION, "v1 BaseRegistrar extended too");
        assertEq(userBefore - USDC.balanceOf(user), total);
        assertEq(USDC.balanceOf(address(bulk)), 0);
    }

    function test_multiRenew_emptyBitmapMeansAllV2() public {
        string[] memory labels = _arr(V2_NAME);
        (, uint256 total,) = bulk.renewQuote(labels, _durations(1), USDC);
        vm.prank(user);
        bool[] memory ok = bulk.multiRenew(labels, _durations(1), new uint256[](0), USDC, total);
        assertTrue(ok[0]);
    }

    function test_multiRenew_misroutedNameFailsAndRefunds() public {
        string[] memory labels = _arr(V2_NAME, V1_NAME);
        (uint256[] memory prices, uint256 total,) = bulk.renewQuote(labels, _durations(2), USDC);

        uint256 userBefore = USDC.balanceOf(user);
        vm.recordLogs();
        vm.prank(user);
        // empty bitmap sends V1_NAME to the ETHRegistrar, which rejects RESERVED names
        bool[] memory ok = bulk.multiRenew(labels, _durations(2), new uint256[](0), USDC, total);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(ok[0]);
        assertFalse(ok[1]);
        assertEq(_countFailures(logs, BulkRegistrationV2.NameRenewalFailed.selector), 1);
        assertEq(userBefore - USDC.balanceOf(user), prices[0]);
        assertEq(USDC.balanceOf(address(bulk)), 0);
    }

    function test_multiRenewWithPermit() public {
        string[] memory labels = _arr(V2_NAME, V1_NAME);
        (, uint256 total, uint256[] memory bitmap) = bulk.renewQuote(labels, _durations(2), USDC);

        vm.prank(user);
        USDC.approve(address(bulk), 0);
        BulkRegistrationV2.Permit memory p = _signPermit(USDC, total, block.timestamp + 1 hours);

        vm.prank(user);
        bool[] memory ok = bulk.multiRenewWithPermit(labels, _durations(2), bitmap, USDC, total, p);
        assertTrue(ok[0] && ok[1]);
    }

    /// @dev Whatever the gas limit, the batch either reverts or every name succeeds:
    ///      an out-of-gas renewal must never be reported as a per-name failure.
    function test_multiRenew_lowGasNeverReportsFalseFailure() public {
        string[] memory labels = _arr(V2_NAME, V1_NAME, V1_NAME2);
        (, uint256 total, uint256[] memory bitmap) = bulk.renewQuote(labels, _durations(3), USDC);
        bytes memory data = abi.encodeCall(bulk.multiRenew, (labels, _durations(3), bitmap, USDC, total));

        for (uint256 g = 100_000; g <= 700_000; g += 25_000) {
            uint256 snap = vm.snapshotState();
            vm.prank(user);
            (bool success, bytes memory ret) = address(bulk).call{gas: g}(data);
            if (success) {
                bool[] memory ok = abi.decode(ret, (bool[]));
                for (uint256 i = 0; i < ok.length; i++) {
                    assertTrue(ok[i], "OOG reported as name failure");
                }
            }
            vm.revertToState(snap);
        }
    }

    /// @dev With a large gas limit, an inner call that runs out of gas still leaves 1/64 of the
    ///      gas, enough to finish the batch. The guard must revert rather than report a failure.
    function test_multiRenew_innerOutOfGasRevertsBatch() public {
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = USDC;
        GasBurningRenewer burner = new GasBurningRenewer();
        BulkRegistrationV2 b =
            new BulkRegistrationV2(REGISTRAR, IETHRenewer(address(burner)), REFERRER, ENS(ENS_REGISTRY), address(this), tokens);
        uint256[] memory bitmap = new uint256[](1);
        bitmap[0] = 1;

        vm.prank(user);
        vm.expectRevert(BulkRegistrationV2.InsufficientGas.selector);
        b.multiRenew{gas: 5_000_000}(_arr(V1_NAME), _durations(1), bitmap, USDC, 0);
    }
}
