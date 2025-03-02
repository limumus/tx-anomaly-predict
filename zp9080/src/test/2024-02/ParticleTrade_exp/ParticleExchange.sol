pragma solidity 0.8.19;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC721} from "@openzeppelin/contracts/interfaces/IERC721.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {WETH} from "@solmate/tokens/WETH.sol";

import {IParticleExchange} from "../interfaces/IParticleExchange.sol";
import {ReentrancyGuard} from "../libraries/security/ReentrancyGuard.sol";
import {MathUtils} from "../libraries/math/MathUtils.sol";
import {Lien} from "../libraries/types/Structs.sol";
import {Errors} from "../libraries/types/Errors.sol";

contract ParticleExchange is IParticleExchange, Ownable2StepUpgradeable, UUPSUpgradeable, ReentrancyGuard, Multicall {
    using Address for address payable;

    uint256 private constant _MAX_RATE = 100_000; // 1000% APR
    uint256 private constant _MAX_PRICE = 1_000 ether;
    uint256 private constant _MAX_TREASURY_RATE = 1_000; // 10%
    uint256 private constant _AUCTION_DURATION = 36 hours;
    uint256 private constant _MIN_AUCTION_DURATION = 1 hours;

    WETH private immutable weth;

    uint256 private _nextLienId;
    uint256 private _treasuryRate;
    uint256 private _treasury;
    mapping(uint256 lienId => bytes32 lienHash) public liens;
    mapping(address account => uint256 balance) public accountBalance;
    mapping(address marketplace => bool registered) public registeredMarketplaces;

    // required by openzeppelin UUPS module
    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address) internal override onlyOwner {}

    constructor(address wethAddress) {
        weth = WETH(payable(wethAddress));
        _disableInitializers();
    }

    function initialize() external initializer {
        __UUPSUpgradeable_init();
        __Ownable_init();
    }

    /*==============================================================
                               Supply Logic
    ==============================================================*/

    /// @inheritdoc IParticleExchange
    function supplyNft(
        address collection,
        uint256 tokenId,
        uint256 price,
        uint256 rate
    ) external override nonReentrant returns (uint256 lienId) {
        lienId = _supplyNft(msg.sender, collection, tokenId, price, rate);

        // transfer NFT into contract
        /// @dev collection.setApprovalForAll should have been called by this point
        /// @dev receiver is this contract, no need to safeTransferFrom
        IERC721(collection).transferFrom(msg.sender, address(this), tokenId);

        return lienId;
    }

    function _supplyNft(
        address lender,
        address collection,
        uint256 tokenId,
        uint256 price,
        uint256 rate
    ) internal returns (uint256 lienId) {
        if (price > _MAX_PRICE || rate > _MAX_RATE) {
            revert Errors.InvalidParameters();
        }

        // create a new lien
        Lien memory lien = Lien({
            lender: lender,
            borrower: address(0),
            collection: collection,
            tokenId: tokenId,
            price: price,
            rate: rate,
            loanStartTime: 0,
            auctionStartTime: 0
        });

        /// @dev Safety: lienId unlikely to overflow by linear increment
        unchecked {
            liens[lienId = _nextLienId++] = keccak256(abi.encode(lien));
        }

        emit SupplyNFT(lienId, lender, collection, tokenId, price, rate);
    }

    /// @inheritdoc IParticleExchange
    function updateLoan(
        Lien calldata lien,
        uint256 lienId,
        uint256 price,
        uint256 rate
    ) external override validateLien(lien, lienId) nonReentrant {
        if (msg.sender != lien.lender) {
            revert Errors.Unauthorized();
        }

        if (lien.loanStartTime != 0) {
            revert Errors.LoanStarted();
        }

        if (price > _MAX_PRICE || rate > _MAX_RATE) {
            revert Errors.InvalidParameters();
        }

        liens[lienId] = keccak256(
            abi.encode(
                Lien({
                    lender: lien.lender,
                    borrower: address(0),
                    collection: lien.collection,
                    tokenId: lien.tokenId,
                    price: price,
                    rate: rate,
                    loanStartTime: 0,
                    auctionStartTime: 0
                })
            )
        );

        emit UpdateLoan(lienId, price, rate);
    }

    /*==============================================================
                              Withdraw Logic
    ==============================================================*/

    /// @inheritdoc IParticleExchange
    function withdrawNft(Lien calldata lien, uint256 lienId) external override validateLien(lien, lienId) nonReentrant {
        if (msg.sender != lien.lender) {
            revert Errors.Unauthorized();
        }

        if (lien.loanStartTime != 0) {
            /// @dev the same tokenId can be used for other lender's active loan, can't withdraw others
            revert Errors.LoanStarted();
        }

        // delete lien
        delete liens[lienId];

        // transfer NFT back to lender
        /// @dev can withdraw at this point means the NFT is currently in contract without active loan
        /// @dev the interest (if any) is already accrued to lender at NFT acquiring time
        /// @dev use transferFrom in case the receiver does not implement onERC721Received
        IERC721(lien.collection).transferFrom(address(this), msg.sender, lien.tokenId);

        emit WithdrawNFT(lienId);
    }

    /// @inheritdoc IParticleExchange
    function withdrawEth(Lien calldata lien, uint256 lienId) external override validateLien(lien, lienId) nonReentrant {
        if (msg.sender != lien.lender) {
            revert Errors.Unauthorized();
        }

        if (lien.loanStartTime == 0) {
            revert Errors.InactiveLoan();
        }

        // verify that auction is concluded (i.e., liquidation condition has met)
        if (lien.auctionStartTime == 0 || block.timestamp <= lien.auctionStartTime + _AUCTION_DURATION) {
            revert Errors.LiquidationHasNotReached();
        }

        // delete lien
        delete liens[lienId];

        // transfer ETH to lender, i.e., seize ETH collateral
        payable(lien.lender).sendValue(lien.price);

        emit WithdrawETH(lienId);
    }

    /*==============================================================
                            Market Sell Logic
    ==============================================================*/

    /// @inheritdoc IParticleExchange
    function sellNftToMarketPull(
        Lien calldata lien,
        uint256 lienId,
        uint256 amount,
        address marketplace,
        address puller,
        bytes calldata tradeData
    ) external payable override validateLien(lien, lienId) nonReentrant {
        _sellNftToMarketCheck(lien, amount, msg.sender, msg.value);
        _sellNftToMarketLienUpdate(lien, lienId, amount, msg.sender);
        _execSellNftToMarketPull(lien, lien.tokenId, amount, marketplace, puller, tradeData);
    }

    /// @inheritdoc IParticleExchange
    function sellNftToMarketPush(
        Lien calldata lien,
        uint256 lienId,
        uint256 amount,
        address marketplace,
        bytes calldata tradeData
    ) external payable override validateLien(lien, lienId) nonReentrant {
        _sellNftToMarketCheck(lien, amount, msg.sender, msg.value);
        _sellNftToMarketLienUpdate(lien, lienId, amount, msg.sender);
        _execSellNftToMarketPush(lien, lien.tokenId, amount, marketplace, tradeData);
    }

    /**
     * @dev Common pre market sell checks, for both pull and push based flow
     */
    function _sellNftToMarketCheck(Lien calldata lien, uint256 amount, address msgSender, uint256 msgValue) internal {
        if (lien.loanStartTime != 0) {
            revert Errors.LoanStarted();
        }
        if (lien.lender == address(0)) {
            revert Errors.BidNotTaken();
        }
        /// @dev: underlying account balancing ensures balance > lien.price - (amount + msg.value) (i.e., no overspend)
        _balanceAccount(msgSender, lien.price, amount + msgValue);
    }

    /**
     * @dev Common operations prior to market sell execution, used for both market sell and bid acceptance flow
     */
    function _sellNftToMarketBeforeExec(address marketplace) internal view returns (uint256) {
        if (!registeredMarketplaces[marketplace]) {
            revert Errors.UnregisteredMarketplace();
        }
        // ETH + WETH balance before NFT sell execution
        return address(this).balance + weth.balanceOf(address(this));
    }

    /**
     * @dev Pull-based sell nft to market internal execution, used for both market sell and bid acceptance flow
     */
    function _execSellNftToMarketPull(
        Lien memory lien,
        uint256 tokenId,
        uint256 amount,
        address marketplace,
        address puller,
        bytes memory tradeData
    ) internal {
        uint256 balanceBefore = _sellNftToMarketBeforeExec(marketplace);

        /// @dev only approve for one tokenId, preventing bulk execute attack in raw trade
        /// @dev puller (e.g. Seaport Conduit) may be different from marketplace (e.g. Seaport Proxy Router)
        IERC721(lien.collection).approve(puller, tokenId);

        // execute raw order on registered marketplace
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = marketplace.call(tradeData);
        if (!success) {
            revert Errors.MartketplaceFailedToTrade();
        }

        _sellNftToMarketAfterExec(lien, tokenId, amount, balanceBefore);
    }

    /**
     * @dev Push-based sell nft to market internal execution, used for both market sell and bid acceptance flow
     */
    function _execSellNftToMarketPush(
        Lien memory lien,
        uint256 tokenId,
        uint256 amount,
        address marketplace,
        bytes memory tradeData
    ) internal {
        uint256 balanceBefore = _sellNftToMarketBeforeExec(marketplace);

        /// @dev directly send NFT to a marketplace router (e.g. Reservoir); based on the data,
        /// the router will match order and transfer back the correct amount of fund
        IERC721(lien.collection).safeTransferFrom(address(this), marketplace, tokenId, tradeData);

        _sellNftToMarketAfterExec(lien, tokenId, amount, balanceBefore);
    }

    /**
     * @dev Common operations after market sell execution, used for both market sell and bid acceptance flow
     */
    function _sellNftToMarketAfterExec(
        Lien memory lien,
        uint256 tokenId,
        uint256 amount,
        uint256 balanceBefore
    ) internal {
        // transform all WETH (from this trade or otherwise collected elsewhere) to ETH
        uint256 wethAfter = weth.balanceOf(address(this));
        if (wethAfter > 0) {
            weth.withdraw(wethAfter);
        }

        // verify that the NFT in lien is sold and the balance increase is correct
        if (
            IERC721(lien.collection).ownerOf(tokenId) == address(this) ||
            address(this).balance - balanceBefore != amount
        ) {
            revert Errors.InvalidNFTSell();
        }
    }

    /**
     * @dev Common post market sell checks, for both pull and push based flow
     */
    function _sellNftToMarketLienUpdate(
        Lien calldata lien,
        uint256 lienId,
        uint256 amount,
        address msgSender
    ) internal {
        // update lien
        liens[lienId] = keccak256(
            abi.encode(
                Lien({
                    lender: lien.lender,
                    borrower: msgSender,
                    collection: lien.collection,
                    tokenId: lien.tokenId,
                    price: lien.price,
                    rate: lien.rate,
                    loanStartTime: block.timestamp,
                    auctionStartTime: 0
                })
            )
        );

        emit SellMarketNFT(lienId, msgSender, amount, block.timestamp);
    }

    /*==============================================================
                            Market Buy Logic
    ==============================================================*/

    /// @inheritdoc IParticleExchange
    function buyNftFromMarket(
        Lien calldata lien,
        uint256 lienId,
        uint256 tokenId,
        uint256 amount,
        address spender,
        address marketplace,
        bytes calldata tradeData
    ) external override validateLien(lien, lienId) nonReentrant {
        if (msg.sender != lien.borrower) {
            revert Errors.Unauthorized();
        }

        if (lien.loanStartTime == 0) {
            revert Errors.InactiveLoan();
        }

        uint256 accruedInterest = MathUtils.calculateCurrentInterest(lien.price, lien.rate, lien.loanStartTime);

        // since: lien.price = sold amount + margin
        // and:   payback    = sold amount + margin - bought amount - interest
        // hence: payback    = lien.price - bought amount - interest
        /// @dev cannot overspend, i.e., will revert if payback to borrower < 0. Payback < 0
        /// means the borrower loses all the margin, and still owes some interest. Notice that
        /// this function is not payable because rational borrower won't deposit even more cost
        /// to exit an already liquidated position.
        uint256 payback = lien.price - amount - accruedInterest;

        // accrue interest to lender
        _accrueInterest(lien.lender, accruedInterest);

        // payback PnL to borrower
        if (payback > 0) {
            accountBalance[lien.borrower] += payback;
        }

        // update lien (by default, the lien is open to accept new loan)
        liens[lienId] = keccak256(
            abi.encode(
                Lien({
                    lender: lien.lender,
                    borrower: address(0),
                    collection: lien.collection,
                    tokenId: tokenId,
                    price: lien.price,
                    rate: lien.rate,
                    loanStartTime: 0,
                    auctionStartTime: 0
                })
            )
        );

        // route trade execution to marketplace
        _execBuyNftFromMarket(lien.collection, tokenId, amount, spender, marketplace, tradeData);

        emit BuyMarketNFT(lienId, tokenId, amount);
    }

    function _execBuyNftFromMarket(
        address collection,
        uint256 tokenId,
        uint256 amount,
        address spender,
        address marketplace,
        bytes calldata tradeData
    ) internal {
        if (!registeredMarketplaces[marketplace]) {
            revert Errors.UnregisteredMarketplace();
        }

        if (IERC721(collection).ownerOf(tokenId) == address(this)) {
            revert Errors.InvalidNFTBuy();
        }

        uint256 ethBalanceBefore = address(this).balance;
        uint256 wethBalanceBefore = weth.balanceOf(address(this));

        // execute raw order on registered marketplace
        bool success;
        if (spender == address(0)) {
            // use ETH
            // solhint-disable-next-line avoid-low-level-calls
            (success, ) = marketplace.call{value: amount}(tradeData);
        } else {
            // use WETH
            weth.deposit{value: amount}();
            weth.approve(spender, amount);
            // solhint-disable-next-line avoid-low-level-calls
            (success, ) = marketplace.call(tradeData);
        }

        if (!success) {
            revert Errors.MartketplaceFailedToTrade();
        }

        // conert back any unspent WETH to ETH
        uint256 wethBalance = weth.balanceOf(address(this));
        if (wethBalance > 0) {
            weth.withdraw(wethBalance);
        }

        // verify that the declared NFT is acquired and the balance decrease is correct
        if (
            IERC721(collection).ownerOf(tokenId) != address(this) ||
            ethBalanceBefore + wethBalanceBefore - address(this).balance != amount
        ) {
            revert Errors.InvalidNFTBuy();
        }
    }

    /*==============================================================
                               Swap Logic
    ==============================================================*/

    /// @inheritdoc IParticleExchange
    function swapWithEth(
        Lien calldata lien,
        uint256 lienId
    ) external payable override validateLien(lien, lienId) nonReentrant {
        if (lien.loanStartTime != 0) {
            revert Errors.LoanStarted();
        }

        if (lien.lender == address(0)) {
            revert Errors.BidNotTaken();
        }

        /// @dev: underlying account balancing ensures balance > lien.price - msg.value (i.e., no overspend)
        _balanceAccount(msg.sender, lien.price, msg.value);

        // update lien
        liens[lienId] = keccak256(
            abi.encode(
                Lien({
                    lender: lien.lender,
                    borrower: msg.sender,
                    collection: lien.collection,
                    tokenId: lien.tokenId,
                    price: lien.price,
                    rate: lien.rate,
                    loanStartTime: block.timestamp,
                    auctionStartTime: 0
                })
            )
        );

        // transfer NFT to borrower
        IERC721(lien.collection).safeTransferFrom(address(this), msg.sender, lien.tokenId);

        emit SwapWithETH(lienId, msg.sender, block.timestamp);
    }

    /// @inheritdoc IParticleExchange
    function repayWithNft(
        Lien calldata lien,
        uint256 lienId,
        uint256 tokenId
    ) external override validateLien(lien, lienId) nonReentrant {
        if (msg.sender != lien.borrower) {
            revert Errors.Unauthorized();
        }

        if (lien.loanStartTime == 0) {
            revert Errors.InactiveLoan();
        }

        // transfer fund to corresponding recipients
        _execRepayWithNft(lien, lienId, tokenId);

        // transfer NFT to the contract
        /// @dev collection.setApprovalForAll should have been called by this point
        /// @dev receiver is this contract, no need to safeTransferFrom
        IERC721(lien.collection).transferFrom(msg.sender, address(this), tokenId);
    }

    /// @dev unchecked function, make sure lien is valid, caller is borrower and collection is matched
    function _execRepayWithNft(Lien memory lien, uint256 lienId, uint256 tokenId) internal {
        // accrue interest to lender
        uint256 accruedInterest = MathUtils.calculateCurrentInterest(lien.price, lien.rate, lien.loanStartTime);

        // pay PnL to borrower
        // since: lien.price = sold amount + margin
        // and:   payback    = sold amount + margin - interest
        // hence: payback    = lien.price - interest
        uint256 payback = lien.price - accruedInterest;
        if (payback > 0) {
            accountBalance[lien.borrower] += payback;
        }

        // accrue interest to lender
        _accrueInterest(lien.lender, accruedInterest);

        // update lien (by default, the lien is open to accept new loan)
        liens[lienId] = keccak256(
            abi.encode(
                Lien({
                    lender: lien.lender,
                    borrower: address(0),
                    collection: lien.collection,
                    tokenId: tokenId,
                    price: lien.price,
                    rate: lien.rate,
                    loanStartTime: 0,
                    auctionStartTime: 0
                })
            )
        );

        emit RepayWithNFT(lienId, tokenId);
    }

    /*==============================================================
                            Refinance Logic
    ==============================================================*/

    /// @inheritdoc IParticleExchange
    function refinanceLoan(
        Lien calldata oldLien,
        uint256 oldLienId,
        Lien calldata newLien,
        uint256 newLienId
    ) external payable override validateLien(oldLien, oldLienId) validateLien(newLien, newLienId) nonReentrant {
        if (msg.sender != oldLien.borrower) {
            revert Errors.Unauthorized();
        }

        if (oldLien.loanStartTime == 0) {
            revert Errors.InactiveLoan();
        }

        if (newLien.loanStartTime != 0) {
            // cannot swap to another active loan
            revert Errors.LoanStarted();
        }

        if (newLien.lender == address(0)) {
            revert Errors.BidNotTaken();
        }

        if (oldLien.collection != newLien.collection) {
            // cannot swap to a new loan with different collection
            revert Errors.UnmatchedCollections();
        }

        uint256 accruedInterest = MathUtils.calculateCurrentInterest(
            oldLien.price,
            oldLien.rate,
            oldLien.loanStartTime
        );

        /// @dev old price + msg.value is available now, new price + interest is the need to spend
        /// @dev account balancing ensures balance > new price + interest - (old price + msg.value) (i.e., no overspend)
        _balanceAccount(msg.sender, newLien.price + accruedInterest, oldLien.price + msg.value);

        // accrue interest to the lender
        _accrueInterest(oldLien.lender, accruedInterest);

        // update old lien
        liens[oldLienId] = keccak256(
            abi.encode(
                Lien({
                    lender: oldLien.lender,
                    borrower: address(0),
                    collection: oldLien.collection,
                    tokenId: newLien.tokenId,
                    price: oldLien.price,
                    rate: oldLien.rate,
                    loanStartTime: 0,
                    auctionStartTime: 0
                })
            )
        );

        // update new lien
        liens[newLienId] = keccak256(
            abi.encode(
                Lien({
                    lender: newLien.lender,
                    borrower: oldLien.borrower,
                    collection: newLien.collection,
                    tokenId: newLien.tokenId,
                    price: newLien.price,
                    rate: newLien.rate,
                    loanStartTime: block.timestamp,
                    auctionStartTime: 0
                })
            )
        );

        emit Refinance(oldLienId, newLienId, block.timestamp);
    }

    /*==============================================================
                                 Bid Logic
    ==============================================================*/

    /// @inheritdoc IParticleExchange
    function offerBid(
        address collection,
        uint256 margin,
        uint256 price,
        uint256 rate
    ) external payable override nonReentrant returns (uint256 lienId) {
        if (price > _MAX_PRICE || rate > _MAX_RATE) {
            revert Errors.InvalidParameters();
        }

        // balance the account for the reest of the margin
        _balanceAccount(msg.sender, margin, msg.value);

        // create a new lien
        Lien memory lien = Lien({
            lender: address(0),
            borrower: msg.sender,
            collection: collection,
            tokenId: margin, /// @dev: use tokenId for margin storage
            price: price,
            rate: rate,
            loanStartTime: 0,
            auctionStartTime: 0
        });

        /// @dev Safety: lienId unlikely to overflow by linear increment
        unchecked {
            liens[lienId = _nextLienId++] = keccak256(abi.encode(lien));
        }

        emit OfferBid(lienId, msg.sender, collection, margin, price, rate);
    }

    /// @inheritdoc IParticleExchange
    function updateBid(
        Lien calldata lien,
        uint256 lienId,
        uint256 margin,
        uint256 price,
        uint256 rate
    ) external payable validateLien(lien, lienId) nonReentrant {
        if (msg.sender != lien.borrower) {
            revert Errors.Unauthorized();
        }

        if (lien.lender != address(0)) {
            /// @dev: if lender exists, an NFT is supplied, regardless of loan active or not,
            /// bid is taken and can't be updated
            revert Errors.BidTaken();
        }

        if (price > _MAX_PRICE || rate > _MAX_RATE) {
            revert Errors.InvalidParameters();
        }

        /// @dev: old margin was stored in the lien.tokenId field
        /// @dev: old margin + msg.value is available now; surplus adds to balance, deficit takes from balance
        _balanceAccount(msg.sender, margin, lien.tokenId + msg.value);

        // update lien
        liens[lienId] = keccak256(
            abi.encode(
                Lien({
                    lender: address(0),
                    borrower: lien.borrower,
                    collection: lien.collection,
                    tokenId: margin, /// @dev: use tokenId for margin storage
                    price: price,
                    rate: rate,
                    loanStartTime: 0,
                    auctionStartTime: 0
                })
            )
        );

        emit UpdateBid(lienId, margin, price, rate);
    }

    /// @inheritdoc IParticleExchange
    function cancelBid(Lien calldata lien, uint256 lienId) external override validateLien(lien, lienId) nonReentrant {
        if (msg.sender != lien.borrower) {
            revert Errors.Unauthorized();
        }

        if (lien.lender != address(0)) {
            /// @dev: if lender exists, an NFT is supplied, regardless of loan active or not,
            /// bid is taken and can't be cancelled
            revert Errors.BidTaken();
        }

        // return margin to borrower
        /// @dev: old margin was stored in the lien.tokenId field
        accountBalance[lien.borrower] += lien.tokenId;

        // delete lien
        delete liens[lienId];

        emit CancelBid(lienId);
    }

    /// @inheritdoc IParticleExchange
    function acceptBidSellNftToMarketPull(
        Lien calldata lien,
        uint256 lienId,
        uint256 tokenId,
        uint256 amount,
        address marketplace,
        address puller,
        bytes calldata tradeData
    ) external override validateLien(lien, lienId) nonReentrant {
        _acceptBidSellNftToMarketCheck(lien, amount);
        _acceptBidSellNftToMarketLienUpdate(lien, lienId, tokenId, amount, msg.sender);
        // transfer NFT into contract
        /// @dev collection.setApprovalForAll should have been called by this point
        /// @dev receiver is this contract, no need to safeTransferFrom
        IERC721(lien.collection).transferFrom(msg.sender, address(this), tokenId);
        _execSellNftToMarketPull(lien, tokenId, amount, marketplace, puller, tradeData);
    }

    /// @inheritdoc IParticleExchange
    function acceptBidSellNftToMarketPush(
        Lien calldata lien,
        uint256 lienId,
        uint256 tokenId,
        uint256 amount,
        address marketplace,
        bytes calldata tradeData
    ) external override validateLien(lien, lienId) nonReentrant {
        _acceptBidSellNftToMarketCheck(lien, amount);
        _acceptBidSellNftToMarketLienUpdate(lien, lienId, tokenId, amount, msg.sender);
        // transfer NFT into contract
        /// @dev collection.setApprovalForAll should have been called by this point
        /// @dev receiver is this contract, no need to safeTransferFrom
        IERC721(lien.collection).transferFrom(msg.sender, address(this), tokenId);
        _execSellNftToMarketPush(lien, tokenId, amount, marketplace, tradeData);
    }

    function _acceptBidSellNftToMarketCheck(Lien memory lien, uint256 amount) internal {
        if (lien.lender != address(0)) {
            /// @dev: if lender exists, an NFT is supplied, regardless of loan active or not,
            /// bid is taken and can't be re-accepted
            revert Errors.BidTaken();
        }

        // transfer the surplus to the borrower
        /// @dev: lien.tokenId stores the margin
        /// @dev: revert if margin + sold amount can't cover lien.price, i.e., no overspend
        accountBalance[lien.borrower] += lien.tokenId + amount - lien.price;
    }

    function _acceptBidSellNftToMarketLienUpdate(
        Lien memory lien,
        uint256 lienId,
        uint256 tokenId,
        uint256 amount,
        address lender
    ) internal {
        // update lien
        liens[lienId] = keccak256(
            abi.encode(
                Lien({
                    lender: lender,
                    borrower: lien.borrower,
                    collection: lien.collection,
                    tokenId: tokenId,
                    price: lien.price,
                    rate: lien.rate,
                    loanStartTime: block.timestamp,
                    auctionStartTime: 0
                })
            )
        );

        emit AcceptBid(lienId, lender, tokenId, amount, block.timestamp);
    }

    /*==============================================================
                               Auction Logic
    ==============================================================*/

    /// @inheritdoc IParticleExchange
    function startLoanAuction(
        Lien calldata lien,
        uint256 lienId
    ) external override validateLien(lien, lienId) nonReentrant {
        if (msg.sender != lien.lender) {
            revert Errors.Unauthorized();
        }

        if (lien.loanStartTime == 0) {
            revert Errors.InactiveLoan();
        }

        if (lien.auctionStartTime != 0) {
            revert Errors.AuctionStarted();
        }

        // update lien
        liens[lienId] = keccak256(
            abi.encode(
                Lien({
                    lender: lien.lender,
                    borrower: lien.borrower,
                    collection: lien.collection,
                    tokenId: lien.tokenId,
                    price: lien.price,
                    rate: lien.rate,
                    loanStartTime: lien.loanStartTime,
                    auctionStartTime: block.timestamp
                })
            )
        );

        emit StartAuction(lienId, block.timestamp);
    }

    /// @inheritdoc IParticleExchange
    function stopLoanAuction(
        Lien calldata lien,
        uint256 lienId
    ) external override validateLien(lien, lienId) nonReentrant {
        if (msg.sender != lien.lender) {
            revert Errors.Unauthorized();
        }

        if (lien.auctionStartTime == 0) {
            revert Errors.AuctionNotStarted();
        }

        if (block.timestamp < lien.auctionStartTime + _MIN_AUCTION_DURATION) {
            revert Errors.AuctionEndTooSoon();
        }

        // update lien
        liens[lienId] = keccak256(
            abi.encode(
                Lien({
                    lender: lien.lender,
                    borrower: lien.borrower,
                    collection: lien.collection,
                    tokenId: lien.tokenId,
                    price: lien.price,
                    rate: lien.rate,
                    loanStartTime: lien.loanStartTime,
                    auctionStartTime: 0
                })
            )
        );

        emit StopAuction(lienId);
    }

    /// @inheritdoc IParticleExchange
    function auctionSellNft(
        Lien calldata lien,
        uint256 lienId,
        uint256 tokenId
    ) external override validateLien(lien, lienId) nonReentrant {
        if (lien.auctionStartTime == 0) {
            revert Errors.AuctionNotStarted();
        }

        // transfer fund to corresponding recipients
        _execAuctionSellNft(lien, lienId, tokenId, msg.sender);

        // transfer NFT to the contract
        /// @dev receiver is this contract, no need to safeTransferFrom
        /// @dev at this point, collection.setApprovalForAll should have been called
        IERC721(lien.collection).transferFrom(msg.sender, address(this), tokenId);
    }

    /// @dev unchecked function, make sure lien is validated, auction is live and collection is matched
    function _execAuctionSellNft(Lien memory lien, uint256 lienId, uint256 tokenId, address auctionBuyer) internal {
        uint256 accruedInterest = MathUtils.calculateCurrentInterest(lien.price, lien.rate, lien.loanStartTime);

        /// @dev: arithmetic revert if accruedInterest > lien.price, i.e., even 0 buyback cannot cover the interest
        uint256 currentAuctionPrice = MathUtils.calculateCurrentAuctionPrice(
            lien.price - accruedInterest,
            block.timestamp - lien.auctionStartTime,
            _AUCTION_DURATION
        );

        // pay PnL to borrower
        uint256 payback = lien.price - currentAuctionPrice - accruedInterest;
        if (payback > 0) {
            accountBalance[lien.borrower] += payback;
        }

        // pay auction price to new NFT supplier
        payable(auctionBuyer).sendValue(currentAuctionPrice);

        // accrue interest to lender
        _accrueInterest(lien.lender, accruedInterest);

        // update lien (by default, the lien is open to accept new loan)
        liens[lienId] = keccak256(
            abi.encode(
                Lien({
                    lender: lien.lender,
                    borrower: address(0),
                    collection: lien.collection,
                    tokenId: tokenId,
                    price: lien.price,
                    rate: lien.rate,
                    loanStartTime: 0,
                    auctionStartTime: 0
                })
            )
        );

        emit AuctionSellNFT(lienId, auctionBuyer, tokenId, currentAuctionPrice);
    }

    /*==============================================================
                             Push-Based Logic
    ==============================================================*/

    /**
     * @notice Receiver function upon ERC721 transfer
     *
     * @dev We modify this receiver to enable "push based" NFT supply, where one of the following is embedded in the
     * data bytes that are piggy backed with the SafeTransferFrom call:
     * (1) the price and rate (for nft supply) (64 bytes) or
     * (2) lien information (for NFT repay or auction buy) (288 bytes) or
     * (3) lien information and market sell information (accept bid to NFT market sell) (>= 384 bytes).
     * This way, the lender doesn't need to additionally sign the "setApprovalForAll" transaction, which saves gas and
     * creates a better user experience.
     *
     * @param from the address which previously owned the NFT
     * @param tokenId the NFT identifier which is being transferred
     * @param data additional data with no specified format
     */
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata data) external returns (bytes4) {
        /// @dev NFT transfer coming from buyNftFromMarket will be flagged as already enterred (re-entrancy status),
        /// where the NFT is matched with an existing lien already. If it proceeds (to supply), this NFT will be tied
        /// with two liens, which creates divergence.
        if (!isEntered()) {
            _pushBasedNftSupply(from, tokenId, data);
        }
        return this.onERC721Received.selector;
    }

    function _pushBasedNftSupply(address from, uint256 tokenId, bytes calldata data) internal nonReentrant {
        /// @dev this function is external and can be called by anyone, we need to check the NFT is indeed received
        /// at this point to proceed, message sender is the NFT collection in nominal function call
        if (IERC721(msg.sender).ownerOf(tokenId) != address(this)) {
            revert Errors.NFTNotReceived();
        }
        // use data.length to branch different conditions
        if (data.length == 64) {
            // Conditon (1): NFT supply
            (uint256 price, uint256 rate) = abi.decode(data, (uint256, uint256));
            /// @dev the msg.sender is the NFT collection (called by safeTransferFrom's _checkOnERC721Received check)
            _supplyNft(from, msg.sender, tokenId, price, rate);
        } else if (data.length == 288) {
            // Conditon (2): NFT repay or auction buy
            (Lien memory lien, uint256 lienId) = abi.decode(data, (Lien, uint256));
            /// @dev equivalent to modifier validateLien, replacing calldata to memory
            if (liens[lienId] != keccak256(abi.encode(lien))) {
                revert Errors.InvalidLien();
            }
            /// @dev msg.sender is the NFT collection address
            if (msg.sender != lien.collection) {
                revert Errors.UnmatchedCollections();
            }
            if (from == lien.borrower) {
                /// @dev repayWithNft branch
                /// @dev notice that for borrower repayWithNft and auctionSellNft (at any price point) yield the same
                /// return, since repayNft's payback = auction's payback + auction price, and auction price goes to the
                /// same "from" (the borrower) too. Routing to repayNft is more gas efficient for one less receiver.
                if (lien.loanStartTime == 0) {
                    revert Errors.InactiveLoan();
                }
                _execRepayWithNft(lien, lienId, tokenId);
            } else {
                /// @dev auctionSellNft branch
                /// @dev equivalent to modifier auctionLive, replacing calldata to memory
                if (lien.auctionStartTime == 0) {
                    revert Errors.AuctionNotStarted();
                }
                /// @dev "from" (acution buyer) is the auction buyer address that calls safeTransferFrom
                _execAuctionSellNft(lien, lienId, tokenId, from);
            }
        } else if (data.length >= 384) {
            // Conditon (3): Accept bid to sell NFT to market
            /// @dev flexible data.length because tradeData can be of any non-zero length
            (
                Lien memory lien,
                uint256 lienId,
                uint256 amount,
                address marketplace,
                address puller,
                bytes memory tradeData
            ) = abi.decode(data, (Lien, uint256, uint256, address, address, bytes));
            /// @dev equivalent to modifier validateLien, replacing calldata to memory
            if (liens[lienId] != keccak256(abi.encode(lien))) {
                revert Errors.InvalidLien();
            }
            /// @dev msg.sender is the NFT collection address
            if (msg.sender != lien.collection) {
                revert Errors.UnmatchedCollections();
            }
            /// @dev "from" (nft supplier) is address that calls safeTransferFrom
            /// @dev zero address puller, means sell to market using push based flow
            if (puller == address(0)) {
                _acceptBidSellNftToMarketCheck(lien, amount);
                _acceptBidSellNftToMarketLienUpdate(lien, lienId, tokenId, amount, from);
                _execSellNftToMarketPush(lien, tokenId, amount, marketplace, tradeData);
            } else {
                _acceptBidSellNftToMarketCheck(lien, amount);
                _acceptBidSellNftToMarketLienUpdate(lien, lienId, tokenId, amount, from);
                _execSellNftToMarketPull(lien, tokenId, amount, marketplace, puller, tradeData);
            }
        } else {
            revert Errors.InvalidParameters();
        }
    }

    /*==============================================================
                               Balance Logic
    ==============================================================*/

    /// @inheritdoc IParticleExchange
    function withdrawAccountBalance() external override nonReentrant {
        uint256 balance = accountBalance[msg.sender];
        if (balance == 0) return;

        accountBalance[msg.sender] = 0;
        payable(msg.sender).sendValue(balance);

        emit WithdrawAccountBalance(msg.sender, balance);
    }

    function _accrueInterest(address account, uint256 amount) internal {
        uint256 treasuryRate = _treasuryRate; /// @dev SLOAD once to cache, saving gas
        if (treasuryRate > 0) {
            uint256 treasuryInterest = MathUtils.calculateTreasuryProportion(amount, treasuryRate);
            _treasury += treasuryInterest;
            amount -= treasuryInterest;
        }
        accountBalance[account] += amount;

        emit AccrueInterest(account, amount);
    }

    function _balanceAccount(address account, uint256 withdraw, uint256 deposit) internal {
        if (withdraw > deposit) {
            // use account balance to cover the deposit deficit
            /// @dev balance - (amount - deposit) >= 0, i.e., amount <= balance + deposit (cannot overspend)
            accountBalance[account] -= (withdraw - deposit);
        } else if (deposit > withdraw) {
            // top up account balance with the deposit surplus
            accountBalance[account] += (deposit - withdraw);
        }
    }

    /*==============================================================
                             Validation Logic
    ==============================================================*/

    modifier validateLien(Lien calldata lien, uint256 lienId) {
        if (liens[lienId] != keccak256(abi.encode(lien))) {
            revert Errors.InvalidLien();
        }
        _;
    }

    /*==============================================================
                               Admin Logic
    ==============================================================*/

    /// @inheritdoc IParticleExchange
    function registerMarketplace(address marketplace) external override onlyOwner {
        registeredMarketplaces[marketplace] = true;
        emit RegisterMarketplace(marketplace);
    }

    /// @inheritdoc IParticleExchange
    function unregisterMarketplace(address marketplace) external override onlyOwner {
        registeredMarketplaces[marketplace] = false;
        emit UnregisterMarketplace(marketplace);
    }

    /// @inheritdoc IParticleExchange
    function setTreasuryRate(uint256 rate) external override onlyOwner {
        if (rate > _MAX_TREASURY_RATE) {
            revert Errors.InvalidParameters();
        }
        _treasuryRate = rate;
        emit UpdateTreasuryRate(rate);
    }

    /// @inheritdoc IParticleExchange
    function withdrawTreasury(address receiver) external override onlyOwner {
        uint256 withdrawAmount = _treasury;
        if (withdrawAmount > 0) {
            if (receiver == address(0)) {
                revert Errors.InvalidParameters();
            }
            _treasury = 0;
            payable(receiver).sendValue(withdrawAmount);
            emit WithdrawTreasury(receiver, withdrawAmount);
        }
    }

    /*==============================================================
                              Miscellaneous
    ==============================================================*/

    // receive ETH
    // solhint-disable-next-line no-empty-blocks
    receive() external payable {}

    // solhint-disable-next-line func-name-mixedcase
    function WETH_ADDRESS() external view returns (address) {
        return address(weth);
    }
}
pragma solidity ^0.8.0;

