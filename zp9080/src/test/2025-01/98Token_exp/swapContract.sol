pragma solidity ^0.8.20;

import {SafeERC20,IERC20} from "./SafeERC20.sol";
import {Ownable} from "./Ownable.sol";

interface IPancakeRouter {
    function getAmountsOut(uint amountIn, address[] memory path) external view returns (uint[] memory amounts);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

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
}

contract PancakeRouter {
    IPancakeRouter public constant _IPancakeRouter = IPancakeRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    function getSwapRouterAmountsOut(address[] memory path, uint256 _amount) public view returns (uint256) {
        uint256 amountOut;
        uint256[] memory amounts = _IPancakeRouter.getAmountsOut(_amount, path);
        amountOut = amounts[1];
        return amountOut;
    }

    function swapTokensForTokens(address[] memory path, uint256 tokenAmount,uint256 tokenOutMin, address to) public {
        _IPancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            tokenOutMin, 
            path,
            to,
            block.timestamp + 60
        );
    }

    function addLiquidity(address tokenA, address tokenB, uint256 amountADesired, uint256 amountBDesired, uint256 amountAMin, uint256 amountBMin, address to) public {
        _IPancakeRouter.addLiquidity(
            tokenA,
            tokenB,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin,
            to,
            block.timestamp + 60
        );
    }
}

