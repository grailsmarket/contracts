// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {ENS} from "ens-contracts/registry/ENS.sol";
import {BulkRegistration} from "../src/BulkRegistration.sol";

contract Deploy is Script {
    function run() external {
        address controller;
        address ens = 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e;

        if (block.chainid == 1) {
            controller = 0x253553366Da8546fC250F225fe3d25d0C782303b;
        } else if (block.chainid == 11155111) {
            controller = 0xFED6a969AaA60E4961FCD3EBF1A2e8913ac65B72;
        } else {
            revert("Unsupported chain");
        }

        bytes32 referrer = vm.envBytes32("REFERRER");

        vm.startBroadcast();
        new BulkRegistration(controller, referrer, ENS(ens), msg.sender);
        vm.stopBroadcast();
    }
}
