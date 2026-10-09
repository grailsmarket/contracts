// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Minimal subset of the ENSv2 `IETHRenewer` interface.
 * @dev Implemented by both `ETHRegistrar` (REGISTERED names) and `ETHRenewerV1`
 *      (RESERVED, i.e. pre-migrated but unmigrated v1 names).
 *      https://github.com/ensdomains/contracts-v2/blob/main/contracts/src/registrar/interfaces/IETHRenewer.sol
 */
interface IETHRenewer {
    function renew(string calldata label, uint64 duration, IERC20 paymentToken, bytes32 referrer) external;

    function getRenewPrice(string calldata label, uint64 duration, IERC20 paymentToken) external view returns (uint256);

    function isRenewable(string calldata label) external view returns (bool);
}

/**
 * @notice Minimal subset of the ENSv2 `IETHRegistrar` interface.
 * @dev `subregistry` is typed as `address` here; it is ABI-identical to `IRegistry`.
 *      https://github.com/ensdomains/contracts-v2/blob/main/contracts/src/registrar/interfaces/IETHRegistrar.sol
 */
interface IETHRegistrarV2 is IETHRenewer {
    function commit(bytes32 commitment) external;

    function register(
        string calldata label,
        address owner,
        bytes32 secret,
        address subregistry,
        address resolver,
        uint64 duration,
        IERC20 paymentToken,
        bytes32 referrer
    ) external returns (uint256 tokenId);

    function commitmentAt(bytes32 commitment) external view returns (uint64);

    function getRegisterPrice(string calldata label, uint64 duration, IERC20 paymentToken)
        external
        view
        returns (uint256 base, uint256 premium);

    function isAvailable(string calldata label) external view returns (bool);

    function makeCommitment(
        string calldata label,
        address owner,
        bytes32 secret,
        address subregistry,
        address resolver,
        uint64 duration,
        bytes32 referrer
    ) external pure returns (bytes32);
}
