// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17 <0.9.0;

import {IPriceOracle} from "ens-contracts/ethregistrar/IPriceOracle.sol";

interface IETHRegistrarController {
    function rentPrice(string memory name, uint256 duration) external view returns (IPriceOracle.Price memory);

    function available(string memory name) external view returns (bool);

    function makeCommitment(
        string memory name,
        address owner,
        uint256 duration,
        bytes32 secret,
        address resolver,
        bytes[] calldata data,
        bool reverseRecord,
        uint16 ownerControlledFuses
    ) external pure returns (bytes32);

    function commit(bytes32 commitment) external;

    function register(
        string calldata name,
        address owner,
        uint256 duration,
        bytes32 secret,
        address resolver,
        bytes[] calldata data,
        bool reverseRecord,
        uint16 ownerControlledFuses
    ) external payable;
}
