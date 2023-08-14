// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {DeployDecentralizedStableCoin} from "../script/DeployDecentralizedStableCoin.s.sol";
import {HelperConfig} from "../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";

contract TestDSCEngine is Test {
    DSCEngine engine;
    DecentralizedStableCoin dsc;
    HelperConfig helperConfig;

    address wethAddress;
    address wbtcAddress;
    address wbtcPriceFeed;
    address wethPriceFeed;

    uint256 USER_INITIAL_WETH_BALANCE = 10 ether;

    uint256 USER_INITIAL_COLLATERAL_DEPOSIT = 2 ether;
    uint256 USER_INITIAL_MINTED_DSC = 100 ether;

    address USER = makeAddr("user");
    address LIQUIDATOR = makeAddr("liquidator");

    modifier depositedWeth() {
        ERC20Mock mock = ERC20Mock(wethAddress);
        vm.startPrank(USER);
        mock.approve(address(engine), USER_INITIAL_COLLATERAL_DEPOSIT);
        engine.depositCollateral(wethAddress, USER_INITIAL_COLLATERAL_DEPOSIT);
        vm.stopPrank();
        _;
    }

    modifier mintedDsc() {
        vm.startPrank(USER);
        engine.mintDsc(USER_INITIAL_MINTED_DSC);
        vm.stopPrank();
        _;
    }

    function setUp() external {
        DeployDecentralizedStableCoin deploy = new DeployDecentralizedStableCoin();
        (engine, dsc, helperConfig) = deploy.run();
        (wethAddress, wbtcAddress, wethPriceFeed, wbtcPriceFeed,) = helperConfig.activeNetworkConfig();
        ERC20Mock(wethAddress).mint(USER, USER_INITIAL_WETH_BALANCE);
    }

    ///////////////////////////////////
    // Price tests////////////////////
    //////////////////////////////////
    function testGetUsdInCollateral() public {
        uint256 usd = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        assertEq(expectedWeth, engine.getTokenAmountFromUsd(wethAddress, usd));
    }

    function testGetCollateralValue() public {
        uint256 tokenAmount = 5;
        uint256 wethExpectedValue =
            uint256(helperConfig.ETH_INITIAL_PRICE()) * engine.ADDITIONAL_PRECISION() / engine.PRECISION() * tokenAmount;

        uint256 wethValue = engine.getCollateralUsdValue(wethAddress, tokenAmount);
        assertEq(wethValue, wethExpectedValue);
    }

    ///////////////////////////////////
    // Constructor tests//////////////
    //////////////////////////////////
    address[] priceFeedAddresses;
    address[] tokenAddresses;

    function testRevertIfPriceFeedLengthDoesntMatchTokenLength() public {
        tokenAddresses.push(wethAddress);
        tokenAddresses.push(wbtcAddress);
        priceFeedAddresses.push(wethPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustHaveSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    ////////////////////////////
    // Health Factor tests/////
    //////////////////////////
    function testHealthFactor() public depositedWeth {
        uint256 expectedHealthFactor = type(uint256).max;
        uint256 actualHealthFactor = engine.healthFactor(USER);
        assertEq(expectedHealthFactor, actualHealthFactor);

        vm.prank(USER);
        engine.mintDsc(100 ether);

        expectedHealthFactor = 20 * 10e18;
        assertEq(expectedHealthFactor, engine.healthFactor(USER));
    }

    function testDepositAndMint() public {
        vm.startPrank(USER);
        ERC20Mock(wethAddress).approve(address(engine), 2 ether);
        engine.depositCollateralAndMintDsc(wethAddress, 2 ether, 100 ether);
        uint256 expectedHF = 20 * 10e18;
        uint256 actualHF = engine.healthFactor(USER);
        assertEq(expectedHF, actualHF);
        vm.stopPrank();
    }

    //////////////////////////////
    // Deposit Collateral tests///
    //////////////////////////////
    function testRevertIfCollateralIsZero() public {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        engine.depositCollateral(wethAddress, 0);
    }

    function testRevertIfNotAllowedToken() public {
        ERC20Mock ranToken = new ERC20Mock();
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        engine.depositCollateral(address(ranToken), 10e2);
    }

    function testRevertIfUserHasNoEnoughTokens() public {
        vm.prank(USER);
        vm.expectRevert("ERC20: insufficient allowance");
        engine.depositCollateral(wethAddress, 10e2);
    }

    function testUserCollateralIncreaseOnDeposit() public depositedWeth {
        uint256 expectedValue = 2000 * USER_INITIAL_COLLATERAL_DEPOSIT; // User deposited collateral * eth price (2000 usd in our tests)

        (uint256 dscMinted, uint256 collateralValue) = engine.getAccountInformation(USER);
        assertEq(expectedValue, collateralValue);
        assertEq(dscMinted, 0);
    }

    function testWeGotTheCollateral() public depositedWeth {
        ERC20Mock mock = ERC20Mock(wethAddress);
        uint256 collateralBalanceOfEngine = mock.balanceOf(address(engine));
        assertEq(collateralBalanceOfEngine, USER_INITIAL_COLLATERAL_DEPOSIT);
    }

    event CollateralDeposited(address indexed user, address indexed collateralTokenAddress, uint256 indexed amount);

    function testEmitDepositEvent() public {
        ERC20Mock mock = ERC20Mock(wethAddress);
        vm.startPrank(USER);
        mock.approve(address(engine), USER_INITIAL_COLLATERAL_DEPOSIT);

        vm.expectEmit(true, true, true, false);
        emit CollateralDeposited(USER, wethAddress, USER_INITIAL_COLLATERAL_DEPOSIT);

        engine.depositCollateral(wethAddress, USER_INITIAL_COLLATERAL_DEPOSIT);
        vm.stopPrank();
    }

    ///////////////////////////////
    // Redeem Collateral tests////
    //////////////////////////////
    function testRedeemRevertsWhenZero() public depositedWeth {
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        vm.prank(USER);
        engine.redeemCollateral(wethAddress, 0);
    }

    function testCollateralRedeemed() public depositedWeth {
        uint256 initialCollateralBalance = ERC20Mock(wethAddress).balanceOf(USER);
        vm.startPrank(USER);
        engine.redeemCollateral(wethAddress, USER_INITIAL_COLLATERAL_DEPOSIT);
        vm.stopPrank();

        uint256 expectedCollateralBalance = initialCollateralBalance + USER_INITIAL_COLLATERAL_DEPOSIT;
        assertEq(expectedCollateralBalance, ERC20Mock(wethAddress).balanceOf(USER));
    }

    function testRedeemRevertsWhenMoreThanDeposited() public depositedWeth {
        vm.expectRevert();
        vm.prank(USER);
        engine.redeemCollateral(wethAddress, USER_INITIAL_COLLATERAL_DEPOSIT + 1 ether);
    }

    function testRedeemRevertsIfHealthFactorIsBroken() public depositedWeth {
        vm.startPrank(USER);
        engine.mintDsc(USER_INITIAL_MINTED_DSC);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorBroken.selector);
        engine.redeemCollateral(wethAddress, USER_INITIAL_COLLATERAL_DEPOSIT);
        vm.stopPrank();
    }

    ///////////////////////////////
    // Burn DSC tests/////////////
    //////////////////////////////
    function testBurnDsc() public depositedWeth mintedDsc {
        uint256 initialTotalSupply = dsc.totalSupply();
        assertEq(USER_INITIAL_MINTED_DSC, dsc.balanceOf(USER));

        vm.startPrank(USER);
        dsc.approve(address(engine), USER_INITIAL_MINTED_DSC);
        engine.burnDsc(USER_INITIAL_MINTED_DSC);
        vm.stopPrank();

        uint256 expectedTotalSupply = initialTotalSupply - USER_INITIAL_MINTED_DSC;
        uint256 actualSupply = dsc.totalSupply();
        assertEq(expectedTotalSupply, actualSupply);
        assertEq(0, dsc.balanceOf(USER));
    }

    ////////////////////////////////
    //Liquidate tests//////////////
    ///////////////////////////////
    function testCannotLiquidateSolventUsers() public depositedWeth mintedDsc {
        vm.startPrank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine_UserNotLiquidatable.selector);
        engine.liquidate(USER, wethAddress, USER_INITIAL_MINTED_DSC);
        vm.stopPrank();
    }

    function testLiquidateMoreThanZero() public depositedWeth mintedDsc {
        vm.startPrank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        engine.liquidate(USER, wethAddress, 0);
        vm.stopPrank();
    }

    function testLiquidateOnlyAllowedTokens() public depositedWeth mintedDsc {
        ERC20Mock ranToken = new ERC20Mock();
        vm.startPrank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        engine.liquidate(USER, address(ranToken), USER_INITIAL_COLLATERAL_DEPOSIT);
        vm.stopPrank();
    }

    // function testLiquidateRevertIfLiquidatorsHealthFactorIsBroken() public depositedWeth mintedDsc {
    //     MockV3Aggregator aggregator = MockV3Aggregator(wethPriceFeed);

    //     uint256 userMint = 900 ether; // Want the user to get a 'liquidatable' state
    //     vm.prank(USER);
    //     engine.mintDsc(userMint);
    //     console.log("user hf = %d", engine.healthFactor(USER));

    //     // Update the answer to be half the value
    //     aggregator.updateAnswer(900e8); // Half the initial answer
    //     console.log("user hf = %d", engine.healthFactor(USER));

    //     uint256 initialLiquidatorWeth = 0.05 ether; // Not enough to pay for USER's debt
    //     ERC20Mock mock = ERC20Mock(wethAddress);

    //     vm.startPrank(LIQUIDATOR);
    //     mock.mint(LIQUIDATOR, initialLiquidatorWeth);
    //     mock.approve(address(engine), initialLiquidatorWeth);
    //     engine.depositCollateral(wethAddress, initialLiquidatorWeth);
    //     dsc.approve(address(engine), 100 ether);
    //     vm.expectRevert(DSCEngine.DSCEngine__HealthFactorBroken.selector);
    //     engine.liquidate(USER, wethAddress, 100 ether);
    //     vm.stopPrank();
    // }
}
