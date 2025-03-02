pragma solidity ^0.8.8;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./ITokenStake.sol";
import "./ITokenStakeSetting.sol";
import "../token_stake_apy/ITokenStakeApy.sol";
import "../market/IMarketplace.sol";
import "../oracle/Oracle.sol";
import "../stake/IStaking.sol";
import "../ranking/IRanking.sol";

contract TokenStake is ITokenStake, ITokenStakeSetting, Ownable, ERC721Holder {
    uint16 public maxFloor = 8;
    uint256 private unlocked = 1;
    uint256 public timeOpenStaking = 1689786000;
    uint256 public tokenDecimal = 1000000000000000000;
    uint256 public rankCommissionDuration = 62208000; // 24 month
    uint256 public poolDurationHasLimit = 12; // 12 month

    address public novaxToken;
    address public tokenStakeApy;
    address public marketplaceContract;
    address public rankingContract;

    mapping(address => address) public oracleContracts;

    // mapping to store amount staked to get reward
    mapping(uint16 => uint256) public amountConditions;

    // mapping to store commission percent when ref claim staking token
    mapping(uint16 => uint256) public commissionPercents;

    mapping(uint256 => uint256) public directCommissionPercents; // Ex: 500 = 5%

    uint256 public stakeTokenPoolLength = 6;
    uint256 public stakeIndex = 0;

    mapping(uint256 => StakeTokenPools) private stakeTokenPools;
    mapping(uint256 => StakedToken) private stakedToken;
    mapping(address => mapping(uint256 => uint256)) private totalUserStakedPoolToken;
    mapping(address => mapping(uint256 => uint256)) private totalUserStakedPoolUsd;

    mapping(address => uint256) private directCommission;
    mapping(address => uint256) private refClaimed;

    mapping(uint256 => uint256) public canNotWithdraw; // Stake id -> is Can not withdraw

    constructor(address _novaxToken, address _tokenStakeApy, address _marketplaceContract, address _oracleContract) {
        novaxToken = _novaxToken;
        tokenStakeApy = _tokenStakeApy;
        marketplaceContract = _marketplaceContract;
        oracleContracts[_novaxToken] = _oracleContract;
        initStakePool();
        initCommissionConditionUsd();
        initCommissionPercents();
        initDirectCommissionPercents();
    }

    modifier isTimeForStaking() {
        require(block.timestamp >= timeOpenStaking, "TS:T");
        _;
    }

    modifier lock() {
        require(unlocked == 1, "TS:L");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    function initStakePool() internal {
        stakeTokenPools[0].poolId = 0;
        stakeTokenPools[0].maxStakePerWallet = 0;
        stakeTokenPools[0].duration = 0;
        stakeTokenPools[0].isPayProfit = false;
        stakeTokenPools[0].stakeToken = novaxToken;
        stakeTokenPools[0].earnToken = novaxToken;

        stakeTokenPools[1].poolId = 1;
        stakeTokenPools[1].maxStakePerWallet = 1000000000000000000000;
        stakeTokenPools[1].duration = 1;
        stakeTokenPools[1].isPayProfit = true;
        stakeTokenPools[1].stakeToken = novaxToken;
        stakeTokenPools[1].earnToken = novaxToken;

        stakeTokenPools[2].poolId = 2;
        stakeTokenPools[2].maxStakePerWallet = 3000000000000000000000;
        stakeTokenPools[2].duration = 3;
        stakeTokenPools[2].isPayProfit = true;
        stakeTokenPools[2].stakeToken = novaxToken;
        stakeTokenPools[2].earnToken = novaxToken;

        stakeTokenPools[3].poolId = 3;
        stakeTokenPools[3].maxStakePerWallet = 0;
        stakeTokenPools[3].duration = 6;
        stakeTokenPools[3].isPayProfit = true;
        stakeTokenPools[3].stakeToken = novaxToken;
        stakeTokenPools[3].earnToken = novaxToken;

        stakeTokenPools[4].poolId = 4;
        stakeTokenPools[4].maxStakePerWallet = 0;
        stakeTokenPools[4].duration = 12;
        stakeTokenPools[4].isPayProfit = true;
        stakeTokenPools[4].stakeToken = novaxToken;
        stakeTokenPools[4].earnToken = novaxToken;

        stakeTokenPools[5].poolId = 5;
        stakeTokenPools[5].maxStakePerWallet = 0;
        stakeTokenPools[5].duration = 24;
        stakeTokenPools[5].isPayProfit = true;
        stakeTokenPools[5].stakeToken = novaxToken;
        stakeTokenPools[5].earnToken = novaxToken;
    }

    function initCommissionConditionUsd() internal {
        amountConditions[0] = 0;
        amountConditions[1] = 500;
        amountConditions[2] = 1000;
        amountConditions[3] = 1500;
        amountConditions[4] = 2000;
        amountConditions[5] = 3000;
        amountConditions[6] = 4000;
        amountConditions[7] = 5000;
    }

    function initCommissionPercents() internal {
        commissionPercents[0] = 1500;
        commissionPercents[1] = 1000;
        commissionPercents[2] = 800;
        commissionPercents[3] = 500;
        commissionPercents[4] = 400;
        commissionPercents[5] = 300;
        commissionPercents[6] = 300;
        commissionPercents[7] = 200;
    }

    function initDirectCommissionPercents() internal {
        directCommissionPercents[4] = 600;
        directCommissionPercents[5] = 600;
    }

    function getTotalUserStakedToken(address _user) external view override returns (uint256) {
        uint256 value = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory item = stakedToken[i];
            if (item.userAddress == _user) {
                value += item.totalValueStake;
            }
        }
        return value;
    }

    function getTotalUserStakedUsd(address _user) external view override returns (uint256) {
        uint256 value = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory item = stakedToken[i];
            if (item.userAddress == _user) {
                value += item.totalValueStakeUsd;
            }
        }
        return value;
    }

    function getTotalUserStakedAvailableToken(address _user) public view override returns (uint256) {
        uint256 value = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory item = stakedToken[i];
            if (item.userAddress == _user && !item.isWithdraw) {
                value += item.totalValueStake;
            }
        }
        return value;
    }

    function getTotalUserStakedAvailableUsd(address _user) public view override returns (uint256) {
        uint256 value = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory item = stakedToken[i];
            if (item.userAddress == _user && !item.isWithdraw) {
                value += item.totalValueStakeUsd;
            }
        }
        return value;
    }

    function getTotalUserClaimedToken(address _user) external view override returns (uint256) {
        uint256 value = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory item = stakedToken[i];
            if (item.userAddress == _user) {
                value += item.totalValueClaimed;
            }
        }
        return value;
    }

    function getTotalUserClaimedUsd(address _user) external view override returns (uint256) {
        uint256 value = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory item = stakedToken[i];
            if (item.userAddress == _user) {
                value += item.totalValueClaimedUsd;
            }
        }
        return value;
    }

    function getTotalUserWithdrawToken(address _user) external view override returns (uint256) {
        uint256 value = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory item = stakedToken[i];
            if (item.userAddress == _user && item.isWithdraw) {
                value += item.totalValueStake;
            }
        }
        return value;
    }

    function getTotalUserWithdrawUsd(address _user) external view override returns (uint256) {
        uint256 value = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory item = stakedToken[i];
            if (item.userAddress == _user && item.isWithdraw) {
                value += item.totalValueStakeUsd;
            }
        }
        return value;
    }

    function getUserStakedPoolToken(address _user, uint256 _poolId) external view override returns (uint256) {
        uint256 value = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory item = stakedToken[i];
            if (item.userAddress == _user && item.poolId == _poolId && !item.isWithdraw) {
                value += item.totalValueStake;
            }
        }
        return value;
    }

    function getUserStakedPoolUsd(address _user, uint256 _poolId) external view override returns (uint256) {
        uint256 value = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory item = stakedToken[i];
            if (item.userAddress == _user && item.poolId == _poolId && !item.isWithdraw) {
                value += item.totalValueStakeUsd;
            }
        }
        return value;
    }

    function getPoolTotalStakeToken(uint256 _poolId) external view override returns (uint256) {
        uint256 value = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory item = stakedToken[i];
            if (item.poolId == _poolId && !item.isWithdraw) {
                value += item.totalValueStake;
            }
        }
        return value;
    }

    function getPoolTotalStakeUsd(uint256 _poolId) external view override returns (uint256) {
        uint256 value = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory item = stakedToken[i];
            if (item.poolId == _poolId && !item.isWithdraw) {
                value += item.totalValueStakeUsd;
            }
        }
        return value;
    }

    function getPoolTotalClaimToken(uint256 _poolId) external view override returns (uint256) {
        uint256 value = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory item = stakedToken[i];
            if (item.poolId == _poolId) {
                value += item.totalValueClaimed;
            }
        }
        return value;
    }

    function getPoolTotalClaimUsd(uint256 _poolId) external view override returns (uint256) {
        uint256 value = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory item = stakedToken[i];
            if (item.poolId == _poolId) {
                value += item.totalValueClaimedUsd;
            }
        }
        return value;
    }

    function getCommissionPercent(uint16 _level) public view override returns (uint256) {
        return commissionPercents[_level];
    }

    function getDirectCommission(address _user) external view override returns (uint256) {
        return directCommission[_user];
    }

    function getCommissionCondition(uint16 _level) external view override returns (uint256) {
        return amountConditions[_level];
    }

    function totalStakedToken() external view override returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory stakeItem = stakedToken[i];
            total += stakeItem.totalValueStake;
        }

        return total;
    }

    function totalStakedUsd() external view override returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory stakeItem = stakedToken[i];
            total += stakeItem.totalValueStakeUsd;
        }

        return total;
    }

    function totalWithdrawToken() external view override returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory stakeItem = stakedToken[i];
            if (stakeItem.isWithdraw) {
                total += stakeItem.totalValueStake;
            }
        }

        return total;
    }

    function totalWithdrawUsd() external view override returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory stakeItem = stakedToken[i];
            if (stakeItem.isWithdraw) {
                total += stakeItem.totalValueStakeUsd;
            }
        }

        return total;
    }

    function totalClaimedToken() external view override returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory stakeItem = stakedToken[i];
            total += stakeItem.totalValueClaimed;
        }

        return total;
    }

    function totalClaimedUsd() external view override returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 1; i <= stakeIndex; i++) {
            StakedToken memory stakeItem = stakedToken[i];
            total += stakeItem.totalValueClaimedUsd;
        }

        return total;
    }

    function getTeamStakingValue(address _wallet) external view override returns (uint256) {
        return getChildrenStakingValueInUsd(_wallet, 1, maxFloor);
    }

    function getChildrenStakingValueInUsd(address _wallet, uint256 _deep, uint256 _maxDeep) internal view returns (uint256) {
        if (_deep > _maxDeep) {
            return 0;
        }

        uint256 nftValue = 0;
        address[] memory childrenUser = IMarketplace(marketplaceContract).getF1ListForAccount(_wallet);

        if (childrenUser.length <= 0) {
            return 0;
        }

        for (uint256 i = 0; i < childrenUser.length; i++) {
            address f1 = childrenUser[i];
            nftValue += getTotalUserStakedAvailableToken(f1);
            nftValue += getChildrenStakingValueInUsd(f1, _deep + 1, _maxDeep);
        }

        return nftValue;
    }

    function getStakeTokenPool(uint256 _poolId) external view override returns (StakeTokenPools memory) {
        StakeTokenPools memory _stakeTokenPool = stakeTokenPools[_poolId];

        return _stakeTokenPool;
    }

    function getStakedToken(uint256 _stakeId) public view override returns (StakedToken memory) {
        return stakedToken[_stakeId];
    }

    function stake(uint256 _poolId, uint256 _stakeValue) external override lock {
        address stakeToken = stakeTokenPools[_poolId].stakeToken;
        require(IERC20(stakeToken).balanceOf(msg.sender) >= _stakeValue, "TS:E");
        require(IERC20(stakeToken).allowance(msg.sender, address(this)) >= _stakeValue, "TS:A");
        require(IERC20(stakeToken).transferFrom(msg.sender, address(this), _stakeValue), "TS:T");

        uint256 totalUserStakePool = totalUserStakedPoolToken[msg.sender][_poolId] + _stakeValue;
        require(stakeTokenPools[_poolId].maxStakePerWallet == 0 || stakeTokenPools[_poolId].maxStakePerWallet >= totalUserStakePool, "TS:U");

        // insert data staking
        stakeIndex = stakeIndex + 1;
        uint256 stakeValueUsd = tokenToUsd(stakeToken, _stakeValue);

        // if pool duration = 0 => no limit for stake time, can claim every time
        uint256 unlockTimeEstimate = stakeTokenPools[_poolId].duration == 0 ? 0 : (block.timestamp + (2592000 * stakeTokenPools[_poolId].duration));
        stakedToken[stakeIndex].stakeId = stakeIndex;
        stakedToken[stakeIndex].userAddress = msg.sender;
        stakedToken[stakeIndex].poolId = _poolId;
        stakedToken[stakeIndex].startTime = block.timestamp;
        stakedToken[stakeIndex].lastClaimTime = block.timestamp;
        stakedToken[stakeIndex].unlockTime = unlockTimeEstimate;
        stakedToken[stakeIndex].totalValueStake = _stakeValue;
        stakedToken[stakeIndex].totalValueStakeUsd = stakeValueUsd;
        stakedToken[stakeIndex].isWithdraw = false;

        // update fixed data
        totalUserStakedPoolToken[msg.sender][_poolId] += _stakeValue;
        totalUserStakedPoolUsd[msg.sender][_poolId] += stakeValueUsd;

        payDirectCommission(msg.sender, _poolId, _stakeValue);
        if (stakeTokenPools[_poolId].duration >= poolDurationHasLimit) {
            IMarketplace(marketplaceContract).updateStakeTokenValue(msg.sender, stakeValueUsd, true);
        }
        emit Staked(stakeIndex, _poolId, msg.sender, _stakeValue, block.timestamp, unlockTimeEstimate);
    }

    function claimAll(uint256[] memory _stakeIds) external override lock {
        require(_stakeIds.length > 0, "TS:I");
        for (uint i = 0; i < _stakeIds.length; i++) {
            claimInternal(_stakeIds[i]);
        }
    }

    function claimPool(uint256[] memory _stakeIds) external override lock {
        require(_stakeIds.length > 0, "TS:I");
        for (uint i = 0; i < _stakeIds.length; i++) {
            claimInternal(_stakeIds[i]);
        }
    }

    function claim(uint256 _stakeId) external override lock {
        claimInternal(_stakeId);
    }

    function tokenToUsd(address token, uint256 _tokenAmount) public view returns (uint256) {
        address oracleContract = oracleContracts[token];
        return (1000000 * _tokenAmount) / IOracle(oracleContract).convertUsdBalanceDecimalToTokenDecimal(1000000);
    }

    function usdToToken(address token, uint256 _usdAmount) public view returns (uint256) {
        address oracleContract = oracleContracts[token];
        return IOracle(oracleContract).convertUsdBalanceDecimalToTokenDecimal(_usdAmount);
    }

    function payDirectCommission(address _user, uint256 _poolId, uint256 _tokenAmount) internal {
        uint256 _directCommissionPercent = directCommissionPercents[_poolId];
        if (_directCommissionPercent == 0) {
            return;
        }

        address ref = IMarketplace(marketplaceContract).getReferralAccountForAccountExternal(_user);
        address systemWallet = IMarketplace(marketplaceContract).systemWallet();
        if (ref == address(0) || ref == systemWallet) {
            return;
        }

        address stakeToken = stakeTokenPools[_poolId].stakeToken;
        uint256 commissionTokenAmount = (_tokenAmount * _directCommissionPercent) / 10000;
        uint256 commissionUsdAmount = tokenToUsd(stakeToken, commissionTokenAmount);
        commissionUsdAmount = IMarketplace(marketplaceContract).getCommissionCanEarn(ref, commissionUsdAmount);
        if (commissionUsdAmount == 0) {
            return;
        }

        commissionTokenAmount = usdToToken(stakeToken, commissionUsdAmount);
        require(IERC20(stakeToken).balanceOf(address(this)) >= commissionTokenAmount, "TS:E");
        require(IERC20(stakeToken).transfer(ref, commissionTokenAmount), "TS:U");
        directCommission[ref] += commissionUsdAmount;
        IMarketplace(marketplaceContract).updateTotalEarnAndCommission(ref, commissionUsdAmount);
    }

    function claimInternal(uint256 _stakeId) internal {
        StakedToken memory _stakedUserToken = stakedToken[_stakeId];
        require(_stakedUserToken.userAddress == msg.sender, "TS:O");
        uint256 totalUsdClaimDecimal = calculateUsdEarnedStake(_stakeId);
        if (totalUsdClaimDecimal == 0) {
            return;
        }

        address earnToken = stakeTokenPools[_stakedUserToken.poolId].earnToken;
        uint256 totalUsdClaimDecimalCanEarn = IMarketplace(marketplaceContract).getCommissionCanEarn(msg.sender, totalUsdClaimDecimal);
        require(totalUsdClaimDecimal == totalUsdClaimDecimalCanEarn, "TS:CE");
        uint256 totalTokenClaimDecimal = usdToToken(earnToken, totalUsdClaimDecimal);

        require(IERC20(earnToken).balanceOf(address(this)) >= totalTokenClaimDecimal, "TS:E");
        require(IERC20(earnToken).transfer(msg.sender, totalTokenClaimDecimal), "TS:U");
        IMarketplace(marketplaceContract).updateTotalEarnAndCommission(msg.sender, totalUsdClaimDecimal);

        // pay commission multi levels
        if (stakeTokenPools[_stakedUserToken.poolId].isPayProfit) {
            payCommissionMultiLevels(msg.sender, totalTokenClaimDecimal, earnToken);
        }

        stakedToken[_stakeId].totalValueClaimed += totalTokenClaimDecimal;
        stakedToken[_stakeId].totalValueClaimedUsd += totalUsdClaimDecimal;
        stakedToken[_stakeId].lastClaimTime = block.timestamp;

        if (stakeTokenPools[_stakedUserToken.poolId].duration >= 12 && (block.timestamp <= (rankCommissionDuration + _stakedUserToken.startTime))) {
            IRanking(rankingContract).payRankingCommission(msg.sender, totalUsdClaimDecimal);
        }

        emit Claimed(_stakeId, msg.sender, totalTokenClaimDecimal);
    }

    function payCommissionMultiLevels(address _user, uint256 _totalAmountStakeTokenWithDecimal, address earnToken) internal {
        address _marketplaceContract = marketplaceContract;
        address currentRef = IMarketplace(_marketplaceContract).getReferralAccountForAccountExternal(_user);
        address systemWallet = IMarketplace(_marketplaceContract).systemWallet();
        uint16 index = 0;
        uint16 _maxFloor = maxFloor;

        while (currentRef != address(0) && currentRef != systemWallet && index < _maxFloor) {
            bool canReward = possibleForCommission(currentRef, index);
            if (canReward) {
                // Transfer commission in token amount
                uint256 commissionTokenAmount = (_totalAmountStakeTokenWithDecimal * commissionPercents[index]) / 10000;
                uint256 commissionUsdAmount = tokenToUsd(earnToken, commissionTokenAmount);
                commissionUsdAmount = IMarketplace(_marketplaceContract).getCommissionCanEarn(currentRef, commissionUsdAmount);
                if (commissionUsdAmount > 0) {
                    commissionTokenAmount = usdToToken(earnToken, commissionUsdAmount);
                    require(commissionTokenAmount > 0, "TS:IC");
                    require(IERC20(earnToken).balanceOf(address(this)) >= commissionTokenAmount, "TS:E");
                    require(IERC20(earnToken).transfer(currentRef, commissionTokenAmount), "ST:U");
                    refClaimed[currentRef] = refClaimed[currentRef] + commissionTokenAmount;
                    IMarketplace(_marketplaceContract).updateCommissionStakeValueData(currentRef, commissionUsdAmount);
                }
            }
            currentRef = IMarketplace(_marketplaceContract).getReferralAccountForAccountExternal(currentRef);
            index++;
        }
    }

    function possibleForCommission(address _staker, uint16 _level) public view returns (bool) {
        uint256 saleValue = IMarketplace(marketplaceContract).getSaleValue(_staker);
        saleValue = saleValue / tokenDecimal;
        uint256 conditionAmount = amountConditions[_level];
        if (saleValue >= conditionAmount) {
            return true;
        }

        return false;
    }

    function calculateUsdEarnedStake(uint256 _stakeId) public view override returns (uint256) {
        StakedToken memory _stakedUserToken = stakedToken[_stakeId];
        if (_stakedUserToken.isWithdraw) {
            return 0;
        }
        uint256 totalTokenClaimDecimal = 0;
        uint256 index = ITokenStakeApy(tokenStakeApy).getMaxIndex(_stakedUserToken.poolId);
        uint256 apy = 0;
        for (uint256 i = 0; i < index; i++) {
            uint256 startTime = ITokenStakeApy(tokenStakeApy).getStartTime(_stakedUserToken.poolId)[i];
            uint256 endTime = ITokenStakeApy(tokenStakeApy).getEndTime(_stakedUserToken.poolId)[i];
            apy = ITokenStakeApy(tokenStakeApy).getPoolApy(_stakedUserToken.poolId)[i];
            // calculate token claim for each stake pool
            startTime = startTime >= _stakedUserToken.startTime ? startTime : _stakedUserToken.startTime;
            // _stakedUserToken.unlockTime == 0 mean no limit for this pool
            uint256 timeDuration = _stakedUserToken.unlockTime == 0 ? block.timestamp : (_stakedUserToken.unlockTime < block.timestamp ? _stakedUserToken.unlockTime : block.timestamp);
            endTime = endTime == 0 ? timeDuration : (endTime <= timeDuration ? endTime : timeDuration);

            if (startTime <= endTime) {
                totalTokenClaimDecimal += ((endTime - startTime) * apy * _stakedUserToken.totalValueStakeUsd) / 31104000 / 100000;
            }
        }

        if (totalTokenClaimDecimal > _stakedUserToken.totalValueClaimedUsd) {
            return totalTokenClaimDecimal - _stakedUserToken.totalValueClaimedUsd;
        }

        return 0;
    }

    function calculateTokenEarnedStake(uint256 _stakeId) public view override returns (uint256) {
        uint256 earnUsd = calculateUsdEarnedStake(_stakeId);
        if (earnUsd == 0) {
            return 0;
        }
        address earnToken = stakeTokenPools[stakedToken[_stakeId].poolId].earnToken;
        return usdToToken(earnToken, earnUsd);
    }

    function calculateTokenEarnedMulti(uint256[] memory _stakeIds) public view override returns (uint256) {
        uint256 _totalTokenClaimDecimal = 0;
        for (uint i = 0; i < _stakeIds.length; i++) {
            _totalTokenClaimDecimal += calculateTokenEarnedStake(_stakeIds[i]);
        }

        return _totalTokenClaimDecimal;
    }

    function withdraw(uint256 _stakeId) public override lock {
        StakedToken memory _stakedUserToken = stakedToken[_stakeId];
        require(_stakedUserToken.userAddress == msg.sender, "TS:O");
        require(!_stakedUserToken.isWithdraw, "TS:W");
        require(canNotWithdraw[_stakeId] == 0, "TS:C");
        require(_stakedUserToken.unlockTime <= block.timestamp, "TS:T");

        claimInternal(_stakeId);

        StakeTokenPools memory stakeTokenPool = stakeTokenPools[_stakedUserToken.poolId];
        address stakeToken = stakeTokenPool.stakeToken;
        uint256 withdrawTokenValue = usdToToken(stakeToken, _stakedUserToken.totalValueStakeUsd);
        require(IERC20(stakeToken).balanceOf(address(this)) >= withdrawTokenValue, "TS:E");
        require(IERC20(stakeToken).transfer(_stakedUserToken.userAddress, withdrawTokenValue), "TS:U");

        uint256 _poolId = _stakedUserToken.poolId;
        uint256 _value = _stakedUserToken.totalValueStake;
        uint256 _valueUsd = _stakedUserToken.totalValueStakeUsd;
        if (totalUserStakedPoolToken[msg.sender][_poolId] > _value) {
            totalUserStakedPoolToken[msg.sender][_poolId] = totalUserStakedPoolToken[msg.sender][_poolId] - _value;
        } else {
            totalUserStakedPoolToken[msg.sender][_poolId] = 0;
        }

        if (totalUserStakedPoolUsd[msg.sender][_poolId] > _valueUsd) {
            totalUserStakedPoolUsd[msg.sender][_poolId] = totalUserStakedPoolUsd[msg.sender][_poolId] - _valueUsd;
        } else {
            totalUserStakedPoolUsd[msg.sender][_poolId] = 0;
        }

        stakedToken[_stakeId].isWithdraw = true;

        if (stakeTokenPool.duration >= poolDurationHasLimit) {
            IMarketplace(marketplaceContract).updateStakeTokenValue(msg.sender, _valueUsd, false);
        }

        emit Harvested(_stakeId);
    }

    function withdrawPool(uint256[] memory _stakeIds) external override {
        require(_stakeIds.length > 0, "TS:I");
        for (uint i = 0; i < _stakeIds.length; i++) {
            withdraw(_stakeIds[i]);
        }
    }

    function getRefClaimed(address _wallet) external view override returns (uint256) {
        return refClaimed[_wallet];
    }

    // Setting
    function setMaxFloor(uint16 _maxFloor) external override onlyOwner {
        maxFloor = _maxFloor;
    }

    function setTimeOpenStaking(uint256 _timeOpening) external override onlyOwner {
        timeOpenStaking = _timeOpening;
    }

    function setTokenDecimal(uint256 _tokenDecimal) external override onlyOwner {
        tokenDecimal = _tokenDecimal;
    }

    function setRankCommissionDuration(uint256 _rankCommissionDuration) external override onlyOwner {
        rankCommissionDuration = _rankCommissionDuration;
    }

    function setPoolDurationHasLimit(uint256 _poolDurationHasLimit) external override onlyOwner {
        poolDurationHasLimit = _poolDurationHasLimit;
    }

    function setCommissionCondition(uint16 _level, uint256 _conditionInUsd) external override onlyOwner {
        amountConditions[_level] = _conditionInUsd;
    }

    function setCommissionPercent(uint16 _level, uint256 _percent) external override onlyOwner {
        commissionPercents[_level] = _percent;
    }

    function setDirectCommissionPercents(uint256 _poolId, uint256 _percent) external override onlyOwner {
        directCommissionPercents[_poolId] = _percent;
    }

    function setCanNotWithdraw(uint256 _stakedTokenId, uint256 _canNotWithdraw) external override onlyOwner {
        canNotWithdraw[_stakedTokenId] = _canNotWithdraw;
    }

    // Set contract
    function setNovaxToken(address _novaxToken) external override onlyOwner {
        novaxToken = _novaxToken;
    }

    function setApyContract(address _tokenStakeApy) external override onlyOwner {
        tokenStakeApy = _tokenStakeApy;
    }

    function setMarketContract(address _marketContract) external override onlyOwner {
        marketplaceContract = _marketContract;
    }

    function setRankingContract(address _rankingContract) external override onlyOwner {
        rankingContract = _rankingContract;
    }

    function setOracleContract(address _token, address _oracleContract) external override onlyOwner {
        oracleContracts[_token] = _oracleContract;
    }

    // Migrate
    function setStakeTokenPool(uint256 _poolId, uint256 _maxStakePerWallet, uint256 _duration, bool _isPayProfit, address _stakeToken, address _earnToken) external override onlyOwner {
        stakeTokenPools[_poolId].poolId = _poolId;
        stakeTokenPools[_poolId].maxStakePerWallet = _maxStakePerWallet;
        stakeTokenPools[_poolId].duration = _duration;
        stakeTokenPools[_poolId].isPayProfit = _isPayProfit;
        stakeTokenPools[_poolId].stakeToken = _stakeToken;
        stakeTokenPools[_poolId].earnToken = _earnToken;
        uint256 _index = _poolId + 1;
        if (_index > stakeTokenPoolLength) {
            stakeTokenPoolLength = _index;
        }
    }

    function setStakedToken(
        uint256 _stakeId,
        uint256 _poolId,
        address _userAddress,
        uint256 _startTime,
        uint256 _unlockTime,
        uint256 _totalValueStake,
        uint256 _totalValueStakeUsd,
        uint256 _totalValueClaimed,
        uint256 _totalValueClaimedUsd,
        bool _isWithdraw
    ) external override onlyOwner {
        stakedToken[_stakeId].stakeId = _stakeId;
        stakedToken[_stakeId].poolId = _poolId;
        stakedToken[_stakeId].userAddress = _userAddress;
        stakedToken[_stakeId].startTime = _startTime;
        stakedToken[_stakeId].unlockTime = _unlockTime;
        stakedToken[_stakeId].totalValueStake = _totalValueStake;
        stakedToken[_stakeId].totalValueStakeUsd = _totalValueStakeUsd;
        stakedToken[_stakeId].totalValueClaimed = _totalValueClaimed;
        stakedToken[_stakeId].totalValueClaimedUsd = _totalValueClaimedUsd;
        stakedToken[_stakeId].isWithdraw = _isWithdraw;
    }

    function setIndexData(uint256 _stakeTokenPoolLength, uint256 _stakeIndex) external override onlyOwner {
        stakeTokenPoolLength = _stakeTokenPoolLength;
        stakeIndex = _stakeIndex;
    }

    function setDirectCommission(address[] calldata _wallets, uint256[] calldata _directCommissions) external override onlyOwner {
        require(_wallets.length == _directCommissions.length, "I");
        for (uint32 index = 0; index < _wallets.length; index++) {
            directCommission[_wallets[index]] = _directCommissions[index];
        }
    }

    function setRefClaimed(address[] calldata _wallets, uint256[] calldata _refClaimeds) external override onlyOwner {
        require(_wallets.length == _refClaimeds.length, "I");
        for (uint32 index = 0; index < _wallets.length; index++) {
            refClaimed[_wallets[index]] = _refClaimeds[index];
        }
    }

    function setUserStakedPoolToken(address[] calldata _wallets, uint256[] calldata _poolIds, uint256[] calldata _totalUserStakedPoolTokens) external override onlyOwner {
        require(_wallets.length == _poolIds.length && _wallets.length == _totalUserStakedPoolTokens.length, "I");
        for (uint32 index = 0; index < _wallets.length; index++) {
            totalUserStakedPoolToken[_wallets[index]][_poolIds[index]] = _totalUserStakedPoolTokens[index];
        }
    }

    function setUserStakedPoolUsd(address[] calldata _wallets, uint256[] calldata _poolIds, uint256[] calldata _totalUserStakedPoolUsds) external override onlyOwner {
        require(_wallets.length == _poolIds.length && _wallets.length == _totalUserStakedPoolUsds.length, "I");
        for (uint32 index = 0; index < _wallets.length; index++) {
            totalUserStakedPoolUsd[_wallets[index]][_poolIds[index]] = _totalUserStakedPoolUsds[index];
        }
    }

    // Admin
    function addStakedToken(uint256 _poolId, address _userAddress, uint256 _totalValueStake, bool _payDirect) external override onlyOwner {
        uint256 totalUserStakePool = totalUserStakedPoolToken[_userAddress][_poolId] + _totalValueStake;

        require(stakeTokenPools[_poolId].maxStakePerWallet == 0 || stakeTokenPools[_poolId].maxStakePerWallet >= totalUserStakePool, "TS:M");
        uint256 poolDuration = stakeTokenPools[_poolId].duration;
        uint256 unlockTimeEstimate = poolDuration == 0 ? 0 : (block.timestamp + (2592000 * poolDuration));
        address stakeToken = stakeTokenPools[_poolId].stakeToken;
        uint256 stakeValueUsd = tokenToUsd(stakeToken, _totalValueStake);

        stakeIndex = stakeIndex + 1;
        stakedToken[stakeIndex].stakeId = stakeIndex;
        stakedToken[stakeIndex].poolId = _poolId;
        stakedToken[stakeIndex].userAddress = _userAddress;
        stakedToken[stakeIndex].startTime = block.timestamp;
        stakedToken[stakeIndex].unlockTime = unlockTimeEstimate;
        stakedToken[stakeIndex].totalValueStake = _totalValueStake;
        stakedToken[stakeIndex].totalValueStakeUsd = stakeValueUsd;
        stakedToken[stakeIndex].isWithdraw = false;

        totalUserStakedPoolToken[_userAddress][_poolId] += _totalValueStake;
        totalUserStakedPoolUsd[_userAddress][_poolId] += stakeValueUsd;

        if (_payDirect) {
            payDirectCommission(_userAddress, _poolId, _totalValueStake);
        }

        if (stakeTokenPools[_poolId].duration >= poolDurationHasLimit) {
            IMarketplace(marketplaceContract).updateStakeTokenValue(msg.sender, stakeValueUsd, true);
        }

        emit Staked(stakeIndex, _poolId, _userAddress, _totalValueStake, block.timestamp, unlockTimeEstimate);
    }

    // Withdraw token
    function recoverLostBNB() external override onlyOwner {
        address payable recipient = payable(msg.sender);
        recipient.transfer(address(this).balance);
    }

    function withdrawTokenEmergency(address _token, uint256 _amount) external override onlyOwner {
        require(_amount > 0, "TS:I");
        IERC20(_token).transfer(msg.sender, _amount);
    }
}
pragma solidity ^0.8.0;

