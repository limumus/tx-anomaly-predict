pragma solidity ^0.6.11;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/math/Math.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/IERC20.sol";
import "../lib/interfaces/IDepositContract.sol";
import "../SystemParameters.sol";
import "../lib/Lockable.sol";
import "../lib/interfaces/IAETH.sol";
import "../lib/interfaces/IFETH.sol";
import "../lib/interfaces/IConfig.sol";
import "../lib/interfaces/IStaking.sol";
import "../lib/interfaces/IDepositContract.sol";
import "../lib/Pausable.sol";
import "../lib/interfaces/IGlobalPool.sol";
import "../lib/interfaces/IWithdrawalPool.sol";

contract GlobalPool_R42 is IGlobalPool, Lockable, Pausable {

    using SafeMath for uint256;
    using Math for uint256;

    /* change events */
    event AETHContractChanged(address prevValue, address newValue);
    event FETHContractChanged(address prevValue, address newValue);
    event ConfigContractChanged(address prevValue, address newValue);
    event StakingContractChanged(address prevValue, address newValue);
    event OperatorChanged(address prevValue, address newValue);
    event CrossChainBridgeChanged(address prevValue, address newValue);
    event DistributeGasLimitChanged(uint256 prevValue, uint256 newValue);
    event WithdrawalPoolChanged(address prevValue, address newValue);
    event TreasuryChanged(address prevValue, address newValue);
    event VaultAllowed(address vault);
    event VaultDisallowed(address vault);

    /* staker events */
    event StakePending(address indexed staker, uint256 amount);
    event StakeConfirmed(address indexed staker, uint256 amount);
    event StakeRemoved(address indexed staker, uint256 amount);
    event PendingUnstake(
        address indexed ownerAddress,
        address indexed receiverAddress,
        uint256 amount,
        bool isAETH
    );
    event RewardsDistributed(address[] claimers, uint256[] amounts);
    event RewardsClaimed(
        address indexed receiverAddress,
        address claimer,
        uint256 amount
    );

    event ManualClaimExpected(
        address indexed claimer,
        uint256 amount
    );

    /* pool events */
    event PoolOnGoing(bytes pool);
    event PoolCompleted(bytes pool);
    event PushedToVault(address vault, uint256 count);

    /* provider events */
    event ProviderSlashedAnkr(address indexed provider, uint256 ankrAmount, uint256 etherEquivalence);
    event ProviderSlashedEth(address indexed provider, uint256 amount);
    event ProviderToppedUpEth(address indexed provider, uint256 amount);
    event ProviderToppedUpAnkr(address indexed provider, uint256 amount);
    event ProviderExited(address indexed provider);

    /* rewards (AETH) */
    event RewardsRestaked(address indexed sender, uint256 amount);
    event RewardClaimed(address indexed staker, uint256 amount, bool isAETH);

    // deleted fields
    mapping(address => uint256) private _pendingUserStakes; // deleted

    mapping(address => uint256) private _userStakes;
    mapping(address => uint256) private _rewards;
    mapping(address => uint256) private _claims;

    // deleted fields
    mapping(address => uint256) private _etherBalances; // deleted
    mapping(address => uint256) private _slashings; // deleted

    mapping(address => uint256) private _exits;

    // deleted fields
    address[] private _pendingStakers; // deleted
    uint256 private _pendingAmount; // deleted
    uint256 private _totalStakes; // deleted
    uint256 private _totalRewards; // deleted

    IAETH private _aethContract;
    IStaking private _stakingContract;
    SystemParameters private _systemParameters;
    address private _depositContract;

    // deleted fields
    address[] private _pendingTemp; // deleted
    uint256[50] private __gap; // deleted
    uint256 private _lastPendingStakerPointer; // deleted

    IConfig private _configContract;

    // deleted fields
    mapping(address => uint256) private _pendingEtherBalances; // deleted

    address private _operator; // slot:322

    // deleted fields
    mapping(address => uint256[2]) private _fETHRewards; // deleted

    mapping(address => uint256) private _aETHRewards;
    IFETH private _fethContract;

    // deleted fields
    uint256 private _fethMintBase; // deleted

    /**
     * @dev deprecated variable with old cross-chain bridge
     */
    address private _crossChainBridge; // slot:327
    mapping(address => uint256) private _aETHProviderRewards; // slot:323
    uint256 private _totalSlashedETH;

    address public treasury;

    // unstakes
    uint256 public _DISTRIBUTE_GAS_LIMIT;
    IWithdrawalPool internal _withdrawalPool;
    uint256 internal _pendingUnstakeGap;
    uint256 internal _pendingTotalUnstakes;
    address[] internal _pendingUnstakeClaimers;
    mapping(address => uint256) internal _pendingClaimerUnstakes;
    uint256[] internal _pendingUnstakeRequests;

    // reentrancy guard
    // @dev inverse @openzeppelin/contracts-ethereum-package/contracts/utils/ReentrancyGuard.sol
    bool private _entered;

    // manual claim
    uint256 internal _stashedForManualClaims;
    mapping(address => uint256) internal _manualClaims; // address => amount

    // Vaults
    mapping(address => bool) internal _allowedVaults; // address => bool

    modifier notExitRecently(address provider) {
        require(block.number > _exits[provider].add(_configContract.getConfig("EXIT_BLOCKS")), "Recently exited");
        delete _exits[msg.sender];
        _;
    }

    modifier onlyOperator() {
        require(msg.sender == owner() || msg.sender == _operator, "Operator: not allowed");
        _;
    }

    modifier notMarkedForManualClaim() virtual {
        require(
            _manualClaims[msg.sender] == 0,
            "GlobalPool: sender is marked for manual claim"
        );
        _;
    }

    modifier nonReentrant() {
        // On the first call to nonReentrant, _entered will be false
        require(!_entered, "ReentrancyGuard: reentrant call");

        // Any calls to nonReentrant after this point will fail
        _entered = true;

        _;

        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _entered = false;
    }

    function initialize(IAETH aethContract, SystemParameters parameters, address depositContract) public initializer {
        __Ownable_init();

        _depositContract = depositContract;
        _aethContract = aethContract;
        _systemParameters = parameters;

        _paused["topUpETH"] = true;
        _paused["topUpANKR"] = true;
    }

    // @notice Push 32 ETH x count to allowed vault, where ETH going to Deposit Contract
    function pushToVault(address vault, uint256 count) external onlyOperator nonReentrant {
        require(_allowedVaults[vault], "GlobalPool: vault not allowed");
        require(count > 0, "GlobalPool: count is zero");
        uint256 amount = count.mul(32 ether);
        require(address(this).balance >= amount, "GlobalPool: pending ethers not enough");
        _unsafeTransfer(vault, amount, false);
        emit PushedToVault(vault, count);
    }

    function pushToBeacon(bytes calldata pubkey, bytes calldata withdrawal_credentials, bytes calldata signature, bytes32 deposit_data_root) public onlyOperator {
        require(address(this).balance >= 32 ether, "pending ethers not enough");
        IDepositContract(_depositContract).deposit{value : 32 ether}(pubkey, withdrawal_credentials, signature, deposit_data_root);
        emit PoolOnGoing(pubkey);
    }

    /*
     * @notice add an amount as stakeable reward of pull
     */
    function restake() external payable override {
        emit StakeConfirmed(msg.sender, msg.value);
    }

    function stake() public whenNotPaused("stake") unlocked(msg.sender) payable {
        _stake(msg.sender, msg.value, LockStrategy.Claimable);
    }

    function stakeAndClaimAethC() public whenNotPaused("stake") unlocked(msg.sender) payable {
        _stake(msg.sender, msg.value, LockStrategy.Claimable);
        claimAETH();
    }

    function stakeAndClaimAethB() public whenNotPaused("stake") unlocked(msg.sender) payable {
        _stake(msg.sender, msg.value, LockStrategy.Claimable);
        claimFETH();
    }

    // This function don't have to be protected because there is no reason for someone
    // to call it manually. In this case "attacker" can just delegate his stake to someone else
    // and lock his funds on cross chain contract that doesn't make sense. But on the other
    // hand it brings tiny gas optimization to our backend.
    function crossChainStake(address[] memory addresses, uint256[] memory amounts) public payable {
        require(addresses.length == amounts.length, "Addresses and amounts length must be equal");
        uint256 totalSent = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalSent = totalSent.add(amounts[i]);
            _stake(addresses[i], amounts[i], LockStrategy.CrossChain);
        }
        require(msg.value == totalSent, "Total value must be same with sent");
    }

    enum LockStrategy {
        Claimable, CrossChain, Provider
    }

    function _stake(address staker, uint256 value, LockStrategy lockStrategy) internal {
        require(value > 0, "Value must be greater than zero");
        // check minimum staking amount (don't allow remainders also)
        // uint256 minimumStaking = _configContract.getConfig("REQUESTER_MINIMUM_POOL_STAKING");
        // require(value >= minimumStaking, "Value must be greater than zero");
        // require(value % minimumStaking == 0, "Value must be multiple of minimum staking amount");
        // lets calc how many ethers every user staked
        _userStakes[staker] = _userStakes[staker].add(value);
        // calculate amount of shares to be minted to the user
        uint256 shares = _aethContract.bondsToShares(value);
        // mint rewards based on lock strategy
        if (lockStrategy == LockStrategy.Claimable) {
            // allow staker to claim aETH or fETH tokens
            _aethContract.mint(address(this), shares);
            _aETHRewards[staker] = _aETHRewards[staker].add(shares);
        } else if (lockStrategy == LockStrategy.CrossChain) {
            // lock rewards on cross chain bridge
            require(_crossChainBridge != address(0x00), "Cross chain bridge is not initialized");
            _aethContract.mint(address(_crossChainBridge), shares);
        } else if (lockStrategy == LockStrategy.Provider) {
            // lock rewards because staker is provider
            _aethContract.mint(address(this), shares);
            _aETHProviderRewards[staker] = _aETHProviderRewards[staker].add(shares);
        } else {
            revert("Not supported lock strategy type");
        }
        // mint event that this stake is confirmed
        emit StakeConfirmed(staker, value);
    }

    function claimableAETHRewardOf(address staker) public view returns (uint256) {
        // this is super legacy and super strange reward calculation scheme, lets keep it here
        uint256 blocked = _etherBalances[staker].add(_aETHProviderRewards[staker]);
        uint256 legacyRewards = _rewards[staker].sub(_claims[staker]);
        if (blocked >= legacyRewards) {
            legacyRewards = 0;
        } else {
            legacyRewards = legacyRewards.sub(blocked);
        }
        // return claimable aETH rewards for token
        return _aETHRewards[staker].add(legacyRewards);
    }

    function claimableFETHRewardOf(address staker) public view returns (uint256) {
        return _aethContract.sharesToBonds(claimableAETHRewardOf(staker));
    }

    function claimableAETHFRewardOf(address staker) public view returns (uint256) {
        return claimableFETHRewardOf(staker);
    }

    function claimAETH() /*whenNotPaused("claim")*/ notExitRecently(msg.sender) public {
        address staker = msg.sender;
        uint256 claimableShares = claimableAETHRewardOf(staker);
        require(claimableShares > 0, "claimable reward zero");
        _aETHRewards[staker] = 0;
        uint256 oldReward = _rewards[staker].sub(_claims[staker]);
        if (oldReward > 0) {
            _claims[staker] = _claims[staker].add(oldReward);
        }
        require(_aethContract.transfer(address(staker), claimableShares), "can't transfer shares");
        emit RewardClaimed(staker, claimableShares, true);
    }

    function claimFETH() whenNotPaused("claim") notExitRecently(msg.sender) public {
        address staker = msg.sender;
        uint256 claimableShares = claimableAETHRewardOf(staker);
        require(claimableShares > 0, "claimable reward zero");
        _aETHRewards[staker] = 0;
        uint256 oldReward = _rewards[staker].sub(_claims[staker]);
        if (oldReward > 0) {
            _claims[staker] = _claims[staker].add(oldReward);
        }
        uint256 allowance = _aethContract.allowance(address(this), address(_fethContract));
        if (allowance < claimableShares) {
            require(_aethContract.approve(address(_fethContract), 2 ** 256 - 1), "can't approve");
        }
        _fethContract.lockSharesFor(address(this), staker, claimableShares);
        emit RewardClaimed(staker, claimableShares, false);
    }

    function unstakeFETH(uint256 amount) external whenNotPaused("unstake") nonReentrant notMarkedForManualClaim {
        uint256 shares = _fethContract.bondsToShares(amount);
        // swap fETH into aETH (it also burns fETH)
        _fethContract.unlockSharesFor(msg.sender, shares);
        _unstake(msg.sender, msg.sender, shares, amount, false);
    }

    function unstakeFETHFor(uint256 amount, address recipient) external whenNotPaused("unstake") nonReentrant {
        uint256 shares = _fethContract.bondsToShares(amount);
        // swap fETH into aETH (it also burns fETH)
        _fethContract.unlockSharesFor(msg.sender, shares);
        _unstake(msg.sender, recipient, shares, amount, false);
    }

    function unstakeAETH(uint256 shares) external whenNotPaused("unstake") notMarkedForManualClaim nonReentrant {
        uint256 amount = _fethContract.sharesToBonds(shares);
        _unstake(msg.sender, msg.sender, shares, amount, true);
    }

    function unstakeAETHFor(uint256 shares, address recipient) external whenNotPaused("unstake") nonReentrant {
        uint256 amount = _fethContract.sharesToBonds(shares);
        _unstake(msg.sender, recipient, shares, amount, true);
    }

    /*
     * @param staker - address where we must burn aETH
     * @param recipient - future support for unstakeFor
     * @param shares - aETH to burn
     * @param amount - ETH amount to unstake
     */
    function _unstake(address staker, address recipient, uint256 shares, uint256 amount, bool isAETH) internal {
        require(amount >= _configContract.getConfig("UNSTAKE_MIN_AMOUNT"), "Value must be greater than minimum amount");
        // no need to check balance, because ERC20UpgradeSafe is checking it before burn
        _aethContract.burn(staker, shares);
        _addIntoQueue(staker, recipient, amount);
        emit PendingUnstake(staker, recipient, amount, isAETH);
    }

    /*
     * @dev queue is released by distributeRewards()
     */
    function _addIntoQueue(address staker, address recipient, uint256 amount) internal {
        require(
            amount != 0 && recipient != address(0),
            "GlobalPool: zero input values"
        );
        _pendingTotalUnstakes = _pendingTotalUnstakes.add(amount);
        _pendingUnstakeClaimers.push(recipient);
        _pendingUnstakeRequests.push(amount);

        _pendingClaimerUnstakes[recipient] = _pendingClaimerUnstakes[recipient].add(amount);
    }

    function getUnstakeRequestsOf(
        address claimer
    ) external view returns (uint256[] memory) {
        uint256 j;
        uint256 gap = _pendingUnstakeGap;

        uint256[] memory unstakes = new uint256[](
            _pendingUnstakeClaimers.length - gap
        );
        for (; gap < _pendingUnstakeClaimers.length; gap++) {
            if (_pendingUnstakeClaimers[gap] == claimer) {
                unstakes[j] = _pendingUnstakeRequests[gap];
                ++j;
            }
        }
        uint256 removeCells = unstakes.length - j;
        if (removeCells > 0) {
            assembly {
                mstore(unstakes, j)
            }
        }
        return unstakes;
    }

    function getPendingUnstakesOf(
        address claimer
    ) public view returns (uint256) {
        return _pendingClaimerUnstakes[claimer];
    }

    function getTotalPendingUnstakes() public view returns (uint256) {
        return _pendingTotalUnstakes;
    }

    /*
     * @notice take fee from rewards, pay unstakes, restake the rest of rewards
     * @dev control fee from backend
     * @param fee - ANKR's fee that should be deducted from rewards
     */
    function distributeRewards(uint256 feeAmount) external onlyOperator {
        require(
            _DISTRIBUTE_GAS_LIMIT > 0,
            "GlobalPool: DISTRIBUTE_GAS_LIMIT is not set"
        );
        _withdrawalPool.claim();
        uint256 poolBalance = address(this).balance.sub(_stashedForManualClaims);
        // withdraw ANKR fee to treasury
        require(poolBalance >= feeAmount, "GlobalPool: not enough ETH to withdraw fee");
        poolBalance = poolBalance.sub(feeAmount);
        _unsafeTransfer(treasury, feeAmount, false);

        address[] memory claimers = new address[](
            _pendingUnstakeClaimers.length - _pendingUnstakeGap
        );
        uint256[] memory amounts = new uint256[](
            _pendingUnstakeClaimers.length - _pendingUnstakeGap
        );
        uint256 j = 0;
        uint256 i = _pendingUnstakeGap;

        while (
            i < _pendingUnstakeClaimers.length &&
            poolBalance > 0 &&
            gasleft() > _DISTRIBUTE_GAS_LIMIT
        ) {
            address claimer = _pendingUnstakeClaimers[i];
            uint256 toDistribute = _pendingUnstakeRequests[i];
            // empty unstake
            if (claimer == address(0) || toDistribute == 0) {
                i++;
                continue;
            }

            if (poolBalance < toDistribute) {
                break;
            }

            _pendingClaimerUnstakes[claimer] = _pendingClaimerUnstakes[claimer].sub(toDistribute);
            _pendingTotalUnstakes = _pendingTotalUnstakes.sub(toDistribute);
            poolBalance = poolBalance.sub(toDistribute);
            delete _pendingUnstakeClaimers[i];
            delete _pendingUnstakeRequests[i];
            i++;

            if (isMarkedForManualClaim(claimer)) {
                _setForManualClaim(claimer, toDistribute);
                continue;
            }

            bool success = _unsafeTransfer(claimer, toDistribute, true);
            if (!success) {
                _setForManualClaim(claimer, toDistribute);
                continue;
            }

            claimers[j] = claimer;
            amounts[j] = toDistribute;
            j++;
        }
        _pendingUnstakeGap = i;
        /* decrease arrays */
        uint256 removeCells = claimers.length - j;
        if (removeCells > 0) {
            assembly {
                mstore(claimers, j)
            }
            assembly {
                mstore(amounts, j)
            }
        }
        emit RewardsDistributed(claimers, amounts);
    }

    function _setForManualClaim(
        address claimer,
        uint256 amount
    ) internal {
        _stashedForManualClaims = _stashedForManualClaims.add(amount);
        _manualClaims[claimer] = _manualClaims[claimer].add(amount);

        emit ManualClaimExpected(claimer, amount);
    }

    function claimManually(address receiverAddress) external /* nonReentrant */ {
        require(
            receiverAddress != address(0),
            "GlobalPool: zero address"
        );
        uint256 amount = _manualClaims[receiverAddress];
        require(
            amount > 0,
            "GlobalPool: not marked for manual claim"
        );
        require(_stashedForManualClaims <= address(this).balance, "GlobalPool: not enough balance");
        _stashedForManualClaims = _stashedForManualClaims.sub(amount);
        delete _manualClaims[receiverAddress];

        bool result = _unsafeTransfer(receiverAddress, amount, false);
        require(
            result,
            "GlobalPool: failed to send rewards"
        );
        emit RewardsClaimed(receiverAddress, msg.sender, amount);
    }

    function isMarkedForManualClaim(address claimer)
    public
    view
    returns (bool)
    {
        return _manualClaims[claimer] != uint256(0);
    }

    function getForManualClaimOf(address claimer)
    public
    view
    returns (uint256)
    {
        return _manualClaims[claimer];
    }

    function getStashedForManualClaims() public view returns (uint256) {
        return _stashedForManualClaims;
    }

    function availableEtherBalanceOf(address provider) public view returns (uint256) {
        return _aETHProviderRewards[provider];
    }

    function etherBalanceOf(address provider) public view returns (uint256) {
        return _etherBalances[provider];
    }

    function slashingsOf(address provider) public view returns (uint256) {
        return 0;
    }

    function topUpETH() public whenNotPaused("topUpETH") payable {
        require(_configContract.getConfig("PROVIDER_MINIMUM_ETH_STAKING") <= msg.value, "Value must be greater than minimum amount");
        _stake(msg.sender, msg.value, LockStrategy.Provider);
        emit ProviderToppedUpEth(msg.sender, msg.value);
    }

    function topUpANKR(uint256 amount) public whenNotPaused("topUpANKR") {
        require(_configContract.getConfig("PROVIDER_MINIMUM_ANKR_STAKING") <= amount, "Value must be greater than minimum amount");
        require(_stakingContract.freeze(msg.sender, amount), "Not enough allowance or balance");
        emit ProviderToppedUpAnkr(msg.sender, amount);
    }

    function forceAdminProviderExit(address[] calldata providers) public onlyOperator {
        for (uint256 i = 0; i < providers.length; i++) {
            _forceProviderExitFor(providers[i]);
        }
    }

    event ProviderLockedEthReset(address provider, uint256 amount, uint256 legacy);

    function resetLockedEthForProviders(address[] calldata providers) external onlyOperator {
        for (uint256 i = 0; i < providers.length; i++) {
            address provider = providers[i];
            uint256 legacyBalance = _etherBalances[provider];
            uint256 newBalance = _aETHProviderRewards[provider];
            _etherBalances[provider] = 0;
            _aETHProviderRewards[provider] = 0;
            emit ProviderLockedEthReset(provider, newBalance, legacyBalance);
        }
    }

    function _forceProviderExitFor(address provider) internal {
        uint256 claimableRewards = _aETHProviderRewards[provider];
        if (claimableRewards > 0) {
            _aETHProviderRewards[provider] = _aETHProviderRewards[provider].sub(claimableRewards);
            _aETHRewards[provider] = _aETHRewards[provider].add(claimableRewards);
        }
        uint256 frozenDeposits = _stakingContract.frozenDepositsOf(provider);
        uint256 lockedDeposits = _stakingContract.lockedDepositsOf(provider);
        uint256 ankrDepositBalance = frozenDeposits.sub(lockedDeposits);
        if (ankrDepositBalance > 0) {
            require(_stakingContract.unfreeze(provider, ankrDepositBalance), "Failed to unfreeze");
        }
        emit ProviderExited(provider);
    }

    function softLockBlockNumber(address provider) public view returns (uint256) {
        uint256 exitedAt = _exits[provider];
        if (exitedAt == 0) {
            return 0;
        }
        uint256 waitFor = _configContract.getConfig("EXIT_BLOCKS");
        return exitedAt.add(waitFor);
    }

    /**
        @dev Slash eth, returns remaining needs to be slashed
    */
    function slashETH(address provider, uint256 amount) public onlyOperator {
        require(amount <= _aETHProviderRewards[provider], "Not enough rewards for slashing");
        // deduct slashed amount from provider
        _aETHProviderRewards[provider] = _aETHProviderRewards[provider].sub(amount);
        _totalSlashedETH = _totalSlashedETH.add(amount);
        // emit event indicating provider slash
        emit ProviderSlashedEth(provider, amount);
    }

    function totalSlashedETH() public view returns (uint256) {
        return _totalSlashedETH;
    }

    function updateAETHContract(address payable aEthContract) external onlyOwner {
        address prevValue = address(_aethContract);
        _aethContract = IAETH(aEthContract);
        emit AETHContractChanged(prevValue, aEthContract);
    }

    function updateFETHContract(address payable fEthContract) external onlyOwner {
        address prevValue = address(_fethContract);
        _fethContract = IFETH(fEthContract);
        emit FETHContractChanged(prevValue, fEthContract);
    }

    function updateConfigContract(address configContract) external onlyOwner {
        address prevValue = address(_configContract);
        _configContract = IConfig(configContract);
        emit ConfigContractChanged(prevValue, configContract);
    }

    function updateStakingContract(address stakingContract) external onlyOwner {
        address prevValue = address(_stakingContract);
        _stakingContract = IStaking(stakingContract);
        emit StakingContractChanged(prevValue, stakingContract);
    }

    function changeOperator(address operator) public onlyOwner {
        address prevValue = _operator;
        _operator = operator;
        emit OperatorChanged(prevValue, operator);
    }

    function updateDistributeGasLimit(uint256 newValue) external onlyOwner {
        require(newValue > 0, "GlobalPool: cannot be zero");
        emit DistributeGasLimitChanged(_DISTRIBUTE_GAS_LIMIT, newValue);
        _DISTRIBUTE_GAS_LIMIT = newValue;
    }

    function updateWithdrawalPool(address newValue) external onlyOwner {
        require(newValue != address(0), "GlobalPool: zero address");
        emit WithdrawalPoolChanged(address(_withdrawalPool), newValue);
        _withdrawalPool = IWithdrawalPool(newValue);
    }

    function updateTreasury(address newValue) external onlyOwner {
        require(newValue != address(0), "GlobalPool: zero address");
        emit TreasuryChanged(address(treasury), newValue);
        treasury = newValue;
    }

    function allowVault(address vault) external onlyOwner {
        require(vault != address(0), "GlobalPool: zero address");
        require(!_allowedVaults[vault], "GlobalPool: already allowed");
        _allowedVaults[vault] = true;
        emit VaultAllowed(vault);
    }

    function disallowVault(address vault) external onlyOwner {
        require(vault != address(0), "GlobalPool: zero address");
        require(_allowedVaults[vault], "GlobalPool: not allowed");
        _allowedVaults[vault] = false;
        emit VaultDisallowed(vault);
    }

    function depositContractAddress() public view returns (address) {
        return _depositContract;
    }

    /**
     * @dev deprecated
     */
    function crossChainBridge() public view returns (address) {
        return _crossChainBridge;
    }

    function _unsafeTransfer (
        address receiverAddress,
        uint256 amount,
        bool limit
    ) internal virtual returns (bool) {
        address payable wallet = payable(receiverAddress);
        bool success;
        if (limit) {
            assembly {
                success := call(10000, wallet, amount, 0, 0, 0, 0)
            }
            return success;
        }
        (success, ) = wallet.call{value: amount}("");
        return success;
    }

    receive() external payable virtual {
        require(msg.sender == address(_withdrawalPool), "sender not allowed");
    }
}File 2 of 18 : IERC20.solpragma solidity ^0.6.0;

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IERC20 {
    /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves `amount` tokens from the caller's account to `recipient`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address recipient, uint256 amount) external returns (bool);

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
     * @dev Moves `amount` tokens from `sender` to `recipient` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

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
}File 3 of 18 : SafeMath.solpragma solidity ^0.6.0;

