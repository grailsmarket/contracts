// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {ENS} from "ens-contracts/registry/ENS.sol";
import {GrailsSubscription} from "../src/GrailsSubscription.sol";

contract DeploySubscription is Script {
    function run() external {
        address ens = 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e;

        if (block.chainid != 1 && block.chainid != 11155111) {
            revert("Unsupported chain");
        }

        // uint256 pricePerDay = vm.envUint("PRICE_PER_DAY");
        uint256 pricePerDay = 273972602739726;
        address deployer = vm.envAddress("DEPLOYER");

        vm.startBroadcast(deployer);
        new GrailsSubscription(pricePerDay, ENS(ens), deployer);
        vm.stopBroadcast();
    }
}