import "../../interfaces/draft-IERC1822Upgradeable.sol";
import "../ERC1967/ERC1967UpgradeUpgradeable.sol";
import "./Initializable.sol";

/**
 * @dev An upgradeability mechanism designed for UUPS proxies. The functions included here can perform an upgrade of an
 * {ERC1967Proxy}, when this contract is set as the implementation behind such a proxy.
 *
 * A security mechanism ensures that an upgrade does not turn off upgradeability accidentally, although this risk is
 * reinstated if the upgrade retains upgradeability but removes the security mechanism, e.g. by replacing
 * `UUPSUpgradeable` with a custom implementation of upgrades.
 *
 * The {_authorizeUpgrade} function must be overridden to include access restriction to the upgrade mechanism.
 *
 * _Available since v4.1._
 */
abstract contract UUPSUpgradeable is Initializable, IERC1822ProxiableUpgradeable, ERC1967UpgradeUpgradeable {
    function __UUPSUpgradeable_init() internal onlyInitializing {
    }

    function __UUPSUpgradeable_init_unchained() internal onlyInitializing {
    }
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable state-variable-assignment
    address private immutable __self = address(this);

    /**
     * @dev Check that the execution is being performed through a delegatecall call and that the execution context is
     * a proxy contract with an implementation (as defined in ERC1967) pointing to self. This should only be the case
     * for UUPS and transparent proxies that are using the current contract as their implementation. Execution of a
     * function through ERC1167 minimal proxies (clones) would not normally pass this test, but is not guaranteed to
     * fail.
     */
    modifier onlyProxy() {
        require(address(this) != __self, "Function must be called through delegatecall");
        require(_getImplementation() == __self, "Function must be called through active proxy");
        _;
    }

    /**
     * @dev Check that the execution is not being performed through a delegate call. This allows a function to be
     * callable on the implementing contract but not through proxies.
     */
    modifier notDelegated() {
        require(address(this) == __self, "UUPSUpgradeable: must not be called through delegatecall");
        _;
    }

    /**
     * @dev Implementation of the ERC1822 {proxiableUUID} function. This returns the storage slot used by the
     * implementation. It is used to validate the implementation's compatibility when performing an upgrade.
     *
     * IMPORTANT: A proxy pointing at a proxiable contract should not be considered proxiable itself, because this risks
     * bricking a proxy that upgrades to it, by delegating to itself until out of gas. Thus it is critical that this
     * function revert if invoked through a proxy. This is guaranteed by the `notDelegated` modifier.
     */
    function proxiableUUID() external view virtual override notDelegated returns (bytes32) {
        return _IMPLEMENTATION_SLOT;
    }

    /**
     * @dev Upgrade the implementation of the proxy to `newImplementation`.
     *
     * Calls {_authorizeUpgrade}.
     *
     * Emits an {Upgraded} event.
     */
    function upgradeTo(address newImplementation) external virtual onlyProxy {
        _authorizeUpgrade(newImplementation);
        _upgradeToAndCallUUPS(newImplementation, new bytes(0), false);
    }

    /**
     * @dev Upgrade the implementation of the proxy to `newImplementation`, and subsequently execute the function call
     * encoded in `data`.
     *
     * Calls {_authorizeUpgrade}.
     *
     * Emits an {Upgraded} event.
     */
    function upgradeToAndCall(address newImplementation, bytes memory data) external payable virtual onlyProxy {
        _authorizeUpgrade(newImplementation);
        _upgradeToAndCallUUPS(newImplementation, data, true);
    }

    /**
     * @dev Function that should revert when `msg.sender` is not authorized to upgrade the contract. Called by
     * {upgradeTo} and {upgradeToAndCall}.
     *
     * Normally, this function will use an xref:access.adoc[access control] modifier such as {Ownable-onlyOwner}.
     *
     * ```solidity
     * function _authorizeUpgrade(address) internal override onlyOwner {}
     * ```
     */
    function _authorizeUpgrade(address newImplementation) internal virtual;

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[50] private __gap;
}
pragma solidity ^0.8.0;

