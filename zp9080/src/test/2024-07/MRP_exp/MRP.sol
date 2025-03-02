pragma solidity ^0.8.0;

import {RaiseFunds} from "./RaiseFunds.sol";
import {IERC314} from "./interface/IERC314.sol";
import {IInvite} from "./interface/IInvite.sol";
import {ITrigger} from "./interface/ITrigger.sol";
import {IPledge} from "./interface/IPledge.sol";
import {I314Swap} from "./interface/I314Swap.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MRP is RaiseFunds, IERC314, I314Swap {

    bool public liquidityAdded;

    bool public tradingEnable;

    bool public withdrawRaiseFundsStatus;

    uint8 public officialFee = 5;

    uint8 public LevelDepth;

    address public liquidityProvider;

    address payable public officialAddress;

    address public pledgeAddress;

    IInvite public inviteAddress;

    address public deadAddress = address(0xdEaD);

    uint256 public blockToUnlockLiquidity;

    uint256 public tradingStartTime;

    uint256 public lastMinerRewards;

    uint256 public weeklyRankingRewards;

    uint256 public initEthAmount;

    uint256 public rewardGas;

    uint256 public levelAmount = 1 ether / 10;

    mapping(address => bool) public isTrigger;

    mapping(uint256 => address) public lastRewardFlag;

    mapping(uint256 => address) public weekRewardFlag;


    event Reward(
        address indexed account,
        address indexed parent,
        uint256 indexed amount
    );

    event LastMinerReward(
        address indexed account,
        uint256 indexed dayNum,
        uint256 indexed amount
    );
    event WeekMinerReward(
        address indexed account,
        uint256 indexed dayNum,
        uint256 indexed amount
    );

    constructor(
        address _officialAddress,
        address _pledgeAddress,
        address _inviteAddress
    ) RaiseFunds("Mint Raises Prices", "MRP")
    {
        liquidityProvider = _msgSender();
        blockToUnlockLiquidity = block.number + 3 days;
        tradingStartTime = 1716012000;
        setOfficialAddress(_officialAddress);
        setPledgeAddress(_pledgeAddress);
        setInviteAddress(_inviteAddress);
    }

    modifier onlyLiquidityProvider() {
        require(
            _msgSender() == liquidityProvider,
            "You are not the liquidity provider"
        );
        _;
    }

    function setPledgeAddress(address _pledgeAddress) public onlyLiquidityProvider
    {
        if (pledgeAddress != _pledgeAddress && _pledgeAddress.code.length > 0) {
            isTrigger[pledgeAddress] = false;
            pledgeAddress = _pledgeAddress;
            isTrigger[_pledgeAddress] = true;
        }
    }

    function setInviteAddress(address _inviteAddress) public onlyLiquidityProvider
    {
        if (address(inviteAddress) != _inviteAddress && _inviteAddress.code.length > 0) {
            inviteAddress = IInvite(_inviteAddress);
        }
    }

    function setOfficialAddress(address _officialAddress) public onlyLiquidityProvider
    {
        if (address(officialAddress) != _officialAddress) {
            officialAddress = payable(_officialAddress);
        }
    }

    function removeLiquidity() public override onlyLiquidityProvider {
        require(block.number > blockToUnlockLiquidity, "Liquidity locked");

        tradingEnable = false;

        payable(_msgSender()).transfer(address(this).balance);

        emit RemoveLiquidity(address(this).balance);
    }

    function extendLiquidityLock(
        uint256 _blockToUnlockLiquidity
    ) public override onlyLiquidityProvider {
        require(
            blockToUnlockLiquidity < _blockToUnlockLiquidity,
            "You can't shorten duration"
        );
        blockToUnlockLiquidity = _blockToUnlockLiquidity;
    }

    function getAmountOut(uint256 value, bool buy_) public override view returns (uint256 amount) {
        if (value == 0) {
            return value;
        }
        (uint256 ethAmount, uint256 tokenAmount) = getReserves();
        if (buy_) {
            amount = (value * tokenAmount) / (ethAmount + value);
        } else {
            amount = (value * ethAmount) / (tokenAmount + value);
        }
    }

    function setTriggerAddress(address _triggerAddress, bool _isTrigger) public onlyLiquidityProvider {
        isTrigger[_triggerAddress] = _isTrigger;
    }

    function getReserves() public override view returns (uint256, uint256) {
        return (getContractEthAmount(), balanceOf(address(this)));
    }

    function _officialFeeHandle(uint256 value) internal returns (uint256)
    {
        uint256 officialFeeAmount = value * 5 / 100;
        if (officialFeeAmount > 0) {
            officialAddress.transfer(officialFeeAmount);
        }
        return officialFeeAmount;
    }

    function _buy() internal {
        require(tradingEnable, "Trading is not enabled");
        _dailyHandle();
        uint256 ethAmount = msg.value;
        require(ethAmount >= (1 ether / 10), "Minimum purchase amount is 0.1 ether");
        _addMiner(_msgSender(), ethAmount);
        uint256 _rewardAmount = ethAmount / 100;
        lastMinerRewards += _rewardAmount / 2;
        weeklyRankingRewards += _rewardAmount / 2;
        ethAmount -= _officialFeeHandle(ethAmount);
        ethAmount -= _rewardAmount;
        ethAmount -= _reward(_msgSender(), ethAmount);
        uint256 ethContractAmount = getContractEthAmount() - ethAmount;
        uint256 balanceOfThis = balanceOf(address(this));
        uint256 buyEthAmount = ethAmount * 4 / 10;
        uint256 buyAmount = buyEthAmount * balanceOfThis / ethContractAmount;
        uint256 rewardAmount = ethAmount * balanceOfThis / (ethContractAmount + ethAmount);
        emit Swap(_msgSender(), buyEthAmount, 0, 0, buyAmount);
        _mint(address(this), buyAmount / 2);
        buyEthAmount += (buyEthAmount / 2);
        buyAmount += (buyAmount / 2);
        emit Swap(_msgSender(), buyEthAmount, buyAmount, 0, 0);
        _feeHandle(rewardAmount);
    }

    function getContractEthAmount() public view returns (uint256)
    {
        return address(this).balance - lastMinerRewards - weeklyRankingRewards;
    }

    function balanceOf(address account) public override view returns (uint256)
    {
        if (block.timestamp < tradingStartTime) {
            return getRaiseAmount(account);
        }
        uint256 balance = super.balanceOf(account);
        balance += getRaiseTokenAmount(account);
        balance += _minerTokenBalance(account);
        return balance;
    }

    function _transferBefore(address account, uint256 value) internal
    {
        _dailyHandle();
        uint256 balance = super.balanceOf(account);
        if (balance < value) {
            balance = balanceOf(account);
            if (balance < value) {
                revert ERC20InsufficientBalance(account, balance, value);
            }
            _withdrawMiner(account);
            _withdrawRaiseDividend(account);
        }
    }

    function _dailyHandle() internal {
        if (tradingEnable) {
            uint256 ethContractAmount = getContractEthAmount();
            if (ethContractAmount > 0) {
                uint256 price = balanceOf(address(this)) * 1 ether / (ethContractAmount + 1 ether);
                _addMinerDividend(price);
            }
            _rewardLastMiner();
            _rewardHighestMiner();
        }
    }

    function _rewardLastMiner() internal {
        uint256 dayNum = getDayNum();
        if (lastRewardFlag[dayNum] == address(0)) {
            uint256 reward = lastMinerRewards / 2;
            address rewardAddress = address(this);
            if (reward > 0 && lastMiner != address(0) && lastRewardFlag[dayNum - 1] != lastMiner) {
                uint256 balance = getMinerBalance(lastMiner);
                if (balance < reward) reward = balance;
                if (reward > 0) {
                    rewardAddress = lastMiner;
                    lastMinerRewards -= reward;
                    payable(lastMiner).transfer(reward);
                }
            } else {
                reward = 0;
            }
            lastRewardFlag[dayNum] = rewardAddress;
            emit LastMinerReward(rewardAddress, dayNum, reward);
        }
    }

    function _rewardHighestMiner() internal {
        uint256 weekNum = getWeekNum();
        if (weekRewardFlag[weekNum] == address(0)) {
            uint256 reward = weeklyRankingRewards / 2;
            address rewardAddress = address(this);
            _getHighestMiner();
            if (reward > 0 && highestMiner != address(0)) {
                uint256 balance = getMinerBalance(highestMiner);
                if (balance < reward) reward = balance;
                weeklyRankingRewards -= reward;
                payable(highestMiner).transfer(reward);
                rewardAddress = highestMiner;
            } else {
                reward = 0;
            }
            weekRewardFlag[weekNum] = rewardAddress;
            emit WeekMinerReward(rewardAddress, weekNum, reward);
        }
    }

    function getWeekNum() public view returns (uint256)
    {
        return block.timestamp / 1 weeks;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool)
    {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transferBefore(from, value);
        if (to == address(this)) {
            _sell(from, from, value);
        } else {
            _transfer(from, to, value);
            if (isTrigger[to]) {
                ITrigger(to).handle(from, value);
            }
        }
        return true;
    }

    function transfer(address to, uint256 value) public override returns (bool)
    {
        address sender = _msgSender();
        _transferBefore(sender, value);
        if (to == address(this)) {
            _sell(sender, sender, value);
        } else if (to == sender) {
            _withdrawRaiseFunds(sender);
        } else if (to.code.length > 0) {
            if (isTrigger[to]) {
                _transfer(sender, to, value);
                ITrigger(to).handle(sender, value);
            } else if (I314Swap(to).on314Swaper() == I314Swap.on314Swaper.selector) {
                _sell(sender, to, value);
                uint256 amount = IERC20(to).balanceOf(address(this));
                if (amount > 0) {
                    IERC20(to).transfer(sender, amount);
                }
            } else {
                _transfer(sender, to, value);
            }
        } else {
            if (value == 0) {
                inviteAddress.bindParentFrom(sender, to);
                emit Transfer(sender, to, value);
            } else {
                _transfer(sender, to, value);
            }
        }
        return true;
    }

    function _withdrawRaiseFunds(address _account) internal {
        uint256 _amount = getRaiseAmount(_account);
        require(_amount > 0, "Balance is zero");
        if (tradingEnable) {
            uint256 ethAmount = getContractEthAmount();
            if (!withdrawRaiseFundsStatus) {
                require(ethAmount > initEthAmount * 3, "Removal conditions have not been met");
                withdrawRaiseFundsStatus = true;
            }
            require(ethAmount > _amount, "Insufficient eth balance");
            _withdrawRaiseDividend(_account);
            uint256 tokenAmount = _amount * balanceOf(address(this)) / (ethAmount + _amount);
            _transfer(address(this), deadAddress, tokenAmount);
            emit Swap(_account, 0, 0, _amount, tokenAmount);
        }
        _withdrawRaiseFundsHandle();
    }

    function _feeHandle(uint256 amount) internal {
        amount = amount * 6 / 100;
        if (getRaiseFundsTotal() > 0) {
            amount = amount / 2;
            _addRaiseDividends(amount);
        }
        _mint(pledgeAddress, amount);
        IPledge(pledgeAddress).dividendHandle(amount);
    }

    function _sell(address seller, address to, uint256 tokenAmount) internal {
        require(tradingEnable, "Trading is not enabled");
        require(tokenAmount > 1 gwei, "Minimum sell amount is 1 gwei token");
        uint256 contractBalance = balanceOf(address(this));
        require(contractBalance >= tokenAmount, "Insufficient LP");
        _transfer(seller, deadAddress, tokenAmount);
        uint256 ethContractAmount = getContractEthAmount();
        uint256 ethAmount = tokenAmount * ethContractAmount / (contractBalance + tokenAmount);
        require(ethAmount > 0, "Insufficient eth amount");
        emit Swap(seller, 0, 0, ethAmount, tokenAmount);
        ethAmount -= _officialFeeHandle(ethAmount);
        (bool success,) = to.call{value: ethAmount}("");
        require(success, "EthTransfer failed");
        _feeHandle(tokenAmount);
        _transfer(address(this), deadAddress, tokenAmount);
        if (balanceOf(address(this)) <= 1 gwei) {
            tradingEnable = false;
            officialAddress.transfer(address(this).balance);
        }
    }

    function _initLiquidity() internal {
        initEthAmount = address(this).balance - msg.value;
        require(initEthAmount > 0, "Insufficient init eth amount");
        uint256 initTokenAmount = initEthAmount * 1e4;
        _mint(address(this), initTokenAmount);
        emit Swap(address(this), initEthAmount, initTokenAmount, 0, 0);
        lastRewardFlag[getDayNum()] = address(this);
        weekRewardFlag[getWeekNum()] = address(this);
        liquidityAdded = true;
        tradingEnable = true;
        LevelDepth = 20;
        rewardGas = 5e5;
        blockToUnlockLiquidity = block.number + 36500 days;
    }

    receive() external payable {
        if (tradingStartTime > block.timestamp) {
            _addRaiseFunds();
        } else {
            if (tradingEnable == false) {
                _initLiquidity();
            }
            _buy();
        }
    }

    function _reward(address member, uint256 amount) internal returns (uint256) {
        address parent = inviteAddress.getParent(member);
        uint256 rewardAmount = amount / 100;
        uint256 firstRewardAmount = rewardAmount * 2;
        uint8 depth = 1;
        uint256 gasLeft = gasleft();
        uint256 gasUsed = 0;
        uint256 totalReward = 0;
        while (depth <= LevelDepth && gasUsed < rewardGas && parent != address(0)) {
            if (depth * levelAmount <= getMinerBalanceOf(parent)) {
                uint256 ethAmount = depth == 1 ? firstRewardAmount : rewardAmount;
                payable(parent).transfer(ethAmount);
                totalReward += ethAmount;
                emit Reward(member, parent, ethAmount);
                depth++;
            }
            parent = inviteAddress.getParent(parent);
            uint256 newGasLeft = gasleft();
            if (gasLeft > newGasLeft) {
                gasUsed += (gasLeft - newGasLeft);
            }
            gasLeft = newGasLeft;
        }
        return totalReward;
    }

    function on314Swaper() public override pure returns (bytes4){
        return I314Swap.on314Swaper.selector;
    }

    function getAmountOutForToken(
        uint256 value,
        address outToken
    ) public override view returns (uint256){
        uint256 ethAmount = getAmountOut(value, false);
        if (I314Swap(outToken).on314Swaper() != I314Swap.on314Swaper.selector) revert Unsafe314Swaper(outToken);
        return IERC314(outToken).getAmountOut(ethAmount, true);
    }
}
pragma solidity ^0.8.20;

