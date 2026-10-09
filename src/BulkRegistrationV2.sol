// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {ENS} from "ens-contracts/registry/ENS.sol";
import {ReverseClaimer} from "ens-contracts/reverseRegistrar/ReverseClaimer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IETHRegistrarV2, IETHRenewer} from "./IETHRegistrarV2.sol";

/**
 * @custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVM MEVM
 * @title BulkRegistrationV2
 * @author 0xthrpw
 * @notice Batch registration and renewal of ENSv2 .eth names, paid in ERC20 stablecoins.
 *         Registrations go through the v2 `ETHRegistrar`. Renewals are routed per name to
 *         either the `ETHRegistrar` (REGISTERED names) or `ETHRenewerV1` (RESERVED names that
 *         were pre-migrated from v1 but not yet migrated).
 *
 *         Pricing lives entirely in the view functions. A write pulls a caller-supplied
 *         `maxAmount` once, lets the registrar pull each name's exact price, and refunds
 *         whatever is left (unused quote headroom plus the share of any failed names).
 *
 *         Individual failures do not revert the batch: they are reported in the return value
 *         and via `NameRegistrationFailed` / `NameRenewalFailed`. Successes are reported by the
 *         registrar's own `NameRegistered` / `NameRenewed` events, which carry `REFERRER`.
 */
