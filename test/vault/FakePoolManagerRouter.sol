// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {FakePoolManager} from "./FakePoolManager.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "../../src/types/Currency.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {toBalanceDelta} from "../../src/types/BalanceDelta.sol";

contract FakePoolManagerRouter is Test {
    using CurrencyLibrary for Currency;

    event LockAcquired();

    IVault vault;
    PoolKey poolKey;
    FakePoolManager poolManager;
    Forwarder forwarder;

    constructor(IVault _vault, PoolKey memory _poolKey) {
        vault = _vault;
        poolKey = _poolKey;
        poolManager = FakePoolManager(address(_poolKey.poolManager));
        forwarder = new Forwarder();
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        emit LockAcquired();

        if (data[0] == 0x01) {
            poolManager.mockAccounting(poolKey, 10 ether, 10 ether);
        } else if (data[0] == 0x02) {
            poolManager.mockAccounting(poolKey, 10 ether, 10 ether);
            vault.settle(poolKey.currency0);
            vault.settle(poolKey.currency1);
        } else if (data[0] == 0x03) {
            poolManager.mockAccounting(poolKey, 3 ether, -3 ether);
            vault.settle(poolKey.currency0);
            vault.take(poolKey.currency1, address(this), 3 ether);
        } else if (data[0] == 0x04) {
            poolManager.mockAccounting(poolKey, 15 ether, -15 ether);
            vault.settle(poolKey.currency0);
            vault.take(poolKey.currency1, address(this), 15 ether);
        } else if (data[0] == 0x05) {
            vault.take(poolKey.currency0, address(this), 20 ether);
            vault.take(poolKey.currency1, address(this), 20 ether);

            // ... flashloan logic
            vault.sync(poolKey.currency0);
            vault.sync(poolKey.currency1);
            poolKey.currency0.transfer(address(vault), 20 ether);
            poolKey.currency1.transfer(address(vault), 20 ether);
            vault.settle(poolKey.currency0);
            vault.settle(poolKey.currency1);
        } else if (data[0] == 0x06) {
            // poolKey.poolManager was hacked hence not equal to msg.sender
            PoolKey memory maliciousPoolKey = poolKey;
            maliciousPoolKey.poolManager = IPoolManager(address(0));
            poolManager.mockAccounting(maliciousPoolKey, 3 ether, -3 ether);
        } else if (data[0] == 0x07) {
            // generate nested lock call
            vault.take(poolKey.currency0, address(this), 5 ether);
            vault.take(poolKey.currency1, address(this), 5 ether);

            forwarder.forward(vault);
        } else if (data[0] == 0x08) {
            // settle generated balance delta by 0x07
            vault.sync(poolKey.currency0);
            vault.sync(poolKey.currency1);
            poolKey.currency0.transfer(address(vault), 5 ether);
            poolKey.currency1.transfer(address(vault), 5 ether);
            vault.settle(poolKey.currency0);
            vault.settle(poolKey.currency1);
        } else if (data[0] == 0x09) {
            vault.take(poolKey.currency1, address(this), 5 ether);
        } else if (data[0] == 0x10) {
            // call accountPoolBalanceDelta from arbitrary addr
            vault.accountPoolBalanceDelta(poolKey, toBalanceDelta(int128(1), int128(0)), address(0));
        } else if (data[0] == 0x11) {
            // settleFor
            Payer payer = new Payer();
            payer.settleFor(vault, poolKey.currency0, 5 ether);

            vault.sync(poolKey.currency0);
            poolKey.currency0.transfer(address(vault), 5 ether);
            payer.settle(vault, poolKey.currency0);

            vault.take(poolKey.currency0, address(this), 5 ether);
        } else if (data[0] == 0x12) {
            // settleFor(, , 0)
            Payer payer = new Payer();

            vault.sync(poolKey.currency0);
            uint256 amt = poolKey.currency0.balanceOfSelf();
            poolKey.currency0.transfer(address(vault), amt);
            payer.settle(vault, poolKey.currency0);

            vault.take(poolKey.currency0, address(this), amt);
            payer.settleFor(vault, poolKey.currency0, 0);
        } else if (data[0] == 0x13) {
            // mint
            uint256 amt = poolKey.currency0.balanceOf(address(vault));
            vault.settle(poolKey.currency0);
            vault.mint(address(this), poolKey.currency0, amt);
        } else if (data[0] == 0x14) {
            // mint to someone else, poolKey.currency1 for example
            uint256 amt = poolKey.currency0.balanceOf(address(vault));
            vault.settle(poolKey.currency0);
            vault.mint(Currency.unwrap(poolKey.currency1), poolKey.currency0, amt);
        } else if (data[0] == 0x15) {
            // burn

            uint256 amt = poolKey.currency0.balanceOf(address(vault));
            vault.settle(poolKey.currency0);
            vault.mint(address(this), poolKey.currency0, amt);

            vault.burn(address(this), poolKey.currency0, amt);
            vault.take(poolKey.currency0, address(this), amt);
        } else if (data[0] == 0x16) {
            // burn half if possible

            uint256 amt = poolKey.currency0.balanceOf(address(vault));
            vault.settle(poolKey.currency0);

            vault.mint(address(this), poolKey.currency0, amt);

            vault.burn(address(this), poolKey.currency0, amt / 2);
            vault.take(poolKey.currency0, address(this), amt / 2);
        } else if (data[0] == 0x17) {
            // settle ETH
            vault.settle{value: 5 ether}(CurrencyLibrary.NATIVE);
            vault.take(CurrencyLibrary.NATIVE, address(this), 5 ether);
        } else if (data[0] == 0x18) {
            // settle currency0 and verify currencyDelta
            vault.settle(poolKey.currency0);
            assertEq(vault.currencyDelta(address(this), poolKey.currency0), 0);
        } else if (data[0] == 0x19) {
            // mint & settle first
            uint256 maxBalanceAmt = uint256(int256(type(int128).max));
            uint256 amt = poolKey.currency0.balanceOf(address(vault));
            vault.mint(address(this), poolKey.currency0, amt);
            vault.settle(poolKey.currency0);

            // assert that the manager balance is the full balance.
            assertEq(poolKey.currency0.balanceOf(address(vault)), maxBalanceAmt);

            // sync already called in settle
            assertEq(vault.reservesOfVault(poolKey.currency0), maxBalanceAmt);

            // delta balance should be 0, because it has been fully settled.
            assertEq(vault.currencyDelta(address(this), poolKey.currency0), 0);

            // if not sync and do take
            vault.take(poolKey.currency0, address(this), amt);

            // assert that the manager balance is the full balance.
            assertEq(poolKey.currency0.balanceOf(address(vault)), 0);

            // sync not called so reserveOfVault should still be maxBalanceAmt
            assertEq(vault.reservesOfVault(poolKey.currency0), maxBalanceAmt);

            // Expect an underflow/overflow because reservesBefore > reservesNow since sync() had not been called before settle.
            vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
            vault.settle(poolKey.currency0);

            // reset reserveOfVault to 0
            vault.sync(poolKey.currency0);
            poolKey.currency0.transfer(address(vault), amt);
            vault.settle(poolKey.currency0);
        } else if (data[0] == 0x20) {
            // burn on behalf of someone else
            uint256 amt = poolKey.currency0.balanceOf(address(vault));
            vault.settle(poolKey.currency0);
            vault.mint(address(0x01), poolKey.currency0, amt);

            vault.burn(address(0x01), poolKey.currency0, amt);
            vault.take(poolKey.currency0, address(this), amt);
        } else if (data[0] == 0x21) {
            // currency0 is native and currency1 is erc20
            poolManager.mockAccounting(poolKey, 10 ether, 10 ether);
            vault.settle{value: 10 ether}(poolKey.currency0);
            vault.settle(poolKey.currency1);
        } else if (data[0] == 0x22) {
            // currency0 is native and currency1 is erc20
            vault.take(poolKey.currency0, address(this), 20 ether);
            vault.take(poolKey.currency1, address(this), 20 ether);

            // ... flashloan logic

            // no need to sync currency0 as it is native
            // vault.sync(poolKey.currency0);
            vault.sync(poolKey.currency1);

            // only for erc20 as native will call settle with value
            poolKey.currency1.transfer(address(vault), 20 ether);

            vault.settle{value: 20 ether}(poolKey.currency0);
            vault.settle(poolKey.currency1);
        } else if (data[0] == 0x23) {
            vault.mint(address(this), poolKey.currency0, 10 ether);
            vault.settle(poolKey.currency0);
        }

        return "";
    }

    function callback() external {
        vault.lock(hex"08");
    }

    receive() external payable {}
}

contract Forwarder {
    function forward(IVault vault) external {
        vault.lock(abi.encode(msg.sender));
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        address lastLocker = abi.decode(data, (address));
        FakePoolManagerRouter(payable(lastLocker)).callback();
        return "";
    }
}

contract Payer {
    function settleFor(IVault vault, Currency currency, uint256 amt) public {
        vault.settleFor(currency, msg.sender, amt);
    }

    function settle(IVault vault, Currency currency) public {
        vault.settle(currency);
    }
}
