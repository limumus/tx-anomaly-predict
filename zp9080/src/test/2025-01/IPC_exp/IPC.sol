pragma solidity 0.8.6;

import "./IERC20.sol";
import "./IUniswapV2Router.sol";
import "./IUniswapV2Factory.sol";

interface IUniswapV2Pair {
    function sync() external;
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IToken is IERC20 {
    
    /**
    * @dev 0 Address Verification
    */
    error ZeroAddress();

    /**
    * @dev 0 amount verification
    */
    error ZeroValue();

    /**
    * @dev Insufficient balance
    */
    error InsufficientBalance();

    error TransferTimeLock();

    error NoOpenSwap();

    event SetPool(address indexed _pool);
    event LostOwner(address indexed _owner);
    event AddMarketer(address indexed _marketer);
    event OpenSwap();

    /**
    * @dev Returns the token symbol.
    */
    function symbol() external view returns (string memory);

    /**
    * @dev Returns the token name.
    */
    function name() external view returns (string memory);

    /**
    * @dev Atomically increases the allowance granted to `spender` by the caller.
    *
    * This is an alternative to {approve} that can be used as a mitigation for
    * problems described in {BEP20-approve}.
    *
    * Emits an {Approval} event indicating the updated allowance.
    *
    * Requirements:
    *
    * - `spender` cannot be the zero address.
    */
    function increaseAllowance(address spender, uint256 addedValue) external returns (bool);

    /**
    * @dev Atomically decreases the allowance granted to `spender` by the caller.
    *
    * This is an alternative to {approve} that can be used as a mitigation for
    * problems described in {BEP20-approve}.
    *
    * Emits an {Approval} event indicating the updated allowance.
    *
    * Requirements:
    *
    * - `spender` cannot be the zero address.
    * - `spender` must have allowance for the caller of at least
    * `subtractedValue`.
    */
    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool);
}

