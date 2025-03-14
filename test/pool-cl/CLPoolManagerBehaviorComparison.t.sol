// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {V3Helper, IUniswapV3Pool, IUniswapV3MintCallback, IUniswapV3SwapCallback} from "./helpers/V3Helper.sol";
import {Deployers} from "./helpers/Deployers.sol";
import {Currency, CurrencyLibrary} from "../../src/types/Currency.sol";
import {Fuzzers} from "./helpers/Fuzzers.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "../../src/types/BalanceDelta.sol";
import {IHooks} from "../../src/interfaces/IHooks.sol";
import {ICLPoolManager} from "../../src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {SqrtPriceMath} from "../../src/pool-cl/libraries/SqrtPriceMath.sol";
import {TickMath} from "../../src/pool-cl/libraries/TickMath.sol";
import {SafeCast} from "../../src/libraries/SafeCast.sol";
import {LiquidityAmounts} from "./helpers/LiquidityAmounts.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {CLPoolManagerRouter} from "./helpers/CLPoolManagerRouter.sol";
import {CLPoolParametersHelper} from "../../src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract V3Fuzzer is V3Helper, Deployers, Fuzzers, IUniswapV3MintCallback, IUniswapV3SwapCallback {
    using CurrencyLibrary for Currency;
    using CLPoolParametersHelper for bytes32;

    IVault vault;
    ICLPoolManager manager;
    CLPoolManagerRouter router;

    Currency currency0;
    Currency currency1;

    function setUp() public virtual override {
        super.setUp();
        (vault, manager) = createFreshManager();
        router = new CLPoolManagerRouter(vault, manager);

        (currency0, currency1) = deployCurrencies(2 ** 255);
        // ensure router has enough allowance to move tokens, required for infinity
        IERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
    }

    function initPools(uint24 fee, int24 tickSpacing, int256 sqrtPriceX96seed)
        internal
        returns (IUniswapV3Pool v3Pool, PoolKey memory key_, uint160 sqrtPriceX96)
    {
        fee = uint24(bound(fee, 0, 999999));
        tickSpacing = int24(bound(tickSpacing, 1, 16383));
        // v3 pools don't allow overwriting existing fees, 500, 3000, 10000 are set by default in the constructor
        if (fee == 500) tickSpacing = 10;
        else if (fee == 3000) tickSpacing = 60;
        else if (fee == 10000) tickSpacing = 200;
        else v3Factory.enableFeeAmount(fee, tickSpacing);

        sqrtPriceX96 = createRandomSqrtPriceX96(tickSpacing, sqrtPriceX96seed);

        v3Pool = IUniswapV3Pool(v3Factory.createPool(Currency.unwrap(currency0), Currency.unwrap(currency1), fee));
        v3Pool.initialize(sqrtPriceX96);

        key_ = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: manager,
            fee: fee,
            parameters: bytes32(0).setTickSpacing(tickSpacing)
        });
        manager.initialize(key_, sqrtPriceX96);
    }

    function addLiquidity(
        IUniswapV3Pool v3Pool,
        PoolKey memory key_,
        uint160 sqrtPriceX96,
        int24 lowerTickUnsanitized,
        int24 upperTickUnsanitized,
        int256 liquidityDeltaUnbound,
        bool tight
    ) internal {
        ICLPoolManager.ModifyLiquidityParams memory infinityLiquidityParams = ICLPoolManager.ModifyLiquidityParams({
            tickLower: lowerTickUnsanitized,
            tickUpper: upperTickUnsanitized,
            liquidityDelta: liquidityDeltaUnbound,
            salt: 0
        });

        infinityLiquidityParams = tight
            ? createFuzzyLiquidityParamsWithTightBound(key_, infinityLiquidityParams, sqrtPriceX96, 20)
            : createFuzzyLiquidityParams(key_, infinityLiquidityParams, sqrtPriceX96);

        v3Pool.mint(
            address(this),
            infinityLiquidityParams.tickLower,
            infinityLiquidityParams.tickUpper,
            uint128(int128(infinityLiquidityParams.liquidityDelta)),
            ""
        );

        router.modifyPosition(key_, infinityLiquidityParams, "");
    }

    function swap(IUniswapV3Pool pool, PoolKey memory key_, bool zeroForOne, int128 amountSpecified)
        internal
        returns (int256 amount0Diff, int256 amount1Diff)
    {
        if (amountSpecified == 0) amountSpecified = 1;
        if (amountSpecified == type(int128).min) amountSpecified = type(int128).min + 1;
        // v3 swap
        (int256 amount0Delta, int256 amount1Delta) = pool.swap(
            // invert amountSpecified because v3 swaps use inverted signs
            address(this),
            zeroForOne,
            amountSpecified * -1,
            zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT,
            ""
        );
        // v3 can handle bigger numbers than infinity version, so if we exceed int128, check that the next call reverts
        bool overflows = false;
        if (
            amount0Delta > type(int128).max || amount1Delta > type(int128).max || amount0Delta < type(int128).min
                || amount1Delta < type(int128).min
        ) {
            overflows = true;
        }
        // infinity version swap
        ICLPoolManager.SwapParams memory swapParams = ICLPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
        CLPoolManagerRouter.SwapTestSettings memory testSettings =
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true});

        BalanceDelta delta;
        try router.swap(key_, swapParams, testSettings, "") returns (BalanceDelta delta_) {
            delta = delta_;
        } catch (bytes memory reason) {
            require(overflows, "infinity version should not overflow");
            assertEq(bytes4(reason), SafeCast.SafeCastOverflow.selector);
            delta = toBalanceDelta(0, 0);
            amount0Delta = 0;
            amount1Delta = 0;
        }

        // because signs for v3 and infinity version swaps are inverted, add values up to get the difference
        amount0Diff = amount0Delta + delta.amount0();
        amount1Diff = amount1Delta + delta.amount1();
    }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external {
        currency0.transfer(msg.sender, amount0Owed);
        currency1.transfer(msg.sender, amount1Owed);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (amount0Delta > 0) currency0.transfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) currency1.transfer(msg.sender, uint256(amount1Delta));
    }
}

