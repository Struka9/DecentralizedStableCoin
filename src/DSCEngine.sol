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
import {OracleLib} from "./lib/OracleLib.sol";

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
    error DSCEngine_UserNotLiquidatable();
    error DSCEngine_HealthFactorNotImproved();

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

        bool foundToken = false;
        for (uint256 i = 0; i < s_collateralAddresses.length; i++) {
            if (s_collateralAddresses[i] == _tokenAddress) {
                foundToken = true;
                break;
            }
        }
        if (!foundToken) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    // Types
    using OracleLib for AggregatorV3Interface;

    // State variables
    mapping(address token => address priceFeed) s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_userToCollateralDeposited;
    mapping(address user => uint256 dscMinted) s_userToDscMinted;
    address[] private s_collateralAddresses;
    DecentralizedStableCoin private immutable i_dsc;

    uint256 public constant ADDITIONAL_PRECISION = 10e10;
    uint256 public constant PRECISION = 10e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;
    uint256 public constant LIQUIDATION_PRECISION = 100;
    uint256 public constant MIN_HEALTH_FACTOR = 10e18;
    uint256 public constant LIQUIDATION_BONUS = 10; // This means a 10% bonus

    // Events
    event CollateralDeposited(address indexed user, address indexed collateralTokenAddress, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amountOfCollateral
    );

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

    ///// External Functions
    /**
     *
     * @param _collateralToken The token address to redeem
     * @param _amountOfCollateral The amount of collateral to redeem
     * @notice The health factor must be more than 1 AFTER the collateral has been pulled out.
     */
    function redeemCollateral(address _collateralToken, uint256 _amountOfCollateral)
        public
        nonReentrant
        moreThanZero(_amountOfCollateral)
    {
        _redeemCollateral(msg.sender, msg.sender, _collateralToken, _amountOfCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * This functions burns DSC, reducing user's debt.
     * @param _amountOfDsc The amount of DSC to burn
     */
    function burnDsc(uint256 _amountOfDsc) public moreThanZero(_amountOfDsc) {
        _burnDsc(msg.sender, msg.sender, _amountOfDsc);
    }

    /**
     *
     * @param _user The user who has broken the health factor, who will get liquidated.
     * @param _collateralToken T
     * @param _debtToCover The amount of DSC to improve user's health factor.
     * @notice You can partially liquidate a user, you get a liquidation bonus for paying off user's debt.
     */
    function liquidate(address _user, address _collateralToken, uint256 _debtToCover)
        external
        nonReentrant
        moreThanZero(_debtToCover)
        isAllowedToken(_collateralToken)
    {
        uint256 startingUserHealthFactor = _healthFactor(_user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine_UserNotLiquidatable();
        }

        uint256 collateralAmountFromDebtCovered = getTokenAmountFromUsd(_collateralToken, _debtToCover);
        uint256 bonusCollateral = collateralAmountFromDebtCovered * LIQUIDATION_BONUS / LIQUIDATION_PRECISION;
        uint256 totalCollateral = collateralAmountFromDebtCovered + bonusCollateral;

        _redeemCollateral(_user, msg.sender, _collateralToken, totalCollateral);
        _burnDsc(_user, msg.sender, _debtToCover);
        uint256 endingUserHealthFactor = _healthFactor(_user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine_HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function redeemCollateralForDsc(address _collateralToken, uint256 _amountOfCollateral, uint256 _amountOfDsc)
        external
    {
        burnDsc(_amountOfDsc);
        redeemCollateral(_collateralToken, _amountOfCollateral);
    }

    //// Public Functions
    function depositCollateralAndMintDsc(address _collateralToken, uint256 _amountOfCollateral, uint256 _amountDsc)
        public
    {
        depositCollateral(_collateralToken, _amountOfCollateral);
        mintDsc(_amountDsc);
    }
    /**
     *
     * @param _collateralTokenAddress The address of the token to use as collateral.
     * @param _amountOfCollateral The amount of collateral to deposit.
     */

    function depositCollateral(address _collateralTokenAddress, uint256 _amountOfCollateral)
        public
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
    function mintDsc(uint256 _amountDsct) public nonReentrant moreThanZero(_amountDsct) {
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
            (collateralValueInUsd * PRECISION * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        if (totalDscMinted == 0) return type(uint256).max;
        return (collateralValueAdjustedForThreshold) / totalDscMinted;
    }

    function _redeemCollateral(address _from, address _to, address _collateralToken, uint256 _amountOfCollateral)
        internal
        moreThanZero(_amountOfCollateral)
    {
        s_userToCollateralDeposited[_from][_collateralToken] -= _amountOfCollateral;
        bool success = IERC20(_collateralToken).transfer(_to, _amountOfCollateral);
        if (!success) {
            // Hypotetically unreachable
            revert DSCEngine__TransferFailed();
        }
        emit CollateralRedeemed(_from, _to, _collateralToken, _amountOfCollateral);
    }

    /**
     *
     * @param _from The account we are burning DSC from
     * @param _amountOfDsc The amount of DSC to burn
     * @dev Low level burn function
     */
    function _burnDsc(address _onBehalfOf, address _from, uint256 _amountOfDsc) private moreThanZero(_amountOfDsc) {
        s_userToDscMinted[_onBehalfOf] -= _amountOfDsc;
        bool success = i_dsc.transferFrom(_from, address(this), _amountOfDsc);
        if (!success) {
            // Hypotetically unreachable
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(_amountOfDsc);
    }

    // Public view & pure functions
    /**
     * Returns the amount of a given token deposited as collateral by the user.
     * @param _account The user that deposited collateral
     * @param _collateralAddress The token deposited
     */
    function getDepositedCollateral(address _account, address _collateralAddress) public view returns (uint256) {
        return s_userToCollateralDeposited[_account][_collateralAddress];
    }

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
        (, int256 price,,,) = priceFeed.checkForStalePrices();
        return (uint256(price) * _amount * ADDITIONAL_PRECISION) / PRECISION;
    }

    function getTokenAmountFromUsd(address _collateral, uint256 _tokenAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[_collateral]);
        (, int256 answer,,,) = priceFeed.checkForStalePrices();
        uint256 price = uint256(answer) * ADDITIONAL_PRECISION;
        return _tokenAmountInWei * PRECISION / price;
    }

    function getAccountInformation(address _user) external view returns (uint256 dscMinted, uint256 collateralInUsd) {
        (dscMinted, collateralInUsd) = _getAccountInformation(_user);
    }

    function healthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getAllowedCollateral() external view returns (address[] memory) {
        return s_collateralAddresses;
    }
}
