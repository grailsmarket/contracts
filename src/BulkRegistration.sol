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
 * @notice Batch registration contract for ENS .eth names via the wrapped ETHRegistrarController.
 *         Supports mixed-length names (3, 4, 5+ chars) with different prices in a single transaction.
 *         Excess ETH is automatically refunded to the caller.
 */
contract BulkRegistration is ReverseClaimer {
    /**
     * @notice The wrapped ETHRegistrarController used for all registration operations
     */
    IETHRegistrarController public immutable controller;

    /**
     * @notice Referrer identifier emitted with every registration event for tracking
     */
    bytes32 public immutable referrer;

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
     * @notice Thrown when msg.value is less than the total registration cost
     */
    error InsufficientFunds();

    /**
     * @notice Thrown when the ETH refund to the caller fails
     */
    error RefundFailed();

    /**
     * @param _controller Address of the wrapped ETHRegistrarController
     * @param _referrer Referrer identifier (bytes32-padded address) for tracking
     * @param _ens Address of the ENS registry (for reverse resolution)
     * @param _owner Address to claim reverse ENS ownership for this contract
     */
    constructor(address _controller, bytes32 _referrer, ENS _ens, address _owner) ReverseClaimer(_ens, _owner) {
        controller = IETHRegistrarController(_controller);
        referrer = _referrer;
    }

    /**
     * @notice Check availability of multiple names in a single call
     * @param names Array of ENS labels to check (without .eth suffix)
     * @return Array of booleans indicating availability for each name
     */
    function available(string[] calldata names) external view returns (bool[] memory) {
        bool[] memory results = new bool[](names.length);
        for (uint256 i = 0; i < names.length; i++) {
            results[i] = controller.available(names[i]);
        }
        return results;
    }

    /**
     * @notice Get individual rent prices for multiple names
     * @param names Array of ENS labels to price
     * @param duration Registration duration in seconds
     * @return Array of prices in wei (base + premium) for each name
     */
    function rentPrices(string[] calldata names, uint256 duration) external view returns (uint256[] memory) {
        uint256[] memory prices = new uint256[](names.length);
        for (uint256 i = 0; i < names.length; i++) {
            IPriceOracle.Price memory price = controller.rentPrice(names[i], duration);
            prices[i] = price.base + price.premium;
        }
        return prices;
    }

    /**
     * @notice Get the total price for registering multiple names
     * @param names Array of ENS labels to price
     * @param duration Registration duration in seconds
     * @return Total price in wei for all names combined
     */
    function totalPrice(string[] calldata names, uint256 duration) external view returns (uint256) {
        uint256 total;
        for (uint256 i = 0; i < names.length; i++) {
            IPriceOracle.Price memory price = controller.rentPrice(names[i], duration);
            total += price.base + price.premium;
        }
        return total;
    }

    /**
     * @notice Generate commitment hashes for multiple names
     * @dev Commitments must be submitted via multiCommit() and waited on (60s) before registering
     * @param names Array of ENS labels to commit
     * @param owner Address that will own the registered names
     * @param duration Registration duration in seconds
     * @param secret Random bytes32 used to obscure the commitment
     * @param resolver Address of the resolver to set for each name
     * @param data Additional resolver data to set during registration
     * @param reverseRecord Whether to set a reverse record for the owner
     * @param ownerControlledFuses Fuses to burn on the NameWrapper token
     * @return Array of commitment hashes to pass to multiCommit()
     */
    function makeCommitments(
        string[] calldata names,
        address owner,
        uint256 duration,
        bytes32 secret,
        address resolver,
        bytes[] calldata data,
        bool reverseRecord,
        uint16 ownerControlledFuses
    ) external view returns (bytes32[] memory) {
        bytes32[] memory commitments = new bytes32[](names.length);
        for (uint256 i = 0; i < names.length; i++) {
            commitments[i] =
                controller.makeCommitment(names[i], owner, duration, secret, resolver, data, reverseRecord, ownerControlledFuses);
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
            controller.commit(commitments[i]);
        }
    }

    /**
     * @notice Register multiple names in a single transaction
     * @dev Requires commitments to have been submitted at least 60 seconds prior.
     *      Each name is priced individually, so mixed-length batches are supported.
     *      Any excess ETH is refunded to msg.sender after all registrations complete.
     * @param names Array of ENS labels to register
     * @param owner Address that will own the registered names
     * @param duration Registration duration in seconds
     * @param secret The same secret used when generating commitments
     * @param resolver Address of the resolver to set for each name
     * @param data Additional resolver data to set during registration
     * @param reverseRecord Whether to set a reverse record for the owner
     * @param ownerControlledFuses Fuses to burn on the NameWrapper token
     */
    function multiRegister(
        string[] calldata names,
        address owner,
        uint256 duration,
        bytes32 secret,
        address resolver,
        bytes[] calldata data,
        bool reverseRecord,
        uint16 ownerControlledFuses
    ) external payable {
        uint256 totalCost;

        for (uint256 i = 0; i < names.length; i++) {
            IPriceOracle.Price memory price = controller.rentPrice(names[i], duration);
            uint256 cost = price.base + price.premium;
            totalCost += cost;

            controller.register{value: cost}(names[i], owner, duration, secret, resolver, data, reverseRecord, ownerControlledFuses);

            emit NameRegistered(names[i], keccak256(bytes(names[i])), owner, cost, duration, referrer);
        }

        if (msg.value < totalCost) revert InsufficientFunds();

        if (address(this).balance > 0) {
            (bool success,) = payable(msg.sender).call{value: address(this).balance}("");
            if (!success) revert RefundFailed();
        }
    }

    /**
     * @notice Accept ETH transfers (needed to receive controller refunds during registration)
     */
    receive() external payable {}
}