import "../utils/Context.sol";

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
abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor() {
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
     * `onlyOwner` functions. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby disabling any functionality that is only available to the owner.
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
}
pragma solidity ^0.8.0;

import "./IERC20.sol";
import "./extensions/IERC20Metadata.sol";
import "../../utils/Context.sol";

/**
 * @dev Implementation of the {IERC20} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
 * For a generic mechanism see {ERC20PresetMinterPauser}.
 *
 * TIP: For a detailed writeup see our guide
 * https://forum.openzeppelin.com/t/how-to-implement-erc20-supply-mechanisms/226[How
 * to implement supply mechanisms].
 *
 * The default value of {decimals} is 18. To change this, you should override
 * this function so it returns a different value.
 *
 * We have followed general OpenZeppelin Contracts guidelines: functions revert
 * instead returning `false` on failure. This behavior is nonetheless
 * conventional and does not conflict with the expectations of ERC20
 * applications.
 *
 * Additionally, an {Approval} event is emitted on calls to {transferFrom}.
 * This allows applications to reconstruct the allowance for all accounts just
 * by listening to said events. Other implementations of the EIP may not emit
 * these events, as it isn't required by the specification.
 *
 * Finally, the non-standard {decreaseAllowance} and {increaseAllowance}
 * functions have been added to mitigate the well-known issues around setting
 * allowances. See {IERC20-approve}.
 */
