pragma solidity =0.8.23;

import "./SimpleERC20.sol";

import "../../InterfaceHub/IPendle.sol";
import "../../InterfaceHub/IPendleController.sol";

import "../../TransferHub/TransferHelper.sol";

error MarketExpired();
error NotController();
error ZeroFee();
error TooMuchFee();
error NotEnoughLpAssetsTransferred();
error InsufficientShares();
error ZeroAmount();
error FeeTooHigh();
error NotEnoughShares();

contract PendlePowerFarmToken is SimpleERC20, TransferHelper {

    // Pendle - LP token address
    address public immutable UNDERLYING_PENDLE_MARKET;
    address public immutable PENDLE_POWER_FARM_CONTROLLER;

    // Total balance of LPs backing at current compound distribution
    uint256 public underlyingLpAssetsCurrent;

    // Lp assets from compound left to distribute
    uint256 public totalLpAssetsToDistribute;

    // Interface Object for underlying Market
    IPendleMarket public immutable PENDLE_MARKET;

    // Interface for Pendle Controller
    IPendleController public immutable PENDLE_CONTROLLER;

    // Max cardinality of Pendle Market
    uint16 public immutable MAX_CARDINALITY;

    uint256 public mintFee;
    uint256 public lastInteraction;

    uint256 private constant ONE_WEEK = 1 weeks;
    uint256 private constant MAX_MINT_FEE = 10000;

    uint256 private constant PRECISION_FACTOR_E6 = 1E6;
    uint256 private constant PRECISION_FACTOR_E18 = 1E18;

    constructor(
        address _pendleController,
        address _underlyingPendleMarket,
        string memory _tokenName,
        string memory _symbolName,
        uint16 _maxCardinality
    )
        SimpleERC20(
            _tokenName,
            _symbolName
        )
    {
        PENDLE_MARKET = IPendleMarket(
            _underlyingPendleMarket
        );

        if (PENDLE_MARKET.isExpired() == true) {
            revert MarketExpired();
        }

        PENDLE_CONTROLLER = IPendleController(
            _pendleController
        );

        MAX_CARDINALITY = _maxCardinality;

        _name = _tokenName;
        _symbol = _symbolName;

        PENDLE_POWER_FARM_CONTROLLER = _pendleController;
        UNDERLYING_PENDLE_MARKET = _underlyingPendleMarket;

        _decimals = PENDLE_MARKET.decimals();

        lastInteraction = block.timestamp;

        _totalSupply = 1;
        underlyingLpAssetsCurrent = 1;
        mintFee = 3000;
    }

    modifier onlyController() {
        _onlyController();
        _;
    }

    function _onlyController()
        private
        view
    {
        if (msg.sender != PENDLE_POWER_FARM_CONTROLLER) {
            revert NotController();
        }
    }

    modifier syncSupply()
    {
        _triggerIndexUpdate();
        _overWriteCheck();
        _syncSupply();
        _updateRewards();
        _setLastInteraction();
        _increaseCardinalityNext();
        _;
    }

    function _overWriteCheck()
        internal
    {
        _wrapOverWrites(
            _updateRewardTokens()
        );
    }

    function _triggerIndexUpdate()
        internal
    {
        _withdrawLp(
            UNDERLYING_PENDLE_MARKET,
            0
        );
    }

    function _wrapOverWrites(
        bool _overWritten
    )
        internal
    {
        if (_overWritten == true) {
            _overWriteIndexAll();
            _overWriteAmounts();
        }
    }

    function _updateRewardTokens()
        private
        returns (bool)
    {
        return PENDLE_CONTROLLER.updateRewardTokens(
            UNDERLYING_PENDLE_MARKET
        );
    }

    function _overWriteIndexAll()
        private
    {
        PENDLE_CONTROLLER.overWriteIndexAll(
            UNDERLYING_PENDLE_MARKET
        );
    }

    function _overWriteIndex(
        uint256 _index
    )
        private
    {
        PENDLE_CONTROLLER.overWriteIndex(
            UNDERLYING_PENDLE_MARKET,
            _index
        );
    }

    function _overWriteAmounts()
        private
    {
        PENDLE_CONTROLLER.overWriteAmounts(
            UNDERLYING_PENDLE_MARKET
        );
    }

    function _updateRewards()
        private
    {
        uint256[] memory rewardsOutsideArray = _calculateRewardsClaimedOutside();

        uint256 i;
        uint256 l = rewardsOutsideArray.length;

        while (i < l) {
            if (rewardsOutsideArray[i] > 0) {
                PENDLE_CONTROLLER.increaseReservedForCompound(
                    UNDERLYING_PENDLE_MARKET,
                    rewardsOutsideArray
                );
                break;
            }
            unchecked {
                ++i;
            }
        }
    }

    function _calculateRewardsClaimedOutside()
        internal
        returns (uint256[] memory)
    {
        address[] memory rewardTokens = PENDLE_CONTROLLER.pendleChildCompoundInfoRewardTokens(
            UNDERLYING_PENDLE_MARKET
        );

        uint128[] memory lastIndex = PENDLE_CONTROLLER.pendleChildCompoundInfoLastIndex(
            UNDERLYING_PENDLE_MARKET
        );

        uint256 l = rewardTokens.length;
        uint256[] memory rewardsOutsideArray = new uint256[](l);

        uint256 i;
        uint128 index;

        while (i < l) {
            UserReward memory userReward = _getUserReward(
                rewardTokens[i],
                PENDLE_POWER_FARM_CONTROLLER
            );

            if (userReward.accrued > 0) {
                PENDLE_MARKET.redeemRewards(
                    PENDLE_POWER_FARM_CONTROLLER
                );

                userReward = _getUserReward(
                    rewardTokens[i],
                    PENDLE_POWER_FARM_CONTROLLER
                );
            }

            index = userReward.index;

            if (lastIndex[i] == 0 && index > 0) {
                rewardsOutsideArray[i] = 0;
                _overWriteIndex(
                    i
                );
                unchecked {
                    ++i;
                }
                continue;
            }

            if (index == lastIndex[i]) {
                rewardsOutsideArray[i] = 0;
                unchecked {
                    ++i;
                }
                continue;
            }

            uint256 indexDiff = index
                - lastIndex[i];

            uint256 activeBalance = _getActiveBalance();
            uint256 totalLpAssetsCurrent = totalLpAssets();
            uint256 lpBalanceController = _getBalanceLpBalanceController();

            bool scaleNecessary = totalLpAssetsCurrent < lpBalanceController;

            rewardsOutsideArray[i] = scaleNecessary
                ? indexDiff
                    * activeBalance
                    * totalLpAssetsCurrent
                    / lpBalanceController
                    / PRECISION_FACTOR_E18
                : indexDiff
                    * activeBalance
                    / PRECISION_FACTOR_E18;

            _overWriteIndex(
                i
            );

            unchecked {
                ++i;
            }
        }

        return rewardsOutsideArray;
    }

    function _getBalanceLpBalanceController()
        private
        view
        returns (uint256)
    {
        return PENDLE_MARKET.balanceOf(
            PENDLE_POWER_FARM_CONTROLLER
        );
    }

    function _getActiveBalance()
        private
        view
        returns (uint256)
    {
        return PENDLE_MARKET.activeBalance(
            PENDLE_POWER_FARM_CONTROLLER
        );
    }

    function _syncSupply()
        private
    {
        uint256 additonalAssets = previewDistribution();

        if (additonalAssets == 0) {
            return;
        }

        underlyingLpAssetsCurrent += additonalAssets;
        totalLpAssetsToDistribute -= additonalAssets;
    }

    function _increaseCardinalityNext()
        internal
    {
        MarketStorage memory storageMarket = PENDLE_MARKET._storage();

        if (storageMarket.observationCardinalityNext < MAX_CARDINALITY) {
            PENDLE_MARKET.increaseObservationsCardinalityNext(
                storageMarket.observationCardinalityNext + 1
            );
        }
    }

    function _withdrawLp(
        address _to,
        uint256 _amount
    )
        internal
    {
        PENDLE_CONTROLLER.withdrawLp(
            UNDERLYING_PENDLE_MARKET,
            _to,
            _amount
        );
    }

    function _getUserReward(
        address _rewardToken,
        address _user
    )
        internal
        view
        returns (UserReward memory)
    {
        return PENDLE_MARKET.userReward(
            _rewardToken,
            _user
        );
    }

    function previewDistribution()
        public
        view
        returns (uint256)
    {
        if (totalLpAssetsToDistribute == 0) {
            return 0;
        }

        if (block.timestamp == lastInteraction) {
            return 0;
        }

        if (totalLpAssetsToDistribute < ONE_WEEK) {
            return totalLpAssetsToDistribute;
        }

        uint256 currentRate = totalLpAssetsToDistribute
            / ONE_WEEK;

        uint256 additonalAssets = currentRate
            * (block.timestamp - lastInteraction);

        if (additonalAssets > totalLpAssetsToDistribute) {
            return totalLpAssetsToDistribute;
        }

        return additonalAssets;
    }

    function _setLastInteraction()
        private
    {
        lastInteraction = block.timestamp;
    }

    function _applyMintFee(
        uint256 _amount
    )
        internal
        view
        returns (uint256)
    {
        return _amount
            * (PRECISION_FACTOR_E6 - mintFee)
            / PRECISION_FACTOR_E6;
    }

    function totalLpAssets()
        public
        view
        returns (uint256)
    {
        return underlyingLpAssetsCurrent
            + totalLpAssetsToDistribute;
    }

    function previewUnderlyingLpAssets()
        external
        view
        returns (uint256)
    {
        return previewDistribution()
            + underlyingLpAssetsCurrent;
    }

    function previewMintShares(
        uint256 _underlyingAssetAmount,
        uint256 _underlyingLpAssetsCurrent
    )
        public
        view
        returns (uint256)
    {
        return _underlyingAssetAmount
            * totalSupply()
            / _underlyingLpAssetsCurrent;
    }

    function previewAmountWithdrawShares(
        uint256 _shares,
        uint256 _underlyingLpAssetsCurrent
    )
        public
        view
        returns (uint256)
    {
        return _shares
            * _underlyingLpAssetsCurrent
            / totalSupply();
    }

    function previewBurnShares(
        uint256 _underlyingAssetAmount,
        uint256 _underlyingLpAssetsCurrent
    )
        public
        view
        returns (uint256)
    {
        uint256 product = _underlyingAssetAmount
            * totalSupply();

        return product % _underlyingLpAssetsCurrent == 0
            ? product / _underlyingLpAssetsCurrent
            : product / _underlyingLpAssetsCurrent + 1;
    }

    function manualSync()
        external
        syncSupply
        returns (bool)
    {
        return true;
    }

    function addCompoundRewards(
        uint256 _amount
    )
        external
        syncSupply
    {
        if (_amount == 0) {
            revert ZeroAmount();
        }

        totalLpAssetsToDistribute += _amount;

        if (msg.sender == PENDLE_POWER_FARM_CONTROLLER) {
            return;
        }

        _safeTransferFrom(
            UNDERLYING_PENDLE_MARKET,
            msg.sender,
            PENDLE_POWER_FARM_CONTROLLER,
            _amount
        );
    }

    /**
     * @dev External wrapper for mint function.
     */
    function depositExactAmount(
        uint256 _underlyingLpAssetAmount
    )
        external
        syncSupply
        returns (
            uint256,
            uint256
        )
    {
        if (_underlyingLpAssetAmount == 0) {
            revert ZeroAmount();
        }

        uint256 shares = previewMintShares(
            _underlyingLpAssetAmount,
            underlyingLpAssetsCurrent
        );

        if (shares == 0) {
            revert NotEnoughLpAssetsTransferred();
        }

        uint256 reducedShares = _applyMintFee(
            shares
        );

        uint256 feeShares = shares
            - reducedShares;

        if (feeShares == 0) {
            revert ZeroFee();
        }

        if (reducedShares == feeShares) {
            revert TooMuchFee();
        }

        _mint(
            msg.sender,
            reducedShares
        );

        _mint(
            PENDLE_POWER_FARM_CONTROLLER,
            feeShares
        );

        underlyingLpAssetsCurrent += _underlyingLpAssetAmount;

        _safeTransferFrom(
            UNDERLYING_PENDLE_MARKET,
            msg.sender,
            PENDLE_POWER_FARM_CONTROLLER,
            _underlyingLpAssetAmount
        );

        return (
            reducedShares,
            feeShares
        );
    }

    function changeMintFee(
        uint256 _newFee
    )
        external
        onlyController
    {
        if (_newFee > MAX_MINT_FEE) {
            revert FeeTooHigh();
        }

        mintFee = _newFee;
    }

    /**
     * @dev External wrapper for burn function.
     */
    function withdrawExactShares(
        uint256 _shares
    )
        external
        syncSupply
        returns (uint256)
    {
        if (_shares == 0) {
            revert ZeroAmount();
        }

        if (_shares > balanceOf(msg.sender)) {
            revert InsufficientShares();
        }

        uint256 tokenAmount = previewAmountWithdrawShares(
            _shares,
            underlyingLpAssetsCurrent
        );

        underlyingLpAssetsCurrent -= tokenAmount;

        _burn(
            msg.sender,
            _shares
        );

        if (msg.sender == PENDLE_POWER_FARM_CONTROLLER) {
            return tokenAmount;
        }

        _withdrawLp(
            msg.sender,
            tokenAmount
        );

        return tokenAmount;
    }

    function withdrawExactAmount(
        uint256 _underlyingLpAssetAmount
    )
        external
        syncSupply
        returns (uint256)
    {
        if (_underlyingLpAssetAmount == 0) {
            revert ZeroAmount();
        }

        uint256 shares = previewBurnShares(
            _underlyingLpAssetAmount,
            underlyingLpAssetsCurrent
        );

        if (shares > balanceOf(msg.sender)) {
            revert NotEnoughShares();
        }

        _burn(
            msg.sender,
            shares
        );

        underlyingLpAssetsCurrent -= _underlyingLpAssetAmount;

        _withdrawLp(
            msg.sender,
            _underlyingLpAssetAmount
        );

        return shares;
    }
}
pragma solidity =0.8.23;

