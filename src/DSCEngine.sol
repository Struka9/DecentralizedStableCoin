// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Oscar Flores
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */
contract DSCEngine is ReentrancyGuard {
    // Errors
    error DSCEngine__MustBeMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustHaveSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorBroken();
    error DSCEngine__MintFailed();

    // Modifiers
    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) {
            revert DSCEngine__MustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address _tokenAddress) {
        if (address(0) == _tokenAddress) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    // State variables
    mapping(address token => address priceFeed) s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_userToCollateralDeposited;
    mapping(address user => uint256 dscMinted) s_userToDscMinted;
    address[] private s_collateralAddresses;
    DecentralizedStableCoin private immutable i_dsc;

    uint256 private constant ADDITIONAL_PRECISION = 10e10;
    uint256 private constant PRECISION = 10e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    // Events
    event CollateralDeposited(address indexed user, address indexed collateralTokenAddress, uint256 indexed amount);

    // Functions
    constructor(address[] memory _tokenAddresses, address[] memory _priceFeedAddresses, address _dscAddress) {
        if (_tokenAddresses.length != _priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustHaveSameLength();
        }

        for (uint256 i = 0; i < _tokenAddresses.length; i++) {
            s_priceFeeds[_tokenAddresses[i]] = _priceFeedAddresses[i];
            s_collateralAddresses.push(_tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(_dscAddress);
    }

    //// External Functions
    /**
     *
     * @param _collateralTokenAddress The address of the token to use as collateral.
     * @param _amountOfCollateral The amount of collateral to deposit.
     */
    function depositCollateral(address _collateralTokenAddress, uint256 _amountOfCollateral)
        external
        moreThanZero(_amountOfCollateral)
        isAllowedToken(_collateralTokenAddress)
        nonReentrant
    {
        s_userToCollateralDeposited[msg.sender][_collateralTokenAddress] += _amountOfCollateral;
        emit CollateralDeposited(msg.sender, _collateralTokenAddress, _amountOfCollateral);
        bool success = IERC20(_collateralTokenAddress).transferFrom(msg.sender, address(this), _amountOfCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     *
     * @param _amountDsct The amount of DSC to mint, must have enough collateral deposited.
     */
    function mintDsc(uint256 _amountDsct) external nonReentrant moreThanZero(_amountDsct) {
        s_userToDscMinted[msg.sender] += _amountDsct;
        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, _amountDsct);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    // Internal & private view functions
    function _revertIfHealthFactorIsBroken(address _user) private view {
        uint256 userHealthFactor = _healthFactor(_user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorBroken();
        }
    }
    /**
     *
     * @param _user The user to check.
     * @return dscMinted The total amount of DSC minted by _user.
     * @return collateralInUsd The total amount of collateral in USD deposited by _user.
     */

    function _getAccountInformation(address _user) private view returns (uint256 dscMinted, uint256 collateralInUsd) {
        dscMinted = s_userToDscMinted[_user];
        collateralInUsd = getAccountCollateral(_user);
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralValueAdjustedForThreshold =
            (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralValueAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    // Public view & pure functions
    /**
     * Returns the value of the account's deposited collateral in USD.
     * @param _account The account to get the collateral value of.
     * @return  valueOfCollateral
     */
    function getAccountCollateral(address _account) public view returns (uint256 valueOfCollateral) {
        // Loop through the collateral
        for (uint256 i = 0; i < s_collateralAddresses.length; i++) {
            address token = s_collateralAddresses[i];
            uint256 collateralAmount = s_userToCollateralDeposited[_account][token];
            valueOfCollateral += getCollateralUsdValue(token, collateralAmount);
        }
    }

    /**
     * Returns the value in USD of _amount of the _token passed.
     * @param _token The address of the token to get the value of.
     * @param _amount The amount of the token to get the value of.
     */
    function getCollateralUsdValue(address _token, uint256 _amount) public view returns (uint256 priceInUsd) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[_token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (uint256(price) * _amount * ADDITIONAL_PRECISION) / PRECISION;
    }
}
