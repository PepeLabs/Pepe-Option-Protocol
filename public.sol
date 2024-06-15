// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC1155.sol";

interface IERC20Extended is IERC20 {
    function decimals() external view returns (uint8);
}

interface PeopOptionExtended is IERC1155 {
    function expiredTs(uint optionId) external view returns (uint);
}

/**
 * @title IPeopOption
 * @dev Interface for the PeopOption contract to adjust protocol fees.
 */
interface IPeopOption {
    /**
     * @dev Adjusts the protocol fee based on a boolean flag.
     * @param increase True to increase the fee, false to decrease.
     */
    function adjustProtocolFee(bool increase) external;
}

interface IDividendsPool {
    function sendDividends(address target, uint256 amount) external;
}