contract Main is PancakeRouter, Ownable {
    using SafeERC20 for IERC20;
    IERC20 public constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 public Token = IERC20(0xc0dDfD66420ccd3a337A17dD5D94eb54ab87523F);
    address public constant burnAddr = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant AMPLIFIED_BASE = 10000;
    uint256 public constant AMPLIFIED_DECIMALS = 1 * 10 ** 18;

    address public receiverAddress;
    address public firstAddress;
    mapping(address => address) public userRecommended;
    mapping(address => address[]) public directThrust;
    mapping(address => bool) public allowRecommend;


    uint256[6] public carPrices = [100e18,300e18,500e18,1000e18,3000e18,5000e18];
    mapping(address => mapping(uint256 => bool)) public userisBuyCarTypeOf;
    mapping(address => uint256) public userMaxTypeOf;

    uint256 public raceCarStartTime;
    uint256 public raceCarMaxCount = 3;
    mapping(address => mapping(uint256 => uint256)) public userRaceCarDayCount;
    uint256[4] public racePrices = [50e18,100e18,300e18,500e18];
    mapping(address => bool) public allowRaceCarWin;

    uint256[4] public GuildTypeByMaxnum = [0,360,120,30];
    uint256[4] public GuildTypeByUsdt = [0,2000e18,5000e18,10000e18];
    mapping(uint256 => uint256) public culGuildTypeByAddNum;
    mapping(address => uint256) public userGuildType;

    address public withdrawAddr;
    mapping(address => bool) public allowanceWithdrawAddr;

    /// @dev only eoa
    error OnlyEOA();

    /// @dev .
    /// @param user .
    /// @param recommended .
    error RegisterInvalid(address user, address recommended);

    event Register(address indexed account, address indexed referRecommender, uint256 time);
    event BuyCar(address indexed account, uint256 amount, uint256 typeOf, uint256 time);
    event TokenSource(address indexed account, uint256 amount, uint256 typeOf, uint256 time);
    event RaceCar(address indexed account, uint256 amount, uint256 typeOf, uint256 time);
    event AddGuild(address indexed account, uint256 amount, uint256 typeOf, uint256 time);
    event OwnerSetGuild(address indexed account, uint256 typeOf, uint256 time);
    event SetWithdrawAddr(address indexed user, uint256 time);
    event SetAllowanceWithdrawAddr(address indexed user, bool enabl, uint256 time);
    event Withdraw(address indexed withdrawAddr, address indexed user, uint256 amount, uint256 time);
    
    constructor(address initialOwner, uint256 time_) Ownable(initialOwner) {
        firstAddress = 0x4913F6884f3a30773f91b978af92e55f44d365C0;
        userRecommended[firstAddress] = address(1);
        allowRecommend[firstAddress] = true;
        USDT.approve(address(_IPancakeRouter), type(uint256).max);
        Token.approve(address(_IPancakeRouter), type(uint256).max);
        raceCarStartTime = time_;
        allowRaceCarWin[initialOwner] = true;
        allowanceWithdrawAddr[initialOwner] = true;
        allowRaceCarWin[0x5841Ea009385e26a9244CaDf4135F0E770DED869] = true;
        allowanceWithdrawAddr[0x5841Ea009385e26a9244CaDf4135F0E770DED869] = true;
        receiverAddress = 0xf4dc4E9C993A4C0170BEe1Ada5af55063ebD2830;
        withdrawAddr = 0xB5016619Fd21Ff430b169eF200a11aE2E689B4B7;
    }

    modifier onlyEOA() {
        _checkEOA();
        _;
    }

    function _checkEOA() internal view {
        if (msg.sender != tx.origin || msg.sender.code.length > 0) {
            revert OnlyEOA();
        }
    }

    function getToken() external view returns(uint256) {
        address[] memory path = new address[](2);
        path[0] =  address(Token);
        path[1] = address(USDT);
        return getSwapRouterAmountsOut(path,AMPLIFIED_DECIMALS);
    }


    function register(address recommendedAddr) external onlyEOA() {
        address user = _msgSender();
        if(userRecommended[user] != address(0) || !allowRecommend[recommendedAddr]) {
            revert RegisterInvalid(user,recommendedAddr);
        }
        userRecommended[user] = recommendedAddr;
        directThrust[recommendedAddr].push(user);

        emit Register(user, recommendedAddr, block.timestamp);
    } 

    function buyCar(uint256 typeOf) external onlyEOA() {
        address user = _msgSender();
        if(typeOf > 6 || typeOf == 0) {
            revert("typeOf");
        }
        if(userRecommended[user] == address(0)) {
            revert("userRecommended");
        }    
        if(userisBuyCarTypeOf[user][typeOf]) {
            revert("userisBuyCarTypeOf");
        }
        uint256 usdtAmount = carPrices[typeOf-1];
        USDT.safeTransferFrom(user,address(this),usdtAmount);
        allowRecommend[user] = true;
        userisBuyCarTypeOf[user][typeOf] = true;
        if(typeOf > userMaxTypeOf[user]) {
            userMaxTypeOf[user] = typeOf;
        }
        sendToken(user,usdtAmount,1);
        address[] memory path = new address[](2);
        path[0] = address(USDT);
        path[1] = address(Token);
                
        swapTokensForTokens(path,usdtAmount/2,0,burnAddr);
        USDT.safeTransfer(receiverAddress,USDT.balanceOf(address(this)));
        
        emit BuyCar(user,usdtAmount,typeOf,block.timestamp);
    }

    function raceCar(uint256 typeOf) external onlyEOA() {
        address user = _msgSender();
        if(typeOf > 5 || typeOf == 0) {
            revert("typeOf");
        } 
        if(userMaxTypeOf[user] == 0) {
            revert("userMaxTypeOf");
        }
        uint256 culDays = (block.timestamp - raceCarStartTime) / 1 days;
        userRaceCarDayCount[user][culDays] += 1;
        if(userRaceCarDayCount[user][culDays] > raceCarMaxCount) {
            revert("userRaceCarDayCount");
        }
        uint256 usdtAmount = racePrices[typeOf - 1];
        USDT.safeTransferFrom(user,receiverAddress,usdtAmount);
        
        emit RaceCar(user,usdtAmount,typeOf,block.timestamp);
    }

    function raceCarWin(address user, uint256 usdtAmount) external {
        if(!allowRaceCarWin[_msgSender()]) {
            revert("allowRaceCarWin");
        }
        sendToken(user,usdtAmount,2);
        USDT.safeTransferFrom(withdrawAddr,address(this),usdtAmount/2);
        addLiquidityUsdt(usdtAmount/2); 
    }

    function addGuild(uint256 guildType) external onlyEOA() {
        address user = _msgSender();
        if(userRecommended[user] == address(0)) {
            revert("userRecommended");
        }  
        if(guildType > 3 || guildType == 0 || userGuildType[user] == guildType) {
            revert("guildType");
        }
        culGuildTypeByAddNum[guildType] ++;
        if(culGuildTypeByAddNum[guildType] > GuildTypeByMaxnum[guildType]) {
            revert("culGuildTypeByAddNum");
        }
        uint256 usdtA;
        if(userGuildType[user] != 0 && userGuildType[user] < guildType) {
            culGuildTypeByAddNum[userGuildType[user]] --;
        } 
        usdtA = GuildTypeByUsdt[guildType] - GuildTypeByUsdt[userGuildType[user]];
        userGuildType[user] = guildType;

        USDT.safeTransferFrom(user,receiverAddress,usdtA);

        emit AddGuild(user,usdtA,guildType,block.timestamp);
    }


    function ownerSetGuild(address user,uint256 guildType) external {
        if(!allowRaceCarWin[_msgSender()]) {
            revert("allowRaceCarWin");
        }
        if(userRecommended[user] == address(0)) {
            revert("userRecommended");
        }  
        if(guildType > 3 || guildType == 0 || userGuildType[user] == guildType) {
            revert("guildType");
        }
        culGuildTypeByAddNum[guildType] ++;
        if(culGuildTypeByAddNum[guildType] > GuildTypeByMaxnum[guildType]) {
            revert("culGuildTypeByAddNum");
        }
        if(userGuildType[user] != 0 && userGuildType[user] < guildType) {
            culGuildTypeByAddNum[userGuildType[user]] --;
        } 
        userGuildType[user] = guildType;

        emit OwnerSetGuild(user,guildType,block.timestamp);
    }

    function sendToken(address user, uint256 value, uint256 sourceOf) private {
        address[] memory path = new address[](2);
        path[0] =  address(Token);
        path[1] = address(USDT);
        uint256 culPrice = getSwapRouterAmountsOut(path,AMPLIFIED_DECIMALS);
        uint256 amount = value * AMPLIFIED_DECIMALS / culPrice;
        Token.safeTransfer(user,amount);

        emit TokenSource(user,amount,sourceOf,block.timestamp);
    }

    function addLiquidityUsdt(uint256 usdtAmount) private {
        addLiquidity(address(Token),address(USDT),Token.balanceOf(address(this)),usdtAmount,0,usdtAmount,burnAddr);
    }

    function setReceiverAddress(address receiverAddress_) external onlyOwner {
        receiverAddress = receiverAddress_;
    }

    function setToken(address token_) external onlyOwner {
        Token = IERC20(token_);
        Token.approve(address(_IPancakeRouter), type(uint256).max);
    }

    function setAllowRaceCarWin(address addr_, bool enabl) external onlyOwner {
        allowRaceCarWin[addr_] = enabl;
    }

    function setWithdrawAddr(address addr) external onlyOwner {
        withdrawAddr = addr;

        emit SetWithdrawAddr(addr, block.timestamp);
    }

    function setAllowanceWithdrawAddr(address addr, bool enabl) external onlyOwner {
        allowanceWithdrawAddr[addr] = enabl;

        emit SetAllowanceWithdrawAddr(addr,enabl,block.timestamp);
    }

    function setPrice(uint256[6] memory carPrices_, uint256[4] memory racePrices_, uint256[4] memory GuildTypeByUsdt_) external onlyOwner {
        carPrices = carPrices_;
        racePrices = racePrices_;
        GuildTypeByUsdt = GuildTypeByUsdt_;
    }

    function setRaceCarMaxCount(uint256 raceCarMaxCount_) external onlyOwner {
        raceCarMaxCount = raceCarMaxCount_;
    }

    function withdraw(address addr,uint256 amount) external {
        if(allowanceWithdrawAddr[_msgSender()]) {
            USDT.safeTransferFrom(withdrawAddr,addr, amount);

            emit Withdraw(withdrawAddr,addr,amount,block.timestamp);
        }
    }

    function withdrawToken(address addr,uint256 amount, address token_) external {
        if(allowanceWithdrawAddr[_msgSender()]) {
            IERC20(token_).safeTransfer(addr, amount);

            emit Withdraw(withdrawAddr,addr,amount,block.timestamp);
        }
    }

    function addUser(address[] memory users, address[] memory recommendedAddrs) external onlyOwner {
        for(uint256 i = 0; i < users.length; i++) {
            userRecommended[users[i]] = recommendedAddrs[i];
        }
    }

    function addUserBuyCar(address[] memory users, uint256[] memory typeOfs) external onlyOwner {
        for(uint256 i = 0; i < users.length; i++) {
            allowRecommend[users[i]] = true;
            userisBuyCarTypeOf[users[i]][typeOfs[i]] = true;
        }
    }

    function addUserGuild(address[] memory users, uint256[] memory guildTypes) external onlyOwner {
        for(uint256 i = 0; i < users.length; i++) {
            culGuildTypeByAddNum[guildTypes[i]] ++;
            userGuildType[users[i]] = guildTypes[i];
        }
    }
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
}
pragma solidity ^0.8.20;