contract Token is IToken {

    string constant public override name = "AI IPC";
    string constant public override symbol = "IPC";
    uint8 constant public override decimals = 18;

    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant SWAP_V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;

    address constant PUBLISHER = 0xe77EAf4b033F187779e094e1eFE5cc4699c7C38A; // 2%
    address constant FEE1 = 0x003BF877298Dd7f2f9109EfA7b872Fac0854749F; // 70%
    address constant FEE2 = 0x05632970d3920fDd9827CC9258c31FE0db8b23B8; // 20%
    address constant FEE3 = 0xF6C7b7d582f3C2d4991b73D4Ce8645b589cd5F84; // 10%
    uint256 constant TRANSFER_LOCK = 30 minutes;

    address public pool;

    uint256 public override totalSupply = 2100000 * 10 ** 18;
    uint256 constant public MAX_TOTAL_SUPPLY = 2 ** 112;
    uint256 constant public MARKET_TAX = 15; // /1000 ; 1.5%
    uint256 constant public PUBLISH_TAX = 20; // /1000 ; 2%;
    uint256 public destroyNum;
    uint256 public lastDestroyNum;
    uint256 public lastLPTotalSupply;

    address public owner;
    bool public lastSellIsAdd;
    bool public isOpenSwap;
    
    mapping (address => uint256) balances;
    mapping (address => mapping (address => uint256)) allowances;
    mapping (address => uint256) transferTime;
    mapping(address => bool) isMarketer;

    constructor() {
        owner = msg.sender;
        balances[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }
    
    function balanceOf(address account) public view override returns(uint256 balance) {
        balance = balances[account];
    }

    function productWait() external view returns (uint256) {
        return destroyNum * 2;
    }

    function producedAlreadyNum() external view returns (uint256) {
        return totalSupply - 2100000 * 10**18;
    }
    
    function allowance(address account, address spender) external view override returns(uint256){
        return allowances[account][spender];
    }
    
    function transfer(address recipient, uint256 amount) public override returns(bool success) {
        _transfer(msg.sender, recipient, amount);
        success = true;
    }
    
    function approve(address spender, uint256 amount) external override returns(bool success) {
        _approve(msg.sender, spender, amount);
        success = true;
    }
    
    function increaseAllowance(address spender, uint256 addedValue) external override returns (bool) {
        _approve(msg.sender, spender, allowances[msg.sender][spender] + addedValue);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) external override returns (bool) {
        _approve(msg.sender, spender, allowances[msg.sender][spender] - subtractedValue);
        return true;
    }
    
    function transferFrom(address sender, address recipient, uint256 amount) external override returns(bool success){
        _transfer(sender, recipient, amount);
        _approve(sender, msg.sender, allowances[sender][msg.sender] - amount);
        success = true;
    }

    function setPool(address _pool) external {
        require(owner == msg.sender, "Error owner!");
        pool = _pool;
        emit SetPool(_pool);
    }

    function setMarkeret(address account) external {
        require(owner == msg.sender, "Error owner!");
        isMarketer[account] = true;
        emit AddMarketer(account);
    }

    function openSwap() external {
        require(owner == msg.sender, "Error owner!");
        isOpenSwap = true;
        emit OpenSwap();
    }

    function lostOwner() external {
        require(owner == msg.sender, "Error owner!");
        owner = address(0);
        emit LostOwner(owner);
    }

    function _approve(address _owner, address spender, uint256 amount) internal {
        if (_owner == address(0) || spender == address(0)) revert ZeroAddress();

        allowances[_owner][spender] = amount;
        emit Approval(_owner, spender, amount);
    }

    function _transfer(address sender, address recipient, uint256 amount) internal {
        if (isOpenSwap == false) {
            if (isMarketer[sender] == false && isMarketer[recipient] == false) {
                revert NoOpenSwap();
            }
        }

        if (sender == address(0) || recipient == address(0)) revert ZeroAddress();
        if (amount > balanceOf(sender)) revert InsufficientBalance();

        uint256 fee = 0;
        address pair = IUniswapV2Factory(SWAP_V2_FACTORY).getPair(address(this), USDT);

        if (pair != address(0)) {
            uint256 LPTotalSupply = IERC20(pair).totalSupply();
            if (lastLPTotalSupply < LPTotalSupply && lastSellIsAdd == false) {
                if (destroyNum >= lastDestroyNum) destroyNum -= lastDestroyNum;
            }
            lastSellIsAdd = false;
            lastLPTotalSupply = LPTotalSupply;
            if (sender == pair && !_isRemoveLP(pair) && recipient != address(this)) {
                //buy
                fee = amount * MARKET_TAX / 1000;
                transferTime[recipient] = block.timestamp;
                _buy(fee);
            } else if (recipient == pair && sender != address(this)) {
                if (_isAddLP(pair)) {
                    lastSellIsAdd = true;
                } else {
                    //sell
                    if (block.timestamp < transferTime[sender] + TRANSFER_LOCK) revert TransferTimeLock();
                    fee = amount * (MARKET_TAX + PUBLISH_TAX) / 1000;
                    _destroy(destroyNum);
                    destroyNum += (amount - fee) / 2;
                    lastDestroyNum = (amount - fee) / 2;
                    _sell(fee);
                }
            }

            if (sender != pair && recipient != pair) {
                if (block.timestamp < transferTime[sender] + TRANSFER_LOCK) revert TransferTimeLock();
                _destroy(destroyNum);
            }
        }
        
        balances[sender] -= amount;
        balances[recipient] += amount - fee;
        emit Transfer(sender, recipient, amount - fee);
    }

    function _buy(uint256 fee) internal {
        // 70%
        balances[FEE1] += fee * 7 / 10;
        emit Transfer(address(this), FEE1, fee * 7 / 10);
        // 20%
        balances[FEE2] += fee * 2 / 10;
        emit Transfer(address(this), FEE2, fee * 2 / 10);
        // 10%
        balances[FEE3] += fee * 1 / 10;
        emit Transfer(address(this), FEE3, fee * 1 / 10);
    }

    function _sell(uint256 fee) internal {
        // PUBLISH_TAX
        uint256 publisherFee = fee * PUBLISH_TAX / (MARKET_TAX + PUBLISH_TAX);
        balances[PUBLISHER] += publisherFee;
        emit Transfer(address(this), PUBLISHER, publisherFee);

        // fee - publisherFee;
        fee -= publisherFee;
        
        // 70%
        balances[FEE1] += fee * 7 / 10;
        emit Transfer(address(this), FEE1, fee * 7 / 10);
        // 20%
        balances[FEE2] += fee * 2 / 10;
        emit Transfer(address(this), FEE2, fee * 2 / 10);
        // 10%
        balances[FEE3] += fee * 1 / 10;
        emit Transfer(address(this), FEE3, fee * 1 / 10);
    }

    function _destroy(uint256 burnNum) internal {
        if (burnNum < 1) return;
        address pair = IUniswapV2Factory(SWAP_V2_FACTORY).getPair(USDT, address(this));
        uint256 pairToken = IERC20(address(this)).balanceOf(pair);
        if (pairToken - 10**18 < burnNum) {
            burnNum = pairToken - 10**18;
        }
        balances[pair] -= burnNum;
        balances[address(0)] += burnNum;
        IUniswapV2Pair(pair).sync();
        emit Transfer(pair, address(0), burnNum);
        destroyNum -= burnNum;
        lastDestroyNum = 0;

        //produce -> pool produceNum = burnNum * 2; produceNum 90% -> LP; 10% -> lper's Preaccount
        uint256 produceNum = burnNum * 2;
        if (totalSupply + produceNum > MAX_TOTAL_SUPPLY) {
            produceNum = MAX_TOTAL_SUPPLY - totalSupply;
        }
        totalSupply += produceNum;
        balances[pool] += produceNum;
        emit Transfer(address(0), pool, produceNum);
    }

    function _isAddLP(address pair) internal view returns(bool) {
        (uint256 reserve0, uint256 reserve1, ) = IUniswapV2Pair(pair).getReserves();
        uint256 USDTReserve = reserve0;
        if (USDT > address(this)) {
            USDTReserve = reserve1;
        }

        return IERC20(USDT).balanceOf(pair) > USDTReserve;
    }

    function _isRemoveLP(address pair) internal view returns(bool) {
        (uint256 reserve0, uint256 reserve1, ) = IUniswapV2Pair(pair).getReserves();
        uint256 USDTReserve = reserve0;
        if (USDT > address(this)) {
            USDTReserve = reserve1;
        }

        return IERC20(USDT).balanceOf(pair) < USDTReserve;
    }
}
pragma solidity 0.8.6;

/**
 * @dev Interface of the ERC-20 standard as defined in the ERC.
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

    function decimals() external returns(uint8);
}
}
pragma solidity 0.8.6;

interface IUniswapV2Factory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);

    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint) external view returns (address pair);
    function allPairsLength() external view returns (uint);

    function createPair(address tokenA, address tokenB) external returns (address pair);

    function setFeeTo(address) external;
    function setFeeToSetter(address) external;
}
pragma solidity 0.8.6;

interface IUniswapV2Router {
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
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function quote(uint amountA, uint reserveA, uint reserveB) external pure returns (uint amountB);
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) external pure returns (uint amountOut);
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) external pure returns (uint amountIn);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
}