import "./OwnableUpgradeable.sol";
import "../proxy/utils/Initializable.sol";

/**
 * @dev Contract module which provides access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * By default, the owner account will be the one that deploys the contract. This
 * can later be changed with {transferOwnership} and {acceptOwnership}.
 *
 * This module is used through inheritance. It will make available all functions
 * from parent (Ownable).
 */
abstract contract Ownable2StepUpgradeable is Initializable, OwnableUpgradeable {
    function __Ownable2Step_init() internal onlyInitializing {
        __Ownable_init_unchained();
    }

    function __Ownable2Step_init_unchained() internal onlyInitializing {
    }
    address private _pendingOwner;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Returns the address of the pending owner.
     */
    function pendingOwner() public view virtual returns (address) {
        return _pendingOwner;
    }

    /**
     * @dev Starts the ownership transfer of the contract to a new account. Replaces the pending transfer if there is one.
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual override onlyOwner {
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner(), newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`) and deletes any pending owner.
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual override {
        delete _pendingOwner;
        super._transferOwnership(newOwner);
    }

    /**
     * @dev The new owner accepts the ownership transfer.
     */
    function acceptOwnership() external {
        address sender = _msgSender();
        require(pendingOwner() == sender, "Ownable2Step: caller is not the new owner");
        _transferOwnership(sender);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[49] private __gap;
}
pragma solidity ^0.8.1;

/**
 * @dev Collection of functions related to the address type
 */
library Address {
    /**
     * @dev Returns true if `account` is a contract.
     *
     * [IMPORTANT]
     * ====
     * It is unsafe to assume that an address for which this function returns
     * false is an externally-owned account (EOA) and not a contract.
     *
     * Among others, `isContract` will return false for the following
     * types of addresses:
     *
     *  - an externally-owned account
     *  - a contract in construction
     *  - an address where a contract will be created
     *  - an address where a contract lived, but was destroyed
     * ====
     *
     * [IMPORTANT]
     * ====
     * You shouldn't rely on `isContract` to protect against flash loan attacks!
     *
     * Preventing calls from contracts is highly discouraged. It breaks composability, breaks support for smart wallets
     * like Gnosis Safe, and does not provide security since it can be circumvented by calling from a contract
     * constructor.
     * ====
     */
    function isContract(address account) internal view returns (bool) {
        // This method relies on extcodesize/address.code.length, which returns 0
        // for contracts in construction, since the code is only stored at the end
        // of the constructor execution.

        return account.code.length > 0;
    }

    /**
     * @dev Replacement for Solidity's `transfer`: sends `amount` wei to
     * `recipient`, forwarding all available gas and reverting on errors.
     *
     * https://eips.ethereum.org/EIPS/eip-1884[EIP1884] increases the gas cost
     * of certain opcodes, possibly making contracts go over the 2300 gas limit
     * imposed by `transfer`, making them unable to receive funds via
     * `transfer`. {sendValue} removes this limitation.
     *
     * https://diligence.consensys.net/posts/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.5.11/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
     */
    function sendValue(address payable recipient, uint256 amount) internal {
        require(address(this).balance >= amount, "Address: insufficient balance");

        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Address: unable to send value, recipient may have reverted");
    }

    /**
     * @dev Performs a Solidity function call using a low level `call`. A
     * plain `call` is an unsafe replacement for a function call: use this
     * function instead.
     *
     * If `target` reverts with a revert reason, it is bubbled up by this
     * function (like regular Solidity function calls).
     *
     * Returns the raw returned data. To convert to the expected return value,
     * use https://solidity.readthedocs.io/en/latest/units-and-global-variables.html?highlight=abi.decode#abi-encoding-and-decoding-functions[`abi.decode`].
     *
     * Requirements:
     *
     * - `target` must be a contract.
     * - calling `target` with `data` must not revert.
     *
     * _Available since v3.1._
     */
    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0, "Address: low-level call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`], but with
     * `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but also transferring `value` wei to `target`.
     *
     * Requirements:
     *
     * - the calling contract must have an ETH balance of at least `value`.
     * - the called Solidity function must be `payable`.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value
    ) internal returns (bytes memory) {
        return functionCallWithValue(target, data, value, "Address: low-level call with value failed");
    }

    /**
     * @dev Same as {xref-Address-functionCallWithValue-address-bytes-uint256-}[`functionCallWithValue`], but
     * with `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value,
        string memory errorMessage
    ) internal returns (bytes memory) {
        require(address(this).balance >= value, "Address: insufficient balance for call");
        (bool success, bytes memory returndata) = target.call{value: value}(data);
        return verifyCallResultFromTarget(target, success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(address target, bytes memory data) internal view returns (bytes memory) {
        return functionStaticCall(target, data, "Address: low-level static call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal view returns (bytes memory) {
        (bool success, bytes memory returndata) = target.staticcall(data);
        return verifyCallResultFromTarget(target, success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a delegate call.
     *
     * _Available since v3.4._
     */
    function functionDelegateCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionDelegateCall(target, data, "Address: low-level delegate call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a delegate call.
     *
     * _Available since v3.4._
     */
    function functionDelegateCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal returns (bytes memory) {
        (bool success, bytes memory returndata) = target.delegatecall(data);
        return verifyCallResultFromTarget(target, success, returndata, errorMessage);
    }

    /**
     * @dev Tool to verify that a low level call to smart-contract was successful, and revert (either by bubbling
     * the revert reason or using the provided one) in case of unsuccessful call or if target was not a contract.
     *
     * _Available since v4.8._
     */
    function verifyCallResultFromTarget(
        address target,
        bool success,
        bytes memory returndata,
        string memory errorMessage
    ) internal view returns (bytes memory) {
        if (success) {
            if (returndata.length == 0) {
                // only check isContract if the call was successful and the return data is empty
                // otherwise we already know that it was a contract
                require(isContract(target), "Address: call to non-contract");
            }
            return returndata;
        } else {
            _revert(returndata, errorMessage);
        }
    }

    /**
     * @dev Tool to verify that a low level call was successful, and revert if it wasn't, either by bubbling the
     * revert reason or using the provided one.
     *
     * _Available since v4.3._
     */
    function verifyCallResult(
        bool success,
        bytes memory returndata,
        string memory errorMessage
    ) internal pure returns (bytes memory) {
        if (success) {
            return returndata;
        } else {
            _revert(returndata, errorMessage);
        }
    }

    function _revert(bytes memory returndata, string memory errorMessage) private pure {
        // Look for revert reason and bubble it up if present
        if (returndata.length > 0) {
            // The easiest way to bubble the revert reason is using memory via assembly
            /// @solidity memory-safe-assembly
            assembly {
                let returndata_size := mload(returndata)
                revert(add(32, returndata), returndata_size)
            }
        } else {
            revert(errorMessage);
        }
    }
}
pragma solidity ^0.8.0;

}
pragma solidity ^0.8.0;

import "./Address.sol";

/**
 * @dev Provides a function to batch together multiple calls in a single external call.
 *
 * _Available since v4.1._
 */
abstract contract Multicall {
    /**
     * @dev Receives and executes a batch of function calls on this contract.
     */
    function multicall(bytes[] calldata data) external virtual returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            results[i] = Address.functionDelegateCall(address(this), data[i]);
        }
        return results;
    }
}
pragma solidity >=0.8.0;

import {ERC20} from "./ERC20.sol";

import {SafeTransferLib} from "../utils/SafeTransferLib.sol";

/// @notice Minimalist and modern Wrapped Ether implementation.
/// @author Solmate (https://github.com/transmissions11/solmate/blob/main/src/tokens/WETH.sol)
/// @author Inspired by WETH9 (https://github.com/dapphub/ds-weth/blob/master/src/weth9.sol)
contract WETH is ERC20("Wrapped Ether", "WETH", 18) {
    using SafeTransferLib for address;

    event Deposit(address indexed from, uint256 amount);

    event Withdrawal(address indexed to, uint256 amount);

    function deposit() public payable virtual {
        _mint(msg.sender, msg.value);

        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) public virtual {
        _burn(msg.sender, amount);

        emit Withdrawal(msg.sender, amount);

        msg.sender.safeTransferETH(amount);
    }

    receive() external payable virtual {
        deposit();
    }
}
pragma solidity 0.8.19;

import {Lien} from "../libraries/types/Structs.sol";

interface IParticleExchange {
    event SupplyNFT(uint256 lienId, address lender, address collection, uint256 tokenId, uint256 price, uint256 rate);

    event UpdateLoan(uint256 lienId, uint256 price, uint256 rate);

    event WithdrawNFT(uint256 lienId);

    event WithdrawETH(uint256 lienId);

    event SellMarketNFT(uint256 lienId, address borrower, uint256 soldAmount, uint256 loanStartTime);

    event BuyMarketNFT(uint256 lienId, uint256 tokenId, uint256 paidAmount);

    event SwapWithETH(uint256 lienId, address borrower, uint256 loanStartTime);

    event RepayWithNFT(uint256 lienId, uint256 tokenId);

    event Refinance(uint256 oldLienId, uint256 newLienId, uint256 loanStartTime);

    event OfferBid(uint256 lienId, address borrower, address collection, uint256 margin, uint256 price, uint256 rate);

    event UpdateBid(uint256 lienId, uint256 margin, uint256 price, uint256 rate);

    event CancelBid(uint256 lienId);

    event AcceptBid(uint256 lienId, address lender, uint256 tokenId, uint256 soldAmount, uint256 loanStartTime);

    event StartAuction(uint256 lienId, uint256 auctionStartTime);

    event StopAuction(uint256 lienId);

    event AuctionSellNFT(uint256 lienId, address supplier, uint256 tokenId, uint256 paidAmount);

    event AccrueInterest(address account, uint256 amount);

    event WithdrawAccountBalance(address account, uint256 amount);

    event UpdateTreasuryRate(uint256 rate);

    event WithdrawTreasury(address receiver, uint256 amount);

    event RegisterMarketplace(address marketplace);

    event UnregisterMarketplace(address marketplace);

    /*==============================================================
                                Supply Logic
    ==============================================================*/

    /**
     * @notice Supply an NFT to contract
     * @param collection The address to the NFT collection
     * @param tokenId The ID of the NFT being supplied
     * @param price The supplier specified price for NFT
     * @param rate The supplier specified interest rate
     * @return lienId newly generated lienId
     */
    function supplyNft(
        address collection,
        uint256 tokenId,
        uint256 price,
        uint256 rate
    ) external returns (uint256 lienId);

    /**
     * @notice Update Loan parameters
     * @param lien Reconstructed lien info
     * @param lienId The ID for the existing lien
     * @param price The supplier specified new price for NFT
     * @param rate The supplier specified new interest rate
     */
    function updateLoan(Lien calldata lien, uint256 lienId, uint256 price, uint256 rate) external;

    /*==============================================================
                              Withdraw Logic
    ==============================================================*/

    /**
     * @notice Withdraw NFT from the contract
     * @param lien Reconstructed lien info
     * @param lienId The ID for the lien being cleared
     */
    function withdrawNft(Lien calldata lien, uint256 lienId) external;

    /**
     * @notice Withdraw ETH from the contract
     * @param lien Reconstructed lien info
     * @param lienId The ID for the lien being cleared
     */
    function withdrawEth(Lien calldata lien, uint256 lienId) external;

    /**
     * @notice Withdraw account balance of the message sender account
     */
    function withdrawAccountBalance() external;

    /*==============================================================
                               Trading Logic
    ==============================================================*/

    /**
     * @notice Pull-based sell NFT to market (another contract initiates NFT transfer)
     * @param lien Reconstructed lien info
     * @param lienId The lien ID
     * @param amount Declared ETH amount for NFT sale
     * @param marketplace The contract address of the marketplace (e.g. Seaport Proxy Router)
     * @param puller The contract address that executes the pull operation (e.g. Seaport Conduit)
     * @param tradeData The trade execution bytes on the marketplace
     */
    function sellNftToMarketPull(
        Lien calldata lien,
        uint256 lienId,
        uint256 amount,
        address marketplace,
        address puller,
        bytes calldata tradeData
    ) external payable;

    /**
     * @notice Push-based sell NFT to market (this contract initiates NFT transfer)
     * @param lien Reconstructed lien info
     * @param lienId The lien ID
     * @param amount Declared ETH amount for NFT sale
     * @param marketplace The contract address of the marketplace
     * @param tradeData The trade execution bytes to route to the marketplace
     */
    function sellNftToMarketPush(
        Lien calldata lien,
        uint256 lienId,
        uint256 amount,
        address marketplace,
        bytes calldata tradeData
    ) external payable;

    /**
     * @notice Buy NFT from market
     * @param lien Reconstructed lien info
     * @param lienId The lien ID
     * @param tokenId The ID of the NFT being bought
     * @param amount Declared ETH amount for NFT purchase
     * @param spender The spender address to approve WETH spending, zero address to use ETH
     * @param marketplace The address of the marketplace
     * @param tradeData The trade execution bytes on the marketplace
     */
    function buyNftFromMarket(
        Lien calldata lien,
        uint256 lienId,
        uint256 tokenId,
        uint256 amount,
        address spender,
        address marketplace,
        bytes calldata tradeData
    ) external;

    /**
     * @notice Swap NFT with ETH
     * @param lien Reconstructed lien info
     * @param lienId The lien ID
     */
    function swapWithEth(Lien calldata lien, uint256 lienId) external payable;

    /**
     * @notice Repay loan with NFT
     * @param lien Reconstructed lien info
     * @param lienId The lien ID
     * @param tokenId The ID of the NFT being used to repay the loan
     */
    function repayWithNft(Lien calldata lien, uint256 lienId, uint256 tokenId) external;

    /**
     * @notice Refinance an existing loan with a new one
     * @param oldLien Reconstructed old lien info
     * @param oldLienId The ID for the existing lien
     * @param newLien Reconstructed new lien info
     * @param newLienId The ID for the new lien
     */
    function refinanceLoan(
        Lien calldata oldLien,
        uint256 oldLienId,
        Lien calldata newLien,
        uint256 newLienId
    ) external payable;

    /*==============================================================
                                 Bid Logic
    ==============================================================*/

    /**
     * @notice Trader offers a bid for loan
     * @param collection The address to the NFT collection
     * @param margin Margin to use, should satisfy: margin <= msg.value + accountBalance[msg.sender]
     * @param price Bade desired price for NFT supplier
     * @param rate Bade interest rate for NFT supplier
     * @return lienId newly generated lienId
     */
    function offerBid(
        address collection,
        uint256 margin,
        uint256 price,
        uint256 rate
    ) external payable returns (uint256 lienId);

    /**
     * @notice Trader offers a bid for loan
     * @param lien Reconstructed lien info
     * @param lienId The lien ID
     * @param margin Margin to use, should satisfy: margin <= msg.value + accountBalance[msg.sender]
     * @param price Bade desired price for NFT supplier
     * @param rate Bade interest rate for NFT supplier
     */
    function updateBid(
        Lien calldata lien,
        uint256 lienId,
        uint256 margin,
        uint256 price,
        uint256 rate
    ) external payable;

    /**
     * @notice Trader cancels a opened bid (not yet accepted)
     * @param lien Reconstructed lien info
     * @param lienId The lien ID
     */
    function cancelBid(Lien calldata lien, uint256 lienId) external;

    /**
     * @notice Supplier accepts a bid by supplying an NFT and pull-based sell to market
     * @param lien Reconstructed lien info
     * @param lienId The lien ID
     * @param tokenId The ID of the NFT being supplied
     * @param amount Declared ETH amount for NFT sale
     * @param marketplace The address of the marketplace (e.g. Seaport Proxy Router)
     * @param puller The contract address that executes the pull operation (e.g. Seaport Conduit)
     * @param tradeData The trade execution bytes on the marketplace
     */
    function acceptBidSellNftToMarketPull(
        Lien calldata lien,
        uint256 lienId,
        uint256 tokenId,
        uint256 amount,
        address marketplace,
        address puller,
        bytes calldata tradeData
    ) external;

    /**
     * @notice Supplier accepts a bid by supplying an NFT and push-based sell to market
     * @param lien Reconstructed lien info
     * @param lienId The lien ID
     * @param tokenId The ID of the NFT being supplied
     * @param amount Declared ETH amount for NFT sale
     * @param marketplace The address of the marketplace
     * @param tradeData The trade execution bytes on the marketplace
     */
    function acceptBidSellNftToMarketPush(
        Lien calldata lien,
        uint256 lienId,
        uint256 tokenId,
        uint256 amount,
        address marketplace,
        bytes calldata tradeData
    ) external;

    /*==============================================================
                               Auction Logic
    ==============================================================*/

    /**
     * @notice Start auction for a loan
     * @param lien Reconstructed lien info
     * @param lienId The lien ID
     */
    function startLoanAuction(Lien calldata lien, uint256 lienId) external;

    /**
     * @notice Stop an auction for a loan
     * @param lien Reconstructed lien info
     * @param lienId The lien ID
     */
    function stopLoanAuction(Lien calldata lien, uint256 lienId) external;

    /**
     * @notice Buy NFT from auction
     * @param lien Reconstructed lien info
     * @param lienId The lien ID
     * @param tokenId The ID of the NFT being bought
     */
    function auctionSellNft(Lien calldata lien, uint256 lienId, uint256 tokenId) external;

    /*==============================================================
                               Admin Logic
    ==============================================================*/

    /**
     * @notice Register a trusted marketplace address
     * @param marketplace The address of the marketplace
     */
    function registerMarketplace(address marketplace) external;

    /**
     * @notice Unregister a marketplace address
     * @param marketplace The address of the marketplace
     */
    function unregisterMarketplace(address marketplace) external;

    /**
     * @notice Update treasury rate
     * @param rate The treasury rate in bips
     */
    function setTreasuryRate(uint256 rate) external;

    /**
     * @notice Withdraw treasury balance
     * @param receiver The address to receive the treasury balance
     */
    function withdrawTreasury(address receiver) external;
}
pragma solidity 0.8.19;

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuard {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and making it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        // On the first call to nonReentrant, _status will be _NOT_ENTERED
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");

        // Any calls to nonReentrant after this point will fail
        _status = _ENTERED;
    }

    function _nonReentrantAfter() private {
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = _NOT_ENTERED;
    }

    function isEntered() internal view returns (bool) {
        return _status == _ENTERED;
    }
}
pragma solidity 0.8.19;

library MathUtils {
    uint256 private constant _BASIS_POINTS = 10_000;

    /**
     * @dev Calculate the current interest linearly accrued since the loan start time.
     * @param principal The principal amount of the loan in WEI
     * @param rateBips The yearly interest rate of the loan in bips
     * @param loanStartTime The timestamp at which this loan is opened
     * @return interest The current interest in WEI
     */
    function calculateCurrentInterest(
        uint256 principal,
        uint256 rateBips,
        uint256 loanStartTime
    ) external view returns (uint256 interest) {
        interest = (principal * rateBips * (block.timestamp - loanStartTime)) / (_BASIS_POINTS * 365 days);
    }

    /**
     * @dev Calculates the current allowed auction price (increases linearly in time)
     * @param price The max auction buy price in WEI
     * @param auctionElapsed The current elapsed auction time
     * @param auctionDuration The block span for the auction
     * @return currentAuctionPrice Current allowed auction price in WEI
     */
    function calculateCurrentAuctionPrice(
        uint256 price,
        uint256 auctionElapsed,
        uint256 auctionDuration
    ) external pure returns (uint256 currentAuctionPrice) {
        uint256 auctionPortion = auctionElapsed > auctionDuration ? auctionDuration : auctionElapsed;
        currentAuctionPrice = (price * auctionPortion) / auctionDuration;
    }

    /**
     * @dev Calculates the proportion that goes into treasury
     * @param interest total interest accrued in WEI
     * @param portionBips The treasury proportion in bips
     * @return treasuryAmount Amount goes into treasury in WEI
     */
    function calculateTreasuryProportion(
        uint256 interest,
        uint256 portionBips
    ) external pure returns (uint256 treasuryAmount) {
        treasuryAmount = (interest * portionBips) / _BASIS_POINTS;
    }
}
pragma solidity 0.8.19;

struct Lien {
    address lender; // NFT supplier address
    address borrower; // NFT trade executor address
    address collection; // NFT collection address
    uint256 tokenId; /// NFT ID  (@dev: at borrower bidding, this field is used to store margin)
    uint256 price; // NFT supplier's desired sold price
    uint256 rate; // APR in bips, _BASIS_POINTS defined in MathUtils.sol
    uint256 loanStartTime; // loan start block.timestamp
    uint256 auctionStartTime; // auction start block.timestamp
}
pragma solidity 0.8.19;

library Errors {
    error Unauthorized();
    error UnregisteredMarketplace();
    error InvalidParameters();
    error InvalidLien();
    error LoanStarted();
    error InactiveLoan();
    error LiquidationHasNotReached();
    error MartketplaceFailedToTrade();
    error InvalidNFTSell();
    error InvalidNFTBuy();
    error NFTNotReceived();
    error Overspend();
    error UnmatchedCollections();
    error BidTaken();
    error BidNotTaken();
    error AuctionStarted();
    error AuctionNotStarted();
    error AuctionEndTooSoon();
}
pragma solidity ^0.8.0;

/**
 * @dev ERC1822: Universal Upgradeable Proxy Standard (UUPS) documents a method for upgradeability through a simplified
 * proxy whose upgrades are fully controlled by the current implementation.
 */
interface IERC1822ProxiableUpgradeable {
    /**
     * @dev Returns the storage slot that the proxiable contract assumes is being used to store the implementation
     * address.
     *
     * IMPORTANT: A proxy pointing at a proxiable contract should not be considered proxiable itself, because this risks
     * bricking a proxy that upgrades to it, by delegating to itself until out of gas. Thus it is critical that this
     * function revert if invoked through a proxy.
     */
    function proxiableUUID() external view returns (bytes32);
}
pragma solidity ^0.8.2;

import "../beacon/IBeaconUpgradeable.sol";
import "../../interfaces/IERC1967Upgradeable.sol";
import "../../interfaces/draft-IERC1822Upgradeable.sol";
import "../../utils/AddressUpgradeable.sol";
import "../../utils/StorageSlotUpgradeable.sol";
import "../utils/Initializable.sol";

/**
 * @dev This abstract contract provides getters and event emitting update functions for
 * https://eips.ethereum.org/EIPS/eip-1967[EIP1967] slots.
 *
 * _Available since v4.1._
 *
 * @custom:oz-upgrades-unsafe-allow delegatecall
 */
abstract contract ERC1967UpgradeUpgradeable is Initializable, IERC1967Upgradeable {
    function __ERC1967Upgrade_init() internal onlyInitializing {
    }

    function __ERC1967Upgrade_init_unchained() internal onlyInitializing {
    }
    // This is the keccak-256 hash of "eip1967.proxy.rollback" subtracted by 1
    bytes32 private constant _ROLLBACK_SLOT = 0x4910fdfa16fed3260ed0e7147f7cc6da11a60208b5b9406d12a635614ffd9143;

    /**
     * @dev Storage slot with the address of the current implementation.
     * This is the keccak-256 hash of "eip1967.proxy.implementation" subtracted by 1, and is
     * validated in the constructor.
     */
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /**
     * @dev Returns the current implementation address.
     */
    function _getImplementation() internal view returns (address) {
        return StorageSlotUpgradeable.getAddressSlot(_IMPLEMENTATION_SLOT).value;
    }

    /**
     * @dev Stores a new address in the EIP1967 implementation slot.
     */
    function _setImplementation(address newImplementation) private {
        require(AddressUpgradeable.isContract(newImplementation), "ERC1967: new implementation is not a contract");
        StorageSlotUpgradeable.getAddressSlot(_IMPLEMENTATION_SLOT).value = newImplementation;
    }

    /**
     * @dev Perform implementation upgrade
     *
     * Emits an {Upgraded} event.
     */
    function _upgradeTo(address newImplementation) internal {
        _setImplementation(newImplementation);
        emit Upgraded(newImplementation);
    }

    /**
     * @dev Perform implementation upgrade with additional setup call.
     *
     * Emits an {Upgraded} event.
     */
    function _upgradeToAndCall(
        address newImplementation,
        bytes memory data,
        bool forceCall
    ) internal {
        _upgradeTo(newImplementation);
        if (data.length > 0 || forceCall) {
            _functionDelegateCall(newImplementation, data);
        }
    }

    /**
     * @dev Perform implementation upgrade with security checks for UUPS proxies, and additional setup call.
     *
     * Emits an {Upgraded} event.
     */
    function _upgradeToAndCallUUPS(
        address newImplementation,
        bytes memory data,
        bool forceCall
    ) internal {
        // Upgrades from old implementations will perform a rollback test. This test requires the new
        // implementation to upgrade back to the old, non-ERC1822 compliant, implementation. Removing
        // this special case will break upgrade paths from old UUPS implementation to new ones.
        if (StorageSlotUpgradeable.getBooleanSlot(_ROLLBACK_SLOT).value) {
            _setImplementation(newImplementation);
        } else {
            try IERC1822ProxiableUpgradeable(newImplementation).proxiableUUID() returns (bytes32 slot) {
                require(slot == _IMPLEMENTATION_SLOT, "ERC1967Upgrade: unsupported proxiableUUID");
            } catch {
                revert("ERC1967Upgrade: new implementation is not UUPS");
            }
            _upgradeToAndCall(newImplementation, data, forceCall);
        }
    }

    /**
     * @dev Storage slot with the admin of the contract.
     * This is the keccak-256 hash of "eip1967.proxy.admin" subtracted by 1, and is
     * validated in the constructor.
     */
    bytes32 internal constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    /**
     * @dev Returns the current admin.
     */
    function _getAdmin() internal view returns (address) {
        return StorageSlotUpgradeable.getAddressSlot(_ADMIN_SLOT).value;
    }

    /**
     * @dev Stores a new address in the EIP1967 admin slot.
     */
    function _setAdmin(address newAdmin) private {
        require(newAdmin != address(0), "ERC1967: new admin is the zero address");
        StorageSlotUpgradeable.getAddressSlot(_ADMIN_SLOT).value = newAdmin;
    }

    /**
     * @dev Changes the admin of the proxy.
     *
     * Emits an {AdminChanged} event.
     */
    function _changeAdmin(address newAdmin) internal {
        emit AdminChanged(_getAdmin(), newAdmin);
        _setAdmin(newAdmin);
    }

    /**
     * @dev The storage slot of the UpgradeableBeacon contract which defines the implementation for this proxy.
     * This is bytes32(uint256(keccak256('eip1967.proxy.beacon')) - 1)) and is validated in the constructor.
     */
    bytes32 internal constant _BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    /**
     * @dev Returns the current beacon.
     */
    function _getBeacon() internal view returns (address) {
        return StorageSlotUpgradeable.getAddressSlot(_BEACON_SLOT).value;
    }

    /**
     * @dev Stores a new beacon in the EIP1967 beacon slot.
     */
    function _setBeacon(address newBeacon) private {
        require(AddressUpgradeable.isContract(newBeacon), "ERC1967: new beacon is not a contract");
        require(
            AddressUpgradeable.isContract(IBeaconUpgradeable(newBeacon).implementation()),
            "ERC1967: beacon implementation is not a contract"
        );
        StorageSlotUpgradeable.getAddressSlot(_BEACON_SLOT).value = newBeacon;
    }

    /**
     * @dev Perform beacon upgrade with additional setup call. Note: This upgrades the address of the beacon, it does
     * not upgrade the implementation contained in the beacon (see {UpgradeableBeacon-_setImplementation} for that).
     *
     * Emits a {BeaconUpgraded} event.
     */
    function _upgradeBeaconToAndCall(
        address newBeacon,
        bytes memory data,
        bool forceCall
    ) internal {
        _setBeacon(newBeacon);
        emit BeaconUpgraded(newBeacon);
        if (data.length > 0 || forceCall) {
            _functionDelegateCall(IBeaconUpgradeable(newBeacon).implementation(), data);
        }
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a delegate call.
     *
     * _Available since v3.4._
     */
    function _functionDelegateCall(address target, bytes memory data) private returns (bytes memory) {
        require(AddressUpgradeable.isContract(target), "Address: delegate call to non-contract");

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returndata) = target.delegatecall(data);
        return AddressUpgradeable.verifyCallResult(success, returndata, "Address: low-level delegate call failed");
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[50] private __gap;
}
pragma solidity ^0.8.2;

import "../../utils/AddressUpgradeable.sol";

/**
 * @dev This is a base contract to aid in writing upgradeable contracts, or any kind of contract that will be deployed
 * behind a proxy. Since proxied contracts do not make use of a constructor, it's common to move constructor logic to an
 * external initializer function, usually called `initialize`. It then becomes necessary to protect this initializer
 * function so it can only be called once. The {initializer} modifier provided by this contract will have this effect.
 *
 * The initialization functions use a version number. Once a version number is used, it is consumed and cannot be
 * reused. This mechanism prevents re-execution of each "step" but allows the creation of new initialization steps in
 * case an upgrade adds a module that needs to be initialized.
 *
 * For example:
 *
 * [.hljs-theme-light.nopadding]
 * ```
 * contract MyToken is ERC20Upgradeable {
 *     function initialize() initializer public {
 *         __ERC20_init("MyToken", "MTK");
 *     }
 * }
 * contract MyTokenV2 is MyToken, ERC20PermitUpgradeable {
 *     function initializeV2() reinitializer(2) public {
 *         __ERC20Permit_init("MyToken");
 *     }
 * }
 * ```
 *
 * TIP: To avoid leaving the proxy in an uninitialized state, the initializer function should be called as early as
 * possible by providing the encoded function call as the `_data` argument to {ERC1967Proxy-constructor}.
 *
 * CAUTION: When used with inheritance, manual care must be taken to not invoke a parent initializer twice, or to ensure
 * that all initializers are idempotent. This is not verified automatically as constructors are by Solidity.
 *
 * [CAUTION]
 * ====
 * Avoid leaving a contract uninitialized.
 *
 * An uninitialized contract can be taken over by an attacker. This applies to both a proxy and its implementation
 * contract, which may impact the proxy. To prevent the implementation contract from being used, you should invoke
 * the {_disableInitializers} function in the constructor to automatically lock it when it is deployed:
 *
 * [.hljs-theme-light.nopadding]
 * ```
 * /// @custom:oz-upgrades-unsafe-allow constructor
 * constructor() {
 *     _disableInitializers();
 * }
 * ```
 * ====
 */
abstract contract Initializable {
    /**
     * @dev Indicates that the contract has been initialized.
     * @custom:oz-retyped-from bool
     */
    uint8 private _initialized;

    /**
     * @dev Indicates that the contract is in the process of being initialized.
     */
    bool private _initializing;

    /**
     * @dev Triggered when the contract has been initialized or reinitialized.
     */
    event Initialized(uint8 version);

    /**
     * @dev A modifier that defines a protected initializer function that can be invoked at most once. In its scope,
     * `onlyInitializing` functions can be used to initialize parent contracts.
     *
     * Similar to `reinitializer(1)`, except that functions marked with `initializer` can be nested in the context of a
     * constructor.
     *
     * Emits an {Initialized} event.
     */
    modifier initializer() {
        bool isTopLevelCall = !_initializing;
        require(
            (isTopLevelCall && _initialized < 1) || (!AddressUpgradeable.isContract(address(this)) && _initialized == 1),
            "Initializable: contract is already initialized"
        );
        _initialized = 1;
        if (isTopLevelCall) {
            _initializing = true;
        }
        _;
        if (isTopLevelCall) {
            _initializing = false;
            emit Initialized(1);
        }
    }

    /**
     * @dev A modifier that defines a protected reinitializer function that can be invoked at most once, and only if the
     * contract hasn't been initialized to a greater version before. In its scope, `onlyInitializing` functions can be
     * used to initialize parent contracts.
     *
     * A reinitializer may be used after the original initialization step. This is essential to configure modules that
     * are added through upgrades and that require initialization.
     *
     * When `version` is 1, this modifier is similar to `initializer`, except that functions marked with `reinitializer`
     * cannot be nested. If one is invoked in the context of another, execution will revert.
     *
     * Note that versions can jump in increments greater than 1; this implies that if multiple reinitializers coexist in
     * a contract, executing them in the right order is up to the developer or operator.
     *
     * WARNING: setting the version to 255 will prevent any future reinitialization.
     *
     * Emits an {Initialized} event.
     */
    modifier reinitializer(uint8 version) {
        require(!_initializing && _initialized < version, "Initializable: contract is already initialized");
        _initialized = version;
        _initializing = true;
        _;
        _initializing = false;
        emit Initialized(version);
    }

    /**
     * @dev Modifier to protect an initialization function so that it can only be invoked by functions with the
     * {initializer} and {reinitializer} modifiers, directly or indirectly.
     */
    modifier onlyInitializing() {
        require(_initializing, "Initializable: contract is not initializing");
        _;
    }

    /**
     * @dev Locks the contract, preventing any future reinitialization. This cannot be part of an initializer call.
     * Calling this in the constructor of a contract will prevent that contract from being initialized or reinitialized
     * to any version. It is recommended to use this to lock implementation contracts that are designed to be called
     * through proxies.
     *
     * Emits an {Initialized} event the first time it is successfully executed.
     */
    function _disableInitializers() internal virtual {
        require(!_initializing, "Initializable: contract is initializing");
        if (_initialized < type(uint8).max) {
            _initialized = type(uint8).max;
            emit Initialized(type(uint8).max);
        }
    }

    /**
     * @dev Returns the highest version that has been initialized. See {reinitializer}.
     */
    function _getInitializedVersion() internal view returns (uint8) {
        return _initialized;
    }

    /**
     * @dev Returns `true` if the contract is currently initializing. See {onlyInitializing}.
     */
    function _isInitializing() internal view returns (bool) {
        return _initializing;
    }
}
pragma solidity ^0.8.0;

import "../utils/ContextUpgradeable.sol";
import "../proxy/utils/Initializable.sol";

/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * By default, the owner account will be the one that deploys the contract. This
 * can later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract OwnableUpgradeable is Initializable, ContextUpgradeable {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    function __Ownable_init() internal onlyInitializing {
        __Ownable_init_unchained();
    }

    function __Ownable_init_unchained() internal onlyInitializing {
        _transferOwnership(_msgSender());
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if the sender is not the owner.
     */
    function _checkOwner() internal view virtual {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[49] private __gap;
}
pragma solidity ^0.8.0;

import "../../utils/introspection/IERC165.sol";

/**
 * @dev Required interface of an ERC721 compliant contract.
 */
interface IERC721 is IERC165 {
    /**
     * @dev Emitted when `tokenId` token is transferred from `from` to `to`.
     */
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    /**
     * @dev Emitted when `owner` enables `approved` to manage the `tokenId` token.
     */
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);

    /**
     * @dev Emitted when `owner` enables or disables (`approved`) `operator` to manage all of its assets.
     */
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    /**
     * @dev Returns the number of tokens in ``owner``'s account.
     */
    function balanceOf(address owner) external view returns (uint256 balance);

    /**
     * @dev Returns the owner of the `tokenId` token.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     */
    function ownerOf(uint256 tokenId) external view returns (address owner);

    /**
     * @dev Safely transfers `tokenId` token from `from` to `to`.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must exist and be owned by `from`.
     * - If the caller is not `from`, it must be approved to move this token by either {approve} or {setApprovalForAll}.
     * - If `to` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon a safe transfer.
     *
     * Emits a {Transfer} event.
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes calldata data
    ) external;

    /**
     * @dev Safely transfers `tokenId` token from `from` to `to`, checking first that contract recipients
     * are aware of the ERC721 protocol to prevent tokens from being forever locked.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must exist and be owned by `from`.
     * - If the caller is not `from`, it must have been allowed to move this token by either {approve} or {setApprovalForAll}.
     * - If `to` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon a safe transfer.
     *
     * Emits a {Transfer} event.
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    /**
     * @dev Transfers `tokenId` token from `from` to `to`.
     *
     * WARNING: Note that the caller is responsible to confirm that the recipient is capable of receiving ERC721
     * or else they may be permanently lost. Usage of {safeTransferFrom} prevents loss, though the caller must
     * understand this adds an external call which potentially creates a reentrancy vulnerability.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must be owned by `from`.
     * - If the caller is not `from`, it must be approved to move this token by either {approve} or {setApprovalForAll}.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    /**
     * @dev Gives permission to `to` to transfer `tokenId` token to another account.
     * The approval is cleared when the token is transferred.
     *
     * Only a single account can be approved at a time, so approving the zero address clears previous approvals.
     *
     * Requirements:
     *
     * - The caller must own the token or be an approved operator.
     * - `tokenId` must exist.
     *
     * Emits an {Approval} event.
     */
    function approve(address to, uint256 tokenId) external;

    /**
     * @dev Approve or remove `operator` as an operator for the caller.
     * Operators can call {transferFrom} or {safeTransferFrom} for any token owned by the caller.
     *
     * Requirements:
     *
     * - The `operator` cannot be the caller.
     *
     * Emits an {ApprovalForAll} event.
     */
    function setApprovalForAll(address operator, bool _approved) external;

    /**
     * @dev Returns the account approved for `tokenId` token.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     */
    function getApproved(uint256 tokenId) external view returns (address operator);

    /**
     * @dev Returns if the `operator` is allowed to manage all of the assets of `owner`.
     *
     * See {setApprovalForAll}
     */
    function isApprovedForAll(address owner, address operator) external view returns (bool);
}
pragma solidity >=0.8.0;

/// @notice Modern and gas efficient ERC20 + EIP-2612 implementation.
/// @author Solmate (https://github.com/transmissions11/solmate/blob/main/src/tokens/ERC20.sol)
/// @author Modified from Uniswap (https://github.com/Uniswap/uniswap-v2-core/blob/master/contracts/UniswapV2ERC20.sol)
/// @dev Do not manually set balances without updating totalSupply, as the sum of all user balances must not exceed it.
abstract contract ERC20 {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Transfer(address indexed from, address indexed to, uint256 amount);

    event Approval(address indexed owner, address indexed spender, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                            METADATA STORAGE
    //////////////////////////////////////////////////////////////*/

    string public name;

    string public symbol;

    uint8 public immutable decimals;

    /*//////////////////////////////////////////////////////////////
                              ERC20 STORAGE
    //////////////////////////////////////////////////////////////*/

    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;

    mapping(address => mapping(address => uint256)) public allowance;

    /*//////////////////////////////////////////////////////////////
                            EIP-2612 STORAGE
    //////////////////////////////////////////////////////////////*/

    uint256 internal immutable INITIAL_CHAIN_ID;

    bytes32 internal immutable INITIAL_DOMAIN_SEPARATOR;

    mapping(address => uint256) public nonces;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals
    ) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;

        INITIAL_CHAIN_ID = block.chainid;
        INITIAL_DOMAIN_SEPARATOR = computeDomainSeparator();
    }

    /*//////////////////////////////////////////////////////////////
                               ERC20 LOGIC
    //////////////////////////////////////////////////////////////*/

    function approve(address spender, uint256 amount) public virtual returns (bool) {
        allowance[msg.sender][spender] = amount;

        emit Approval(msg.sender, spender, amount);

        return true;
    }

    function transfer(address to, uint256 amount) public virtual returns (bool) {
        balanceOf[msg.sender] -= amount;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(msg.sender, to, amount);

        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual returns (bool) {
        uint256 allowed = allowance[from][msg.sender]; // Saves gas for limited approvals.

        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;

        balanceOf[from] -= amount;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(from, to, amount);

        return true;
    }

    /*//////////////////////////////////////////////////////////////
                             EIP-2612 LOGIC
    //////////////////////////////////////////////////////////////*/

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public virtual {
        require(deadline >= block.timestamp, "PERMIT_DEADLINE_EXPIRED");

        // Unchecked because the only math done is incrementing
        // the owner's nonce which cannot realistically overflow.
        unchecked {
            address recoveredAddress = ecrecover(
                keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        DOMAIN_SEPARATOR(),
                        keccak256(
                            abi.encode(
                                keccak256(
                                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                                ),
                                owner,
                                spender,
                                value,
                                nonces[owner]++,
                                deadline
                            )
                        )
                    )
                ),
                v,
                r,
                s
            );

            require(recoveredAddress != address(0) && recoveredAddress == owner, "INVALID_SIGNER");

            allowance[recoveredAddress][spender] = value;
        }

        emit Approval(owner, spender, value);
    }

    function DOMAIN_SEPARATOR() public view virtual returns (bytes32) {
        return block.chainid == INITIAL_CHAIN_ID ? INITIAL_DOMAIN_SEPARATOR : computeDomainSeparator();
    }

    function computeDomainSeparator() internal view virtual returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    keccak256(bytes(name)),
                    keccak256("1"),
                    block.chainid,
                    address(this)
                )
            );
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL MINT/BURN LOGIC
    //////////////////////////////////////////////////////////////*/

    function _mint(address to, uint256 amount) internal virtual {
        totalSupply += amount;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            balanceOf[to] += amount;
        }

        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal virtual {
        balanceOf[from] -= amount;

        // Cannot underflow because a user's balance
        // will never be larger than the total supply.
        unchecked {
            totalSupply -= amount;
        }

        emit Transfer(from, address(0), amount);
    }
}
pragma solidity >=0.8.0;

