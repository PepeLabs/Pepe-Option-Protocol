// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Snapshot.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./public.sol";

/**
 * @title PEOP Contract
 * @dev This contract allows for snapshot-based dividend distribution among token holders.
 * It leverages ERC20Snapshot for capturing token balances at specific points to calculate dividends.
 */
contract Peop is ERC20Snapshot, Ownable, ReentrancyGuard {
    receive() external payable {}
    struct Proposal {
        uint256 id;
        uint256 sid;
        uint votedWeight;
        uint256 dividends;
        mapping(address => eStatus) status;
    }
    enum eStatus { notVoted, voted, claimed }
    IDividendsPool public dividendsPool;
    IPeopOption public peopOption;
    Proposal[] public dividendsProposals;
    Proposal[] public adjustFeeProposals;

    uint public votesForIncrease;
    uint public votesForDecrease;

    mapping(uint256 => uint256) public snapshotDividends;

    event voteForDividendsSucc(uint256 indexed dividendsProposalId, uint256 indexed snapId, uint256 indexed dividends);
    event voteForAdjustProtoFeeSucc(uint256 indexed adjustProtoFeeProposalId, bool indexed increase);
    event sendToDividendsPoolSucc(uint256 indexed amount);

    /**
     * @dev Constructor to mint initial supply of tokens and set up initial proposals.
     * @param _initialSupply Initial amount of tokens to mint.
     * @param _dividendsPool Address of the dividends pool contract.
     */
    constructor(uint256 _initialSupply, address _dividendsPool)
        ERC20("PepeOption", "PEOP")
    
    {
        _mint(msg.sender, _initialSupply);
        dividendsPool = IDividendsPool(_dividendsPool);
        _createdividendProposal();
        _createAdjustProtoFeeProposal();
    }

    /**
     * @dev Sets the PEOP option contract address.
     * @param _peopOptionAddr Address of the PEOP option contract.
     */
    function setPeopOptionContract(address _peopOptionAddr) external onlyOwner {
        peopOption = IPeopOption(_peopOptionAddr);
    }

    /**
     * @dev Retrieve the IDs of the latest proposals for dividends and fee adjustments.
     * @return dividendsProposalId The ID of the latest dividends proposal.
     * @return adjustFeeProposalId The ID of the latest fee adjustment proposal.
     */
    function getProposalId() external view returns (uint256, uint256) {
        uint256 dividendsProposalId = 0;
        uint256 adjustFeeProposalId = 0;
        if (dividendsProposals.length > 0) {
            dividendsProposalId = dividendsProposals.length - 1;
        }
        if (adjustFeeProposals.length > 0) {
            adjustFeeProposalId = adjustFeeProposals.length - 1;
        }
        return (dividendsProposalId, adjustFeeProposalId);
    }

    /**
    * @dev Retrieves the voting status for a specific address from both dividends and fee adjustment proposals.
    * This function is used to check whether an address has voted on specific proposals and the status of those votes.
    * 
    * @param dividendsProposalId The ID of the dividends proposal to check the status for.
    * @param adjustFeeProposalId The ID of the fee adjustment proposal to check the status for.
    * @param addr The address of the user whose status is to be checked.
    * 
    * @return eStatus The voting status in the dividends proposal for the specified address.
    * @return eStatus The voting status in the fee adjustment proposal for the specified address.
    * 
    * @notice This function requires the proposal IDs to be valid (i.e., the ID should exist within the array bounds).
    * It ensures data integrity by confirming that the provided IDs correspond to actual proposals.
     * 
    * @custom:error "invalid dividendsProposalId" Indicates that the provided dividends proposal ID does not exist.
    * @custom:error "invalid adjustFeeProposalId" Indicates that the provided fee adjustment proposal ID does not exist.
    */
    function getProposalStatus(uint256 dividendsProposalId, uint256 adjustFeeProposalId, address addr) external view returns (eStatus, eStatus) {
        require(dividendsProposalId < dividendsProposals.length, "invalid dividendsProposalId");
        require(adjustFeeProposalId < adjustFeeProposals.length, "invalid adjustFeeProposalId");
        eStatus dStatus = dividendsProposals[dividendsProposalId].status[addr];
        eStatus aStatus = adjustFeeProposals[adjustFeeProposalId].status[addr];
        return (dStatus, aStatus);
    }

    /**
    * @dev Allows a token holder to vote on the current dividends proposal. Each token holder can only vote once per proposal.
    * Voting also involves checking if the voter's weight is sufficient to make decisions for the proposal.
    * If the voted weight reaches more than half of the total supply, the proposal is considered accepted,
    * and the dividends are distributed accordingly.
    *
    * @notice This function is protected against reentrancy attacks.
    * It ensures that a voter can only participate if they haven't voted yet and possess tokens at the snapshot time.
    *
    * @custom:error "No proposal exists" Thrown if there are no active dividend proposals to vote on.
    * @custom:error "You already voted" Thrown if the caller has already participated in the current proposal.
    * @custom:error "No voting rights" Thrown if the caller does not have any tokens at the time of the proposal snapshot.
    */
    function voteForDividends() public nonReentrant {
        
        require(dividendsProposals.length > 0, "No proposal exists");
        uint256 proposalId = dividendsProposals.length - 1;
        Proposal storage proposal = dividendsProposals[proposalId];
        require(proposal.status[msg.sender] == eStatus.notVoted, "You already voted");

        uint256 voterWeight = balanceOfAt(msg.sender, proposal.sid);
        
        require(voterWeight > 0, "No voting rights");

        proposal.status[msg.sender] = eStatus.voted;
        proposal.votedWeight += voterWeight;
        if (proposal.votedWeight >= totalSupply() / 2) {
            uint256 availableDividends = address(this).balance;
            proposal.dividends = availableDividends;
            emit voteForDividendsSucc(proposal.id, proposal.sid, proposal.dividends);
            snapshotDividends[proposal.sid] = availableDividends;
            if (availableDividends > 0) {
                _sendToDividendsPool();
            }
            _createdividendProposal();
        }
    }

    function _createdividendProposal() private {
        uint256 _sid = _snapshot();
        uint256 proposalId = dividendsProposals.length;
        dividendsProposals.push();
        Proposal storage newProposal = dividendsProposals[proposalId];
        newProposal.id = proposalId;
        newProposal.sid = _sid;
    }

    /**
    * @dev Allows token holders to vote on adjusting the protocol fee. This function can be used to increase or decrease
    * the protocol fee based on the majority vote.
    * @param increase Boolean value where true represents a vote to increase the fee and false to decrease it.
    *
    * @notice This function is protected against reentrancy attacks.
    * It requires:
    *   - At least one adjust fee proposal to exist.
    *   - The caller not to have voted already on the current proposal.
    *   - The caller to have voting rights, i.e., a non-zero balance at the time of the proposal's snapshot.
    *
    * Events:
    * - voteForAdjustProtoFeeSucc: Emitted when a decision on fee adjustment is reached.
    *
    * @custom:error "No proposal exists" - Thrown if there are no active fee adjustment proposals.
    * @custom:error "You already voted" - Thrown if the caller has already voted in the current proposal.
    * @custom:error "No voting rights" - Thrown if the caller does not have any tokens at the time of the proposal snapshot.
    */
    function voteForAdjustProtoFee(bool increase) public nonReentrant {
        require(adjustFeeProposals.length > 0, "No proposal exists");
        uint256 proposalId = adjustFeeProposals.length - 1;
        Proposal storage proposal = adjustFeeProposals[proposalId];
        require(proposal.status[msg.sender] == eStatus.notVoted, "You already voted");

        uint256 voterWeight = balanceOfAt(msg.sender, proposal.sid);
        require(voterWeight > 0, "No voting rights");

        proposal.status[msg.sender] = eStatus.voted;
        if (increase) {
            votesForIncrease += voterWeight;
        } else {
            votesForDecrease += voterWeight;
        }

        if ((votesForIncrease + votesForDecrease) >= totalSupply() / 2) {
            if (votesForIncrease > votesForDecrease) {
                peopOption.adjustProtocolFee(true);
                emit voteForAdjustProtoFeeSucc(proposalId, true);
            } else {
                peopOption.adjustProtocolFee(false);
                emit voteForAdjustProtoFeeSucc(proposalId, false);
            }
            votesForIncrease = 0;
            votesForDecrease = 0;
            _createAdjustProtoFeeProposal();
        }
    }

    function _createAdjustProtoFeeProposal() private {
        uint256 _sid = _snapshot();
        uint256 proposalId = adjustFeeProposals.length;
        adjustFeeProposals.push();
        Proposal storage newProposal = adjustFeeProposals[proposalId];
        newProposal.id = proposalId;
        newProposal.sid = _sid;
    }
    
    /**
    * @dev Allows a token holder to claim their dividends from a specific dividends proposal.
    * This function ensures that dividends are distributed only once per proposal to each eligible token holder,
    * based on their token balance at the time of the snapshot associated with the proposal.
    *
    * @param dividendsProposalId The ID of the dividends proposal from which to claim dividends.
    *
    * @custom:error "invalid proposalId" - Thrown if the specified proposal ID does not exist.
    * @custom:error "you have claimed" - Thrown if the caller has already claimed their dividends for this proposal.
    * @custom:error "You had no tokens at this snapshot." - Thrown if the caller did not have any tokens at the time of the snapshot,
    * which is necessary to be eligible for dividends.
    */
    function claimDividends(uint256 dividendsProposalId) public nonReentrant {
        require(dividendsProposalId < dividendsProposals.length, "invalid proposalId");
        Proposal storage p = dividendsProposals[dividendsProposalId];
        require(p.status[msg.sender] != eStatus.claimed, "you have claimed");
        require(balanceOfAt(msg.sender, p.sid) > 0, "You had no tokens at this snapshot.");
        uint256 totalSupplyAtSnapshot = totalSupplyAt(p.sid);
        uint256 userBalanceAtSnapshot = balanceOfAt(msg.sender, p.sid);
        uint256 dividendPortion = (snapshotDividends[p.sid] * userBalanceAtSnapshot) / totalSupplyAtSnapshot;
        p.status[msg.sender] = eStatus.claimed;
        dividendsPool.sendDividends(msg.sender, dividendPortion);
    }

    /**
    * @dev Calculates the amount of dividends an address is entitled to from a specific dividends proposal,
    * based on their token balance at the snapshot associated with that proposal.
    *
    * This function is useful for querying the amount of dividends that an address can claim before actually
    * making a claim. It ensures transparency and allows token holders to verify their dividend entitlements.
    *
    * @param addr The address of the token holder whose dividend entitlement is being calculated.
    * @param dividendsProposalId The ID of the dividends proposal from which the dividend entitlement is calculated.
    *
    * @return uint256 The calculated dividend amount that the address can claim from the specified proposal.
    *
    * @notice This function only calculates and returns the dividend amount, and does not involve any state changes or
    * token transfers.
    *
    * @custom:error "invalid proposalId" - Thrown if the specified dividends proposal ID does not exist within
    * the array of proposals. This ensures the function operates on valid data.
    */
    function dividends(address addr, uint256 dividendsProposalId) external view returns (uint256){
        require(dividendsProposalId < dividendsProposals.length, "invalid proposalId");
        Proposal storage p = dividendsProposals[dividendsProposalId];
        uint256 snapBalance = balanceOfAt(addr, p.sid);
        uint256 totalSupplyAtSnapshot = totalSupplyAt(p.sid);
        uint256 dividendPortion = (snapshotDividends[p.sid] * snapBalance) / totalSupplyAtSnapshot;
        return dividendPortion;
    }

    function _sendToDividendsPool() internal {
        uint256 balance = address(this).balance;
        require(balance > 0, "_sendTodividendsPool: no ETH available");
        emit sendToDividendsPoolSucc(balance);
        (bool sent, ) = payable(address(dividendsPool)).call{value: balance}("");
        require(sent, "_sendTodividendsPool failed");
    }
}