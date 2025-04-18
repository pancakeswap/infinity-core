// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity 0.8.26;

import {ProtocolFees} from "../ProtocolFees.sol";
import {Hooks} from "../libraries/Hooks.sol";
import {BinPool} from "./libraries/BinPool.sol";
import {BinPoolParametersHelper} from "./libraries/BinPoolParametersHelper.sol";
import {ParametersHelper} from "../libraries/math/ParametersHelper.sol";
import {Currency, CurrencyLibrary} from "../types/Currency.sol";
import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {IBinPoolManager} from "./interfaces/IBinPoolManager.sol";
import {PoolId} from "../types/PoolId.sol";
import {PoolKey} from "../types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "../types/BalanceDelta.sol";
import {IVault} from "../interfaces/IVault.sol";
import {BinPosition} from "./libraries/BinPosition.sol";
import {LPFeeLibrary} from "../libraries/LPFeeLibrary.sol";
import {PackedUint128Math} from "./libraries/math/PackedUint128Math.sol";
import {Extsload} from "../Extsload.sol";
import {BinHooks} from "./libraries/BinHooks.sol";
import {PriceHelper} from "./libraries/PriceHelper.sol";
import {BeforeSwapDelta} from "../types/BeforeSwapDelta.sol";
import {BinSlot0} from "./types/BinSlot0.sol";
import {VaultAppDeltaSettlement} from "../libraries/VaultAppDeltaSettlement.sol";