contract ERC20 is Context, IERC20, IERC20Metadata {
    mapping(address => uint256) private _balances;

    mapping(address => mapping(address => uint256)) private _allowances;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;

    /**
     * @dev Sets the values for {name} and {symbol}.
     *
     * All two of these values are immutable: they can only be set once during
     * construction.
     */
    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    /**
     * @dev Returns the name of the token.
     */
    function name() public view virtual override returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5.05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei. This is the default value returned by this function, unless
     * it's overridden.
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IERC20-balanceOf} and {IERC20-transfer}.
     */
    function decimals() public view virtual override returns (uint8) {
        return 18;
    }

    /**
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IERC20-balanceOf}.
     */
    function balanceOf(address account) public view virtual override returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     */
    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, amount);
        return true;
    }

    /**
     * @dev See {IERC20-allowance}.
     */
    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * NOTE: If `amount` is the maximum `uint256`, the allowance is not updated on
     * `transferFrom`. This is semantically equivalent to an infinite approval.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, amount);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP. See the note at the beginning of {ERC20}.
     *
     * NOTE: Does not update the allowance if the current allowance
     * is the maximum `uint256`.
     *
     * Requirements:
     *
     * - `from` and `to` cannot be the zero address.
     * - `from` must have a balance of at least `amount`.
     * - the caller must have allowance for ``from``'s tokens of at least
     * `amount`.
     */
    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        _transfer(from, to, amount);
        return true;
    }

    /**
     * @dev Atomically increases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, allowance(owner, spender) + addedValue);
        return true;
    }

    /**
     * @dev Atomically decreases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `spender` must have allowance for the caller of at least
     * `subtractedValue`.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        address owner = _msgSender();
        uint256 currentAllowance = allowance(owner, spender);
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        unchecked {
            _approve(owner, spender, currentAllowance - subtractedValue);
        }

        return true;
    }

    /**
     * @dev Moves `amount` of tokens from `from` to `to`.
     *
     * This internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `from` must have a balance of at least `amount`.
     */
    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        _beforeTokenTransfer(from, to, amount);

        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _balances[from] = fromBalance - amount;
            // Overflow not possible: the sum of all balances is capped by totalSupply, and the sum is preserved by
            // decrementing then incrementing.
            _balances[to] += amount;
        }

        emit Transfer(from, to, amount);

        _afterTokenTransfer(from, to, amount);
    }

    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     */
    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");

        _beforeTokenTransfer(address(0), account, amount);

        _totalSupply += amount;
        unchecked {
            // Overflow not possible: balance + amount is at most totalSupply + amount, which is checked above.
            _balances[account] += amount;
        }
        emit Transfer(address(0), account, amount);

        _afterTokenTransfer(address(0), account, amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, reducing the
     * total supply.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     * - `account` must have at least `amount` tokens.
     */
    function _burn(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: burn from the zero address");

        _beforeTokenTransfer(account, address(0), amount);

        uint256 accountBalance = _balances[account];
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");
        unchecked {
            _balances[account] = accountBalance - amount;
            // Overflow not possible: amount <= accountBalance <= totalSupply.
            _totalSupply -= amount;
        }

        emit Transfer(account, address(0), amount);

        _afterTokenTransfer(account, address(0), amount);
    }

    /**
     * @dev Sets `amount` as the allowance of `spender` over the `owner` s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     */
    function _approve(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    /**
     * @dev Updates `owner` s allowance for `spender` based on spent `amount`.
     *
     * Does not update the allowance amount in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Might emit an {Approval} event.
     */
    function _spendAllowance(address owner, address spender, uint256 amount) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "ERC20: insufficient allowance");
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }

    /**
     * @dev Hook that is called before any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * will be transferred to `to`.
     * - when `from` is zero, `amount` tokens will be minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens will be burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual {}

    /**
     * @dev Hook that is called after any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * has been transferred to `to`.
     * - when `from` is zero, `amount` tokens have been minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens have been burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _afterTokenTransfer(address from, address to, uint256 amount) internal virtual {}
}
pragma solidity ^0.8.0;

import "../IERC20.sol";

/**
 * @dev Interface for the optional metadata functions from the ERC20 standard.
 *
 * _Available since v4.1._
 */
