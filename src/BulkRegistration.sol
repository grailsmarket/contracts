// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17 <0.9.0;

import {ENS} from "ens-contracts/registry/ENS.sol";
import {ReverseClaimer} from "ens-contracts/reverseRegistrar/ReverseClaimer.sol";
import {IPriceOracle} from "ens-contracts/ethregistrar/IPriceOracle.sol";
import {IETHRegistrarController} from "./IETHRegistrarController.sol";

/**
 * @custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVM MEVM
 * @title BulkRegistration
 * @author 0xthrpw
 * @notice Batch registration contract for ENS .eth names via the ETHRegistrarController.
 *         Supports mixed-length names (3, 4, 5+ chars) with different prices in a single transaction.
 *         Per-name resolver data allows setting distinct records for each name.
 *         Excess ETH is automatically refunded to the caller.
 */
contract BulkRegistration is ReverseClaimer {
    /**
     * @notice The ETHRegistrarController used for all registration operations
     */
    IETHRegistrarController public immutable CONTROLLER;

    /**
     * @notice Referrer identifier emitted with every registration event for tracking
     */
    bytes32 public immutable REFERRER;

    /**
     * @notice The namehash of the .eth TLD node
     */
    bytes32 private constant ETH_NODE = 0x93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae;

    /**
     * @notice Emitted for each name registered through this contract
     * @param name The ENS label registered (e.g. "example" for example.eth)
     * @param labelHash The keccak256 hash of the name, indexed for filtering
     * @param owner The address that owns the registered name
     * @param cost The ETH cost paid for this specific registration
     * @param duration The registration duration in seconds
     * @param referrer The referrer identifier set at deployment
     */
    event NameRegistered(
        string name, bytes32 indexed labelHash, address indexed owner, uint256 cost, uint256 duration, bytes32 indexed referrer
    );

    /**
     * @notice Thrown when the ETH refund to the caller fails
     */
    error RefundFailed();

    /**
     * @param _controller Address of the ETHRegistrarController
     * @param _referrer Referrer identifier (bytes32-padded address) for tracking
     * @param _ens Address of the ENS registry (for reverse resolution)
     * @param _owner Address to claim reverse ENS ownership for this contract
     */
    constructor(address _controller, bytes32 _referrer, ENS _ens, address _owner) ReverseClaimer(_ens, _owner) {
        CONTROLLER = IETHRegistrarController(_controller);
        REFERRER = _referrer;
    }

    /**
     * @dev Accept ETH so the controller can refund us mid-loop when a caller-supplied
     *      price exceeds the true rent (e.g. stale oracle quote). Anything that lands
     *      here is swept back to msg.sender at the end of multiRegister.
     */
    receive() external payable {}

    /**
     * @notice Check availability of multiple names in a single call
     * @param names Array of ENS labels to check (without .eth suffix)
     * @return Array of booleans indicating availability for each name
     */
    function available(string[] calldata names) external view returns (bool[] memory) {
        bool[] memory results = new bool[](names.length);
        for (uint256 i = 0; i < names.length; i++) {
            results[i] = CONTROLLER.available(names[i]);
        }
        return results;
    }

    /**
     * @notice Get individual rent prices for multiple names
     * @param names Array of ENS labels to price
     * @param durations Registration duration in seconds for each name
     * @return Array of prices in wei (base + premium) for each name
     */
    function rentPrices(string[] calldata names, uint256[] calldata durations) external view returns (uint256[] memory) {
        uint256[] memory prices = new uint256[](names.length);
        for (uint256 i = 0; i < names.length; i++) {
            prices[i] = _rentPrice(names[i], durations[i]);
        }
        return prices;
    }

    /**
     * @notice Get the total price for registering multiple names
     * @param names Array of ENS labels to price
     * @param durations Registration duration in seconds for each name
     * @return Total price in wei for all names combined
     */
    function totalPrice(string[] calldata names, uint256[] calldata durations) external view returns (uint256) {
        uint256 total;
        for (uint256 i = 0; i < names.length; i++) {
            total += _rentPrice(names[i], durations[i]);
        }
        return total;
    }

    /**
     * @notice Generate commitment hashes for multiple names
     * @dev Commitments must be submitted via multiCommit() and waited on (60s) before registering
     * @param names Array of ENS labels to commit
     * @param owner Address that will own the registered names
     * @param durations Registration duration in seconds for each name
     * @param secret Random bytes32 used to obscure the commitment
     * @param resolver Address of the resolver to set for each name
     * @param data Array of resolver data arrays, one per name (data[i] is applied to names[i])
     * @param reverseRecord Bitmask controlling reverse record behaviour
     * @return Array of commitment hashes to pass to multiCommit()
     */
    function makeCommitments(
        string[] calldata names,
        address owner,
        uint256[] calldata durations,
        bytes32 secret,
        address resolver,
        bytes[][] calldata data,
        uint8 reverseRecord
    ) external view returns (bytes32[] memory) {
        bytes32[] memory commitments = new bytes32[](names.length);
        for (uint256 i = 0; i < names.length; i++) {
            string calldata name = names[i];
            bytes32 labelHash = keccak256(bytes(name));
            commitments[i] = CONTROLLER.makeCommitment(
                IETHRegistrarController.Registration({
                    label: name,
                    owner: owner,
                    duration: durations[i],
                    secret: secret,
                    resolver: resolver,
                    data: _enrichData(labelHash, owner, data[i]),
                    reverseRecord: reverseRecord,
                    referrer: REFERRER
                })
            );
        }
        return commitments;
    }

    /**
     * @notice Submit multiple commitment hashes to the controller
     * @dev Wait at least 60 seconds after committing before calling multiRegister()
     * @param commitments Array of commitment hashes from makeCommitments()
     */
    function multiCommit(bytes32[] calldata commitments) external {
        for (uint256 i = 0; i < commitments.length; i++) {
            CONTROLLER.commit(commitments[i]);
        }
    }

    /**
     * @notice Register multiple names in a single transaction
     * @dev Requires commitments to have been submitted at least 60 seconds prior.
     *      Each name is priced individually, so mixed-length batches are supported.
     *      Any excess ETH is refunded to msg.sender after all registrations complete.
     *      Callers must supply `prices` (e.g. from `rentPrices()`); if `prices[i]` is
     *      below the true rent the controller reverts, and any over-pay is refunded
     *      by the controller back to this contract and then forwarded to msg.sender.
     * @param names Array of ENS labels to register
     * @param owner Address that will own the registered names
     * @param durations Registration duration in seconds for each name
     * @param prices Per-name price in wei (base + premium) — caller-supplied to avoid a second oracle query
     * @param secret The same secret used when generating commitments
     * @param resolver Address of the resolver to set for each name
     * @param data Array of resolver data arrays, one per name (data[i] is applied to names[i])
     * @param reverseRecord Bitmask controlling reverse record behaviour
     */
    function multiRegister(
        string[] calldata names,
        address owner,
        uint256[] calldata durations,
        uint256[] calldata prices,
        bytes32 secret,
        address resolver,
        bytes[][] calldata data,
        uint8 reverseRecord
    ) external payable {
        for (uint256 i = 0; i < names.length; i++) {
            _registerOne(names[i], owner, durations[i], prices[i], secret, resolver, data[i], reverseRecord);
        }

        // Refund any leftover: caller's overpayment plus any refund the controller sent
        // back when prices[i] exceeded the true rent (e.g. stale oracle quote).
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool success,) = payable(msg.sender).call{value: balance}("");
            if (!success) revert RefundFailed();
        }
    }

    /**
     * @dev Registers a single name and emits NameRegistered. Extracted from multiRegister
     *      so the per-iteration locals live in a fresh stack frame (avoids
     *      Yul-pipeline stack-too-deep with 8 caller-facing params).
     */
    function _registerOne(
        string calldata name,
        address owner,
        uint256 duration,
        uint256 cost,
        bytes32 secret,
        address resolver,
        bytes[] calldata data,
        uint8 reverseRecord
    ) internal {
        bytes32 labelHash = keccak256(bytes(name));
        CONTROLLER.register{value: cost}(
            IETHRegistrarController.Registration({
                label: name,
                owner: owner,
                duration: duration,
                secret: secret,
                resolver: resolver,
                data: _enrichData(labelHash, owner, data),
                reverseRecord: reverseRecord,
                referrer: REFERRER
            })
        );
        emit NameRegistered(name, labelHash, owner, cost, duration, REFERRER);
    }

    /**
     * @dev Prepend a setAddr(node, owner) call to the resolver data so that
     *      the ETH address record is always set during registration.
     * @param labelHash Pre-computed keccak256(bytes(label)) for the name
     * @param _owner The address to set as the ETH address record
     * @param originalData Caller-supplied resolver data entries
     * @return enriched A new array with the setAddr call at index 0 followed by originalData
     */
    function _enrichData(bytes32 labelHash, address _owner, bytes[] calldata originalData)
        internal
        pure
        returns (bytes[] memory enriched)
    {
        bytes32 node = keccak256(abi.encodePacked(ETH_NODE, labelHash));
        uint256 originalLen = originalData.length;
        enriched = new bytes[](originalLen + 1);
        enriched[0] = abi.encodeWithSignature("setAddr(bytes32,address)", node, _owner);
        if (originalLen == 0) return enriched;
        for (uint256 i = 0; i < originalLen; i++) {
            enriched[i + 1] = originalData[i];
        }
    }

    /**
     * @dev Get the total rent price (base + premium) for a single name
     * @param name The ENS label to price (without .eth suffix)
     * @param duration Registration duration in seconds
     * @return Total price in wei for the name
     */
    function _rentPrice(string calldata name, uint256 duration) internal view returns (uint256) {
        IPriceOracle.Price memory price = CONTROLLER.rentPrice(name, duration);
        return price.base + price.premium;
    }
}