/**
 * @dev Wrappers over Solidity's arithmetic operations with added overflow
 * checks.
 *
 * Arithmetic operations in Solidity wrap on overflow. This can easily result
 * in bugs, because programmers usually assume that an overflow raises an
 * error, which is the standard behavior in high level programming languages.
 * `SafeMath` restores this intuition by reverting the transaction when an
 * operation overflows.
 *
 * Using this library instead of the unchecked operations eliminates an entire
 * class of bugs, so it's recommended to use it always.
 */
library SafeMath {
    /**
     * @dev Returns the addition of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `+` operator.
     *
     * Requirements:
     * - Addition cannot overflow.
     */
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");

        return c;
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting on
     * overflow (when the result is negative).
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     * - Subtraction cannot overflow.
     */
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return sub(a, b, "SafeMath: subtraction overflow");
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting with custom message on
     * overflow (when the result is negative).
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     * - Subtraction cannot overflow.
     */
    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        uint256 c = a - b;

        return c;
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `*` operator.
     *
     * Requirements:
     * - Multiplication cannot overflow.
     */
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
        // benefit is lost if 'b' is also tested.
        // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
        if (a == 0) {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");

        return c;
    }

    /**
     * @dev Returns the integer division of two unsigned integers. Reverts on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator. Note: this function uses a
     * `revert` opcode (which leaves remaining gas untouched) while Solidity
     * uses an invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(a, b, "SafeMath: division by zero");
    }

    /**
     * @dev Returns the integer division of two unsigned integers. Reverts with custom message on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator. Note: this function uses a
     * `revert` opcode (which leaves remaining gas untouched) while Solidity
     * uses an invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        // Solidity only automatically asserts when dividing by 0
        require(b > 0, errorMessage);
        uint256 c = a / b;
        // assert(a == b * c + a % b); // There is no case in which this doesn't hold

        return c;
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * Reverts when dividing by zero.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        return mod(a, b, "SafeMath: modulo by zero");
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * Reverts with custom message when dividing by zero.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        require(b != 0, errorMessage);
        return a % b;
    }
}File 4 of 18 : Math.solpragma solidity ^0.6.0;

/**
 * @dev Standard math utilities missing in the Solidity language.
 */
library Math {
    /**
     * @dev Returns the largest of two numbers.
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }

    /**
     * @dev Returns the smallest of two numbers.
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @dev Returns the average of two numbers. The result is rounded towards
     * zero.
     */
    function average(uint256 a, uint256 b) internal pure returns (uint256) {
        // (a + b) / 2 can overflow, so we distribute
        return (a / 2) + (b / 2) + ((a % 2 + b % 2) / 2);
    }
}File 5 of 18 : Ownable.solpragma solidity ^0.6.0;

import "../GSN/Context.sol";
import "../Initializable.sol";
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
contract OwnableUpgradeSafe is Initializable, ContextUpgradeSafe {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */

    function __Ownable_init() internal initializer {
        __Context_init_unchained();
        __Ownable_init_unchained();
    }

    function __Ownable_init_unchained() internal initializer {


        address msgSender = _msgSender();
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);

    }


    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(_owner == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }

    uint256[49] private __gap;
}File 6 of 18 : Initializable.solpragma solidity >=0.4.24 <0.7.0;