contract BulkRegistrationV2 is ReverseClaimer, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /**
     * @notice EIP-2612 permit signature, signed for `value = maxAmount` and `spender = this`
     */
    struct Permit {
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /**
     * @notice The ENSv2 ETHRegistrar used for commits, registrations and REGISTERED renewals
     */
    IETHRegistrarV2 public immutable REGISTRAR;

    /**
     * @notice The ENSv2 ETHRenewerV1 used for renewals of RESERVED (unmigrated v1) names
     */
    IETHRenewer public immutable RENEWER_V1;

    /**
     * @notice Referrer identifier passed to the registrar with every registration and renewal
     */
    bytes32 public immutable REFERRER;

    /**
     * @notice Emitted when a registration in a batch reverts and is skipped
     * @param index Position of the name in the `labels` array
     * @param label The ENS label that failed
     * @param reason Raw revert data from the registrar
     */
    event NameRegistrationFailed(uint256 indexed index, string label, bytes reason);

    /**
     * @notice Emitted when a renewal in a batch reverts and is skipped
     * @param index Position of the name in the `labels` array
     * @param label The ENS label that failed
     * @param reason Raw revert data from the renewer
     */
    event NameRenewalFailed(uint256 indexed index, string label, bytes reason);

    /**
     * @notice Thrown when `labels` and `durations` have different lengths
     */
    error LengthMismatch();

    /**
     * @notice Thrown when a registrar call ran out of gas, so the batch is not silently truncated
     */
    error InsufficientGas();

    /**
     * @param registrar Address of the ENSv2 ETHRegistrar
     * @param renewerV1 Address of the ENSv2 ETHRenewerV1
     * @param referrer Referrer identifier (bytes32-padded address) for tracking
     * @param ens Address of the ENS registry (for reverse resolution)
     * @param owner Address to claim reverse ENS ownership for this contract
     * @param tokens Payment tokens to pre-approve for the registrar and renewer
     */
    constructor(IETHRegistrarV2 registrar, IETHRenewer renewerV1, bytes32 referrer, ENS ens, address owner, IERC20[] memory tokens)
        ReverseClaimer(ens, owner)
    {
        REGISTRAR = registrar;
        RENEWER_V1 = renewerV1;
        REFERRER = referrer;
        for (uint256 i = 0; i < tokens.length; i++) {
            _approve(tokens[i]);
        }
    }

    /**
     * @notice Grant the registrar and renewer a max allowance for `token`
     * @dev Permissionless: this contract holds no balance between transactions, so the
     *      allowance only ever covers funds a caller is spending in the same call. Use it
     *      when ENS adds a payment token after deployment.
     * @param token The payment token to approve
     */
    function approveToken(IERC20 token) external {
        _approve(token);
    }

    // ------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------

    /**
     * @notice Check availability of multiple names in a single call
     * @param labels Array of ENS labels to check (without .eth suffix)
     * @return Array of booleans indicating availability for each name
     */
    function available(string[] calldata labels) external view returns (bool[] memory) {
        bool[] memory results = new bool[](labels.length);
        for (uint256 i = 0; i < labels.length; i++) {
            results[i] = REGISTRAR.isAvailable(labels[i]);
        }
        return results;
    }

    /**
     * @notice Quote registration prices for multiple names
     * @dev Names that cannot be registered (unavailable, invalid, duration too short or
     *      unsupported token) are quoted as 0 instead of reverting the whole call.
     *      Premiums only decay, so passing `total` as `maxAmount` shortly after is safe.
     * @param labels Array of ENS labels to price
     * @param durations Registration duration in seconds for each name
     * @param token The payment token
     * @return prices Per-name price (base + premium) in `token` units, 0 if not registrable
     * @return total Sum of `prices`, to pass as `maxAmount`
     */
    function registerQuote(string[] calldata labels, uint64[] calldata durations, IERC20 token)
        external
        view
        returns (uint256[] memory prices, uint256 total)
    {
        uint256 n = labels.length;
        if (durations.length != n) revert LengthMismatch();
        prices = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            try REGISTRAR.getRegisterPrice(labels[i], durations[i], token) returns (uint256 base, uint256 premium) {
                prices[i] = base + premium;
                total += base + premium;
            } catch {}
        }
    }

    /**
     * @notice Quote renewal prices for multiple names and work out which renewer each uses
     * @dev Names renewable by neither contract are quoted as 0 instead of reverting.
     * @param labels Array of ENS labels to price
     * @param durations Renewal duration in seconds for each name
     * @param token The payment token
     * @return prices Per-name price in `token` units, 0 if not renewable
     * @return total Sum of `prices`, to pass as `maxAmount`
     * @return v1Bitmap Bit `i` set means name `i` renews via `RENEWER_V1`; pass to `multiRenew`
     */
    function renewQuote(string[] calldata labels, uint64[] calldata durations, IERC20 token)
        external
        view
        returns (uint256[] memory prices, uint256 total, uint256[] memory v1Bitmap)
    {
        uint256 n = labels.length;
        if (durations.length != n) revert LengthMismatch();
        prices = new uint256[](n);
        v1Bitmap = new uint256[]((n + 255) >> 8);
        for (uint256 i = 0; i < n; i++) {
            try REGISTRAR.getRenewPrice(labels[i], durations[i], token) returns (uint256 price) {
                prices[i] = price;
            } catch {
                try RENEWER_V1.getRenewPrice(labels[i], durations[i], token) returns (uint256 price) {
                    prices[i] = price;
                    v1Bitmap[i >> 8] |= 1 << (i & 255);
                } catch {}
            }
            total += prices[i];
        }
    }

    /**
     * @notice Generate commitment hashes for multiple names
     * @dev Commitments must be submitted via multiCommit() and must age past the registrar's
     *      MIN_COMMITMENT_AGE (and not past MAX_COMMITMENT_AGE) before registering.
     * @param labels Array of ENS labels to commit
     * @param owner Address that will own the registered names
     * @param durations Registration duration in seconds for each name
     * @param secret Random bytes32 used to obscure the commitment
     * @param subregistry Initial subregistry for each name (address(0) for none)
     * @param resolver Initial resolver for each name
     * @return commitments Array of commitment hashes to pass to multiCommit()
     */
    function makeCommitments(
        string[] calldata labels,
        address owner,
        uint64[] calldata durations,
        bytes32 secret,
        address subregistry,
        address resolver
    ) external view returns (bytes32[] memory commitments) {
        uint256 n = labels.length;
        if (durations.length != n) revert LengthMismatch();
        commitments = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            commitments[i] = REGISTRAR.makeCommitment(labels[i], owner, secret, subregistry, resolver, durations[i], REFERRER);
        }
    }

    // ------------------------------------------------------------------------------------
    // Writes
    // ------------------------------------------------------------------------------------

    /**
     * @notice Submit multiple commitment hashes to the registrar
     * @param commitments Array of commitment hashes from makeCommitments()
     */
    function multiCommit(bytes32[] calldata commitments) external {
        for (uint256 i = 0; i < commitments.length; i++) {
            REGISTRAR.commit(commitments[i]);
        }
    }

    /**
     * @notice Register multiple names in a single transaction
     * @dev Requires a prior `token.approve(this, maxAmount)`. Pulls `maxAmount` once; the
     *      registrar pulls each name's exact price; the remainder is refunded to msg.sender.
     *      A name that reverts (e.g. taken, commitment missing or too new) is skipped and
     *      reported instead of reverting the batch.
     * @param labels Array of ENS labels to register
     * @param owner Address that will own the registered names
     * @param durations Registration duration in seconds for each name
     * @param secret The same secret used when generating commitments
     * @param subregistry Initial subregistry for each name (as committed)
     * @param resolver Initial resolver for each name (as committed)
     * @param token The payment token
     * @param maxAmount Amount of `token` to pull, e.g. `total` from registerQuote()
     * @return tokenIds Registered token ID per name, 0 where registration failed
     */
    function multiRegister(
        string[] calldata labels,
        address owner,
        uint64[] calldata durations,
        bytes32 secret,
        address subregistry,
        address resolver,
        IERC20 token,
        uint256 maxAmount
    ) external nonReentrant returns (uint256[] memory tokenIds) {
        return _multiRegister(labels, owner, durations, secret, subregistry, resolver, token, maxAmount);
    }

    /**
     * @notice multiRegister() with an EIP-2612 permit (e.g. USDC) instead of a prior approve
     * @dev The permit is attempted in a try/catch so a front-run permit does not block the
     *      call; if no allowance results, the token transfer reverts.
     * @param permit Signature over `permit(msg.sender, this, maxAmount, deadline)`
     */
    function multiRegisterWithPermit(
        string[] calldata labels,
        address owner,
        uint64[] calldata durations,
        bytes32 secret,
        address subregistry,
        address resolver,
        IERC20 token,
        uint256 maxAmount,
        Permit calldata permit
    ) external nonReentrant returns (uint256[] memory tokenIds) {
        _permit(token, maxAmount, permit);
        return _multiRegister(labels, owner, durations, secret, subregistry, resolver, token, maxAmount);
    }

    /**
     * @notice Renew multiple names in a single transaction
     * @dev Requires a prior `token.approve(this, maxAmount)`. A name that reverts (e.g. routed
     *      to the wrong renewer because it migrated after quoting) is skipped and reported.
     * @param labels Array of ENS labels to renew
     * @param durations Renewal duration in seconds for each name
     * @param v1Bitmap Renewer routing from renewQuote(); missing words are treated as 0
     * @param token The payment token
     * @param maxAmount Amount of `token` to pull, e.g. `total` from renewQuote()
     * @return renewed Per-name success flag
     */
    function multiRenew(string[] calldata labels, uint64[] calldata durations, uint256[] calldata v1Bitmap, IERC20 token, uint256 maxAmount)
        external
        nonReentrant
        returns (bool[] memory renewed)
    {
        return _multiRenew(labels, durations, v1Bitmap, token, maxAmount);
    }

    /**
     * @notice multiRenew() with an EIP-2612 permit (e.g. USDC) instead of a prior approve
     * @param permit Signature over `permit(msg.sender, this, maxAmount, deadline)`
     */
    function multiRenewWithPermit(
        string[] calldata labels,
        uint64[] calldata durations,
        uint256[] calldata v1Bitmap,
        IERC20 token,
        uint256 maxAmount,
        Permit calldata permit
    ) external nonReentrant returns (bool[] memory renewed) {
        _permit(token, maxAmount, permit);
        return _multiRenew(labels, durations, v1Bitmap, token, maxAmount);
    }

    // ------------------------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------------------------

    function _multiRegister(
        string[] calldata labels,
        address owner,
        uint64[] calldata durations,
        bytes32 secret,
        address subregistry,
        address resolver,
        IERC20 token,
        uint256 maxAmount
    ) internal returns (uint256[] memory tokenIds) {
        uint256 n = labels.length;
        if (durations.length != n) revert LengthMismatch();
        token.safeTransferFrom(msg.sender, address(this), maxAmount);
        tokenIds = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            tokenIds[i] = _registerOne(i, labels[i], owner, durations[i], secret, subregistry, resolver, token);
        }
        _refund(token);
    }

    /**
     * @dev Registers a single name, returning 0 and emitting NameRegistrationFailed on revert.
     *      Extracted so the per-iteration locals live in a fresh stack frame.
     */
    function _registerOne(
        uint256 index,
        string calldata label,
        address owner,
        uint64 duration,
        bytes32 secret,
        address subregistry,
        address resolver,
        IERC20 token
    ) internal returns (uint256) {
        uint256 gasBefore = gasleft();
        try REGISTRAR.register(label, owner, secret, subregistry, resolver, duration, token, REFERRER) returns (uint256 tokenId) {
            return tokenId;
        } catch (bytes memory reason) {
            _checkGas(gasBefore);
            emit NameRegistrationFailed(index, label, reason);
            return 0;
        }
    }

    function _multiRenew(
        string[] calldata labels,
        uint64[] calldata durations,
        uint256[] calldata v1Bitmap,
        IERC20 token,
        uint256 maxAmount
    ) internal returns (bool[] memory renewed) {
        uint256 n = labels.length;
        if (durations.length != n) revert LengthMismatch();
        token.safeTransferFrom(msg.sender, address(this), maxAmount);
        renewed = new bool[](n);
        uint256 words = v1Bitmap.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 word = i >> 8;
            bool useV1 = word < words && (v1Bitmap[word] >> (i & 255)) & 1 == 1;
            renewed[i] = _renewOne(i, labels[i], durations[i], useV1 ? RENEWER_V1 : REGISTRAR, token);
        }
        _refund(token);
    }

    /**
     * @dev Renews a single name, returning false and emitting NameRenewalFailed on revert.
     */
    function _renewOne(uint256 index, string calldata label, uint64 duration, IETHRenewer renewer, IERC20 token) internal returns (bool) {
        uint256 gasBefore = gasleft();
        try renewer.renew(label, duration, token, REFERRER) {
            return true;
        } catch (bytes memory reason) {
            _checkGas(gasBefore);
            emit NameRenewalFailed(index, label, reason);
            return false;
        }
    }

    /**
     * @dev A call forwards at most 63/64 of the remaining gas. If at most 1/64 of `gasBefore`
     *      is left after it reverted, it almost certainly ran out of gas, so revert the whole
     *      batch rather than report a name as failed because of a low gas limit.
     */
    function _checkGas(uint256 gasBefore) internal view {
        if (gasleft() <= gasBefore / 64) revert InsufficientGas();
    }

    /**
     * @dev Attempt an EIP-2612 permit; ignore failure (it may have been front-run).
     */
    function _permit(IERC20 token, uint256 value, Permit calldata permit) internal {
        try IERC20Permit(address(token)).permit(msg.sender, address(this), value, permit.deadline, permit.v, permit.r, permit.s) {} catch {}
    }

    /**
     * @dev Return any `token` balance (quote headroom plus failed names) to msg.sender.
     */
    function _refund(IERC20 token) internal {
        uint256 balance = token.balanceOf(address(this));
        if (balance > 0) token.safeTransfer(msg.sender, balance);
    }

    function _approve(IERC20 token) internal {
        token.forceApprove(address(REGISTRAR), type(uint256).max);
        token.forceApprove(address(RENEWER_V1), type(uint256).max);
    }
}
