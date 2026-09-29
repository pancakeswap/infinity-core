// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {AccessControl, IAccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {PoolKey} from "./types/PoolKey.sol";
import {Currency} from "./types/Currency.sol";
import {LPFeeLibrary} from "./libraries/LPFeeLibrary.sol";
import {IProtocolFeeController} from "./interfaces/IProtocolFeeController.sol";
import {IProtocolFees} from "./interfaces/IProtocolFees.sol";
import {ProtocolFeeLibrary} from "./libraries/ProtocolFeeLibrary.sol";

/// @notice ProtocolFeeController for both Pool type
contract ProtocolFeeController is IProtocolFeeController, Ownable2Step, AccessControlEnumerable {
    /// @notice throw when the pool manager saved does not match the pool manager from the pool key
    error InvalidPoolManager();

    /// @notice throw when the default protocol fee for dynamic fee pool is invalid i.e. greater than 0.4%
    error InvalidDefaultProtocolFeeForDynamicFeePool();

    /// @notice throw when the protocol fee split ratio is invalid i.e. greater than 100%
    error InvalidProtocolFeeSplitRatio();

    /// @notice throw when the input arrays of a batch function have different lengths
    error ArrayLengthMismatch();

    /// @notice 100% in hundredths of a bip
    uint256 private constant ONE_HUNDRED_PERCENT_RATIO = 1e6;

    /// @notice The ratio of the protocol fee in the total fee, expressed in hundredths of a bip i.e. 1e4 is 1%
    /// @dev The default value is 33% i.e. protocol fee should be 33% of the total fee
    uint256 public protocolFeeSplitRatio = 33 * 1e4;

    address public immutable poolManager;

    /// @notice Role allowed to call batchRefreshProtocolFee, i.e. re-apply the current protocolFeeForPool rule to existing pools
    /// @dev Holders cannot set arbitrary fees, they can only sync pools to the fee derived from the owner's configuration.
    /// The role is granted and revoked by the owner only, DEFAULT_ADMIN_ROLE is not used in this contract
    bytes32 public constant FEE_SETTER_ROLE = keccak256("FEE_SETTER_ROLE");

    /// @notice the default protocol fee for dynamic fee pool,
    /// every newly created dynamic fee pool will have this default protocol fee
    /// @dev 1000 = 0.1%, the initial setting is 0.03% i.e. 3bps
    uint24 public defaultProtocolFeeForDynamicFeePool = 300;

    event DefaultProtocolFeeForDynamicFeePoolUpdated(
        uint24 oldDefaultProtocolFeeForDynamicFeePool, uint24 newDefaultProtocolFeeForDynamicFeePool
    );

    event ProtocolFeeSplitRatioUpdated(uint256 oldProtocolFeeSplitRatio, uint256 newProtocolFeeSplitRatio);

    /// @notice emit when the protocol fee is collected
    event ProtocolFeeCollected(Currency indexed currency, uint256 amount);

    constructor(address _poolManager) Ownable(msg.sender) {
        poolManager = _poolManager;
    }

    /// @notice Restrict the function to accounts holding `role` or the owner
    /// @dev reverts with OwnableUnauthorizedAccount if the caller has neither
    modifier onlyRoleOrOwner(bytes32 role) {
        if (!hasRole(role, msg.sender)) _checkOwner();
        _;
    }

    /// @notice Grant `role` to `account`, only callable by the owner
    /// @dev Overrides AccessControl so role management follows Ownable2Step ownership instead of the role admin
    /// @param role The role to grant, e.g. FEE_SETTER_ROLE
    /// @param account The account to receive the role
    function grantRole(bytes32 role, address account) public override(AccessControl, IAccessControl) onlyOwner {
        _grantRole(role, account);
    }

    /// @notice Revoke `role` from `account`, only callable by the owner
    /// @dev Overrides AccessControl so role management follows Ownable2Step ownership instead of the role admin.
    /// Role holders can still give up their own role via renounceRole
    /// @param role The role to revoke, e.g. FEE_SETTER_ROLE
    /// @param account The account to lose the role
    function revokeRole(bytes32 role, address account) public override(AccessControl, IAccessControl) onlyOwner {
        _revokeRole(role, account);
    }

    /// @notice Set the protocol fee used when dynamic fee pools are initialized or refreshed.
    /// @dev Existing pools keep their stored fees until explicitly updated.
    /// @param newDefaultProtocolFeeForDynamicFeePool 1000 = 0.1%, the initial setting is 0.03% i.e. 3bps
    function setDefaultProtocolFeeForDynamicFeePool(uint24 newDefaultProtocolFeeForDynamicFeePool) external onlyOwner {
        // cap the protocol fee at 0.4%, if it's over the limit we revert the tx
        if (newDefaultProtocolFeeForDynamicFeePool > ProtocolFeeLibrary.MAX_PROTOCOL_FEE) {
            revert InvalidDefaultProtocolFeeForDynamicFeePool();
        }

        uint24 oldDefaultProtocolFeeForDynamicFeePool = defaultProtocolFeeForDynamicFeePool;
        defaultProtocolFeeForDynamicFeePool = newDefaultProtocolFeeForDynamicFeePool;

        emit DefaultProtocolFeeForDynamicFeePoolUpdated(
            oldDefaultProtocolFeeForDynamicFeePool, newDefaultProtocolFeeForDynamicFeePool
        );
    }

    /// @notice Set the ratio of the protocol fee in the total fee
    /// @param newProtocolFeeSplitRatio 30e4 would mean 30% of the total fee goes to protocol
    function setProtocolFeeSplitRatio(uint256 newProtocolFeeSplitRatio) external onlyOwner {
        if (newProtocolFeeSplitRatio > ONE_HUNDRED_PERCENT_RATIO) revert InvalidProtocolFeeSplitRatio();

        uint256 oldProtocolFeeSplitRatio = protocolFeeSplitRatio;
        protocolFeeSplitRatio = newProtocolFeeSplitRatio;

        emit ProtocolFeeSplitRatioUpdated(oldProtocolFeeSplitRatio, newProtocolFeeSplitRatio);
    }

    /// @notice Get the LP fee based on protocolFeeSplitRatio and total fee. This is useful for FE to calculate the LP fee
    /// based on user's input when initializing a static fee pool
    /// warning: if protocolFee is over 0.4% based on the totalFee, then it will be capped at 0.4% which means
    /// lpFee in this case will charge more lpFee than expected i.e more than "1 - protocolFeeSplitRatio"
    /// @param totalFee The total fee (including lpFee and protocolFee) for the pool, expressed in hundredths of a bip
    /// @return lpFee The LP fee that can be passed in as poolKey.fee, expressed in hundredths of a bip
    function getLPFeeFromTotalFee(uint24 totalFee) external view returns (uint24) {
        /// @dev the formula is derived from the following equation:
        /// poolKey.fee = lpFee = (totalFee - protocolFee) / (1 - protocolFee)
        uint256 oneDirectionProtocolFee = totalFee * protocolFeeSplitRatio / ONE_HUNDRED_PERCENT_RATIO;
        if (oneDirectionProtocolFee > ProtocolFeeLibrary.MAX_PROTOCOL_FEE) {
            oneDirectionProtocolFee = ProtocolFeeLibrary.MAX_PROTOCOL_FEE;
        }

        return uint24(
            (totalFee - oneDirectionProtocolFee) * ONE_HUNDRED_PERCENT_RATIO
                / (ONE_HUNDRED_PERCENT_RATIO - oneDirectionProtocolFee)
        );
    }

    /// @inheritdoc IProtocolFeeController
    function protocolFeeForPool(PoolKey memory poolKey) public view override returns (uint24 protocolFee) {
        if (address(poolKey.poolManager) != poolManager) revert InvalidPoolManager();

        // calculate the protocol fee based on the predefined rule
        uint256 lpFee = poolKey.fee;
        if (lpFee == LPFeeLibrary.DYNAMIC_FEE_FLAG) {
            /// @notice for dynamic fee pools, the default protocol fee is set separately
            return _buildProtocolFee(defaultProtocolFeeForDynamicFeePool);
        } else if (protocolFeeSplitRatio == 0) {
            return _buildProtocolFee(0);
        } else if (protocolFeeSplitRatio == ONE_HUNDRED_PERCENT_RATIO) {
            return _buildProtocolFee(ProtocolFeeLibrary.MAX_PROTOCOL_FEE);
        } else {
            /// @notice for static fee pools, the protocol fee should be a portion of the total fee based on 'protocolFeeSplitRatio'
            /// @dev the formula is derived from the following equation:
            /// totalSwapFee = protocolFee + (1 - protocolFee) * lpFee = protocolFee / protocolFeeSplitRatio
            uint24 oneDirectionProtocolFee = uint24(
                lpFee * ONE_HUNDRED_PERCENT_RATIO
                    / (lpFee
                        + ONE_HUNDRED_PERCENT_RATIO
                        * ONE_HUNDRED_PERCENT_RATIO
                        / protocolFeeSplitRatio
                        - ONE_HUNDRED_PERCENT_RATIO)
            );

            // cap the protocol fee at 0.4%, if it's over the limit we set it to the max
            if (oneDirectionProtocolFee > ProtocolFeeLibrary.MAX_PROTOCOL_FEE) {
                oneDirectionProtocolFee = ProtocolFeeLibrary.MAX_PROTOCOL_FEE;
            }
            return _buildProtocolFee(oneDirectionProtocolFee);
        }
    }

    /// @param fee If 1000, the protocol fee is 0.1%, cap at 0.4%
    /// @return The protocol fee for both directions, the upper 12 bits are for 1->0
    function _buildProtocolFee(uint24 fee) internal pure returns (uint24) {
        return fee + (fee << 12);
    }

    /// @notice Override the default protocol fee for the pool
    /// @dev this could be used for marketing campaign where PCS takes 0 protocol fee for a pool for a period
    /// @param newProtocolFee Packed directional fees: lower 12 bits for 0->1, upper 12 bits for 1->0.
    /// Each direction is capped at 4000, or 0.4% of swap input.
    function setProtocolFee(PoolKey memory key, uint24 newProtocolFee) external onlyOwner {
        _setProtocolFee(key, newProtocolFee);
    }

    /// @notice Override the protocol fee for multiple pools in a single tx
    /// @dev The whole batch reverts if any pool has an invalid pool manager or an invalid fee
    /// @param keys The pools to update
    /// @param newProtocolFees The new protocol fee for each pool in `keys`, same encoding as setProtocolFee
    function batchSetProtocolFee(PoolKey[] calldata keys, uint24[] calldata newProtocolFees) external onlyOwner {
        if (keys.length != newProtocolFees.length) revert ArrayLengthMismatch();
        for (uint256 i; i < keys.length; ++i) {
            _setProtocolFee(keys[i], newProtocolFees[i]);
        }
    }

    /// @notice Reset the protocol fee of multiple pools to the value given by protocolFeeForPool
    /// @dev Useful to sync existing pools after defaultProtocolFeeForDynamicFeePool or protocolFeeSplitRatio is updated.
    /// This replaces any custom fee set via setProtocolFee on the supplied pools, e.g. a 0 fee marketing campaign.
    /// The whole batch reverts if any pool has an invalid pool manager
    /// @param keys The pools to refresh
    function batchRefreshProtocolFee(PoolKey[] calldata keys) external onlyRoleOrOwner(FEE_SETTER_ROLE) {
        for (uint256 i; i < keys.length; ++i) {
            PoolKey memory key = keys[i];
            _setProtocolFee(key, protocolFeeForPool(key));
        }
    }

    /// @notice Set the protocol fee for a pool on the pool manager
    /// @param key The pool to update, must belong to `poolManager`
    /// @param newProtocolFee Packed directional fees, see setProtocolFee
    function _setProtocolFee(PoolKey memory key, uint24 newProtocolFee) internal {
        if (address(key.poolManager) != poolManager) revert InvalidPoolManager();

        // no need to validate the protocol fee as it will be done in the pool manager
        IProtocolFees(address(key.poolManager)).setProtocolFee(key, newProtocolFee);
    }

    /// @notice Collect the protocol fee from the pool manager
    /// @param recipient The address to receive the protocol fee
    /// @param currency The currency of the protocol fee
    /// @param amount The amount of the protocol fee to collect, 0 means collect all
    function collectProtocolFee(address recipient, Currency currency, uint256 amount) external onlyOwner {
        _collectProtocolFee(recipient, currency, amount);
    }

    /// @notice Collect protocol fees for multiple currencies / recipients in a single tx
    /// @dev Entries are processed in order and the whole batch reverts if any collection fails.
    /// Recipients and currencies may repeat, an amount of 0 collects whatever is still accrued for that currency
    /// at that point, so it only makes sense as the last entry of a given currency
    /// @param recipients The address to receive the protocol fee for each entry
    /// @param currencies The currency to collect for each entry
    /// @param amounts The amount to collect for each entry, 0 means collect all remaining
    function batchCollectProtocolFee(
        address[] calldata recipients,
        Currency[] calldata currencies,
        uint256[] calldata amounts
    ) external onlyOwner {
        if (recipients.length != currencies.length || currencies.length != amounts.length) revert ArrayLengthMismatch();
        for (uint256 i; i < currencies.length; ++i) {
            _collectProtocolFee(recipients[i], currencies[i], amounts[i]);
        }
    }

    /// @notice Collect the protocol fee from the pool manager and emit the amount actually received
    /// @param recipient The address to receive the protocol fee
    /// @param currency The currency of the protocol fee
    /// @param amount The amount of the protocol fee to collect, 0 means collect all
    function _collectProtocolFee(address recipient, Currency currency, uint256 amount) internal {
        // balance check to handle fee-on-transfer tokens
        uint256 balanceBefore = currency.balanceOf(recipient);
        IProtocolFees(poolManager).collectProtocolFees(recipient, currency, amount);
        uint256 balanceAfter = currency.balanceOf(recipient);

        emit ProtocolFeeCollected(currency, balanceAfter - balanceBefore);
    }
}