/**
 * @title Initializable
 *
 * @dev Helper contract to support initializer functions. To use it, replace
 * the constructor with a function that has the `initializer` modifier.
 * WARNING: Unlike constructors, initializer functions must be manually
 * invoked. This applies both to deploying an Initializable contract, as well
 * as extending an Initializable contract via inheritance.
 * WARNING: When used with inheritance, manual care must be taken to not invoke
 * a parent initializer twice, or ensure that all initializers are idempotent,
 * because this is not dealt with automatically as with constructors.
 */
contract Initializable {

  /**
   * @dev Indicates that the contract has been initialized.
   */
  bool private initialized;

  /**
   * @dev Indicates that the contract is in the process of being initialized.
   */
  bool private initializing;

  /**
   * @dev Modifier to use in the initializer function of a contract.
   */
  modifier initializer() {
    require(initializing || isConstructor() || !initialized, "Contract instance has already been initialized");

    bool isTopLevelCall = !initializing;
    if (isTopLevelCall) {
      initializing = true;
      initialized = true;
    }

    _;

    if (isTopLevelCall) {
      initializing = false;
    }
  }

  /// @dev Returns true if and only if the function is running in the constructor
  function isConstructor() private view returns (bool) {
    // extcodesize checks the size of the code stored in an address, and
    // address returns the current address. Since the code is still not
    // deployed when running a constructor, any checks on its code size will
    // yield zero, making it an effective way to detect if a contract is
    // under construction or not.
    address self = address(this);
    uint256 cs;
    assembly { cs := extcodesize(self) }
    return cs == 0;
  }

  // Reserved storage space to allow for layout changes in the future.
  uint256[50] private ______gap;
}File 7 of 18 : Context.solpragma solidity ^0.6.0;
import "../Initializable.sol";

