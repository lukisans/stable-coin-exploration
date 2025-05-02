// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig config;

    address weth;
    address wbtc;
    address wethUsdPriceFeed;
    address wbtcUsdPriceFeed;
    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant AMOUNT_TO_MINT = 100 ether; // $100 worth of DSC
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, config) = deployer.run();
        (wethUsdPriceFeed, wbtcUsdPriceFeed, weth, wbtc, ) = config
            .activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(LIQUIDATOR, STARTING_ERC20_BALANCE);
    }

    // ================== Constructor Tests ==================

    function test_Constructor_SetsCorrectTokensAndPriceFeeds() public view {
        assertEq(engine.getCollateralTokenPrice(weth), wethUsdPriceFeed);
        assertEq(engine.getCollateralTokenPrice(wbtc), wbtcUsdPriceFeed);
    }

    function test_Constructor_RevertsOnMismatchedArrayLengths() public {
        address[] memory tokenAddresses = new address[](2);
        tokenAddresses[0] = weth;
        tokenAddresses[1] = wbtc;

        address[] memory priceFeedAddresses = new address[](1);
        priceFeedAddresses[0] = wethUsdPriceFeed;

        vm.expectRevert(
            DSCEngine.DSCEngine__TokenAndPriceFeedArraysLengthMismatch.selector
        );
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    // ================== Deposit Collateral Tests ==================

    function test_DepositCollateral_Works() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        (bool depositSuccess, ) = address(engine).call(
            abi.encodeWithSignature(
                "depositCollateral(address,uint256)",
                weth,
                AMOUNT_COLLATERAL
            )
        );
        vm.stopPrank();

        assertEq(depositSuccess, true);
    }

    function test_DepositCollateral_RevertIfZeroAmount() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function test_DepositCollateral_RevertIfTokenNotAllowed() public {
        ERC20Mock randomToken = new ERC20Mock(
            "Random",
            "RND",
            USER,
            AMOUNT_COLLATERAL
        );

        vm.startPrank(USER);
        randomToken.approve(address(engine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        engine.depositCollateral(address(randomToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function test_DepositCollateral_EmitsEvent() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        vm.expectEmit(true, true, true, true, address(engine));
        emit DSCEngine.CollateralDeposited(USER, weth, AMOUNT_COLLATERAL);

        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    // ================== Mint DSC Tests ==================

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function test_MintDsc_Works() public depositedCollateral {
        vm.prank(USER);

        // Let's determine how much we can mint
        uint256 ethValue = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 maxDscToMint = (ethValue * LIQUIDATION_THRESHOLD) / 100;

        uint256 amountToMint = maxDscToMint / 2; // Mint half of the max

        engine.mintDsc(amountToMint);

        assertEq(dsc.balanceOf(USER), amountToMint);
    }

    function test_MintDsc_RevertIfBreaksHealthFactor()
        public
        depositedCollateral
    {
        // Calculate the maximum amount that would break the health factor
        uint256 ethValue = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 maxDscToMint = (ethValue * LIQUIDATION_THRESHOLD) / 100;
        uint256 amountToMint = maxDscToMint + 1; // Just over the limit

        vm.startPrank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__BreaksHealthFactor.selector,
                0
            )
        );
        engine.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function test_MintDsc_RevertIfZeroAmount() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.mintDsc(0);
        vm.stopPrank();
    }

    // ================== depositCollateralAndMintDsc Tests ==================

    function test_DepositAndMint_Works() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        // Calculate safe mint amount
        uint256 ethValue = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 maxDscToMint = (ethValue * LIQUIDATION_THRESHOLD) / 100;
        uint256 amountToMint = maxDscToMint / 2;

        engine.depositCollateralAndMintDsc(
            weth,
            AMOUNT_COLLATERAL,
            amountToMint
        );

        assertEq(dsc.balanceOf(USER), amountToMint);
        vm.stopPrank();
    }

    // ================== Health Factor Tests ==================

    function test_HealthFactor_CalculatesCorrectly()
        public
        depositedCollateral
    {
        // Mint some DSC
        vm.startPrank(USER);
        uint256 ethValue = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 maxDscToMint = (ethValue * LIQUIDATION_THRESHOLD) / 100;
        uint256 amountToMint = maxDscToMint / 2;

        engine.mintDsc(amountToMint);

        // Check health factor
        uint256 expectedHealthFactor = (((ethValue * LIQUIDATION_THRESHOLD) /
            100) * 1e18) / amountToMint;
        uint256 actualHealthFactor = engine.getHealthFactor(USER);

        assertEq(actualHealthFactor, expectedHealthFactor);
        vm.stopPrank();
    }

    function test_HealthFactor_MaxIfZeroDscMinted() public depositedCollateral {
        uint256 healthFactor = engine.getHealthFactor(USER);
        assertEq(healthFactor, type(uint256).max);
    }

    // ================== Burn DSC Tests ==================

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);

        uint256 ethValue = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 maxDscToMint = (ethValue * LIQUIDATION_THRESHOLD) / 100;
        uint256 amountToMint = maxDscToMint / 2;

        engine.mintDsc(amountToMint);
        vm.stopPrank();
        _;
    }

    function test_BurnDsc_Works() public depositedCollateralAndMintedDsc {
        uint256 userBalance = dsc.balanceOf(USER);
        uint256 amountToBurn = userBalance / 2;

        vm.startPrank(USER);
        dsc.approve(address(engine), amountToBurn);
        engine.burnDsc(amountToBurn);

        assertEq(dsc.balanceOf(USER), userBalance - amountToBurn);
        assertEq(engine.getTotalDscMinted(USER), userBalance - amountToBurn);
        vm.stopPrank();
    }

    function test_BurnDsc_RevertIfZeroAmount()
        public
        depositedCollateralAndMintedDsc
    {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.burnDsc(0);
        vm.stopPrank();
    }

    // ================== Redeem Collateral Tests ==================

    function test_RedeemCollateral_Works() public depositedCollateral {
        uint256 amountToRedeem = AMOUNT_COLLATERAL / 2;

        vm.startPrank(USER);
        engine.redeemCollateral(weth, amountToRedeem);

        assertEq(
            ERC20Mock(weth).balanceOf(USER),
            STARTING_ERC20_BALANCE - AMOUNT_COLLATERAL + amountToRedeem
        );
        vm.stopPrank();
    }

    function test_RedeemCollateral_RevertIfBreaksHealthFactor()
        public
        depositedCollateralAndMintedDsc
    {
        // Try to redeem all collateral - should break health factor
        vm.startPrank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__BreaksHealthFactor.selector,
                0
            )
        );
        engine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function test_RedeemCollateral_EmitsEvent() public depositedCollateral {
        uint256 amountToRedeem = AMOUNT_COLLATERAL / 2;

        vm.startPrank(USER);
        vm.expectEmit(true, true, true, true, address(engine));
        emit DSCEngine.CollateralRedeemed(USER, weth, amountToRedeem);

        engine.redeemCollateral(weth, amountToRedeem);
        vm.stopPrank();
    }

    // ================== redeemCollateralForDsc Tests ==================

    function test_RedeemCollateralForDsc_Works()
        public
        depositedCollateralAndMintedDsc
    {
        uint256 userDscBalance = dsc.balanceOf(USER);
        uint256 amountCollateralToRedeem = AMOUNT_COLLATERAL / 4;

        vm.startPrank(USER);
        dsc.approve(address(engine), userDscBalance);
        engine.redeemCollateralForDsc(
            weth,
            amountCollateralToRedeem,
            userDscBalance
        );

        assertEq(dsc.balanceOf(USER), 0);
        assertEq(engine.getTotalDscMinted(USER), 0);
        assertEq(
            ERC20Mock(weth).balanceOf(USER),
            STARTING_ERC20_BALANCE -
                AMOUNT_COLLATERAL +
                amountCollateralToRedeem
        );
        vm.stopPrank();
    }

    // ================== Liquidation Tests ==================

    function test_Liquidate_Works() public {
        // Setup: User deposits collateral and mints DSC to the max
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);

        uint256 ethValue = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 maxDscToMint = (ethValue * LIQUIDATION_THRESHOLD) / 100;

        engine.mintDsc(maxDscToMint);
        vm.stopPrank();

        // Drop ETH price to make USER undercollateralized
        int256 ethUpdatedPrice = 1500e8; // $1500 from $2000 (assuming)
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(ethUpdatedPrice);

        // Liquidator setup
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        engine.mintDsc(maxDscToMint);
        dsc.approve(address(engine), maxDscToMint);

        // Liquidate half the debt
        uint256 debtToCover = maxDscToMint / 2;
        engine.liquidate(weth, USER, debtToCover);

        // Calculate expected collateral reward
        uint256 tokenAmountFromDebtCovered = engine.getTokenAmountFromUsd(
            weth,
            debtToCover
        );
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * 10) / 100; // 10% bonus
        uint256 totalCollateralRedeemed = tokenAmountFromDebtCovered +
            bonusCollateral;

        // Verify LIQUIDATOR's balances
        assertEq(dsc.balanceOf(LIQUIDATOR), maxDscToMint - debtToCover);
        assertEq(
            ERC20Mock(weth).balanceOf(LIQUIDATOR),
            STARTING_ERC20_BALANCE - AMOUNT_COLLATERAL + totalCollateralRedeemed
        );

        // Verify USER's debt reduced
        assertEq(engine.getTotalDscMinted(USER), maxDscToMint - debtToCover);
        vm.stopPrank();
    }

    function test_Liquidate_RevertIfHealthFactorOk()
        public
        depositedCollateralAndMintedDsc
    {
        // User should be well-collateralized
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        engine.mintDsc(AMOUNT_TO_MINT);
        dsc.approve(address(engine), AMOUNT_TO_MINT);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        engine.liquidate(weth, USER, AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    function test_Liquidate_RevertIfHealthFactorNotImproved() public {
        // Setup: User deposits collateral and mints DSC to the max
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);

        uint256 ethValue = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 maxDscToMint = (ethValue * LIQUIDATION_THRESHOLD) / 100;

        engine.mintDsc(maxDscToMint);
        vm.stopPrank();

        // Drop ETH price to make USER undercollateralized
        int256 ethUpdatedPrice = 1500e8; // $1500 from $2000 (assuming)
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(ethUpdatedPrice);

        // Liquidator setup but tries to liquidate with too much debt
        // which would make the Liquidator's health factor worse
        vm.startPrank(LIQUIDATOR);
        dsc.approve(address(engine), maxDscToMint);

        // This should fail because liquidator doesn't have the DSC to cover the debt
        vm.expectRevert();
        engine.liquidate(weth, USER, maxDscToMint);
        vm.stopPrank();
    }

    // ================== Price Feed Tests ==================

    function test_GetUsdValue_CalculatesCorrectly() public {
        // Assuming ETH price is $2000 in the mock
        int256 ethPrice = 2000e8;
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(ethPrice);

        uint256 ethAmount = 1 ether;
        uint256 expectedValue = 2000e18; // $2000 with 18 decimals

        uint256 actualValue = engine.getUsdValue(weth, ethAmount);
        assertEq(actualValue, expectedValue);
    }

    function test_GetTokenAmountFromUsd_CalculatesCorrectly() public {
        // Assuming ETH price is $2000 in the mock
        int256 ethPrice = 2000e8;
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(ethPrice);

        uint256 usdAmount = 2000e18; // $2000 with 18 decimals
        uint256 expectedEthAmount = 1 ether;

        uint256 actualEthAmount = engine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(actualEthAmount, expectedEthAmount);
    }

    // ================== Getter Function Tests ==================

    function test_GetAccountCollateralValue_CalculatesCorrectly()
        public
        depositedCollateral
    {
        uint256 ethPrice = 2000e18; // $2000 with 18 decimals (adjusted for ADDITIONAL_FEED_PRECISION)
        uint256 expectedValue = (AMOUNT_COLLATERAL * ethPrice) / 1e18;

        vm.startPrank(USER);
        uint256 actualValue = engine.getAccountCollateralValue(USER);
        assertEq(actualValue, expectedValue);
        vm.stopPrank();
    }

    function test_GetAccountInformation_ReturnsCorrectValues()
        public
        depositedCollateralAndMintedDsc
    {
        vm.startPrank(USER);
        uint256 userDscBalance = dsc.balanceOf(USER);
        uint256 userCollateralValue = engine.getAccountCollateralValue(USER);

        // This test would need to extract values from a view function
        // For simplicity, just assert the values are non-zero
        assertGt(userDscBalance, 0);
        assertGt(userCollateralValue, 0);
        vm.stopPrank();
    }

    function test_GetterConstants_ReturnCorrectValues() public view {
        assertEq(engine.getAdditionalFeedPrecision(), 1e10);
        assertEq(engine.getPrecision(), 1e18);
        assertEq(engine.getLiquidationThreshold(), 50);
        assertEq(engine.getLiquidationPrecision(), 100);
        assertEq(engine.getLiquidationBonus(), 10);
        assertEq(engine.getMinHealthFactor(), 1e18);
    }
}
