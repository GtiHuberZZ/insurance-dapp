// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./PolicyNFT.sol";

contract PolicyMarket is AccessControl, ReentrancyGuard {
    ///////////////////
    /// Errors ///////
    ///////////////////
    error InvalidListing();
    error NotListingSeller();
    error ListingStale(uint256 policyId);
    error InvalidFee();
    error ZeroAmount();
    error TransferFailed();

    //////////////////////
    /// State Variables //
    //////////////////////
    bytes32 public constant FEE_ADMIN_ROLE = keccak256("FEE_ADMIN_ROLE");

    IERC20 public immutable usdc;
    PolicyNFT public immutable policyNFT;

    address public feeRecipient;
    uint16 public feeBps;

    struct Listing {
        address seller;
        uint256 price;
        bool active;
    }
    mapping(uint256 => Listing) public listings;

    ////////////////
    /// Events /////
    ////////////////
    event Listed(uint256 indexed policyId, address indexed seller, uint256 price);
    event ListingCancelled(uint256 indexed policyId);
    event Purchased(uint256 indexed policyId, address indexed seller, address indexed buyer, uint256 price);
    event FeeParamsUpdated(address indexed feeRecipient, uint16 feeBps);

    ///////////////////
    /// Constructor ///
    ///////////////////
    constructor(
        address usdc_,
        address policyNFT_,
        address admin,
        address feeRecipient_,
        uint16 feeBps_
    ) {
        if (feeBps_ > 1000) revert InvalidFee();
        usdc = IERC20(usdc_);
        policyNFT = PolicyNFT(policyNFT_);
        feeRecipient = feeRecipient_;
        feeBps = feeBps_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(FEE_ADMIN_ROLE, admin);
    }

    ///////////////////////
    /// 挂单 / 取消 //////
    ///////////////////////

    function list(uint256 policyId, uint256 price) external {
        if (price == 0) revert ZeroAmount();
        if (policyNFT.ownerOf(policyId) != msg.sender) revert NotListingSeller();

        listings[policyId] = Listing({
            seller: msg.sender,
            price: price,
            active: true
        });

        emit Listed(policyId, msg.sender, price);
    }

    function cancelListing(uint256 policyId) external {
        Listing memory l = listings[policyId];
        if (!l.active) revert InvalidListing();
        if (l.seller != msg.sender) revert NotListingSeller();

        listings[policyId].active = false;
        emit ListingCancelled(policyId);
    }

    ///////////////////////
    /// 购买 /////////////
    ///////////////////////

    function buy(uint256 policyId) external nonReentrant {
        Listing memory l = listings[policyId];
        if (!l.active) revert InvalidListing();

        if (policyNFT.ownerOf(policyId) != l.seller) {
            revert ListingStale(policyId);
        }

        listings[policyId].active = false;

        uint256 fee = (l.price * feeBps) / 10000;
        uint256 sellerAmount = l.price - fee;

        bool ok1 = usdc.transferFrom(msg.sender, l.seller, sellerAmount);
        if (!ok1) revert TransferFailed();

        if (fee > 0) {
            bool ok2 = usdc.transferFrom(msg.sender, feeRecipient, fee);
            if (!ok2) revert TransferFailed();
        }

        policyNFT.transferFrom(l.seller, msg.sender, policyId);

        emit Purchased(policyId, l.seller, msg.sender, l.price);
    }

    ///////////////////////
    /// 管理 /////////////
    ///////////////////////

    function setFeeParams(address feeRecipient_, uint16 feeBps_)
        external
        onlyRole(FEE_ADMIN_ROLE)
    {
        if (feeBps_ > 1000) revert InvalidFee();
        feeRecipient = feeRecipient_;
        feeBps = feeBps_;
        emit FeeParamsUpdated(feeRecipient_, feeBps_);
    }
}