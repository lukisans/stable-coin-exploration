// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Fahmi Lukistriya
 * @notice Core contract of the Decentralized StableCoin (DSC) system.
 * Maintains a 1:1 USD peg using exogenous collateral (wETH, wBTC) with no governance or fees.
 * Ensures over-collateralization: collateral value always exceeds DSC's USD value.
 * Handles minting/redeeming DSC, depositing/withdrawing collateral, and liquidation.
 * Loosely inspired by MakerDAO's DAI system.
 */
contract DSCEngine is ReentrancyGuard {
    // ════════════════════════════════════════ ERRORS ════════════════════════════════════════
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAndPriceFeedArraysLengthMismatch();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);

    // ════════════════════════════════════════ STATE VARIABLES ════════════════════════════════════════
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10; // Adjusts price feed decimals
    uint256 private constant PRECISION = 1e18; // Standard precision for calculations
    uint256 private constant LIQUIDATION_TRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100; // Precision
    uint256 private constant MIN_HEALTF_FACTOR = 1;

    DecentralizedStableCoin private immutable i_dsc; // DSC token contract

    // ════════════════════════════════════════ EVENTS ════════════════════════════════════════
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    // ════════════════════════════════════════ MODIFIERS ════════════════════════════════════════
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) revert DSCEngine__NeedsMoreThanZero();
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) revert DSCEngine__TokenNotAllowed();
        _;
    }

    // ════════════════════════════════════════ CONSTRUCTOR ════════════════════════════════════════
    /**
     * @param tokenAddresses Array of collateral token addresses
     * @param priceFeedAddresses Array of corresponding price feed addresses
     * @param dscAddress Address of the DSC token contract
     * @notice Initializes token-price feed mappings and DSC contract
     */
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAndPriceFeedArraysLengthMismatch();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    // ════════════════════════════════════════ EXTERNAL FUNCTIONS ════════════════════════════════════════
    /**
     * @param tokenCollateralAddress Address of the collateral token
     * @param amountCollateral Amount of collateral to deposit
     * @notice Deposits collateral; requires valid token and non-zero amount
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) revert DSCEngine__TransferFailed();
    }

    /**
     * @param amountDscToMint Amount of DSC to mint
     * @notice Mints DSC; ensures user has sufficient collateral
     */
    function mintDsc(uint256 amountDscToMint) external moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function depositCollateralAndMintDsc() external {
        // TODO: Implement
    }

    function redeemCollateralForDsc() external {
        // TODO: Implement
    }

    function burnDsc() external {
        // TODO: Implement
    }

    function liquidate() external {
        // TODO: Implement
    }

    function getHealthFactor() external view {
        // TODO: Implement
    }

    // ════════════════════════════════════════ PUBLIC FUNCTIONS ════════════════════════════════════════
    /**
     * @param user Address to query
     * @return totalCollateralValueInUsd Total USD value of user's collateral
     * @notice Calculates total collateral value based on price feeds
     */
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
    }

    /**
     * @param token Address of the collateral token
     * @param amount Amount of token
     * @return USD value of the specified token amount
     * @notice Converts token amount to USD using Chainlink price feeds
     */
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    // ════════════════════════════════════════ PRIVATE FUNCTIONS ════════════════════════════════════════
    /**
     * @param user Address to query
     * @return totalDscMinted Total DSC minted by user
     * @return collateralValueInUsd Total USD value of user's collateral
     * @notice Retrieves account details for health factor calculations
     */
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * @param user Address to check
     * @return Health factor indicating liquidation risk
     * @notice Calculates how close a user is to liquidation
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralValueInUsdAjusted = (collateralValueInUsd * LIQUIDATION_TRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralValueInUsdAjusted * PRECISION) / totalDscMinted;
    }

    /**
     * @param user Address to check
     * @notice Reverts if user's health factor is below threshold
     */
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTF_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }
}
