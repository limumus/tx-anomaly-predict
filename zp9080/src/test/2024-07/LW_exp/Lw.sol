pragma solidity ^0.7.6;
pragma abicoder v2;

import "./interface/IERC20.sol";
import "./interface/Ownable.sol";
import "./interface/IPancakeRouter02.sol";
import "./interface/IUniswapV2Factory.sol";
import "./interface/IPancakePair.sol";
import "./lib/PancakeLibrary.sol";

// 基础代币
contract LinkingTheWorld is IERC20, Ownable {
    // 费率，需要小于基数 BASE
    // 买营销税率
    uint256 public _buyFundFee = 0;
    // 买回流税率
    uint256 public _buyLPFee = 0;
    // 买销毁税率
    uint256 public _buyBurnFee = 0;
    // 卖营销A税率
    uint256 public _sellFundFee = 0;
    // 绑定税率
    uint256 public _bondFundFee = 0;
    // 卖营销B税率
    uint256 public _sellLPFee = 0;
    // 卖销毁税率
    uint256 public _sellBurnFee = 0;

    // 代币基础信息
    // 代币名称
    string public override name;
    // 代币简称
    string public override symbol;
    // 代币精度
    uint256 public override decimals;
    // 代币总发行量，与精度相关
    uint256 public override totalSupply;

    // 底池代币
    address public currency;
    // 推荐绑定代币
    address public bondingToken;

    // 营销A钱包地址
    address public LPFeeAccountA;
    // 营销B钱包地址
    address public LPFeeAccountB;
    // 底池燃烧管理员地址
    address public manager;

    // 余额
    mapping(address => uint256) public _balances;
    // 授权
    mapping(address => mapping(address => uint256)) public _allowances;
    // 白名单
    mapping(address => bool) public _feeWhiteList;
    // 黑名单
    mapping(address => bool) public _blackList;
    // 推荐绑定
    mapping(address => address) public _bonding;

    // 黑洞地址
    address deadAddress = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant MAX = ~uint256(0);
    // 费率基数
    uint256 public constant BASE = 10000;

    // 薄饼的路由合约地址
    IPancakeRouter02 public _swapRouter;
    // 底池pool地址
    address public _mainPair;

    mapping(address => bool) public _swapPairList;

    // 转账
    function transfer(
        address recipient,
        uint256 amount
    ) external virtual override returns (bool) {}

    // 转账
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external virtual override returns (bool) {}

    // 查询余额
    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    // 查询授权
    function allowance(
        address owner,
        address spender
    ) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    // 授权
    function approve(
        address spender,
        uint256 amount
    ) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    // 授权
    function _approve(address owner, address spender, uint256 amount) private {
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    // &#160;设置白名单
    function setWhiteList(
        address[] calldata addr,
        bool enable
    ) external onlyOwner {
        for (uint256 i = 0; i < addr.length; i++) {
            _feeWhiteList[addr[i]] = enable;
        }
    }

    // &#160;设置黑名单
    function setBlackList(
        address[] calldata addr,
        bool enable
    ) external onlyOwner {
        for (uint256 i = 0; i < addr.length; i++) {
            _blackList[addr[i]] = enable;
        }
    }

    // 底池币燃烧
    function lpBurn(uint256 currency_to_burn) external {
        require(msg.sender == manager);
        require(_balances[_mainPair] >= currency_to_burn);
        _balances[_mainPair] -= currency_to_burn;
        _balances[deadAddress] += currency_to_burn;
        IPancakePair(_mainPair).sync();
    }

    // 设置绑定关系
    function setBonding(address a, address b) external {
        require(msg.sender == bondingToken, "not bondingToken");
        _bonding[a] = b;
    }
}

// swapToken
contract DexToken is LinkingTheWorld {
    // 初始化
    constructor(
        string[] memory stringParams,
        address[] memory addressParams,
        uint256[] memory numberParams
    ) {
        // 设置配置
        // 代币名称
        name = stringParams[0];
        // 代币简称
        symbol = stringParams[1];
        // 代币精度
        decimals = numberParams[0];
        // 代币总发行量
        totalSupply = numberParams[1];
        // 底池代币地址
        currency = addressParams[0];

        // 购买营销费率
        _buyFundFee = numberParams[2];
        // 购买销毁费率
        _buyBurnFee = numberParams[3];
        // 购买回流费率
        _buyLPFee = numberParams[4];
        // 售卖营销A费率
        _sellFundFee = numberParams[5];
        // 推荐人费率
        _bondFundFee = numberParams[6];
        // 售卖销毁费率
        _sellBurnFee = numberParams[7];
        // 售卖营销B费率
        _sellLPFee = numberParams[8];

        // 代币初始化接收地址
        address ReceiveAddress = addressParams[2];
        // 营销A钱包地址
        LPFeeAccountA = addressParams[3];
        // 营销B钱包地址
        LPFeeAccountB = addressParams[4];
        // 底池燃烧管理员地址
        manager = addressParams[5];
        // 推荐绑定代币地址
        bondingToken = addressParams[6];

        // 获取pancake swap router
        IPancakeRouter02 swapRouter = IPancakeRouter02(addressParams[1]);

        // 创建池
        IUniswapV2Factory swapFactory = IUniswapV2Factory(swapRouter.factory());
        address swapPair = swapFactory.createPair(address(this), currency);
        // 记录pair地址
        _mainPair = swapPair;
        _swapPairList[swapPair] = true;

        // 授权
        IERC20(currency).approve(address(swapRouter), MAX);
        _swapRouter = swapRouter;
        _allowances[address(this)][address(swapRouter)] = MAX;
        _allowances[address(this)][_mainPair] = MAX;

        // 分配代币
        _balances[ReceiveAddress] = totalSupply;
        emit Transfer(address(0), ReceiveAddress, totalSupply);

        // from和to都在白名单内的swap不收取手续费
        _feeWhiteList[ReceiveAddress] = true;
        _feeWhiteList[address(this)] = true;
        _feeWhiteList[msg.sender] = true;
        _feeWhiteList[tx.origin] = true;
        _feeWhiteList[deadAddress] = true;
    }

    // 接收原生币
    receive() external payable {}

    // 转账
    function transfer(
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    // 转账
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _transfer(sender, recipient, amount);
        if (_allowances[sender][msg.sender] != MAX) {
            _allowances[sender][msg.sender] =
                _allowances[sender][msg.sender] -
                amount;
        }
        return true;
    }

    // 内部转账方法
    function _transfer(address from, address to, uint256 amount) private {
        // 黑名单无法买卖和转账
        if (_blackList[from] || _blackList[to]) {
            require(false);
        }
        // 判断余额
        uint256 balance = _balances[from];
        require(balance >= amount, "balanceNotEnough");
        bool isSell;
        bool takeFee;
        // from或to是pool
        if (_swapPairList[from] || _swapPairList[to]) {
            // from和to均不是白名单，则收取手续费
            if (!_feeWhiteList[from] && !_feeWhiteList[to]) {
                takeFee = true;
            }
            // to为pool，则为卖
            if (_swapPairList[to]) {
                isSell = true;
            }
        }

        bool isTransfer;
        // from和to均不是pool
        if (!_swapPairList[from] && !_swapPairList[to]) {
            isTransfer = true;
        }
        _tokenTransfer(from, to, amount, takeFee, isSell, isTransfer);
    }

    // 扣除税费
    function _tokenTransfer(
        address sender,
        address recipient,
        uint256 tAmount,
        bool takeFee,
        bool isSell,
        bool isTransfer
    ) private {
        // 付款人扣费
        _balances[sender] = _balances[sender] - tAmount;
        uint256 feeAmount;

        // 如果是转账或者卖出
        // 扣除税率并兑换为底池代币
        if (!_feeWhiteList[sender]) {
            if ((takeFee && isSell) || isTransfer) {
                uint sellFundAmount = (tAmount * _sellFundFee) / BASE;
                uint bondFundAmount = (tAmount * _bondFundFee) / BASE;
                // 有推荐人则返利给推荐人
                if (_bonding[tx.origin] != address(0)) {
                    if (bondFundAmount > 0) {
                        feeAmount += bondFundAmount;
                        // 兑换成底池代币
                        _internalSwap(bondFundAmount, _bonding[tx.origin]);
                    }
                } else {
                    // 没有推荐人则加到营销A钱包
                    sellFundAmount += bondFundAmount;
                }
                if (sellFundAmount > 0 && LPFeeAccountA != address(0)) {
                    feeAmount += sellFundAmount;
                    // 兑换成底池代币
                    _internalSwap(sellFundAmount, LPFeeAccountA);
                }
                // 返利给营销B钱包
                uint sellLPAmount = (tAmount * _sellLPFee) / BASE;
                if (sellLPAmount > 0 && LPFeeAccountB != address(0)) {
                    feeAmount += sellLPAmount;
                    // 兑换成底池代币
                    _internalSwap(sellLPAmount, LPFeeAccountB);
                }
                // 销毁
                uint burnAmount = (tAmount * _sellBurnFee) / BASE;
                if (burnAmount > 0) {
                    feeAmount += burnAmount;
                    // 销毁token
                    _takeTransfer(sender, address(0xdead), burnAmount);
                }
            } else if (takeFee && !isSell) {
                // 计算要扣除的费用
                // 营销
                uint buFundAmount = (tAmount * _buyFundFee) / BASE;
                if (buFundAmount > 0) {
                    feeAmount += buFundAmount;
                    _takeTransfer(sender, LPFeeAccountA, buFundAmount);
                }
                // 回流
                uint256 buyLPAmount = (tAmount * _buyLPFee) / BASE;
                if (buyLPAmount > 0) {
                    feeAmount += buyLPAmount;
                    _takeTransfer(sender, address(this), buyLPAmount);
                }
                // 销毁
                uint burnAmount = (tAmount * _buyBurnFee) / BASE;
                if (burnAmount > 0) {
                    feeAmount += burnAmount;
                    _takeTransfer(sender, address(0xdead), burnAmount);
                }
            }
        }

        // 转账给最终收款人
        _takeTransfer(sender, recipient, tAmount - feeAmount);
    }

    // 普通转账
    function _takeTransfer(
        address sender,
        address to,
        uint256 tAmount
    ) private {
        _balances[to] = _balances[to] + tAmount;
        emit Transfer(sender, to, tAmount);
    }

    // 内部swap
    function _internalSwap(uint swapAmount, address account) private {
        // 完成转账
        _balances[address(this)] -= swapAmount;
        _balances[_mainPair] += swapAmount;

        // 内部兑换计算
        (address token0, ) = PancakeLibrary.sortTokens(address(this), currency);
        (uint reserve0, uint reserve1, ) = IPancakePair(_mainPair)
            .getReserves();
        (uint reserveInput, uint reserveOutput) = address(this) == token0
            ? (reserve0, reserve1)
            : (reserve1, reserve0);
        uint amountInput = _balances[_mainPair] - reserveInput;
        // 计算amountOut
        uint amountOutput = PancakeLibrary.getAmountOut(
            amountInput,
            reserveInput,
            reserveOutput
        );
        (uint amount0Out, uint amount1Out) = address(this) == token0
            ? (uint(0), amountOutput)
            : (amountOutput, uint(0));
        // swap
        IPancakePair(_mainPair).swap(
            amount0Out,
            amount1Out,
            account,
            new bytes(0)
        );
    }
}
pragma solidity ^0.7.6;

interface IERC20 {
    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function totalSupply() external view returns (uint256);

    function decimals() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function transfer(
        address recipient,
        uint256 amount
    ) external returns (bool);

    function allowance(
        address owner,
        address spender
    ) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
}
pragma solidity >=0.5.0;

interface IPancakePair {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external pure returns (string memory);
    function symbol() external pure returns (string memory);
    function decimals() external pure returns (uint8);
    function totalSupply() external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function PERMIT_TYPEHASH() external pure returns (bytes32);
    function nonces(address owner) external view returns (uint);

    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    function MINIMUM_LIQUIDITY() external pure returns (uint);
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint);
    function price1CumulativeLast() external view returns (uint);
    function kLast() external view returns (uint);

    function mint(address to) external returns (uint liquidity);
    function burn(address to) external returns (uint amount0, uint amount1);
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;

    function initialize(address, address) external;
}File 4 of 8 : IPancakeRouter01.solpragma solidity >=0.6.2;

