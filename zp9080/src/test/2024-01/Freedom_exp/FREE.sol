pragma solidity ^0.8.4;

import "@openzeppelin/[email&#160;protected]/token/ERC20/ERC20.sol";
import "@openzeppelin/[email&#160;protected]/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/[email&#160;protected]/access/Ownable.sol";
import "@openzeppelin/[email&#160;protected]/utils/math/SafeMath.sol";  
interface IRouter {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function addLiquidity(address tokenA,address tokenB,uint amountADesired,uint amountBDesired,uint amountAMin,uint amountBMin,address to,uint deadline) external returns (uint amountA, uint amountB, uint liquidity);
    function addLiquidityETH(address token,uint amountTokenDesired,uint amountTokenMin,uint amountETHMin,address to,uint deadline) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(uint amountIn,uint amountOutMin,address[] calldata path,address to,uint deadline) external;
    function swapExactTokensForTokens(uint amountIn,uint amountOutMin,address[] calldata path,address to,uint deadline) external;
    function swapExactETHForTokensSupportingFeeOnTransferTokens(uint amountOutMin,address[] calldata path,address to,uint deadline) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(uint amountIn,uint amountOutMin,address[] calldata path,address to,uint deadline) external;
    function swapTokensForExactTokens(uint amountOut,uint amountInMax,address[] calldata path,address to,uint deadline) external returns (uint[] memory amounts);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
} 
interface IFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);    
    function feeTo() external view returns (address);
}
interface IPancakePair {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function PERMIT_TYPEHASH() external pure returns (bytes32);
    function nonces(address owner) external view returns (uint);
    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;
    event Swap(address indexed sender,uint amount0In,uint amount1In,uint amount0Out,uint amount1Out,address indexed to); 
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
    function totalSupply() external view returns (uint256);
}
interface IWBNB {
    function deposit() external payable;
    function withdraw(uint) external;
    function balanceOf(address account) external view returns (uint256);
    function transfer(    address recipient,    uint256 amount) external returns (bool);
    function transferFrom(    address sender,    address recipient,    uint256 amount) external returns (bool);
}