interface IERC20Metadata is IERC20 {
    /**
     * @dev Returns the name of the token.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the symbol of the token.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the decimals places of the token.
     */
    function decimals() external view returns (uint8);
}
pragma solidity ^0.8.0;

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IERC20 {
    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves `amount` tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 amount) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `from` to `to` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
pragma solidity ^0.8.0;

/**
 * @title ERC721 token receiver interface
 * @dev Interface for any contract that wants to support safeTransfers
 * from ERC721 asset contracts.
 */
interface IERC721Receiver {
    /**
     * @dev Whenever an {IERC721} `tokenId` token is transferred to this contract via {IERC721-safeTransferFrom}
     * by `operator` from `from`, this function is called.
     *
     * It must return its Solidity selector to confirm the token transfer.
     * If any other value is returned or the interface is not implemented by the recipient, the transfer will be reverted.
     *
     * The selector can be obtained in Solidity with `IERC721Receiver.onERC721Received.selector`.
     */
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
}
pragma solidity ^0.8.0;

import "../IERC721Receiver.sol";

/**
 * @dev Implementation of the {IERC721Receiver} interface.
 *
 * Accepts all token transfers.
 * Make sure the contract is able to use its token with {IERC721-safeTransferFrom}, {IERC721-approve} or {IERC721-setApprovalForAll}.
 */
