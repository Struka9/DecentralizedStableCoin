// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/**
 *
 * Invariants
 * 1. Total supply of DSC should be less than the total value of collateral
 * 2. Getter view functions should never revert
 */

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDecentralizedStableCoin} from "../../script/DeployDecentralizedStableCoin.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract InvariantsTest is StdInvariant, Test {
    DeployDecentralizedStableCoin deployer;
    DSCEngine engine;
    DecentralizedStableCoin dsc;
    HelperConfig helperConfig;

    address weth;
    address wbtc;

    Handler handler;

    function setUp() external {
        deployer = new DeployDecentralizedStableCoin();
        (engine, dsc, helperConfig) = deployer.run();
        (weth, wbtc,,,) = helperConfig.activeNetworkConfig();
        handler = new Handler(engine, dsc);
        targetContract(address(handler));
    }

    function invariant_testTotalDscSupplyShouldBeLessThanCollateralValue() external view {
        uint256 wethSupply = IERC20(weth).balanceOf(address(engine));
        uint256 wbtcSupply = IERC20(wbtc).balanceOf(address(engine));

        uint256 wethValue = engine.getCollateralUsdValue(weth, wethSupply);
        uint256 wbtcValue = engine.getCollateralUsdValue(wbtc, wbtcSupply);

        uint256 dscSupply = dsc.totalSupply();

        console.log("weth supply: %d", wethSupply);
        console.log("wbtc supply: %d", wbtcSupply);
        console.log("dsc supply: %d", dscSupply);

        assert(wethValue + wbtcValue >= dscSupply);
    }

    function invariant_testGetterFunctionsShouldNotRevert() external view {
        engine.getAccountCollateral(msg.sender);
        engine.getAccountInformation(msg.sender);
        engine.getAllowedCollateral();
        engine.getDepositedCollateral(msg.sender, weth);
        engine.getTokenAmountFromUsd(weth, 1 ether);
    }
}