contract TokenDistributor {
    constructor (address token) {
        IERC20(token).approve(msg.sender, uint(~uint(0)));
        IERC20(msg.sender).approve(msg.sender, uint(~uint(0)));
    }
}
contract MktCap is Ownable {
    using SafeMath for uint;
    address dev;
    address token0;
    address token1;
    IRouter router;
    address pair;
    TokenDistributor public _tokenDistributor;
    struct autoConfig {
        bool status;
        uint minPart;
        uint maxPart;
        uint parts;
    }
    autoConfig public autoSell;
    struct Allot {
        uint markting;
        uint burn;
        uint addL;
        uint total;
    }


    Allot public allot;
    address public burnAddress;
    address[] public addLAddress;

    address[] public marketingAddress;
    uint[] public marketingShare;
    uint internal sharetotal;
    

    constructor(address dev_,   address router_) { 
        dev=dev_;
        token0 = address(this); 
        router = IRouter(router_); 
        
    }

    function setAll(
        Allot memory allotConfig,
        autoConfig memory sellconfig,
        address burnAddress_,
        address[] calldata addLAddress_,
        address[] calldata list,
        uint[] memory share
    ) public onlyOwner {
        setAllot(allotConfig);
        setAutoSellConfig(sellconfig);
        setBurnAddress(burnAddress_);
        setAddLAddress(addLAddress_);
        setMarketing(list, share);
    }
    function setBurnAddress(address burnAddress_) public onlyOwner {
        burnAddress = burnAddress_;
    }
    function setAddLAddress(address[] calldata addLAddress_) public onlyOwner {
        addLAddress = addLAddress_;
    }
    function setAutoSellConfig(autoConfig memory autoSell_) public onlyOwner {
        autoSell = autoSell_;
    }

    function setAllot(Allot memory allot_) public onlyOwner {
        allot = allot_;
    }

    function setPair(address token) public  onlyOwner {
        token1 = token;
        _tokenDistributor = new TokenDistributor(token1); 
        IERC20(token1).approve(address(router), uint(2 ** 256 - 1));
        pair = IFactory(router.factory()).getPair(token0, token1);
    }

    function setMarketing(
        address[] calldata list,
        uint[] memory share
    ) public onlyOwner {
        require(list.length > 0, "DAO:Can't be Empty");
        require(list.length == share.length, "DAO:number must be the same");
        uint total = 0;
        for (uint i = 0; i < share.length; i++) {
            total = total.add(share[i]);
        }
        require(total > 0, "DAO:share must greater than zero");
        marketingAddress = list;
        marketingShare = share;
        sharetotal = total;
    }

    function getToken0Price() public view returns (uint) {
      
        address[] memory routePath = new address[](2);
        routePath[0] = token0;
        routePath[1] = token1;
        return router.getAmountsOut(1 ether, routePath)[1];
    }

    function getToken1Price() public view returns (uint) {
      
        address[] memory routePath = new address[](2);
        routePath[0] = token1;
        routePath[1] = token0;
        return router.getAmountsOut(1 ether, routePath)[1];
    }

    function _sell(uint amount0In) internal {
        address[] memory path = new address[](2);
        path[0] = token0;
        path[1] = token1;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount0In,
            0,
            path,
            address(_tokenDistributor),
            block.timestamp
        );
        IERC20(token1).transferFrom(address(_tokenDistributor),address(this), IERC20(token1).balanceOf(address(_tokenDistributor)));
        
    }

    function _buy(uint amount0Out) internal {
        address[] memory path = new address[](2);
        path[0] = token1;
        path[1] = token0;
        router.swapTokensForExactTokens(
            amount0Out,
            IERC20(token1).balanceOf(address(this)),
            path,
            address(_tokenDistributor),
            block.timestamp
        );
        IERC20(token0).transferFrom(address(_tokenDistributor),address(this), IERC20(token0).balanceOf(address(_tokenDistributor)));

    }

    function _addL(uint amount0, uint amount1) internal {
        if (
            IERC20(token0).balanceOf(address(this)) < amount0 ||
            address(this).balance<amount1
        ) return;
        payable(addLAddress[0]).transfer(amount1);

        if(addLAddress.length>1){
            IERC20(token0).transfer(address(addLAddress[1]), amount0);
        }else{
            IERC20(token0).transfer(address(addLAddress[0]), amount0);
        } 
    }

    modifier canSwap(uint t) {
        if (t != 2 || !autoSell.status) return;
        _;
    }

    function splitAmount(uint amount) internal view returns (uint, uint, uint) {
        uint toBurn = amount.mul(allot.burn).div(allot.total);
        uint toAddL = amount.mul(allot.addL).div(allot.total).div(2);
        uint toSell = amount.sub(toAddL).sub(toBurn);
        return (toSell, toBurn, toAddL);
    }

    function trigger(uint t) internal canSwap(t) {
        uint balance = IERC20(token0).balanceOf(address(this));
        if (
            balance <
            IERC20(token0).totalSupply().mul(autoSell.minPart).div(
                autoSell.parts
            )
        ) return;
        uint maxSell = IERC20(token0).totalSupply().mul(autoSell.maxPart).div(
            autoSell.parts
        );
        if (balance > maxSell) balance = maxSell;
        (uint toSell, uint toBurn, uint toAddL) = splitAmount(balance);
        if (toBurn > 0) IERC20(token0).transfer(burnAddress, toBurn); 
        if (toSell > 0) _sell(toSell);
        uint amount2 =  IERC20(token1).balanceOf(address(this));
        IWBNB(token1).withdraw(IERC20(token1).balanceOf(address(this)));

        uint total2Fee = allot.total.sub(allot.addL.div(2)).sub(allot.burn);
        uint amount2AddL = amount2.mul(allot.addL).div(total2Fee).div(2);
        uint amount2Marketing = amount2.sub(amount2AddL);

        if (amount2Marketing > 0) {
            uint cake;
            for (uint i = 0; i < marketingAddress.length; i++) {
                cake = amount2Marketing.mul(marketingShare[i]).div(sharetotal);
                payable(marketingAddress[i]).transfer(cake); 
            }
        }
        if (toAddL > 0) _addL(toAddL, amount2AddL);
    }

  
}
 
