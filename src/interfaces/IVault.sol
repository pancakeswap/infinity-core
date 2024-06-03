//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Currency} from "../types/Currency.sol";
import {IVaultToken} from "./IVaultToken.sol";

interface IVault is IVaultToken {
    event PoolManagerRegistered(address indexed poolManager);

    /// @notice Thrown when a pool manager is not registered
    error PoolManagerUnregistered();

    /// @notice Thrown when a currency is not netted out after a lock
    error CurrencyNotSettled();

    /// @notice Thrown when there is already a locker
    /// @param locker The address of the current locker
    error LockerAlreadySet(address locker);

    /// @notice Thrown when passing in msg.value for non-native currency
    error SettleNonNativeCurrencyWithValue();

    /// @notice Thrown when there is no locker
    error NoLocker();

    function isPoolManagerRegistered(address poolManager) external returns (bool);

    /// @notice Returns the reserves for a currency thats sync in transient storage
    function reservesOfVault(Currency currency) external view returns (uint256);

    /// @notice Returns the reserves for a a given pool type and currency
    function reservesOfPoolManager(address poolManager, Currency currency) external view returns (uint256);

    /// @notice enable or disable specific pool manager
    function registerPoolManager(address poolManager) external;

    /// @notice Returns the locker who is locking the vault
    function getLocker() external view returns (address locker);

    /// @notice Returns lock data
    function getUnsettledDeltasCount() external view returns (uint256 count);

    /// @notice Get the current delta for a locker in the given currency
    /// @param currency The currency for which to lookup the delta
    function currencyDelta(address settler, Currency currency) external view returns (int256);

    /// @notice All operations go through this function
    /// @param data Any data to pass to the callback, via `ILockCallback(msg.sender).lockCallback(data)`
    /// @return The data returned by the call to `ILockCallback(msg.sender).lockCallback(data)`
    function lock(bytes calldata data) external returns (bytes memory);

    /// @notice Called by the pool manager to account for a change in the pool balance,
    /// typically after modifyLiquidity, swap, donate
    /// @param currency The currency to update
    /// @param delta The change in the pool's balance
    /// @param settler The address whose delta will be updated
    function accountPoolBalanceDelta(Currency currency, int128 delta, address settler) external;

    /// @notice Called by the user to net out some value owed to the user
    /// @dev Can also be used as a mechanism for _free_ flash loans
    function take(Currency currency, address to, uint256 amount) external;

    /// @notice Called before erc20 transfer to tstore the current reserve balance
    function sync(Currency token0) external returns (uint256 balance);

    /// @notice Called by the user to pay what is owed
    function settle(Currency token) external payable returns (uint256 paid);

    /// @notice move the delta from target to the msg.sender, only payment delta can be moved
    /// @param currency The currency to settle
    /// @param target The address whose delta will be updated
    /// @param amount The amount to settle. 0 to settle all outstanding debt
    function settleFor(Currency currency, address target, uint256 amount) external;

    /// @notice Called by pool manager to collect any fee related
    /// @dev no restriction on caller, underflow happen if caller collect more than the reserve
    function collectFee(Currency currency, uint256 amount, address recipient) external;

    /// @notice Called by the user to store surplus tokens in the vault
    function mint(address to, Currency currency, uint256 amount) external;

    /// @notice Called by the user to use surplus tokens for payment settlement
    function burn(address from, Currency currency, uint256 amount) external;
}
