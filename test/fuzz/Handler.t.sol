// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract Handler is Test {
    DecentralizedStableCoin dsc;
    DSCEngine engine;

    address weth;
    address wbtc;

    uint256 public mintDscCalled = 0;

    uint256 constant MAX_DEPOSIT_SIZE = type(uint96).max;

    address[] usersWithCollateralDeposited;

    constructor(DSCEngine _engine, DecentralizedStableCoin _dsc) {
        engine = _engine;
        dsc = _dsc;

        address[] memory collateralTokens = engine.getAllowedCollateral();
        weth = collateralTokens[0];
        wbtc = collateralTokens[1];
    }

    function depositCollateral(uint256 _collateralSeed, uint256 _amountCollateral) public {
        address collateral = _getCollateralFromSeed(_collateralSeed);
        _amountCollateral = _bind(_amountCollateral, 1, MAX_DEPOSIT_SIZE);

        ERC20Mock collateralMock = ERC20Mock(collateral);

        vm.startPrank(msg.sender);
        collateralMock.mint(msg.sender, _amountCollateral);
        collateralMock.approve(address(engine), _amountCollateral);
        engine.depositCollateral(collateral, _amountCollateral);
        vm.stopPrank();

        // double push
        usersWithCollateralDeposited.push(msg.sender);
    }

    function redeemCollateral(uint256 _collateralSeed, uint256 _amountCollateral) public {
        address collateral = _getCollateralFromSeed(_collateralSeed);
        uint256 depositedCollateral = engine.getDepositedCollateral(msg.sender, collateral);
        if (depositedCollateral == 0) {
            return;
        }
        _amountCollateral = _bind(_amountCollateral, 0.01 ether, depositedCollateral);
        vm.startPrank(msg.sender);
        engine.redeemCollateral(collateral, _amountCollateral);
        vm.stopPrank();
    }

    function mintDsc(uint256 _amountDscToMint, uint256 _userSeed) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        address sender = usersWithCollateralDeposited[_userSeed % usersWithCollateralDeposited.length];
        _amountDscToMint = _bind(_amountDscToMint, 1, MAX_DEPOSIT_SIZE);
        (uint256 mintedDsc, uint256 collateralValueUsd) = engine.getAccountInformation(sender);
        mintDscCalled++;
        int256 check = int256(collateralValueUsd / 2) - int256(mintedDsc + _amountDscToMint);
        if (check < 0) {
            return;
        }
        vm.startPrank(sender);
        engine.mintDsc(_amountDscToMint);
        vm.stopPrank();
    }

    function _getCollateralFromSeed(uint256 _collateralSeed) private view returns (address) {
        if (_collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }

    function _bind(uint256 _amount, uint256 _min, uint256 _max) private pure returns (uint256) {
        if (_amount > _max) return _max;
        if (_amount <= _min) return _min;
        return _amount;
    }
}