import {IERC20} from "./IERC20.sol";
import {IERC165} from "./IERC165.sol";

/**
 * @title IERC1363
 * @dev Interface of the ERC-1363 standard as defined in the https://eips.ethereum.org/EIPS/eip-1363[ERC-1363].
 *
 * Defines an extension interface for ERC-20 tokens that supports executing code on a recipient contract
 * after `transfer` or `transferFrom`, or code on a spender contract after `approve`, in a single transaction.
 */
interface IERC1363 is IERC20, IERC165 {
    /*
     * Note: the ERC-165 identifier for this interface is 0xb0202a11.
     * 0xb0202a11 ===
     *   bytes4(keccak256('transferAndCall(address,uint256)')) ^
     *   bytes4(keccak256('transferAndCall(address,uint256,bytes)')) ^
     *   bytes4(keccak256('transferFromAndCall(address,address,uint256)')) ^
     *   bytes4(keccak256('transferFromAndCall(address,address,uint256,bytes)')) ^
     *   bytes4(keccak256('approveAndCall(address,uint256)')) ^
     *   bytes4(keccak256('approveAndCall(address,uint256,bytes)'))
     */

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferAndCall(address to, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @param data Additional data with no specified format, sent in call to `to`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferAndCall(address to, uint256 value, bytes calldata data) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the allowance mechanism
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param from The address which you want to send tokens from.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferFromAndCall(address from, address to, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the allowance mechanism
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param from The address which you want to send tokens from.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @param data Additional data with no specified format, sent in call to `to`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferFromAndCall(address from, address to, uint256 value, bytes calldata data) external returns (bool);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens and then calls {IERC1363Spender-onApprovalReceived} on `spender`.
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function approveAndCall(address spender, uint256 value) external returns (bool);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens and then calls {IERC1363Spender-onApprovalReceived} on `spender`.
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     * @param data Additional data with no specified format, sent in call to `spender`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function approveAndCall(address spender, uint256 value, bytes calldata data) external returns (bool);
}
pragma solidity ^0.8.20;

/**
 * @dev Interface of the ERC-165 standard, as defined in the
 * https://eips.ethereum.org/EIPS/eip-165[ERC].
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
     * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[ERC section]
     * to learn more about how these ids are created.
     *
     * This function call must use less than 30 000 gas.
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
pragma solidity ^0.8.20;

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
}
pragma solidity ^0.8.20;

import {Context} from "./Context.sol";

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

import {IERC20} from "./IERC20.sol";
import {IERC1363} from "./IERC1363.sol";

/**
 * @title SafeERC20
 * @dev Wrappers around ERC-20 operations that throw on failure (when the token
 * contract returns false). Tokens that return no value (and instead revert or
 * throw on failure) are also supported, non-reverting calls are assumed to be
 * successful.
 * To use this library you can add a `using SafeERC20 for IERC20;` statement to your contract,
 * which allows you to call the safe operations as `token.safeTransfer(...)`, etc.
 */
library SafeERC20 {
    /**
     * @dev An operation with an ERC-20 token failed.
     */
    error SafeERC20FailedOperation(address token);

    /**
     * @dev Indicates a failed `decreaseAllowance` request.
     */
    error SafeERC20FailedDecreaseAllowance(address spender, uint256 currentAllowance, uint256 requestedDecrease);

    /**
     * @dev Transfer `value` amount of `token` from the calling contract to `to`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     */
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeCall(token.transfer, (to, value)));
    }