contract CLPoolManagerBehaviorComparisonTest is V3Fuzzer {
    function test_shouldSwapEqual(
        uint24 feeSeed,
        int24 tickSpacingSeed,
        int24 lowerTickUnsanitized,
        int24 upperTickUnsanitized,
        int256 liquidityDeltaUnbound,
        int256 sqrtPriceX96seed,
        int128 swapAmount,
        bool zeroForOne
    ) public {
        (IUniswapV3Pool pool, PoolKey memory key_, uint160 sqrtPriceX96) =
            initPools(feeSeed, tickSpacingSeed, sqrtPriceX96seed);
        addLiquidity(pool, key_, sqrtPriceX96, lowerTickUnsanitized, upperTickUnsanitized, liquidityDeltaUnbound, false);
        (int256 amount0Diff, int256 amount1Diff) = swap(pool, key_, zeroForOne, swapAmount);
        assertEq(amount0Diff, 0);
        assertEq(amount1Diff, 0);
    }

    struct TightLiquidityParams {
        int24 lowerTickUnsanitized;
        int24 upperTickUnsanitized;
        int256 liquidityDeltaUnbound;
    }

    function test_shouldSwapEqualMultipleLP(
        uint24 feeSeed,
        int24 tickSpacingSeed,
        TightLiquidityParams[] memory liquidityParams,
        int256 sqrtPriceX96seed,
        int128 swapAmount,
        bool zeroForOne
    ) public {
        (IUniswapV3Pool pool, PoolKey memory key_, uint160 sqrtPriceX96) =
            initPools(feeSeed, tickSpacingSeed, sqrtPriceX96seed);
        for (uint256 i = 0; i < liquidityParams.length; ++i) {
            if (i == 20) break;
            addLiquidity(
                pool,
                key_,
                sqrtPriceX96,
                liquidityParams[i].lowerTickUnsanitized,
                liquidityParams[i].upperTickUnsanitized,
                liquidityParams[i].liquidityDeltaUnbound,
                true
            );
        }

        (int256 amount0Diff, int256 amount1Diff) = swap(pool, key_, zeroForOne, swapAmount);
        assertEq(amount0Diff, 0);
        assertEq(amount1Diff, 0);
    }
}
