// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./public.sol";

/**
 * @title PeopMarket
 * @dev Implements a marketplace for trading options as ERC1155 tokens.
 * Provides functionality to list options for sale, remove them from the market, and allow users to purchase these options.
 * This contract ensures transactions are safe from reentrancy attacks and handles the proper transfer of tokens and funds.
 */
contract PeopMarket is Ownable(), ReentrancyGuard {
    PeopOptionExtended public PeopOption;
    uint public OrderId;
    bytes4 private constant _ERC1155_RECEIVED = 0xf23a6e61;

    // key: orderId => Order
    mapping (uint => Order) public OrderPool;

    struct Order {
        uint OptionId;
        uint Price;
        uint Amount;
        bool Valid;
        address Seller;
    }
    
    event AddToMarketSucc(uint indexed orderId, address indexed seller, Order order);
    event RemoveFromMarketSucc(uint indexed orderId, uint indexed amount, Order order);
    event BuyOptionSucc(uint indexed orderId, uint indexed amount, address indexed buyer, Order order);

    /**
    * @dev Initializes the marketplace contract with a reference to the PeopOptionExtended contract.
    * @param PeopOptionAddr The address of the PeopOptionExtended contract that manages the options being traded.
    */
    constructor(address PeopOptionAddr) {
        PeopOption = PeopOptionExtended(PeopOptionAddr);
    }

    /**
    * @dev Sets a new contract address for the PeopOption contract that this marketplace interacts with.
    * This function is used to update the contract reference in case of upgrades or migrations to a new PeopOption contract.
    *
    * @param PeopOptionAddr The new address of the PeopOptionExtended contract.
    *
    * @notice This operation can only be performed by the owner of the contract to ensure that the update is authorized and controlled.
    * It is crucial to ensure that the new address provided is correct and points to a contract compatible with the expected interface.
    *
    * @custom:security Only callable by the contract owner to prevent unauthorized changes to critical operational parameters.
    */
    function SetPeopOptionCnt(address PeopOptionAddr) public onlyOwner {
        PeopOption = PeopOptionExtended(PeopOptionAddr);
    }

    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata data
    )
        external view
        returns(bytes4)
    {
        require(msg.sender == address(PeopOption), "Invalid NFT address");

        require(operator == address(this), "Invalid operator");

        require(data.length == 32, "Invalid data");

        uint orderId = abi.decode(data, (uint));
        Order storage order = OrderPool[orderId];
        require(order.OptionId == id, "Order id mismatch");

        require(order.Amount == value, "Order amount mismatch");
        
        require(from == order.Seller, "Seller mismatch");
        
        return _ERC1155_RECEIVED;
    }

    /**
    * @dev Lists an option token for sale on the market.
    * @param optionId The ID of the option token to list.
    * @param price The price per unit of the option token.
    * @param amount The number of tokens to list.
    * 
    * @notice Requires that the option has not expired and the seller has approved the market to manage their tokens.
    * Calls `safeTransferFrom` to transfer the tokens from the seller to the market contract.
    * 
    * Emits `AddToMarketSucc` when tokens are successfully listed.
    */
    function AddToMarket(uint optionId, uint price, uint amount) external {
        require(PeopOption.expiredTs(optionId) > block.timestamp, "option expired");
        require(PeopOption.isApprovedForAll(msg.sender, address(this)), "not approved");
        Order memory order = Order(optionId, price, amount, true, msg.sender);
        OrderPool[OrderId] = order;
        PeopOption.safeTransferFrom(msg.sender, address(this), optionId,  amount, abi.encodePacked(OrderId));
        emit AddToMarketSucc(OrderId, msg.sender, order);
        OrderId ++;
    }

    /**
    * @dev Removes or decrements the listed amount of an option order from the market.
    * @param orderId The ID of the order to remove or decrement.
    * @param amount The amount to remove from the market listing.
    *
    * @notice Requires that the caller is the seller of the order and that the order is valid.
    * Uses `safeTransferFrom` to return the specified amount of tokens to the seller.
    *
    * Emits `RemoveFromMarketSucc` upon successful removal or decrement.
    */
    function RemoveFromMarket(uint orderId, uint amount) external nonReentrant {
        Order storage order = OrderPool[orderId];
        require(order.Valid, "invalid order");
        require(msg.sender == order.Seller, "not allowed");
        require(amount <= order.Amount, "insufficient quantity");
        PeopOption.safeTransferFrom(address(this), order.Seller, order.OptionId,  amount, abi.encodePacked(OrderId));
        if (amount == order.Amount) {
            order.Amount = 0;
            order.Valid = false;
        } else {
            order.Amount -= amount;
        }
        emit RemoveFromMarketSucc(orderId, amount, order);
    }

    /**
    * @dev Facilitates the purchase of option tokens from the market by a buyer. This function handles the
    * financial transaction, transferring the required amount of ETH from the buyer to the seller, and
    * the corresponding option tokens from the marketplace contract to the buyer.
    *
    * @param orderId The ID of the market order from which to buy the options.
    * @param amount The number of option tokens to buy from the specified order.
    *
    * @notice This function requires the buyer to send the exact amount of ETH corresponding to the price and
    * quantity of options being purchased. It ensures that the order is valid, has enough tokens available,
    * and the payment is correct before proceeding with the transaction.
    *
    * @custom:error "invalid order" Thrown if the order ID provided does not correspond to a valid, active order.
    * @custom:error "insufficient amount" Thrown if the buyer tries to purchase more options than are available in the order.
    * @custom:error "Incorrect ETH amount sent" Thrown if the amount of ETH sent by the buyer does not exactly match
    * the total price required for the number of options being purchased.
    * @custom:error "Failed to send ETH" Thrown if the contract fails to transfer the ETH to the seller.
    *
    * Emits a `BuyOptionSucc` event upon successful transaction, indicating the completion of the option purchase,
    * which includes details of the order, the buyer, and the amount of options purchased.
    */
    function BuyOption(uint orderId, uint amount) external payable nonReentrant {
        Order storage order = OrderPool[orderId];
        require(order.Valid, "invalid order");
        require(amount <= order.Amount, "insufficient amount");
        require(msg.value == order.Price * amount, "Incorrect ETH amount sent");
        (bool sent, ) = order.Seller.call{value: msg.value}("");
        require(sent, "Failed to send ETH");

        PeopOption.safeTransferFrom(address(this), msg.sender, order.OptionId, amount, "");
        if (amount == order.Amount) {
            order.Amount = 0;
            order.Valid = false;
        } else {
            order.Amount -= amount;
        }
        emit BuyOptionSucc(orderId, amount, msg.sender, order);
    }
}