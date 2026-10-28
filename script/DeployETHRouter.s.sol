// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Script, console} from "forge-std/Script.sol";
import {ENS} from "ens-contracts/registry/ENS.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {GrailsETHRouter} from "../src/GrailsETHRouter.sol";
import {BulkRegistrationV2} from "../src/BulkRegistrationV2.sol";

/**
 * @dev Deploys GrailsETHRouter in front of the chain's BulkRegistrationV2, swapping through the
 *      hook-free native ETH/USDC 0.05% Uniswap v4 pool. On Sepolia, run SetupSepoliaPool.s.sol
 *      first (the constructor reverts if the pool doesn't exist).
 *
 *      Env: DEPLOYER (also claims the router's reverse ENS name). Optional: BULK (override).
 *
 *      forge script script/DeployETHRouter.s.sol --rpc-url <sepolia|mainnet> --account <keystore> --broadcast --verify
 */
contract DeployETHRouter is Script {
    address constant ENS_REGISTRY = 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e;
    uint24 constant POOL_FEE = 500;
    int24 constant POOL_TICK_SPACING = 10;

    address constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant MAINNET_BULK = 0x438edcB58703dfB2e1D4Bb5E54a280E75A95ad90;
    address constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant SEPOLIA_BULK = 0x3C549e0FFdD3951afB95B7be97bf4D844d8C3244;
    address constant SEPOLIA_USDC = 0x240b0316Df57887DBBE58b586508b19e633a14aa; // MockUSDC

    function run() external {
        address deployer = vm.envAddress("DEPLOYER");

        address poolManager;
        address bulk;
        address usdc;
        if (block.chainid == 1) {
            (poolManager, bulk, usdc) = (MAINNET_POOL_MANAGER, MAINNET_BULK, MAINNET_USDC);
        } else if (block.chainid == 11155111) {
            (poolManager, bulk, usdc) = (SEPOLIA_POOL_MANAGER, SEPOLIA_BULK, SEPOLIA_USDC);
        } else {
            revert("unsupported chain");
        }
        bulk = vm.envOr("BULK", bulk);

        vm.startBroadcast(deployer);
        GrailsETHRouter router = new GrailsETHRouter(
            IPoolManager(poolManager), BulkRegistrationV2(bulk), IERC20(usdc), POOL_FEE, POOL_TICK_SPACING, ENS(ENS_REGISTRY), deployer
        );
        vm.stopBroadcast();

        console.log("GrailsETHRouter:", address(router));
    }
}