interface IERC20 {

    function totalSupply()
        external
        view
        returns (uint256);

    function balanceOf(
        address _account
    )
        external
        view
        returns (uint256);

    function transferFrom(
        address _sender,
        address _recipient,
        uint256 _amount
    )
        external
        returns (bool);

    function transfer(
        address _recipient,
        uint256 _amount
    )
        external
        returns (bool);

    function allowance(
        address owner,
        address spender
    )
        external
        view
        returns (uint256);

    function approve(
        address _spender,
        uint256 _amount
    )
        external
        returns (bool);

    function decimals()
        external
        view
        returns (uint8);

    event Transfer(
        address indexed from,
        address indexed to,
        uint256 value
    );

    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );

    event  Deposit(
        address indexed dst,
        uint wad
    );

    event  Withdrawal(
        address indexed src,
        uint wad
    );
}
pragma solidity =0.8.23;

struct MarketStorage {
    int128 totalPt;
    int128 totalSy;
    uint96 lastLnImpliedRate;
    uint16 observationIndex;
    uint16 observationCardinality;
    uint16 observationCardinalityNext;
}

struct MarketState {
    int256 totalPt;
    int256 totalSy;
    int256 totalLp;
    address treasury;
    int256 scalarRoot;
    uint256 expiry;
    uint256 lnFeeRateRoot;
    uint256 reserveFeePercent;
    uint256 lastLnImpliedRate;
}

