// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {Test, console} from "forge-std/Test.sol";

contract TestDecentralizedStableCoin is Test {
    event Transfer(address indexed from, address indexed to, uint256 value);

    address BOB = makeAddr("Bob");
    DecentralizedStableCoin instance;

    function setUp() public {
        instance = new DecentralizedStableCoin();
    }

    function testCannotMintZero() external {
        vm.expectRevert(
            DecentralizedStableCoin
                .DecentralizedStableCoin__MustBeMoreThanZero
                .selector
        );
        instance.mint(address(this), 0);
    }

    function testCannotMintToZeroAddress() external {
        vm.expectRevert(
            DecentralizedStableCoin
                .DecentralizedStableCoin__NotZeroAddress
                .selector
        );
        instance.mint(address(0), 100);
    }

    function testMint() external {
        uint256 amountToMint = 10;
        vm.expectEmit(true, true, true, false);
        emit Transfer(address(0), BOB, amountToMint);
        bool result = instance.mint(BOB, amountToMint);
        assert(result);
    }

    function testCannotBurnZeroOrLess() external {
        vm.expectRevert(
            DecentralizedStableCoin
                .DecentralizedStableCoin__MustBeMoreThanZero
                .selector
        );
        instance.burn(0);
    }

    function testCannotBurnMoreThanBalance() external {
        vm.expectRevert(
            DecentralizedStableCoin
                .DecentralizedStableCoin__BurnAmountExceedsBalance
                .selector
        );
        instance.burn(1);
    }

    function testEmitEventOnBurn() external {
        uint256 amountToBurn = 10;
        instance.mint(address(this), amountToBurn);
        vm.expectEmit(true, true, true, false);
        emit Transfer(address(this), address(0), amountToBurn);
        instance.burn(amountToBurn);
    }
}
