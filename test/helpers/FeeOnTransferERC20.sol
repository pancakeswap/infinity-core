// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice Minimal ERC20 that burns 1% of every transfer to a sink, so the recipient receives 99%
contract FeeOnTransferERC20 is ERC20 {
    /// @dev a fixed sink avoids giving the test contract a mint/burn hook
    address internal constant SINK = address(0xdead);

    uint256 internal constant FEE_DENOMINATOR = 100;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) ERC20(_name, _symbol, _decimals) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _transferWithFee(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;

        _transferWithFee(from, to, amount);
        return true;
    }

    function _transferWithFee(address from, address to, uint256 amount) internal {
        uint256 fee = amount / FEE_DENOMINATOR;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        balanceOf[SINK] += fee;

        emit Transfer(from, to, amount - fee);
        emit Transfer(from, SINK, fee);
    }
}
