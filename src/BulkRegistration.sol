// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17 <0.9.0;

import {ENS} from "ens-contracts/registry/ENS.sol";
import {ReverseClaimer} from "ens-contracts/reverseRegistrar/ReverseClaimer.sol";
import {IPriceOracle} from "ens-contracts/ethregistrar/IPriceOracle.sol";
import {IETHRegistrarController} from "./IETHRegistrarController.sol";

contract BulkRegistration is ReverseClaimer {
    IETHRegistrarController public immutable controller;
    bytes32 public immutable referrer;

    event NameRegistered(
        string name, bytes32 indexed labelHash, address indexed owner, uint256 cost, uint256 duration, bytes32 indexed referrer
    );

    error InsufficientFunds();
    error RefundFailed();

    constructor(address _controller, bytes32 _referrer, ENS _ens, address _owner) ReverseClaimer(_ens, _owner) {
        controller = IETHRegistrarController(_controller);
        referrer = _referrer;
    }

    /// @notice Check availability of multiple names
    function available(string[] calldata names) external view returns (bool[] memory) {
        bool[] memory results = new bool[](names.length);
        for (uint256 i = 0; i < names.length; i++) {
            results[i] = controller.available(names[i]);
        }
        return results;
    }

    /// @notice Get rent prices for multiple names
    function rentPrices(string[] calldata names, uint256 duration) external view returns (uint256[] memory) {
        uint256[] memory prices = new uint256[](names.length);
        for (uint256 i = 0; i < names.length; i++) {
            IPriceOracle.Price memory price = controller.rentPrice(names[i], duration);
            prices[i] = price.base + price.premium;
        }
        return prices;
    }

    /// @notice Get total price for registering multiple names
    function totalPrice(string[] calldata names, uint256 duration) external view returns (uint256) {
        uint256 total;
        for (uint256 i = 0; i < names.length; i++) {
            IPriceOracle.Price memory price = controller.rentPrice(names[i], duration);
            total += price.base + price.premium;
        }
        return total;
    }

    /// @notice Generate commitments for multiple names
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

    /// @notice Submit multiple commitments
    function multiCommit(bytes32[] calldata commitments) external {
        for (uint256 i = 0; i < commitments.length; i++) {
            controller.commit(commitments[i]);
        }
    }

    /// @notice Register multiple names in a single transaction
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

    /// @notice Accept ETH (needed for controller refunds)
    receive() external payable {}
}
