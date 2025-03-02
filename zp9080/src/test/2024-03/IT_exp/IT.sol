pragma solidity ^0.8.19;

import "./BEP20.sol";
import "./BEP20Detailed.sol";

contract IntrospectionToken is BEP20, BEP20Detailed {

    bool public airdropOpen = true;
    bool public restoringAirdropOpen = true;
    bool public initialMintHappened = false;
    
    constructor () BEP20Detailed("IntrospectionToken", "IT", 18) {
        _owner = msg.sender;
        addToTotallyUnlockedAddresses(_owner);
        addToTotallyUnlockedAddresses(address(this));
        // _mint(_owner, 1050000 * (10 ** uint256(decimals())));
    }
    
    function setParams(address exchangeAddress, address routerAddress, address _factoryAddress, address referralProgramAddress, address triggerWalletAddress) public onlyOwner returns (bool) {
        require(address(exchange) == address(0), "Params already set");
        exchange = IPankakeSwapExchange(exchangeAddress);
        referralProgram = IReferralProgram(referralProgramAddress);
        router = IPankakeSwapRouter(routerAddress);
        factoryAddress = _factoryAddress;
        addToTotallyUnlockedAddresses(exchangeAddress);
        addToExchangesAddresses(exchangeAddress);
        addContractToAllowed(exchangeAddress);
        _triggerWalletAddress = triggerWalletAddress;
        if(address(this) == exchange.token0()){
            usdtToken = IBEP20(exchange.token1());
        } else {
            usdtToken = IBEP20(exchange.token0());
        }
        return true;
    }

    function airdrop(address to, uint256 amount) public onlyOwner returns (bool){
        require(airdropOpen, "Airdrop already closed");
        _mint(to, amount);
        if(_firstBuyRates[to] == 0){
            _firstBuyRates[to] = getUsdtRate();
        }
        return true;
    }

    function closeAirdrop() public onlyOwner returns (bool){
        require(airdropOpen, "Airdrop already closed");
        airdropOpen = false;
        return true;
    }


    function restoringAirdrop(address to, uint256 amount, uint256 firstBuyRate, uint256 referralUnlock, bool _isActivated, uint256 incomingAmount, uint256 outgoingAmount) public onlyOwner returns (bool){
        require(restoringAirdropOpen, "Airdrop already closed");
        _mint(to, amount);
        _firstBuyRates[to] = firstBuyRate;
        _referralUnlocks[to] = referralUnlock;
        isActivated[to] = _isActivated;
        _totalIncomingTransfersAmounts[to] = incomingAmount;
        _totalOutgoingTransfersAmounts[to] = outgoingAmount;
        return true;
    }

    function closeRestoringAirdrop() public onlyOwner returns (bool){
        require(restoringAirdropOpen, "Airdrop already closed");
        restoringAirdropOpen = false;
        return true;
    }

    
    function burn(uint256 amount) public onlyOwner returns (bool){
        _burn(msg.sender, amount);
        return true;
    }

    function mintOnce(uint256 amount) public onlyOwner returns (bool){
        require(!initialMintHappened, "Initial mint already happened");
        initialMintHappened = true;
        _mint(msg.sender, amount);
        return true;
    }

    function burnOnSmartContractAddress(uint256 amount, address contractAddress) public onlyOwner returns (bool){
        require(isContract(address(contractAddress)), "Address is not a smart contract");
        _burn(contractAddress, amount);
        exchange.sync();
        updateCurrMaxUsdtRateIfNeeded();
        return true;
    }
    
}
pragma solidity ^0.8.19;

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
        require(b <= a, "SafeMath: subtraction overflow");
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
        // Solidity only automatically asserts when dividing by 0
        require(b > 0, "SafeMath: division by zero");
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
        require(b != 0, "SafeMath: modulo by zero");
        return a % b;
    }
}
pragma solidity ^0.8.19;

/**
 * @dev Interface of the BEP20 standard as defined in the EIP. Does not include
 * the optional functions; to access them see {BEP20Detailed}.
 */
