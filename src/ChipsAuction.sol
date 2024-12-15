// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {Ownable} from "solady/src/auth/Ownable.sol";

contract ChipsAuction is Ownable {
    // Custom errors
    error BidTooLow();
    error RefundFailed();
    error NoActiveAuction();
    error AuctionNotStarted();
    error AuctionEnded();
    error InvalidAuctionTiming();
    error AuctionAlreadyExists();
    error AuctionStillActive();
    error InvalidBidIncrement();

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

    // Add this struct for frontend-friendly auction data
    struct AuctionView {
        uint256 auctionId;
        uint256 startTime;
        uint256 endTime;
        uint256 startingPrice;
        uint256 highestBid;
        address highestBidder;
        bool withdrawn;
    }

    // State variables
    uint256 public minBidIncrement;
    uint256 public currentAuctionId;
    mapping(uint256 => Auction) public auctions;

    // Events
    event BidPlaced(uint256 indexed auctionId, address indexed bidder, uint256 amount);
    event BidRefunded(uint256 indexed auctionId, address indexed bidder, uint256 amount);
    event AuctionCreated(uint256 indexed auctionId, uint256 startTime, uint256 endTime, uint256 startingPrice);
    event AuctionRemoved(uint256 indexed auctionId);
    event FundsWithdrawn(uint256[] auctionIds, uint256 totalAmount);
    event BidIncrementUpdated(uint256 oldIncrement, uint256 newIncrement);

    constructor() {
        _initializeOwner(msg.sender);
        minBidIncrement = 0.1 ether; // 0.1 SEI
    }

    /**
     * @notice Create a new auction
     * @param startTime The timestamp when the auction starts
     * @param endTime The timestamp when the auction ends
     * @param startingPrice The minimum bid to start the auction
     */
    function createAuction(uint256 startTime, uint256 endTime, uint256 startingPrice)
        external
        onlyOwner
        returns (uint256 newAuctionId)
    {
        if (startTime >= endTime || startTime < block.timestamp) {
            revert InvalidAuctionTiming();
        }

        newAuctionId = currentAuctionId + 1;

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
     */
    function placeBid(uint256 auctionId) external payable {
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
            if (msg.value < auction.startingPrice) {
                revert BidTooLow();
            }
        } else {
            // Subsequent bids must be at least minBidIncrement more than current highest bid
            if (msg.value <= auction.highestBid + minBidIncrement) {
                revert BidTooLow();
            }
        }

        // If there was a previous bid, refund it immediately
        if (auction.highestBidder != address(0)) {
            uint256 previousBid = auction.highestBid;
            (bool success,) = auction.highestBidder.call{value: previousBid}("");
            if (!success) {
                revert RefundFailed();
            }
            emit BidRefunded(auctionId, auction.highestBidder, previousBid);
        }

        // Update auction state
        auction.highestBid = msg.value;
        auction.highestBidder = msg.sender;

        emit BidPlaced(auctionId, msg.sender, msg.value);
    }

    /**
     * @notice Get the current active auction if any exists
     * @return currentAuction The current active auction (returns empty struct if none exists)
     */
    function getCurrentAuction() external view returns (AuctionView memory currentAuction) {
        // Check all auctions from most recent to oldest
        for (uint256 i = currentAuctionId; i > 0; i--) {
            Auction memory auction = auctions[i];
            if (auction.exists && block.timestamp >= auction.startTime && block.timestamp < auction.endTime) {
                return AuctionView({
                    auctionId: i,
                    startTime: auction.startTime,
                    endTime: auction.endTime,
                    startingPrice: auction.startingPrice,
                    highestBid: auction.highestBid,
                    highestBidder: auction.highestBidder,
                    withdrawn: auction.withdrawn
                });
            }
        }
        return AuctionView(0, 0, 0, 0, 0, address(0), false);
    }

    /**
     * @notice Get the next scheduled auction if any exists
     * @return nextAuction The next scheduled auction (returns empty struct if none exists)
     */
    function getNextAuction() external view returns (AuctionView memory nextAuction) {
        // Check all auctions from most recent to oldest
        for (uint256 i = currentAuctionId; i > 0; i--) {
            Auction memory auction = auctions[i];
            if (auction.exists && block.timestamp < auction.startTime) {
                return AuctionView({
                    auctionId: i,
                    startTime: auction.startTime,
                    endTime: auction.endTime,
                    startingPrice: auction.startingPrice,
                    highestBid: auction.highestBid,
                    highestBidder: auction.highestBidder,
                    withdrawn: auction.withdrawn
                });
            }
        }
        return AuctionView(0, 0, 0, 0, 0, address(0), false);
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
            (bool success,) = owner().call{value: totalAmount}("");
            if (!success) {
                revert RefundFailed();
            }
            emit FundsWithdrawn(auctionIds, totalAmount);
        }
    }

    /**
     * @notice Get all past auctions
     * @return pastAuctions Array of past auctions
     */
    function getPastAuctions() external view returns (AuctionView[] memory pastAuctions) {
        // First, count the number of past auctions
        uint256 count = 0;
        for (uint256 i = 1; i <= currentAuctionId; i++) {
            Auction memory auction = auctions[i];
            if (auction.exists && block.timestamp >= auction.endTime) {
                count++;
            }
        }

        // Initialize array with the correct size
        pastAuctions = new AuctionView[](count);

        // Fill array with past auction data
        uint256 index = 0;
        for (uint256 i = 1; i <= currentAuctionId; i++) {
            Auction memory auction = auctions[i];
            if (auction.exists && block.timestamp >= auction.endTime) {
                pastAuctions[index] = AuctionView({
                    auctionId: i,
                    startTime: auction.startTime,
                    endTime: auction.endTime,
                    startingPrice: auction.startingPrice,
                    highestBid: auction.highestBid,
                    highestBidder: auction.highestBidder,
                    withdrawn: auction.withdrawn
                });
                index++;
            }
        }

        return pastAuctions;
    }

    /**
     * @notice Get all upcoming auctions (excluding current active auction)
     * @return upcomingAuctions Array of upcoming auctions
     */
    function getUpcomingAuctions() external view returns (AuctionView[] memory upcomingAuctions) {
        // First, count the number of upcoming auctions
        uint256 count = 0;
        for (uint256 i = 1; i <= currentAuctionId; i++) {
            Auction memory auction = auctions[i];
            if (auction.exists && block.timestamp < auction.startTime) {
                count++;
            }
        }

        // Initialize array with the correct size
        upcomingAuctions = new AuctionView[](count);

        // Fill array with upcoming auction data
        uint256 index = 0;
        for (uint256 i = 1; i <= currentAuctionId; i++) {
            Auction memory auction = auctions[i];
            if (auction.exists && block.timestamp < auction.startTime) {
                upcomingAuctions[index] = AuctionView({
                    auctionId: i,
                    startTime: auction.startTime,
                    endTime: auction.endTime,
                    startingPrice: auction.startingPrice,
                    highestBid: auction.highestBid,
                    highestBidder: auction.highestBidder,
                    withdrawn: auction.withdrawn
                });
                index++;
            }
        }

        return upcomingAuctions;
    }

    /**
     * @notice Update the minimum bid increment
     * @param newIncrement The new minimum bid increment in SEI
     */
    function updateMinBidIncrement(uint256 newIncrement) external onlyOwner {
        if (newIncrement == 0) {
            revert InvalidBidIncrement();
        }
        uint256 oldIncrement = minBidIncrement;
        minBidIncrement = newIncrement * 1 ether; // Convert to SEI
        emit BidIncrementUpdated(oldIncrement, minBidIncrement);
    }

    // Add receive function to accept SEI
    receive() external payable {}
}
