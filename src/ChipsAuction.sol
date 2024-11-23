// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Ownable} from "solady/src/auth/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract ChipsAuction is Ownable {
    // Custom errors
    error BidTooLow();
    error TokenTransferFailed();
    error RefundFailed();
    error NoActiveAuction();
    error AuctionNotStarted();
    error AuctionEnded();
    error InvalidAuctionTiming();
    error AuctionAlreadyExists();
    error AuctionStillActive();

    // Structs
    struct Auction {
        uint256 startTime;
        uint256 endTime;
        uint256 startingPrice;
        uint256 highestBid;
        address highestBidder;
        bool exists;
        bool withdrawn;
    }

    // Constants
    IERC20Metadata public immutable TOKEN;
    uint256 public immutable MIN_BID_INCREMENT;
    uint256 private immutable TOKEN_DECIMALS;

    // State variables
    uint256 public currentAuctionId;
    mapping(uint256 => Auction) public auctions;

    // Events
    event BidPlaced(uint256 indexed auctionId, address indexed bidder, uint256 amount);
    event BidRefunded(uint256 indexed auctionId, address indexed bidder, uint256 amount);
    event AuctionCreated(uint256 indexed auctionId, uint256 startTime, uint256 endTime, uint256 startingPrice);
    event AuctionRemoved(uint256 indexed auctionId);
    event FundsWithdrawn(uint256[] auctionIds, uint256 totalAmount);

    constructor() {
        _initializeOwner(msg.sender);
        TOKEN = IERC20Metadata(0xBd82f3bfE1dF0c84faEC88a22EbC34C9A86595dc);
        // Get token decimals - most tokens implement this optional function
        TOKEN_DECIMALS = TOKEN.decimals();
        MIN_BID_INCREMENT = 10_000 * 10 ** TOKEN_DECIMALS;
    }

    /**
     * @notice Create a new auction
     * @param startTime The timestamp when the auction starts
     * @param endTime The timestamp when the auction ends
     * @param startingPrice The minimum bid to start the auction
     */
    function createAuction(uint256 startTime, uint256 endTime, uint256 startingPrice) external onlyOwner {
        if (startTime >= endTime || startTime < block.timestamp) {
            revert InvalidAuctionTiming();
        }

        uint256 newAuctionId = currentAuctionId + 1;

        auctions[newAuctionId] = Auction({
            startTime: startTime,
            endTime: endTime,
            startingPrice: startingPrice,
            highestBid: startingPrice,
            highestBidder: address(0),
            exists: true,
            withdrawn: false
        });

        currentAuctionId = newAuctionId;

        emit AuctionCreated(newAuctionId, startTime, endTime, startingPrice);
    }

    /**
     * @notice Remove an auction
     * @param auctionId The ID of the auction to remove
     */
    function removeAuction(uint256 auctionId) external onlyOwner {
        if (!auctions[auctionId].exists) {
            revert NoActiveAuction();
        }
        delete auctions[auctionId];
        emit AuctionRemoved(auctionId);
    }

    /**
     * @notice Place a bid in the current auction
     * @param auctionId The ID of the auction to bid on
     * @param amount The amount to bid
     */
    function placeBid(uint256 auctionId, uint256 amount) external {
        Auction storage auction = auctions[auctionId];

        if (!auction.exists) {
            revert NoActiveAuction();
        }
        if (block.timestamp < auction.startTime) {
            revert AuctionNotStarted();
        }
        if (block.timestamp >= auction.endTime) {
            revert AuctionEnded();
        }

        // Check if this is the first bid or a subsequent bid
        if (auction.highestBidder == address(0)) {
            // First bid must be at least the starting price
            if (amount < auction.startingPrice) {
                revert BidTooLow();
            }
        } else {
            // Subsequent bids must be at least MIN_BID_INCREMENT more than current highest bid
            if (amount <= auction.highestBid + MIN_BID_INCREMENT) {
                revert BidTooLow();
            }
        }

        // Transfer tokens from bidder to contract
        if (!TOKEN.transferFrom(msg.sender, address(this), amount)) {
            revert TokenTransferFailed();
        }

        // If there was a previous bid, refund it immediately
        if (auction.highestBidder != address(0)) {
            uint256 previousBid = auction.highestBid;
            if (!TOKEN.transfer(auction.highestBidder, previousBid)) {
                revert RefundFailed();
            }
            emit BidRefunded(auctionId, auction.highestBidder, previousBid);
        }

        // Update auction state
        auction.highestBid = amount;
        auction.highestBidder = msg.sender;

        emit BidPlaced(auctionId, msg.sender, amount);
    }

    /**
     * @notice Get the current active auction if any exists
     * @return auctionId The ID of the current auction (0 if none)
     * @return startTime The start time of the current auction
     * @return endTime The end time of the current auction
     * @return currentPrice The current highest bid
     * @return isActive Whether the auction is currently active
     */
    function getCurrentAuction()
        external
        view
        returns (uint256 auctionId, uint256 startTime, uint256 endTime, uint256 currentPrice, bool isActive)
    {
        // Check all auctions from most recent to oldest
        for (uint256 i = currentAuctionId; i > 0; i--) {
            Auction memory auction = auctions[i];
            if (auction.exists && block.timestamp >= auction.startTime && block.timestamp < auction.endTime) {
                return (i, auction.startTime, auction.endTime, auction.highestBid, true);
            }
        }
        return (0, 0, 0, 0, false);
    }

    /**
     * @notice Get the next scheduled auction if any exists
     * @return auctionId The ID of the next auction (0 if none)
     * @return startTime The start time of the next auction
     * @return endTime The end time of the next auction
     * @return startingPrice The starting price of the next auction
     * @return exists Whether a future auction exists
     */
    function getNextAuction()
        external
        view
        returns (uint256 auctionId, uint256 startTime, uint256 endTime, uint256 startingPrice, bool exists)
    {
        // Check all auctions from most recent to oldest
        for (uint256 i = currentAuctionId; i > 0; i--) {
            Auction memory auction = auctions[i];
            if (auction.exists && block.timestamp < auction.startTime) {
                return (i, auction.startTime, auction.endTime, auction.startingPrice, true);
            }
        }
        return (0, 0, 0, 0, false);
    }

    /**
     * @notice Withdraw funds from ended auctions and delete them
     * @param auctionIds Array of auction IDs to withdraw from
     */
    function withdrawFunds(uint256[] calldata auctionIds) external onlyOwner {
        uint256 totalAmount;

        for (uint256 i = 0; i < auctionIds.length; i++) {
            Auction storage auction = auctions[auctionIds[i]];

            // Check if auction exists, has a winning bid, and hasn't been withdrawn
            if (!auction.exists || auction.highestBidder == address(0) || auction.withdrawn) {
                continue;
            }

            // Check if auction has ended
            if (block.timestamp < auction.endTime) {
                revert AuctionStillActive();
            }

            totalAmount += auction.highestBid;

            // Mark as withdrawn instead of deleting
            auction.withdrawn = true;
        }

        // Only transfer if there are funds to withdraw
        if (totalAmount > 0) {
            if (!TOKEN.transfer(owner(), totalAmount)) {
                revert TokenTransferFailed();
            }
            emit FundsWithdrawn(auctionIds, totalAmount);
        }
    }

    /**
     * @notice Get all past auctions
     * @return pastAuctionIds Array of past auction IDs
     * @return winningBids Array of winning bid amounts
     * @return winners Array of winning bidders
     * @return withdrawalStates Array of withdrawal states
     */
    function getPastAuctions()
        external
        view
        returns (
            uint256[] memory pastAuctionIds,
            uint256[] memory winningBids,
            address[] memory winners,
            bool[] memory withdrawalStates
        )
    {
        // First, count the number of past auctions
        uint256 count = 0;
        for (uint256 i = 1; i <= currentAuctionId; i++) {
            Auction memory auction = auctions[i];
            if (auction.exists && block.timestamp >= auction.endTime) {
                count++;
            }
        }

        // Initialize arrays with the correct size
        pastAuctionIds = new uint256[](count);
        winningBids = new uint256[](count);
        winners = new address[](count);
        withdrawalStates = new bool[](count);

        // Fill arrays with past auction data
        uint256 index = 0;
        for (uint256 i = 1; i <= currentAuctionId; i++) {
            Auction memory auction = auctions[i];
            if (auction.exists && block.timestamp >= auction.endTime) {
                pastAuctionIds[index] = i;
                winningBids[index] = auction.highestBid;
                winners[index] = auction.highestBidder;
                withdrawalStates[index] = auction.withdrawn;
                index++;
            }
        }

        return (pastAuctionIds, winningBids, winners, withdrawalStates);
    }
}