contract ERC721Holder is IERC721Receiver {
    /**
     * @dev See {IERC721Receiver-onERC721Received}.
     *
     * Always returns `IERC721Receiver.onERC721Received.selector`.
     */
    function onERC721Received(address, address, uint256, bytes memory) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
pragma solidity ^0.8.0;

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
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }

    function _contextSuffixLength() internal view virtual returns (uint256) {
        return 0;
    }
}
pragma solidity ^0.8.8;

library StructData {
    // struct to store staked NFT information
    struct StakedNFT {
        address stakerAddress;
        uint256 lastClaimedTime;
        uint256 unlockTime;
        uint256 totalValueStakeUsdWithDecimal;
        uint256 totalClaimedAmountTokenWithDecimal;
        bool isUnstaked;
    }

    struct ChildListData {
        address[] childList;
        uint256 memberCounter;
    }

    struct ListBuyData {
        StructData.InfoBuyData[] childList;
    }

    struct InfoBuyData {
        uint256 timeBuy;
        uint256 valueUsd;
    }

    struct ListSwapData {
        StructData.InfoSwapData[] childList;
    }

    struct InfoSwapData {
        uint256 timeSwap;
        uint256 valueSwap;
    }

    struct ListMaintenance {
        StructData.InfoMaintenanceNft[] childList;
    }

    struct InfoMaintenanceNft {
        uint256 startTimeRepair;
        uint256 endTimeRepair;
    }
}
pragma solidity ^0.8.8;

interface IMarketplace {
    event Buy(address seller, address buyer, uint256 nftId, address refAddress);
    event Sell(address seller, address buyer, uint256 nftId);
    event PayCommission(address buyer, address refAccount, uint256 commissionAmount);

    function systemWallet() external view returns (address);

    function buyByCurrency(uint256[] memory _nftIds, address _refAddress) external;
    function buyByToken(uint256[] memory _nftIds, address _refAddress) external;
    function buyByTokenAndCurrency(uint256[] memory _nftIds, address _refAddress) external;