struct LockedPosition {
    uint128 amount;
    uint128 expiry;
}

struct UserReward {
    uint128 index;
    uint128 accrued;
}

struct ApproxParams {
    uint256 guessMin;
    uint256 guessMax;
    uint256 guessOffchain;
    uint256 maxIteration;
    uint256 eps;
}

interface IPendleSy {

    function previewDeposit(
        address _tokenIn,
        uint256 _amountTokenToDeposit
    )
        external
        view
        returns (uint256 sharesAmount);

    function deposit(
        address _receiver,
        address _tokenIn,
        uint256 _amountTokenToDeposit,
        uint256 _minSharesOut
    )
        external
        returns (uint256 sharesAmount);

    function exchangeRate()
        external
        view
        returns (uint256);

    function redeem(
        address _receiver,
        uint256 _amountSharesToRedeem,
        address _tokenOut,
        uint256 _minTokenOut,
        bool _burnFromInternalBalance
    )
        external
        returns (uint256 amountTokenOut);
}

interface IPendleYt {

    function mintPY(
        address _receiverPT,
        address _receiverYT
    )
        external
        returns (uint256 pyAmount);

    function redeemPY(
        address _receiver
    )
        external
        returns (uint256);

    function redeemDueInterestAndRewards(
        address _user,
        bool _redeemInterest,
        bool _redeemRewards
    )
        external
        returns (
            uint256 interestOut,
            uint256[] memory rewardsOut
        );