import {ERC20} from "../tokens/ERC20.sol";

/// @notice Safe ETH and ERC20 transfer library that gracefully handles missing return values.
/// @author Solmate (https://github.com/transmissions11/solmate/blob/main/src/utils/SafeTransferLib.sol)
/// @dev Use with caution! Some functions in this library knowingly create dirty bits at the destination of the free memory pointer.
/// @dev Note that none of the functions in this library check that a token has code at all! That responsibility is delegated to the caller.
library SafeTransferLib {
    /*//////////////////////////////////////////////////////////////
                             ETH OPERATIONS
    //////////////////////////////////////////////////////////////*/

    function safeTransferETH(address to, uint256 amount) internal {
        bool success;

        /// @solidity memory-safe-assembly
        assembly {
            // Transfer the ETH and store if it succeeded or not.
            success := call(gas(), to, amount, 0, 0, 0, 0)
        }

        require(success, "ETH_TRANSFER_FAILED");
    }

    /*//////////////////////////////////////////////////////////////
                            ERC20 OPERATIONS
    //////////////////////////////////////////////////////////////*/

    function safeTransferFrom(
        ERC20 token,
        address from,
        address to,
        uint256 amount
    ) internal {
        bool success;

        /// @solidity memory-safe-assembly
        assembly {
            // Get a pointer to some free memory.
            let freeMemoryPointer := mload(0x40)

            // Write the abi-encoded calldata into memory, beginning with the function selector.
            mstore(freeMemoryPointer, 0x23b872dd00000000000000000000000000000000000000000000000000000000)
            mstore(add(freeMemoryPointer, 4), from) // Append the "from" argument.
            mstore(add(freeMemoryPointer, 36), to) // Append the "to" argument.
            mstore(add(freeMemoryPointer, 68), amount) // Append the "amount" argument.

            success := and(
                // Set success to whether the call reverted, if not we check it either
                // returned exactly 1 (can't just be non-zero data), or had no return data.
                or(and(eq(mload(0), 1), gt(returndatasize(), 31)), iszero(returndatasize())),
                // We use 100 because the length of our calldata totals up like so: 4 + 32 * 3.
                // We use 0 and 32 to copy up to 32 bytes of return data into the scratch space.
                // Counterintuitively, this call must be positioned second to the or() call in the
                // surrounding and() call or else returndatasize() will be zero during the computation.
                call(gas(), token, 0, freeMemoryPointer, 100, 0, 32)
            )
        }

        require(success, "TRANSFER_FROM_FAILED");
    }

    function safeTransfer(
        ERC20 token,
        address to,
        uint256 amount
    ) internal {
        bool success;

        /// @solidity memory-safe-assembly
        assembly {
            // Get a pointer to some free memory.
            let freeMemoryPointer := mload(0x40)

            // Write the abi-encoded calldata into memory, beginning with the function selector.
            mstore(freeMemoryPointer, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
            mstore(add(freeMemoryPointer, 4), to) // Append the "to" argument.
            mstore(add(freeMemoryPointer, 36), amount) // Append the "amount" argument.

            success := and(
                // Set success to whether the call reverted, if not we check it either
                // returned exactly 1 (can't just be non-zero data), or had no return data.
                or(and(eq(mload(0), 1), gt(returndatasize(), 31)), iszero(returndatasize())),
                // We use 68 because the length of our calldata totals up like so: 4 + 32 * 2.
                // We use 0 and 32 to copy up to 32 bytes of return data into the scratch space.
                // Counterintuitively, this call must be positioned second to the or() call in the
                // surrounding and() call or else returndatasize() will be zero during the computation.
                call(gas(), token, 0, freeMemoryPointer, 68, 0, 32)
            )
        }

        require(success, "TRANSFER_FAILED");
    }

    function safeApprove(
        ERC20 token,
        address to,
        uint256 amount
    ) internal {
        bool success;

        /// @solidity memory-safe-assembly
        assembly {
            // Get a pointer to some free memory.
            let freeMemoryPointer := mload(0x40)

            // Write the abi-encoded calldata into memory, beginning with the function selector.
            mstore(freeMemoryPointer, 0x095ea7b300000000000000000000000000000000000000000000000000000000)
            mstore(add(freeMemoryPointer, 4), to) // Append the "to" argument.
            mstore(add(freeMemoryPointer, 36), amount) // Append the "amount" argument.

            success := and(
                // Set success to whether the call reverted, if not we check it either
                // returned exactly 1 (can't just be non-zero data), or had no return data.
                or(and(eq(mload(0), 1), gt(returndatasize(), 31)), iszero(returndatasize())),
                // We use 68 because the length of our calldata totals up like so: 4 + 32 * 2.
                // We use 0 and 32 to copy up to 32 bytes of return data into the scratch space.
                // Counterintuitively, this call must be positioned second to the or() call in the
                // surrounding and() call or else returndatasize() will be zero during the computation.
                call(gas(), token, 0, freeMemoryPointer, 68, 0, 32)
            )
        }

        require(success, "APPROVE_FAILED");
    }
}
pragma solidity ^0.8.0;

/**
 * @dev This is the interface that {BeaconProxy} expects of its beacon.
 */
interface IBeaconUpgradeable {
    /**
     * @dev Must return an address that can be used as a delegate call target.
     *
     * {BeaconProxy} will check that this address is a contract.
     */
    function implementation() external view returns (address);
}
pragma solidity ^0.8.0;

/**
 * @dev ERC-1967: Proxy Storage Slots. This interface contains the events defined in the ERC.
 *
 * _Available since v4.9._
 */
interface IERC1967Upgradeable {
    /**
     * @dev Emitted when the implementation is upgraded.
     */
    event Upgraded(address indexed implementation);

    /**
     * @dev Emitted when the admin account has changed.
     */
    event AdminChanged(address previousAdmin, address newAdmin);

    /**
     * @dev Emitted when the beacon is changed.
     */
    event BeaconUpgraded(address indexed beacon);
}
pragma solidity ^0.8.1;

/**
 * @dev Collection of functions related to the address type
 */
library AddressUpgradeable {
    /**
     * @dev Returns true if `account` is a contract.
     *
     * [IMPORTANT]
     * ====
     * It is unsafe to assume that an address for which this function returns
     * false is an externally-owned account (EOA) and not a contract.
     *
     * Among others, `isContract` will return false for the following
     * types of addresses:
     *
     *  - an externally-owned account
     *  - a contract in construction
     *  - an address where a contract will be created
     *  - an address where a contract lived, but was destroyed
     * ====
     *
     * [IMPORTANT]
     * ====
     * You shouldn't rely on `isContract` to protect against flash loan attacks!
     *
     * Preventing calls from contracts is highly discouraged. It breaks composability, breaks support for smart wallets
     * like Gnosis Safe, and does not provide security since it can be circumvented by calling from a contract
     * constructor.
     * ====
     */
    function isContract(address account) internal view returns (bool) {
        // This method relies on extcodesize/address.code.length, which returns 0
        // for contracts in construction, since the code is only stored at the end
        // of the constructor execution.

        return account.code.length > 0;
    }

    /**
     * @dev Replacement for Solidity's `transfer`: sends `amount` wei to
     * `recipient`, forwarding all available gas and reverting on errors.
     *
     * https://eips.ethereum.org/EIPS/eip-1884[EIP1884] increases the gas cost
     * of certain opcodes, possibly making contracts go over the 2300 gas limit
     * imposed by `transfer`, making them unable to receive funds via
     * `transfer`. {sendValue} removes this limitation.
     *
     * https://diligence.consensys.net/posts/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.5.11/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
     */
    function sendValue(address payable recipient, uint256 amount) internal {
        require(address(this).balance >= amount, "Address: insufficient balance");

        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Address: unable to send value, recipient may have reverted");
    }

    /**
     * @dev Performs a Solidity function call using a low level `call`. A
     * plain `call` is an unsafe replacement for a function call: use this
     * function instead.
     *
     * If `target` reverts with a revert reason, it is bubbled up by this
     * function (like regular Solidity function calls).
     *
     * Returns the raw returned data. To convert to the expected return value,
     * use https://solidity.readthedocs.io/en/latest/units-and-global-variables.html?highlight=abi.decode#abi-encoding-and-decoding-functions[`abi.decode`].
     *
     * Requirements:
     *
     * - `target` must be a contract.
     * - calling `target` with `data` must not revert.
     *
     * _Available since v3.1._
     */
    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0, "Address: low-level call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`], but with
     * `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but also transferring `value` wei to `target`.
     *
     * Requirements:
     *
     * - the calling contract must have an ETH balance of at least `value`.
     * - the called Solidity function must be `payable`.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value
    ) internal returns (bytes memory) {
        return functionCallWithValue(target, data, value, "Address: low-level call with value failed");
    }

    /**
     * @dev Same as {xref-Address-functionCallWithValue-address-bytes-uint256-}[`functionCallWithValue`], but
     * with `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value,
        string memory errorMessage
    ) internal returns (bytes memory) {
        require(address(this).balance >= value, "Address: insufficient balance for call");
        (bool success, bytes memory returndata) = target.call{value: value}(data);
        return verifyCallResultFromTarget(target, success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(address target, bytes memory data) internal view returns (bytes memory) {
        return functionStaticCall(target, data, "Address: low-level static call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal view returns (bytes memory) {
        (bool success, bytes memory returndata) = target.staticcall(data);
        return verifyCallResultFromTarget(target, success, returndata, errorMessage);
    }

    /**
     * @dev Tool to verify that a low level call to smart-contract was successful, and revert (either by bubbling
     * the revert reason or using the provided one) in case of unsuccessful call or if target was not a contract.
     *
     * _Available since v4.8._
     */
    function verifyCallResultFromTarget(
        address target,
        bool success,
        bytes memory returndata,
        string memory errorMessage
    ) internal view returns (bytes memory) {
        if (success) {
            if (returndata.length == 0) {
                // only check isContract if the call was successful and the return data is empty
                // otherwise we already know that it was a contract
                require(isContract(target), "Address: call to non-contract");
            }
            return returndata;
        } else {
            _revert(returndata, errorMessage);
        }
    }

    /**
     * @dev Tool to verify that a low level call was successful, and revert if it wasn't, either by bubbling the
     * revert reason or using the provided one.
     *
     * _Available since v4.3._
     */
    function verifyCallResult(
        bool success,
        bytes memory returndata,
        string memory errorMessage
    ) internal pure returns (bytes memory) {
        if (success) {
            return returndata;
        } else {
            _revert(returndata, errorMessage);
        }
    }

    function _revert(bytes memory returndata, string memory errorMessage) private pure {
        // Look for revert reason and bubble it up if present
        if (returndata.length > 0) {
            // The easiest way to bubble the revert reason is using memory via assembly
            /// @solidity memory-safe-assembly
            assembly {
                let returndata_size := mload(returndata)
                revert(add(32, returndata), returndata_size)
            }
        } else {
            revert(errorMessage);
        }
    }
}
pragma solidity ^0.8.0;

/**
 * @dev Library for reading and writing primitive types to specific storage slots.
 *
 * Storage slots are often used to avoid storage conflict when dealing with upgradeable contracts.
 * This library helps with reading and writing to such slots without the need for inline assembly.
 *
 * The functions in this library return Slot structs that contain a `value` member that can be used to read or write.
 *
 * Example usage to set ERC1967 implementation slot:
 * ```
 * contract ERC1967 {
 *     bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
 *
 *     function _getImplementation() internal view returns (address) {
 *         return StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value;
 *     }
 *
 *     function _setImplementation(address newImplementation) internal {
 *         require(Address.isContract(newImplementation), "ERC1967: new implementation is not a contract");
 *         StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value = newImplementation;
 *     }
 * }
 * ```
 *
 * _Available since v4.1 for `address`, `bool`, `bytes32`, and `uint256`._
 */
library StorageSlotUpgradeable {
    struct AddressSlot {
        address value;
    }

    struct BooleanSlot {
        bool value;
    }

    struct Bytes32Slot {
        bytes32 value;
    }

    struct Uint256Slot {
        uint256 value;
    }

    /**
     * @dev Returns an `AddressSlot` with member `value` located at `slot`.
     */
    function getAddressSlot(bytes32 slot) internal pure returns (AddressSlot storage r) {
        /// @solidity memory-safe-assembly
        assembly {
            r.slot := slot
        }
    }

    /**
     * @dev Returns an `BooleanSlot` with member `value` located at `slot`.
     */
    function getBooleanSlot(bytes32 slot) internal pure returns (BooleanSlot storage r) {
        /// @solidity memory-safe-assembly
        assembly {
            r.slot := slot
        }
    }

    /**
     * @dev Returns an `Bytes32Slot` with member `value` located at `slot`.
     */
    function getBytes32Slot(bytes32 slot) internal pure returns (Bytes32Slot storage r) {
        /// @solidity memory-safe-assembly
        assembly {
            r.slot := slot
        }
    }

    /**
     * @dev Returns an `Uint256Slot` with member `value` located at `slot`.
     */
    function getUint256Slot(bytes32 slot) internal pure returns (Uint256Slot storage r) {
        /// @solidity memory-safe-assembly
        assembly {
            r.slot := slot
        }
    }
}
pragma solidity ^0.8.0;
import "../proxy/utils/Initializable.sol";

/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract ContextUpgradeable is Initializable {
    function __Context_init() internal onlyInitializing {
    }

    function __Context_init_unchained() internal onlyInitializing {
    }
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[50] private __gap;
}
pragma solidity ^0.8.0;

/**
 * @dev Interface of the ERC165 standard, as defined in the
 * https://eips.ethereum.org/EIPS/eip-165[EIP].
 *
 * Implementers can declare support of contract interfaces, which can then be
 * queried by others ({ERC165Checker}).
 *
 * For an implementation, see {ERC165}.
 */
interface IERC165 {
    /**
     * @dev Returns true if this contract implements the interface defined by
     * `interfaceId`. See the corresponding
     * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[EIP section]
     * to learn more about how these ids are created.
     *
     * This function call must use less than 30 000 gas.
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
