// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {ENS} from "ens-contracts/registry/ENS.sol";
import {BulkRegistration} from "../src/BulkRegistration.sol";

contract Deploy is Script {
    function run() external {
        address controller = 0x59E16fcCd424Cc24e280Be16E11Bcd56fb0CE547;
        address ens = 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e;

        address deployer = vm.envAddress("DEPLOYER");
        // bytes32 referrer = vm.envBytes32("REFERRER");
        bytes32 referrer = 0x0000000000000000000000007e491cde0fbf08e51f54c4fb6b9e24afbd18966d;

        vm.startBroadcast(deployer);
        new BulkRegistration(controller, referrer, ENS(ens), deployer);
        vm.stopBroadcast();
    }
}