/*
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with GSN meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
contract ContextUpgradeSafe is Initializable {
    // Empty internal constructor, to prevent people from mistakenly deploying
    // an instance of this contract, which should be used via inheritance.

    function __Context_init() internal initializer {
        __Context_init_unchained();
    }

    function __Context_init_unchained() internal initializer {


    }


    function _msgSender() internal view virtual returns (address payable) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes memory) {
        this; // silence state mutability warning without generating bytecode - see https://github.com/ethereum/solidity/issues/2691
        return msg.data;
    }

    uint256[50] private __gap;
}File 8 of 18 : IWithdrawalPool.solpragma solidity ^0.6.11;

interface IWithdrawalPool {

    function claim() external;
}File 9 of 18 : IStaking.solpragma solidity ^0.6.11;

interface IStaking {
    function compensateLoss(address provider, uint256 ethAmount) external returns (bool, uint256, uint256);

    function freeze(address user, uint256 amount) external returns (bool);

    function unfreeze(address user, uint256 amount) external returns (bool);

    function frozenStakesOf(address staker) external view returns (uint256);

    function lockedDepositsOf(address staker) external view returns (uint256);

    function stakesOf(address staker) external view returns (uint256);

    function frozenDepositsOf(address staker) external view returns (uint256);

    function depositsOf(address staker) external view returns (uint256);

    function deposit() external;

    function deposit(address user) external;
}File 10 of 18 : IGlobalPool.solpragma solidity ^0.6.11;

interface IGlobalPool {

    function restake() external payable;

}File 11 of 18 : IFETH.solpragma solidity ^0.6.11;

import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/IERC20.sol";

interface IFETH is IERC20 {

    function mint(address account, uint256 shares, uint256 sent) external;

    function updateReward(uint256 newReward) external returns (uint256);

    function lockShares(address account, uint256 shares) external;

    function lockSharesFor(address spender, address account, uint256 shares) external;

    function unlockShares(uint256 shares) external;

    function unlockSharesFor(address account, uint256 shares) external;

    function sharesToBonds(uint256 amount) external view returns (uint256);

    function bondsToShares(uint256 amount) external view returns (uint256);
}File 12 of 18 : IDepositContract.solpragma solidity ^0.6.11;

interface IDepositContract {
    /// @notice A processed deposit event.
    event DepositEvent(
        bytes pubkey,
        bytes withdrawal_credentials,
        bytes amount,
        bytes signature,
        bytes index
    );

    /// @notice Submit a Phase 0 DepositData object.
    /// @param pubkey A BLS12-381 public key.
    /// @param withdrawal_credentials Commitment to a public key for withdrawals.
    /// @param signature A BLS12-381 signature.
    /// @param deposit_data_root The SHA-256 hash of the SSZ-encoded DepositData object.
    /// Used as a protection against malformed input.
    function deposit(
        bytes calldata pubkey,
        bytes calldata withdrawal_credentials,
        bytes calldata signature,
        bytes32 deposit_data_root
    ) external payable;

    /// @notice Query the current deposit root hash.
    /// @return The deposit root hash.
    function get_deposit_root() external view returns (bytes32);

    /// @notice Query the current deposit count.
    /// @return The deposit count encoded as a little endian 64-bit number.
    function get_deposit_count() external view returns (bytes memory);
}File 13 of 18 : IConfig.solpragma solidity ^0.6.11;

interface IConfig {
    function getConfig(bytes32 config) external view returns (uint256);

    function setConfig(bytes32 config, uint256 value) external;
}File 14 of 18 : IAETH.solpragma solidity ^0.6.11;

import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/IERC20.sol";

interface IAETH is IERC20 {

    function burn(address account, uint256 amount) external;

    function updateMicroPoolContract(address microPoolContract) external;

    function ratio() external view returns (uint256);

    function mintFrozen(address account, uint256 amount) external;

    function mint(address account, uint256 amount) external returns (uint256);

    function mintApprovedTo(address account, address spender, uint256 amount) external;

    function mintPool() payable external;

    function fundPool(uint256 poolIndex, uint256 amount) external;

    function sharesToBonds(uint256 amount) external view returns (uint256);

    function bondsToShares(uint256 amount) external view returns (uint256);
}File 15 of 18 : Pausable.solpragma solidity 0.6.11;
import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

contract Pausable is  OwnableUpgradeSafe {
    mapping (bytes32 => bool) internal _paused;

    modifier whenNotPaused(bytes32 action) {
        require(!_paused[action], "This action currently paused");
        _;
    }

    function togglePause(bytes32 action) public onlyOwner {
        _paused[action] = !_paused[action];
    }

    function isPaused(bytes32 action) public view returns(bool) {
        return _paused[action];
    }

    uint256[50] private __gap;
}File 16 of 18 : Lockable.solpragma solidity ^0.6.11;

abstract contract Lockable {
    mapping(address => bool) private _locks;

    modifier unlocked(address addr) {
        require(!_locks[addr], "Reentrancy protection");
        _locks[addr] = true;
        _;
        _locks[addr] = false;
    }

    uint256[50] private __gap;
}
pragma solidity ^0.6.11;

import "./Governable.sol";

contract SystemParameters is Governable {

    // Minimum ankr staking amount to be abel to initialize a pool
    uint256 public PROVIDER_MINIMUM_STAKING;

    // Minimum staking amount for pool participants
    uint256 public REQUESTER_MINIMUM_POOL_STAKING; // 0.1 ETH

    // Ethereum staking amount
    uint256 public ETHEREUM_STAKING_AMOUNT;

    uint256 public EXIT_BLOCKS;

    function initialize() external initializer {
        PROVIDER_MINIMUM_STAKING = 100000 ether;
        REQUESTER_MINIMUM_POOL_STAKING = 500 finney;
        ETHEREUM_STAKING_AMOUNT = 4 ether;
        EXIT_BLOCKS = 24;
    }
}
pragma solidity ^0.6.0;

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

contract Governable is Initializable {
    address public governor;

    event GovernorshipTransferred(address indexed previousGovernor, address indexed newGovernor);

    /**
     * @dev Contract initializer.
     * called once by the factory at time of deployment
     */
    function initialize(address governor_) virtual public initializer {
        governor = governor_;
        emit GovernorshipTransferred(address(0), governor);
    }

    modifier governance() {
        require(msg.sender == governor);
        _;
    }

    /**
     * @dev Allows the current governor to relinquish control of the contract.
     * @notice Renouncing to governorship will leave the contract without an governor.
     * It will not be possible to call the functions with the `governance.js`
     * modifier anymore.
     */
    function renounceGovernorship() public governance {
        emit GovernorshipTransferred(governor, address(0));
        governor = address(0);
    }

    /**
     * @dev Allows the current governor to transfer control of the contract to a newGovernor.
     * @param newGovernor The address to transfer governorship to.
     */
    function transferGovernorship(address newGovernor) public governance {
        _transferGovernorship(newGovernor);
    }

    /**
     * @dev Transfers control of the contract to a newGovernor.
     * @param newGovernor The address to transfer governorship to.
     */
    function _transferGovernorship(address newGovernor) internal {
        require(newGovernor != address(0));
        emit GovernorshipTransferred(governor, newGovernor);
        governor = newGovernor;
    }

    uint256[50] private __gap;
}
