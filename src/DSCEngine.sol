// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

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
    error DSCEngine__HealthFactorNotImproved();

    // false positive case, throw when check health factor when liquidate
    error DSCEngine__HealthFactorOk();

    // ════════════════════════════════════════ STATE VARIABLES ════════════════════════════════════════
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10; // Adjusts price feed decimals
    uint256 private constant PRECISION = 1e18; // Standard precision for calculations
    uint256 private constant LIQUIDATION_TRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100; // Precision
    uint256 private constant LIQUIDATION_BONUS = 10; // reward for securing protocol
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    DecentralizedStableCoin private immutable i_dsc; // DSC token contract

    // ════════════════════════════════════════ EVENTS ════════════════════════════════════════
    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );
    event CollateralRedeemed(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );

    // ════════════════════════════════════════ MODIFIERS ════════════════════════════════════════
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) revert DSCEngine__NeedsMoreThanZero();
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0))
            revert DSCEngine__TokenNotAllowed();
        _;
    }

    // ════════════════════════════════════════ CONSTRUCTOR ════════════════════════════════════════
    /**
     * @param tokenAddresses Array of collateral token addresses
     * @param priceFeedAddresses Array of corresponding price feed addresses
     * @param dscAddress Address of the DSC token contract
     * @notice Initializes token-price feed mappings and DSC contract
     */
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAndPriceFeedArraysLengthMismatch();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    // ════════════════════════════════════════ INTERNAL FUNCTIONS ════════════════════════════════════════
    function _redeemedCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        address from,
        address to
    ) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );

        bool ok = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!ok) revert DSCEngine__TransferFailed();
    }

    function _burnDsc(
        uint256 amountDscToBurn,
        address onBehalfOf,
        address dscFrom
    ) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool ok = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!ok) revert DSCEngine__TransferFailed();

        i_dsc.burn(amountDscToBurn);
    }

    // ════════════════════════════════════════ EXTERNAL FUNCTIONS ════════════════════════════════════════
    /*
     * @param tokenCollateralAddress the Address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint: The amount of DecentralizedStableCoin to mint
     * @notice This function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        burnDsc(amountDscToMint);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    /*
     * @param collateral: The ERC20 token address of the collateral you're using to make the protocol solvent again.
     * This is collateral that you're going to take from the user who is insolvent.
     * In return, you have to burn your DSC to pay off their debt, but you don't pay off your own.
     * @param user: The user who is insolvent. They have to have a _healthFactor below MIN_HEALTH_FACTOR
     * @param debtToCover: The amount of DSC you want to burn to cover the user's debt.
     *
     * @notice: You can partially liquidate a user.
     * @notice: You will get a 10% LIQUIDATION_BONUS for taking the users funds.
     * @notice: This function working assumes that the protocol will be roughly 150%
     *    overcollateralized in order for this to work.
     * @notice: A known bug would be if the protocol was only 100% collateralized,
     *    we wouldn't be able to liquidate anyone.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover
    ) external moreThanZero(debtToCover) nonReentrant {
        // check healthFactor
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor > MIN_HEALTH_FACTOR)
            revert DSCEngine__HealthFactorOk();

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(
            collateral,
            debtToCover
        );

        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        uint256 totalCollateralRedeemed = tokenAmountFromDebtCovered +
            bonusCollateral;
        _redeemedCollateral(
            collateral,
            totalCollateralRedeemed,
            user,
            msg.sender
        );
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endUserHealthFactor = _healthFactor(user);
        if (endUserHealthFactor <= startingUserHealthFactor)
            revert DSCEngine__HealthFactorNotImproved();
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_TRESHOLD;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokePrice(
        address token
    ) external view returns (address) {
        return s_priceFeeds[token];
    }

    // ════════════════════════════════════════ PUBLIC FUNCTIONS ════════════════════════════════════════
    function getTokenAmountFromUsd(
        address token,
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();

        return
            (usdAmountInWei * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    /**
     * @param tokenCollateralAddress Address of the collateral token
     * @param amountCollateral Amount of collateral to deposit
     * @notice Deposits collateral; requires valid token and non-zero amount
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][
            tokenCollateralAddress
        ] += amountCollateral;
        emit CollateralDeposited(
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );
        if (!success) revert DSCEngine__TransferFailed();
    }

    /**
     * @param amountDscToMint Amount of DSC to mint
     * @notice Mints DSC; ensures user has sufficient collateral
     */
    function mintDsc(
        uint256 amountDscToMint
    ) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @param amount Amount of DSC to burn
     * @notice Burn DSC; ensures system is healhty
     */
    function burnDsc(uint256 amount) public moreThanZero(amount) nonReentrant {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     *  @param tokenCollateralAddress The address that collateralized
     *  @param amountCollateral The amount that want to be redeemed
     */
    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public moreThanZero(amountCollateral) nonReentrant {
        _redeemedCollateral(
            tokenCollateralAddress,
            amountCollateral,
            msg.sender,
            msg.sender
        );
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @param user Address to query
     * @return totalCollateralValueInUsd Total USD value of user's collateral
     * @notice Calculates total collateral value based on price feeds
     */
    function getAccountCollateralValue(
        address user
    ) public view returns (uint256 totalCollateralValueInUsd) {
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
    function getUsdValue(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return
            ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    // ════════════════════════════════════════ PRIVATE FUNCTIONS ════════════════════════════════════════
    /**
     * @param user Address to query
     * @return totalDscMinted Total DSC minted by user
     * @return collateralValueInUsd Total USD value of user's collateral
     * @notice Retrieves account details for health factor calculations
     */
    function _getAccountInformation(
        address user
    )
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
        (
            uint256 totalDscMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInformation(user);
        return _calculateHealtFactor(totalDscMinted, collateralValueInUsd);
    }

    function _calculateHealtFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    ) internal pure returns (uint256) {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralValueInUsdAjusted = (collateralValueInUsd *
            LIQUIDATION_TRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralValueInUsdAjusted * PRECISION) / totalDscMinted;
    }

    /**
     * @param user Address to check
     * @notice Reverts if user's health factor is below threshold
     */
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }
}
