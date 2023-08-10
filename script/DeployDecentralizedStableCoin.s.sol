// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";
import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../src/DSCEngine.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployDecentralizedStableCoin is Script {
    address[] tokenAddresses;
    address[] priceFeedAddresses;

    function run() external returns (DSCEngine, DecentralizedStableCoin, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();
        (address wethAddress, address wbtcAddress, address wethPriceFeed, address wbtcPriceFeed, uint256 deployerKey) =
            helperConfig.activeNetworkConfig();

        tokenAddresses = [wethAddress, wbtcAddress];
        priceFeedAddresses = [wethPriceFeed, wbtcPriceFeed];

        vm.startBroadcast(deployerKey);
        DecentralizedStableCoin dscInstance = new DecentralizedStableCoin();
        DSCEngine engine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dscInstance));
        dscInstance.transferOwnership(address(engine));
        vm.stopBroadcast();
        return (engine, dscInstance, helperConfig);
    }
}