    function getActiveMemberForAccount(address _wallet) external view returns (uint256);
    function getTotalCommission(address _wallet) external view returns (uint256);
    function getTotalEarnAndCommission(address _wallet) external view returns (uint256);
    function getReferredNftValueForAccount(address _wallet) external view returns (uint256);
    function getNftCommissionEarnedForAccount(address _wallet) external view returns (uint256);
    function getNftSaleValueForAccountInUsdDecimal(address _wallet) external view returns (uint256);
    function getStakeTokenValueUsdDecimal(address _wallet) external view returns (uint256);
    function getRestakeValueUsdDecimal(address _wallet) external view returns (uint256);
    function getTotalCommissionStakeByAddressInUsd(address _wallet) external view returns (uint256);
    function getMaxCommissionByAddressInUsd(address _wallet) external view returns (uint256);
    function getSaleValue(address _wallet) external view returns (uint256);

    function updateCommissionStakeValueData(address _user, uint256 _valueInUsdWithDecimal) external;
    function updateTotalEarnAndCommission(address _user, uint256 _valueInUsdWithDecimal) external;
    function updateReferralData(address _user, address _refAddress) external;

    function getReferralAccountForAccount(address _user) external view returns (address);
    function getReferralAccountForAccountExternal(address _user) external view returns (address);
    function getF1ListForAccount(address _wallet) external view returns (address[] memory);
    function getTeamNftSaleValueForAccountInUsdDecimal(address _wallet) external view returns (uint256);
    function getCommissionRef(address _refWallet, uint256 _totalValueUsdWithDecimal, uint256 _totalCommission, uint16 _commissionBuy) external view returns (uint256);
    function getCommissionCanEarn(address _wallet, uint256 _earnableWithDecimal) external view returns (uint256);

    function possibleChangeReferralData(address _wallet) external view returns (bool);

    function isBuyByToken(uint256 _nftId) external view returns (bool);

    function updateSaleValue(address _receiver, uint256 totalValueUsdWithDecimal) external;
    function updateStakeTokenValue(address _receiver, uint256 _valueUsdWithDecimal, bool _isAdd) external;
    function updateRestakeValue(address _receiver, uint256 _valueUsdWithDecimal, bool _isAdd) external;
    function updateNetworkMintData(address _refWallet, uint256 _totalValueUsdWithDecimal, uint16 _commissionBuy) external;

    function checkValidRefCodeAdvance(address _user, address _refAddress) external view returns (bool);
    function getCommissionPercent(uint8 _level) external view returns (uint16);
    function getTierUsdPercent(uint16 _tier) external view returns (uint256);
    function getConditionTotalCommission(uint8 _level) external returns (uint256);
}
pragma solidity ^0.8.8;

interface IOracle {
    function convertUsdBalanceDecimalToTokenDecimal(uint256 _balanceUsdDecimal) external view returns (uint256);
}
pragma solidity ^0.8.8;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../swap/InternalSwap.sol";
import "./IOracle.sol";

interface IPancakePair {
    function getReserves() external view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast);
}

contract Oracle is IOracle, Ownable {
    uint256 private minTokenAmount = 0;
    uint256 private maxTokenAmount = 0;

    address public pairAddress;
    address public stableToken;
    address public tokenAddress;
    address public swapAddress;
    uint8 private typeConvert = 1; // 0:average 1: only swap 2: only pancake

    constructor(address _swapAddress, address _stableToken, address _tokenAddress) {
        swapAddress = _swapAddress;
        stableToken = _stableToken;
        tokenAddress = _tokenAddress;
    }

    function convertInternalSwap(uint256 _value, bool toToken) public view returns (uint256) {
        uint256 usdtAmount = InternalSwap(swapAddress).getUsdtAmount();
        uint256 tokenAmount = InternalSwap(swapAddress).getTokenAmount();
        if (tokenAmount > 0 && usdtAmount > 0) {
            uint256 amountTokenDecimal;
            if (toToken) {
                amountTokenDecimal = (_value * tokenAmount) / usdtAmount;
            } else {
                amountTokenDecimal = (_value * usdtAmount) / tokenAmount;
            }

            return amountTokenDecimal;
        }
        return 0;
    }

    function convertUsdBalanceDecimalToTokenDecimal(uint256 _balanceUsdDecimal) public view returns (uint256) {
        uint256 tokenInternalSwap = convertInternalSwap(_balanceUsdDecimal, true);
        uint256 tokenPairConvert;
        if (pairAddress != address(0)) {
            (uint256 _reserve0, uint256 _reserve1, ) = IPancakePair(pairAddress).getReserves();
            (uint256 _tokenBalance, uint256 _stableBalance) = address(tokenAddress) < address(stableToken) ? (_reserve0, _reserve1) : (_reserve1, _reserve0);

            uint256 _minTokenAmount = (_balanceUsdDecimal * minTokenAmount) / 1000000;
            uint256 _maxTokenAmount = (_balanceUsdDecimal * maxTokenAmount) / 1000000;
            uint256 _tokenAmount = (_balanceUsdDecimal * _tokenBalance) / _stableBalance;

            if (_tokenAmount < _minTokenAmount) {
                tokenPairConvert = _minTokenAmount;
            }

            if (_tokenAmount > _maxTokenAmount) {
                tokenPairConvert = _maxTokenAmount;
            }

            tokenPairConvert = _tokenAmount;
        }
        if (typeConvert == 1) {
            return tokenInternalSwap;
        } else if (typeConvert == 2) {
            return tokenPairConvert;
        } else {
            if (tokenPairConvert == 0 || tokenInternalSwap == 0) {
                return tokenPairConvert + tokenInternalSwap;
            } else {
                return (tokenPairConvert + tokenInternalSwap) / 2;
            }
        }
    }

    function setPairAddress(address _address) external onlyOwner {
        require(_address != address(0), "ORACLE: INVALID PAIR ADDRESS");
        pairAddress = _address;
    }

    function setSwapAddress(address _address) external onlyOwner {
        require(_address != address(0), "ORACLE: INVALID SWAP ADDRESS");
        swapAddress = _address;
    }

    function setTypeConvertPrice(uint8 _type) external onlyOwner {
        require(_type <= 2, "ORACLE: INVALID TYPE CONVERT");
        typeConvert = _type;
    }

    function getTypeConvert() external view returns (uint8) {
        return typeConvert;
    }

    function setMinTokenAmount(uint256 _tokenAmount) external onlyOwner {
        minTokenAmount = _tokenAmount;
    }

    function setMaxTokenAmount(uint256 _tokenAmount) external onlyOwner {
        maxTokenAmount = _tokenAmount;
    }

    /**
     * @dev Recover lost bnb and send it to the contract owner
     */
    function recoverLostBNB() public onlyOwner {
        address payable recipient = payable(msg.sender);
        recipient.transfer(address(this).balance);
    }

    /**
     * @dev withdraw some token balance from contract to owner account
     */
    function withdrawTokenEmergency(address _token, uint256 _amount) public onlyOwner {
        require(_amount > 0, "INVALID AMOUNT");
        require(IERC20(_token).transfer(msg.sender, _amount), "CANNOT WITHDRAW TOKEN");
    }
}
pragma solidity ^0.8.8;

interface IRanking {
    event UpdateRank(address indexed user, uint256 rank);
    event EarnCommission(address indexed user, uint256 rank, uint256 usdtValue, uint256 tokenValue);

    function payRankingCommission(address _wallet, uint256 _earnUsd) external;
    function addSaleValue(address _wallet, uint256 _saleUsd) external;
    function subSaleValue(address _wallet, uint256 _saleUsd) external;
}
pragma solidity ^0.8.8;

import "../data/StructData.sol";

interface IStaking {
    event Staked(uint256 id, address indexed staker, uint256 indexed nftID, uint256 unlockTime);
    event Unstaked(uint256 id, address indexed staker, uint256 indexed nftID);
    event Claimed(uint256 id, address indexed staker, uint256 claimAmount);

    function getCommissionCondition(uint8 _level) external view returns (uint32);

    function getCommissionPercent(uint8 _level) external view returns (uint16);

    function getTotalTeamInvestment(address _wallet) external view returns (uint256);

    function getRefStakingValue(address _wallet) external view returns (uint256);

    function getUserStakingNfts(address _wallet) external view returns (uint256[] memory);

    function stake(uint256 _nftId, bytes memory _data) external;

    function getTeamStakingValue(address _wallet) external view returns (uint256);

    function getStakingCommissionEarned(address _wallet) external view returns (uint256);

    function getTimeClaimEarn() external view returns (uint256);