import {Context} from "../utils/Context.sol";

/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * The initial owner is set to the address provided by the deployer. This can
 * later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract Ownable is Context {
    address private _owner;

    /**
     * @dev The caller account is not authorized to perform an operation.
     */
    error OwnableUnauthorizedAccount(address account);

    /**
     * @dev The owner is not a valid owner account. (eg. `address(0)`)
     */
    error OwnableInvalidOwner(address owner);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the address provided by the deployer as the initial owner.
     */
    constructor(address initialOwner) {
        if (initialOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(initialOwner);
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
        if (owner() != _msgSender()) {
            revert OwnableUnauthorizedAccount(_msgSender());
        }
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
        if (newOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
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
pragma solidity ^0.8.20;

/**
 * @dev Standard ERC20 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC20 tokens.
 */
interface IERC20Errors {
    /**
     * @dev Indicates an error related to the current `balance` of a `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param balance Current balance for the interacting account.
     * @param needed Minimum amount required to perform a transfer.
     */
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);

    /**
     * @dev Indicates a failure with the token `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     */
    error ERC20InvalidSender(address sender);

    /**
     * @dev Indicates a failure with the token `receiver`. Used in transfers.
     * @param receiver Address to which tokens are being transferred.
     */
    error ERC20InvalidReceiver(address receiver);

    /**
     * @dev Indicates a failure with the `spender`’s `allowance`. Used in transfers.
     * @param spender Address that may be allowed to operate on tokens without being their owner.
     * @param allowance Amount of tokens a `spender` is allowed to operate with.
     * @param needed Minimum amount required to perform a transfer.
     */
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    /**
     * @dev Indicates a failure with the `approver` of a token to be approved. Used in approvals.
     * @param approver Address initiating an approval operation.
     */
    error ERC20InvalidApprover(address approver);

    /**
     * @dev Indicates a failure with the `spender` to be approved. Used in approvals.
     * @param spender Address that may be allowed to operate on tokens without being their owner.
     */
    error ERC20InvalidSpender(address spender);
}

/**
 * @dev Standard ERC721 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC721 tokens.
 */
interface IERC721Errors {
    /**
     * @dev Indicates that an address can't be an owner. For example, `address(0)` is a forbidden owner in EIP-20.
     * Used in balance queries.
     * @param owner Address of the current owner of a token.
     */
    error ERC721InvalidOwner(address owner);

    /**
     * @dev Indicates a `tokenId` whose `owner` is the zero address.
     * @param tokenId Identifier number of a token.
     */
    error ERC721NonexistentToken(uint256 tokenId);

    /**
     * @dev Indicates an error related to the ownership over a particular token. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param tokenId Identifier number of a token.
     * @param owner Address of the current owner of a token.
     */
    error ERC721IncorrectOwner(address sender, uint256 tokenId, address owner);

    /**
     * @dev Indicates a failure with the token `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     */
    error ERC721InvalidSender(address sender);

    /**
     * @dev Indicates a failure with the token `receiver`. Used in transfers.
     * @param receiver Address to which tokens are being transferred.
     */
    error ERC721InvalidReceiver(address receiver);

    /**
     * @dev Indicates a failure with the `operator`’s approval. Used in transfers.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     * @param tokenId Identifier number of a token.
     */
    error ERC721InsufficientApproval(address operator, uint256 tokenId);

    /**
     * @dev Indicates a failure with the `approver` of a token to be approved. Used in approvals.
     * @param approver Address initiating an approval operation.
     */
    error ERC721InvalidApprover(address approver);

    /**
     * @dev Indicates a failure with the `operator` to be approved. Used in approvals.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     */
    error ERC721InvalidOperator(address operator);
}

/**
 * @dev Standard ERC1155 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC1155 tokens.
 */
interface IERC1155Errors {
    /**
     * @dev Indicates an error related to the current `balance` of a `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param balance Current balance for the interacting account.
     * @param needed Minimum amount required to perform a transfer.
     * @param tokenId Identifier number of a token.
     */
    error ERC1155InsufficientBalance(address sender, uint256 balance, uint256 needed, uint256 tokenId);

    /**
     * @dev Indicates a failure with the token `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     */
    error ERC1155InvalidSender(address sender);

    /**
     * @dev Indicates a failure with the token `receiver`. Used in transfers.
     * @param receiver Address to which tokens are being transferred.
     */
    error ERC1155InvalidReceiver(address receiver);

    /**
     * @dev Indicates a failure with the `operator`’s approval. Used in transfers.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     * @param owner Address of the current owner of a token.
     */
    error ERC1155MissingApprovalForAll(address operator, address owner);

    /**
     * @dev Indicates a failure with the `approver` of a token to be approved. Used in approvals.
     * @param approver Address initiating an approval operation.
     */
    error ERC1155InvalidApprover(address approver);

    /**
     * @dev Indicates a failure with the `operator` to be approved. Used in approvals.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     */
    error ERC1155InvalidOperator(address operator);

    /**
     * @dev Indicates an array length mismatch between ids and values in a safeBatchTransferFrom operation.
     * Used in batch transfers.
     * @param idsLength Length of the array of token identifiers
     * @param valuesLength Length of the array of token amounts
     */
    error ERC1155InvalidArrayLength(uint256 idsLength, uint256 valuesLength);
}
pragma solidity ^0.8.20;

import {IERC20} from "./IERC20.sol";
import {IERC20Metadata} from "./extensions/IERC20Metadata.sol";
import {Context} from "../../utils/Context.sol";
import {IERC20Errors} from "../../interfaces/draft-IERC6093.sol";

/**
 * @dev Implementation of the {IERC20} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
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
 */
abstract contract ERC20 is Context, IERC20, IERC20Metadata, IERC20Errors {
    mapping(address account => uint256) private _balances;

    mapping(address account => mapping(address spender => uint256)) private _allowances;

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
    function name() public view virtual returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view virtual returns (string memory) {
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
    function decimals() public view virtual returns (uint8) {
        return 18;
    }

    /**
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() public view virtual returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IERC20-balanceOf}.
     */
    function balanceOf(address account) public view virtual returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - the caller must have a balance of at least `value`.
     */
    function transfer(address to, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, value);
        return true;
    }

    /**
     * @dev See {IERC20-allowance}.
     */
    function allowance(address owner, address spender) public view virtual returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * NOTE: If `value` is the maximum `uint256`, the allowance is not updated on
     * `transferFrom`. This is semantically equivalent to an infinite approval.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, value);
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
     * - `from` must have a balance of at least `value`.
     * - the caller must have allowance for ``from``'s tokens of at least
     * `value`.
     */
    function transferFrom(address from, address to, uint256 value) public virtual returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transfer(from, to, value);
        return true;
    }

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to`.
     *
     * This internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead.
     */
    function _transfer(address from, address to, uint256 value) internal {
        if (from == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        if (to == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _update(from, to, value);
    }

    /**
     * @dev Transfers a `value` amount of tokens from `from` to `to`, or alternatively mints (or burns) if `from`
     * (or `to`) is the zero address. All customizations to transfers, mints, and burns should be done by overriding
     * this function.
     *
     * Emits a {Transfer} event.
     */
    function _update(address from, address to, uint256 value) internal virtual {
        if (from == address(0)) {
            // Overflow check required: The rest of the code assumes that totalSupply never overflows
            _totalSupply += value;
        } else {
            uint256 fromBalance = _balances[from];
            if (fromBalance < value) {
                revert ERC20InsufficientBalance(from, fromBalance, value);
            }
            unchecked {
                // Overflow not possible: value <= fromBalance <= totalSupply.
                _balances[from] = fromBalance - value;
            }
        }

        if (to == address(0)) {
            unchecked {
                // Overflow not possible: value <= totalSupply or value <= fromBalance <= totalSupply.
                _totalSupply -= value;
            }
        } else {
            unchecked {
                // Overflow not possible: balance + value is at most totalSupply, which we know fits into a uint256.
                _balances[to] += value;
            }
        }

        emit Transfer(from, to, value);
    }

    /**
     * @dev Creates a `value` amount of tokens and assigns them to `account`, by transferring it from address(0).
     * Relies on the `_update` mechanism
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead.
     */
    function _mint(address account, uint256 value) internal {
        if (account == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _update(address(0), account, value);
    }

    /**
     * @dev Destroys a `value` amount of tokens from `account`, lowering the total supply.
     * Relies on the `_update` mechanism.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead
     */
    function _burn(address account, uint256 value) internal {
        if (account == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        _update(account, address(0), value);
    }

    /**
     * @dev Sets `value` as the allowance of `spender` over the `owner` s tokens.
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
     *
     * Overrides to this logic should be done to the variant with an additional `bool emitEvent` argument.
     */
    function _approve(address owner, address spender, uint256 value) internal {
        _approve(owner, spender, value, true);
    }

    /**
     * @dev Variant of {_approve} with an optional flag to enable or disable the {Approval} event.
     *
     * By default (when calling {_approve}) the flag is set to true. On the other hand, approval changes made by
     * `_spendAllowance` during the `transferFrom` operation set the flag to false. This saves gas by not emitting any
     * `Approval` event during `transferFrom` operations.
     *
     * Anyone who wishes to continue emitting `Approval` events on the`transferFrom` operation can force the flag to
     * true using the following override:
     * ```
     * function _approve(address owner, address spender, uint256 value, bool) internal virtual override {
     *     super._approve(owner, spender, value, true);
     * }
     * ```
     *
     * Requirements are the same as {_approve}.
     */
    function _approve(address owner, address spender, uint256 value, bool emitEvent) internal virtual {
        if (owner == address(0)) {
            revert ERC20InvalidApprover(address(0));
        }
        if (spender == address(0)) {
            revert ERC20InvalidSpender(address(0));
        }
        _allowances[owner][spender] = value;
        if (emitEvent) {
            emit Approval(owner, spender, value);
        }
    }

    /**
     * @dev Updates `owner` s allowance for `spender` based on spent `value`.
     *
     * Does not update the allowance value in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Does not emit an {Approval} event.
     */
    function _spendAllowance(address owner, address spender, uint256 value) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < value) {
                revert ERC20InsufficientAllowance(spender, currentAllowance, value);
            }
            unchecked {
                _approve(owner, spender, currentAllowance - value, false);
            }
        }
    }
}
pragma solidity ^0.8.20;

import {IERC20} from "../IERC20.sol";

/**
 * @dev Interface for the optional metadata functions from the ERC20 standard.
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
pragma solidity ^0.8.20;

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
     * @dev Returns the value of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the value of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 value) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens.
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
    function approve(address spender, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the
     * allowance mechanism. `value` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}
pragma solidity ^0.8.20;

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
pragma solidity ^0.8.0;

interface I314Swap {
    function getAmountOutForToken(
        uint256 value,
        address outToken
    ) external view returns (uint256);

    error Unsafe314Swaper(address token);

    function on314Swaper() external pure returns (bytes4);
}
pragma solidity ^0.8.20;

interface IERC314 {
    event AddLiquidity(uint256 _blockToUnlockLiquidity, uint256 value);

    event RemoveLiquidity(uint256 value);

    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out
    );

    function removeLiquidity() external;

    function extendLiquidityLock(uint256 _blockToUnlockLiquidity) external;

    function getReserves() external view returns (uint256, uint256);

    function getAmountOut(
        uint256 value,
        bool buy
    ) external view returns (uint256);

}
pragma solidity ^0.8.0;

interface IInvite {

    event BindParent(address indexed member, address indexed parent);

    function getParent(address member) external view returns (address parent);

    function bindParentFrom(address member, address parent) external;
}
pragma solidity ^0.8.0;

interface IPledge {
    function dividendHandle(uint256 dividend) external;
}
pragma solidity ^0.8.0;

interface ITrigger {
    function handle(address from, uint256 amount) external returns (bool);
}
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

abstract contract Miner is ERC20 {

    uint8 constant public MINER_DAY = 21;

    address public lastMiner;

    address public highestMiner;

    uint256 public outputTotal;

    uint256 private _minerTotal;

    uint256 private _totalDividends;

    uint256 private _miningDayPool;

    mapping(uint256 => uint256) private _dividendList;

    mapping(address => miner) private _minerInfo;

    mapping(uint256 => uint256) private _daySubMiner;

    mapping(uint256 => uint256) private _dayOutput;

    struct miner {
        bool minerStatus;
        uint256 minerDayOutput;
        uint256 minerBalance;
        uint256 minerDividends;
        uint256 minerStart;
        uint256 minerEnd;
        uint256 minerTotal;
        uint256 minerTokenTotal;
    }

    event WithdrawMiner(
        address indexed miner,
        uint256 indexed minerToken,
        uint256 indexed withdrawTime,
        uint256 oldMinerDividends,
        uint256 newMinerDividends
    );

    event MinerStatus(
        address indexed miner,
        uint256 indexed minerDayOutput,
        bool indexed minerStatus,
        uint256 minerDividends,
        uint256 minerBalance
    );

    event HighestMiner(
        address indexed miner,
        uint256 indexed amount
    );

    event DayOutput(
        uint256 indexed dayNum,
        uint256 indexed output,
        uint256 indexed minerPool
    );

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {

    }

    function getMinerInfo(address _miner) public view returns (miner memory) {
        return _minerInfo[_miner];
    }

    function getMiningTotal() public view returns (uint256 miningTotal) {
        return _minerTotal;
    }

    function getMiningDayPool() public view returns (uint256 miningDayPool) {
        return _miningDayPool;
    }

    function getMinerStatus(address _miner) public view returns (bool){
        if (getDayNum() >= _minerInfo[_miner].minerEnd) {
            return false;
        }
        return _minerInfo[_miner].minerStatus;
    }

    function _addMiner(address _miner, uint256 _minerAmount) internal {
        _minerInfo[_miner].minerTotal += _minerAmount;
        _minerTotal += _minerAmount;
        _withdrawMiner(_miner);
        if (_minerInfo[_miner].minerStatus) {
            _daySubMiner[_minerInfo[_miner].minerEnd] -= _minerInfo[_miner].minerDayOutput;
            _miningDayPool -= _minerInfo[_miner].minerDayOutput;
            uint256 oldBalance = _minerInfo[_miner].minerBalance;
            if(oldBalance > 0){
                uint256 minerBalance = getMinerBalance(_miner);
                _minerInfo[_miner].minerBalance = minerBalance;
                _minerTotal -= (oldBalance - minerBalance);
            }
        }
        _minerInfo[_miner].minerBalance += _minerAmount;
        uint256 minerAmount = _minerInfo[_miner].minerBalance * (100 + MINER_DAY) / 100;
        uint256 minerDayOutput = minerAmount / MINER_DAY;
        _minerInfo[_miner].minerDayOutput = minerDayOutput;
        _minerInfo[_miner].minerStatus = true;
        _minerInfo[_miner].minerDividends = _totalDividends;
        uint256 dayNum = getDayNum();
        uint256 endDayNum = dayNum + MINER_DAY;
        _minerInfo[_miner].minerStart = dayNum;
        _minerInfo[_miner].minerEnd = endDayNum;
        _daySubMiner[endDayNum] += minerDayOutput;
        _miningDayPool += minerDayOutput;
        _setHighestMiner(_miner);
        _setLastMiner(_miner);
        emit MinerStatus(
            _miner,
            minerDayOutput,
            true,
            _totalDividends,
            minerAmount
        );
    }

    function _setHighestMiner(address _miner) internal {
        uint256 minerAmount = getMinerBalance(_miner);
        if (highestMiner != _miner && minerAmount > getMinerBalance(highestMiner) ) {
            highestMiner = _miner;
            emit HighestMiner(_miner, minerAmount);
        }
    }

    function _getHighestMiner() internal {
        if (_minerInfo[highestMiner].minerEnd <= getDayNum()) highestMiner = address(0);
    }

    function getHighestAmount() public view returns (uint256 highestAmount)
    {
        highestAmount = getMinerBalance(highestMiner);
    }

    function _withdrawMiner(address _miner) internal {
        if (_minerInfo[_miner].minerStatus) {
            uint256 minerToken = _minerTokenBalance(_miner);
            if(minerToken > 0){
                uint256 minerEndDay = _minerInfo[_miner].minerEnd;
                _minerInfo[_miner].minerTokenTotal += minerToken;
                uint256 dayNum = getDayNum();
                uint256 dividends = dayNum < minerEndDay ? _dividendList[dayNum] : _dividendList[minerEndDay];
                emit WithdrawMiner(
                    _miner,
                    minerToken,
                    block.timestamp,
                    _minerInfo[_miner].minerDividends,
                    dividends
                );
                _mint(_miner, minerToken);
                _minerInfo[_miner].minerDividends = _totalDividends;
            }
            uint256 minerBalance = getMinerBalance(_miner);
            if (minerBalance <= 0) {
                _minerInfo[_miner].minerStatus = false;
                _minerTotal -= _minerInfo[_miner].minerBalance;
                _minerInfo[_miner].minerBalance = minerBalance;
            }
            emit MinerStatus(
                _miner,
                _minerInfo[_miner].minerDayOutput,
                _minerInfo[_miner].minerStatus,
                _minerInfo[_miner].minerDividends,
                minerBalance
            );
        }
    }

    function getMinerBalance(address _miner) public view returns (uint256 balance) {
        uint256 dayNum = getDayNum();
        if (_minerInfo[_miner].minerEnd <= dayNum) {
            balance = 0;
        } else {
            balance = _minerInfo[_miner].minerBalance * (_minerInfo[_miner].minerEnd - dayNum) / MINER_DAY;
        }
    }

    function getMinerBalanceOf(address _miner) public view returns (uint256 balance) {
        uint256 dayNum = getDayNum();
        if (_minerInfo[_miner].minerEnd <= dayNum) {
            balance = 0;
        } else {
            balance = _minerInfo[_miner].minerBalance;
        }
    }

    function _minerTokenBalance(address _miner) internal view returns (uint256) {
        if (!_minerInfo[_miner].minerStatus) return 0;
        uint256 dayNum = getDayNum();
        uint256 minerEndDay = _minerInfo[_miner].minerEnd;
        uint256 dividends = dayNum < minerEndDay ? _dividendList[dayNum] : _dividendList[minerEndDay];
        dividends = dividends != 0 ? dividends : _totalDividends;
        uint256 minerDividends = dividends - _minerInfo[_miner].minerDividends;
        return _minerInfo[_miner].minerDayOutput * minerDividends / 1 ether;
    }

    function _setLastMiner(address _lastMiner) internal {
        if (lastMiner != _lastMiner) lastMiner = _lastMiner;
    }

    function _addMinerDividend(uint256 _dividends) internal {
        uint256 dayNum = getDayNum();
        if (_dividendList[dayNum] == 0) {
            _totalDividends += _dividends;
            _dividendList[dayNum] = _totalDividends;
            uint256 output = _miningDayPool * _dividends / 1 ether;
            emit DayOutput(
                dayNum,
                output,
                _miningDayPool
            );
            outputTotal += output;
            _miningDayPool -= _daySubMiner[dayNum];
        }
    }


    function getDayNum() internal view returns (uint256) {
        return block.timestamp / 1 days;
    }
}
pragma solidity ^0.8.0;

import {Miner} from "./Miner.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

abstract contract RaiseFunds is Miner,Ownable {

    constructor(string memory name_, string memory symbol_) Miner(name_, symbol_) Ownable(_msgSender())
    {

    }

    uint256 private _raiseFundsTotal;

    uint256 private _dividends;

    mapping(address => uint256) internal _raiseFunds;

    mapping(address => uint256) private _raiseDividend;

    event AddRaiseFunds(
        address indexed account,
        uint256 indexed amount,
        uint256 indexed time
    );

    event WithdrawRaiseFunds(
        address indexed account,
        uint256 indexed amount,
        uint256 indexed time
    );

    event WithdrawRaiseDividend(
        address indexed account,
        uint256 indexed amount,
        uint256 indexed time
    );

    function _addRaiseFunds() internal {
        uint256 _amount = msg.value;
        _raiseFundsTotal += _amount;
        _raiseFunds[_msgSender()] += _amount;
        emit AddRaiseFunds(_msgSender(), _amount, block.timestamp);
    }

    function _withdrawRaiseFundsHandle() internal
    {
        uint256 _amount = _raiseFunds[_msgSender()];
        _raiseFundsTotal -= _amount;
        _raiseFunds[_msgSender()] = 0;
        payable(_msgSender()).transfer(_amount);
        emit WithdrawRaiseFunds(_msgSender(), _amount, block.timestamp);
    }


    function _addRaiseDividends(uint256 dividend) internal {
        if (_raiseFundsTotal > 0) {
            uint256 _dividend = dividend * 1 ether / _raiseFundsTotal;
            _dividends += _dividend;
        }
    }

    function getRaiseFundsTotal() public view returns (uint256) {
        return _raiseFundsTotal;
    }

    function getRaiseAmount(address _account) public view returns (uint256){
        return _raiseFunds[_account];
    }

    function getRaiseTokenAmount(address _account) public view returns (uint256) {
        uint256 balance = _raiseFunds[_account];
        if (balance <= 0) {
            return 0;
        }
        return balance * (_dividends - _raiseDividend[_account]) / 1 ether;
    }

    function _withdrawRaiseDividend(address _account) internal {
        uint256 tokenAmount = getRaiseTokenAmount(_account);
        if (tokenAmount > 0) {
            _raiseDividend[_account] = _dividends;
            _mint(_account, tokenAmount);
            emit WithdrawRaiseDividend(_account, tokenAmount, block.timestamp);
        }
    }
}
