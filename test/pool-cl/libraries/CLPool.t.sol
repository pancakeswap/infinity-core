// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {CLPool} from "../../../src/pool-cl/libraries/CLPool.sol";
import {CLPoolManager} from "../../../src/pool-cl/CLPoolManager.sol";
import {CLPosition} from "../../../src/pool-cl/libraries/CLPosition.sol";
import {TickMath} from "../../../src/pool-cl/libraries/TickMath.sol";
import {TickBitmap} from "../../../src/pool-cl/libraries/TickBitmap.sol";
import {Tick} from "../../../src/pool-cl/libraries/Tick.sol";
import {FixedPoint96} from "../../../src/pool-cl/libraries/FixedPoint96.sol";
import {SafeCast} from "../../../src/libraries/SafeCast.sol";
import {LiquidityAmounts} from "../helpers/LiquidityAmounts.sol";
import {LPFeeLibrary} from "../../../src/libraries/LPFeeLibrary.sol";
import {FullMath} from "../../../src/pool-cl/libraries/FullMath.sol";
import {FixedPoint128} from "../../../src/pool-cl/libraries/FixedPoint128.sol";
import {ICLPoolManager} from "../../../src/pool-cl/interfaces/ICLPoolManager.sol";
import {LPFeeLibrary} from "../../../src/libraries/LPFeeLibrary.sol";
import {ProtocolFeeLibrary} from "../../../src/libraries/ProtocolFeeLibrary.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "../../../src/types/BalanceDelta.sol";
import {CLSlot0} from "../../../src/pool-cl/types/CLSlot0.sol";