    function unstake(uint256 _stakeId, bytes memory data) external;

    function claim(uint256 _stakeId) external;

    function claimAll(uint256[] memory _stakeIds) external;

    function getDetailOfStake(uint256 _stakeId) external view returns (StructData.StakedNFT memory);

    function possibleUnstake(uint256 _stakeId) external view returns (bool);

    function claimableForStakeInTokenWithDecimal(uint256 _nftId) external view returns (uint256);

    function earnableForStakeWithDecimal(uint256 _nftId) external view returns (uint256);

    function getTotalStakeAmountUSD(address _staker) external view returns (uint256);

    function possibleForCommission(address _staker, uint8 _level) external view returns (bool);

    function getMaxFloorProfit(address _user) external view returns (uint8);

    function getUserCommissionCanEarnUsdWithDecimal(address _user, uint256 _totalCommissionInUsdDecimal) external view returns (uint256);

    function getCommissionProfitUnclaim(address _user) external view returns (uint256);

    function getSaleAddresses() external view returns (address[] memory);

    function checkUserIsSaleAddress(address _user) external view returns (bool);
}
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IMarketplaceSmall {
    function getNftSaleValueForAccountInUsdDecimal(address _wallet) external view returns (uint256);
}

contract InternalSwap is Ownable {
    uint256 public constant SECONDS_PER_DAY = 86400;

    uint256 private usdtAmount = 1000000;
    uint256 private tokenAmount = 223914;
    address public currency;
    address public tokenAddress;
    address public marketContract;
    uint8 private typeSwap = 2; //0: all, 1: usdt -> token only, 2: token -> usdt only
    bool public onlyBuyerCanSwap = true;

    uint256 private limitDay = 1;
    uint256 private limitValue = 150;
    uint256 private _taxSellFee = 500;
    uint256 private _taxBuyFee = 500;
    address private _taxAddress = 0x490aAab021A3354AfcBA4A8DfB8cC3ffC24Beb32;

    mapping(address => bool) private _addressBuyExcludeTaxFee;
    mapping(address => bool) private _addressSellExcludeHasTaxFee;
    mapping(address => bool) public swapWhiteList;

    // wallet -> date buy -> total amount
    mapping(address => mapping(uint256 => uint256)) private _sellAmounts;

    address private contractOwner;
    uint256 private unlocked = 1;

    event ChangeRate(uint256 _usdtAmount, uint256 _tokenAmount, uint256 _time);

    constructor(address _stableToken, address _tokenAddress) {
        currency = _stableToken;
        tokenAddress = _tokenAddress;
        contractOwner = _msgSender();
    }

    modifier checkOwner() {
        require(owner() == _msgSender() || contractOwner == _msgSender(), "SWAP: CALLER IS NOT THE OWNER");
        _;
    }

    modifier canSwap() {
        require(!onlyBuyerCanSwap || swapWhiteList[msg.sender] || isBuyer(msg.sender), "SWAP: CALLER CAN NOT SWAP");
        _;
    }

    modifier lock() {
        require(unlocked == 1, "SWAP: LOCKED");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    function isBuyer(address _wallet) public view returns (bool) {
        require(marketContract != address(0), "SWAP: MARKETPLACE CONTRACT IS ZERO ADDRESS");
        return IMarketplaceSmall(marketContract).getNftSaleValueForAccountInUsdDecimal(_wallet) > 0;
    }

    function getLimitDay() external view returns (uint256) {
        return limitDay;
    }

    function getUsdtAmount() external view returns (uint256) {
        return usdtAmount;
    }

    function getTokenAmount() external view returns (uint256) {
        return tokenAmount;
    }

    function getLimitValue() external view returns (uint256) {
        return limitValue;
    }

    function getTaxSellFee() external view returns (uint256) {
        return _taxSellFee;
    }

    function getTaxBuyFee() external view returns (uint256) {
        return _taxBuyFee;
    }

    function getTaxAddress() external view returns (address) {
        return _taxAddress;
    }

    function getTypeSwap() external view returns (uint8) {
        return typeSwap;
    }

    function setCurrency(address _currency) external checkOwner {
        currency = _currency;
    }

    function setTokenAddress(address _tokenAddress) external checkOwner {
        tokenAddress = _tokenAddress;
    }

    function setMarketContract(address _marketContract) external checkOwner {
        marketContract = _marketContract;
    }

    function setLimitDay(uint256 _limitDay) external checkOwner {
        limitDay = _limitDay;
    }

    function setLimitValue(uint256 _limitValue) external checkOwner {
        limitValue = _limitValue;
    }

    function setOnlyBuyerCanSwap(bool _onlyBuyerCanSwap) external checkOwner {
        onlyBuyerCanSwap = _onlyBuyerCanSwap;
    }

    function setSwapWhiteList(address _walletAddress, bool _isSwapWhiteList) external checkOwner {
        swapWhiteList[_walletAddress] = _isSwapWhiteList;
    }

    function setTaxSellFeePercent(uint256 taxFeeBps) external checkOwner {
        _taxSellFee = taxFeeBps;
    }

    function setTaxBuyFeePercent(uint256 taxFeeBps) external checkOwner {
        _taxBuyFee = taxFeeBps;
    }

    function setTaxAddress(address taxAddress) external checkOwner {
        _taxAddress = taxAddress;
    }

    function setAddressBuyExcludeTaxFee(address account, bool excludeFee) external checkOwner {
        _addressBuyExcludeTaxFee[account] = excludeFee;
    }

    function setAddressSellExcludeTaxFee(address account, bool excludeFee) external checkOwner {
        _addressSellExcludeHasTaxFee[account] = excludeFee;
    }

    function setPriceData(uint256 _usdtAmount, uint256 _tokenAmount) external checkOwner {
        require(_usdtAmount > 0 && _tokenAmount > 0, "SWAP: INVALID DATA");
        usdtAmount = _usdtAmount;
        tokenAmount = _tokenAmount;
        emit ChangeRate(_usdtAmount, _tokenAmount, block.timestamp);
    }

    function setPriceType(uint8 _type) external checkOwner {
        require(_type <= 2, "SWAP: INVALID TYPE SWAP (0, 1, 2)");
        typeSwap = _type;
    }

    function checkCanSellToken(address _wallet, uint256 _tokenValue) internal view returns (bool) {
        if (limitValue == 0 || limitDay == 0) {
            return true;
        }

        uint256 currentDate = block.timestamp / (limitDay * SECONDS_PER_DAY);
        uint256 valueAfterSell = _sellAmounts[_wallet][currentDate] + _tokenValue;
        uint256 maxValue = (limitValue * (10 ** ERC20(tokenAddress).decimals()) * tokenAmount) / usdtAmount;

        if (valueAfterSell > maxValue) {
            return false;
        }

        return true;
    }

    function buyToken(uint256 _usdtValue) external lock canSwap {
        require(typeSwap == 1 || typeSwap == 0, "SWAP: CANNOT BUY TOKEN NOW");
        require(_usdtValue > 0, "SWAP: INVALID VALUE");

        uint256 buyFee = 0;
        uint256 amountTokenDecimal = (_usdtValue * tokenAmount) / usdtAmount;
        if (_taxBuyFee != 0 && !_addressBuyExcludeTaxFee[msg.sender]) {
            buyFee = (amountTokenDecimal * _taxBuyFee) / 10000;
            amountTokenDecimal = amountTokenDecimal - buyFee;
        }

        if (amountTokenDecimal != 0) {
            require(ERC20(currency).balanceOf(msg.sender) >= _usdtValue, "SWAP: NOT ENOUGH BALANCE CURRENCY TO BUY");
            require(ERC20(currency).allowance(msg.sender, address(this)) >= _usdtValue, "SWAP: MUST APPROVE FIRST");
            require(ERC20(currency).transferFrom(msg.sender, address(this), _usdtValue), "SWAP: FAIL TO SWAP");

            require(ERC20(tokenAddress).transfer(msg.sender, amountTokenDecimal), "SWAP: FAIL TO SWAP");
            if (buyFee != 0) {
                require(ERC20(tokenAddress).transfer(_taxAddress, buyFee), "SWAP: FAIL TO SWAP");
            }
        }
    }

    function sellToken(uint256 _tokenValue) external lock canSwap {
        require(typeSwap == 2 || typeSwap == 0, "SWAP: CANNOT SELL TOKEN NOW");
        require(_tokenValue > 0, "SWAP: INVALID VALUE");
        require(checkCanSellToken(msg.sender, _tokenValue), "SWAP: MAXIMUM SWAP TODAY");

        uint256 sellFee = 0;
        if (_taxSellFee != 0 && !_addressSellExcludeHasTaxFee[msg.sender]) {
            sellFee = (_tokenValue * _taxSellFee) / 10000;
        }
        uint256 amountUsdtDecimal = ((_tokenValue - sellFee) * usdtAmount) / tokenAmount;

        if (amountUsdtDecimal != 0) {
            require(ERC20(tokenAddress).balanceOf(msg.sender) >= _tokenValue, "SWAP: NOT ENOUGH BALANCE TOKEN TO SELL");
            require(ERC20(tokenAddress).allowance(msg.sender, address(this)) >= _tokenValue, "SWAP: MUST APPROVE FIRST");
            require(ERC20(tokenAddress).transferFrom(msg.sender, address(this), _tokenValue), "SWAP: FAIL TO SWAP");
            require(ERC20(currency).transfer(msg.sender, amountUsdtDecimal), "SWAP: FAIL TO SWAP");

            if (sellFee != 0) {
                require(ERC20(tokenAddress).transfer(_taxAddress, sellFee), "SWAP: FAIL TO SWAP");
            }

            if (limitDay > 0) {
                uint256 currentDate = block.timestamp / (limitDay * SECONDS_PER_DAY);
                _sellAmounts[msg.sender][currentDate] = _sellAmounts[msg.sender][currentDate] + _tokenValue;
            }
        }
    }

    function setContractOwner(address _newContractOwner) external checkOwner {
        contractOwner = _newContractOwner;
    }

    function recoverBNB(uint256 _amount) public checkOwner {
        require(_amount > 0, "INVALID AMOUNT");
        address payable recipient = payable(msg.sender);
        recipient.transfer(_amount);
    }

    function withdrawTokenEmergency(address _token, uint256 _amount) public checkOwner {
        require(_amount > 0, "INVALID AMOUNT");
        require(IERC20(_token).transfer(msg.sender, _amount), "CANNOT WITHDRAW TOKEN");
    }
}
pragma solidity ^0.8.8;

interface ITokenStakeApy {
    function setNftApy(uint256 _poolId, uint256 _poolIdEarnPerDay) external;

    function setNftApyExactly(uint256 _poolId, uint256[] calldata _startTime, uint256[] calldata _endTime, uint256[] calldata _tokenEarn) external;

    function getStartTime(uint256 _poolId) external view returns (uint256[] memory);

    function getEndTime(uint256 _poolId) external view returns (uint256[] memory);

    function getPoolApy(uint256 _poolId) external view returns (uint256[] memory);

    function getMaxIndex(uint256 _poolId) external view returns (uint256);
}
pragma solidity ^0.8.8;

interface ITokenStake {
    struct StakeTokenPools {
        uint256 poolId;
        uint256 maxStakePerWallet;
        uint256 duration;
        bool isPayProfit;
        address stakeToken;
        address earnToken;
    }

    struct StakedToken {
        uint256 stakeId;
        uint256 poolId;
        address userAddress;
        uint256 startTime;
        uint256 unlockTime;
        uint256 lastClaimTime;
        uint256 totalValueStake;
        uint256 totalValueStakeUsd;
        uint256 totalValueClaimed;
        uint256 totalValueClaimedUsd;
        bool isWithdraw;
    }

    event Staked(uint256 indexed id, uint256 poolId, address indexed staker, uint256 stakeValue, uint256 startTime, uint256 unlockTime);
    event Claimed(uint256 indexed id, address indexed staker, uint256 claimAmount);
    event Harvested(uint256 indexed id);

    function getCommissionPercent(uint16 _level) external view returns (uint256);

    function getCommissionCondition(uint16 _level) external view returns (uint256);

    function getStakeTokenPool(uint256 _poolId) external view returns (StakeTokenPools memory);

    function getTotalUserStakedToken(address _user) external returns (uint256);

    function getTotalUserStakedUsd(address _user) external returns (uint256);

    function getTotalUserWithdrawToken(address _user) external returns (uint256);

    function getTotalUserWithdrawUsd(address _user) external returns (uint256);

    function getTotalUserClaimedToken(address _user) external returns (uint256);

    function getTotalUserClaimedUsd(address _user) external returns (uint256);

    function getTotalUserStakedAvailableToken(address _user) external returns (uint256);

    function getTotalUserStakedAvailableUsd(address _user) external returns (uint256);

    function getUserStakedPoolToken(address _user, uint256 _poolId) external view returns (uint256);

    function getUserStakedPoolUsd(address _user, uint256 _poolId) external view returns (uint256);

    function getDirectCommission(address _user) external view returns (uint256);

    function getPoolTotalStakeToken(uint256 _poolId) external view returns (uint256);

    function getPoolTotalStakeUsd(uint256 _poolId) external view returns (uint256);

    function getPoolTotalClaimToken(uint256 _poolId) external view returns (uint256);

    function getPoolTotalClaimUsd(uint256 _poolId) external view returns (uint256);

    function totalStakedToken() external view returns (uint256);

    function totalStakedUsd() external view returns (uint256);

    function totalWithdrawToken() external view returns (uint256);

    function totalWithdrawUsd() external view returns (uint256);

    function totalClaimedToken() external view returns (uint256);

    function totalClaimedUsd() external view returns (uint256);

    function stake(uint256 _poolId, uint256 _stakeValue) external;

    function claimAll(uint256[] memory _poolIds) external;

    function claim(uint256 _poolId) external;

    function withdraw(uint256 _stakeId) external;

    function withdrawPool(uint256[] memory _stakeIds) external;

    function claimPool(uint256[] memory _stakeIds) external;

    function possibleForCommission(address _staker, uint16 _level) external view returns (bool);

    function calculateTokenEarnedStake(uint256 _stakeId) external view returns (uint256);

    function calculateUsdEarnedStake(uint256 _stakeId) external view returns (uint256);

    function calculateTokenEarnedMulti(uint256[] memory _stakeIds) external view returns (uint256);

    function getStakedToken(uint256 _stakeId) external view returns (StakedToken memory);

    function getTeamStakingValue(address _wallet) external view returns (uint256);

    function getRefClaimed(address _wallet) external view returns (uint256);
}
pragma solidity ^0.8.8;

import "../data/StructData.sol";

interface ITokenStakeSetting {
    function setRankCommissionDuration(uint256 _rankCommissionDuration) external;

    function setPoolDurationHasLimit(uint256 _poolDurationHasLimit) external;

    function setIndexData(uint256 _stakeTokenPoolLength, uint256 _stakeIndex) external;

    function setMaxFloor(uint16 _maxFloor) external;

    function setTokenDecimal(uint256 _tokenDecimal) external;

    function setRefClaimed(address[] calldata _wallets, uint256[] calldata _refClaimeds) external;

    function setDirectCommission(address[] calldata _wallets, uint256[] calldata _directCommissions) external;

    function setUserStakedPoolToken(address[] calldata _wallets, uint256[] calldata _poolIds, uint256[] calldata _totalUserStakedPoolTokens) external;

    function setUserStakedPoolUsd(address[] calldata _wallets, uint256[] calldata _poolIds, uint256[] calldata _totalUserStakedPoolUsds) external;

    function setDirectCommissionPercents(uint256 _poolId, uint256 _percent) external;

    function setCommissionPercent(uint16 _level, uint256 _percent) external;

    function setCommissionCondition(uint16 _level, uint256 _conditionInUsd) external;

    function setTimeOpenStaking(uint256 _timeOpening) external;

    function setCanNotWithdraw(uint256 _stakedTokenId, uint256 _canNotWithdraw) external;

    function setMarketContract(address _marketContract) external;

    function setNovaxToken(address _novaxToken) external;

    function setApyContract(address _tokenStakeApy) external;

    function setOracleContract(address _token, address _oracleContract) external;

    function setRankingContract(address _rankingContract) external;

    function setStakeTokenPool(uint256 _poolId, uint256 _maxStakePerWallet, uint256 _duration, bool _isPayProfit, address _stakeToken, address _earnToken) external;

    function setStakedToken(
        uint256 _stakeId,
        uint256 _poolId,
        address _userAddress,
        uint256 _startTime,
        uint256 _unlockTime,
        uint256 _totalValueStake,
        uint256 _totalValueStakeUsd,
        uint256 _totalValueClaimed,
        uint256 _totalValueClaimedUsd,
        bool _isWithdraw
    ) external;

    function addStakedToken(uint256 _poolId, address _userAddress, uint256 _totalValueStake, bool _payDirect) external;

    function recoverLostBNB() external;

    function withdrawTokenEmergency(address _token, uint256 _amount) external;
}