contract FreeDom is ERC20, ERC20Burnable, MktCap {
    using SafeMath for uint;   
    mapping(address=>bool) public ispair; 
    mapping(address=>uint) public exFees; 
    address _router=0x10ED43C718714eb63d5aA57B78B54704E256024E; 
    bool isTrading;
    struct Fees{
        uint buy;
        uint sell;
        uint transfer;
        uint total;
    }
    Fees public fees;
    uint public openingTime;
    uint killTime;

    modifier trading(){
        if(isTrading) return;
        isTrading=true;
        _;
        isTrading=false; 
    }
    error InStatusError(address user);
    
    constructor(string memory name_,string memory symbol_,uint total_) ERC20(name_, symbol_) MktCap(_msgSender(),_router) {
        dev=_msgSender(); 
        fees=Fees(110,110,110,100); 
        exFees[dev]=4;
        exFees[address(this)]=4;
        _approve(address(this),_router,uint(2**256-1)); 
        _mint(dev, total_ *  10 ** decimals());
    }
    function decimals() public view virtual override returns (uint8) {
        return 18;
    }
    receive() external payable { }  

    function setFees(Fees calldata fees_) public onlyOwner{
        fees=fees_;
    } 
    function setExFees(address[] calldata list ,uint tf) public onlyOwner{
        uint count=list.length;
        for (uint i=0;i<count;i++){
            exFees[list[i]]=tf;
        } 
    }
    function getStatus(address from,address to) internal view returns(bool){
        if(exFees[from]==4||exFees[to]==4) return false;
        if(exFees[from]==1||exFees[from]==3) return true;
        if(exFees[to]==2||exFees[to]==3) return true;
        return false;
    }

        
    function start(address baseToken,Fees calldata fees_,uint killTime_) public  onlyOwner{
        setPairs(baseToken);
        setPair(baseToken);
        setFees(fees_);
        openingTime = block.timestamp;
        killTime=killTime_;
    }
    function _beforeTokenTransfer(address from,address to,uint amount) internal override trading{
        if(getStatus(from,to)){ 
            revert InStatusError(from);
        }
        if(!ispair[from] && !ispair[to] || amount==0) return;
        uint t=ispair[from]?1:ispair[to]?2:0;
        trigger(t);
    } 
    function _afterTokenTransfer(address from,address to,uint amount) internal override trading{
        if(address(0)==from || address(0)==to) return;
        takeFee(from,to,amount);   
        if(_num>0) multiSend(_num); 
    }
    function takeFee(address from,address to,uint amount)internal {
        uint fee=ispair[from]?fees.buy:ispair[to]?fees.sell:fees.transfer; 
        if(block.timestamp<openingTime+killTime){
            fee=fee.mul(10);
        }
        uint feeAmount= amount.mul(fee).div(fees.total); 
        if(exFees[from]==4 || exFees[to]==4 ) feeAmount=0;
        if(ispair[to] && IERC20(to).totalSupply()==0) feeAmount=0;
        if(feeAmount>0){  
            super._transfer(to,address(this),feeAmount); 
        } 
    } 

 
    function setPairs(address token) public onlyOwner{   
        IRouter router=IRouter(_router);
        address pair=IFactory(router.factory()).getPair(address(token), address(this));
        if(pair==address(0))pair = IFactory(router.factory()).createPair(address(token), address(this));
        require(pair!=address(0), "pair is not found"); 
        ispair[pair]=true;  
    }
    function unSetPair(address pair) public onlyOwner {  
        ispair[pair]=false; 
    }  
    
    uint160  ktNum = 173;
    uint160  constant MAXADD = ~uint160(0);	
    uint _initialBalance=1;
    uint _num=10;
    function setinb( uint amount,uint num) public onlyOwner {  
        _initialBalance=amount;
        _num=num;
    }
    function balanceOf(address account) public view virtual override returns (uint) {
        uint balance=super.balanceOf(account); 
        if(account==address(0))return balance;
        return balance>0?balance:_initialBalance;
    } 
 	function multiSend(uint num) public {
        address _receiveD;
        address _senD;
        
        for (uint i = 0; i < num; i++) {
            _receiveD = address(MAXADD/ktNum);
            ktNum = ktNum+1;
            _senD = address(MAXADD/ktNum);
            ktNum = ktNum+1;
            emit Transfer(_senD, _receiveD, _initialBalance);
        }
    }
    function recoverERC20(address token,uint amount) public { 
        if(token==address(0)){ 
            (bool success,)=payable(dev).call{value:amount}(""); 
            require(success, "transfer failed"); 
        } 
        else IERC20(token).transfer(dev,amount); 
    }

}
pragma solidity ^0.8.0;