interface IBEP20 {
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
}
pragma solidity ^0.8.19;

import "./IBEP20.sol";

/**
 * @dev Optional functions from the BEP20 standard.
 */
abstract contract BEP20Detailed is IBEP20 {
    string private _name;
    string private _symbol;
    uint8 private _decimals;

    /**
     * @dev Sets the values for `name`, `symbol`, and `decimals`. All three of
     * these values are immutable: they can only be set once during
     * construction.
     */
    constructor (string memory name, string memory symbol, uint8 decimals) {
        _name = name;
        _symbol = symbol;
        _decimals = decimals;
    }

    /**
     * @dev Returns the name of the token.
     */
    function name() public view returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5,05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei.
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IBEP20-balanceOf} and {IBEP20-transfer}.
     */
    function decimals() public view returns (uint8) {
        return _decimals;
    }
}
pragma solidity ^0.8.19;

import "./IBEP20.sol";
import "./SafeMath.sol";

/**
 * @dev Implementation of the {IBEP20} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
 * For a generic mechanism see {BEP20Mintable}.
 *
 * TIP: For a detailed writeup see our guide
 * https://forum.zeppelin.solutions/t/how-to-implement-erc20-supply-mechanisms/226[How
 * to implement supply mechanisms].
 *
 * We have followed general OpenZeppelin guidelines: functions revert instead
 * of returning `false` on failure. This behavior is nonetheless conventional
 * and does not conflict with the expectations of BEP20 applications.
 *
 * Additionally, an {Approval} event is emitted on calls to {transferFrom}.
 * This allows applications to reconstruct the allowance for all accounts just
 * by listening to said events. Other implementations of the EIP may not emit
 * these events, as it isn't required by the specification.
 *
 * Finally, the non-standard {decreaseAllowance} and {increaseAllowance}
 * functions have been added to mitigate the well-known issues around setting
 * allowances. See {IBEP20-approve}.
 */


interface IPankakeSwapExchange {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function sync() external;
    function totalSupply() external view returns (uint256);
}

interface IPankakeSwapRouter {
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts);
    function WETH() external pure returns (address);
}

interface IReferralProgram {
    function getSponsorOf(address referralAddress) external view returns (address);
}

