// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./public.sol";

/**
 * @title PeopAirDrop
 * @dev This contract manages the airdrop distribution of PEOP tokens. It allows the owner to set up airdrops for multiple addresses
 * and for users to claim their designated tokens.
 * 
 * Inherits from:
 * - Ownable: Provides ownership management functionalities.
 * - ReentrancyGuard: Prevents reentrancy attacks during token transfers.
 */
contract PeopAirDrop is Ownable, ReentrancyGuard {
    IERC20Extended public peop;
    mapping(address => uint256) public airdropPool;

    /**
     * @dev Initializes the contract by setting the token to be used for the airdrop.
     * @param _peop The address of the PEOP token contract.
     */
    constructor (address _peop) {
        peop = IERC20Extended(_peop);
    }
    event claimAirdropSucc(address indexed target, uint256 indexed amount);

    /**
     * @dev Adds or updates airdrop amounts for a list of addresses.
     * @param target An array of addresses to receive the airdrop.
     * @param amount An array of token amounts corresponding to each address.
     * 
     * @notice This function can only be called by the owner of the contract. It requires the arrays of targets and amounts to be of equal length.
     */
    function addAirdrops(address[] memory target, uint256[] memory amount) external onlyOwner {
        require(target.length == amount.length, "Target and amount length mismatch");

        for (uint256 i = 0; i < target.length; i++) {
            airdropPool[target[i]] += amount[i];
        }
    }

    /**
     * @dev Allows an eligible address to claim its airdropped tokens.
     * 
     * @notice This function ensures that the claim is non-reentrant and can only proceed if the caller has a positive balance to claim.
     * Claims set the caller's airdrop balance to zero and transfer the designated tokens to their address.
     */
    function claimAirdrop() external nonReentrant {
        uint256 amount = airdropPool[msg.sender];
        require(amount > 0, "No airdrop available to claim");
        airdropPool[msg.sender] = 0;
        require(peop.transfer(msg.sender, amount), "Transfer failed");
        emit claimAirdropSucc(msg.sender, amount);
    }
}