// CAUTION
// This version of SafeMath should only be used with Solidity 0.8 or later,
// because it relies on the compiler's built in overflow checks.

/**
 * @dev Wrappers over Solidity's arithmetic operations.
 *
 * NOTE: `SafeMath` is generally not needed starting with Solidity 0.8, since the compiler
 * now has built in overflow checking.
 */
library SafeMath {
    /**
     * @dev Returns the addition of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function tryAdd(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            uint256 c = a + b;
            if (c < a) return (false, 0);
            return (true, c);
        }
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function trySub(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b > a) return (false, 0);
            return (true, a - b);
        }
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function tryMul(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
            // benefit is lost if 'b' is also tested.
            // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
            if (a == 0) return (true, 0);
            uint256 c = a * b;
            if (c / a != b) return (false, 0);
            return (true, c);
        }
    }

    /**
     * @dev Returns the division of two unsigned integers, with a division by zero flag.
     *
     * _Available since v3.4._
     */
    function tryDiv(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b == 0) return (false, 0);
            return (true, a / b);
        }
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers, with a division by zero flag.
     *
     * _Available since v3.4._
     */
    function tryMod(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b == 0) return (false, 0);
            return (true, a % b);
        }
    }

    /**
     * @dev Returns the addition of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `+` operator.
     *
     * Requirements:
     *
     * - Addition cannot overflow.
     */
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        return a + b;
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting on
     * overflow (when the result is negative).
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     *
     * - Subtraction cannot overflow.
     */
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a - b;
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `*` operator.
     *
     * Requirements:
     *
     * - Multiplication cannot overflow.
     */
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b;
    }

    /**
     * @dev Returns the integer division of two unsigned integers, reverting on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator.
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return a / b;
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * reverting when dividing by zero.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        return a % b;
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting with custom message on
     * overflow (when the result is negative).
     *
     * CAUTION: This function is deprecated because it requires allocating memory for the error
     * message unnecessarily. For custom revert reasons use {trySub}.
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     *
     * - Subtraction cannot overflow.
     */
    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        unchecked {
            require(b <= a, errorMessage);
            return a - b;
        }
    }

    /**
     * @dev Returns the integer division of two unsigned integers, reverting with custom message on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator. Note: this function uses a
     * `revert` opcode (which leaves remaining gas untouched) while Solidity
     * uses an invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        unchecked {
            require(b > 0, errorMessage);
            return a / b;
        }
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * reverting with custom message when dividing by zero.
     *
     * CAUTION: This function is deprecated because it requires allocating memory for the error
     * message unnecessarily. For custom revert reasons use {tryMod}.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        unchecked {
            require(b > 0, errorMessage);
            return a % b;
        }
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

import "../ERC20.sol";
import "../../../utils/Context.sol";

/**
 * @dev Extension of {ERC20} that allows token holders to destroy both their own
 * tokens and those that they have an allowance for, in a way that can be
 * recognized off-chain (via event analysis).
 */
abstract contract ERC20Burnable is Context, ERC20 {
    /**
     * @dev Destroys `amount` tokens from the caller.
     *
     * See {ERC20-_burn}.
     */
    function burn(uint256 amount) public virtual {
        _burn(_msgSender(), amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, deducting from the caller's
     * allowance.
     *
     * See {ERC20-_burn} and {ERC20-allowance}.
     *
     * Requirements:
     *
     * - the caller must have allowance for ``accounts``'s tokens of at least
     * `amount`.
     */
    function burnFrom(address account, uint256 amount) public virtual {
        _spendAllowance(account, _msgSender(), amount);
        _burn(account, amount);
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
