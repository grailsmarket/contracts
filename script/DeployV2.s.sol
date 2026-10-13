// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {ENS} from "ens-contracts/registry/ENS.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BulkRegistrationV2} from "../src/BulkRegistrationV2.sol";
import {IETHRegistrarV2, IETHRenewer} from "../src/IETHRegistrarV2.sol";

/**
 * @dev Env: DEPLOYER, REFERRER (bytes32). On mainnet also ETH_REGISTRAR_V2 and ETH_RENEWER_V1,
 *      since ENS has not published mainnet v2 addresses yet. Sepolia defaults to the
 *      contracts-v2 `deployments/sepolia` addresses unless those env vars are set.
 */
contract DeployV2 is Script {
    address constant ENS_REGISTRY = 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e;

    address constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant MAINNET_DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    address constant SEPOLIA_REGISTRAR = 0xf633e7FC17e2bbE0D0965D18ec1821dcB754a3d3;
    address constant SEPOLIA_RENEWER_V1 = 0xf2ece44980778966b8a0FccB3A9E339440f6e045;
    address constant SEPOLIA_USDC = 0x240b0316Df57887DBBE58b586508b19e633a14aa; // MockUSDC
    address constant SEPOLIA_DAI = 0xF6faC8A58a0BE13b9197f27C41B73162Fe32572b; // MockDAI

    function run() external {
        address deployer = vm.envAddress("DEPLOYER");
        bytes32 referrer = vm.envBytes32("REFERRER");

        address registrar;
        address renewerV1;
        IERC20[] memory tokens = new IERC20[](2);
        if (block.chainid == 1) {
            registrar = vm.envAddress("ETH_REGISTRAR_V2");
            renewerV1 = vm.envAddress("ETH_RENEWER_V1");
            tokens[0] = IERC20(MAINNET_USDC);
            tokens[1] = IERC20(MAINNET_DAI);
        } else if (block.chainid == 11155111) {
            registrar = vm.envOr("ETH_REGISTRAR_V2", SEPOLIA_REGISTRAR);
            renewerV1 = vm.envOr("ETH_RENEWER_V1", SEPOLIA_RENEWER_V1);
            tokens[0] = IERC20(SEPOLIA_USDC);
            tokens[1] = IERC20(SEPOLIA_DAI);
        } else {
            revert("unsupported chain");
        }

        vm.startBroadcast(deployer);
        new BulkRegistrationV2(IETHRegistrarV2(registrar), IETHRenewer(renewerV1), referrer, ENS(ENS_REGISTRY), deployer, tokens);
        vm.stopBroadcast();
    }
}
