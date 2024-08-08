// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.0;

import {Owner} from "./Owner.sol";
import {Currency} from "./types/Currency.sol";
import {IProtocolFeeController} from "./interfaces/IProtocolFeeController.sol";
import {IProtocolFees} from "./interfaces/IProtocolFees.sol";
import {ProtocolFeeLibrary} from "./libraries/ProtocolFeeLibrary.sol";
import {PoolKey} from "./types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "./types/PoolId.sol";
import {IVault} from "./interfaces/IVault.sol";

abstract contract ProtocolFees is IProtocolFees, Owner {
    using PoolIdLibrary for PoolKey;
    using ProtocolFeeLibrary for uint24;

    /// @inheritdoc IProtocolFees
    mapping(Currency currency => uint256 amount) public protocolFeesAccrued;

    /// @inheritdoc IProtocolFees
    IProtocolFeeController public protocolFeeController;

    /// @inheritdoc IProtocolFees
    IVault public immutable vault;

    uint256 private immutable controllerGasLimit;

    constructor(IVault _vault, uint256 _controllerGasLimit) {
        vault = _vault;
        controllerGasLimit = _controllerGasLimit;
    }

    function _setProtocolFee(PoolId id, uint24 newProtocolFee) internal virtual;

    /// @inheritdoc IProtocolFees
    function setProtocolFee(PoolKey memory key, uint24 newProtocolFee) external virtual {
        if (msg.sender != address(protocolFeeController)) revert InvalidCaller();
        if (!newProtocolFee.validate()) revert ProtocolFeeTooLarge(newProtocolFee);
        PoolId id = key.toId();
        _setProtocolFee(id, newProtocolFee);
        emit ProtocolFeeUpdated(id, newProtocolFee);
    }

    /// @notice Fetch the protocol fee for a given pool, returning false if the call fails or the returned fee is invalid.
    /// @dev to prevent an invalid protocol fee controller from blocking pools from being initialized
    ///      the success of this function is NOT checked on initialize and if the call fails, the protocol fee is set to 0.
    /// @dev the success of this function must be checked when called in setProtocolFee
    function _fetchProtocolFee(PoolKey memory key) internal returns (bool success, uint24 protocolFee) {
        if (address(protocolFeeController) != address(0)) {
            // note that EIP-150 mandates that calls requesting more than 63/64ths of remaining gas
            // will be allotted no more than this amount, so controllerGasLimit must be set with this
            // in mind.
            if (gasleft() < controllerGasLimit) revert ProtocolFeeCannotBeFetched();

            uint256 gasLimit = controllerGasLimit;
            address targetProtocolFeeController = address(protocolFeeController);
            bytes memory data = abi.encodeCall(IProtocolFeeController.protocolFeeForPool, (key));
            uint256 returnData;
            assembly ("memory-safe") {
                success := call(gasLimit, targetProtocolFeeController, 0, add(data, 0x20), mload(data), 0, 0)

                // success if return data size is 32 bytes
                // only load the return value if it is 32 bytes to prevent gas griefing
                success := and(success, eq(returndatasize(), 32))

                // load the return data if success is true
                if success {
                    let fmp := mload(0x40)
                    returndatacopy(fmp, 0, returndatasize())
                    returnData := mload(fmp)
                    mstore(fmp, 0)
                }
            }

            (success, protocolFee) = success && (returnData == uint24(returnData)) && uint24(returnData).validate()
                ? (true, uint24(returnData))
                : (false, 0);
        }
    }

    function setProtocolFeeController(IProtocolFeeController controller) external onlyOwner {
        protocolFeeController = controller;
        emit ProtocolFeeControllerUpdated(address(controller));
    }

    function collectProtocolFees(address recipient, Currency currency, uint256 amount)
        external
        override
        returns (uint256 amountCollected)
    {
        if (msg.sender != owner() && msg.sender != address(protocolFeeController)) revert InvalidCaller();

        amountCollected = (amount == 0) ? protocolFeesAccrued[currency] : amount;
        protocolFeesAccrued[currency] -= amountCollected;
        vault.collectFee(currency, amountCollected, recipient);
    }
}