    function getRewardTokens()
        external
        view
        returns (address[] memory);

    function userReward(
        address _token,
        address _user
    )
        external
        view
        returns (UserReward memory);

    function userInterest(
        address user
    )
        external
        view
        returns (
            uint128 lastPYIndex,
            uint128 accruedInterest
        );

    function pyIndexStored()
        external
        view
        returns (uint256);
}

interface IPendleMarket {

    function readTokens()
        external
        view
        returns (
            address SY,
            address PT,
            address YT
        );

    function activeBalance(
        address _user
    )
        external
        view
        returns (uint256);

    function transferFrom(
        address _from,
        address _to,
        uint256 _amount
    )
        external;

    function balanceOf(
        address _user
    )
        external
        view
        returns (uint256);

    function isExpired()
        external
        view
        returns (bool);

    function decimals()
        external
        view
        returns (uint8);

    function increaseObservationsCardinalityNext(
        uint16 _newObservationCardinalityNext
    )
        external;

    function swapExactPtForSy(
        address receiver,
        uint256 exactPtIn,
        bytes calldata data
    )
        external
        returns (
            uint256 netSyOut,
            uint256 netSyFee
        );

    function _storage()
        external
        view
        returns (MarketStorage memory);

    function getRewardTokens()
        external
        view
        returns (address[] memory);