contract PoolTest is Test {
    using CLPool for CLPool.State;
    using LPFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint24;

    CLPool.State state;

    function testPoolInitialize(uint160 sqrtPriceX96, uint24 protocolFee, uint24 lpFee) public {
        if (sqrtPriceX96 < TickMath.MIN_SQRT_RATIO || sqrtPriceX96 >= TickMath.MAX_SQRT_RATIO) {
            vm.expectRevert(abi.encodeWithSelector(TickMath.InvalidSqrtRatio.selector, sqrtPriceX96));
            state.initialize(sqrtPriceX96, protocolFee, lpFee);
        } else {
            state.initialize(sqrtPriceX96, protocolFee, lpFee);
            assertEq(state.slot0.sqrtPriceX96(), sqrtPriceX96);
            assertEq(state.slot0.protocolFee(), protocolFee);
            assertEq(state.slot0.tick(), TickMath.getTickAtSqrtRatio(sqrtPriceX96));
            assertLt(state.slot0.tick(), TickMath.MAX_TICK);
            assertGt(state.slot0.tick(), TickMath.MIN_TICK - 1);
            assertEq(state.slot0.lpFee(), lpFee);
        }
    }

    function testModifyPosition(
        uint160 sqrtPriceX96,
        CLPool.ModifyLiquidityParams memory params,
        uint24 lpFee,
        uint24 protocolFee
    ) public {
        // Assumptions tested in PoolManager.t.sol
        params.tickSpacing = int24(bound(params.tickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));

        testPoolInitialize(sqrtPriceX96, protocolFee, lpFee);

        if (params.tickLower >= params.tickUpper) {
            vm.expectRevert(abi.encodeWithSelector(Tick.TicksMisordered.selector, params.tickLower, params.tickUpper));
        } else if (params.tickLower < TickMath.MIN_TICK) {
            vm.expectRevert(abi.encodeWithSelector(Tick.TickLowerOutOfBounds.selector, params.tickLower));
        } else if (params.tickUpper > TickMath.MAX_TICK) {
            vm.expectRevert(abi.encodeWithSelector(Tick.TickUpperOutOfBounds.selector, params.tickUpper));
        } else if (params.liquidityDelta < 0) {
            vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        } else if (params.liquidityDelta == 0) {
            vm.expectRevert(CLPosition.CannotUpdateEmptyPosition.selector);
        } else if (params.liquidityDelta > int128(Tick.tickSpacingToMaxLiquidityPerTick(params.tickSpacing))) {
            vm.expectRevert(abi.encodeWithSelector(Tick.TickLiquidityOverflow.selector, params.tickLower));
        } else if (params.tickLower % params.tickSpacing != 0) {
            vm.expectRevert(
                abi.encodeWithSelector(TickBitmap.TickMisaligned.selector, params.tickLower, params.tickSpacing)
            );
        } else if (params.tickUpper % params.tickSpacing != 0) {
            vm.expectRevert(
                abi.encodeWithSelector(TickBitmap.TickMisaligned.selector, params.tickUpper, params.tickSpacing)
            );
        } else {
            // We need the assumptions above to calculate this
            uint256 maxInt128InTypeU256 = uint256(uint128(type(int128).max));
            (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(params.tickLower),
                TickMath.getSqrtRatioAtTick(params.tickUpper),
                uint128(params.liquidityDelta)
            );

            if ((amount0 > maxInt128InTypeU256) || (amount1 > maxInt128InTypeU256)) {
                vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflow.selector));
            }
        }

        params.owner = address(this);
        state.modifyLiquidity(params);
    }

    function testSwap(
        uint160 sqrtPriceX96,
        CLPool.ModifyLiquidityParams memory modifyLiquidityParams,
        CLPool.SwapParams memory swapParams,
        uint24 lpFee,
        uint16 protocolFee0,
        uint16 protocolFee1
    ) public {
        // modifyLiquidityParams = CLPool.ModifyLiquidityParams({
        //     owner: 0x250Eb93F2C350590E52cdb977b8BcF502a1Db7e7,
        //     tickLower: -402986,
        //     tickUpper: 50085,
        //     liquidityDelta: 33245614918536803008426086500145,
        //     tickSpacing: 1,
        //     salt: 0xfd9c91c4f1bbf3d855ba0a973b97c685c1dd51875a574392ef94ab56d7a72528
        // });
        // swapParams = CLPool.SwapParams({
        //     tickSpacing: 8807,
        //     zeroForOne: true,
        //     amountSpecified: 20406714586857485490153777552586525,
        //     sqrtPriceLimitX96: 3669890892491818487,
        //     lpFeeOverride: 440
        // });
        // TODO: find a better way to cover following case:
        // 1. when amountSpecified is large enough
        // 2. and the effect price is either too large or too small (due to larger price slippage or inproper liquidity range)
        // It will cause the amountUnspecified to be out of int128 range hence the tx reverts with SafeCastOverflow
        // try to comment following three limitations and uncomment above case and rerun the test to verify

        lpFee = uint24(bound(lpFee, 0, LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE));
        protocolFee0 = uint16(bound(protocolFee0, 0, ProtocolFeeLibrary.MAX_PROTOCOL_FEE));
        protocolFee1 = uint16(bound(protocolFee1, 0, ProtocolFeeLibrary.MAX_PROTOCOL_FEE));
        uint24 protocolFee = protocolFee1 << 12 | protocolFee0;

        modifyLiquidityParams.tickLower = -100;
        modifyLiquidityParams.tickUpper = 100;
        swapParams.amountSpecified = int256(bound(swapParams.amountSpecified, 0, type(int128).max));

        testModifyPosition(sqrtPriceX96, modifyLiquidityParams, lpFee, protocolFee);

        swapParams.tickSpacing = modifyLiquidityParams.tickSpacing;
        CLSlot0 slot0 = state.slot0;

        // avoid lpFee override valid
        if (
            swapParams.lpFeeOverride.isOverride()
                && swapParams.lpFeeOverride.removeOverrideFlag() > LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE
        ) {
            return;
        }

        uint24 lpSwapFee = swapParams.lpFeeOverride.isOverride()
            ? swapParams.lpFeeOverride.removeOverrideAndValidate(LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE)
            : lpFee;
        /// @dev the fee charged on the swap is the combination of the protocol fee and the lp fee
        uint16 swapProtocolFee = swapParams.zeroForOne ? protocolFee.getZeroForOneFee() : protocolFee.getOneForZeroFee();
        uint24 swapFee =
            swapProtocolFee == 0 ? lpSwapFee : ProtocolFeeLibrary.calculateSwapFee(swapProtocolFee, lpSwapFee);

        bool invalidSqrtPriceLimit = swapParams.zeroForOne
            ? (swapParams.sqrtPriceLimitX96 >= slot0.sqrtPriceX96()
                    || swapParams.sqrtPriceLimitX96 <= TickMath.MIN_SQRT_RATIO)
            : (swapParams.sqrtPriceLimitX96 <= slot0.sqrtPriceX96()
                    || swapParams.sqrtPriceLimitX96 >= TickMath.MAX_SQRT_RATIO);

        if (invalidSqrtPriceLimit) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    CLPool.InvalidSqrtPriceLimit.selector, slot0.sqrtPriceX96(), swapParams.sqrtPriceLimitX96
                )
            );
        } else if (swapFee >= LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE && swapParams.amountSpecified >= 0) {
            /// @dev a swap fee totaling 100% makes exact output swaps impossible
            vm.expectRevert(CLPool.InvalidFeeForExactOut.selector);
        }

        (BalanceDelta delta,) = state.swap(swapParams);

        if (swapParams.amountSpecified == 0) {
            // early return if amountSpecified is 0
            assertTrue(delta == BalanceDeltaLibrary.ZERO_DELTA);
            return;
        }

        if (
            modifyLiquidityParams.liquidityDelta == 0
                || (swapParams.zeroForOne && slot0.tick() < modifyLiquidityParams.tickLower)
                || (!swapParams.zeroForOne && slot0.tick() >= modifyLiquidityParams.tickUpper)
        ) {
            // no liquidity, hence all the way to the limit
            if (swapParams.zeroForOne) {
                assertEq(state.slot0.sqrtPriceX96(), swapParams.sqrtPriceLimitX96);
            } else {
                assertEq(state.slot0.sqrtPriceX96(), swapParams.sqrtPriceLimitX96);
            }
        } else {
            if (swapParams.zeroForOne) {
                assertGe(state.slot0.sqrtPriceX96(), swapParams.sqrtPriceLimitX96);
            } else {
                assertLe(state.slot0.sqrtPriceX96(), swapParams.sqrtPriceLimitX96);
            }
        }
    }

    function testDonate(
        uint160 sqrtPriceX96,
        CLPool.ModifyLiquidityParams memory params,
        uint256 amount0,
        uint256 amount1,
        uint24 lpFee,
        uint16 protocolFee0,
        uint16 protocolFee1
    ) public {
        lpFee = uint24(bound(lpFee, 0, LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE));
        protocolFee0 = uint16(bound(protocolFee0, 0, ProtocolFeeLibrary.MAX_PROTOCOL_FEE));
        protocolFee1 = uint16(bound(protocolFee1, 0, ProtocolFeeLibrary.MAX_PROTOCOL_FEE));
        uint24 protocolFee = protocolFee1 << 12 | protocolFee0;

        testModifyPosition(sqrtPriceX96, params, lpFee, protocolFee);

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        if (!(params.liquidityDelta > 0 && tick >= params.tickLower && tick < params.tickUpper)) {
            vm.expectRevert(CLPool.NoLiquidityToReceiveFees.selector);
        }
        /// @dev due to "delta = toBalanceDelta(amount0.toInt128(), amount1.toInt128());"
        /// amount0 and amount1 must be less than or equal to type(int128).max
        else if (amount0 > uint128(type(int128).max) || amount1 > uint128(type(int128).max)) {
            vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        }

        uint256 feeGrowthGlobal0BeforeDonate = state.feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1BeforeDonate = state.feeGrowthGlobal1X128;
        state.donate(amount0, amount1);
        uint256 feeGrowthGlobal0AfterDonate = state.feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1AftereDonate = state.feeGrowthGlobal1X128;

        if (state.liquidity != 0) {
            assertEq(
                feeGrowthGlobal0AfterDonate - feeGrowthGlobal0BeforeDonate,
                FullMath.mulDiv(amount0, FixedPoint128.Q128, state.liquidity)
            );
            assertEq(
                feeGrowthGlobal1AftereDonate - feeGrowthGlobal1BeforeDonate,
                FullMath.mulDiv(amount1, FixedPoint128.Q128, state.liquidity)
            );
        }
    }
}