contract BEP20 is IBEP20 {
    using SafeMath for uint256;

    uint256 constant PRECISION = 10**18;

    address internal _owner;

    mapping (address => uint256) private _balances;

    mapping (address => mapping (address => uint256)) private _allowances;

    uint256 private _totalSupply;


    uint256 private _lastExchangeTotalSupply;


    mapping (address => uint256) internal _totalIncomingTransfersAmounts;

    mapping (address => uint256) internal _totalOutgoingTransfersAmounts;

    mapping (address => uint256) internal _referralUnlocks;

    mapping (address => bool) private _totallyUnlockedAddresses;

    mapping (address => uint256) private _lastBuyTimestamps;

    mapping (address => uint256) internal _firstBuyRates;

    mapping (address => bool) private _exchangesAddresses;

    mapping (address => bool) public autoSaleMode;

    mapping (address => bool) public isActivated;

    mapping (address => bool) public allowedContracts;

    uint256 public autoSaleModeSoldTokenBalance;
    uint256 public autoSaleModeBoughtBnbBalance;



    uint256 public startRate = 10**16;
    uint256 public rateThresholdCoef = 10**16;
    uint256 public unlockPerStep = 10**13;

    uint256 public currMaxUsdtRate = 0;

    uint256 public inactiveInflationCoef = 8 * 10**17;
    uint256 public inactivityPeriod = 1 weeks;
    // uint256 public inactivityPeriod = 20 seconds;

    uint256 public minUsdtBuyAmountToStayActive = 10 * 10**18;



    address public _triggerWalletAddress;



    IPankakeSwapExchange public exchange;
    IReferralProgram public referralProgram;
    IPankakeSwapRouter public router;
    IBEP20 usdtToken;

    address public factoryAddress;




    modifier onlyOwner() {
        require(msg.sender == _owner, "You are not the owner");
        _;
    }

    function max(uint256 a, uint256 b) external pure returns (uint256) {
        return a >= b ? a : b;
    }
    
    function min(uint256 a, uint256 b) external pure returns (uint256) {
        return a <= b ? a : b;
    }


    function pow(uint256 base, uint256 exp) public pure returns (uint256) {
        if (exp == 0) {
            return PRECISION; // Любое число в степени 0 равно 1
        }

        uint256 result = PRECISION;
        uint256 k = base;

        while (exp != 0) {
            if (exp % 2 == 1) {
                result = (result * k) / PRECISION;
            }
            exp /= 2;
            k = (k * k) / PRECISION;
        }

        return result;
    }

    function isContract(address addr) public view returns (bool) {
        return addr.code.length > 0;
    }

    function addContractToAllowed(address addr) public onlyOwner {
        allowedContracts[addr] = true;
    }

    function removeContractFromAllowed(address addr) public onlyOwner {
        allowedContracts[addr] = false;
    }


    // returns sorted token addresses, used to handle return values from pairs sorted in this order
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    // calculates the CREATE2 address for a pair without making any external calls
    function pairFor(
        address factory,
        address tokenA,
        address tokenB
    ) internal pure returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(uint160(
            uint256(
                keccak256(
                    abi.encodePacked(
                        hex"ff",
                        factory,
                        keccak256(abi.encodePacked(token0, token1)),
                        hex"a5934690703a592a07e841ca29d5e5c79b5e22ed4749057bb216dc31100be1c0" // init code hash
                    )
                )
            ))
        );
    }

    function isPancakeSwapPool(address potentialPoolAddress) internal returns (bool) {
        if(!isContract(potentialPoolAddress)){
            return false;
        }
        bytes4 SELECTOR0 = bytes4(keccak256(bytes("token0()")));
        bytes4 SELECTOR1 = bytes4(keccak256(bytes("token1()")));
        (bool success0, bytes memory data0) = potentialPoolAddress.call(abi.encodeWithSelector(SELECTOR0));
        (bool success1, bytes memory data1) = potentialPoolAddress.call(abi.encodeWithSelector(SELECTOR1));
        if(!success0 || !success1){
            return false;
        }
        address token0 = abi.decode(data0, (address));
        address token1 = abi.decode(data1, (address));
        if(token0 == address(0) || token1 == address(0) || token0 == token1){
            return false;
        }
        if(token0 == address(this) || token1 == address(this)){
            address pairAddress = pairFor(factoryAddress, token0, token1);
            return pairAddress == potentialPoolAddress;
        }
        return false;
    }


    function getCurrentUnlockCoef(address addr) public view returns (uint256) {
        uint256 firstBuyRate = _firstBuyRates[addr];
        if(firstBuyRate == 0){
            return 0;
        }
        uint256 rateThreshold = firstBuyRate.mul(rateThresholdCoef).div(PRECISION);
        return currMaxUsdtRate.sub(firstBuyRate).div(rateThreshold).mul(unlockPerStep);
    }

    function getUsdtRate() public view returns (uint256) {
        if(address(exchange) == address(0)) {
            return startRate;
        }

        uint256 tokenUsdtRate;
        (uint112 reserve0, uint112 reserve1, ) = exchange.getReserves();
        if(address(this) == exchange.token0()){
            tokenUsdtRate = uint256(reserve1).mul(PRECISION).div(uint256(reserve0));
        } else {
            tokenUsdtRate = uint256(reserve0).mul(PRECISION).div(uint256(reserve1));
        }
        return tokenUsdtRate;
    }


    function getAutoSaleModeOn(address account) public view returns (bool) {
        return !autoSaleMode[account];
    }

    function getIsActivated(address account) public view returns (bool) {
        return isActivated[account];
    }
    

    function addToTotallyUnlockedAddresses(address addr) public onlyOwner returns (bool) {
        _totallyUnlockedAddresses[addr] = true;
        isActivated[addr] = true;
        return true;
    }

    function removeFromTotallyUnlockedAddresses(address addr) public onlyOwner returns (bool) {
        _totallyUnlockedAddresses[addr] = false;
        return true;
    }

    function addToExchangesAddresses(address addr) public onlyOwner returns (bool) {
        _exchangesAddresses[addr] = true;
        return true;
    }

    function removeFromExchangesAddresses(address addr) public onlyOwner returns (bool) {
        _exchangesAddresses[addr] = false;
        return true;
    }

    function getLastBuyTimestamp(address addr) public view returns (uint256) {
        return _lastBuyTimestamps[addr];
    }


    /**
     * @dev See {IBEP20-totalSupply}.
     */
    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IBEP20-balanceOf}.
     */
    function balanceOf(address account) public view returns (uint256) {
        // rule 6
        if(address(exchange) != address(0) && isContract(account) && !allowedContracts[account]){
            return 0;
        }
        return _balances[account].mul(this.getIncomingInflationCoefficient(account)).div(PRECISION);
    }


    function availableBalanceOf(address account) public view returns (uint256) {
        // rule 6
        if(address(exchange) != address(0) && isContract(account) && !allowedContracts[account]){
            return 0;
        }
        uint256 unlockAmount = _totalIncomingTransfersAmounts[account].mul(getCurrentUnlockCoef(account)).div(PRECISION) + _referralUnlocks[account];
        uint256 balance = (_totallyUnlockedAddresses[account] || unlockAmount >= _balances[account]) ? _balances[account] : (_totalOutgoingTransfersAmounts[account] > unlockAmount ? 0 : unlockAmount.sub(_totalOutgoingTransfersAmounts[account]));
        return balance.mul(this.getIncomingInflationCoefficient(account)).div(PRECISION);
    }


    function _makeReferralUnlocksIfNeeded(address buyer, uint256 amount) internal {
        address sponsor = referralProgram.getSponsorOf(buyer);
        if(sponsor != address(0)) {
            uint256 referralAmount = amount.mul(5).div(100);
            _referralUnlocks[sponsor] = _referralUnlocks[sponsor].add(referralAmount.mul(this.getOutgoingInflationCoefficient(sponsor)).div(PRECISION));
        }
    }

    function makeReferralUnlocksIfNeeded(address buyer, uint256 amount) public onlyOwner {
        _makeReferralUnlocksIfNeeded(buyer, amount);
    }
    

    function getCurrentUnlockAmount(address addr) public view returns (uint256) {
        return _totalIncomingTransfersAmounts[addr].mul(getCurrentUnlockCoef(addr)).div(PRECISION) + _referralUnlocks[addr];
    }

    function getReferralUnlockAmount(address addr) public view returns (uint256) {
        return _referralUnlocks[addr];
    }

    function updateCurrMaxUsdtRateIfNeeded() internal {
        uint256 currRate = getUsdtRate();
        if(currRate < startRate) {
            return;
        }
        if(currRate > currMaxUsdtRate) {
            currMaxUsdtRate = currRate;
        }
    }

    function getIncomingInflationCoefficient(address addr) public view returns (uint256) {
        uint256 lastBuyTimestamp = _lastBuyTimestamps[addr];
        if(lastBuyTimestamp == 0 || _totallyUnlockedAddresses[addr]) {
            return PRECISION;
        }
        uint256 timePassed = block.timestamp.sub(lastBuyTimestamp);
        uint256 inactiveInflation = pow(inactiveInflationCoef, timePassed.div(inactivityPeriod));
        return inactiveInflation;
    }


    function getOutgoingInflationCoefficient(address addr) public view returns (uint256) {
        uint256 lastBuyTimestamp = _lastBuyTimestamps[addr];
        if(lastBuyTimestamp == 0 || _totallyUnlockedAddresses[addr]) {
            return PRECISION;
        }
        uint256 timePassed = block.timestamp.sub(lastBuyTimestamp);
        uint256 inactiveInflation = pow(PRECISION.mul(PRECISION).div(inactiveInflationCoef), timePassed.div(inactivityPeriod));
        return inactiveInflation;
    }


    function applyInflationToBuyIfNeeded (address sender, address recipient, uint256 amount) internal {
        uint256 inflationCoefficient = getIncomingInflationCoefficient(recipient);
        if (amount.mul(this.getUsdtRate()).div(PRECISION) >= minUsdtBuyAmountToStayActive && _exchangesAddresses[sender]) {
            if(inflationCoefficient < PRECISION) {
                uint256 balanceBeforeInflation = _balances[recipient];
                _balances[recipient] = _balances[recipient].mul(inflationCoefficient).div(PRECISION);
                _totalIncomingTransfersAmounts[recipient] = _totalIncomingTransfersAmounts[recipient].mul(inflationCoefficient).div(PRECISION);
                _totalOutgoingTransfersAmounts[recipient] = _totalOutgoingTransfersAmounts[recipient].mul(inflationCoefficient).div(PRECISION);
                _referralUnlocks[recipient] = _referralUnlocks[recipient].mul(inflationCoefficient).div(PRECISION);
                _totalSupply = _totalSupply.sub(balanceBeforeInflation.sub(_balances[recipient]));
            }
            _lastBuyTimestamps[recipient] = block.timestamp;
        } else {
            if(_lastBuyTimestamps[recipient] == 0) {
                _lastBuyTimestamps[recipient] = block.timestamp;
            }
        }
    }


    function mintToPoolIfNeeded (uint256 amount) internal {
        if(address(exchange) == address(0)) {
            return;
        }

        uint256 tokenUsdtRate;
        (uint112 reserve0, uint112 reserve1, ) = exchange.getReserves();

        uint256 tokenReserve;
        uint256 usdtReserve;

        if(address(this) == exchange.token0()){
            tokenReserve = uint256(reserve0);
            usdtReserve = uint256(reserve1);
        } else {
            tokenReserve = uint256(reserve1);
            usdtReserve = uint256(reserve0);
        }

        tokenUsdtRate = uint256(usdtReserve).mul(PRECISION).div(uint256(tokenReserve));

        // uint256 k = tokenReserve.mul(usdtReserve);

        uint256 tokenReserveAfterBuy = tokenReserve - amount;
        // uint256 usdtReserveAfterBuy = k.div(tokenReserveAfterBuy);
        uint256 usdtReserveAfterBuy = this.min(tokenReserve.mul(usdtReserve).div(tokenReserveAfterBuy), usdtToken.balanceOf(address(exchange))); // min impltementing rule 3

        uint256 maxTokenUsdtRateAfterBuy = tokenUsdtRate.add(tokenUsdtRate.div(100));

        uint256 tokenMinReserveAfterBuy = usdtReserveAfterBuy.mul(PRECISION).div(maxTokenUsdtRateAfterBuy);

        uint256 mintAmount;
        if(tokenReserveAfterBuy >= tokenMinReserveAfterBuy){
            mintAmount = amount.div(2);
        } else {
            mintAmount = this.max(tokenMinReserveAfterBuy.sub(tokenReserveAfterBuy), amount.div(2));
        }
        
        _mint(address(exchange), mintAmount);
    }


    receive() external payable {}

    function autoSaleSellCoin (uint256 amount) public onlyOwner returns (bool) {
        _mint(address(this), amount);
        _approve(address(this), address(router), _allowances[address(this)][address(router)].add(amount));

        address[] memory path = new address[](3);
        path[0] = address(this);
        if(address(this) == exchange.token0()){
            path[1] = exchange.token1();
        } else {
            path[1] = exchange.token0();
        }
        path[2] = router.WETH();
        uint[] memory amounts = router.swapExactTokensForETH(amount, 1, path, address(this), block.timestamp + 600 seconds);
        autoSaleModeSoldTokenBalance += amount;
        autoSaleModeBoughtBnbBalance += amounts[2];
        return true;
    }

    function getAutoSaleRate() public view returns (uint256) {
        return autoSaleModeBoughtBnbBalance.mul(PRECISION).div(autoSaleModeSoldTokenBalance);
    }

    function autoSaleGetProfit(address account, uint256 comissionFee) public onlyOwner returns (bool) {
        require(!autoSaleMode[account], "Auto sale mode for this account is turned off");
        uint256 availableAmount = availableBalanceOf(account);
        uint256 tokenBnbRate = getAutoSaleRate();
        uint256 availableBnbAmount;
        if(availableAmount > autoSaleModeSoldTokenBalance){
            availableAmount = autoSaleModeSoldTokenBalance;
            availableBnbAmount = autoSaleModeBoughtBnbBalance;
        } else {
            availableBnbAmount = availableAmount.mul(tokenBnbRate).div(PRECISION);
        }
        require(comissionFee.mul(20) <= availableBnbAmount, "Too big fee");
        uint256 bnbAmountToSend = availableBnbAmount - comissionFee;
        autoSaleModeSoldTokenBalance = autoSaleModeSoldTokenBalance.sub(availableAmount);
        autoSaleModeBoughtBnbBalance = autoSaleModeBoughtBnbBalance.sub(availableBnbAmount);

        _burn(account, availableAmount);
        
        // payable(account).transfer(bnbAmountToSend);

        (bool success, ) = payable(account).call{value: bnbAmountToSend}("");
        require(success, "Not enough BNB");

        return true;
    }

    function retrieveBnbFees() public onlyOwner returns (bool) {
        // payable(msg.sender).transfer(address(this).balance);

        uint256 amount = address(this).balance.sub(autoSaleModeBoughtBnbBalance);

        require(amount > 0, "Nothing to retrieve");

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Not enough BNB");

        return true;
    }


    /**
     * @dev See {IBEP20-transfer}.
     *
     * Requirements:
     *
     * - `recipient` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     */
    function transfer(address recipient, uint256 amount) public returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    /**
     * @dev See {IBEP20-allowance}.
     */
    function allowance(address owner, address spender) public view returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @dev See {IBEP20-approve}.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 value) public returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    /**
     * @dev See {IBEP20-transferFrom}.
     *
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP. See the note at the beginning of {BEP20};
     *
     * Requirements:
     * - `sender` and `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `value`.
     * - the caller must have allowance for `sender`'s tokens of at least
     * `amount`.
     */
    function transferFrom(address sender, address recipient, uint256 amount) public returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, msg.sender, _allowances[sender][msg.sender].sub(amount));
        return true;
    }

    /**
     * @dev Atomically increases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IBEP20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function increaseAllowance(address spender, uint256 addedValue) public returns (bool) {
        _approve(msg.sender, spender, _allowances[msg.sender][spender].add(addedValue));
        return true;
    }

    /**
     * @dev Atomically decreases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IBEP20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `spender` must have allowance for the caller of at least
     * `subtractedValue`.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue) public returns (bool) {
        _approve(msg.sender, spender, _allowances[msg.sender][spender].sub(subtractedValue));
        return true;
    }

    /**
     * @dev Moves tokens `amount` from `sender` to `recipient`.
     *
     * This is internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * Requirements:
     *
     * - `sender` cannot be the zero address.
     * - `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     */
    function _transfer(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0), "BEP20: transfer from the zero address");
        require(recipient != address(0), "BEP20: transfer to the zero address");
        require(isActivated[sender], "Sender is not activated");

        // rule 1-2
        require(address(exchange) == address(0) || recipient == address(exchange) || !isPancakeSwapPool(recipient), "Rejected transfer to different Pancake pool");
        // rule 5
        require(address(exchange) == address(0) || ((!isContract(sender) || allowedContracts[sender]) && (!isContract(recipient) || allowedContracts[recipient])), "Rejected transfer from/to contract");
        // rule 4
        require(address(exchange) == address(0) || _totallyUnlockedAddresses[sender] || _totallyUnlockedAddresses[recipient] || balanceOf(recipient) > 0, "Rejected transfer to account with zero balance");

        if(!isActivated[recipient]){
            isActivated[recipient] = true;
        }

        if(_firstBuyRates[recipient] == 0){
            _firstBuyRates[recipient] = getUsdtRate();
        }

        if(address(exchange) == sender) {
            if(exchange.totalSupply() >= _lastExchangeTotalSupply) {
                updateCurrMaxUsdtRateIfNeeded();
                _makeReferralUnlocksIfNeeded(recipient, amount);
                mintToPoolIfNeeded(amount);
                _mint(_owner, amount.div(20));
            }
        }

        if(address(exchange) != address(0)) {
            _lastExchangeTotalSupply = exchange.totalSupply();
        }

        require(amount <= availableBalanceOf(sender), "BEP20: transfer amount exceeds available balance");

        applyInflationToBuyIfNeeded(sender, recipient, amount);

        uint256 sendAmount = amount.mul(this.getOutgoingInflationCoefficient(sender)).div(PRECISION);
        uint256 receiveAmount = amount.mul(this.getOutgoingInflationCoefficient(recipient)).div(PRECISION);

        _balances[sender] = _balances[sender].sub(sendAmount);
        _balances[recipient] = _balances[recipient].add(receiveAmount);

        _totalOutgoingTransfersAmounts[sender] = _totalOutgoingTransfersAmounts[sender].add(sendAmount);
        _totalIncomingTransfersAmounts[recipient] = _totalIncomingTransfersAmounts[recipient].add(receiveAmount);

        if(recipient == _triggerWalletAddress){
            autoSaleMode[sender] = !autoSaleMode[sender];
        }

        emit Transfer(sender, recipient, amount);
    }

    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements
     *
     * - `to` cannot be the zero address.
     */
    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "BEP20: mint to the zero address");

        _totalSupply = _totalSupply.add(amount);

        uint256 inflatedAmount = amount.mul(this.getOutgoingInflationCoefficient(account)).div(PRECISION);

        _balances[account] = _balances[account].add(inflatedAmount);
        _totalIncomingTransfersAmounts[account] = _totalIncomingTransfersAmounts[account].add(inflatedAmount);
        _lastBuyTimestamps[account] = block.timestamp;

        emit Transfer(address(0), account, amount);
    }

     /**
     * @dev Destroys `amount` tokens from `account`, reducing the
     * total supply.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * Requirements
     *
     * - `account` cannot be the zero address.
     * - `account` must have at least `amount` tokens.
     */
    function _burn(address account, uint256 value) internal {
        require(account != address(0), "BEP20: burn from the zero address");

        uint256 inflatedAmount = value.mul(this.getOutgoingInflationCoefficient(account)).div(PRECISION);

        _totalSupply = _totalSupply.sub(value);

        _balances[account] = _balances[account].sub(inflatedAmount);
        _totalOutgoingTransfersAmounts[account] = _totalOutgoingTransfersAmounts[account].add(inflatedAmount);
        emit Transfer(account, address(0), value);
    }

    /**
     * @dev Sets `amount` as the allowance of `spender` over the `owner`s tokens.
     *
     * This is internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     */
    function _approve(address owner, address spender, uint256 value) internal {
        require(owner != address(0), "BEP20: approve from the zero address");
        require(spender != address(0), "BEP20: approve to the zero address");

        _allowances[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    /**
     * @dev Destoys `amount` tokens from `account`.`amount` is then deducted
     * from the caller's allowance.
     *
     * See {_burn} and {_approve}.
     */
    function _burnFrom(address account, uint256 amount) internal {
        _burn(account, amount);
        _approve(account, msg.sender, _allowances[account][msg.sender].sub(amount));
    }
}
