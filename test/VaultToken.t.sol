// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VaultToken} from "../src/VaultToken.sol";
import {Currency} from "../src/types/Currency.sol";

contract MockVaultToken is VaultToken {
    function mint(address receiver, Currency currency, uint256 amount) public virtual {
        _mint(receiver, currency, amount);
    }

    function burn(address sender, Currency currency, uint256 amount) public virtual {
        _burn(sender, currency, amount);
    }
}

contract VaultTokenTest is Test {
    MockVaultToken token;

    mapping(address => mapping(Currency => uint256)) public userMintAmounts;
    mapping(address => mapping(Currency => uint256)) public userTransferOrBurnAmounts;

    function _toCurrency(uint256 id) internal pure returns (Currency) {
        return Currency.wrap(address(uint160(id)));
    }

    function setUp() public {
        token = new MockVaultToken();
    }

    function testMint() public {
        token.mint(address(0xBEEF), _toCurrency(1337), 100);

        assertEq(token.balanceOf(address(0xBEEF), _toCurrency(1337)), 100);
    }

    function testBurn() public {
        token.mint(address(0xBEEF), _toCurrency(1337), 100);
        token.burn(address(0xBEEF), _toCurrency(1337), 70);

        assertEq(token.balanceOf(address(0xBEEF), _toCurrency(1337)), 30);
    }

    function testSetOperator() public {
        token.setOperator(address(0xBEEF), true);

        assertTrue(token.isOperator(address(this), address(0xBEEF)));
    }

    function testApprove() public {
        token.approve(address(0xBEEF), _toCurrency(1337), 100);

        assertEq(token.allowance(address(this), address(0xBEEF), _toCurrency(1337)), 100);
    }

    function testTransfer() public {
        address sender = address(0xABCD);

        token.mint(sender, _toCurrency(1337), 100);

        vm.prank(sender);
        token.transfer(address(0xBEEF), _toCurrency(1337), 70);

        assertEq(token.balanceOf(sender, _toCurrency(1337)), 30);
        assertEq(token.balanceOf(address(0xBEEF), _toCurrency(1337)), 70);
    }

    function testTransferFromWithApproval() public {
        address sender = address(0xABCD);
        address receiver = address(0xBEEF);

        token.mint(sender, _toCurrency(1337), 100);

        vm.prank(sender);
        token.approve(address(this), _toCurrency(1337), 100);

        token.transferFrom(sender, receiver, _toCurrency(1337), 70);

        assertEq(token.allowance(sender, address(this), _toCurrency(1337)), 30);
        assertEq(token.balanceOf(sender, _toCurrency(1337)), 30);
        assertEq(token.balanceOf(receiver, _toCurrency(1337)), 70);
    }

    function testTransferFromWithInfiniteApproval() public {
        address sender = address(0xABCD);
        address receiver = address(0xBEEF);

        token.mint(sender, _toCurrency(1337), 100);

        vm.prank(sender);
        token.approve(address(this), _toCurrency(1337), type(uint256).max);

        token.transferFrom(sender, receiver, _toCurrency(1337), 70);

        assertEq(token.allowance(sender, address(this), _toCurrency(1337)), type(uint256).max);
        assertEq(token.balanceOf(sender, _toCurrency(1337)), 30);
        assertEq(token.balanceOf(receiver, _toCurrency(1337)), 70);
    }

    function testTransferFromAsOperator() public {
        address sender = address(0xABCD);
        address receiver = address(0xBEEF);

        token.mint(sender, _toCurrency(1337), 100);

        vm.prank(sender);
        token.setOperator(address(this), true);

        token.transferFrom(sender, receiver, _toCurrency(1337), 70);

        assertEq(token.balanceOf(sender, _toCurrency(1337)), 30);
        assertEq(token.balanceOf(receiver, _toCurrency(1337)), 70);
    }

    function test_RevertWhenMintBalanceOverflow() public {
        token.mint(address(0xDEAD), _toCurrency(1337), type(uint256).max);
        vm.expectRevert();
        token.mint(address(0xDEAD), _toCurrency(1337), 1);
    }

    function test_RevertWhenTransferBalanceUnderflow() public {
        address sender = address(0xABCD);
        address receiver = address(0xBEEF);

        vm.expectRevert();
        vm.prank(sender);
        token.transferFrom(sender, receiver, _toCurrency(1337), 1);
    }

    function test_RevertWhenTransferBalanceOverflow() public {
        address sender = address(0xABCD);
        address receiver = address(0xBEEF);

        token.mint(sender, _toCurrency(1337), type(uint256).max);

        vm.prank(sender);
        token.transferFrom(sender, receiver, _toCurrency(1337), type(uint256).max);

        token.mint(sender, _toCurrency(1337), 1);

        vm.expectRevert();
        vm.prank(sender);
        token.transferFrom(sender, receiver, _toCurrency(1337), 1);
    }

    function test_RevertWhenTransferFromBalanceUnderflow() public {
        address sender = address(0xABCD);
        address receiver = address(0xBEEF);

        vm.expectRevert();
        vm.prank(sender);
        token.transferFrom(sender, receiver, _toCurrency(1337), 1);
    }

    function test_RevertWhenTransferFromBalanceOverflow() public {
        address sender = address(0xABCD);
        address receiver = address(0xBEEF);

        token.mint(sender, _toCurrency(1337), type(uint256).max);

        vm.prank(sender);
        token.transferFrom(sender, receiver, _toCurrency(1337), type(uint256).max);

        token.mint(sender, _toCurrency(1337), 1);

        vm.expectRevert();
        vm.prank(sender);
        token.transferFrom(sender, receiver, _toCurrency(1337), 1);
    }

    function test_RevertWhenTransferFromNotAuthorized() public {
        address sender = address(0xABCD);
        address receiver = address(0xBEEF);

        token.mint(sender, _toCurrency(1337), 100);

        vm.expectRevert();
        token.transferFrom(sender, receiver, _toCurrency(1337), 100);
    }

    function testMint(address receiver, Currency currency, uint256 amount) public {
        token.mint(receiver, currency, amount);

        assertEq(token.balanceOf(receiver, currency), amount);
    }

    function testBurn(address sender, Currency currency, uint256 amount) public {
        token.mint(sender, currency, amount);
        token.burn(sender, currency, amount);

        assertEq(token.balanceOf(sender, currency), 0);
    }

    function testSetOperator(address operator, bool approved) public {
        token.setOperator(operator, approved);

        assertEq(token.isOperator(address(this), operator), approved);
    }

    function testApprove(address spender, Currency currency, uint256 amount) public {
        token.approve(spender, currency, amount);

        assertEq(token.allowance(address(this), spender, currency), amount);
    }

    function testTransfer(
        address sender,
        address receiver,
        Currency currency,
        uint256 mintAmount,
        uint256 transferAmount
    ) public {
        transferAmount = bound(transferAmount, 0, mintAmount);

        token.mint(sender, currency, mintAmount);

        vm.prank(sender);
        token.transfer(receiver, currency, transferAmount);

        if (sender == receiver) {
            assertEq(token.balanceOf(sender, currency), mintAmount);
        } else {
            assertEq(token.balanceOf(sender, currency), mintAmount - transferAmount);
            assertEq(token.balanceOf(receiver, currency), transferAmount);
        }
    }

    function testTransferFromWithApprovalFuzz(
        address sender,
        address receiver,
        Currency currency,
        uint256 mintAmount,
        uint256 transferAmount
    ) public {
        transferAmount = bound(transferAmount, 0, mintAmount);

        token.mint(sender, currency, mintAmount);

        vm.prank(sender);
        token.approve(address(this), currency, mintAmount);

        token.transferFrom(sender, receiver, currency, transferAmount);

        if (mintAmount == type(uint256).max) {
            assertEq(token.allowance(sender, address(this), currency), type(uint256).max);
        } else if (sender == address(this)) {
            /// if sender === address(this), transferFrom will not consume allowance
            assertEq(token.allowance(sender, address(this), currency), mintAmount);
        } else {
            assertEq(token.allowance(sender, address(this), currency), mintAmount - transferAmount);
        }

        if (sender == receiver) {
            assertEq(token.balanceOf(sender, currency), mintAmount);
        } else {
            assertEq(token.balanceOf(sender, currency), mintAmount - transferAmount);
            assertEq(token.balanceOf(receiver, currency), transferAmount);
        }
    }

    function testTransferFromWithInfiniteApproval(
        address sender,
        address receiver,
        Currency currency,
        uint256 mintAmount,
        uint256 transferAmount
    ) public {
        transferAmount = bound(transferAmount, 0, mintAmount);

        token.mint(sender, currency, mintAmount);

        vm.prank(sender);
        token.approve(address(this), currency, type(uint256).max);

        token.transferFrom(sender, receiver, currency, transferAmount);

        assertEq(token.allowance(sender, address(this), currency), type(uint256).max);

        if (sender == receiver) {
            assertEq(token.balanceOf(sender, currency), mintAmount);
        } else {
            assertEq(token.balanceOf(sender, currency), mintAmount - transferAmount);
            assertEq(token.balanceOf(receiver, currency), transferAmount);
        }
    }

    function testTransferFromAsOperator(
        address sender,
        address receiver,
        Currency currency,
        uint256 mintAmount,
        uint256 transferAmount
    ) public {
        transferAmount = bound(transferAmount, 0, mintAmount);

        token.mint(sender, currency, mintAmount);

        vm.prank(sender);
        token.setOperator(address(this), true);

        token.transferFrom(sender, receiver, currency, transferAmount);

        if (sender == receiver) {
            assertEq(token.balanceOf(sender, currency), mintAmount);
        } else {
            assertEq(token.balanceOf(sender, currency), mintAmount - transferAmount);
            assertEq(token.balanceOf(receiver, currency), transferAmount);
        }
    }

    function test_RevertWhenTransferBalanceUnderflow(
        address sender,
        address receiver,
        Currency currency,
        uint256 amount
    ) public {
        amount = bound(amount, 1, type(uint256).max);

        vm.expectRevert();
        vm.prank(sender);
        token.transfer(receiver, currency, amount);
    }

    function test_RevertWhenTransferBalanceOverflow(address sender, address receiver, Currency currency, uint256 amount)
        public
    {
        if (sender == receiver) return; // same address transfer will revert earlier

        amount = bound(amount, 1, type(uint256).max);
        uint256 overflowAmount = type(uint256).max - amount + 1;

        token.mint(sender, currency, amount);

        vm.prank(sender);
        token.transfer(receiver, currency, amount);

        token.mint(sender, currency, overflowAmount);

        vm.expectRevert();
        vm.prank(sender);
        token.transfer(receiver, currency, overflowAmount);
    }

    function test_RevertWhenTransferFromBalanceUnderflow(
        address sender,
        address receiver,
        Currency currency,
        uint256 amount
    ) public {
        amount = bound(amount, 1, type(uint256).max);

        vm.expectRevert();
        vm.prank(sender);
        token.transferFrom(sender, receiver, currency, amount);
    }

    function test_RevertWhenTransferFromBalanceOverflow(
        address sender,
        address receiver,
        Currency currency,
        uint256 amount
    ) public {
        if (sender == receiver) return; // same address transfer will revert earlier

        amount = bound(amount, 1, type(uint256).max);
        uint256 overflowAmount = type(uint256).max - amount + 1;

        token.mint(sender, currency, amount);

        vm.prank(sender);
        token.transferFrom(sender, receiver, currency, amount);

        token.mint(sender, currency, overflowAmount);

        vm.expectRevert();
        vm.prank(sender);
        token.transferFrom(sender, receiver, currency, overflowAmount);
    }

    function test_RevertWhenTransferFromNotAuthorized(
        address sender,
        address receiver,
        Currency currency,
        uint256 amount
    ) public {
        amount = bound(amount, 1, type(uint256).max);
        vm.assume(sender != address(this));

        token.mint(sender, currency, amount);

        vm.expectRevert();
        token.transferFrom(sender, receiver, currency, amount);
    }
}