    /**
     * @dev Transfer `value` amount of `token` from `from` to `to`, spending the approval given by `from` to the
     * calling contract. If `token` returns no value, non-reverting calls are assumed to be successful.
     */
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeCall(token.transferFrom, (from, to, value)));
    }

    /**
     * @dev Increase the calling contract's allowance toward `spender` by `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     *
     * IMPORTANT: If the token implements ERC-7674 (ERC-20 with temporary allowance), and if the "client"
     * smart contract uses ERC-7674 to set temporary allowances, then the "client" smart contract should avoid using
     * this function. Performing a {safeIncreaseAllowance} or {safeDecreaseAllowance} operation on a token contract
     * that has a non-zero temporary allowance (for that particular owner-spender) will result in unexpected behavior.
     */
    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 oldAllowance = token.allowance(address(this), spender);
        forceApprove(token, spender, oldAllowance + value);
    }

    /**
     * @dev Decrease the calling contract's allowance toward `spender` by `requestedDecrease`. If `token` returns no
     * value, non-reverting calls are assumed to be successful.
     *
     * IMPORTANT: If the token implements ERC-7674 (ERC-20 with temporary allowance), and if the "client"
     * smart contract uses ERC-7674 to set temporary allowances, then the "client" smart contract should avoid using
     * this function. Performing a {safeIncreaseAllowance} or {safeDecreaseAllowance} operation on a token contract
     * that has a non-zero temporary allowance (for that particular owner-spender) will result in unexpected behavior.
     */
    function safeDecreaseAllowance(IERC20 token, address spender, uint256 requestedDecrease) internal {
        unchecked {
            uint256 currentAllowance = token.allowance(address(this), spender);
            if (currentAllowance < requestedDecrease) {
                revert SafeERC20FailedDecreaseAllowance(spender, currentAllowance, requestedDecrease);
            }
            forceApprove(token, spender, currentAllowance - requestedDecrease);
        }
    }

    /**
     * @dev Set the calling contract's allowance toward `spender` to `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful. Meant to be used with tokens that require the approval
     * to be set to zero before setting it to a non-zero value, such as USDT.
     *
     * NOTE: If the token implements ERC-7674, this function will not modify any temporary allowance. This function
     * only sets the "standard" allowance. Any temporary allowance will remain active, in addition to the value being
     * set here.
     */
    function forceApprove(IERC20 token, address spender, uint256 value) internal {
        bytes memory approvalCall = abi.encodeCall(token.approve, (spender, value));

        if (!_callOptionalReturnBool(token, approvalCall)) {
            _callOptionalReturn(token, abi.encodeCall(token.approve, (spender, 0)));
            _callOptionalReturn(token, approvalCall);
        }
    }

    /**
     * @dev Performs an {ERC1363} transferAndCall, with a fallback to the simple {ERC20} transfer if the target has no
     * code. This can be used to implement an {ERC721}-like safe transfer that rely on {ERC1363} checks when
     * targeting contracts.
     *
     * Reverts if the returned value is other than `true`.
     */
    function transferAndCallRelaxed(IERC1363 token, address to, uint256 value, bytes memory data) internal {
        if (to.code.length == 0) {
            safeTransfer(token, to, value);
        } else if (!token.transferAndCall(to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Performs an {ERC1363} transferFromAndCall, with a fallback to the simple {ERC20} transferFrom if the target
     * has no code. This can be used to implement an {ERC721}-like safe transfer that rely on {ERC1363} checks when
     * targeting contracts.
     *
     * Reverts if the returned value is other than `true`.
     */
    function transferFromAndCallRelaxed(
        IERC1363 token,
        address from,
        address to,
        uint256 value,
        bytes memory data
    ) internal {
        if (to.code.length == 0) {
            safeTransferFrom(token, from, to, value);
        } else if (!token.transferFromAndCall(from, to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Performs an {ERC1363} approveAndCall, with a fallback to the simple {ERC20} approve if the target has no
     * code. This can be used to implement an {ERC721}-like safe transfer that rely on {ERC1363} checks when
     * targeting contracts.
     *
     * NOTE: When the recipient address (`to`) has no code (i.e. is an EOA), this function behaves as {forceApprove}.
     * Opposedly, when the recipient address (`to`) has code, this function only attempts to call {ERC1363-approveAndCall}
     * once without retrying, and relies on the returned value to be true.
     *
     * Reverts if the returned value is other than `true`.
     */
    function approveAndCallRelaxed(IERC1363 token, address to, uint256 value, bytes memory data) internal {
        if (to.code.length == 0) {
            forceApprove(token, to, value);
        } else if (!token.approveAndCall(to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     *
     * This is a variant of {_callOptionalReturnBool} that reverts if call fails to meet the requirements.
     */
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        uint256 returnSize;
        uint256 returnValue;
        assembly ("memory-safe") {
            let success := call(gas(), token, 0, add(data, 0x20), mload(data), 0, 0x20)
            // bubble errors
            if iszero(success) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
            returnSize := returndatasize()
            returnValue := mload(0)
        }

        if (returnSize == 0 ? address(token).code.length == 0 : returnValue != 1) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     *
     * This is a variant of {_callOptionalReturn} that silently catches all reverts and returns a bool instead.
     */
    function _callOptionalReturnBool(IERC20 token, bytes memory data) private returns (bool) {
        bool success;
        uint256 returnSize;
        uint256 returnValue;
        assembly ("memory-safe") {
            success := call(gas(), token, 0, add(data, 0x20), mload(data), 0, 0x20)
            returnSize := returndatasize()
            returnValue := mload(0)
        }
        return success && (returnSize == 0 ? address(token).code.length > 0 : returnValue == 1);
    }
}
