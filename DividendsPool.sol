// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./public.sol";

/**
 * @title Dividends Pool Contract for PEOP
 * @dev Extends Ownable and ReentrancyGuard for basic ownership and reentrancy protection.
 */
contract PeopDividendsPool is Ownable, ReentrancyGuard {
    receive() external payable {}
    address public peop;

    /**
     * @dev Sends dividends to a specified address
     * @param target The address that will receive the dividends
     * @param amount The amount of Ether to send
     * @notice This function can only be called by the address stored in `peop`.
     * The calling address must have sufficient Ether balance to complete the transfer.
     * It uses the nonReentrant modifier to prevent reentrant attacks.
     */
    function sendDividends(address target, uint256 amount) external nonReentrant {
        require(msg.sender == peop, "not allowed");
        require(address(this).balance >= amount, "Insufficient balance");
        (bool sent, ) = target.call{value: amount}("");
        require(sent, "sendDividends failed");
    }

    /**
     * @dev Sets the address responsible for managing dividends
     * @param peopAddr The new manager address
     * @notice This function can only be called by the contract owner.
     * The address cannot be the zero address to prevent accidentally removing management capabilities.
     */
    function setPeop(address peopAddr) external onlyOwner {
        require(peopAddr != address(0), "Peop address cannot be zero.");
        peop = peopAddr;
    }

}