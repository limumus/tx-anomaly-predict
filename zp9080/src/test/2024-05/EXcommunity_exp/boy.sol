pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {ITokenDistributor} from "./interfaces/ITokenDistributor.sol";
import {ITokenFarm} from "./interfaces/ITokenFarm.sol";

interface IEERC314 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event AddLiquidity(uint32 blockToUnlockLiquidity, uint256 value);
    event RemoveLiquidity(uint256 value);
    event Swap(address indexed sender, uint256 amount0In, uint256 amount1In, uint256 amount0Out, uint256 amount1Out);

    error InvalidParameter();
    error InvalidSender();
    error InvalidReceiver();
    error InsufficientBalance();
    error BlockConflict();
    error DuplicateInitialization();
    error LiquidityLocked();
    error NotEnabled();
    error NotStarted();
    error ExceedMaxValue();
    error InsufficientOutputAmount();
}

contract EXboy is IEERC314, Ownable {
    uint256 internal constant PRECISION = 1e18;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant SECONDS_PER_DAY = 86400;
    uint256 internal constant SECONDS_PER_HOUR = 3600;

    mapping(address account => uint256) private _balances;
    mapping(address account => uint32) private lastTransaction;
    mapping(address => bool) public isExcludedFromFee;
    mapping(address => uint256) public lastTxTimes;

    bool public tradingEnable;
    bool public liquidityAdded;
    bool public maxWalletEnable;
    uint32 public blockToUnlockLiquidity;
    uint256 public _maxWallet;

    uint256 private _totalSupply;
    string private _name;
    string private _symbol;

    ITokenDistributor public tokenDistributor;
    ITokenFarm public tokenFarm;

    struct FeeInfo {
        uint256 transferFee;
        uint256 burnFee;
        address transferFeeReceiver;
    }
    FeeInfo public feeInfo;

    struct TxFeeInfo {
        uint96 feeRate;
        address feeReceiver;
    }
    TxFeeInfo[] internal _buyFeeInfos;
    TxFeeInfo[] internal _sellFeeInfos;

    uint256 public dailyOpenPrice;

    struct TimeManagement {
        uint256 nextBurnTime;
        uint256 nextOpenTime;
        uint256 whitelistTime;
    }
    TimeManagement public timeManagement; 

    struct AdvantageInfo {
        uint256 rebalanceRatio;
        uint256 maxTransferRatio;
        uint256 declinePercentage;
        uint256 rateMultiplier;
    }
    AdvantageInfo public advantageInfo;

    address public liquidityProvider;

    constructor(address liquidityProvider_) Ownable(msg.sender) {
        _name = "EXboy";
        _symbol = "EXboy";
        _mint(address(this), 50000e18);
        _mint(msg.sender, 2050000e18);

        isExcludedFromFee[msg.sender] = true;
        isExcludedFromFee[liquidityProvider_] = true;
        liquidityProvider = liquidityProvider_;
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
     * {IEERC314-balanceOf} and {IEERC314-transfer}.
     */
    function decimals() public view virtual returns (uint8) {
        return 18;
    }

    /**
     * @dev See {IEERC314-totalSupply}.
     */
    function totalSupply() public view virtual returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IEERC314-balanceOf}.
     */
    function balanceOf(address account) public view virtual returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev See {IEERC314-transfer}.
     *
     * Requirements:
     *
     * - the caller must have a balance of at least `value`.
     * - if the receiver is the contract, the caller must send the amount of tokens to sell
     */
    function transfer(address to, uint256 value) public virtual returns (bool) {
        if (to == address(this)) {
            sell(value);
        } else {
            _transfer(msg.sender, to, value);
        }
        return true;
    }

    /**
     * @dev Transfers a `value` amount of tokens from `from` to `to`, or alternatively burns if `to` is the zero address.
     * All customizations to transfers and burns should be done by overriding this function.
     * This function includes MEV protection, which prevents the same address from making two transactions in the same block.(lastTransaction)
     * Emits a {Transfer} event.
     */
    function _transfer(address from, address to, uint256 value) internal virtual {
        if (from == address(0)) {
            revert InvalidSender();
        }
        if (to == address(0)) {
            revert InvalidReceiver();
        }
        if (from == owner() || to == owner() || from == address(tokenDistributor) || to == address(tokenDistributor)) {
            _update(from, to, value);
            return;
        }
        // Update the daily opening price.
        if (timeManagement.nextOpenTime != 0 && block.timestamp > timeManagement.nextOpenTime) {
            timeManagement.nextOpenTime += SECONDS_PER_DAY;
            dailyOpenPrice = getPrice();
        }

        // The maximum allowable amount for transfers.
        if (from != address(this) && !isExcludedFromFee[from]) {
            uint256 maxTransferAmount = _getMaximumTransferAmount(from);
            if (value > maxTransferAmount) {
                value = maxTransferAmount;
            }
        }

        // Restrict consecutive transactions for each account.
        if (from == address(this) || to == address(this)) {
            address user = from == address(this) ? to : from;
            if (block.timestamp < timeManagement.whitelistTime && !tokenDistributor.isWhitelist(user)) {
                revert NotStarted();
            }
            
            if (lastTxTimes[user] != 0 && lastTxTimes[user] + 60 >= block.timestamp) {
                revert BlockConflict();
            }
            lastTxTimes[user] = block.timestamp;

            // transfer fee
        } else {
            if (!isExcludedFromFee[from] && !isExcludedFromFee[to]) {
                uint256 fee = value * feeInfo.transferFee / PRECISION;
                value -= fee;
                _update(from, feeInfo.transferFeeReceiver, fee);
            }
            
        }

        if (lastTransaction[from] == block.number) {
            revert BlockConflict();
        }
        lastTransaction[from] = uint32(block.number);

        uint256 fromBalance = _balances[from];
        if (fromBalance < value) {
            revert InsufficientBalance();
        }

        unchecked {
            _balances[from] = fromBalance - value;
            _balances[to] += value;
        }

        emit Transfer(from, to, value);

        if (from != address(this)) {
            tokenFarm.updateBal(from, balanceOf(from));
        }

        if (to != address(this)) {
            tokenFarm.updateBal(to, balanceOf(to));
        }
        
    }

    function _mint(address account, uint256 value) internal {
        _balances[account] += value;
        _totalSupply += value;
        emit Transfer(address(0), account, value);
    }

    function _burn(address account, uint256 value) internal {
        _balances[account] -= value;
        _totalSupply -= value;
        emit Transfer(account, address(0), value);
    }

    /**
     * @dev Returns the amount of ETH and tokens in the contract, used for trading.
     */
    function getReserves() public view returns (uint256, uint256) {
        return (address(this).balance, _balances[address(this)]);
    }

    /**
     * @dev Enables or disables trading.
     * @param _tradingEnable: true to enable trading, false to disable trading.
     * onlyOwner modifier
     */
    function enableTrading(bool _tradingEnable) external onlyOwner {
        tradingEnable = _tradingEnable;
    }

    /**
     * @dev Enables or disables the max wallet.
     * @param _maxWalletEnable: true to enable max wallet, false to disable max wallet.
     * onlyOwner modifier
     */
    function enableMaxWallet(bool _maxWalletEnable) external onlyOwner {
        maxWalletEnable = _maxWalletEnable;
    }

    /**
     * @dev Sets the max wallet.
     * @param _maxWallet_: the new max wallet.
     * onlyOwner modifier
     */
    function setMaxWallet(uint256 _maxWallet_) external onlyOwner {
        _maxWallet = _maxWallet_;
    }

    /**
     * @dev Adds liquidity to the contract.
     * @param _blockToUnlockLiquidity: the block number to unlock the liquidity.
     * value: the amount of ETH to add to the liquidity.
     * onlyOwner modifier
     */
    function addLiquidity(uint32 _blockToUnlockLiquidity) public payable virtual {
        require(msg.sender == liquidityProvider, "Not provider");
        if (liquidityAdded) {
            revert DuplicateInitialization();
        }
        liquidityAdded = true;

        if (msg.value <= 0) {
            revert InsufficientBalance();
        }

        if (block.number >= _blockToUnlockLiquidity) {
            revert InvalidParameter();
        }

        blockToUnlockLiquidity = _blockToUnlockLiquidity;
        tradingEnable = true;

        uint256 nextDay = block.timestamp + SECONDS_PER_DAY;
        timeManagement.nextBurnTime = nextDay;
        timeManagement.nextOpenTime = nextDay;
        timeManagement.whitelistTime = block.timestamp + SECONDS_PER_HOUR * 2;
        dailyOpenPrice = getPrice();

        emit AddLiquidity(_blockToUnlockLiquidity, msg.value);
    }

    /**
     * @dev Removes liquidity from the contract.
     */
    function removeLiquidity() public virtual {
        require(msg.sender == liquidityProvider, "Not provider");
        if (block.number <= blockToUnlockLiquidity) {
            revert LiquidityLocked();
        }

        tradingEnable = false;

        payable(msg.sender).transfer(address(this).balance);

        emit RemoveLiquidity(address(this).balance);
    }

    /**
     * @dev Extends the liquidity lock, only if the new block number is higher than the current one.
     * @param _blockToUnlockLiquidity: the new block number to unlock the liquidity.
     */
    function extendLiquidityLock(uint32 _blockToUnlockLiquidity) public onlyOwner {
        if (blockToUnlockLiquidity >= _blockToUnlockLiquidity) {
            revert InvalidParameter();
        }
        blockToUnlockLiquidity = _blockToUnlockLiquidity;
    }

    /**
     * @dev Estimates the amount of tokens or ETH to receive when buying or selling.
     * @param value: the amount of ETH or tokens to swap.
     * @param _buy: true if buying, false if selling.
     */
    function getAmountOut(uint256 value, bool _buy) public view returns (uint256) {
        (uint256 reserveETH, uint256 reserveToken) = getReserves();

        if (_buy) {
            return (value * reserveToken) / (reserveETH + value);
        } else {
            return (value * reserveETH) / (reserveToken + value);
        }
    }

    /**
     * @dev Buys tokens with ETH.
     */
    function buy() internal virtual {
        if (!tradingEnable) {
            revert NotEnabled();
        }

        uint256 tokenAmount = (msg.value * _balances[address(this)]) / (address(this).balance);
        if (tokenAmount <= 0) {
            revert InsufficientOutputAmount();
        }
        if (maxWalletEnable && tokenAmount + _balances[msg.sender] > _maxWallet) {
            revert ExceedMaxValue();
        }

        _transfer(address(this), msg.sender, tokenAmount);

        emit Swap(msg.sender, msg.value, 0, 0, tokenAmount);

        if (msg.sender != address(tokenDistributor)) {
            uint256 sellAmount = tokenAmount * advantageInfo.rebalanceRatio / PRECISION;
            tokenDistributor.distributeB(sellAmount);
        }
    }

    /**
     * @dev Sells tokens for ETH.
     */
    function sell(uint256 sellAmount) internal virtual {
        if (!tradingEnable) {
            revert NotEnabled();
        }

        if (!isExcludedFromFee[msg.sender]) {
            uint256 length = _sellFeeInfos.length;
            uint256 tempSellAmount = sellAmount;
            uint256 rateMultiplier = PRECISION;
            if (getPrice() <= dailyOpenPrice * advantageInfo.declinePercentage / PRECISION) {
                rateMultiplier = advantageInfo.rateMultiplier;
            }
            for (uint256 i = 0; i < length; i++) {
                uint256 feeRate = _sellFeeInfos[i].feeRate * rateMultiplier / PRECISION;
                uint256 fee = tempSellAmount * feeRate / PRECISION;
                sellAmount -= fee;
                _update(msg.sender, _sellFeeInfos[i].feeReceiver, fee);
            }
            
        }

        uint256 ethAmount = (sellAmount * address(this).balance) / (_balances[address(this)] + sellAmount);
        if (ethAmount <= 0) {
            revert InsufficientOutputAmount();
        }
        if (address(this).balance < ethAmount) {
            revert InsufficientBalance();
        }

        _transfer(msg.sender, address(this), sellAmount);
        payable(msg.sender).transfer(ethAmount);

        emit Swap(msg.sender, 0, sellAmount, ethAmount, 0);
    }

    function setTokenDistributor(address payable newTokenDistributor) external onlyOwner {
        tokenDistributor = ITokenDistributor(newTokenDistributor);
    }

    function setTokenFarm(address payable newTokenFarm) external onlyOwner {
        tokenFarm = ITokenFarm(newTokenFarm);
        tokenFarm.updateBal(owner(), balanceOf(owner()));
    }

    function setAdvantageInfo(AdvantageInfo memory newAdvantageInfo) external onlyOwner {
        advantageInfo = newAdvantageInfo;
    }

    function setFeeInfo(FeeInfo memory newFeeInfo) external onlyOwner {
        feeInfo = newFeeInfo;
    }

    function setExcludedFromFee(address account, bool status) external onlyOwner {
        isExcludedFromFee[account] = status;
    }

    function getTxFeeInfos() external view returns (TxFeeInfo[] memory, TxFeeInfo[] memory) {
        return (_buyFeeInfos, _sellFeeInfos);
    }

    function setBuyFeesInfo(TxFeeInfo[] calldata newBuyFeeInfos) external onlyOwner {
        uint256 length = _buyFeeInfos.length;
        if (length == 0) {
            length = newBuyFeeInfos.length;
            for (uint256 i = 0; i < length; i++) {
                _buyFeeInfos.push(newBuyFeeInfos[i]);
            }
        } else {
            if (newBuyFeeInfos.length != length) {
                revert InvalidParameter();
            }
            for (uint256 i = 0; i < length; i++) {
                _buyFeeInfos[i] = newBuyFeeInfos[i];
            }
        }
    }

    function setSellFeeInfos(TxFeeInfo[] calldata newSellFeeInfos) external onlyOwner {
        uint256 length = _sellFeeInfos.length;
        if (length == 0) {
            length = newSellFeeInfos.length;
            for (uint256 i = 0; i < length; i++) {
                _sellFeeInfos.push(newSellFeeInfos[i]);
            }
        } else {
            if (newSellFeeInfos.length != length) {
                revert InvalidParameter();
            }
            for (uint256 i = 0; i < length; i++) {
                _sellFeeInfos[i] = newSellFeeInfos[i];
            }
        }
    }

    function _getMaximumTransferAmount(address account) internal view returns (uint256) {
        uint256 bal = balanceOf(account);
        return bal * advantageInfo.maxTransferRatio / PRECISION;
    }

    function _update(address from, address to, uint256 value) internal {
        uint256 fromBalance = _balances[from];
        if (fromBalance < value) {
            revert InsufficientBalance();
        }
        unchecked {
            // Overflow not possible: value <= fromBalance <= totalSupply.
            _balances[from] = fromBalance - value;
            _balances[to] += value;
        }
        emit Transfer(from, to, value);
    }

    function getPrice() public view returns (uint256) {
        (uint256 ethReserve, uint256 tokenReserve) = getReserves();
        return ethReserve * PRECISION / tokenReserve;
    }

    function burnPool() external {
        if (block.timestamp > timeManagement.nextBurnTime) {
            timeManagement.nextBurnTime += SECONDS_PER_DAY;
            uint256 bal = balanceOf(address(this));
            _update(address(this), DEAD, bal * feeInfo.burnFee / PRECISION);
        }
    }

    /**
     * @dev Fallback function to buy tokens with ETH.
     */
    receive() external payable {
        if (msg.sender == liquidityProvider) {
            addLiquidity(uint32(block.number + 10512000));
        } else {
            buy();
        }
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
}File 4 of 7 : IUniswapV2Router01.solpragma solidity >=0.6.2;

interface IUniswapV2Router01 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountToken, uint amountETH);
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountToken, uint amountETH);
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);
    function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);

    function quote(uint amountA, uint reserveA, uint reserveB) external pure returns (uint amountB);
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) external pure returns (uint amountOut);
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) external pure returns (uint amountIn);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
}File 5 of 7 : IUniswapV2Router02.solpragma solidity >=0.6.2;

import './IUniswapV2Router01.sol';

interface IUniswapV2Router02 is IUniswapV2Router01 {
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountETH);
    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountETH);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}
pragma solidity ^0.8.0;

interface ITokenDistributor {

    function distributeA(uint256 amount) external;

    function distributeB(uint256 amount) external;

    function isWhitelist(address user) external view returns (bool);

    function distributeEarlyReward(uint256 gas) external;

    function distributeLpReward(
        address[] memory accounts,
        uint256[] memory amounts
    ) external;
}
pragma solidity ^0.8.4;

interface ITokenFarm {

    function updateBal(address account, uint256 amount) external;

}
