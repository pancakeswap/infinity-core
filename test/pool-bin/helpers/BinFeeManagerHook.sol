// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IBinPoolManager} from "../../../src/pool-bin/interfaces/IBinPoolManager.sol";
import {IBinHooks} from "../../../src/pool-bin/interfaces/IBinHooks.sol";
import {PoolKey} from "../../../src/types/PoolKey.sol";
import {IHooks} from "../../../src/interfaces/IHooks.sol";
import {BaseBinTestHook} from "./BaseBinTestHook.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "../../../src/types/BeforeSwapDelta.sol";

contract BinFeeManagerHook is BaseBinTestHook {
    uint16 bitmap;
    uint24 internal fee = 3000; // default 0.3%
    IBinPoolManager public immutable binManager;

    constructor(IBinPoolManager _binManager) {
        binManager = _binManager;
    }

    function setHooksRegistrationBitmap(uint16 _bitmap) external {
        bitmap = _bitmap;
    }

    function getHooksRegistrationBitmap() external view override returns (uint16) {
        return bitmap;
    }

    function setFee(uint24 _fee) external {
        fee = _fee;
    }

    function getFee(address, PoolKey calldata) external view returns (uint24) {
        return fee;
    }

    /// @dev handle mint composition fee related test
    function beforeMint(address, PoolKey calldata key, IBinPoolManager.MintParams calldata, bytes calldata hookData)
        external
        override
        returns (bytes4, uint24)
    {
        if (hookData.length > 0) {
            (bool _update, uint24 _fee) = abi.decode(hookData, (bool, uint24));
            if (_update) {
                fee = _fee;
                binManager.updateDynamicLPFee(key, _fee);
            }
        }

        return (IBinHooks.beforeMint.selector, 0);
    }

    function beforeSwap(address, PoolKey calldata key, bool, int128, bytes calldata hookData)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (hookData.length > 0) {
            (bool _update, uint24 _fee) = abi.decode(hookData, (bool, uint24));
            if (_update) {
                fee = _fee;
                binManager.updateDynamicLPFee(key, _fee);
            }
        }

        return (IBinHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