    function readState(
        address _router
    )
        external
        view
        returns (MarketState memory marketState);

    function mint(
        address _receiver,
        uint256 _netSyDesired,
        uint256 _netPtDesired
    )
        external
        returns (uint256[3] memory);

    function burn(
        address _receiverAddressSy,
        address _receiverAddressPt,
        uint256 _lpToBurn
    )
        external
        returns (
            uint256 syOut,
            uint256 ptOut
        );

    function redeemRewards(
        address _user
    )
        external
        returns (uint256[] memory);

    function totalSupply()
        external
        view
        returns (uint256);

    function userReward(
        address _token,
        address _user
    )
        external
        view
        returns (UserReward memory);
}

interface IPendleChildToken {

    function totalLpAssets()
        external
        view
        returns (uint256);

    function totalSupply()
        external
        view
        returns (uint256);

    function previewUnderlyingLpAssets()
        external
        view
        returns (uint256);

    function previewMintShares(
        uint256 _underlyingAssetAmount,
        uint256 _underlyingLpAssetsCurrent
    )
        external
        view
        returns (uint256);

    function previewAmountWithdrawShares(
        uint256 _shares,
        uint256 _underlyingLpAssetsCurrent
    )
        external
        view
        returns (uint256);

    function previewBurnShares(
        uint256 _underlyingAssetAmount,
        uint256 _underlyingLpAssetsCurrent
    )
        external
        view
        returns (uint256);
}