interface IPancakeRouter01 {
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
}File 5 of 8 : IPancakeRouter02.solpragma solidity >=0.6.2;

import './IPancakeRouter01.sol';

interface IPancakeRouter02 is IPancakeRouter01 {
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
pragma solidity 0.7.6;
interface IUniswapV2Factory {
    event PairCreated(
        address indexed token0,
        address indexed token1,
        address pair,
        uint256
    );

    function feeTo() external view returns (address);

    function feeToSetter() external view returns (address);

    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address pair);

    function allPairs(uint256) external view returns (address pair);

    function allPairsLength() external view returns (uint256);

    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address pair);

    function setFeeTo(address) external;

    function setFeeToSetter(address) external;
}
pragma solidity 0.7.6;

contract Context {
    // Empty internal constructor, to prevent people from mistakenly deploying
    // an instance of this contract, which should be used via inheritance.
    //   constructor () internal { }

    function _msgSender() internal view returns (address) {
        return payable(msg.sender);
    }

    function _msgData() internal view returns (bytes memory) {
        this; // silence state mutability warning without generating bytecode - see https://github.com/ethereum/solidity/issues/2691
        return msg.data;
    }
}

contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor() {
        address msgSender = _msgSender();
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public onlyOwner {
        emit OwnershipTransferred(
            _owner,
            0x000000000000000000000000000000000000dEaD
        );
        _owner = 0x000000000000000000000000000000000000dEaD;
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public onlyOwner {
        require(
            newOwner != address(0),
            "Ownable: new owner is the zero address"
        );
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
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
}File 8 of 8 : PancakeLibrary.solpragma solidity >=0.5.0;

library SafeMath {
    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x, 'ds-math-add-overflow');
    }

    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x, 'ds-math-sub-underflow');
    }

    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x, 'ds-math-mul-overflow');
    }
}

library PancakeLibrary {
    using SafeMath for uint;
    function getAmountOut(
        uint amountIn,
        uint reserveIn,
        uint reserveOut
    ) internal pure returns (uint amountOut) {
        require(amountIn > 0, "PancakeLibrary: INSUFFICIENT_INPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "PancakeLibrary: INSUFFICIENT_LIQUIDITY"
        );
        uint amountInWithFee = amountIn.mul(9975);
        uint numerator = amountInWithFee.mul(reserveOut);
        uint denominator = reserveIn.mul(10000).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, 'PancakeLibrary: IDENTICAL_ADDRESSES');
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'PancakeLibrary: ZERO_ADDRESS');
    }
}
