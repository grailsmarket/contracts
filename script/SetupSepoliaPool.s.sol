// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {Script, console} from "forge-std/Script.sol";
import {SepoliaETHPool} from "./SepoliaETHPool.sol";

/**
 * @dev Creates (if needed) and funds the hook-free ETH/MockUSDC 0.05% pool on Sepolia that
 *      GrailsETHRouter swaps through. Run before DeployETHRouter.s.sol, and again to add liquidity.
 *
 *      Env: SENDER (broadcasting wallet; receives the position NFT).
 *      Optional: POOL_ETH (wei, default 0.3 ether), USDC_PER_ETH (initial price, default 2500;
 *      ignored if the pool already exists).
 *
 *      forge script script/SetupSepoliaPool.s.sol --rpc-url sepolia --account <keystore> --broadcast
 */
contract SetupSepoliaPool is Script, SepoliaETHPool {
    function run() external {
        require(block.chainid == 11155111, "Sepolia only");
        address sender = vm.envAddress("SENDER");
        uint256 ethAmount = vm.envOr("POOL_ETH", uint256(0.3 ether));
        uint256 usdcPerEth = vm.envOr("USDC_PER_ETH", uint256(2500));

        vm.startBroadcast(sender);
        (uint128 liquidity, uint256 usdcAmount) = _seedSepoliaPool(sender, usdcPerEth, ethAmount);
        vm.stopBroadcast();

        console.log("Added liquidity:", liquidity);
        console.log("ETH (max, excess swept back):", ethAmount);
        console.log("MockUSDC minted and added:", usdcAmount);
    }
}