interface IPendleLock {

    function increaseLockPosition(
        uint128 _additionalAmountToLock,
        uint128 _newExpiry
    )
        external
        returns (uint128 newVeBalance);

    function withdraw()
        external
        returns (uint128);

    function positionData(
        address _user
    )
        external
        view
        returns (LockedPosition memory);

    function getBroadcastPositionFee(
        uint256[] calldata _chainIds
    )
        external
        view
        returns (uint256);
}

interface IPendleVoteRewards {
    function claimRetail(
        address _user,
        uint256 _amount,
        bytes32[] calldata _merkleProof
    )
        external
        returns (uint256);
}

interface IPendleVoter {
    function vote(
        address[] memory _pools,
        uint64[] memory _weights
    )
        external;
}

interface IPendleChild {
    function depositExactAmount(
        uint256 _amount
    )
        external
        returns (
            uint256,
            uint256
        );

    function withdrawExactShares(
        uint256 _shares
    )
        external
        returns (uint256);
}

interface IPendleRouter {

    function swapSyForExactYt(
        address _receiver,
        address _market,
        uint256 _exactYtOut,
        uint256 _maxSyIn
    )
        external
        returns (
            uint256 netSyIn,
            uint256 netSyFee
        );

    function swapExactSyForYt(
        address _receiver,
        address _market,
        uint256 _exactSyIn,
        uint256 _minYtOut
    )
        external
        returns (
            uint256 netYtOut,
            uint256 netSyFee
        );

    function swapSyForExactPt(
        address _receiver,
        address _market,
        uint256 _exactPtOut,
        uint256 _maxSyIn
    )
        external
        returns (
            uint256 netSyIn,
            uint256 netSyFee
        );

    function swapExactSyForPt(
        address _receiver,
        address _market,
        uint256 _exactSyIn,
        uint256 _minPtOut
    )
        external
        returns (
            uint256 netPtOut,
            uint256 netSyFee
        );

    function removeLiquiditySingleSy(
        address _receiver,
        address _market,
        uint256 _netLpToRemove,
        uint256 _minSyOut
    )
        external
        returns (
            uint256 netSyOut,
            uint256 netSyFee
        );

    function addLiquiditySingleSy(
        address _receiver,
        address _market,
        uint256 _netSyIn,
        uint256 _minLpOut,
        ApproxParams calldata _guessPtReceivedFromSy
    )
        external
        returns (
            uint256 netLpOut,
            uint256 netSyFee
        );
}

interface IPendleRouterStatic {

    function addLiquiditySingleSyStatic(
        address _market,
        uint256 _netSyIn
    )
        external
        view
        returns (
            uint256 netLpOut,
            uint256 netPtFromSwap,
            uint256 netSyFee,
            uint256 priceImpact,
            uint256 exchangeRateAfter,
            uint256 netSyToSwap
        );

    function swapExactPtForSyStatic(
        address _market,
        uint256 _exactPtIn
    )
        external
        view
        returns (
            uint256 netSyOut,
            uint256 netSyFee,
            uint256 priceImpact,
            uint256 exchangeRateAfter
        );
}
pragma solidity =0.8.23;

interface IPendleController {