/// @notice Holds the state for all bin pools
contract BinPoolManager is IBinPoolManager, ProtocolFees, Extsload {
    using BinPool for *;
    using BinPosition for mapping(bytes32 => BinPosition.Info);
    using BinPoolParametersHelper for bytes32;
    using LPFeeLibrary for uint24;
    using PackedUint128Math for bytes32;
    using Hooks for bytes32;
    using VaultAppDeltaSettlement for IVault;

    /// @inheritdoc IBinPoolManager
    uint16 public constant override MIN_BIN_STEP = 1;

    /// @inheritdoc IBinPoolManager
    uint16 public override maxBinStep = 100;

    /// @inheritdoc IBinPoolManager
    uint256 public override minBinShareForDonate = 2 ** 128;

    mapping(PoolId id => BinPool.State poolState) public pools;

    mapping(PoolId id => PoolKey poolKey) public poolIdToPoolKey;

    constructor(IVault vault) ProtocolFees(vault) {}

    /// @notice pool manager specified in the pool key must match current contract
    modifier poolManagerMatch(address poolManager) {
        if (address(this) != poolManager) revert PoolManagerMismatch();
        _;
    }

    /// @inheritdoc IBinPoolManager
    function getSlot0(PoolId id) external view override returns (uint24 activeId, uint24 protocolFee, uint24 lpFee) {
        BinSlot0 slot0 = pools[id].slot0;

        return (slot0.activeId(), slot0.protocolFee(), slot0.lpFee());
    }

    /// @inheritdoc IBinPoolManager
    function getBin(PoolId id, uint24 binId)
        external
        view
        override
        returns (uint128 binReserveX, uint128 binReserveY, uint256 binLiquidity, uint256 totalShares)
    {
        PoolKey memory key = poolIdToPoolKey[id];
        (binReserveX, binReserveY, binLiquidity, totalShares) = pools[id].getBin(key.parameters.getBinStep(), binId);
    }

    /// @inheritdoc IBinPoolManager
    function getPosition(PoolId id, address owner, uint24 binId, bytes32 salt)
        external
        view
        override
        returns (BinPosition.Info memory position)
    {
        return pools[id].positions.get(owner, binId, salt);
    }

    /// @inheritdoc IBinPoolManager
    function getNextNonEmptyBin(PoolId id, bool swapForY, uint24 binId)
        external
        view
        override
        returns (uint24 nextId)
    {
        nextId = pools[id].getNextNonEmptyBin(swapForY, binId);
    }

    /// @inheritdoc IBinPoolManager
    function initialize(PoolKey memory key, uint24 activeId)
        external
        override
        poolManagerMatch(address(key.poolManager))
    {
        uint16 binStep = key.parameters.getBinStep();
        if (binStep < MIN_BIN_STEP) revert BinStepTooSmall(binStep);
        if (binStep > maxBinStep) revert BinStepTooLarge(binStep);
        if (key.currency0 >= key.currency1) {
            revert CurrenciesInitializedOutOfOrder(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
        }

        // safety check, making sure that the price can be calculated
        PriceHelper.getPriceFromId(activeId, binStep);

        ParametersHelper.checkUnusedBitsAllZero(
            key.parameters, BinPoolParametersHelper.OFFSET_MOST_SIGNIFICANT_UNUSED_BITS
        );
        Hooks.validateHookConfig(key);
        BinHooks.validatePermissionsConflict(key);

        /// @notice init value for dynamic lp fee is 0, but hook can still set it in afterInitialize
        uint24 lpFee = key.fee.getInitialLPFee();
        lpFee.validate(LPFeeLibrary.TEN_PERCENT_FEE);

        BinHooks.beforeInitialize(key, activeId);

        PoolId id = key.toId();

        uint24 protocolFee = _fetchProtocolFee(key);
        pools[id].initialize(activeId, protocolFee, lpFee);

        poolIdToPoolKey[id] = key;

        /// @notice Make sure the first event is noted, so that later events from afterHook won't get mixed up with this one
        emit Initialize(id, key.currency0, key.currency1, key.hooks, key.fee, key.parameters, activeId);

        BinHooks.afterInitialize(key, activeId);
    }

    /// @inheritdoc IBinPoolManager
    function swap(PoolKey memory key, bool swapForY, int128 amountSpecified, bytes calldata hookData)
        external
        override
        whenNotPaused
        returns (BalanceDelta delta)
    {
        if (amountSpecified == 0) revert AmountSpecifiedIsZero();

        PoolId id = key.toId();
        BinPool.State storage pool = pools[id];
        pool.checkPoolInitialized();

        (int128 amountToSwap, BeforeSwapDelta beforeSwapDelta, uint24 lpFeeOverride) =
            BinHooks.beforeSwap(key, swapForY, amountSpecified, hookData);

        /// @dev fix stack too deep
        {
            BinPool.SwapState memory state;
            (delta, state) = pool.swap(
                BinPool.SwapParams({
                    swapForY: swapForY,
                    binStep: key.parameters.getBinStep(),
                    lpFeeOverride: lpFeeOverride,
                    amountSpecified: amountToSwap
                })
            );

            unchecked {
                if (state.feeAmountToProtocol > 0) {
                    protocolFeesAccrued[key.currency0] += state.feeAmountToProtocol.decodeX();
                    protocolFeesAccrued[key.currency1] += state.feeAmountToProtocol.decodeY();
                }
            }

            /// @notice Make sure the first event is noted, so that later events from afterHook won't get mixed up with this one
            emit Swap(
                id, msg.sender, delta.amount0(), delta.amount1(), state.activeId, state.swapFee, state.protocolFee
            );
        }

        BalanceDelta hookDelta;
        (delta, hookDelta) = BinHooks.afterSwap(key, swapForY, amountSpecified, delta, hookData, beforeSwapDelta);

        vault.accountAppDeltaWithHookDelta(key, delta, hookDelta);
    }

    /// @inheritdoc IBinPoolManager
    function mint(PoolKey memory key, IBinPoolManager.MintParams calldata params, bytes calldata hookData)
        external
        override
        whenNotPaused
        returns (BalanceDelta delta, BinPool.MintArrays memory mintArray)
    {
        PoolId id = key.toId();
        BinPool.State storage pool = pools[id];
        pool.checkPoolInitialized();

        (uint24 lpFeeOverride) = BinHooks.beforeMint(key, params, hookData);

        bytes32 feeAmountToProtocol;
        bytes32 compositionFeeAmount;
        (delta, feeAmountToProtocol, mintArray, compositionFeeAmount) = pool.mint(
            BinPool.MintParams({
                to: msg.sender,
                liquidityConfigs: params.liquidityConfigs,
                amountIn: params.amountIn,
                binStep: key.parameters.getBinStep(),
                lpFeeOverride: lpFeeOverride,
                salt: params.salt
            })
        );

        unchecked {
            if (feeAmountToProtocol > 0) {
                protocolFeesAccrued[key.currency0] += feeAmountToProtocol.decodeX();
                protocolFeesAccrued[key.currency1] += feeAmountToProtocol.decodeY();
            }
        }

        /// @notice Make sure the first event is noted, so that later events from afterHook won't get mixed up with this one
        emit Mint(
            id, msg.sender, mintArray.ids, params.salt, mintArray.amounts, compositionFeeAmount, feeAmountToProtocol
        );

        BalanceDelta hookDelta;
        (delta, hookDelta) = BinHooks.afterMint(key, params, delta, hookData);

        vault.accountAppDeltaWithHookDelta(key, delta, hookDelta);
    }

    /// @inheritdoc IBinPoolManager
    function burn(PoolKey memory key, IBinPoolManager.BurnParams memory params, bytes calldata hookData)
        external
        override
        returns (BalanceDelta delta)
    {
        PoolId id = key.toId();
        BinPool.State storage pool = pools[id];
        pool.checkPoolInitialized();

        BinHooks.beforeBurn(key, params, hookData);

        uint256[] memory binIds;
        bytes32[] memory amountRemoved;
        (delta, binIds, amountRemoved) = pool.burn(
            BinPool.BurnParams({
                from: msg.sender,
                ids: params.ids,
                amountsToBurn: params.amountsToBurn,
                salt: params.salt
            })
        );

        /// @notice Make sure the first event is noted, so that later events from afterHook won't get mixed up with this one
        emit Burn(id, msg.sender, binIds, params.salt, amountRemoved);

        BalanceDelta hookDelta;
        (delta, hookDelta) = BinHooks.afterBurn(key, params, delta, hookData);

        vault.accountAppDeltaWithHookDelta(key, delta, hookDelta);
    }

    function donate(PoolKey memory key, uint128 amount0, uint128 amount1, bytes calldata hookData)
        external
        override
        whenNotPaused
        returns (BalanceDelta delta, uint24 binId)
    {
        PoolId id = key.toId();
        BinPool.State storage pool = pools[id];
        pool.checkPoolInitialized();

        BinHooks.beforeDonate(key, amount0, amount1, hookData);

        /// @dev Share is 1:1 liquidity when liquidity is first added to bin
        uint256 currentBinShare = pool.shareOfBin[pool.slot0.activeId()];
        if (currentBinShare < minBinShareForDonate) {
            revert InsufficientBinShareForDonate(currentBinShare);
        }

        (delta, binId) = pool.donate(key.parameters.getBinStep(), amount0, amount1);

        vault.accountAppBalanceDelta(key.currency0, key.currency1, delta, msg.sender);

        /// @notice Make sure the first event is noted, so that later events from afterHook won't get mixed up with this one
        emit Donate(id, msg.sender, delta.amount0(), delta.amount1(), binId);

        BinHooks.afterDonate(key, amount0, amount1, hookData);
    }

    /// @inheritdoc IBinPoolManager
    function setMaxBinStep(uint16 newMaxBinStep) external override onlyOwner {
        if (newMaxBinStep <= MIN_BIN_STEP) revert MaxBinStepTooSmall(newMaxBinStep);

        maxBinStep = newMaxBinStep;
        emit SetMaxBinStep(newMaxBinStep);
    }

    /// @inheritdoc IBinPoolManager
    function setMinBinSharesForDonate(uint256 minBinShare) external override onlyOwner {
        minBinShareForDonate = minBinShare;
        emit SetMinBinSharesForDonate(minBinShare);
    }

    /// @inheritdoc IPoolManager
    function updateDynamicLPFee(PoolKey memory key, uint24 newDynamicLPFee) external override {
        if (!key.fee.isDynamicLPFee() || msg.sender != address(key.hooks)) revert UnauthorizedDynamicLPFeeUpdate();
        newDynamicLPFee.validate(LPFeeLibrary.TEN_PERCENT_FEE);

        PoolId id = key.toId();
        pools[id].setLPFee(newDynamicLPFee);
        emit DynamicLPFeeUpdated(id, newDynamicLPFee);
    }

    function _setProtocolFee(PoolId id, uint24 newProtocolFee) internal override {
        pools[id].setProtocolFee(newProtocolFee);
    }
}
