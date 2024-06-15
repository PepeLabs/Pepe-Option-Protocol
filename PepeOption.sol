// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./public.sol";

/**
 * @title PeopOption
 * @dev Implements an options trading platform on ERC1155 standard with enhanced functionalities
 * such as protocol fee adjustments, and asset management through options.
 * The contract uses ERC1155 for minting option tokens that represent either a call or put option.
 *
 * Each option is tied to specific parameters like the underlying token, pricing token, strike price, 
 * and expiration time, which are all tracked within an Option struct.
 *
 * The contract is Ownable and uses ReentrancyGuard for preventing reentrancy attacks during 
 * critical functions like creating and exercising options.
 */
contract PeopOption is ERC1155, Ownable(), ReentrancyGuard  {
    receive() external payable {}

    uint id;
    IERC20 public Peop;

    uint8 public ProtoAssetDecimal;

    enum OptionType { CallOption, PutOption }

    uint public ProtocolFee;

    uint public MaxTs;

    mapping(uint => Option) public OptionMetadata;

    uint public FeeLastUpdateTime;
    uint public StrikePriceDecimal;

    uint[] public ProtocolFeeRange;

    struct Option {
        address Seller;
        uint UnexercisedOptionNum;
        IERC20Extended UnderlyingToken;
        IERC20Extended PricingToken;
        uint TokenAmount;
        uint StrikePrice;
        uint ExpireTime;
        OptionType OptionType;
    }
    
    /**
    * @dev Constructor for the PeopOption contract. Sets up the ERC1155 token with options-related parameters,
    * initializes the contract with necessary operational settings, and sets protocol fees and their allowable range.
    *
    * @param uri The URI for the token metadata, adhering to the ERC1155 metadata URI standard.
    * @param _peopAddr The address of the PEOP token which will be used within this contract for fee payments and other functionalities.
    * @param _protoFee The initial protocol fee that will be used for transactions within this platform.
    * @param _protoFeeRange An array containing the minimum and maximum allowable values for the protocol fee to ensure
    * that the fee remains within reasonable bounds. This array must contain exactly two elements.
    *
    * The constructor also sets several critical operational timestamps and financial parameters, including:
    * - `FeeLastUpdateTime`: Tracks the last time the protocol fee was updated, initially set to the creation time of the contract.
    *   - `MaxTs`: A predefined maximum timestamp to ensure the expiration times for options are within reasonable bounds.
    * - `StrikePriceDecimal`: Used for handling strike price calculations to maintain precision without floating point operations.
    *
    * @notice The constructor requires that the `_protoFeeRange` array contains exactly two elements, representing the
    * minimum and maximum fees allowed. This is validated to prevent improper fee range configurations.
    *
    * Emits a Transfer event for the minting of tokens as per ERC1155 standards.
    */
    constructor(string memory uri, address _peopAddr, uint _protoFee, uint[] memory _protoFeeRange) ERC1155(uri) {
        Peop = IERC20(_peopAddr);
        FeeLastUpdateTime = block.timestamp;
        ProtocolFee = _protoFee;
        MaxTs  = 4000000000;
        StrikePriceDecimal = 1 * 10 ** 18;
        require(_protoFeeRange.length == 2, "invalid protoFeeRange");
        ProtocolFeeRange = _protoFeeRange;
    }

    event writeOptionSucc(uint indexed optionId, Option opt, uint indexed optionQuantity);
    event exerciseOptionSucc(uint indexed optionId, address indexed exerciser, Option opt, uint indexed optionQuantity);
    event unlockUnExpiredOptionAssetsSucc(uint indexed optionId, Option opt, uint indexed optionQuantity);
    event unlockExpiredOptionAssetsSucc(uint indexed optionId, Option opt);

    /**
    * @dev Sets the PEOP token address used for protocol fee payments.
    * This function allows the contract owner to update the address of the PEOP token,
    * which might be necessary in case of token migration or updates.
    *
    * @param _peopAddr The address of the PEOP contract.
    *
    * @notice This operation can only be performed by the owner of the contract.
    */
    function setPeopAddr(address _peopAddr) external onlyOwner {
        Peop = IERC20(_peopAddr);
    }

    /**
    * @dev Sets the allowable range for the protocol fee.
    * This function defines the minimum and maximum values that the protocol fee can be set to,
    * which helps in keeping the fee within reasonable and manageable boundaries.
    *
    * @param protoFeeRange An array of two integers where the first element is the minimum fee and
    * the second element is the maximum fee.
    *
    * @notice The function checks that exactly two elements are provided to avoid misconfigurations.
    * Only the owner can change the protocol fee range.
    *
    * @custom:error "invalid protoFeeRange" Thrown if the provided array does not contain exactly two elements.
    */
    function setProtoFeeRange(uint[] memory protoFeeRange) external onlyOwner {
        require(protoFeeRange.length == 2, "invalid protoFeeRange");
        ProtocolFeeRange = protoFeeRange;
    }

    /**
    * @dev Allows users to write (create) new options, either calls or puts, based on the given parameters.
    * This function handles the creation of options by taking in the necessary details, collecting required fees,
    * and minting corresponding ERC1155 tokens that represent the options.
    *
    * @param UnderlyingToken The address of the token that the option contract is based on (e.g., the asset for a call option).
    * @param PricingToken The address of the token used for pricing the option (e.g., the asset used to pay the strike price).
    * @param optionNum The number of options the user wishes to create.
    * @param tokenAmount The amount of the underlying tokens each option covers.
    * @param strikePrice The price at which the option can be exercised.
    * @param expireTime The timestamp at which these options will expire and no longer be valid.
    * @param optionType The type of option being created: either CallOption or PutOption.
    *
    * @notice This function requires the transaction to include a protocol fee payment.
    * The function enforces that the expiration time is set within valid bounds—no less than 60 seconds from the current time
    * and not exceeding a pre-set maximum timestamp (`MaxTs`).
    *
    * @custom:error "invalid expireTime" Thrown if the `expireTime` is less than the minimum allowed or more than `MaxTs`.
    * @custom:error "transfer failed" Thrown if the token transfer necessary to back the option or pay the strike price fails.
    *
    * The function performs different actions based on the type of option:
    * - For a CallOption: Transfers the underlying tokens from the user to the contract as collateral.
    * - For a PutOption: Transfers the pricing tokens calculated based on the strike price from the user to the contract.
    *  
    * After ensuring fee payment and successful token transfers, the function proceeds to mint the option tokens (NFTs)
    * representing the written options, linking these tokens with the specific terms set by the user.
    */
    function writeOption(address UnderlyingToken, address PricingToken, uint optionNum, uint tokenAmount, uint strikePrice, uint expireTime, OptionType optionType) public payable nonReentrant {
        require(expireTime < MaxTs, "invalid expireTime");
        require(expireTime >= block.timestamp + 60, "invalid expireTime");

        _sendProtocolFee(optionNum);
        if (optionType == OptionType.CallOption) {
            IERC20 underlyingToken = IERC20(UnderlyingToken);
            require(underlyingToken.transferFrom(msg.sender, address(this), tokenAmount * optionNum));
            
            _writeOptionNft(UnderlyingToken, PricingToken, optionNum, tokenAmount, strikePrice, expireTime, optionType);
            
        } else {
            IERC20 pricingToken = IERC20(PricingToken);
            require(pricingToken.transferFrom(msg.sender, address(this), tokenAmount * optionNum * strikePrice / StrikePriceDecimal));
            _writeOptionNft(UnderlyingToken, PricingToken, optionNum, tokenAmount, strikePrice, expireTime, optionType);
        }
    }

    function _writeOptionNft(address UnderlyingToken, address PricingToken, uint optionNum, uint tokenAmount, uint strikePrice, uint expireTime, OptionType optionType) private {
        Option memory opt = Option(msg.sender, optionNum, IERC20Extended(UnderlyingToken), IERC20Extended(PricingToken), tokenAmount, strikePrice, expireTime, optionType);
        OptionMetadata[id] = opt;
        _mint(msg.sender, id, optionNum, "");
        emit writeOptionSucc(id, opt, optionNum);
        id ++;
    }

    /**
    * @dev Allows a token holder to exercise their options, whether they are call or put options.
    * This function handles the transfer of assets between the option holder and the seller based on the option type.
    *
    * @param optionId The identifier of the option token being exercised.
    * @param optionNum The number of option tokens the user wants to exercise.
    *
    * @notice This function is protected against reentrancy attacks.
    * It checks:
    *   - That the number of options to exercise is valid (greater than zero and not exceeding the holder's balance).
    *   - That the option has not expired (the current time is less than the option's expiry time).
    *
    * @custom:error "invalid optionNum" - Thrown if the specified number of options to exercise is zero or exceeds the caller's balance.
    * @custom:error "option expired" - Thrown if the options have already expired.
    * @custom:error "pricing token trasfer failed" - Thrown if the transfer of the pricing token fails.
    * @custom:error "underlying token trasfer failed" - Thrown if the transfer of the underlying token fails.
    *
    * Emits `exerciseOptionSucc` event after successfully exercising the options.
    */
    function exerciseOption(uint optionId, uint optionNum) external nonReentrant {
        require(optionNum > 0 && optionNum <= balanceOf(msg.sender, optionId), "invalid optionNum");

        require(OptionMetadata[optionId].ExpireTime >= block.timestamp, "option expired");
        Option storage opt = OptionMetadata[optionId];
        uint8 underlyingTokenDecimal = opt.UnderlyingToken.decimals();
        uint8 pricingTokenDecimal = opt.PricingToken.decimals();

        if (opt.OptionType == OptionType.CallOption) {
            require(opt.PricingToken.transferFrom(msg.sender, opt.Seller, optionNum * opt.TokenAmount * (10 ** pricingTokenDecimal) * opt.StrikePrice / StrikePriceDecimal / (10 ** underlyingTokenDecimal)), "pricing token trasfer failed");
            require(opt.UnderlyingToken.transfer(msg.sender, optionNum * opt.TokenAmount), "underlying token trasfer failed");
        } else {
            require(opt.UnderlyingToken.transferFrom(msg.sender, opt.Seller, optionNum *(10 ** underlyingTokenDecimal) * opt.TokenAmount / (10 ** pricingTokenDecimal)), "underlying token trasfer failed");
            require(opt.PricingToken.transfer(msg.sender, optionNum * opt.TokenAmount * opt.StrikePrice / StrikePriceDecimal), "pricing token trasfer failed");
        }

        opt.UnexercisedOptionNum -= optionNum;
        _burn(msg.sender, optionId, optionNum);
        emit exerciseOptionSucc(optionId, msg.sender, opt, optionNum);
    }

    function _sendProtocolFee(uint optionNum) private {
        require(msg.value == optionNum * ProtocolFee, "invalid ETH value");
        payable(address(Peop)).transfer(msg.value);
    }

    /**
    * @dev Adjusts the protocol fee up or down by 10%, depending on the passed argument.
    * This function allows dynamic adjustment of the protocol fee to react to market conditions or business strategies.
    *
    * @param Increase A boolean that specifies whether to increase (true) or decrease (false) the protocol fee.
    *
    * @notice Can only be called by the Peop token contract address to ensure that fee adjustments
    * are managed through a controlled process, potentially involving governance or automated mechanisms.
    * The function enforces a cooldown period of 24 hours to prevent too frequent changes which could destabilize operations.
    *
    * @custom:error "invalid caller" - Thrown if the function is called by any account other than the Peop token address.
    * @custom:error "invalid adjust time" - Thrown if the function is called less than 24 hours after the last adjustment.
    * @custom:error "out of range" - Thrown if the current fee is outside the predefined acceptable range.
    */
    function adjustProtocolFee(bool Increase) external nonReentrant {
        require(msg.sender == address(Peop), "invalid caller");
        require(block.timestamp - FeeLastUpdateTime >= 86400, "invalid adjust time");
        require((ProtocolFee >= ProtocolFeeRange[0] && ProtocolFee < ProtocolFeeRange[1]), "out of range");
        FeeLastUpdateTime = block.timestamp;
        
        if (Increase) {
            ProtocolFee += ProtocolFee / 10;
        } else {
            ProtocolFee -= ProtocolFee / 10;
        }
    }

    /**
    * @dev Retrieves the balance of a specified ERC20 token that is held by this contract.
    * This function is useful for checking how much of a given asset the contract currently holds, 
    * which can include fees collected, collateral, or other operational balances.
    *
    * @param asset The address of the ERC20 token for which the balance is being queried.
    *
    * @return uint The amount of the specified token that this contract currently holds.
    *
    * @notice This is a view function and does not modify the state of the contract. It simply reads and returns 
    * the balance of the specified token. It can be called by anyone externally and is intended to provide transparency
    * into the contract's holdings.
    *
    * This function can be used to monitor the financial state of the contract, such as tracking the amount of fees
    * accumulated or the amount of tokens set aside for payouts or refunds.
    */
    function getProtocolLockedBalance(address asset) view external returns (uint) {
        return IERC20(asset).balanceOf(address(this));
    }

    /**
    * @dev Allows the seller of options to unlock and retrieve assets tied up in unexpired options.
    * This function is crucial for managing assets before the expiration of the option, ensuring liquidity and control for the option writer.
    *
    * @param optionId The identifier of the option token from which assets are being unlocked.
    * @param optionNum The number of option tokens for which the assets are to be unlocked.
    *
    * @notice This function is protected against reentrancy attacks to ensure transaction integrity.
    * It can only be called by the original seller of the options, ensuring that only authorized parties can unlock assets.
    *
    * @custom:error "insufficient unexpired option" Thrown if the caller does not own enough of the specified option tokens.
    * @custom:error "invalid caller" Thrown if anyone other than the seller tries to unlock the assets.
    * @custom:error "transfer underlyingToken failed" or "transfer pricingToken failed" Thrown if the token transfer fails.
    *
    * Emits `unlockUnExpiredOptionAssetsSucc` event after successfully unlocking the assets, providing transparency and traceability.
    */
    function unlockUnExpiredOptionAssets(uint optionId, uint optionNum) external nonReentrant {

        require(balanceOf(msg.sender, optionId) >= optionNum, "insufficient unexpired option");
        Option storage opt = OptionMetadata[optionId];

        require(msg.sender == opt.Seller, "invalid caller");
        if (opt.OptionType == OptionType.CallOption) {
            require(opt.UnderlyingToken.transfer(opt.Seller, opt.TokenAmount * optionNum), "transfer underlyingToken failed");
        } else {
            require(opt.PricingToken.transfer(opt.Seller, opt.TokenAmount * optionNum * opt.StrikePrice / StrikePriceDecimal), "transfer pricingToken failed");
        }
        opt.UnexercisedOptionNum -= optionNum;
        _burn(msg.sender, optionId, optionNum);
        emit unlockUnExpiredOptionAssetsSucc(optionId, opt, optionNum);
    }

    /**
    * @dev Allows the seller of options to retrieve assets tied up in options that have expired.
    * This function ensures that the assets locked in options that are no longer valid due to expiration
    * are returned to the original seller, maintaining fairness and liquidity.
    *
    * @param optionId The identifier of the expired option token from which assets are being reclaimed.
    *
    * @return bool Returns true if the operation was successful.
    *
    * @notice Requires that the function caller is the original seller of the options and that the options have indeed expired.
    * This function is protected against reentrancy attacks to ensure the integrity of the transaction.
    *
    * @custom:error "invalid option or not expired" Thrown if the option has not expired or does not exist.
    * @custom:error "invalid caller" Thrown if anyone other than the seller, or an invalid address, tries to unlock the assets.
    * @custom:error "insufficient unexercised option" Thrown if there are no unexercised options left to unlock.
    * @custom:error "transfer underlyingToken failed" or "transfer pricingToken failed" Thrown if the token transfer back to the seller fails.
    *
    * Emits `unlockExpiredOptionAssetsSucc` event upon successful unlocking of assets, providing transparency and traceability.
    */
    function unlockExpiredOptionAssets(uint optionId) external nonReentrant returns (bool) {
        Option storage opt = OptionMetadata[optionId]; 
        require(opt.ExpireTime != 0 && opt.ExpireTime < block.timestamp, "invalid option or not expired");
        require(opt.Seller == msg.sender && opt.Seller != address(0), "invalid caller");
        require(opt.UnexercisedOptionNum > 0, "insufficient unexercised option");
        if (opt.OptionType == OptionType.CallOption) {
            require(opt.UnderlyingToken.transfer(opt.Seller, opt.TokenAmount * opt.UnexercisedOptionNum), "transfer underlyingToken failed");
        } else {
            require(opt.PricingToken.transfer(opt.Seller, opt.TokenAmount * opt.UnexercisedOptionNum * opt.StrikePrice / StrikePriceDecimal), "transfer pricingToken failed");
        }
        _burn(msg.sender, optionId, opt.UnexercisedOptionNum);
        emit unlockExpiredOptionAssetsSucc(optionId, opt);
        delete OptionMetadata[optionId];
        return true;
    }

    /**
    * @dev Retrieves the expiration timestamp of a specified option.
    * This view function allows anyone to check when a particular option will expire or has expired,
    * providing essential information for decision-making related to option exercise or management.
    *
    * @param optionId The identifier of the option whose expiration timestamp is being queried.
    * @return uint The expiration timestamp of the specified option. This is the time at which the option
    * ceases to be valid for exercise or other operational purposes.
    *
    * @notice This function does not modify the state of the contract and only reads and returns information
    * about a specific option's expiration. It is accessible externally to provide transparency on option validity.
    *
    * @custom:error "option does not exist" - This implicit error could occur if the queried optionId does not exist in the
    * contract’s state, leading to a return of a default value (potentially zero if not set explicitly upon creation).
    * It is important for callers to verify the validity of the returned timestamp.
    */
    function expiredTs(uint optionId) external view returns (uint) {
        Option memory opt = OptionMetadata[optionId];
        return opt.ExpireTime;
    }

}
