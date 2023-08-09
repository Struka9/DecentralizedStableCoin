// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {Script} from "forge-std/Script.sol";

contract HelperConfig is Script {
    int256 public constant BTC_INITIAL_PRICE = 30000e8;
    int256 public constant ETH_INITIAL_PRICE = 1840e8;
    uint8 public constant DECIMAL_PLACES = 8;
    uint256 public constant DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    struct NetworkConfig {
        address wethAddress;
        address wbtcAddress;
        address ethPriceFeedAddress;
        address btcPriceFeedAddress;
        uint256 deployerKey;
    }

    NetworkConfig public activeNetworkConfig;

    constructor() {
        if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilConfig();
        }
    }

    function getOrCreateAnvilConfig() internal returns (NetworkConfig memory) {
        if (activeNetworkConfig.wethAddress != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();
        MockV3Aggregator btcPriceFeed = new MockV3Aggregator(DECIMAL_PLACES, BTC_INITIAL_PRICE);
        ERC20Mock wbtcMock = new ERC20Mock();
        MockV3Aggregator ethPriceFeed = new MockV3Aggregator(DECIMAL_PLACES, ETH_INITIAL_PRICE);
        ERC20Mock wethMock = new ERC20Mock();
        vm.stopBroadcast();
        return NetworkConfig({
            ethPriceFeedAddress: address(ethPriceFeed),
            btcPriceFeedAddress: address(btcPriceFeed),
            wethAddress: address(wethMock),
            wbtcAddress: address(wbtcMock),
            deployerKey: DEFAULT_ANVIL_KEY
        });
    }

    function getSepoliaConfig() internal view returns (NetworkConfig memory) {
        return NetworkConfig({
            ethPriceFeedAddress: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            btcPriceFeedAddress: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43,
            wethAddress: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81,
            wbtcAddress: 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063,
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }
}
