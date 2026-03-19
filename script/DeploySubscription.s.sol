// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {ENS} from "ens-contracts/registry/ENS.sol";
import {GrailsSubscription} from "../src/GrailsSubscription.sol";
import {GrailsPricing, AggregatorInterface} from "../src/GrailsPricing.sol";
import {IGrailsPricing} from "../src/IGrailsPricing.sol";

contract DeploySubscription is Script {
    function run() external {
        address ens = 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e;

        address chainlinkOracle;
        if (block.chainid == 1) {
            chainlinkOracle = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
        } else if (block.chainid == 11155111) {
            chainlinkOracle = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
        } else {
            revert("Unsupported chain");
        }

        // ~$10/month tier
        uint256 tier1Rate = 3_858_024_691_358;
        // ~$30/month tier
        uint256 tier2Rate = 11_574_074_074_074;
        // ~$50/month tier (placeholder — adjust to final gold price)
        uint256 tier3Rate = 19_290_123_456_790;

        address deployer = vm.envAddress("DEPLOYER");

        vm.startBroadcast(deployer);

        GrailsPricing pricing = new GrailsPricing(AggregatorInterface(chainlinkOracle), deployer);
        pricing.setTierPrice(1, tier1Rate);
        pricing.setTierPrice(2, tier2Rate);
        pricing.setTierPrice(3, tier3Rate);

        new GrailsSubscription(IGrailsPricing(address(pricing)), ENS(ens), deployer);

        vm.stopBroadcast();
    }
}
