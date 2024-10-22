// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {GasPriceFeesHook} from "../src/GasPriceFeesHook.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {console} from "forge-std/console.sol";

contract TestGasPriceFeesHook is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    GasPriceFeesHook hook;

    function setUp() public {
        // Deploy v4-core
        deployFreshManagerAndRouters();

        // Deploy, mint tokens, and approve all periphery contracts for two tokens
        deployMintAndApprove2Currencies();

        // Deploy our hook with the proper flags
        address hookAddress = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG |
                    Hooks.BEFORE_SWAP_FLAG |
                    Hooks.AFTER_SWAP_FLAG
            )
        );

        // Set gas price = 10 gwei and deploy our hook
        vm.txGasPrice(10 gwei);
        deployCodeTo("GasPriceFeesHook", abi.encode(manager), hookAddress);
        hook = GasPriceFeesHook(hookAddress);

        // Initialize a pool
        (key, ) = initPool(
            currency0,
            currency1,
            hook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG, // Set the `DYNAMIC_FEE_FLAG` in place of specifying a fixed fee
            SQRT_PRICE_1_1,
            ZERO_BYTES
        );

        // Add some liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_feeUpdatesWithGasPrice() public {
        // Set up our swap parameters
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -0.00001 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Current gas price is 10 gwei
        // Moving average should also be 10
        uint128 gasPrice = uint128(tx.gasprice);
        uint128 movingAverageGasPrice = hook.movingAverageGasPrice();
        uint104 movingAverageGasPriceCount = hook.movingAverageGasPriceCount();
        assertEq(gasPrice, 10 gwei);
        assertEq(movingAverageGasPrice, 10 gwei);
        assertEq(movingAverageGasPriceCount, 1);

        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------

        // 1. Conduct a swap at gasprice = 10 gwei
        // This should just use `BASE_FEE` since the gas price is the same as the current average
        uint256 balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        uint256 balanceOfToken1After = currency1.balanceOfSelf();
        uint256 outputFromBaseFeeSwap = balanceOfToken1After -
            balanceOfToken1Before;

        assertGt(balanceOfToken1After, balanceOfToken1Before);

        // Our moving average shouldn't have changed
        // only the count should have incremented
        movingAverageGasPrice = hook.movingAverageGasPrice();
        movingAverageGasPriceCount = hook.movingAverageGasPriceCount();
        assertEq(movingAverageGasPrice, 10 gwei);
        assertEq(movingAverageGasPriceCount, 2);

        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------

        // 2. Conduct a swap at lower gasprice = 4 gwei
        // This should have a higher transaction fees
        vm.txGasPrice(4 gwei);
        balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        balanceOfToken1After = currency1.balanceOfSelf();

        uint256 outputFromIncreasedFeeSwap = balanceOfToken1After -
            balanceOfToken1Before;

        assertGt(balanceOfToken1After, balanceOfToken1Before);

        // Our moving average should now be (10 + 10 + 4) / 3 = 8 Gwei
        movingAverageGasPrice = hook.movingAverageGasPrice();
        movingAverageGasPriceCount = hook.movingAverageGasPriceCount();
        assertEq(movingAverageGasPrice, 8 gwei);
        assertEq(movingAverageGasPriceCount, 3);

        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------
        // ----------------------------------------------------------------------

        // 3. Conduct a swap at higher gas price = 12 gwei
        // This should have a lower transaction fees
        vm.txGasPrice(12 gwei);
        balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        balanceOfToken1After = currency1.balanceOfSelf();

        uint outputFromDecreasedFeeSwap = balanceOfToken1After -
            balanceOfToken1Before;

        assertGt(balanceOfToken1After, balanceOfToken1Before);

        // Our moving average should now be (10 + 10 + 4 + 12) / 4 = 9 Gwei
        movingAverageGasPrice = hook.movingAverageGasPrice();
        movingAverageGasPriceCount = hook.movingAverageGasPriceCount();

        assertEq(movingAverageGasPrice, 9 gwei);
        assertEq(movingAverageGasPriceCount, 4);

        // ------

        // 4. Check all the output amounts

        console.log("Base Fee Output", outputFromBaseFeeSwap);
        console.log("Increased Fee Output", outputFromIncreasedFeeSwap);
        console.log("Decreased Fee Output", outputFromDecreasedFeeSwap);

        assertGt(outputFromDecreasedFeeSwap, outputFromBaseFeeSwap);
        assertGt(outputFromBaseFeeSwap, outputFromIncreasedFeeSwap);
    }

    function test_extremeGasPriceChanges() public {
        // Set up our swap parameters
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -0.00001 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Initial state
        assertEq(hook.movingAverageGasPrice(), 10 gwei);
        assertEq(hook.movingAverageGasPriceCount(), 1);

        // Extreme low gas price
        vm.txGasPrice(1 gwei);
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        
        uint128 lowGasPrice = hook.movingAverageGasPrice();
        assertLt(lowGasPrice, 10 gwei);

        // Extreme high gas price
        vm.txGasPrice(100 gwei);
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        
        uint128 highGasPrice = hook.movingAverageGasPrice();
        assertGt(highGasPrice, lowGasPrice);
    }

    function test_consistentGasPrice() public {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -0.00001 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Perform multiple swaps with the same gas price
        for (uint i = 0; i < 10; i++) {
            vm.txGasPrice(10 gwei);
            swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        }

        // Check that the moving average remains stable
        assertEq(hook.movingAverageGasPrice(), 10 gwei);
        assertEq(hook.movingAverageGasPriceCount(), 11); // 1 from setup + 10 from this test
    }

    function test_movingAverageCalculation() public {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -0.00001 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Perform swaps with different gas prices
        uint128[] memory gasPrices = new uint128[](5);
        gasPrices[0] = 10 gwei; // Initial state
        gasPrices[1] = 15 gwei;
        gasPrices[2] = 8 gwei;
        gasPrices[3] = 12 gwei;
        gasPrices[4] = 20 gwei;

        for (uint i = 1; i < gasPrices.length; i++) {
            vm.txGasPrice(gasPrices[i]);
            swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        }

        // Calculate expected moving average
        uint128 expectedAverage = 0;
        for (uint i = 0; i < gasPrices.length; i++) {
            expectedAverage += gasPrices[i];
        }
        expectedAverage /= uint128(gasPrices.length);

        assertEq(hook.movingAverageGasPrice(), expectedAverage);
        assertEq(hook.movingAverageGasPriceCount(), gasPrices.length);
    }

    function test_feeAdjustmentImpact() public {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -0.001 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Perform swaps with different gas prices and compare outputs
        uint256[] memory outputs = new uint256[](3);

        // Baseline swap at average gas price
        vm.txGasPrice(10 gwei);
        uint256 balanceBefore = currency1.balanceOfSelf();
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        outputs[0] = currency1.balanceOfSelf() - balanceBefore;

        // Swap with higher gas price (lower fee)
        vm.txGasPrice(20 gwei);
        balanceBefore = currency1.balanceOfSelf();
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        outputs[1] = currency1.balanceOfSelf() - balanceBefore;

        // Swap with lower gas price (higher fee)
        vm.txGasPrice(5 gwei);
        balanceBefore = currency1.balanceOfSelf();
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        outputs[2] = currency1.balanceOfSelf() - balanceBefore;

        // Check that the outputs reflect the fee adjustments
        assertGt(outputs[1], outputs[0], "Higher gas price should result in larger output");
        assertLt(outputs[2], outputs[0], "Lower gas price should result in smaller output");
    }
}
