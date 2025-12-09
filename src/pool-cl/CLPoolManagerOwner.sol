// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity 0.8.26;

import {IProtocolFeeController} from "../interfaces/IProtocolFeeController.sol";
import {PausableRole} from "../base/PausableRole.sol";
import {PoolManagerOwnable2Step} from "../base/PoolManagerOwnable2Step.sol";
import {ICLPoolManager} from "./interfaces/ICLPoolManager.sol";
import {IPoolManagerOwner} from "../interfaces/IPoolManagerOwner.sol";

/// @dev added interface in this file to avoid polluting other files in repository
interface ICLPoolManagerWithPauseOwnable is ICLPoolManager {
    function pause() external;
    function unpause() external;
    function transferOwnership(address newOwner) external;
}

/**
 * @dev This contract is the owner of the CLPoolManager contract
 *
 * A seperate owner contract is used to handle some functionality so as to reduce the contract size
 * of PoolManager. This allow a higher optimizer run, reducing the gas cost for other poolManager functions.
 */
contract CLPoolManagerOwner is IPoolManagerOwner, PoolManagerOwnable2Step, PausableRole {
    ICLPoolManagerWithPauseOwnable public immutable poolManager;

    constructor(ICLPoolManagerWithPauseOwnable _poolManager) {
        poolManager = _poolManager;
    }

    /// @inheritdoc IPoolManagerOwner
    function pausePoolManager() external override onlyPausableRoleOrOwner {
        poolManager.pause();
    }

    /// @inheritdoc IPoolManagerOwner
    function unpausePoolManager() external override onlyOwner {
        poolManager.unpause();
    }

    /// @inheritdoc IPoolManagerOwner
    function setProtocolFeeController(IProtocolFeeController protocolFeeController) external override onlyOwner {
        poolManager.setProtocolFeeController(protocolFeeController);
    }

    /// @inheritdoc IPoolManagerOwner
    function transferPoolManagerOwnership(address newPoolManagerOwner) external override onlyOwner {
        if (newPoolManagerOwner == address(0)) revert();
        _setPendingPoolManagerOwner(newPoolManagerOwner);
        emit PoolManagerOwnershipTransferStarted(address(this), newPoolManagerOwner);
    }

    /// @inheritdoc IPoolManagerOwner
    function acceptPoolManagerOwnership() external override onlyPendingPoolManagerOwner {
        _setPendingPoolManagerOwner(address(0));
        poolManager.transferOwnership(msg.sender);

        emit PoolManagerOwnershipTransferred(address(this), msg.sender);
    }
}