    struct compoundStruct {
        uint256[] reservedForCompound;
        uint128[] lastIndex;
        address[] rewardTokens;
    }

    function withdrawLp(
        address _pendleMarket,
        address _to,
        uint256 _amount
    )
        external;

    function increaseReservedForCompound(
        address _pendleMarket,
        uint256[] memory _amounts
    )
        external;

    function pendleChildCompoundInfoReservedForCompound(
        address _pendleMarket
    )
        external
        view
        returns (uint256[] memory);

    function pendleChildCompoundInfoLastIndex(
        address _pendleMarket
    )
        external
        view
        returns (uint128[] memory);

    function pendleChildCompoundInfoRewardTokens(
        address _pendleMarket
    )
        external
        view
        returns (address[] memory);

    function updateRewardTokens(
        address _pendleMarket
    )
        external
        returns (bool);

    function overWriteIndexAll(
        address _pendleMarket
    )
        external;

    function overWriteIndex(
        address _pendleMarket,
        uint256 _index
    )
        external;

    function overWriteAmounts(
        address _pendleMarket
    )
        external;
}
pragma solidity =0.8.23;

error AllowanceBelowZero();
error ApproveWithZeroAddress();
error BurnExceedsBalance();
error BurnFromZeroAddress();
error InsufficientAllowance();
error MintToZeroAddress();
error TransferAmountExceedsBalance();
error TransferZeroAddress();

contract SimpleERC20 {

    string internal _name;
    string internal _symbol;

    uint8 internal _decimals;
    uint256 internal _totalSupply;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // Miscellaneous constants
    uint256 internal constant UINT256_MAX = type(uint256).max;
    address internal constant ZERO_ADDRESS = address(0);

    event Transfer(
        address indexed from,
        address indexed to,
        uint256 value
    );


    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );

    constructor(
        string memory _tokenName,
        string memory _tokenSymbol
    )
    {
        _name = _tokenName;
        _symbol = _tokenSymbol;

        _totalSupply = 1;
    }

    function name()
        external
        view
        returns (string memory)
    {
        return _name;
    }

    function symbol()
        external
        view
        returns (string memory)
    {
        return _symbol;
    }

    function decimals()
        external
        view
        returns (uint8)
    {
        return _decimals;
    }

    function totalSupply()
        public
        view
        returns (uint256)
    {
        return _totalSupply;
    }

    function balanceOf(
        address _account
    )
        public
        view
        returns (uint256)
    {
        return _balances[_account];
    }

    function _transfer(
        address _from,
        address _to,
        uint256 _amount
    )
        internal
    {
        if (_from == ZERO_ADDRESS || _to == ZERO_ADDRESS) {
            revert TransferZeroAddress();
        }

        uint256 fromBalance = _balances[_from];

        if (fromBalance < _amount) {
            revert TransferAmountExceedsBalance();
        }

        unchecked {
            _balances[_from] = fromBalance - _amount;
            _balances[_to] += _amount;
        }

        emit Transfer(
            _from,
            _to,
            _amount
        );
    }

    function _mint(
        address _account,
        uint256 _amount
    )
        internal
    {
        if (_account == ZERO_ADDRESS) {
            revert MintToZeroAddress();
        }

        _totalSupply += _amount;

        unchecked {
            _balances[_account] += _amount;
        }

        emit Transfer(
            ZERO_ADDRESS,
            _account,
            _amount
        );
    }

    function _burn(
        address _account,
        uint256 _amount
    )
        internal
    {
        if (_account == ZERO_ADDRESS) {
            revert BurnFromZeroAddress();
        }

        uint256 accountBalance = _balances[
            _account
        ];

        if (accountBalance < _amount) {
            revert BurnExceedsBalance();
        }

        unchecked {
            _balances[_account] = accountBalance - _amount;
            _totalSupply -= _amount;
        }

        emit Transfer(
            _account,
            ZERO_ADDRESS,
            _amount
        );
    }

    function transfer(
        address _to,
        uint256 _amount
    )
        external
        returns (bool)
    {
        _transfer(
            _msgSender(),
            _to,
            _amount
        );

        return true;
    }

    function allowance(
        address _owner,
        address _spender
    )
        public
        view
        returns (uint256)
    {
        return _allowances[_owner][_spender];
    }

    function approve(
        address _spender,
        uint256 _amount
    )
        external
        returns (bool)
    {
        _approve(
            _msgSender(),
            _spender,
            _amount
        );

        return true;
    }

    function transferFrom(
        address _from,
        address _to,
        uint256 _amount
    )
        external
        returns (bool)
    {
        _spendAllowance(
            _from,
            _msgSender(),
            _amount
        );

        _transfer(
            _from,
            _to,
            _amount
        );

        return true;
    }

    function increaseAllowance(
        address _spender,
        uint256 _addedValue
    )
        external
        returns (bool)
    {
        address owner = _msgSender();

        _approve(
            owner,
            _spender,
            allowance(owner, _spender) + _addedValue
        );

        return true;
    }

    function decreaseAllowance(
        address _spender,
        uint256 _subtractedValue
    )
        external
        returns (bool)
    {
        address owner = _msgSender();

        uint256 currentAllowance = allowance(
            owner,
            _spender
        );

        if (currentAllowance < _subtractedValue) {
            revert AllowanceBelowZero();
        }

        unchecked {
            _approve(
                owner,
                _spender,
                currentAllowance - _subtractedValue
            );
        }

        return true;
    }

    function _approve(
        address _owner,
        address _spender,
        uint256 _amount
    )
        internal
    {
        if (_owner == ZERO_ADDRESS || _spender == ZERO_ADDRESS) {
            revert ApproveWithZeroAddress();
        }

        _allowances[_owner][_spender] = _amount;

        emit Approval(
            _owner,
            _spender,
            _amount
        );
    }

    function _spendAllowance(
        address _owner,
        address _spender,
        uint256 _amount
    )
        internal
    {
        uint256 currentAllowance = allowance(
            _owner,
            _spender
        );

        if (currentAllowance != UINT256_MAX) {

            if (currentAllowance < _amount) {
                revert InsufficientAllowance();
            }

            unchecked {
                _approve(
                    _owner,
                    _spender,
                    currentAllowance - _amount
                );
            }
        }
    }

    function _msgSender()
        internal
        view
        returns (address)
    {
        return msg.sender;
    }
}
pragma solidity =0.8.23;

