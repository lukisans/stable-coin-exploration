// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";

import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20MockFailedTransfer} from "../mocks/ERC20MockFailed.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dscCoin;
    DSCEngine dscEngine;
    HelperConfig config;

    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();

        (dscCoin, dscEngine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, ) = config
            .activeNetworkConfig();
    }

    // Constructor
    function test_ConstructorRevertsIfTokenAndPriceFeedArraysLengthMismatch()
        public
    {
        // Do deploy DSCEngine with mismatched token and price feed array lengths
        // Expect revert with DSCEngine__TokenAndPriceFeedArraysLengthMismatch error
        address[] memory tokenAddress = new address[](1);
        tokenAddress[0] = weth;

        address[] memory priceFeedAddresses = new address[](2);
        priceFeedAddresses[0] = ethUsdPriceFeed;
        priceFeedAddresses[1] = btcUsdPriceFeed;

        // Expect to fail
        vm.expectRevert(
            DSCEngine.DSCEngine__TokenAndPriceFeedArraysLengthMismatch.selector
        );
        new DSCEngine(tokenAddress, priceFeedAddresses, address(dscCoin));

        address[] memory tokenAddressSameLength = new address[](2);
        tokenAddressSameLength[0] = weth;
        tokenAddressSameLength[1] = wbtc;
        new DSCEngine(
            tokenAddressSameLength,
            priceFeedAddresses,
            address(dscCoin)
        );
    }

    function test_ConstructorSetsTokenPriceFeedMappings() public view {
        // Do deploy DSCEngine with valid token and price feed arrays
        // Expect token-price feed mappings and DSC address to be set correctly
        vm.assertEq(dscEngine.getCollateralTokenPrice(weth), ethUsdPriceFeed);
        vm.assertEq(dscEngine.getCollateralTokenPrice(wbtc), btcUsdPriceFeed);
        vm.assertEq(dscEngine.getDsc(), address(dscCoin));
    }

    // depositCollateral
    function test_DepositCollateralRevertsIfAmountIsZero() public {
        // Do deposit zero collateral amount
        // Expect revert with DSCEngine__NeedsMoreThanZero error
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
    }

    function test_DepositCollateralRevertsIfTokenNotAllowed() public {
        // Do deposit collateral with unallowed token
        // Expect revert with DSCEngine__TokenNotAllowed error
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        dscEngine.depositCollateral(weth, 1_000);
    }

    function test_DepositCollateralRevertsIfTransferFails() public {
        // Do deposit collateral with failing token transfer
        // Expect revert with DSCEngine__TransferFailed error``
        // Arrange: Set up mock token and DSCEngine
        ERC20MockFailedTransfer mockErc = new ERC20MockFailedTransfer(
            "WFLD",
            "WFLD",
            USER,
            1000e8 // 1,000 tokens (assuming 8 decimals)
        );
        address[] memory tokenAddresses = new address[](1);
        tokenAddresses[0] = address(mockErc);

        address[] memory priceFeedAddresses = new address[](1);
        priceFeedAddresses[0] = btcUsdPriceFeed;

        DSCEngine engine = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(dscCoin)
        );

        // Verify initial USER balance
        vm.assertEq(
            mockErc.balanceOf(USER),
            1000e8,
            "Initial USER balance incorrect"
        );

        // First deposit: Should succeed
        vm.startPrank(USER);
        mockErc.approve(address(engine), 500e8); // Approve 500 tokens
        engine.depositCollateral(address(mockErc), 500e8); // Deposit 500 tokens
        vm.stopPrank();

        // Check balances after successful deposit
        vm.assertEq(
            mockErc.balanceOf(USER),
            500e8,
            "USER balance after deposit incorrect"
        );
        vm.assertEq(
            mockErc.balanceOf(address(engine)),
            500e8,
            "Engine balance after deposit incorrect"
        );

        // Second deposit: Should fail due to transfer failure
        vm.startPrank(USER);
        mockErc.setTransferShouldFail(true); // Make transferFrom fail
        mockErc.approve(address(engine), 100e8); // Approve 100 tokens
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        engine.depositCollateral(address(mockErc), 100e8); // Attempt to deposit 100 tokens
        vm.stopPrank();

        // Check balances after failed deposit
        vm.assertEq(
            mockErc.balanceOf(USER),
            500e8,
            "USER balance changed after failed deposit"
        );
        vm.assertEq(
            mockErc.balanceOf(address(engine)),
            500e8,
            "Engine balance changed after failed deposit"
        );
    }

    function test_DepositCollateralUpdatesStateAndEmitsEvent() public {
        // Do deposit valid collateral amount
        // Expect collateral deposited state updated and CollateralDeposited event emitted
        // Mock ERC20
        uint256 depositAmount = 500e8;

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), depositAmount);

        // Action 1: Deposit collateral and trigger emit
        vm.expectEmit(true, true, false, true, address(dscEngine));
        emit DSCEngine.CollateralDeposited(USER, address(weth), depositAmount);
        dscEngine.depositCollateral(address(weth), depositAmount);
        vm.stopPrank();

        uint256 userCollateral = dscEngine.getAccountCollateralValue(USER);
        uint256 depositAmountInUsd = dscEngine.getUsdValue(
            address(weth),
            depositAmount
        );
        vm.assertEq(
            userCollateral,
            depositAmountInUsd,
            "User collateral balance incorrect"
        );
    }

    // mintDsc
    function test_MintDscRevertsIfAmountIsZero() public {
        // Do mint zero DSC amount
        // Expect revert with DSCEngine__NeedsMoreThanZero error
        vm.startPrank(USER);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.mintDsc(0);

        vm.stopPrank();
    }

    function test_MintDscRevertsIfHealthFactorBroken() public {
        // Do mint some DSC amount but break health factor
        // Expect revert with DSCEngine__BreaksHealthFactor error
        uint256 depositAmount = 500_000e8;
        ERC20Mock mockErc = new ERC20Mock(
            "WFLD",
            "WFLD",
            address(dscEngine),
            1_000_000e8 // 1,000 tokens (assuming 8 decimals)
        );
        vm.startPrank(address(dscEngine));
        ERC20Mock(mockErc).transfer(address(USER), depositAmount);
        vm.stopPrank();

        address[] memory tokenAddresses = new address[](1);
        tokenAddresses[0] = address(mockErc);

        address[] memory priceFeedAddresses = new address[](1);
        priceFeedAddresses[0] = ethUsdPriceFeed;

        DecentralizedStableCoin dsc = new DecentralizedStableCoin(
            address(USER)
        );
        DSCEngine dscengine = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(dsc)
        );

        vm.startPrank(USER);
        dsc.transferOwnership(address(dscengine));
        vm.stopPrank();

        (, int256 price, , , ) = MockV3Aggregator(ethUsdPriceFeed)
            .latestRoundData();
        uint256 amountToMint = (depositAmount *
            uint256(price) *
            dscengine.getAdditionalFeedPrecision()) / dscengine.getPrecision();

        vm.startPrank(USER);
        ERC20Mock(mockErc).approve(address(dscengine), depositAmount);
        dscengine.depositCollateral(address(mockErc), depositAmount);

        uint256 expectedHF = dscengine.calculateHealtFactor(
            amountToMint,
            dscengine.getUsdValue(address(mockErc), depositAmount)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__BreaksHealthFactor.selector,
                expectedHF
            )
        );
        dscengine.mintDsc(amountToMint);

        vm.stopPrank();
    }

    function test_MintDscSucceedsWithSufficientCollateral() public {
        // Do mint valid DSC amount with sufficient collateral
        // Expect DSC minted state updated and health factor maintained
        uint256 depositAmount = 500_000e8;
        ERC20Mock mockErc = new ERC20Mock(
            "WFLD",
            "WFLD",
            address(dscEngine),
            1_000_000e8 // 1,000 tokens (assuming 8 decimals)
        );
        vm.startPrank(address(dscEngine));
        ERC20Mock(mockErc).transfer(address(USER), depositAmount);
        vm.stopPrank();

        address[] memory tokenAddresses = new address[](1);
        tokenAddresses[0] = address(mockErc);

        address[] memory priceFeedAddresses = new address[](1);
        priceFeedAddresses[0] = ethUsdPriceFeed;

        DecentralizedStableCoin dsc = new DecentralizedStableCoin(
            address(USER)
        );
        DSCEngine dscengine = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(dsc)
        );

        vm.startPrank(USER);
        dsc.transferOwnership(address(dscengine));
        vm.stopPrank();

        (, int256 price, , , ) = MockV3Aggregator(ethUsdPriceFeed)
            .latestRoundData();
        uint256 amountToMint = (100e8 *
            uint256(price) *
            dscengine.getAdditionalFeedPrecision()) / dscengine.getPrecision();

        vm.startPrank(USER);
        ERC20Mock(mockErc).approve(address(dscengine), depositAmount);
        dscengine.depositCollateral(address(mockErc), depositAmount);

        dscengine.mintDsc(amountToMint);

        vm.stopPrank();
    }

    // burnDsc
    function test_BurnDscRevertsIfAmountIsZero() public {
        // Do burn zero DSC amount
        // Expect revert with DSCEngine__NeedsMoreThanZero error
    }

    function test_BurnDscSucceeds() public {
        // Do burn valid DSC amount
        // Expect DSC burned, state updated, and health factor maintained
    }

    // _burnDsc (assuming public for testing)
    function test_BurnDscRevertsIfTransferFails() public {
        // Do call _burnDsc with failing DSC transfer
        // Expect revert with DSCEngine__TransferFailed error
    }

    function test_BurnDscUpdatesStateAndBurnsDsc() public {
        // Do call _burnDsc with valid parameters
        // Expect DSC state updated and DSC burned
    }

    // redeemCollateral
    function test_RedeemCollateralRevertsIfAmountIsZero() public {
        // Do redeem zero collateral amount
        // Expect revert with DSCEngine__NeedsMoreThanZero error
    }

    function test_RedeemCollateralRevertsIfTransferFails() public {
        // Do redeem collateral with failing transfer
        // Expect revert with DSCEngine__TransferFailed error
    }

    function test_RedeemCollateralSucceeds() public {
        // Do redeem valid collateral amount
        // Expect collateral redeemed, state updated, and CollateralRedeemed event emitted
    }

    // _redeemedCollateral (assuming public for testing)
    function test_RedeemedCollateralRevertsIfTransferFails() public {
        // Do call _redeemedCollateral with failing token transfer
        // Expect revert with DSCEngine__TransferFailed error
    }

    function test_RedeemedCollateralUpdatesStateAndEmitsEvent() public {
        // Do call _redeemedCollateral with valid parameters
        // Expect collateral state updated and CollateralRedeemed event emitted
    }

    // depositCollateralAndMintDsc
    function test_DepositCollateralAndMintDscRevertsIfCollateralZero() public {
        // Do deposit zero collateral and mint DSC
        // Expect revert with DSCEngine__NeedsMoreThanZero error
    }

    function test_DepositCollateralAndMintDscRevertsIfTokenNotAllowed() public {
        // Do deposit collateral with unallowed token and mint DSC
        // Expect revert with DSCEngine__TokenNotAllowed error
    }

    function test_DepositCollateralAndMintDscRevertsIfHealthFactorBroken()
        public
    {
        // Do deposit collateral and mint DSC exceeding health factor
        // Expect revert with DSCEngine__BreaksHealthFactor error
    }

    function test_DepositCollateralAndMintDscSucceeds() public {
        // Do deposit valid collateral and mint valid DSC amount
        // Expect collateral deposited, DSC minted, and states updated correctly
    }

    // redeemCollateralForDsc
    function test_RedeemCollateralForDscRevertsIfAmountZero() public {
        // Do redeem zero collateral and burn DSC
        // Expect revert with DSCEngine__NeedsMoreThanZero error
    }

    function test_RedeemCollateralForDscRevertsIfTransferFails() public {
        // Do redeem collateral with failing transfer
        // Expect revert with DSCEngine__TransferFailed error
    }

    function test_RedeemCollateralForDscSucceeds() public {
        // Do redeem valid collateral and burn DSC
        // Expect collateral redeemed, DSC burned, and states updated correctly
    }

    // liquidate
    function test_LiquidateRevertsIfDebtToCoverZero() public {
        // Do liquidate with zero debt to cover
        // Expect revert with DSCEngine__NeedsMoreThanZero error
    }

    function test_LiquidateRevertsIfHealthFactorOk() public {
        // Do liquidate user with health factor above minimum
        // Expect revert with DSCEngine__HealthFactorOk error
    }

    function test_LiquidateRevertsIfHealthFactorNotImproved() public {
        // Do liquidate with health factor not improved after liquidation
        // Expect revert with DSCEngine__HealthFactorNotImproved error
    }

    function test_LiquidateSucceeds() public {
        // Do liquidate valid user with insufficient health factor
        // Expect collateral transferred, DSC burned, and health factor improved
    }

    // getHealthFactor
    function test_GetHealthFactorReturnsMaxForNoDscMinted() public {
        // Do get health factor for user with no DSC minted
        // Expect return maximum uint256 value
    }

    function test_GetHealthFactorReturnsCorrectValue() public {
        // Do get health factor for user with DSC minted and collateral
        // Expect return calculated health factor based on collateral and DSC
    }

    // getAdditionalFeedPrecision
    function test_GetAdditionalFeedPrecisionReturnsConstant() public {
        // Do call getAdditionalFeedPrecision
        // Expect return ADDITIONAL_FEED_PRECISION constant
    }

    // getPrecision
    function test_GetPrecisionReturnsConstant() public {
        // Do call getPrecision
        // Expect return PRECISION constant
    }

    // getLiquidationThreshold
    function test_GetLiquidationThresholdReturnsConstant() public {
        // Do call getLiquidationThreshold
        // Expect return LIQUIDATION_TRESHOLD constant
    }

    // getLiquidationPrecision
    function test_GetLiquidationPrecisionReturnsConstant() public {
        // Do call getLiquidationPrecision
        // Expect return LIQUIDATION_PRECISION constant
    }

    // getLiquidationBonus
    function test_GetLiquidationBonusReturnsConstant() public {
        // Do call getLiquidationBonus
        // Expect return LIQUIDATION_BONUS constant
    }

    // getMinHealthFactor
    function test_GetMinHealthFactorReturnsConstant() public {
        // Do call getMinHealthFactor
        // Expect return MIN_HEALTH_FACTOR constant
    }

    // getDsc
    function test_GetDscReturnsDscAddress() public {
        // Do call getDsc
        // Expect return DSC contract address
    }

    // getCollateralTokePrice
    function test_GetCollateralTokePriceReturnsPriceFeed() public {
        // Do call getCollateralTokePrice with valid token
        // Expect return corresponding price feed address
    }

    function test_GetCollateralTokePriceReturnsZeroForInvalidToken() public {
        // Do call getCollateralTokePrice with invalid token
        // Expect return zero address
    }

    // getTokenAmountFromUsd
    function test_GetTokenAmountFromUsdReturnsCorrectAmount() public {
        // Do call getTokenAmountFromUsd with valid token and USD amount
        // Expect return correct token amount based on price feed
    }

    function test_GetTokenAmountFromUsdHandlesInvalidToken() public {
        // Do call getTokenAmountFromUsd with invalid token
        // Expect revert or return zero due to missing price feed
    }

    // getAccountCollateralValue
    function test_GetAccountCollateralValueReturnsZeroForNoCollateral() public {
        // Do call getAccountCollateralValue for user with no collateral
        // Expect return zero USD value
    }

    function test_GetAccountCollateralValueReturnsCorrectValue() public {
        // Do call getAccountCollateralValue for user with collateral
        // Expect return total USD value of all collateral based on price feeds
    }

    // getUsdValue
    function test_GetUsdValueReturnsCorrectValue() public {
        // Do call getUsdValue with valid token and amount
        // Expect return correct USD value based on price feed
    }

    function test_GetUsdValueHandlesInvalidToken() public {
        // Do call getUsdValue with invalid token
        // Expect revert or return zero due to missing price feed
    }
}