import "../InterfaceHub/IERC20.sol";

contract CallOptionalReturn {

    /**
     * @dev Helper function to do low-level call
     */
    function _callOptionalReturn(
        address token,
        bytes memory data
    )
        internal
        returns (bool call)
    {
        (
            bool success,
            bytes memory returndata
        ) = token.call(
            data
        );

        bool results = returndata.length == 0 || abi.decode(
            returndata,
            (bool)
        );

        if (success == false) {
            revert();
        }

        call = success
            && results
            && token.code.length > 0;
    }
}
pragma solidity =0.8.23;

import "./CallOptionalReturn.sol";

contract TransferHelper is CallOptionalReturn {

    /**
     * @dev
     * Allows to execute safe transfer for a token
     */
    function _safeTransfer(
        address _token,
        address _to,
        uint256 _value
    )
        internal
    {
        _callOptionalReturn(
            _token,
            abi.encodeWithSelector(
                IERC20.transfer.selector,
                _to,
                _value
            )
        );
    }

    /**
     * @dev
     * Allows to execute safe transferFrom for a token
     */
    function _safeTransferFrom(
        address _token,
        address _from,
        address _to,
        uint256 _value
    )
        internal
    {
        _callOptionalReturn(
            _token,
            abi.encodeWithSelector(
                IERC20.transferFrom.selector,
                _from,
                _to,
                _value
            )
        );
    }
}
