pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";
import "../interfaces/IFeeManager.sol";
import "../interfaces/IRewardManager.sol";

contract HedgeToken is ERC20PresetMinterPauser {
    
    // Transfers are disabled until the initial liquidity is locked
    bool public transfersEnabled = false;

    // Set this here for rebrading
    string private _name_;
    string private _symbol_;
    // DECIMALS
    uint256 public constant DECIMALS = 18;
   
    // Transaction fee in %
    uint256 public buyFee = 18;

    // Transaction fee in %
    uint256 public sellFee = 20;
   
    // Initial supply 250M
    uint256 public constant INITIAL_SUPPLY = 250_000_000 * (10**DECIMALS);

    // Max supply 1B,
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * (10**DECIMALS);

    // If accumulated fees are grather than this threshold we will call the FeeManager to process our fees
    uint256 public feeDistributionMinAmount = 2000;

    // The Fee Manager
    IFeeManager public feeManager;

    // The rewards manager
    IRewardManager public rewardsManager;

    // Exlcude from fees
    mapping(address => bool) private _excludedFromFee;

    // store addresses that a automatic market maker pairs. Any transfer *to* these addresses
    // could be subject to a maximum transfer amount
    mapping (address => bool) public automatedMarketMakerPairs;

    // esential addresses needed for the system to work
    mapping (address => bool) public essentialAddress;

    // EVENTS
    event ExcludedFromFee(address indexed account, bool isExcluded);
    event UpdateFeeManger(address oldAddress, address newAddress);
    event UpdateRewardsManger(address oldAddress, address newAddress);
    event Log(string message);
    event LogBytes(bytes data);

    constructor() ERC20PresetMinterPauser("_", "_") {
        _mint(_msgSender(), INITIAL_SUPPLY);
        _name_ = "HedgePay";
        _symbol_ = "HPAY";
    }

    function name() public view override returns (string memory) {
        return _name_;
    }

    function symbol() public view override returns (string memory) {
        return _symbol_;
    }

    
    function setName(string calldata _name) external onlyRole(DEFAULT_ADMIN_ROLE)  {
        _name_ = _name;
    }

    function setSymbol(string calldata _symbol) external onlyRole(DEFAULT_ADMIN_ROLE)  {
        _symbol_ = _symbol;
    }

    function setBuyFee(uint8 newFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newFee <= 100, "Fee cannot be greater than 100%"); 
        buyFee = newFee;
    }

    function setSellFee(uint8 newFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newFee <= 100, "Fee cannot be greater than 100%"); 
        sellFee = newFee;
    }

    function enableTransfers() external onlyRole(DEFAULT_ADMIN_ROLE) {
       transfersEnabled = true;
    }

    function setFeeDistributionMinAmount(uint256 minAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        feeDistributionMinAmount = minAmount;
    }

    function isExcludedFromFee(address account) public view returns (bool) {
        return _excludedFromFee[account];
    }

    function updateEssentialAddress(address account, bool status) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(essentialAddress[account] != status, "HPAY: Address status allready set");
        essentialAddress[account] = status;
    }

    function excludeFromFee(address account, bool status) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_excludedFromFee[account] != status, "Address already exclude already set");
        _excludedFromFee[account] = status;
        emit ExcludedFromFee(account, status);
    }

    function _mint(address account, uint256 amount) internal override {
        require(totalSupply() + amount <= MAX_SUPPLY, "cap exceeded");

        uint256 oldBalance = balanceOf(account);

        super._mint(account, amount);
        if (address(rewardsManager) != address(0)) {
            rewardsManager.notifyBalanceUpdate(account, oldBalance);
        }
    }

    function _burn(address account, uint256 amount) internal override {
        uint256 oldBalance = balanceOf(account);
        super._burn(account, amount);
        if (address(rewardsManager) != address(0)) {
            rewardsManager.notifyBalanceUpdate(account, oldBalance);
        }
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        require(transfersEnabled || essentialAddress[from] || essentialAddress[to], "Transfers not allowed");

        if (amount == 0) {
            super._transfer(from, to, 0);
            return;
        }

        uint256 currentBalanceFrom = balanceOf(from);   
        uint256 currentBalanceTo = balanceOf(to);
        
        //  Deduct the fee if necessary
        uint256 fees = calculateFee(amount, from, to);
        if (fees > 0) {
            super._transfer(from, address(this), fees);
        }
        super._transfer(from, to, amount - fees);
        handleBalanceUpdate(from, to, currentBalanceFrom, currentBalanceTo);
        _distributeFee();
    }

    function calculateFee(uint256 amount, address from, address to) internal view returns(uint256) {
        if (_excludedFromFee[from] || _excludedFromFee[to]) {
            return 0;
        }
    
        if(automatedMarketMakerPairs[to]) {
            return (amount * sellFee) / 100;
        } else {
             return (amount * buyFee) / 100;
        }
    }

    function _distributeFee() internal {
        uint256 feeBalance = balanceOf(address(this));
        if (address(feeManager) != address(0) && feeBalance >= feeDistributionMinAmount) {
            // Call super transfer function directly to bypass fees and avoid loop
            super._transfer(address(this), address(feeManager), feeBalance);
            feeManager.processFee();
        }
    }

    function distributeFee() external { 
        require(address(feeManager) != address(0), "Fee Manager Not Set");
        require(balanceOf(address(this)) >= feeDistributionMinAmount, "Not enough fee balance" );
        _distributeFee();
    }

    function handleBalanceUpdate( address from, address to, uint256 oldBalanceFrom, uint256 oldBlanceTo) internal {
        if (address(rewardsManager) != address(0)) {
            rewardsManager.notifyBalanceUpdate(from, oldBalanceFrom);
            rewardsManager.notifyBalanceUpdate(to, oldBlanceTo) ;
        }
    }

    function updateFeeManager(address newAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newAddress != address(feeManager),"Fee Manager Address Unchanged");
        emit UpdateFeeManger(address(feeManager), newAddress); 
        feeManager = IFeeManager(newAddress); 
    }

    function updateRewardManager(address newAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newAddress != address(rewardsManager),"Rewards Manager Address Unchanged");
        emit UpdateRewardsManger(address(rewardsManager), newAddress);
        rewardsManager = IRewardManager(newAddress);  
    }

    function setAutomatedMarketMakerPair(address _address, bool status) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_address != address(0), "Pair cannot be 0x00 address");
        require(automatedMarketMakerPairs[_address] != status, "Pair already set");

        automatedMarketMakerPairs[_address] = status;
    }
}
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../../interfaces/IFundProcessor.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract PaymentSplitter is IFundProcessor, Ownable {
    using SafeERC20 for IERC20;
    address[3] addresses;

    constructor(
        address _addr1,
        address _addr2,
        address _addr3
    ) {
        addresses[0] = _addr1;
        addresses[1] = _addr2;
        addresses[2] = _addr3;
    }

    function processFunds(IERC20 token, uint256 amount) override external {
        token.safeTransferFrom(msg.sender, address(this), amount);     
        distribute(token);
    }

    function distribute(IERC20 token) public {
        uint256 splitAmount = token.balanceOf(address(this)) / 3;
        if (
            splitAmount == 0 ||
            addresses[0] == address(0) ||
            addresses[1] == address(0) ||
            addresses[2] == address(0)
        ) {
            return;
        }
        if (splitAmount > 0) {
            token.safeTransfer(addresses[0], splitAmount);
            token.safeTransfer(addresses[1], splitAmount);
            token.safeTransfer(addresses[2], token.balanceOf(address(this)));
        }
    }

    function setAddress(uint256 index, address newAddress) external onlyOwner  {
        require(address(0) != newAddress, "Address cannot be 0");
        addresses[index] = newAddress;
    }

    function getAddress(uint256 index) external view onlyOwner returns(address)  {
        return addresses[index];
    }

    function saveTokens(IERC20 token, address destination) external onlyOwner {
        token.safeTransfer(destination, token.balanceOf(address(this)));
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
 * https://forum.zeppelin.solutions/t/how-to-implement-erc20-supply-mechanisms/226[How
 * to implement supply mechanisms].
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
     * The default value of {decimals} is 18. To select a different value for
     * {decimals} you should overload it.
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
     * Ether and Wei. This is the value {ERC20} uses, unless this function is
     * overridden;
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
     * - `recipient` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     */
    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
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
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP. See the note at the beginning of {ERC20}.
     *
     * Requirements:
     *
     * - `sender` and `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     * - the caller must have allowance for ``sender``'s tokens of at least
     * `amount`.
     */
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public virtual override returns (bool) {
        _transfer(sender, recipient, amount);

        uint256 currentAllowance = _allowances[sender][_msgSender()];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        unchecked {
            _approve(sender, _msgSender(), currentAllowance - amount);
        }

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
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender] + addedValue);
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
        uint256 currentAllowance = _allowances[_msgSender()][spender];
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        unchecked {
            _approve(_msgSender(), spender, currentAllowance - subtractedValue);
        }

        return true;
    }

    /**
     * @dev Moves `amount` of tokens from `sender` to `recipient`.
     *
     * This internal function is equivalent to {transfer}, and can be used to
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
    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        _beforeTokenTransfer(sender, recipient, amount);

        uint256 senderBalance = _balances[sender];
        require(senderBalance >= amount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _balances[sender] = senderBalance - amount;
        }
        _balances[recipient] += amount;

        emit Transfer(sender, recipient, amount);

        _afterTokenTransfer(sender, recipient, amount);
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
        _balances[account] += amount;
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
        }
        _totalSupply -= amount;

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
    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
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
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {}

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
    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {}
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
        _setOwner(_msgSender());
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
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
        _setOwner(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        _setOwner(newOwner);
    }

    function _setOwner(address newOwner) private {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}
pragma solidity 0.8.9;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IFundProcessor {
    function processFunds(IERC20 token, uint256 amount) external;
}
pragma solidity ^0.8.0;

import "../IERC20.sol";
import "../../../utils/Address.sol";

/**
 * @title SafeERC20
 * @dev Wrappers around ERC20 operations that throw on failure (when the token
 * contract returns false). Tokens that return no value (and instead revert or
 * throw on failure) are also supported, non-reverting calls are assumed to be
 * successful.
 * To use this library you can add a `using SafeERC20 for IERC20;` statement to your contract,
 * which allows you to call the safe operations as `token.safeTransfer(...)`, etc.
 */
library SafeERC20 {
    using Address for address;

    function safeTransfer(
        IERC20 token,
        address to,
        uint256 value
    ) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    function safeTransferFrom(
        IERC20 token,
        address from,
        address to,
        uint256 value
    ) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }

    /**
     * @dev Deprecated. This function has issues similar to the ones found in
     * {IERC20-approve}, and its usage is discouraged.
     *
     * Whenever possible, use {safeIncreaseAllowance} and
     * {safeDecreaseAllowance} instead.
     */
    function safeApprove(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        // safeApprove should only be called when setting an initial allowance,
        // or when resetting it to zero. To increase and decrease it, use
        // 'safeIncreaseAllowance' and 'safeDecreaseAllowance'
        require(
            (value == 0) || (token.allowance(address(this), spender) == 0),
            "SafeERC20: approve from non-zero to non-zero allowance"
        );
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, value));
    }

    function safeIncreaseAllowance(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        uint256 newAllowance = token.allowance(address(this), spender) + value;
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
    }

    function safeDecreaseAllowance(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        unchecked {
            uint256 oldAllowance = token.allowance(address(this), spender);
            require(oldAllowance >= value, "SafeERC20: decreased allowance below zero");
            uint256 newAllowance = oldAllowance - value;
            _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
        }
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     */
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves. We use {Address.functionCall} to perform this call, which verifies that
        // the target address contains contract code and also asserts for success in the low-level call.

        bytes memory returndata = address(token).functionCall(data, "SafeERC20: low-level call failed");
        if (returndata.length > 0) {
            // Return data is optional
            require(abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
        }
    }
}
pragma solidity ^0.8.0;

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
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);

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
}
pragma solidity ^0.8.0;

/**
 * @dev Collection of functions related to the address type
 */
library Address {
    /**
     * @dev Returns true if `account` is a contract.
     *
     * [IMPORTANT]
     * ====
     * It is unsafe to assume that an address for which this function returns
     * false is an externally-owned account (EOA) and not a contract.
     *
     * Among others, `isContract` will return false for the following
     * types of addresses:
     *
     *  - an externally-owned account
     *  - a contract in construction
     *  - an address where a contract will be created
     *  - an address where a contract lived, but was destroyed
     * ====
     */
    function isContract(address account) internal view returns (bool) {
        // This method relies on extcodesize, which returns 0 for contracts in
        // construction, since the code is only stored at the end of the
        // constructor execution.

        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }

    /**
     * @dev Replacement for Solidity's `transfer`: sends `amount` wei to
     * `recipient`, forwarding all available gas and reverting on errors.
     *
     * https://eips.ethereum.org/EIPS/eip-1884[EIP1884] increases the gas cost
     * of certain opcodes, possibly making contracts go over the 2300 gas limit
     * imposed by `transfer`, making them unable to receive funds via
     * `transfer`. {sendValue} removes this limitation.
     *
     * https://diligence.consensys.net/posts/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.5.11/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
     */
    function sendValue(address payable recipient, uint256 amount) internal {
        require(address(this).balance >= amount, "Address: insufficient balance");

        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Address: unable to send value, recipient may have reverted");
    }

    /**
     * @dev Performs a Solidity function call using a low level `call`. A
     * plain `call` is an unsafe replacement for a function call: use this
     * function instead.
     *
     * If `target` reverts with a revert reason, it is bubbled up by this
     * function (like regular Solidity function calls).
     *
     * Returns the raw returned data. To convert to the expected return value,
     * use https://solidity.readthedocs.io/en/latest/units-and-global-variables.html?highlight=abi.decode#abi-encoding-and-decoding-functions[`abi.decode`].
     *
     * Requirements:
     *
     * - `target` must be a contract.
     * - calling `target` with `data` must not revert.
     *
     * _Available since v3.1._
     */
    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionCall(target, data, "Address: low-level call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`], but with
     * `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but also transferring `value` wei to `target`.
     *
     * Requirements:
     *
     * - the calling contract must have an ETH balance of at least `value`.
     * - the called Solidity function must be `payable`.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value
    ) internal returns (bytes memory) {
        return functionCallWithValue(target, data, value, "Address: low-level call with value failed");
    }

    /**
     * @dev Same as {xref-Address-functionCallWithValue-address-bytes-uint256-}[`functionCallWithValue`], but
     * with `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value,
        string memory errorMessage
    ) internal returns (bytes memory) {
        require(address(this).balance >= value, "Address: insufficient balance for call");
        require(isContract(target), "Address: call to non-contract");

        (bool success, bytes memory returndata) = target.call{value: value}(data);
        return verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(address target, bytes memory data) internal view returns (bytes memory) {
        return functionStaticCall(target, data, "Address: low-level static call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal view returns (bytes memory) {
        require(isContract(target), "Address: static call to non-contract");

        (bool success, bytes memory returndata) = target.staticcall(data);
        return verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a delegate call.
     *
     * _Available since v3.4._
     */
    function functionDelegateCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionDelegateCall(target, data, "Address: low-level delegate call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a delegate call.
     *
     * _Available since v3.4._
     */
    function functionDelegateCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal returns (bytes memory) {
        require(isContract(target), "Address: delegate call to non-contract");

        (bool success, bytes memory returndata) = target.delegatecall(data);
        return verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Tool to verifies that a low level call was successful, and revert if it wasn't, either by bubbling the
     * revert reason using the provided one.
     *
     * _Available since v4.3._
     */
    function verifyCallResult(
        bool success,
        bytes memory returndata,
        string memory errorMessage
    ) internal pure returns (bytes memory) {
        if (success) {
            return returndata;
        } else {
            // Look for revert reason and bubble it up if present
            if (returndata.length > 0) {
                // The easiest way to bubble the revert reason is using memory via assembly

                assembly {
                    let returndata_size := mload(returndata)
                    revert(add(32, returndata), returndata_size)
                }
            } else {
                revert(errorMessage);
            }
        }
    }
}
pragma solidity 0.8.9;

import "../../interfaces/IInvestmentStrategy.sol";
import "../../interfaces/IMasterChef.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../abstract/AbstractAssetStakingStrategy.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


contract CakePoolStakingStrategy is AssetStakingStrategy {
    using SafeERC20 for IERC20;

    constructor() AssetStakingStrategy(
            // Staking asset address -- Cake
            address(0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82),
            // Reward asset address -- Cake
            address(0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82),
            // Profit asset address -- BUSD
            address(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56)
        )
    {
        router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        stakeContract = IMasterChef(0x73feaa1eE314F8c655E354234017bE2193C9E24E);
    }

    function pendingProfit() external view override returns (uint256) {
        uint256 currentBalance = rewardAsset.balanceOf(address(this));
        uint256 pendingCake = currentBalance + stakeContract.pendingCake(0, address(this));

        if (pendingCake == 0) {
            return 0;
        }

        address[] memory path = new address[](3);
        path[0] = address(stakeAsset);
        path[1] = router.WETH();
        path[2] = address(profitAsset);
        uint256 profit = router.getAmountsOut(pendingCake, path)[2];
        return profit;
    }

    function _withdrwaCapital(uint256 amount, address receiver) internal override {
        profitAsset.transfer(receiver, amount);
    }

    function _withdrawCapitalAsAssets(uint256 amount, address receiver) internal override {
        stakeAsset.transfer(receiver, amount);
    }

    function totalStaked() public override view returns(uint256 stakedAmount) {
        (stakedAmount, ) = stakeContract.userInfo(0, address(this));
        return stakedAmount;
    }

    // Return asset pool value
    function assetPoolValue() external view override returns (uint256 assetAmount, uint256 busdAmount) {
        assetAmount = totalStaked();
        if(assetAmount == 0) {
            return (0,0);
        }
        address[] memory path = new address[](3);
        path[0] = address(stakeAsset);
        path[1] = router.WETH();
        path[2] = address(profitAsset);
        busdAmount = router.getAmountsOut(assetAmount, path)[2];
    }

    function stake(uint256 _amount) internal override {
        if(_amount == 0) {
            return;
        }
        stakeAsset.safeIncreaseAllowance(address(stakeContract), _amount);
        stakeContract.enterStaking(_amount);
    }

    function unstake(uint256 _amount) internal override {
        stakeContract.leaveStaking(_amount);
    }
}
pragma solidity 0.8.9;

/**
    InvestmentStrategy contracts interface.
    Capital can be added to an investment strategy in the form of BNB

    The contract uses the capital to genrate returns.
*/
interface IInvestmentStrategy {
    // Add capital to the investment strategy
    function addCapital() external payable;

   // Add capital to the investment strategy
    function addBusdCapital(uint256 amount) external;

    // Add capital to the investment strategy
    function addAssetCapital(uint256 amount) external;

    // Remove capital from the strategy
    function withdrawCapital(uint256 amount, address receiver) external;

    // Remove capital from the strategy
    function withdrawCapitalAsAssets(uint256 amount, address receiver) external;

    // Collects the rewards genrated while staking
    function collectProfit(address _receiver) external returns(uint256 profit);

    // Returns the unrealized rewards genrated while staking
    function pendingProfit() external view returns (uint256);

    // Reinvest profits into this strategy
    function rollProfit() external;

     // Return asset pool value
    function assetPoolValue() external view returns (uint256 assetAmount, uint256 busdAmount);

}
pragma solidity 0.8.9;

interface IMasterChef {
    function deposit(uint256 _pid, uint256 _amount) external;

    function withdraw(uint256 _pid, uint256 _amount) external;

    function enterStaking(uint256 _amount) external;

    function leaveStaking(uint256 _amount) external;

    function pendingCake(uint256 _pid, address _user) external view returns (uint256);

    function pendingBSW(uint256 _pid, address _user) external view returns (uint256);

    function userInfo(uint256 _pid, address _user) external view returns (uint256, uint256);

    function emergencyWithdraw(uint256 _pid) external;
}File 14 of 65 : IUniswapV2Router02.solpragma solidity >=0.6.2;

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
pragma solidity 0.8.9;

import "../../interfaces/IInvestmentStrategy.sol";
import "../../interfaces/IMasterChef.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../lib/SwapUtils.sol";
import "./AbstractLock.sol";

abstract contract AssetStakingStrategy is IInvestmentStrategy, AccessControl, Lock {
    using SafeERC20 for IERC20;
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");
    
    // Use this max investment to avoid slippage loss
    uint256 public maxEthSwap = type(uint256).max;
    uint256 public maxBusdSwap = type(uint256).max;  
    uint256 public swapSlippage = 150; // 1.5% slippage
    uint256 public busdCapitalPool;

    IMasterChef public stakeContract;
    IERC20 public stakeAsset;
    IERC20 public rewardAsset;
    IERC20 public profitAsset;
    IERC20 public busd;

    // The router used to swap the fee into BNB or stable coin
    IUniswapV2Router02 public router;

    event SwapFailed(address from, address to, uint256 amount, uint256 slippage);
    constructor(
        address stakeAssetAddress,
        address rewardAssetAddress,
        address profitAssetAddress
    ) {
        stakeAsset =  IERC20(stakeAssetAddress);
        rewardAsset = IERC20(rewardAssetAddress);
        profitAsset = IERC20(profitAssetAddress);

        busd = ERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(OWNER_ROLE, msg.sender);
        _setupRole(MANAGER_ROLE, msg.sender);
    }

    function addBusdCapital(uint256 amount) override external {
        require(
            amount > 0,
            "ASSET POOL STRATEGY: Capital amount must be grater than 0"
        );

        busd.safeTransferFrom(msg.sender, address(this), amount);
        busdCapitalPool += amount;

        handleBusdInvestment();
    }

    // Add capital to the investment strategy
    function addAssetCapital(uint256 amount) override external  {
        require(
            amount > 0,
            "ASSET POOL STRATEGY: Capital amount must be grater than 0"
        );

        stakeAsset.safeTransferFrom(msg.sender, address(this), amount);
        stake(amount);
    }

    // Add capital to the investment strategy
    function addCapital() external payable override {
        require(
            msg.value > 0,
            "ASSET POOL STRATEGY: Capital amount must be grater than 0"
        );
    
        handleBnbInvestment();
    }
    
    function handleBusdInvestment() internal { 
        if(busdCapitalPool == 0) {
            return;
        }

        uint256 swapAmount = busdCapitalPool;
        
        if(swapAmount > maxBusdSwap) {
            swapAmount = maxBusdSwap;   
        } 

        uint256 balance = stakeAsset.balanceOf(address(this));
        try SwapUtils.swapTokensForTokens(router, busd, stakeAsset, swapAmount, swapSlippage) {
            busdCapitalPool -= swapAmount;
            uint256 stakeBalance = stakeAsset.balanceOf(address(this)) - balance;
            stake(stakeBalance);
        } catch {
            emit SwapFailed(address(busd), address(stakeAsset), swapAmount, swapSlippage);
        }
    }

    function drainCapitalPool(address receiver) public onlyRole(OWNER_ROLE) lock {
        busd.transfer(receiver, busd.balanceOf(address(this)));
        busdCapitalPool = 0;
    }

    function handleBnbInvestment() internal { 
        // Swap the new capital to the assets
        uint256 ethAmount = address(this).balance;
        
        if(ethAmount == 0) {
            return;
        }

        if(ethAmount > maxEthSwap) {
            ethAmount = maxEthSwap;
        }

        uint256 balance = stakeAsset.balanceOf(address(this));
        try SwapUtils.swapETHForTokens(router, stakeAsset, ethAmount, swapSlippage) {
            uint256 stakeBalance = stakeAsset.balanceOf(address(this)) - balance;
            stake(stakeBalance);
        } catch {
            emit SwapFailed(address(busd), address(stakeAsset), ethAmount, swapSlippage);
        }
    }
    
    // Remove capital from the strategy
    function withdrawCapital(uint256 amount, address receiver) public override onlyRole(MANAGER_ROLE) lock {
        // Unstake tokens before removing capital
        uint256 assetAmount = totalStaked();

        if(assetAmount == 0) {
            return; 
        } 

        if(assetAmount < amount || amount == 0) { 
            amount = assetAmount; 
        }

        unstake(amount);
       
        // Swap the new capital to the assets
        uint256 tokenAmount = stakeAsset.balanceOf(address(this));
        require(tokenAmount > 0, "Insuficient balance");
        SwapUtils.swapTokensForTokens(router, stakeAsset, profitAsset, tokenAmount, swapSlippage);

        uint256 balance = profitAsset.balanceOf(address(this));
        _withdrwaCapital(balance, receiver);

        // Remove any busd remains
        busd.transfer(receiver, busd.balanceOf(address(this)));
        busdCapitalPool = 0;
    }

    function withdrawCapitalAsAssets(uint256 amount, address receiver) override external onlyRole(MANAGER_ROLE) {
        // Unstake tokens before removing capital
        uint256 assetAmount = totalStaked();
        unstake(assetAmount);

        if(assetAmount == 0) {  
            return; 
        } 

        if(assetAmount < amount || amount == 0) {
            amount = assetAmount;
        }

        uint256 balance = stakeAsset.balanceOf(address(this));
        _withdrawCapitalAsAssets(balance, receiver);
        // Remove any busd remains
        busd.transfer(receiver, busd.balanceOf(address(this)));
        busdCapitalPool = 0;
    }

    function totalStaked() public view virtual returns(uint256 stakedAmount) ;

    function destroy(address receiver) external onlyRole(OWNER_ROLE) {
        // Distribute any remaning tokens
        _collectProfit(receiver);
        withdrawCapital(0, receiver);

        require(
            stakeAsset.balanceOf(address(this)) == 0,
            "StakeAsset balance != 0 cannot destroy"
        );

        require(
            rewardAsset.balanceOf(address(this)) == 0,
            "Reward asset balance != 0 cannot destory"
        );

        require(
            busd.balanceOf(address(this)) == 0,
            "Busd asset balance != 0 cannot destory"
        );

        uint256 assetAmount = totalStaked();

        require(assetAmount == 0, "Balance != 0 cannot destroy");

        // Call self destruct and send remaing ETH to owner
        selfdestruct(payable(msg.sender));
    }

    // Collect the profits
    function collectProfit(address _receiver) external override onlyRole(MANAGER_ROLE) returns(uint256) {
       return _collectProfit(_receiver);
    }

    function _collectProfit(address _receiver) private returns(uint256) {
        uint256 pendingProfits = this.pendingProfit();
        if (pendingProfits == 0) {
            return 0;
        }

        unstake(0);
        uint256 tokenAmount = rewardAsset.balanceOf(address(this));
        require(tokenAmount > 0, "Insuficient balance");
        try SwapUtils.swapTokensForTokens(router, rewardAsset, profitAsset, tokenAmount, swapSlippage) {
            pendingProfits = profitAsset.balanceOf(address(this));
            profitAsset.transfer(_receiver, pendingProfits);
            return pendingProfits;
        } catch {
            emit SwapFailed(address(busd), address(stakeAsset), tokenAmount, swapSlippage);
            return 0;
        }
    }

    function rollProfit() override external onlyRole(MANAGER_ROLE) {
        unstake(0);
        stake(stakeAsset.balanceOf(address(this)));
    }

    function rollCapitalPools() external {
        handleBusdInvestment();
        handleBnbInvestment();
    }

    function setSwapSlippage(uint256 slipapge) external onlyRole(MANAGER_ROLE) {
        require(slipapge <= 10_000, "Slippage cannot be > 100%");
        swapSlippage = slipapge;
    }

    function setBusdSwapCap(uint256 maxAmount) external onlyRole(MANAGER_ROLE) {
        maxBusdSwap = maxAmount;
    }

    function setEthSwapCap(uint256 maxAmount) external onlyRole(MANAGER_ROLE) {
        maxEthSwap = maxAmount;
    }

    function setRouter(address routerAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        router = IUniswapV2Router02(routerAddress);
    }

    function _withdrwaCapital(uint256 amount, address receiver) internal virtual;
    function _withdrawCapitalAsAssets(uint256 amount, address receiver) internal virtual;

    function stake(uint256 _amount) internal virtual;
    function unstake(uint256 _amount) internal virtual;

    receive() external payable {}
}File 16 of 65 : IUniswapV2Router01.solpragma solidity >=0.6.2;

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
}
pragma solidity ^0.8.0;

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
        // (a + b) / 2 can overflow.
        return (a & b) + (a ^ b) / 2;
    }

    /**
     * @dev Returns the ceiling of the division of two numbers.
     *
     * This differs from standard division with `/` in that it rounds up instead
     * of rounding down.
     */
    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        // (a + b - 1) / b can overflow on addition, so we distribute.
        return a / b + (a % b == 0 ? 0 : 1);
    }
}
pragma solidity ^0.8.0;

import "./IAccessControl.sol";
import "../utils/Context.sol";
import "../utils/Strings.sol";
import "../utils/introspection/ERC165.sol";

/**
 * @dev Contract module that allows children to implement role-based access
 * control mechanisms. This is a lightweight version that doesn't allow enumerating role
 * members except through off-chain means by accessing the contract event logs. Some
 * applications may benefit from on-chain enumerability, for those cases see
 * {AccessControlEnumerable}.
 *
 * Roles are referred to by their `bytes32` identifier. These should be exposed
 * in the external API and be unique. The best way to achieve this is by
 * using `public constant` hash digests:
 *
 * ```
 * bytes32 public constant MY_ROLE = keccak256("MY_ROLE");
 * ```
 *
 * Roles can be used to represent a set of permissions. To restrict access to a
 * function call, use {hasRole}:
 *
 * ```
 * function foo() public {
 *     require(hasRole(MY_ROLE, msg.sender));
 *     ...
 * }
 * ```
 *
 * Roles can be granted and revoked dynamically via the {grantRole} and
 * {revokeRole} functions. Each role has an associated admin role, and only
 * accounts that have a role's admin role can call {grantRole} and {revokeRole}.
 *
 * By default, the admin role for all roles is `DEFAULT_ADMIN_ROLE`, which means
 * that only accounts with this role will be able to grant or revoke other
 * roles. More complex role relationships can be created by using
 * {_setRoleAdmin}.
 *
 * WARNING: The `DEFAULT_ADMIN_ROLE` is also its own admin: it has permission to
 * grant and revoke this role. Extra precautions should be taken to secure
 * accounts that have been granted it.
 */
abstract contract AccessControl is Context, IAccessControl, ERC165 {
    struct RoleData {
        mapping(address => bool) members;
        bytes32 adminRole;
    }

    mapping(bytes32 => RoleData) private _roles;

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    /**
     * @dev Modifier that checks that an account has a specific role. Reverts
     * with a standardized message including the required role.
     *
     * The format of the revert reason is given by the following regular expression:
     *
     *  /^AccessControl: account (0x[0-9a-f]{40}) is missing role (0x[0-9a-f]{64})$/
     *
     * _Available since v4.1._
     */
    modifier onlyRole(bytes32 role) {
        _checkRole(role, _msgSender());
        _;
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAccessControl).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     * @dev Returns `true` if `account` has been granted `role`.
     */
    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return _roles[role].members[account];
    }

    /**
     * @dev Revert with a standard message if `account` is missing `role`.
     *
     * The format of the revert reason is given by the following regular expression:
     *
     *  /^AccessControl: account (0x[0-9a-f]{40}) is missing role (0x[0-9a-f]{64})$/
     */
    function _checkRole(bytes32 role, address account) internal view {
        if (!hasRole(role, account)) {
            revert(
                string(
                    abi.encodePacked(
                        "AccessControl: account ",
                        Strings.toHexString(uint160(account), 20),
                        " is missing role ",
                        Strings.toHexString(uint256(role), 32)
                    )
                )
            );
        }
    }

    /**
     * @dev Returns the admin role that controls `role`. See {grantRole} and
     * {revokeRole}.
     *
     * To change a role's admin, use {_setRoleAdmin}.
     */
    function getRoleAdmin(bytes32 role) public view override returns (bytes32) {
        return _roles[role].adminRole;
    }

    /**
     * @dev Grants `role` to `account`.
     *
     * If `account` had not been already granted `role`, emits a {RoleGranted}
     * event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     */
    function grantRole(bytes32 role, address account) public virtual override onlyRole(getRoleAdmin(role)) {
        _grantRole(role, account);
    }

    /**
     * @dev Revokes `role` from `account`.
     *
     * If `account` had been granted `role`, emits a {RoleRevoked} event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     */
    function revokeRole(bytes32 role, address account) public virtual override onlyRole(getRoleAdmin(role)) {
        _revokeRole(role, account);
    }

    /**
     * @dev Revokes `role` from the calling account.
     *
     * Roles are often managed via {grantRole} and {revokeRole}: this function's
     * purpose is to provide a mechanism for accounts to lose their privileges
     * if they are compromised (such as when a trusted device is misplaced).
     *
     * If the calling account had been granted `role`, emits a {RoleRevoked}
     * event.
     *
     * Requirements:
     *
     * - the caller must be `account`.
     */
    function renounceRole(bytes32 role, address account) public virtual override {
        require(account == _msgSender(), "AccessControl: can only renounce roles for self");

        _revokeRole(role, account);
    }

    /**
     * @dev Grants `role` to `account`.
     *
     * If `account` had not been already granted `role`, emits a {RoleGranted}
     * event. Note that unlike {grantRole}, this function doesn't perform any
     * checks on the calling account.
     *
     * [WARNING]
     * ====
     * This function should only be called from the constructor when setting
     * up the initial roles for the system.
     *
     * Using this function in any other way is effectively circumventing the admin
     * system imposed by {AccessControl}.
     * ====
     */
    function _setupRole(bytes32 role, address account) internal virtual {
        _grantRole(role, account);
    }

    /**
     * @dev Sets `adminRole` as ``role``'s admin role.
     *
     * Emits a {RoleAdminChanged} event.
     */
    function _setRoleAdmin(bytes32 role, bytes32 adminRole) internal virtual {
        bytes32 previousAdminRole = getRoleAdmin(role);
        _roles[role].adminRole = adminRole;
        emit RoleAdminChanged(role, previousAdminRole, adminRole);
    }

    function _grantRole(bytes32 role, address account) private {
        if (!hasRole(role, account)) {
            _roles[role].members[account] = true;
            emit RoleGranted(role, account, _msgSender());
        }
    }

    function _revokeRole(bytes32 role, address account) private {
        if (hasRole(role, account)) {
            _roles[role].members[account] = false;
            emit RoleRevoked(role, account, _msgSender());
        }
    }
}
pragma solidity 0.8.9;

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

library SwapUtils {
    using SafeERC20 for IERC20;

    function swapExactETHForTokens(IUniswapV2Router02 router, IERC20 token, uint256 ethAmount, uint256 slippage) external returns(uint256) {
        address[] memory path = new address[](2);
        path[0] = router.WETH();
        path[1] = address(token);

        uint256 minAmount = 0;
        if(slippage > 0) {
            minAmount = calculateSlippage(router, path, ethAmount, slippage);
        }

        uint256[] memory amounts = router.swapExactETHForTokens{
            value: ethAmount
        }(minAmount, path, address(this), block.timestamp);

        return amounts[1];
    }

    function swapETHForTokens(IUniswapV2Router02 router, IERC20 token, uint256 ethAmount, uint256 slippage) external {
        address[] memory path = new address[](2);
        path[0] = router.WETH();
        path[1] = address(token);
        
        uint256 minAmount = 0;
        if(slippage > 0) {
            minAmount = calculateSlippage(router, path, ethAmount, slippage);
        }

        router.swapExactETHForTokensSupportingFeeOnTransferTokens{
            value: ethAmount
        }(minAmount, path, address(this), block.timestamp);
    }

    function swapTokensForEth(IUniswapV2Router02 router, IERC20 token, uint256 tokenAmount, uint256 slippage) external {
        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = router.WETH();

        uint256 minAmount = 0;
        if(slippage > 0) {
            minAmount = calculateSlippage(router, path, tokenAmount, slippage);
        }

        token.safeIncreaseAllowance(address(router), tokenAmount);

        // make the swap
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            minAmount,
            path,
            address(this),
            block.timestamp
        );
    }

    function swapTokensForTokens(IUniswapV2Router02 router, IERC20 token0, IERC20 token1, uint256 amount, uint256 slippage) external {
        address[] memory path = new address[](3);
        path[0] = address(token0);
        path[1] = router.WETH();
        path[2] = address(token1);
        
        uint256 minAmount = 0;
        if(slippage > 0) {
            minAmount = calculateSlippage(router, path, amount, slippage);
        }
        token0.safeIncreaseAllowance(address(router), amount);

        // make the swap
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount,
            minAmount,
            path,
            address(this),
            block.timestamp
        );
    }

    /**
     * Return the minimum amount expected for a given trade       
     */
    function calculateSlippage(IUniswapV2Router02  router, address[] memory path, uint256 amount, uint256 slippage) public view returns(uint256) {
        uint256 amountOut = router.getAmountsOut(amount, path)[path.length - 1];
        uint256 minAmount = amountOut - ((amountOut * slippage) / 10000);
        return minAmount;
    }
}
pragma solidity 0.8.9;

abstract contract Lock  {
    bool private unlocked = true;

    modifier lock() {
        require(unlocked == true, "Lock: LOCKED");
        unlocked = false;
        _;
        unlocked = true;
    }
}
pragma solidity ^0.8.0;

/**
 * @dev External interface of AccessControl declared to support ERC165 detection.
 */
interface IAccessControl {
    /**
     * @dev Emitted when `newAdminRole` is set as ``role``'s admin role, replacing `previousAdminRole`
     *
     * `DEFAULT_ADMIN_ROLE` is the starting admin for all roles, despite
     * {RoleAdminChanged} not being emitted signaling this.
     *
     * _Available since v3.1._
     */
    event RoleAdminChanged(bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole);

    /**
     * @dev Emitted when `account` is granted `role`.
     *
     * `sender` is the account that originated the contract call, an admin role
     * bearer except when using {AccessControl-_setupRole}.
     */
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);

    /**
     * @dev Emitted when `account` is revoked `role`.
     *
     * `sender` is the account that originated the contract call:
     *   - if using `revokeRole`, it is the admin role bearer
     *   - if using `renounceRole`, it is the role bearer (i.e. `account`)
     */
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    /**
     * @dev Returns `true` if `account` has been granted `role`.
     */
    function hasRole(bytes32 role, address account) external view returns (bool);

    /**
     * @dev Returns the admin role that controls `role`. See {grantRole} and
     * {revokeRole}.
     *
     * To change a role's admin, use {AccessControl-_setRoleAdmin}.
     */
    function getRoleAdmin(bytes32 role) external view returns (bytes32);

    /**
     * @dev Grants `role` to `account`.
     *
     * If `account` had not been already granted `role`, emits a {RoleGranted}
     * event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     */
    function grantRole(bytes32 role, address account) external;

    /**
     * @dev Revokes `role` from `account`.
     *
     * If `account` had been granted `role`, emits a {RoleRevoked} event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     */
    function revokeRole(bytes32 role, address account) external;

    /**
     * @dev Revokes `role` from the calling account.
     *
     * Roles are often managed via {grantRole} and {revokeRole}: this function's
     * purpose is to provide a mechanism for accounts to lose their privileges
     * if they are compromised (such as when a trusted device is misplaced).
     *
     * If the calling account had been granted `role`, emits a {RoleRevoked}
     * event.
     *
     * Requirements:
     *
     * - the caller must be `account`.
     */
    function renounceRole(bytes32 role, address account) external;
}
pragma solidity ^0.8.0;

/**
 * @dev String operations.
 */
library Strings {
    bytes16 private constant _HEX_SYMBOLS = "0123456789abcdef";

    /**
     * @dev Converts a `uint256` to its ASCII `string` decimal representation.
     */
    function toString(uint256 value) internal pure returns (string memory) {
        // Inspired by OraclizeAPI's implementation - MIT licence
        // https://github.com/oraclize/ethereum-api/blob/b42146b063c7d6ee1358846c198246239e9360e8/oraclizeAPI_0.4.25.sol

        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    /**
     * @dev Converts a `uint256` to its ASCII `string` hexadecimal representation.
     */
    function toHexString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0x00";
        }
        uint256 temp = value;
        uint256 length = 0;
        while (temp != 0) {
            length++;
            temp >>= 8;
        }
        return toHexString(value, length);
    }

    /**
     * @dev Converts a `uint256` to its ASCII `string` hexadecimal representation with fixed length.
     */
    function toHexString(uint256 value, uint256 length) internal pure returns (string memory) {
        bytes memory buffer = new bytes(2 * length + 2);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 2 * length + 1; i > 1; --i) {
            buffer[i] = _HEX_SYMBOLS[value & 0xf];
            value >>= 4;
        }
        require(value == 0, "Strings: hex length insufficient");
        return string(buffer);
    }
}
pragma solidity ^0.8.0;

import "./IERC165.sol";

/**
 * @dev Implementation of the {IERC165} interface.
 *
 * Contracts that want to implement ERC165 should inherit from this contract and override {supportsInterface} to check
 * for the additional interface id that will be supported. For example:
 *
 * ```solidity
 * function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
 *     return interfaceId == type(MyInterface).interfaceId || super.supportsInterface(interfaceId);
 * }
 * ```
 *
 * Alternatively, {ERC165Storage} provides an easier to use but more expensive implementation.
 */
abstract contract ERC165 is IERC165 {
    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}
pragma solidity ^0.8.0;

/**
 * @dev Interface of the ERC165 standard, as defined in the
 * https://eips.ethereum.org/EIPS/eip-165[EIP].
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
     * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[EIP section]
     * to learn more about how these ids are created.
     *
     * This function call must use less than 30 000 gas.
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
pragma solidity 0.8.9;

import "../../interfaces/IInvestmentStrategy.sol";
import "../../interfaces/IMasterChef.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../abstract/AbstractAssetStakingStrategy.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


contract BswPoolStakingStrategy is AssetStakingStrategy {
    using SafeERC20 for IERC20;

    constructor()
        AssetStakingStrategy(
            // Staking a1sset address -- BSW
            address(0x965F527D9159dCe6288a2219DB51fc6Eef120dD1),
            // Reward asset address -- BSW
            address(0x965F527D9159dCe6288a2219DB51fc6Eef120dD1),
            // Profit asset address -- BUSD
            address(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56)
        )
    {
        router = IUniswapV2Router02(0x3a6d8cA21D1CF76F653A67577FA0D27453350dD8);
        stakeContract = IMasterChef(0xDbc1A13490deeF9c3C12b44FE77b503c1B061739);
    }

    function pendingProfit() external view override returns (uint256) {
        uint256 currentBalance = rewardAsset.balanceOf(address(this));
        uint256 pendingBSW = currentBalance + stakeContract.pendingBSW(0, address(this));
        
        if (pendingBSW == 0) {
            return 0;
        }

        address[] memory path = new address[](3);
        path[0] = address(stakeAsset);
        path[1] = router.WETH();
        path[2] = address(profitAsset);
        uint256 profit = router.getAmountsOut(pendingBSW, path)[2];
        return profit;
    }

    function totalStaked() public override view returns(uint256 stakedAmount) {
        (stakedAmount, ) = stakeContract.userInfo(0, address(this));
        return stakedAmount;
    }

    // Return asset pool value
    function assetPoolValue() external view override returns (uint256 assetAmount, uint256 busdAmount) {
        assetAmount = totalStaked();
          if(assetAmount == 0) {
            return (0,0);
        }
        address[] memory path = new address[](3);
        path[0] = address(stakeAsset);
        path[1] = router.WETH();
        path[2] = address(profitAsset);
        busdAmount = router.getAmountsOut(assetAmount, path)[2];
    }

    function _withdrwaCapital(uint256 amount, address receiver) internal override {
        profitAsset.transfer(receiver, amount);
    }

    function _withdrawCapitalAsAssets(uint256 amount, address receiver) internal override {
        stakeAsset.transfer(receiver, amount);
    }

    function stake(uint256 _amount) internal override {
        if(_amount == 0) {
            return;
        }
        stakeAsset.safeIncreaseAllowance(address(stakeContract), _amount);
        stakeContract.enterStaking(_amount);
    }

    function unstake(uint256 _amount) internal override {
        stakeContract.leaveStaking(_amount);
    }
}
pragma solidity 0.8.9;

import "../../interfaces/IMasterChef.sol";
import "../../interfaces/IBiswapPair.sol";
import "../../interfaces/IStash.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
/**
    A rewards stasg that stakes the stashed values until they are claimed
    It uses the biswap BUSD-USDT farm to do so 
 */
contract RewardStash is IRewardStash, AccessControl {
    // Reference to the BUSD contract
    ERC20 public busd = ERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");

    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(OWNER_ROLE, msg.sender);
        _setupRole(MANAGER_ROLE, msg.sender);
    }

    // Use this to stash busd with this strategy
    function stash(uint256 value) external override {
        busd.transferFrom(address(msg.sender), address(this), value);
    }

    // Use this to unstash busd
    function unstash(uint256 busdValue) external override onlyRole(MANAGER_ROLE) {
        require(busdValue <= busd.balanceOf(address(this)), "Insufficient balance");
        busd.transfer(msg.sender, busdValue);
    }

    function stashValue() external view override returns (uint256) {
       return busd.balanceOf(address(this));
    }

    // Use this function to migrate the capital to another address
    function migrateCapital(address _newStashAddress, uint256 busdAmount) external onlyRole(OWNER_ROLE) {
        require(busdAmount <= busd.balanceOf(address(this)), "Insufficient balance");

        busd.transfer(_newStashAddress, busdAmount);
    }

    // Migrate all the capital to a new address
    function migrateAndDestory(address _newStashAddress) external onlyRole(OWNER_ROLE) {
        busd.transfer(_newStashAddress, busd.balanceOf(address(this))); 

        // Self destruct and transfer any ETH to the owner
        selfdestruct(payable(msg.sender));
    }

    receive() external payable {}
}
pragma solidity 0.8.9;

interface IBiswapPair {
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
    function swapFee() external view returns (uint32);
    function devFee() external view returns (uint32);

    function mint(address to) external returns (uint liquidity);
    function burn(address to) external returns (uint amount0, uint amount1);
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;

    function initialize(address, address) external;
    function setSwapFee(uint32) external;
    function setDevFee(uint32) external;
}
pragma solidity 0.8.9;

/**
   Stash rewards until they are ready to be claimed
*/
interface IRewardStash {
    // Add amount to stash
    function stash(uint256 value) external ;

    // Remote amount from stash
    function unstash(uint256 value) external;

    // Returns the current value of the stash
    function stashValue() external view returns(uint256);
}
pragma solidity 0.8.9;

import "../../interfaces/IMasterChef.sol";
import "../../interfaces/IBiswapPair.sol";
import "../../interfaces/IStash.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "@openzeppelin/contracts/access/AccessControl.sol";

/**
    A rewards stasg that stakes the stashed values until they are claimed
    It uses the biswap BUSD-USDT farm to do so 
 */
contract BswBusdFarmStash is IRewardStash, AccessControl {
    IMasterChef public stakeContract;
    IBiswapPair public LPToken;

    uint256 public busdGeneratedLiquidity;
    uint256 public farmingPoolId = 1;

    // Bws tokems are recived as reward from the framing pool
    ERC20 public bsw;

    // Refernece to the USDT contract
    ERC20 public usdt;

    // Reference to the BUSD contract
    ERC20 public busd;

    // We use the router to swap our tokens as needed
    IUniswapV2Router02 public router;

    uint8 private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, "Fund: LOCKED");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");

    event UpdateRouterAddress(address oldAddress, address newAddress);

    constructor() {
        bsw = ERC20(0x965F527D9159dCe6288a2219DB51fc6Eef120dD1);
        usdt = ERC20(0x55d398326f99059fF775485246999027B3197955);
        busd = ERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
        LPToken = IBiswapPair(0xDA8ceb724A06819c0A5cDb4304ea0cB27F8304cF);
        stakeContract = IMasterChef(0xDbc1A13490deeF9c3C12b44FE77b503c1B061739);
        router = IUniswapV2Router02(0x3a6d8cA21D1CF76F653A67577FA0D27453350dD8);

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(OWNER_ROLE, msg.sender);
    }

    // Use this to stash busd with this srategy
    function stash(uint256 value) external override {
        uint256 pendingBSW = stakeContract.pendingBSW(
            farmingPoolId,
            address(this)
        );

        // Claim any farming rewards. The busd will be added back into the farm togheder with the stashed value
        if (pendingBSW > 1) {
            claimFarmingReward();
        }

        // Transfer the busd from the sender
        busd.transferFrom(address(msg.sender), address(this), value);

        uint256 currentBalance = busd.balanceOf(address(this));

        if(currentBalance == 0) {
            return;
        }

        // Swap half of BUSD capital to USDT.
        uint256 capitalHalf = busd.balanceOf(address(this)) / 2;
        sawpBUSDFotUsdt(capitalHalf);

        // We add the BUSD and USDT capital as liquidity and stake that liquidity
        uint256 liquidity = addLiquidityAndStake();

        busdGeneratedLiquidity += liquidity;
    }

    // Use this to unstash busd
    function unstash(uint256 busdValue)
        external
        override
        onlyRole(MANAGER_ROLE)
        lock
    {
    
        _unstash(busdValue);

        require(
            busdValue <= busd.balanceOf(address(this)),
            "Insufficient balance"
        );

        busd.transfer(msg.sender, busdValue);
    }

    function _unstash(uint256 busdValue) private {
        // Calculate how much we need to unstake to cover the unstash value
        uint256 lpAmount = busdValue / lpUsdValue(1);
        unstakeAndRemoveLiquidity(lpAmount);
    }

    function pendingProfit() external view returns (uint256) {
        uint256 pendingBSW = stakeContract.pendingBSW(
            farmingPoolId,
            address(this)
        );

        if(pendingBSW == 0) {
            return 0;
        }
        address[] memory path = new address[](3);
        path[0] = address(bsw);
        path[1] = router.WETH();
        path[2] = address(busd);
        uint256 profit = router.getAmountsOut(pendingBSW, path)[2];
        return profit;
    }

    // Claims the BSW reward generated from farming and swaps it to BUSD
    function claimFarmingReward() public {
        stakeContract.withdraw(farmingPoolId, 0);
        swapRewardForBUSD();
    }

    function stashValue() external view override returns (uint256) {
        (uint256 lpAmount, ) = stakeContract.userInfo(
            farmingPoolId,
            address(this)
        );

        return lpUsdValue(lpAmount);
    }

    function lpUsdValue(uint256 lpAmount) public pure returns (uint256) {
        return lpAmount * 2;
    }

    function addLiquidityAndStake() private returns (uint256 stakedLiquidity) {
        // Add the available BUSD and USDT to the liquidity pool and stake that liquidity
        uint256 liquidity = addLiquidity();
        stakeLp();
        return liquidity;
    }

    // Unstake the liquidity points
    function unstakeAndRemoveLiquidity(uint256 amount) private {
        unstakeLp(amount);
        removeLiquidity(amount);
    }

    function sawpBUSDFotUsdt(uint256 tokenAmount) private {
        address[] memory path = new address[](2);
        path[0] = address(busd);
        path[1] = address(usdt);

        busd.increaseAllowance(address(router), tokenAmount);

        // make the swap
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }

    function swapUSDTFroBUSD(uint256 tokenAmount) private {
        address[] memory path = new address[](2);
        path[0] = address(usdt);
        path[1] = address(busd);

        usdt.increaseAllowance(address(router), tokenAmount);

        // make the swap
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }

    function swapRewardForBUSD() private {
        uint256 tokenAmount = bsw.balanceOf(address(this));
        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(bsw);
        path[1] = address(busd);

        bsw.increaseAllowance(address(router), tokenAmount);

        // make the swap
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }

    function stakeLp() private {
        uint256 lpAmount = LPToken.balanceOf(address(this));
        LPToken.approve(address(stakeContract), lpAmount);

        stakeContract.deposit(farmingPoolId, lpAmount);
    }

    function unstakeLp(uint256 amount) private {
        stakeContract.withdraw(farmingPoolId, amount);
    }

    function addLiquidity() private returns (uint256 addedLiquidity) {
        uint256 busdAmount = busd.balanceOf(address(this));
        uint256 usdtAmount = usdt.balanceOf(address(this));
        // approve token transfer to cover all possible scenarios
        busd.increaseAllowance(address(router), busdAmount);
        usdt.increaseAllowance(address(router), usdtAmount);

        // add the liquidity
        (, , uint256 liquidity) = router.addLiquidity(
            address(busd),
            address(usdt),
            busdAmount,
            usdtAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            address(this),
            block.timestamp
        );

        return liquidity;
    }

    function removeLiquidity(uint256 lpAmount) private {
        LPToken.approve(address(router), lpAmount);

        // add the liquidity
        router.removeLiquidity(
            address(busd),
            address(usdt),
            lpAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            address(this),
            block.timestamp
        );

        swapUSDTFroBUSD(usdt.balanceOf(address(this)));
    }

    function setRouterAddress(address newAddress) public onlyRole(OWNER_ROLE) {
        require(
            address(router) != newAddress,
            "New address is the same as old address"
        );
        require(
            address(0) != newAddress,
            "Router address cannot be address(0)"
        );
        emit UpdateRouterAddress(address(router), newAddress);
        router = IUniswapV2Router02(newAddress);
    }

    // Use this function to migrate the capital to another address
    function migrateCapital(address _newStashAddress, uint256 busdAmount)
        external
        onlyRole(OWNER_ROLE)
    {
        _unstash(busdAmount);

        require(
            busdAmount <= busd.balanceOf(address(this)),
            "Insufficient balance"
        );

        busd.transfer(_newStashAddress, busdAmount);
    }

    // Migrate all the capital to a new address
    function migrateAndDestory(address _newStashAddress) external onlyRole(OWNER_ROLE)
    {
        (uint256 lpAmount, ) = stakeContract.userInfo(
            farmingPoolId,
            address(this)
        );

        claimFarmingReward();
        unstakeAndRemoveLiquidity(lpAmount);

        require(
            bsw.balanceOf(address(this)) == 0,
            "BSW Balance != 0 cannot cannot destroy"
        );

        require(
            usdt.balanceOf(address(this)) == 0,
            "USDT Balance != 0 cannot destory"
        );

        busd.transfer(_newStashAddress, busd.balanceOf(address(this)));

        // Self destruct and transfer any ETH to the owner
        selfdestruct(payable(msg.sender));
    }

    receive() external payable {}
}
pragma solidity 0.8.9;

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "../LiquidityTimeLock.sol";

library PresaleUtils {
    using SafeERC20 for IERC20;
    struct PresalePhase {
        uint256 status;
        uint256 rate;
        uint256 sellRate;
        uint256 minPurchase;
        uint256 maxPurchase;
        uint256 hardCap;
        uint256 _capital;
    }

    function preValidatePurchase(PresalePhase memory phase , address beneficiary, uint256 amount) public pure {
        require(phase.status == 1 , "Phase Not started");
        require(beneficiary != address(0), "Buy: beneficiary is the zero address");
        require(amount > 0, "Buy: amount is 0");
        require(amount <= phase.maxPurchase, "have to send max: maxPurchase");
    }

    function lockLiquidity(IUniswapV2Router02 router , ERC20 token0, ERC20 token1, uint256 amount0, uint256 amount1, address lockOwner) public returns (address) {
        router.addLiquidity(
                address(token0),
                address(token1),
                amount0,
                amount1,
                0,
                0,
                address(this),
                block.timestamp + 360
        );

        IUniswapV2Factory pairFactory = IUniswapV2Factory(router.factory());
        IERC20 pair = IERC20(pairFactory.getPair(address(token0),  address(token1)));
        LiquidityTimelock liquidityLock = new LiquidityTimelock(pair, lockOwner , 90 days);
        pair.safeTransfer(address(liquidityLock), pair.balanceOf(address(this)));

        return address(liquidityLock);
    }

}File 31 of 65 : IUniswapV2Factory.solpragma solidity >=0.5.0;

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
pragma solidity 0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


contract LiquidityTimelock is Ownable{
    using SafeERC20 for IERC20;

    // ERC20 basic token contract being held
    IERC20 private immutable _token;

    // beneficiary of tokens after they are released
    address private immutable _beneficiary;
    
    // Incremental period in seconds
    uint256 private immutable _period;

    // timestamp when token release is enabled
    uint256 private _releaseTime;


    constructor(
        IERC20 token_,
        address beneficiary_,
        uint256 period_
    ) {
        _token = token_;
        _beneficiary = beneficiary_;
        _period = period_;
        _releaseTime = block.timestamp + period_;
    }

    /**
     * @return the token being held.
     */
    function token() public view  returns (IERC20) {
        return _token;
    }

    /**
     * @return the beneficiary of the tokens.
     */
    function beneficiary() public view  returns (address) {
        return _beneficiary;
    }

    /**
     * @return the time when the tokens are released.
     */
    function releaseTime() public view  returns (uint256) {
        return _releaseTime;
    }

     /**
     * @return the time when the tokens are released.
     */
    function period() public view  returns (uint256) {
        return _period;
    }

    /**
     * @notice Transfers tokens held by timelock to beneficiary.
     */
    function release() public  {
        require(block.timestamp >= releaseTime(), "TokenTimelock: current time is before release time");

        uint256 amount = token().balanceOf(address(this));
        require(amount > 0, "TokenTimelock: no tokens to release");

        token().safeTransfer(beneficiary(), amount);
    }

    /**
     * @notice Transfers tokens held by timelock to beneficiary.
     */
    function renew() public onlyOwner {
        _releaseTime = block.timestamp + period();
    }
}
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IFundProcessor.sol";
import "hardhat/console.sol";

contract TeamFaucet is Ownable {
    address[3] addresses;

    uint256 public totalMinted;
    uint256 public lastSendTimestamp;
    uint256 public maxMintPerDay = 120_000 * 10 ** 18;

    ERC20PresetMinterPauser hedgePay;

    constructor(
        address _hedgePay,
        address _addr1,
        address _addr2,
        address _addr3
    ) {
        hedgePay = ERC20PresetMinterPauser(_hedgePay);
        addresses[0] = _addr1;
        addresses[1] = _addr2;
        addresses[2] = _addr3;
        lastSendTimestamp = block.timestamp;
    }


    function distribute() public {  
        uint256 daysSinceLastMint = (block.timestamp - lastSendTimestamp) / 1 days;
        require(daysSinceLastMint >= 1 , "Wait at least one day for new rewards");
        uint256 rewardCap = (hedgePay.totalSupply() * 3) / 100;
        require(totalMinted < rewardCap, "Reward exceeds supply cap"); 
        uint256 toBeMinted  = daysSinceLastMint * maxMintPerDay;
        
        require(toBeMinted > 0, "Nothing to be minted");
        uint256 rewardShare = toBeMinted / 3;


        if (
            addresses[0] == address(0) ||
            addresses[1] == address(0) ||
            addresses[2] == address(0)
        ) {
            return;
        }
        if (rewardShare > 0) {
            hedgePay.mint(addresses[0], rewardShare);
            hedgePay.mint(addresses[1], rewardShare);
            hedgePay.mint(addresses[2], rewardShare);

            lastSendTimestamp =  block.timestamp;
        }
    }

    function setAddress(uint256 index, address newAddress) external onlyOwner  {
        require(address(0) != newAddress, "Address cannot be 0");
        addresses[index] = newAddress;
    }

    function getAddress(uint256 index) external view onlyOwner returns(address)  {
        return addresses[index];
    }
}
pragma solidity ^0.8.0;

import "../ERC20.sol";
import "../extensions/ERC20Burnable.sol";
import "../extensions/ERC20Pausable.sol";
import "../../../access/AccessControlEnumerable.sol";
import "../../../utils/Context.sol";

/**
 * @dev {ERC20} token, including:
 *
 *  - ability for holders to burn (destroy) their tokens
 *  - a minter role that allows for token minting (creation)
 *  - a pauser role that allows to stop all token transfers
 *
 * This contract uses {AccessControl} to lock permissioned functions using the
 * different roles - head to its documentation for details.
 *
 * The account that deploys the contract will be granted the minter and pauser
 * roles, as well as the default admin role, which will let it grant both minter
 * and pauser roles to other accounts.
 */
contract ERC20PresetMinterPauser is Context, AccessControlEnumerable, ERC20Burnable, ERC20Pausable {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /**
     * @dev Grants `DEFAULT_ADMIN_ROLE`, `MINTER_ROLE` and `PAUSER_ROLE` to the
     * account that deploys the contract.
     *
     * See {ERC20-constructor}.
     */
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());

        _setupRole(MINTER_ROLE, _msgSender());
        _setupRole(PAUSER_ROLE, _msgSender());
    }

    /**
     * @dev Creates `amount` new tokens for `to`.
     *
     * See {ERC20-_mint}.
     *
     * Requirements:
     *
     * - the caller must have the `MINTER_ROLE`.
     */
    function mint(address to, uint256 amount) public virtual {
        require(hasRole(MINTER_ROLE, _msgSender()), "ERC20PresetMinterPauser: must have minter role to mint");
        _mint(to, amount);
    }

    /**
     * @dev Pauses all token transfers.
     *
     * See {ERC20Pausable} and {Pausable-_pause}.
     *
     * Requirements:
     *
     * - the caller must have the `PAUSER_ROLE`.
     */
    function pause() public virtual {
        require(hasRole(PAUSER_ROLE, _msgSender()), "ERC20PresetMinterPauser: must have pauser role to pause");
        _pause();
    }

    /**
     * @dev Unpauses all token transfers.
     *
     * See {ERC20Pausable} and {Pausable-_unpause}.
     *
     * Requirements:
     *
     * - the caller must have the `PAUSER_ROLE`.
     */
    function unpause() public virtual {
        require(hasRole(PAUSER_ROLE, _msgSender()), "ERC20PresetMinterPauser: must have pauser role to unpause");
        _unpause();
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override(ERC20, ERC20Pausable) {
        super._beforeTokenTransfer(from, to, amount);
    }
}
pragma solidity >= 0.4.22 <0.9.0;

library console {
	address constant CONSOLE_ADDRESS = address(0x000000000000000000636F6e736F6c652e6c6f67);

	function _sendLogPayload(bytes memory payload) private view {
		uint256 payloadLength = payload.length;
		address consoleAddress = CONSOLE_ADDRESS;
		assembly {
			let payloadStart := add(payload, 32)
			let r := staticcall(gas(), consoleAddress, payloadStart, payloadLength, 0, 0)
		}
	}

	function log() internal view {
		_sendLogPayload(abi.encodeWithSignature("log()"));
	}

	function logInt(int p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(int)", p0));
	}

	function logUint(uint p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint)", p0));
	}

	function logString(string memory p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string)", p0));
	}

	function logBool(bool p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool)", p0));
	}

	function logAddress(address p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address)", p0));
	}

	function logBytes(bytes memory p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes)", p0));
	}

	function logBytes1(bytes1 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes1)", p0));
	}

	function logBytes2(bytes2 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes2)", p0));
	}

	function logBytes3(bytes3 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes3)", p0));
	}

	function logBytes4(bytes4 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes4)", p0));
	}

	function logBytes5(bytes5 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes5)", p0));
	}

	function logBytes6(bytes6 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes6)", p0));
	}

	function logBytes7(bytes7 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes7)", p0));
	}

	function logBytes8(bytes8 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes8)", p0));
	}

	function logBytes9(bytes9 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes9)", p0));
	}

	function logBytes10(bytes10 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes10)", p0));
	}

	function logBytes11(bytes11 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes11)", p0));
	}

	function logBytes12(bytes12 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes12)", p0));
	}

	function logBytes13(bytes13 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes13)", p0));
	}

	function logBytes14(bytes14 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes14)", p0));
	}

	function logBytes15(bytes15 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes15)", p0));
	}

	function logBytes16(bytes16 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes16)", p0));
	}

	function logBytes17(bytes17 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes17)", p0));
	}

	function logBytes18(bytes18 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes18)", p0));
	}

	function logBytes19(bytes19 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes19)", p0));
	}

	function logBytes20(bytes20 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes20)", p0));
	}

	function logBytes21(bytes21 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes21)", p0));
	}

	function logBytes22(bytes22 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes22)", p0));
	}

	function logBytes23(bytes23 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes23)", p0));
	}

	function logBytes24(bytes24 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes24)", p0));
	}

	function logBytes25(bytes25 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes25)", p0));
	}

	function logBytes26(bytes26 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes26)", p0));
	}

	function logBytes27(bytes27 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes27)", p0));
	}

	function logBytes28(bytes28 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes28)", p0));
	}

	function logBytes29(bytes29 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes29)", p0));
	}

	function logBytes30(bytes30 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes30)", p0));
	}

	function logBytes31(bytes31 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes31)", p0));
	}

	function logBytes32(bytes32 p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bytes32)", p0));
	}

	function log(uint p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint)", p0));
	}

	function log(string memory p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string)", p0));
	}

	function log(bool p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool)", p0));
	}

	function log(address p0) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address)", p0));
	}

	function log(uint p0, uint p1) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,uint)", p0, p1));
	}

	function log(uint p0, string memory p1) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,string)", p0, p1));
	}

	function log(uint p0, bool p1) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,bool)", p0, p1));
	}

	function log(uint p0, address p1) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,address)", p0, p1));
	}

	function log(string memory p0, uint p1) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,uint)", p0, p1));
	}

	function log(string memory p0, string memory p1) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,string)", p0, p1));
	}

	function log(string memory p0, bool p1) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,bool)", p0, p1));
	}

	function log(string memory p0, address p1) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,address)", p0, p1));
	}

	function log(bool p0, uint p1) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,uint)", p0, p1));
	}

	function log(bool p0, string memory p1) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,string)", p0, p1));
	}

	function log(bool p0, bool p1) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,bool)", p0, p1));
	}

	function log(bool p0, address p1) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,address)", p0, p1));
	}

	function log(address p0, uint p1) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,uint)", p0, p1));
	}

	function log(address p0, string memory p1) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,string)", p0, p1));
	}

	function log(address p0, bool p1) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,bool)", p0, p1));
	}

	function log(address p0, address p1) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,address)", p0, p1));
	}

	function log(uint p0, uint p1, uint p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,uint,uint)", p0, p1, p2));
	}

	function log(uint p0, uint p1, string memory p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,uint,string)", p0, p1, p2));
	}

	function log(uint p0, uint p1, bool p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,uint,bool)", p0, p1, p2));
	}

	function log(uint p0, uint p1, address p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,uint,address)", p0, p1, p2));
	}

	function log(uint p0, string memory p1, uint p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,string,uint)", p0, p1, p2));
	}

	function log(uint p0, string memory p1, string memory p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,string,string)", p0, p1, p2));
	}

	function log(uint p0, string memory p1, bool p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,string,bool)", p0, p1, p2));
	}

	function log(uint p0, string memory p1, address p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,string,address)", p0, p1, p2));
	}

	function log(uint p0, bool p1, uint p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,bool,uint)", p0, p1, p2));
	}

	function log(uint p0, bool p1, string memory p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,bool,string)", p0, p1, p2));
	}

	function log(uint p0, bool p1, bool p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,bool,bool)", p0, p1, p2));
	}

	function log(uint p0, bool p1, address p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,bool,address)", p0, p1, p2));
	}

	function log(uint p0, address p1, uint p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,address,uint)", p0, p1, p2));
	}

	function log(uint p0, address p1, string memory p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,address,string)", p0, p1, p2));
	}

	function log(uint p0, address p1, bool p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,address,bool)", p0, p1, p2));
	}

	function log(uint p0, address p1, address p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,address,address)", p0, p1, p2));
	}

	function log(string memory p0, uint p1, uint p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,uint,uint)", p0, p1, p2));
	}

	function log(string memory p0, uint p1, string memory p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,uint,string)", p0, p1, p2));
	}

	function log(string memory p0, uint p1, bool p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,uint,bool)", p0, p1, p2));
	}

	function log(string memory p0, uint p1, address p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,uint,address)", p0, p1, p2));
	}

	function log(string memory p0, string memory p1, uint p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,string,uint)", p0, p1, p2));
	}

	function log(string memory p0, string memory p1, string memory p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,string,string)", p0, p1, p2));
	}

	function log(string memory p0, string memory p1, bool p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,string,bool)", p0, p1, p2));
	}

	function log(string memory p0, string memory p1, address p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,string,address)", p0, p1, p2));
	}

	function log(string memory p0, bool p1, uint p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,bool,uint)", p0, p1, p2));
	}

	function log(string memory p0, bool p1, string memory p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,bool,string)", p0, p1, p2));
	}

	function log(string memory p0, bool p1, bool p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,bool,bool)", p0, p1, p2));
	}

	function log(string memory p0, bool p1, address p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,bool,address)", p0, p1, p2));
	}

	function log(string memory p0, address p1, uint p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,address,uint)", p0, p1, p2));
	}

	function log(string memory p0, address p1, string memory p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,address,string)", p0, p1, p2));
	}

	function log(string memory p0, address p1, bool p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,address,bool)", p0, p1, p2));
	}

	function log(string memory p0, address p1, address p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,address,address)", p0, p1, p2));
	}

	function log(bool p0, uint p1, uint p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,uint,uint)", p0, p1, p2));
	}

	function log(bool p0, uint p1, string memory p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,uint,string)", p0, p1, p2));
	}

	function log(bool p0, uint p1, bool p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,uint,bool)", p0, p1, p2));
	}

	function log(bool p0, uint p1, address p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,uint,address)", p0, p1, p2));
	}

	function log(bool p0, string memory p1, uint p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,string,uint)", p0, p1, p2));
	}

	function log(bool p0, string memory p1, string memory p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,string,string)", p0, p1, p2));
	}

	function log(bool p0, string memory p1, bool p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,string,bool)", p0, p1, p2));
	}

	function log(bool p0, string memory p1, address p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,string,address)", p0, p1, p2));
	}

	function log(bool p0, bool p1, uint p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,bool,uint)", p0, p1, p2));
	}

	function log(bool p0, bool p1, string memory p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,bool,string)", p0, p1, p2));
	}

	function log(bool p0, bool p1, bool p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,bool,bool)", p0, p1, p2));
	}

	function log(bool p0, bool p1, address p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,bool,address)", p0, p1, p2));
	}

	function log(bool p0, address p1, uint p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,address,uint)", p0, p1, p2));
	}

	function log(bool p0, address p1, string memory p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,address,string)", p0, p1, p2));
	}

	function log(bool p0, address p1, bool p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,address,bool)", p0, p1, p2));
	}

	function log(bool p0, address p1, address p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,address,address)", p0, p1, p2));
	}

	function log(address p0, uint p1, uint p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,uint,uint)", p0, p1, p2));
	}

	function log(address p0, uint p1, string memory p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,uint,string)", p0, p1, p2));
	}

	function log(address p0, uint p1, bool p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,uint,bool)", p0, p1, p2));
	}

	function log(address p0, uint p1, address p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,uint,address)", p0, p1, p2));
	}

	function log(address p0, string memory p1, uint p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,string,uint)", p0, p1, p2));
	}

	function log(address p0, string memory p1, string memory p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,string,string)", p0, p1, p2));
	}

	function log(address p0, string memory p1, bool p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,string,bool)", p0, p1, p2));
	}

	function log(address p0, string memory p1, address p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,string,address)", p0, p1, p2));
	}

	function log(address p0, bool p1, uint p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,bool,uint)", p0, p1, p2));
	}

	function log(address p0, bool p1, string memory p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,bool,string)", p0, p1, p2));
	}

	function log(address p0, bool p1, bool p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,bool,bool)", p0, p1, p2));
	}

	function log(address p0, bool p1, address p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,bool,address)", p0, p1, p2));
	}

	function log(address p0, address p1, uint p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,address,uint)", p0, p1, p2));
	}

	function log(address p0, address p1, string memory p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,address,string)", p0, p1, p2));
	}

	function log(address p0, address p1, bool p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,address,bool)", p0, p1, p2));
	}

	function log(address p0, address p1, address p2) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,address,address)", p0, p1, p2));
	}

	function log(uint p0, uint p1, uint p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,uint,uint,uint)", p0, p1, p2, p3));
	}

	function log(uint p0, uint p1, uint p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,uint,uint,string)", p0, p1, p2, p3));
	}

	function log(uint p0, uint p1, uint p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,uint,uint,bool)", p0, p1, p2, p3));
	}

	function log(uint p0, uint p1, uint p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,uint,uint,address)", p0, p1, p2, p3));
	}

	function log(uint p0, uint p1, string memory p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,uint,string,uint)", p0, p1, p2, p3));
	}

	function log(uint p0, uint p1, string memory p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,uint,string,string)", p0, p1, p2, p3));
	}

	function log(uint p0, uint p1, string memory p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,uint,string,bool)", p0, p1, p2, p3));
	}

	function log(uint p0, uint p1, string memory p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,uint,string,address)", p0, p1, p2, p3));
	}

	function log(uint p0, uint p1, bool p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,uint,bool,uint)", p0, p1, p2, p3));
	}

	function log(uint p0, uint p1, bool p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,uint,bool,string)", p0, p1, p2, p3));
	}

	function log(uint p0, uint p1, bool p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,uint,bool,bool)", p0, p1, p2, p3));
	}

	function log(uint p0, uint p1, bool p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,uint,bool,address)", p0, p1, p2, p3));
	}

	function log(uint p0, uint p1, address p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,uint,address,uint)", p0, p1, p2, p3));
	}

	function log(uint p0, uint p1, address p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,uint,address,string)", p0, p1, p2, p3));
	}

	function log(uint p0, uint p1, address p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,uint,address,bool)", p0, p1, p2, p3));
	}

	function log(uint p0, uint p1, address p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,uint,address,address)", p0, p1, p2, p3));
	}

	function log(uint p0, string memory p1, uint p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,string,uint,uint)", p0, p1, p2, p3));
	}

	function log(uint p0, string memory p1, uint p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,string,uint,string)", p0, p1, p2, p3));
	}

	function log(uint p0, string memory p1, uint p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,string,uint,bool)", p0, p1, p2, p3));
	}

	function log(uint p0, string memory p1, uint p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,string,uint,address)", p0, p1, p2, p3));
	}

	function log(uint p0, string memory p1, string memory p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,string,string,uint)", p0, p1, p2, p3));
	}

	function log(uint p0, string memory p1, string memory p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,string,string,string)", p0, p1, p2, p3));
	}

	function log(uint p0, string memory p1, string memory p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,string,string,bool)", p0, p1, p2, p3));
	}

	function log(uint p0, string memory p1, string memory p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,string,string,address)", p0, p1, p2, p3));
	}

	function log(uint p0, string memory p1, bool p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,string,bool,uint)", p0, p1, p2, p3));
	}

	function log(uint p0, string memory p1, bool p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,string,bool,string)", p0, p1, p2, p3));
	}

	function log(uint p0, string memory p1, bool p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,string,bool,bool)", p0, p1, p2, p3));
	}

	function log(uint p0, string memory p1, bool p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,string,bool,address)", p0, p1, p2, p3));
	}

	function log(uint p0, string memory p1, address p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,string,address,uint)", p0, p1, p2, p3));
	}

	function log(uint p0, string memory p1, address p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,string,address,string)", p0, p1, p2, p3));
	}

	function log(uint p0, string memory p1, address p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,string,address,bool)", p0, p1, p2, p3));
	}

	function log(uint p0, string memory p1, address p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,string,address,address)", p0, p1, p2, p3));
	}

	function log(uint p0, bool p1, uint p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,bool,uint,uint)", p0, p1, p2, p3));
	}

	function log(uint p0, bool p1, uint p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,bool,uint,string)", p0, p1, p2, p3));
	}

	function log(uint p0, bool p1, uint p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,bool,uint,bool)", p0, p1, p2, p3));
	}

	function log(uint p0, bool p1, uint p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,bool,uint,address)", p0, p1, p2, p3));
	}

	function log(uint p0, bool p1, string memory p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,bool,string,uint)", p0, p1, p2, p3));
	}

	function log(uint p0, bool p1, string memory p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,bool,string,string)", p0, p1, p2, p3));
	}

	function log(uint p0, bool p1, string memory p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,bool,string,bool)", p0, p1, p2, p3));
	}

	function log(uint p0, bool p1, string memory p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,bool,string,address)", p0, p1, p2, p3));
	}

	function log(uint p0, bool p1, bool p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,bool,bool,uint)", p0, p1, p2, p3));
	}

	function log(uint p0, bool p1, bool p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,bool,bool,string)", p0, p1, p2, p3));
	}

	function log(uint p0, bool p1, bool p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,bool,bool,bool)", p0, p1, p2, p3));
	}

	function log(uint p0, bool p1, bool p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,bool,bool,address)", p0, p1, p2, p3));
	}

	function log(uint p0, bool p1, address p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,bool,address,uint)", p0, p1, p2, p3));
	}

	function log(uint p0, bool p1, address p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,bool,address,string)", p0, p1, p2, p3));
	}

	function log(uint p0, bool p1, address p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,bool,address,bool)", p0, p1, p2, p3));
	}

	function log(uint p0, bool p1, address p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,bool,address,address)", p0, p1, p2, p3));
	}

	function log(uint p0, address p1, uint p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,address,uint,uint)", p0, p1, p2, p3));
	}

	function log(uint p0, address p1, uint p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,address,uint,string)", p0, p1, p2, p3));
	}

	function log(uint p0, address p1, uint p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,address,uint,bool)", p0, p1, p2, p3));
	}

	function log(uint p0, address p1, uint p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,address,uint,address)", p0, p1, p2, p3));
	}

	function log(uint p0, address p1, string memory p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,address,string,uint)", p0, p1, p2, p3));
	}

	function log(uint p0, address p1, string memory p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,address,string,string)", p0, p1, p2, p3));
	}

	function log(uint p0, address p1, string memory p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,address,string,bool)", p0, p1, p2, p3));
	}

	function log(uint p0, address p1, string memory p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,address,string,address)", p0, p1, p2, p3));
	}

	function log(uint p0, address p1, bool p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,address,bool,uint)", p0, p1, p2, p3));
	}

	function log(uint p0, address p1, bool p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,address,bool,string)", p0, p1, p2, p3));
	}

	function log(uint p0, address p1, bool p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,address,bool,bool)", p0, p1, p2, p3));
	}

	function log(uint p0, address p1, bool p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,address,bool,address)", p0, p1, p2, p3));
	}

	function log(uint p0, address p1, address p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,address,address,uint)", p0, p1, p2, p3));
	}

	function log(uint p0, address p1, address p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,address,address,string)", p0, p1, p2, p3));
	}

	function log(uint p0, address p1, address p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,address,address,bool)", p0, p1, p2, p3));
	}

	function log(uint p0, address p1, address p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(uint,address,address,address)", p0, p1, p2, p3));
	}

	function log(string memory p0, uint p1, uint p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,uint,uint,uint)", p0, p1, p2, p3));
	}

	function log(string memory p0, uint p1, uint p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,uint,uint,string)", p0, p1, p2, p3));
	}

	function log(string memory p0, uint p1, uint p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,uint,uint,bool)", p0, p1, p2, p3));
	}

	function log(string memory p0, uint p1, uint p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,uint,uint,address)", p0, p1, p2, p3));
	}

	function log(string memory p0, uint p1, string memory p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,uint,string,uint)", p0, p1, p2, p3));
	}

	function log(string memory p0, uint p1, string memory p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,uint,string,string)", p0, p1, p2, p3));
	}

	function log(string memory p0, uint p1, string memory p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,uint,string,bool)", p0, p1, p2, p3));
	}

	function log(string memory p0, uint p1, string memory p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,uint,string,address)", p0, p1, p2, p3));
	}

	function log(string memory p0, uint p1, bool p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,uint,bool,uint)", p0, p1, p2, p3));
	}

	function log(string memory p0, uint p1, bool p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,uint,bool,string)", p0, p1, p2, p3));
	}

	function log(string memory p0, uint p1, bool p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,uint,bool,bool)", p0, p1, p2, p3));
	}

	function log(string memory p0, uint p1, bool p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,uint,bool,address)", p0, p1, p2, p3));
	}

	function log(string memory p0, uint p1, address p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,uint,address,uint)", p0, p1, p2, p3));
	}

	function log(string memory p0, uint p1, address p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,uint,address,string)", p0, p1, p2, p3));
	}

	function log(string memory p0, uint p1, address p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,uint,address,bool)", p0, p1, p2, p3));
	}

	function log(string memory p0, uint p1, address p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,uint,address,address)", p0, p1, p2, p3));
	}

	function log(string memory p0, string memory p1, uint p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,string,uint,uint)", p0, p1, p2, p3));
	}

	function log(string memory p0, string memory p1, uint p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,string,uint,string)", p0, p1, p2, p3));
	}

	function log(string memory p0, string memory p1, uint p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,string,uint,bool)", p0, p1, p2, p3));
	}

	function log(string memory p0, string memory p1, uint p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,string,uint,address)", p0, p1, p2, p3));
	}

	function log(string memory p0, string memory p1, string memory p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,string,string,uint)", p0, p1, p2, p3));
	}

	function log(string memory p0, string memory p1, string memory p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,string,string,string)", p0, p1, p2, p3));
	}

	function log(string memory p0, string memory p1, string memory p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,string,string,bool)", p0, p1, p2, p3));
	}

	function log(string memory p0, string memory p1, string memory p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,string,string,address)", p0, p1, p2, p3));
	}

	function log(string memory p0, string memory p1, bool p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,string,bool,uint)", p0, p1, p2, p3));
	}

	function log(string memory p0, string memory p1, bool p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,string,bool,string)", p0, p1, p2, p3));
	}

	function log(string memory p0, string memory p1, bool p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,string,bool,bool)", p0, p1, p2, p3));
	}

	function log(string memory p0, string memory p1, bool p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,string,bool,address)", p0, p1, p2, p3));
	}

	function log(string memory p0, string memory p1, address p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,string,address,uint)", p0, p1, p2, p3));
	}

	function log(string memory p0, string memory p1, address p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,string,address,string)", p0, p1, p2, p3));
	}

	function log(string memory p0, string memory p1, address p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,string,address,bool)", p0, p1, p2, p3));
	}

	function log(string memory p0, string memory p1, address p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,string,address,address)", p0, p1, p2, p3));
	}

	function log(string memory p0, bool p1, uint p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,bool,uint,uint)", p0, p1, p2, p3));
	}

	function log(string memory p0, bool p1, uint p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,bool,uint,string)", p0, p1, p2, p3));
	}

	function log(string memory p0, bool p1, uint p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,bool,uint,bool)", p0, p1, p2, p3));
	}

	function log(string memory p0, bool p1, uint p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,bool,uint,address)", p0, p1, p2, p3));
	}

	function log(string memory p0, bool p1, string memory p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,bool,string,uint)", p0, p1, p2, p3));
	}

	function log(string memory p0, bool p1, string memory p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,bool,string,string)", p0, p1, p2, p3));
	}

	function log(string memory p0, bool p1, string memory p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,bool,string,bool)", p0, p1, p2, p3));
	}

	function log(string memory p0, bool p1, string memory p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,bool,string,address)", p0, p1, p2, p3));
	}

	function log(string memory p0, bool p1, bool p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,bool,bool,uint)", p0, p1, p2, p3));
	}

	function log(string memory p0, bool p1, bool p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,bool,bool,string)", p0, p1, p2, p3));
	}

	function log(string memory p0, bool p1, bool p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,bool,bool,bool)", p0, p1, p2, p3));
	}

	function log(string memory p0, bool p1, bool p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,bool,bool,address)", p0, p1, p2, p3));
	}

	function log(string memory p0, bool p1, address p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,bool,address,uint)", p0, p1, p2, p3));
	}

	function log(string memory p0, bool p1, address p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,bool,address,string)", p0, p1, p2, p3));
	}

	function log(string memory p0, bool p1, address p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,bool,address,bool)", p0, p1, p2, p3));
	}

	function log(string memory p0, bool p1, address p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,bool,address,address)", p0, p1, p2, p3));
	}

	function log(string memory p0, address p1, uint p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,address,uint,uint)", p0, p1, p2, p3));
	}

	function log(string memory p0, address p1, uint p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,address,uint,string)", p0, p1, p2, p3));
	}

	function log(string memory p0, address p1, uint p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,address,uint,bool)", p0, p1, p2, p3));
	}

	function log(string memory p0, address p1, uint p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,address,uint,address)", p0, p1, p2, p3));
	}

	function log(string memory p0, address p1, string memory p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,address,string,uint)", p0, p1, p2, p3));
	}

	function log(string memory p0, address p1, string memory p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,address,string,string)", p0, p1, p2, p3));
	}

	function log(string memory p0, address p1, string memory p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,address,string,bool)", p0, p1, p2, p3));
	}

	function log(string memory p0, address p1, string memory p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,address,string,address)", p0, p1, p2, p3));
	}

	function log(string memory p0, address p1, bool p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,address,bool,uint)", p0, p1, p2, p3));
	}

	function log(string memory p0, address p1, bool p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,address,bool,string)", p0, p1, p2, p3));
	}

	function log(string memory p0, address p1, bool p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,address,bool,bool)", p0, p1, p2, p3));
	}

	function log(string memory p0, address p1, bool p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,address,bool,address)", p0, p1, p2, p3));
	}

	function log(string memory p0, address p1, address p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,address,address,uint)", p0, p1, p2, p3));
	}

	function log(string memory p0, address p1, address p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,address,address,string)", p0, p1, p2, p3));
	}

	function log(string memory p0, address p1, address p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,address,address,bool)", p0, p1, p2, p3));
	}

	function log(string memory p0, address p1, address p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(string,address,address,address)", p0, p1, p2, p3));
	}

	function log(bool p0, uint p1, uint p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,uint,uint,uint)", p0, p1, p2, p3));
	}

	function log(bool p0, uint p1, uint p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,uint,uint,string)", p0, p1, p2, p3));
	}

	function log(bool p0, uint p1, uint p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,uint,uint,bool)", p0, p1, p2, p3));
	}

	function log(bool p0, uint p1, uint p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,uint,uint,address)", p0, p1, p2, p3));
	}

	function log(bool p0, uint p1, string memory p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,uint,string,uint)", p0, p1, p2, p3));
	}

	function log(bool p0, uint p1, string memory p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,uint,string,string)", p0, p1, p2, p3));
	}

	function log(bool p0, uint p1, string memory p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,uint,string,bool)", p0, p1, p2, p3));
	}

	function log(bool p0, uint p1, string memory p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,uint,string,address)", p0, p1, p2, p3));
	}

	function log(bool p0, uint p1, bool p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,uint,bool,uint)", p0, p1, p2, p3));
	}

	function log(bool p0, uint p1, bool p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,uint,bool,string)", p0, p1, p2, p3));
	}

	function log(bool p0, uint p1, bool p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,uint,bool,bool)", p0, p1, p2, p3));
	}

	function log(bool p0, uint p1, bool p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,uint,bool,address)", p0, p1, p2, p3));
	}

	function log(bool p0, uint p1, address p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,uint,address,uint)", p0, p1, p2, p3));
	}

	function log(bool p0, uint p1, address p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,uint,address,string)", p0, p1, p2, p3));
	}

	function log(bool p0, uint p1, address p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,uint,address,bool)", p0, p1, p2, p3));
	}

	function log(bool p0, uint p1, address p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,uint,address,address)", p0, p1, p2, p3));
	}

	function log(bool p0, string memory p1, uint p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,string,uint,uint)", p0, p1, p2, p3));
	}

	function log(bool p0, string memory p1, uint p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,string,uint,string)", p0, p1, p2, p3));
	}

	function log(bool p0, string memory p1, uint p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,string,uint,bool)", p0, p1, p2, p3));
	}

	function log(bool p0, string memory p1, uint p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,string,uint,address)", p0, p1, p2, p3));
	}

	function log(bool p0, string memory p1, string memory p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,string,string,uint)", p0, p1, p2, p3));
	}

	function log(bool p0, string memory p1, string memory p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,string,string,string)", p0, p1, p2, p3));
	}

	function log(bool p0, string memory p1, string memory p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,string,string,bool)", p0, p1, p2, p3));
	}

	function log(bool p0, string memory p1, string memory p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,string,string,address)", p0, p1, p2, p3));
	}

	function log(bool p0, string memory p1, bool p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,string,bool,uint)", p0, p1, p2, p3));
	}

	function log(bool p0, string memory p1, bool p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,string,bool,string)", p0, p1, p2, p3));
	}

	function log(bool p0, string memory p1, bool p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,string,bool,bool)", p0, p1, p2, p3));
	}

	function log(bool p0, string memory p1, bool p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,string,bool,address)", p0, p1, p2, p3));
	}

	function log(bool p0, string memory p1, address p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,string,address,uint)", p0, p1, p2, p3));
	}

	function log(bool p0, string memory p1, address p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,string,address,string)", p0, p1, p2, p3));
	}

	function log(bool p0, string memory p1, address p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,string,address,bool)", p0, p1, p2, p3));
	}

	function log(bool p0, string memory p1, address p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,string,address,address)", p0, p1, p2, p3));
	}

	function log(bool p0, bool p1, uint p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,bool,uint,uint)", p0, p1, p2, p3));
	}

	function log(bool p0, bool p1, uint p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,bool,uint,string)", p0, p1, p2, p3));
	}

	function log(bool p0, bool p1, uint p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,bool,uint,bool)", p0, p1, p2, p3));
	}

	function log(bool p0, bool p1, uint p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,bool,uint,address)", p0, p1, p2, p3));
	}

	function log(bool p0, bool p1, string memory p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,bool,string,uint)", p0, p1, p2, p3));
	}

	function log(bool p0, bool p1, string memory p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,bool,string,string)", p0, p1, p2, p3));
	}

	function log(bool p0, bool p1, string memory p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,bool,string,bool)", p0, p1, p2, p3));
	}

	function log(bool p0, bool p1, string memory p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,bool,string,address)", p0, p1, p2, p3));
	}

	function log(bool p0, bool p1, bool p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,bool,bool,uint)", p0, p1, p2, p3));
	}

	function log(bool p0, bool p1, bool p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,bool,bool,string)", p0, p1, p2, p3));
	}

	function log(bool p0, bool p1, bool p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,bool,bool,bool)", p0, p1, p2, p3));
	}

	function log(bool p0, bool p1, bool p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,bool,bool,address)", p0, p1, p2, p3));
	}

	function log(bool p0, bool p1, address p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,bool,address,uint)", p0, p1, p2, p3));
	}

	function log(bool p0, bool p1, address p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,bool,address,string)", p0, p1, p2, p3));
	}

	function log(bool p0, bool p1, address p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,bool,address,bool)", p0, p1, p2, p3));
	}

	function log(bool p0, bool p1, address p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,bool,address,address)", p0, p1, p2, p3));
	}

	function log(bool p0, address p1, uint p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,address,uint,uint)", p0, p1, p2, p3));
	}

	function log(bool p0, address p1, uint p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,address,uint,string)", p0, p1, p2, p3));
	}

	function log(bool p0, address p1, uint p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,address,uint,bool)", p0, p1, p2, p3));
	}

	function log(bool p0, address p1, uint p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,address,uint,address)", p0, p1, p2, p3));
	}

	function log(bool p0, address p1, string memory p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,address,string,uint)", p0, p1, p2, p3));
	}

	function log(bool p0, address p1, string memory p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,address,string,string)", p0, p1, p2, p3));
	}

	function log(bool p0, address p1, string memory p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,address,string,bool)", p0, p1, p2, p3));
	}

	function log(bool p0, address p1, string memory p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,address,string,address)", p0, p1, p2, p3));
	}

	function log(bool p0, address p1, bool p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,address,bool,uint)", p0, p1, p2, p3));
	}

	function log(bool p0, address p1, bool p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,address,bool,string)", p0, p1, p2, p3));
	}

	function log(bool p0, address p1, bool p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,address,bool,bool)", p0, p1, p2, p3));
	}

	function log(bool p0, address p1, bool p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,address,bool,address)", p0, p1, p2, p3));
	}

	function log(bool p0, address p1, address p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,address,address,uint)", p0, p1, p2, p3));
	}

	function log(bool p0, address p1, address p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,address,address,string)", p0, p1, p2, p3));
	}

	function log(bool p0, address p1, address p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,address,address,bool)", p0, p1, p2, p3));
	}

	function log(bool p0, address p1, address p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(bool,address,address,address)", p0, p1, p2, p3));
	}

	function log(address p0, uint p1, uint p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,uint,uint,uint)", p0, p1, p2, p3));
	}

	function log(address p0, uint p1, uint p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,uint,uint,string)", p0, p1, p2, p3));
	}

	function log(address p0, uint p1, uint p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,uint,uint,bool)", p0, p1, p2, p3));
	}

	function log(address p0, uint p1, uint p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,uint,uint,address)", p0, p1, p2, p3));
	}

	function log(address p0, uint p1, string memory p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,uint,string,uint)", p0, p1, p2, p3));
	}

	function log(address p0, uint p1, string memory p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,uint,string,string)", p0, p1, p2, p3));
	}

	function log(address p0, uint p1, string memory p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,uint,string,bool)", p0, p1, p2, p3));
	}

	function log(address p0, uint p1, string memory p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,uint,string,address)", p0, p1, p2, p3));
	}

	function log(address p0, uint p1, bool p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,uint,bool,uint)", p0, p1, p2, p3));
	}

	function log(address p0, uint p1, bool p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,uint,bool,string)", p0, p1, p2, p3));
	}

	function log(address p0, uint p1, bool p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,uint,bool,bool)", p0, p1, p2, p3));
	}

	function log(address p0, uint p1, bool p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,uint,bool,address)", p0, p1, p2, p3));
	}

	function log(address p0, uint p1, address p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,uint,address,uint)", p0, p1, p2, p3));
	}

	function log(address p0, uint p1, address p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,uint,address,string)", p0, p1, p2, p3));
	}

	function log(address p0, uint p1, address p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,uint,address,bool)", p0, p1, p2, p3));
	}

	function log(address p0, uint p1, address p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,uint,address,address)", p0, p1, p2, p3));
	}

	function log(address p0, string memory p1, uint p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,string,uint,uint)", p0, p1, p2, p3));
	}

	function log(address p0, string memory p1, uint p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,string,uint,string)", p0, p1, p2, p3));
	}

	function log(address p0, string memory p1, uint p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,string,uint,bool)", p0, p1, p2, p3));
	}

	function log(address p0, string memory p1, uint p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,string,uint,address)", p0, p1, p2, p3));
	}

	function log(address p0, string memory p1, string memory p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,string,string,uint)", p0, p1, p2, p3));
	}

	function log(address p0, string memory p1, string memory p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,string,string,string)", p0, p1, p2, p3));
	}

	function log(address p0, string memory p1, string memory p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,string,string,bool)", p0, p1, p2, p3));
	}

	function log(address p0, string memory p1, string memory p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,string,string,address)", p0, p1, p2, p3));
	}

	function log(address p0, string memory p1, bool p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,string,bool,uint)", p0, p1, p2, p3));
	}

	function log(address p0, string memory p1, bool p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,string,bool,string)", p0, p1, p2, p3));
	}

	function log(address p0, string memory p1, bool p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,string,bool,bool)", p0, p1, p2, p3));
	}

	function log(address p0, string memory p1, bool p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,string,bool,address)", p0, p1, p2, p3));
	}

	function log(address p0, string memory p1, address p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,string,address,uint)", p0, p1, p2, p3));
	}

	function log(address p0, string memory p1, address p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,string,address,string)", p0, p1, p2, p3));
	}

	function log(address p0, string memory p1, address p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,string,address,bool)", p0, p1, p2, p3));
	}

	function log(address p0, string memory p1, address p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,string,address,address)", p0, p1, p2, p3));
	}

	function log(address p0, bool p1, uint p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,bool,uint,uint)", p0, p1, p2, p3));
	}

	function log(address p0, bool p1, uint p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,bool,uint,string)", p0, p1, p2, p3));
	}

	function log(address p0, bool p1, uint p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,bool,uint,bool)", p0, p1, p2, p3));
	}

	function log(address p0, bool p1, uint p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,bool,uint,address)", p0, p1, p2, p3));
	}

	function log(address p0, bool p1, string memory p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,bool,string,uint)", p0, p1, p2, p3));
	}

	function log(address p0, bool p1, string memory p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,bool,string,string)", p0, p1, p2, p3));
	}

	function log(address p0, bool p1, string memory p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,bool,string,bool)", p0, p1, p2, p3));
	}

	function log(address p0, bool p1, string memory p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,bool,string,address)", p0, p1, p2, p3));
	}

	function log(address p0, bool p1, bool p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,bool,bool,uint)", p0, p1, p2, p3));
	}

	function log(address p0, bool p1, bool p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,bool,bool,string)", p0, p1, p2, p3));
	}

	function log(address p0, bool p1, bool p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,bool,bool,bool)", p0, p1, p2, p3));
	}

	function log(address p0, bool p1, bool p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,bool,bool,address)", p0, p1, p2, p3));
	}

	function log(address p0, bool p1, address p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,bool,address,uint)", p0, p1, p2, p3));
	}

	function log(address p0, bool p1, address p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,bool,address,string)", p0, p1, p2, p3));
	}

	function log(address p0, bool p1, address p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,bool,address,bool)", p0, p1, p2, p3));
	}

	function log(address p0, bool p1, address p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,bool,address,address)", p0, p1, p2, p3));
	}

	function log(address p0, address p1, uint p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,address,uint,uint)", p0, p1, p2, p3));
	}

	function log(address p0, address p1, uint p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,address,uint,string)", p0, p1, p2, p3));
	}

	function log(address p0, address p1, uint p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,address,uint,bool)", p0, p1, p2, p3));
	}

	function log(address p0, address p1, uint p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,address,uint,address)", p0, p1, p2, p3));
	}

	function log(address p0, address p1, string memory p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,address,string,uint)", p0, p1, p2, p3));
	}

	function log(address p0, address p1, string memory p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,address,string,string)", p0, p1, p2, p3));
	}

	function log(address p0, address p1, string memory p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,address,string,bool)", p0, p1, p2, p3));
	}

	function log(address p0, address p1, string memory p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,address,string,address)", p0, p1, p2, p3));
	}

	function log(address p0, address p1, bool p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,address,bool,uint)", p0, p1, p2, p3));
	}

	function log(address p0, address p1, bool p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,address,bool,string)", p0, p1, p2, p3));
	}

	function log(address p0, address p1, bool p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,address,bool,bool)", p0, p1, p2, p3));
	}

	function log(address p0, address p1, bool p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,address,bool,address)", p0, p1, p2, p3));
	}

	function log(address p0, address p1, address p2, uint p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,address,address,uint)", p0, p1, p2, p3));
	}

	function log(address p0, address p1, address p2, string memory p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,address,address,string)", p0, p1, p2, p3));
	}

	function log(address p0, address p1, address p2, bool p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,address,address,bool)", p0, p1, p2, p3));
	}

	function log(address p0, address p1, address p2, address p3) internal view {
		_sendLogPayload(abi.encodeWithSignature("log(address,address,address,address)", p0, p1, p2, p3));
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
        uint256 currentAllowance = allowance(account, _msgSender());
        require(currentAllowance >= amount, "ERC20: burn amount exceeds allowance");
        unchecked {
            _approve(account, _msgSender(), currentAllowance - amount);
        }
        _burn(account, amount);
    }
}
pragma solidity ^0.8.0;

import "../ERC20.sol";
import "../../../security/Pausable.sol";

/**
 * @dev ERC20 token with pausable token transfers, minting and burning.
 *
 * Useful for scenarios such as preventing trades until the end of an evaluation
 * period, or having an emergency switch for freezing all token transfers in the
 * event of a large bug.
 */
abstract contract ERC20Pausable is ERC20, Pausable {
    /**
     * @dev See {ERC20-_beforeTokenTransfer}.
     *
     * Requirements:
     *
     * - the contract must not be paused.
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        super._beforeTokenTransfer(from, to, amount);

        require(!paused(), "ERC20Pausable: token transfer while paused");
    }
}
pragma solidity ^0.8.0;

import "./IAccessControlEnumerable.sol";
import "./AccessControl.sol";
import "../utils/structs/EnumerableSet.sol";

/**
 * @dev Extension of {AccessControl} that allows enumerating the members of each role.
 */
abstract contract AccessControlEnumerable is IAccessControlEnumerable, AccessControl {
    using EnumerableSet for EnumerableSet.AddressSet;

    mapping(bytes32 => EnumerableSet.AddressSet) private _roleMembers;

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAccessControlEnumerable).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     * @dev Returns one of the accounts that have `role`. `index` must be a
     * value between 0 and {getRoleMemberCount}, non-inclusive.
     *
     * Role bearers are not sorted in any particular way, and their ordering may
     * change at any point.
     *
     * WARNING: When using {getRoleMember} and {getRoleMemberCount}, make sure
     * you perform all queries on the same block. See the following
     * https://forum.openzeppelin.com/t/iterating-over-elements-on-enumerableset-in-openzeppelin-contracts/2296[forum post]
     * for more information.
     */
    function getRoleMember(bytes32 role, uint256 index) public view override returns (address) {
        return _roleMembers[role].at(index);
    }

    /**
     * @dev Returns the number of accounts that have `role`. Can be used
     * together with {getRoleMember} to enumerate all bearers of a role.
     */
    function getRoleMemberCount(bytes32 role) public view override returns (uint256) {
        return _roleMembers[role].length();
    }

    /**
     * @dev Overload {grantRole} to track enumerable memberships
     */
    function grantRole(bytes32 role, address account) public virtual override(AccessControl, IAccessControl) {
        super.grantRole(role, account);
        _roleMembers[role].add(account);
    }

    /**
     * @dev Overload {revokeRole} to track enumerable memberships
     */
    function revokeRole(bytes32 role, address account) public virtual override(AccessControl, IAccessControl) {
        super.revokeRole(role, account);
        _roleMembers[role].remove(account);
    }

    /**
     * @dev Overload {renounceRole} to track enumerable memberships
     */
    function renounceRole(bytes32 role, address account) public virtual override(AccessControl, IAccessControl) {
        super.renounceRole(role, account);
        _roleMembers[role].remove(account);
    }

    /**
     * @dev Overload {_setupRole} to track enumerable memberships
     */
    function _setupRole(bytes32 role, address account) internal virtual override {
        super._setupRole(role, account);
        _roleMembers[role].add(account);
    }
}
pragma solidity ^0.8.0;

import "../utils/Context.sol";

/**
 * @dev Contract module which allows children to implement an emergency stop
 * mechanism that can be triggered by an authorized account.
 *
 * This module is used through inheritance. It will make available the
 * modifiers `whenNotPaused` and `whenPaused`, which can be applied to
 * the functions of your contract. Note that they will not be pausable by
 * simply including this module, only once the modifiers are put in place.
 */
abstract contract Pausable is Context {
    /**
     * @dev Emitted when the pause is triggered by `account`.
     */
    event Paused(address account);

    /**
     * @dev Emitted when the pause is lifted by `account`.
     */
    event Unpaused(address account);

    bool private _paused;

    /**
     * @dev Initializes the contract in unpaused state.
     */
    constructor() {
        _paused = false;
    }

    /**
     * @dev Returns true if the contract is paused, and false otherwise.
     */
    function paused() public view virtual returns (bool) {
        return _paused;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is not paused.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    modifier whenNotPaused() {
        require(!paused(), "Pausable: paused");
        _;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is paused.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    modifier whenPaused() {
        require(paused(), "Pausable: not paused");
        _;
    }

    /**
     * @dev Triggers stopped state.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    function _pause() internal virtual whenNotPaused {
        _paused = true;
        emit Paused(_msgSender());
    }

    /**
     * @dev Returns to normal state.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    function _unpause() internal virtual whenPaused {
        _paused = false;
        emit Unpaused(_msgSender());
    }
}
pragma solidity ^0.8.0;

import "./IAccessControl.sol";

/**
 * @dev External interface of AccessControlEnumerable declared to support ERC165 detection.
 */
interface IAccessControlEnumerable is IAccessControl {
    /**
     * @dev Returns one of the accounts that have `role`. `index` must be a
     * value between 0 and {getRoleMemberCount}, non-inclusive.
     *
     * Role bearers are not sorted in any particular way, and their ordering may
     * change at any point.
     *
     * WARNING: When using {getRoleMember} and {getRoleMemberCount}, make sure
     * you perform all queries on the same block. See the following
     * https://forum.openzeppelin.com/t/iterating-over-elements-on-enumerableset-in-openzeppelin-contracts/2296[forum post]
     * for more information.
     */
    function getRoleMember(bytes32 role, uint256 index) external view returns (address);

    /**
     * @dev Returns the number of accounts that have `role`. Can be used
     * together with {getRoleMember} to enumerate all bearers of a role.
     */
    function getRoleMemberCount(bytes32 role) external view returns (uint256);
}
pragma solidity ^0.8.0;

/**
 * @dev Library for managing
 * https://en.wikipedia.org/wiki/Set_(abstract_data_type)[sets] of primitive
 * types.
 *
 * Sets have the following properties:
 *
 * - Elements are added, removed, and checked for existence in constant time
 * (O(1)).
 * - Elements are enumerated in O(n). No guarantees are made on the ordering.
 *
 * ```
 * contract Example {
 *     // Add the library methods
 *     using EnumerableSet for EnumerableSet.AddressSet;
 *
 *     // Declare a set state variable
 *     EnumerableSet.AddressSet private mySet;
 * }
 * ```
 *
 * As of v3.3.0, sets of type `bytes32` (`Bytes32Set`), `address` (`AddressSet`)
 * and `uint256` (`UintSet`) are supported.
 */
library EnumerableSet {
    // To implement this library for multiple types with as little code
    // repetition as possible, we write it in terms of a generic Set type with
    // bytes32 values.
    // The Set implementation uses private functions, and user-facing
    // implementations (such as AddressSet) are just wrappers around the
    // underlying Set.
    // This means that we can only create new EnumerableSets for types that fit
    // in bytes32.

    struct Set {
        // Storage of set values
        bytes32[] _values;
        // Position of the value in the `values` array, plus 1 because index 0
        // means a value is not in the set.
        mapping(bytes32 => uint256) _indexes;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function _add(Set storage set, bytes32 value) private returns (bool) {
        if (!_contains(set, value)) {
            set._values.push(value);
            // The value is stored at length-1, but we add 1 to all indexes
            // and use 0 as a sentinel value
            set._indexes[value] = set._values.length;
            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function _remove(Set storage set, bytes32 value) private returns (bool) {
        // We read and store the value's index to prevent multiple reads from the same storage slot
        uint256 valueIndex = set._indexes[value];

        if (valueIndex != 0) {
            // Equivalent to contains(set, value)
            // To delete an element from the _values array in O(1), we swap the element to delete with the last one in
            // the array, and then remove the last element (sometimes called as 'swap and pop').
            // This modifies the order of the array, as noted in {at}.

            uint256 toDeleteIndex = valueIndex - 1;
            uint256 lastIndex = set._values.length - 1;

            if (lastIndex != toDeleteIndex) {
                bytes32 lastvalue = set._values[lastIndex];

                // Move the last value to the index where the value to delete is
                set._values[toDeleteIndex] = lastvalue;
                // Update the index for the moved value
                set._indexes[lastvalue] = valueIndex; // Replace lastvalue's index to valueIndex
            }

            // Delete the slot where the moved value was stored
            set._values.pop();

            // Delete the index for the deleted slot
            delete set._indexes[value];

            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function _contains(Set storage set, bytes32 value) private view returns (bool) {
        return set._indexes[value] != 0;
    }

    /**
     * @dev Returns the number of values on the set. O(1).
     */
    function _length(Set storage set) private view returns (uint256) {
        return set._values.length;
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function _at(Set storage set, uint256 index) private view returns (bytes32) {
        return set._values[index];
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function _values(Set storage set) private view returns (bytes32[] memory) {
        return set._values;
    }

    // Bytes32Set

    struct Bytes32Set {
        Set _inner;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function add(Bytes32Set storage set, bytes32 value) internal returns (bool) {
        return _add(set._inner, value);
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function remove(Bytes32Set storage set, bytes32 value) internal returns (bool) {
        return _remove(set._inner, value);
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(Bytes32Set storage set, bytes32 value) internal view returns (bool) {
        return _contains(set._inner, value);
    }

    /**
     * @dev Returns the number of values in the set. O(1).
     */
    function length(Bytes32Set storage set) internal view returns (uint256) {
        return _length(set._inner);
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function at(Bytes32Set storage set, uint256 index) internal view returns (bytes32) {
        return _at(set._inner, index);
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function values(Bytes32Set storage set) internal view returns (bytes32[] memory) {
        return _values(set._inner);
    }

    // AddressSet

    struct AddressSet {
        Set _inner;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function add(AddressSet storage set, address value) internal returns (bool) {
        return _add(set._inner, bytes32(uint256(uint160(value))));
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function remove(AddressSet storage set, address value) internal returns (bool) {
        return _remove(set._inner, bytes32(uint256(uint160(value))));
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(AddressSet storage set, address value) internal view returns (bool) {
        return _contains(set._inner, bytes32(uint256(uint160(value))));
    }

    /**
     * @dev Returns the number of values in the set. O(1).
     */
    function length(AddressSet storage set) internal view returns (uint256) {
        return _length(set._inner);
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function at(AddressSet storage set, uint256 index) internal view returns (address) {
        return address(uint160(uint256(_at(set._inner, index))));
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function values(AddressSet storage set) internal view returns (address[] memory) {
        bytes32[] memory store = _values(set._inner);
        address[] memory result;

        assembly {
            result := store
        }

        return result;
    }

    // UintSet

    struct UintSet {
        Set _inner;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function add(UintSet storage set, uint256 value) internal returns (bool) {
        return _add(set._inner, bytes32(value));
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function remove(UintSet storage set, uint256 value) internal returns (bool) {
        return _remove(set._inner, bytes32(value));
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(UintSet storage set, uint256 value) internal view returns (bool) {
        return _contains(set._inner, bytes32(value));
    }

    /**
     * @dev Returns the number of values on the set. O(1).
     */
    function length(UintSet storage set) internal view returns (uint256) {
        return _length(set._inner);
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function at(UintSet storage set, uint256 index) internal view returns (uint256) {
        return uint256(_at(set._inner, index));
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function values(UintSet storage set) internal view returns (uint256[] memory) {
        bytes32[] memory store = _values(set._inner);
        uint256[] memory result;

        assembly {
            result := store
        }

        return result;
    }
}
pragma solidity 0.8.9;
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

import "./Fund.sol";
import "./abstract/AbstractLock.sol";
import "./lib/FundWorkerUtils.sol";
import "./lib/SwapUtils.sol";
import "./HedgeToken.sol";
import "../interfaces/IFundProcessor.sol";


contract FundWorker is AccessControl, Lock, Pausable {
    FundWorkerUtils.FundWorkerState public state;

    bool public swap = false;

    // The router used to swap the fee into BNB or stable coin
    IUniswapV2Router02 public router;

    using FundWorkerUtils for FundWorkerUtils.FundWorkerState;
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    uint256 public tokenRewardAmount = 750 * 10 ** 18;
    uint256 public swapSlippage = 150; // 1.5% slippage

    uint256 public lastMint;
    address public splitterAddr;
    Fund public fund;
    HedgeToken public token;
    ERC20 public busd = ERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
    
    event SwapFailed(address from, address to, uint256 amount, uint256 slippage);

    constructor(
        address fundAddress,
        address tokenAddress
    ) {
        fund = Fund(payable(fundAddress));
        token = HedgeToken(tokenAddress);
        state.batchSize = 5;
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(MANAGER_ROLE, msg.sender);
    }

    function collectableProfits() external view returns (uint256 currentProfits, uint256 bounty) {
        currentProfits = state.pendingCollectableProfits(fund);
        bounty = (currentProfits * fund.collectProfitReward()) / 100;
        return (currentProfits, bounty / 100);
    }

    function collectProfits() external {
        uint256 reward = state.collectProfitBatch(fund);

        if (!swap) {
            busd.transfer(msg.sender, reward);
        } else {
            try SwapUtils.swapTokensForTokens(router, busd, token, reward, swapSlippage) {
                token.transfer(msg.sender, token.balanceOf(address(this)));
            } catch {
                emit SwapFailed(address(busd), address(token), reward, swapSlippage);
                busd.transfer(msg.sender, reward);
            }
        }

        if(willGetBonus()) {
            token.mint(msg.sender, tokenRewardAmount);
            lastMint = block.timestamp;
        }
        
        fund.updateRewardSnap();
    }

    function willGetBonus() public view returns (bool) {
        return block.timestamp - lastMint > 1 days && tokenRewardAmount > 0 ;
    } 

    function setBatchSize(uint8 batchSize) external onlyRole(MANAGER_ROLE) {
        require(batchSize > 0, "Batch cannot be 0");
        FundWorkerUtils.FundWorkerState storage st = state;
        st.batchSize = batchSize;
    }

    function setFundAddress(address newAddress) external onlyRole(MANAGER_ROLE) {
        require(address(fund) != newAddress,"New address is the same as old address");
        require(newAddress != address(0), "New address cannot be 0x00");
        fund = Fund(payable(newAddress));
    }

    function setSplitterAddress(address newAddress) external onlyRole(MANAGER_ROLE) {
        require(address(fund) != newAddress, "New address is the same as old address");
        require(newAddress != address(0), "New address cannot be 0x00");
        splitterAddr = newAddress;
    }

    function setRewards(uint256 reward) external onlyRole(MANAGER_ROLE) {
        tokenRewardAmount = reward;
    }

    function destroy(address receiver) external onlyRole(MANAGER_ROLE) {
        if (busd.balanceOf(address(this)) > 0) {
            busd.transfer(receiver, busd.balanceOf(address(this))); 
        }

        if (token.balanceOf(address(this)) > 0) {
            token.transfer(receiver, token.balanceOf(address(this)));
        }

        selfdestruct(payable(receiver));
    }
}
pragma solidity 0.8.9;


import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import "../interfaces/IFundManager.sol";
import "../interfaces/IInvestmentStrategy.sol";
import "../interfaces/IStash.sol";
import "./abstract/AbstractFund.sol";

contract Fund is AbstractFund {
    using EnumerableMap for EnumerableMap.UintToAddressMap;

    bool claimEnabled = true;
    uint16 public performanceFee = 2;
    uint256 public collectedPerformanceFee ;

    address private vault;
    IRewardStash public rewardStash;

    EnumerableMap.UintToAddressMap private clientIndex;
    mapping(address => FundUtils.FundClient) clients;

    modifier canClaim(uint256 amount) {
        require(claimEnabled, "Fund: Not allowed to claim");
        require(amount > 0 && amount <= _pendingRewards(), "Fund: Not enough funds to claim");
        _;
    }

    constructor(address _stashAddress, address _vault)
        AbstractFund(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56, 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56) {
        rewardStash = IRewardStash(_stashAddress);
        vault = _vault;
    }

    // Add a new strategy
    function addClient(address _clientAddress) external override onlyRole(MANAGER_ROLE) {
        if (clients[_clientAddress].exists) {
            return;
        }
        
        clients[_clientAddress] = FundUtils.FundClient({
            profitAllocation: 0,
            pendingProfit: 0,
            exists: true,
            key: getNewKey()
        });

        clientIndex.set(clients[_clientAddress].key, _clientAddress);
    }

    // Remove a strategy 
    function removeClient(address _clientId, address _fundDestonation) external override onlyRole(MANAGER_ROLE)  {
        if (!clients[_clientId].exists) {
            return;
        }
        uint256 key = clients[_clientId].key;
        uint256 pendingProfit = clients[_clientId].pendingProfit;
        clientIndex.remove(key);
        unallocatedProfit += clients[_clientId].profitAllocation;
        delete clients[_clientId]; 
        _claim(pendingProfit, _fundDestonation);
    }

    function updateProfitAllocation(address _strategyId, uint8 allocation) external override onlyRole(MANAGER_ROLE) {
        require(allocation <= 100, "Allocation overflow");
        FundUtils.FundClient storage fundClient = clients[_strategyId];

        if (fundClient.profitAllocation >= allocation) {
            unallocatedProfit += fundClient.profitAllocation - allocation;
        } else {
            require(fundClient.profitAllocation + unallocatedProfit >= allocation, "Insuficient reserve");
            unallocatedProfit -= allocation - fundClient.profitAllocation;
        }
        fundClient.profitAllocation = allocation;
    }
  
    // Claim BUSD rewards into other address
    function _claim(uint256 amount, address _destination) internal override canClaim(amount) { 
        clients[msg.sender].pendingProfit -= amount;
        rewardStash.unstash(amount);
        rewardAsset.transfer(_destination, amount);
        _updateRewardSnap();
    }

    function _stashProfit(uint256 availableProfit) internal override {
        uint256 fee = (availableProfit * performanceFee) / 100 ;
        rewardAsset.increaseAllowance(address(rewardStash), availableProfit - fee); 
        rewardStash.stash(availableProfit - fee);
        rewardAsset.transfer(_vaultAddress(), fee); 
        collectedPerformanceFee += fee;

        for (uint256 index = 0; index < clientIndex.length(); index++) {
            (, address clientAddress) = clientIndex.at(index);
            FundUtils.FundClient storage client = clients[clientAddress];
            uint256 profitShare = ((availableProfit - fee) * client.profitAllocation) / 100;
            client.pendingProfit += profitShare;
        }
    }

    function _stashCapitalPool(uint256 availableCapital) internal override {
       usd.transfer(_vaultAddress(), availableCapital);
    }

    function _stashETHCapitalPool(uint256 availableCapital) internal override {
        payable(_vaultAddress()).transfer(availableCapital);
    }

    function _vaultAddress() internal view override returns (address) {
        return address(vault);
    }

    function totalGenerateRewards() public override view returns(uint256) {
        uint256 brutReward = rewardStash.stashValue();
        return totalRewardsClaimed + brutReward;
    }

    // Get total pending rewards value of an address in BUSD
    function _pendingRewards() internal view override returns (uint256) {
        return clients[msg.sender].pendingProfit;
    }

     // Get total pending rewards value of an address in BUSD
    function currentStashValue() external view returns (uint256) {
        return rewardStash.stashValue(); 
    }

    function setClaimStatus(bool status) external {
        require(claimEnabled != status, "Status allready set");
        claimEnabled = status;
    }

    function updateVault(address newAddress) external onlyRole(DEFAULT_ADMIN_ROLE) { 
        require(newAddress != address(vault), "Vault Address Unchanged");
        require(newAddress != address(0), "Vault cannot be null");

        vault = newAddress;
    }

    function updateStash(address newAddress) external onlyRole(DEFAULT_ADMIN_ROLE) { 
        require(newAddress != address(rewardStash),"Stash Address Unchanged");
        require(newAddress != address(0), "Stash cannot be null");

        rewardStash = IRewardStash(newAddress);
    }
}
pragma solidity 0.8.9;

import "../../interfaces/IInvestmentStrategy.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../Fund.sol";

library FundWorkerUtils {
    event CollectError(address strategy);

    struct FundWorkerState {
        uint256 lastCollectedStrategy;
        uint8 batchSize;
    }

    function pendingCollectableProfits(FundWorkerState memory worker, Fund fund) public view returns (uint256) {
        uint256 poolSize = fund.strategyPoolSize();
        if(poolSize == 0) {
            return 0;
        }
        uint256 profit = 0;
        uint8 steps = 0;
        uint256 currentIndex = (worker.lastCollectedStrategy + 1) % poolSize;
        while (steps < worker.batchSize) {
            steps++;
            (address strategyAddress, bool exists, ) = fund.getStrategy(currentIndex);
            if(!exists) {
                if(currentIndex == worker.lastCollectedStrategy) {
                    break;
                }

                currentIndex = (currentIndex + 1) %  poolSize;
               
                continue;
            }
         
            IInvestmentStrategy strategy = IInvestmentStrategy(strategyAddress);

            try strategy.pendingProfit() returns (uint256 pendingProfit) {
                profit += pendingProfit;
            } catch {
                // do nothing
            }
            
            if(currentIndex == worker.lastCollectedStrategy) {
                break;
            }
            
            currentIndex = (currentIndex + 1) % poolSize;
        }
        return profit;
    }

    function collectProfitBatch(FundWorkerState storage worker, Fund fund) public returns (uint256) {
        uint256 poolSize = fund.strategyPoolSize();
        if(poolSize == 0) {
            return 0;
        }
        uint8 steps = 0;
        uint256 currentIndex = (worker.lastCollectedStrategy + 1) % poolSize;
        uint256 totalReward = 0;
        while (steps < worker.batchSize) {
            steps++;
            (address strategyAddress, bool exists, ) = fund.getStrategy(currentIndex);
            
            if(!exists) {
                if(currentIndex == worker.lastCollectedStrategy) {
                    break;
                }
                currentIndex = (currentIndex + 1) % poolSize;
                continue;
            }
         
            IInvestmentStrategy strategy = IInvestmentStrategy(strategyAddress);
            (, uint256 amount) = fund.collectProfit(strategy); 
            totalReward += amount;
               
            if(currentIndex == worker.lastCollectedStrategy) {
                break;
            }

            currentIndex = (currentIndex + 1) % poolSize;
        }
        fund.stashProfitPool();
        worker.lastCollectedStrategy = currentIndex;
        return totalReward;
    }
}
pragma solidity ^0.8.0;

import "./EnumerableSet.sol";

/**
 * @dev Library for managing an enumerable variant of Solidity's
 * https://solidity.readthedocs.io/en/latest/types.html#mapping-types[`mapping`]
 * type.
 *
 * Maps have the following properties:
 *
 * - Entries are added, removed, and checked for existence in constant time
 * (O(1)).
 * - Entries are enumerated in O(n). No guarantees are made on the ordering.
 *
 * ```
 * contract Example {
 *     // Add the library methods
 *     using EnumerableMap for EnumerableMap.UintToAddressMap;
 *
 *     // Declare a set state variable
 *     EnumerableMap.UintToAddressMap private myMap;
 * }
 * ```
 *
 * As of v3.0.0, only maps of type `uint256 -> address` (`UintToAddressMap`) are
 * supported.
 */
library EnumerableMap {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    // To implement this library for multiple types with as little code
    // repetition as possible, we write it in terms of a generic Map type with
    // bytes32 keys and values.
    // The Map implementation uses private functions, and user-facing
    // implementations (such as Uint256ToAddressMap) are just wrappers around
    // the underlying Map.
    // This means that we can only create new EnumerableMaps for types that fit
    // in bytes32.

    struct Map {
        // Storage of keys
        EnumerableSet.Bytes32Set _keys;
        mapping(bytes32 => bytes32) _values;
    }

    /**
     * @dev Adds a key-value pair to a map, or updates the value for an existing
     * key. O(1).
     *
     * Returns true if the key was added to the map, that is if it was not
     * already present.
     */
    function _set(
        Map storage map,
        bytes32 key,
        bytes32 value
    ) private returns (bool) {
        map._values[key] = value;
        return map._keys.add(key);
    }

    /**
     * @dev Removes a key-value pair from a map. O(1).
     *
     * Returns true if the key was removed from the map, that is if it was present.
     */
    function _remove(Map storage map, bytes32 key) private returns (bool) {
        delete map._values[key];
        return map._keys.remove(key);
    }

    /**
     * @dev Returns true if the key is in the map. O(1).
     */
    function _contains(Map storage map, bytes32 key) private view returns (bool) {
        return map._keys.contains(key);
    }

    /**
     * @dev Returns the number of key-value pairs in the map. O(1).
     */
    function _length(Map storage map) private view returns (uint256) {
        return map._keys.length();
    }

    /**
     * @dev Returns the key-value pair stored at position `index` in the map. O(1).
     *
     * Note that there are no guarantees on the ordering of entries inside the
     * array, and it may change when more entries are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function _at(Map storage map, uint256 index) private view returns (bytes32, bytes32) {
        bytes32 key = map._keys.at(index);
        return (key, map._values[key]);
    }

    /**
     * @dev Tries to returns the value associated with `key`.  O(1).
     * Does not revert if `key` is not in the map.
     */
    function _tryGet(Map storage map, bytes32 key) private view returns (bool, bytes32) {
        bytes32 value = map._values[key];
        if (value == bytes32(0)) {
            return (_contains(map, key), bytes32(0));
        } else {
            return (true, value);
        }
    }

    /**
     * @dev Returns the value associated with `key`.  O(1).
     *
     * Requirements:
     *
     * - `key` must be in the map.
     */
    function _get(Map storage map, bytes32 key) private view returns (bytes32) {
        bytes32 value = map._values[key];
        require(value != 0 || _contains(map, key), "EnumerableMap: nonexistent key");
        return value;
    }

    /**
     * @dev Same as {_get}, with a custom error message when `key` is not in the map.
     *
     * CAUTION: This function is deprecated because it requires allocating memory for the error
     * message unnecessarily. For custom revert reasons use {_tryGet}.
     */
    function _get(
        Map storage map,
        bytes32 key,
        string memory errorMessage
    ) private view returns (bytes32) {
        bytes32 value = map._values[key];
        require(value != 0 || _contains(map, key), errorMessage);
        return value;
    }

    // UintToAddressMap

    struct UintToAddressMap {
        Map _inner;
    }

    /**
     * @dev Adds a key-value pair to a map, or updates the value for an existing
     * key. O(1).
     *
     * Returns true if the key was added to the map, that is if it was not
     * already present.
     */
    function set(
        UintToAddressMap storage map,
        uint256 key,
        address value
    ) internal returns (bool) {
        return _set(map._inner, bytes32(key), bytes32(uint256(uint160(value))));
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the key was removed from the map, that is if it was present.
     */
    function remove(UintToAddressMap storage map, uint256 key) internal returns (bool) {
        return _remove(map._inner, bytes32(key));
    }

    /**
     * @dev Returns true if the key is in the map. O(1).
     */
    function contains(UintToAddressMap storage map, uint256 key) internal view returns (bool) {
        return _contains(map._inner, bytes32(key));
    }

    /**
     * @dev Returns the number of elements in the map. O(1).
     */
    function length(UintToAddressMap storage map) internal view returns (uint256) {
        return _length(map._inner);
    }

    /**
     * @dev Returns the element stored at position `index` in the set. O(1).
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function at(UintToAddressMap storage map, uint256 index) internal view returns (uint256, address) {
        (bytes32 key, bytes32 value) = _at(map._inner, index);
        return (uint256(key), address(uint160(uint256(value))));
    }

    /**
     * @dev Tries to returns the value associated with `key`.  O(1).
     * Does not revert if `key` is not in the map.
     *
     * _Available since v3.4._
     */
    function tryGet(UintToAddressMap storage map, uint256 key) internal view returns (bool, address) {
        (bool success, bytes32 value) = _tryGet(map._inner, bytes32(key));
        return (success, address(uint160(uint256(value))));
    }

    /**
     * @dev Returns the value associated with `key`.  O(1).
     *
     * Requirements:
     *
     * - `key` must be in the map.
     */
    function get(UintToAddressMap storage map, uint256 key) internal view returns (address) {
        return address(uint160(uint256(_get(map._inner, bytes32(key)))));
    }

    /**
     * @dev Same as {get}, with a custom error message when `key` is not in the map.
     *
     * CAUTION: This function is deprecated because it requires allocating memory for the error
     * message unnecessarily. For custom revert reasons use {tryGet}.
     */
    function get(
        UintToAddressMap storage map,
        uint256 key,
        string memory errorMessage
    ) internal view returns (address) {
        return address(uint160(uint256(_get(map._inner, bytes32(key), errorMessage))));
    }
}
pragma solidity 0.8.9;

/**
    Fund contracts interface.
    The fund accepts ETH investments and generates USD rewards.

    The fund manages multiple asset pools and distributes capital to them. Each asset can receive capital and use 
    it to genearate USD returns which are sent back to the fund. Returns can be reinvested or made avaibale to
    the investors to claim.

    IMPORTANT: Funds manager can convert the ETH to other coins therfore the initial investment can lose it's value
*/
interface IFund {
    // Invest a BNB into the fund
    function invest() external payable;

    //INvest BNB into the fund
    function investBUSD(uint256 amount) external;

    // Claim BUSD rewards
    function claim(uint256 amount) external;

    // Claim BUSD rewards into other address
    function claimTo(uint256 amount, address _destination) external;

    // Add a new strategy
    function addStrategy(address strategyId) external;

    // Remove a strategy
    function removeStrategy(address strategyId, bool keepCapitalAsAssets, bool force) external;

    // Add a new client
    function addClient(address clientId) external;

    // Remove a client
    function removeClient(address clientId, address destinationAddress) external;

    // Get a strategy by index
    function getStrategy(uint256 index) external view  returns(address _address, bool exists, uint8 allocation);

    // Get a strategy by address
    function getStrategyByAddress(address _address) external view returns(uint256 index, bool exists, uint8 allocation);

    // Get total pending rewards value in BUSD
    function pendingRewards() external view returns (uint256);

    // Update fund allocation percentage
    function updateAllocation(address _strategyId, uint8 allocation) external;

    // Update client allocations
    function updateProfitAllocation(address _clientId, uint8 allocation) external;
}
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

import "./AbstractLock.sol";
import "../lib/FundUtils.sol";
import "../../interfaces/IFundManager.sol";
import "../../interfaces/IInvestmentStrategy.sol";
import "../../interfaces/IStash.sol";

abstract contract AbstractFund is AccessControl, IFund, Lock {
    using EnumerableMap for EnumerableMap.UintToAddressMap;
    event CollectError(address strategy);
    event WithdrawError(address strategy);
    uint256 lastKey = 1;
    
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant WORKER_ROLE = keccak256("WORKER_ROLE");

    uint8 public unallocatedCapital = 100;
    uint8 public unallocatedProfit = 100;
    // Collect profits reward percent 100 = 1%
    uint16 public collectProfitReward = 50;
    uint256 public totalRewardsClaimed;

    // The reward asset, BUSD for now
    ERC20 public rewardAsset;
    ERC20 public usd;
    FundUtils.InvestmentLog public invstementLog;
    FundUtils.RewardSnapshot public rewardSnapShot;

    EnumerableMap.UintToAddressMap private strategyIndex;
    mapping(address => FundUtils.StrategyConfiguration) strategies;

    constructor(address _rewardAsset, address usdAddress) {
        rewardAsset = ERC20(_rewardAsset);
        usd = ERC20(usdAddress);

        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _setupRole(MANAGER_ROLE, msg.sender);
        _setupRole(WORKER_ROLE, msg.sender);
    }

    function strategyPoolSize() external view returns (uint256) {
        return strategyIndex.length();
    }

    function stashProfitPool() external {
        require(
            hasRole(WORKER_ROLE, msg.sender) ||
            hasRole(MANAGER_ROLE, msg.sender) ||
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Permission denied"
        );

        stashProfit();
    }

    // Stash profits
    function stashProfit() internal {
        if (invstementLog.profitPool > 0) {
            _stashProfit(invstementLog.profitPool);
            invstementLog.profitPool = 0;
        }
    }

    function stashCapitalPool() external onlyRole(MANAGER_ROLE) {
        _stashBUSDCapital();
    }

    function _stashBUSDCapital() internal {
        if (invstementLog.busdCapitalPool > 0) {
            _stashCapitalPool(invstementLog.busdCapitalPool);
            invstementLog.busdCapitalPool = 0;
        }
    }

    function stashETHCapitalPool() external onlyRole(MANAGER_ROLE) {
        _stashETHCapital();
    }

    function _stashETHCapital() internal {
        if (address(this).balance > 0) {
            _stashETHCapitalPool(address(this).balance);
        }
    }

    function invest() external payable override lock {
        handleInvestment();
    }

    function investBUSD(uint256 amount) external override lock {
        addFundsToCapitalPool(amount);
        handleInvestment();
    }

    function addFundsToCapitalPool(uint256 amount) public {
        invstementLog.busdCapitalPool += amount;
        usd.transferFrom(msg.sender, address(this), amount);
    }

    // Update the reward snapshot
    function updateRewardSnap() external {
        _updateRewardSnap();
    }

    // Claim rewards
    function claim(uint256 amount) external override lock {
        _claim(amount, msg.sender);
        totalRewardsClaimed += amount;
    }

    // Claim  rewards into  address
    function claimTo(uint256 amount, address _destination) external override lock {
        _claim(amount, _destination);
        totalRewardsClaimed += amount;
    }

    // Handle Profit Claims
    function _claim(uint256 amount, address _destination) internal virtual;

    // Handle Stashing
    function _stashProfit(uint256 availableProfit) internal virtual;
    function _stashCapitalPool(uint256 availableCapital) internal virtual;
    function _stashETHCapitalPool(uint256 availableCapital) internal virtual;

    // Get total pending rewards value of an address
    function _pendingRewards() internal view virtual returns (uint256);

    //Should return the vault Address
    function _vaultAddress() internal view virtual returns (address);

    function totalGenerateRewards() public view virtual returns (uint256);

    function vaultAddress() external view returns (address) {
        return _vaultAddress();
    }

    // Get total pending rewards value of an address
    function pendingRewards() external view override returns (uint256) {
        return _pendingRewards();
    }

    function handleInvestment() internal {
        uint256 length = strategyIndex.length();

        if (length == 0) {
            return;
        }

        invstementLog.lastInvestmentIndex = (invstementLog.lastInvestmentIndex + 1) % length;
        (, address strategyAddress) = strategyIndex.at(invstementLog.lastInvestmentIndex);

        FundUtils.StrategyConfiguration memory strategyConfig = strategies[strategyAddress];

        if (strategyConfig.capitalAllocation == 0 ) {
            return;
        }

        IInvestmentStrategy strategy = IInvestmentStrategy(strategyAddress);

        if (invstementLog.busdCapitalPool > 0) {
            uint256 busdCapitalAllocation = (invstementLog.busdCapitalPool * strategyConfig.capitalAllocation) / 100;
            usd.increaseAllowance(strategyAddress, busdCapitalAllocation);
            strategy.addBusdCapital(busdCapitalAllocation);
            invstementLog.busdCapitalPool -= busdCapitalAllocation; 
        }

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            uint256 ethCapitalAllocation = (ethBalance * strategyConfig.capitalAllocation) / 100;
            strategy.addCapital{value: ethCapitalAllocation}();
        }
    }

    function getNewKey() internal returns (uint256) {
        return lastKey++;
    }

    function pendingProfits() public view returns (uint256) {
        uint256 profit = 0; 
        for (uint256 index = 0; index < strategyIndex.length(); index++) {
            (, address strategyAddress) = strategyIndex.at(index); 

            IInvestmentStrategy strategy = IInvestmentStrategy(strategyAddress);
            profit += strategy.pendingProfit();
        } 
        return profit;
    }

    // Add a new strategy
    function addStrategy(address _strategyAddress) external override onlyRole(MANAGER_ROLE) {
        if (strategies[_strategyAddress].exists) {
            return;
        }
        strategies[_strategyAddress] = FundUtils.StrategyConfiguration({
            capitalAllocation: 0,
            exists: true,
            key: getNewKey()
        });

        strategyIndex.set(strategies[_strategyAddress].key, _strategyAddress);
    }

    // Remove a strategy 
    function removeStrategy(address _strategyId, bool keepCapitalAsAssets, bool force) external override onlyRole(MANAGER_ROLE) {
        if (!strategies[_strategyId].exists) {
            return;
        }
        uint256 key = strategies[_strategyId].key;
        if (!force) {
            IInvestmentStrategy strategy = IInvestmentStrategy(_strategyId);
            (bool success,uint256 pendingProfit) = FundUtils.collectProfit(strategy);
            require(success, "Could not collect profit");

            invstementLog.profitPool += pendingProfit;
        
            stashProfit();

            bool result = withdrawCapital(strategy, keepCapitalAsAssets);
            require(result, "Could not withdraw capital");
        }

        strategyIndex.remove(key);
        unallocatedCapital += strategies[_strategyId].capitalAllocation;
        delete strategies[_strategyId]; 
    }

    function updateAllocation(address _strategyId, uint8 allocation) external override onlyRole(MANAGER_ROLE) {
        require(allocation <= 100, "Allocation overflow");
        FundUtils.StrategyConfiguration storage strategyConfig = strategies[_strategyId];

        if (strategyConfig.capitalAllocation >= allocation) {
            unallocatedCapital += strategyConfig.capitalAllocation - allocation;
        } else {
            require(strategyConfig.capitalAllocation + unallocatedCapital >= allocation, "Insuficient reserve");
            unallocatedCapital -= allocation - strategyConfig.capitalAllocation;
        }
        strategyConfig.capitalAllocation = allocation;
    }

    function totalCapitalValue() external view returns (uint256) {
        uint256 result = 0;
        for (uint256 index = 0; index < strategyIndex.length(); index++) {
            (, address strategyAddress) = strategyIndex.at(index);

            IInvestmentStrategy strategy = IInvestmentStrategy(strategyAddress);
            (, uint256 busdAmount) = strategy.assetPoolValue();
            result += busdAmount;
        }
        return result;
    }

    function collectProfit(IInvestmentStrategy strategy) external onlyRole(WORKER_ROLE) returns(bool, uint256) {
        (bool success, uint256 pendingProfit) = FundUtils.collectProfit(strategy);
        if(success && pendingProfit > 0) {
            uint256 reward = (pendingProfit * collectProfitReward) / 10_000;
            invstementLog.profitPool += pendingProfit - reward;
            usd.transfer(address(msg.sender), reward);
            return (success, reward);
        }

        return (success, 0);
    }

    function withdrawCapital(IInvestmentStrategy strategy, bool keepCapitalAsAssets) internal returns (bool) {
        return FundUtils.withdrawCapital(strategy, _vaultAddress(), keepCapitalAsAssets);
    }

    function _updateRewardSnap() internal {
        if (block.timestamp - rewardSnapShot.time0 > 5 minutes) { 
            rewardSnapShot.time1 = rewardSnapShot.time0;
            rewardSnapShot.total1 = rewardSnapShot.total0;
        }
        rewardSnapShot.time0 = block.timestamp;
        rewardSnapShot.total0 = totalGenerateRewardsWithProfits();
    }

    function totalGenerateRewardsWithProfits() public view returns(uint256) {
        uint256 currentPendingProfits = pendingProfits();
        return totalGenerateRewards() + currentPendingProfits;
    }

    function getStrategy(uint256 index) external view override returns (address id, bool exists, uint8 allocation) {
        (, address strategyAddress) = strategyIndex.at(index);
        FundUtils.StrategyConfiguration memory strategyConfig = strategies[strategyAddress];

        return (
            strategyAddress,
            strategyConfig.exists,
            strategyConfig.capitalAllocation
        );
    }

    function getStrategyByAddress(address _address) external view override returns (uint256 key, bool exists, uint8 allocation) {
        FundUtils.StrategyConfiguration memory strategyConfig = strategies[_address];
        return (
            strategyConfig.key,
            strategyConfig.exists,
            strategyConfig.capitalAllocation
        );
    }

    /** Use this to free any locked capital */
    function directBusdToStrategy(address strategyAddress, uint256 amount, bool force) external onlyRole(MANAGER_ROLE) {
        require(usd.balanceOf(address(this)) > 0, "Insuficient funds");
        require(force || invstementLog.busdCapitalPool >= amount, "Insuficient investment funds"); 
        require(strategies[strategyAddress].exists, "Strategy does not exist");
        usd.increaseAllowance(strategyAddress, amount);
        IInvestmentStrategy(strategyAddress).addBusdCapital(amount);
        if(invstementLog.busdCapitalPool >= amount) {
            invstementLog.busdCapitalPool -= amount;
        } 
    }

    /** Use this to free any locked capital */
    function directETHToStrategy(address strategyAddress, uint256 amount) external onlyRole(MANAGER_ROLE) {
        require(address(this).balance >= amount, "Insuficient funds");
        require(strategies[strategyAddress].exists, "Strategy does not exist");
        IInvestmentStrategy(strategyAddress).addCapital{value: amount}();
    }

    function profitPool() external view returns(uint256) {
        return invstementLog.profitPool;
    }   

    function destroy() external onlyRole(DEFAULT_ADMIN_ROLE)  {
        _stashBUSDCapital();
        _stashETHCapital();
        stashProfit();

        if(usd.balanceOf(address(this)) > 0) {
            usd.transfer(_vaultAddress(), usd.balanceOf(address(this)));
        }

        selfdestruct(payable(_vaultAddress()));
    }

    function setCollectProfitReward(uint16 newReward) external onlyRole(MANAGER_ROLE) {
        require(newReward > 0 && newReward < 10_000, "Reward must be between 0 and 100%");
        collectProfitReward = newReward;
    } 

    receive() external payable {

    }
}
pragma solidity 0.8.9;

import "../../interfaces/IInvestmentStrategy.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

library FundUtils {

    event CollectError(address strategyId, bytes msg);
    event WithdrawError(address strategyId, bytes msg);

    struct StrategyConfiguration {
        bool exists;
        uint8 capitalAllocation;
        uint256 key;
    }

    struct FundClient {
        bool exists;
        uint8 profitAllocation;
        uint256 pendingProfit;
        uint256 key;
    }

    struct RewardSnapshot {
        uint256 time0;
        uint256 total0;
        uint256 time1;
        uint256 total1;
    }

    struct InvestmentLog {
        uint256 lastInvestmentIndex;
        uint256 busdCapitalPool;
        uint256 profitPool;
    }

    function collectProfit(IInvestmentStrategy strategy) internal returns (bool, uint256) {
        // Collect BUSD profits each strategy
        try strategy.collectProfit(address(this)) returns (uint256 profit) {
            return (true, profit);
        } catch (bytes memory _err) {
            emit CollectError(address(strategy), _err);
            return (false, 0);
        }
    }

    function withdrawCapital(IInvestmentStrategy strategy, address vaultAddress, bool keepCapitalAsAssets) internal returns (bool) {
        bool success = true; 
        if (!keepCapitalAsAssets) {
            try strategy.withdrawCapital(0, vaultAddress) {
            } catch (bytes memory _err) {
                emit WithdrawError(address(strategy), _err);
                success = false;
            }
        } else {
            try strategy.withdrawCapitalAsAssets(0, vaultAddress) {  
            } catch (bytes memory _err) {
                emit WithdrawError(address(strategy), _err);
                success = false;
            }
        }
        return success;
    }
}
pragma solidity 0.8.9;

interface IFeeManager {
    function processFee() external;
    function processBusdFee(uint256 amount) external;
    function distributeBusdFees() external;
    function distributeETHFees() external;
}
pragma solidity 0.8.9;

interface IRewardManager  {
    // Called by the token contract whenever a transfer happends
    function notifyBalanceUpdate(address _address, uint256 prevBalance) external;

    // Returns the unclaimed reward value of a given address
    function unclaimedRewardValue(address _address) external view returns (uint256);

    function fee(address _address) external view returns (uint256);
}
pragma solidity 0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "../interfaces/IFundManager.sol";
import "../interfaces/IRewardManager.sol";
import "./abstract/AbstractYielder.sol";
import "./RewardFeeProvider.sol";

contract RewardManager is AbstractYielder, IRewardManager {
    struct AddressRewardLog {
        uint256 lastClaimTime;
        bool excludedFromFee;
    }

    // The minium balance of Tokens an address must have in order for it to receive a reward
    uint256 public minRewardBalance = 1_000_000 * 10 ** 18;
    IFund public fund;
    IERC20 public token;
    RewardFeeProvider public feeProvider;

    address public feeAddress;
    mapping(address => AddressRewardLog) public rewardLogBook;

    event ActivateRewards(address _address);

    modifier mustHaveFundSet() {
        require(address(fund) != address(0), "No Fund contract was set");
        _;
    }

    modifier notExcluded(address account) {
        if (isExcluded(account)) {
            return;
        }
        _;
    }

    modifier onlyTokenContractOrOwner() {
        require(msg.sender == address(token) || msg.sender == address(owner()), "Only token contract can call this function");
        _;
    }

    constructor(ERC20 _token, address _feeAddress) {
        token = _token;
        feeAddress = _feeAddress;
    }

 
    function notifyBalanceUpdate(address _address, uint256 prevBalance) external override onlyTokenContractOrOwner notExcluded(_address) {
        uint256 balance = token.balanceOf(_address);
        // Calculate balanceDiff
        if (prevBalance > balance) {
            handleBalanceDecrease(_address, balance);
            return;
        }

        if (prevBalance < balance) {
            handleBalanceIncrease(_address, balance);

            // User entered the reward pool, set last claim time to now
            if (prevBalance < minRewardBalance && balance >= minRewardBalance) {
                rewardLogBook[_address].lastClaimTime = block.timestamp; 
            }
            return;
        }
    }
    
    function unclaimedRewardValue(address _address) public view override returns (uint256) {
        return _pendingReward(_address);
    }

    function setFundAddress(address newAddress) public onlyOwner {
        require(address(fund) != newAddress, "New address is the same as old address");
        require(address(0) != newAddress, "Fund address cannot be address(0)");
        fund = IFund(newAddress);
    }

    function setTokenAddress(address newAddress) public onlyOwner {
        require(address(token) != newAddress, "New address is the same as old address"); 
        require(address(0) != newAddress, "Token address cannot be address(0)");
        token = IERC20(newAddress);
    }

    function setFeeAddress(address newAddress) public onlyOwner {
        require(address(feeAddress) != newAddress, "New address is the same as old address"); 
        require(address(0) != newAddress, "Fee address cannot be address(0)"); 
        feeAddress = newAddress;
    }

    function setFeeProvider(address newAddress) public onlyOwner {
        require(address(feeProvider) != newAddress, "New address is the same as old address");
        require(address(0) != newAddress, "Provider address cannot be address(0)");
        feeProvider = RewardFeeProvider(newAddress);
    }

    function updateMinRewardBalance(uint256 _minRewardBalance) external onlyOwner {
        minRewardBalance = _minRewardBalance;
    }

    function banAddress(address _address) external onlyOwner {
        excludeAddress(_address);
        InvestorInfo storage user = investorInfo[_address];
        try fund.claimTo(user.leftToClaim, feeAddress) {} catch {}
        user.leftToClaim = 0;
    }

    function includeAddress(address _address) public virtual override onlyOwner {
        super.includeAddress(_address);
        handleBalanceIncrease(_address, token.balanceOf(_address));
    }

    function rewardEligible(address _address) external view returns (bool) {
        return investorInfo[_address].amount >= minRewardBalance;
    }

    function destroy() external onlyOwner {
        selfdestruct(payable(msg.sender));
    }

    function _totalReward() internal view override returns (uint256) {
        return fund.pendingRewards();
    }

    function _sweepOutstandingReward(uint256 reward) internal override {
          if(reward > 0) {
            fund.claimTo(reward, feeAddress);
        }
    }

    function _claimReward(uint256 reward, address receiver) internal override {
        uint256 feeValue = caculateClaimFee(msg.sender, reward);
        fund.claimTo(reward - feeValue, receiver);
        fund.claimTo(feeValue, feeAddress);

        // In case the reward manager was paused, handle balance decrease to avoid leeches
        uint256 currentDeposited = investorInfo[msg.sender].amount;
        uint256 currentBalance = token.balanceOf(msg.sender);
        rewardLogBook[msg.sender].lastClaimTime = block.timestamp; 

        if (currentBalance < currentDeposited) {
            handleBalanceDecrease(msg.sender, currentBalance);
            return;
        } 

        if (currentBalance < minRewardBalance && currentBalance > 0) {
            withdrawFrom(0, msg.sender);
        }
    }


    function handleBalanceDecrease(address _address, uint256 currentBalance) internal {
        uint256 amount = investorInfo[_address].amount;
        if (currentBalance < minRewardBalance && amount > 0) {
            withdrawFrom(0, _address);
            return;
        }

        if (currentBalance >= minRewardBalance) {
            // Bring balances back in sync in case reward manager does not get notified of transfers
            if (amount > currentBalance) {
                withdrawFrom(amount - currentBalance, _address);
            } 
            
            if(amount < currentBalance) {
                depositTo(currentBalance - amount, _address);
            }
        }
    }

    function handleBalanceIncrease(address _address, uint256 currentBalance) internal {
        if (currentBalance < minRewardBalance) {
            return;
        }

        // Bring balances back in sync in case reward manager does not get notified of transfers
        uint256 amount = investorInfo[_address].amount;
        if(currentBalance > amount) {
            depositTo(currentBalance - amount, _address);
        } 

        if(currentBalance < amount) {
            withdrawFrom(amount - currentBalance, _address);
        }
    }

    // Can be used to manually activate the rewards, in case the threshold changes
    function activateRewards(address _address) external {
        require(!isExcluded(_address), "Address is excluded");
        uint256 balance = token.balanceOf(_address);
        require(balance >= minRewardBalance, "Insufficient balance");
        handleBalanceIncrease(_address, balance);
        emit ActivateRewards(_address);
    }

    function fee(address _address) public view override returns (uint256) {
        AddressRewardLog memory log = rewardLogBook[_address];
        if (log.excludedFromFee || address(feeProvider) == address(0)) {
            return 0;
        }
        return feeProvider.getClaimFee(log.lastClaimTime);
    }

    function caculateClaimFee(address _address, uint256 amount) internal view returns (uint256) {
        AddressRewardLog memory log = rewardLogBook[_address];
        if (log.excludedFromFee || address(feeProvider) == address(0)) {
            return 0;
        }
        return feeProvider.caculateClaimFee(log.lastClaimTime, amount);
    }

    // No need to implement these
    function deposit(uint256 amount) override virtual public onlyOwner {}
    function withdraw(uint256 amount) override virtual public onlyOwner {}
    function _deposit(uint256 amount, address sender) internal override   {}
    function _withdraw(uint256 amount, address receiver) internal override  {}

    receive() external payable {
        revert();
    }

}
pragma solidity 0.8.9;

import "../../interfaces/IYielder.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

abstract contract AbstractYielder is IYielder, Pausable, Ownable {

    struct InvestorInfo {
        uint256 amount;
        uint256 joinRound;
        uint256 claimed;
        uint256 leftToClaim;
        bool inBlackList;
    }

    struct RoundInfo {
        uint256 points;
        uint256 multiplier;
        uint256 depositSnapshot;
        uint256 globalMultiplierSnapshot;
    }

    uint256 public totalDeposited;
    
    uint256 public totalClaimed;
    uint256 public totalLeftToClaim;
    uint256 public currentRound = 1;
    uint256 public globalRewardMultiplier = 1000;
    uint256 public currentReward;
    uint256 public rewardPoints;

    mapping(uint256 => RoundInfo) public roundInfo;
    mapping(address => InvestorInfo) public investorInfo;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Claim(address indexed user, address receiver, uint256 amount);
    event SweepOutstanding(uint256 amount);
    // Calculates the total rewards
    function _totalReward() internal virtual view returns (uint256);
    
    // Called whenever a rewards reqests a claim
    function _claimReward(uint256 reward, address receiver) virtual internal;

    // Called when shareholder number increases from 0 to 1, it should remove all the rewards generated while there were
    // no shareholder active
    function _sweepOutstandingReward(uint256 reward) virtual internal;

    // Handles fund transfers on deposit
    function _deposit(uint256 amount, address _sender) virtual internal;
    
    // Handles fund transfer on witdraw
    function _withdraw(uint256 amount, address _receiver) virtual internal;

    // Returns the pending reward for a given investor
    function pendingReward(address _investor) override virtual public view returns (uint256) {
        return _pendingReward(_investor);
    }  

    function sweepOutstandingReward() public {
        if(totalDeposited == 0) {
            uint256 reward = _totalReward();

            if(reward > totalLeftToClaim){
                _sweepOutstandingReward(reward - totalLeftToClaim);
                emit SweepOutstanding(reward - totalLeftToClaim);
            }
       }
    }

    function excludeAddress(address _blacklistAddress) public virtual onlyOwner {
        InvestorInfo storage investor =  investorInfo[_blacklistAddress];
        require(!investor.inBlackList, "Investor already in blacklist");
       
        updateRoundInfo();
        
        uint256 rewardShare = calculateRewardShare(investor, rewardPoints);
        investor.leftToClaim += rewardShare;
        totalLeftToClaim += rewardShare;
        investor.inBlackList = true;
        investor.joinRound = currentRound;
        totalDeposited -= investor.amount; 
        investor.amount = 0;
        updateMultiplierAndPoints();
    }

    function includeAddress(address _blacklistAddress) public virtual onlyOwner {
        InvestorInfo storage investor =  investorInfo[_blacklistAddress];
        require(investor.inBlackList, "Investor not in blacklist");
        updateRoundInfo();
       
        investor.inBlackList = false;
        investor.joinRound = currentRound;
        totalDeposited += investor.amount;

        updateMultiplierAndPoints();
    }

    function isExcluded(address _address) public view returns(bool) {
       return investorInfo[_address].inBlackList;
    }

    function calculateRewardShare(InvestorInfo memory _userInfo, uint256 _rewardPoints) internal view returns (uint256) {
        if(_userInfo.inBlackList || totalDeposited == 0) {
            return 0;
        }
    
        uint256 rewardPointShare = calculateRewardPointShare(_userInfo, _rewardPoints);

        uint256 poolShare = (_userInfo.amount * 100000) / totalDeposited;
        uint256 rewardValue = (rewardPointShare * poolShare) / 100000;
        return rewardValue;
    }

    function calculateRewardPointShare(InvestorInfo memory _userInfo, uint256 _rewardPoints) internal view returns (uint256) {
        uint256 globalMultiplerOnJoin = getGlobalMultiplierSnapshot(_userInfo.joinRound);
        uint256 joinRoundMultiplier = getRoundMultiplier(_userInfo.joinRound);
     
        uint256 rewardDebt = getRewardDebt(_userInfo.joinRound);
        uint256 roundMultiplier = getRoundMultiplier(currentRound);

        if(currentRound > _userInfo.joinRound) {
            rewardDebt = (rewardDebt  * globalRewardMultiplier * roundMultiplier ) / (globalMultiplerOnJoin * joinRoundMultiplier);
        }

        return _rewardPoints - rewardDebt;
    }

    function getGlobalMultiplierSnapshot(uint256 round) internal view returns (uint256) {
        uint256 result = roundInfo[round].globalMultiplierSnapshot;
        if (result == 0) {
            return 1000;
        }
        return result;
    }

    function getRoundMultiplier(uint256 round) internal view returns (uint256) {
        uint256 result = roundInfo[round].multiplier;
        if (result == 0) {
            return 1000;
        }
        return result;
    }

    function setRoundMultiplier(uint256 round, uint256 value) internal {
        roundInfo[round].multiplier = value;
    }

    function getRoundPoints(uint256 round) internal view returns (uint256) {
        return roundInfo[round].points;
    }

    function getRewardDebt(uint256 round) internal view returns (uint256) {
        return (getRoundPoints(round) * getRoundMultiplier(round)) / 1000;
    }

    function getDepositAmountSnapshot(uint256 round) internal view returns (uint256) {
       return roundInfo[round].depositSnapshot;
    }

    function updateRoundInfo() internal {
        uint256 totalRewards = totalReward();
        if (currentReward < totalRewards) {
            uint256 roundMultipiler = getRoundMultiplier(currentRound);
            globalRewardMultiplier =  (globalRewardMultiplier * roundMultipiler) / 1000;
            
            currentRound++;
            roundInfo[currentRound].globalMultiplierSnapshot = globalRewardMultiplier;
            
            rewardPoints += totalRewards - currentReward;
            roundInfo[currentRound].points = rewardPoints;
            currentReward = totalRewards;
            roundInfo[currentRound].depositSnapshot = totalDeposited;
        }
    }

    function _pendingReward(address _investor) internal view returns (uint256) {
        InvestorInfo memory user = investorInfo[_investor];

        uint256 _rewardPoints = rewardPoints;
        uint256 totalRewards = totalReward();

        if (currentReward < totalRewards) {
            _rewardPoints += totalRewards - currentReward;
        }

        uint256 reward = calculateRewardShare(user, _rewardPoints);

        return reward + user.leftToClaim;
    }

    function claimRewardTo(uint256 amount, address receiver) override virtual public whenNotPaused {
        updateRoundInfo();
   
        uint256 reward = pendingReward(msg.sender);

        if(amount == 0) {
            amount = reward;
        }
        
        require(reward > 0, "Reward is 0");
        require(reward >= amount, "Inssuficient reward");

        _claimReward(reward, receiver);
        
        InvestorInfo storage user = investorInfo[msg.sender];
        totalLeftToClaim -= user.leftToClaim;
        user.leftToClaim = reward - amount;
        totalLeftToClaim += user.leftToClaim;

        user.joinRound = currentRound;
        
        user.claimed += amount;
        totalClaimed += amount;

        emit Claim(msg.sender, receiver, reward);
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    // Claims rewards for the calling investor
    function claimReward(uint256 amount) override virtual external whenNotPaused {
        claimRewardTo(amount, msg.sender);
    }

    function updateMultiplierAndPoints() private  {
        uint256 roundMultipiler = getRoundMultiplier(currentRound);
        uint256 depositSnap = getDepositAmountSnapshot(currentRound);
        if (depositSnap > 0) {
            setRoundMultiplier(currentRound, (totalDeposited * 1000) / depositSnap);
        } 

        roundMultipiler = getRoundMultiplier(currentRound);
        rewardPoints = (roundInfo[currentRound].points * roundMultipiler) / 1000;
    }

    // Yielder may accept funds from investors;
    function deposit(uint256 amount) override virtual external {
       require(depositTo(amount, msg.sender), "Deposit failed");
    }

    function withdraw(uint256 amount) override virtual public {
        require(withdrawFrom(amount, msg.sender), "Withdraw failed");
    }

    function depositTo(uint256 amount, address _address) internal returns(bool) { 
        if(isExcluded(_address)) {
            return false;
        }

        sweepOutstandingReward();
        _depositTo(amount, _address);
        return true;
    }

    function _depositTo(uint256 amount, address _address) internal {
        updateRoundInfo(); 
        
        InvestorInfo storage user = investorInfo[_address];
        uint256 rewardShare = calculateRewardShare(user, rewardPoints);
        user.leftToClaim += rewardShare;
        totalLeftToClaim += rewardShare;

        user.joinRound = currentRound;
        user.amount += amount;
        totalDeposited += amount;

        updateMultiplierAndPoints();
        _deposit(amount, _address);
        emit Deposit(_address, amount);
    }

    function withdrawFrom(uint256 amount, address _address) internal returns(bool) { 
        updateRoundInfo();

        InvestorInfo storage user = investorInfo[_address];
        if(amount == 0) {
            amount = user.amount; 
        }

        if(amount == 0 || amount > user.amount) {
            return false;
        }

        uint256 rewardShare = calculateRewardShare(user, rewardPoints);
        user.leftToClaim += rewardShare;
        totalLeftToClaim += rewardShare;
        
        user.joinRound = currentRound;
        user.amount -= amount;

        totalDeposited -= amount;
        updateMultiplierAndPoints();

        _withdraw(amount, _address); 
        emit Withdraw(_address, amount);
        return true;
    }

    function totalReward() public view returns (uint256) {
        uint256 currentTotalRewards = _totalReward();
        return currentTotalRewards + totalClaimed;
    }
}
pragma solidity 0.8.9;

contract RewardFeeProvider {
   function getClaimFee(uint256 lastClaimTime) public view returns(uint256) {
        return (block.timestamp - lastClaimTime) / 1 days;
   }

   function caculateClaimFee(uint256 lastClaimTime, uint256 amount) public view returns(uint256) {
       return (getClaimFee(lastClaimTime) * amount) / 100;
   }
}
pragma solidity 0.8.9;

/**
   Entity that generates financial return for it's investors
*/
interface IYielder {
  // Rreturns the pending reward for a given investor
  function pendingReward(address _investor) external view returns (uint256);

  // Claims rewards for the calling investor
  function claimRewardTo(uint256 amount, address receiver) external;

  // Claims rewards for the calling investor
  function claimReward(uint256 amount) external;

  // Yielder may accept funds from investors;
  function deposit(uint256 amount) external;

  // Withdraw funds
  function withdraw(uint256 amount) external;
}
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../RewardManager.sol";
import "../abstract/AbstractYielder.sol";

contract HedgeDeposit is AbstractYielder {
  
    RewardManager public rewardManager;
    // Claim fee %
    uint8 public claimFee = 5;  
    address public feeAddress;

    ERC20 public asset;

    constructor(
        address _rewardManagerAddress,
        address _hedgeCoinAddress,
        address _feeAddress
    ) {
        rewardManager = RewardManager(payable(_rewardManagerAddress));
        feeAddress = _feeAddress;
        asset =  ERC20(_hedgeCoinAddress);
    }
    
    function setFeeAddress(address _feeAddress) public onlyOwner {
        require(_feeAddress != address(0), "Address cannot be 0");
        feeAddress = _feeAddress;
    }

    function _totalReward() override internal view returns (uint256) {
        return rewardManager.unclaimedRewardValue(address(this));
    }

    function _sweepOutstandingReward(uint256 reward) internal override {
        if(reward > 0) {
            rewardManager.claimRewardTo(reward, feeAddress);
        }
    }

    function _claimReward(uint256 reward, address receiver) override internal {
        uint256 fee = (reward * claimFee) / 100;
        rewardManager.claimRewardTo(reward - fee, receiver);
        rewardManager.claimRewardTo(fee, feeAddress);
    }

    function _deposit(uint256 amount, address sender) override internal {
        asset.transferFrom(sender, address(this), amount);
    }

    function _withdraw(uint256 amount, address receiver) override internal {
        asset.transfer(receiver, amount);
    }
}
pragma solidity 0.8.9;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract HedgeCoinStaking is OwnableUpgradeable {
    uint8 public stakeTax ;
    uint8 public unStakeTax;
    address public feeAddress;

    uint256 public rewardRate;
    uint256 public lastUpdateBlock;
    uint256 public rewardPerTokenStored;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public _balances;

    ERC20PresetMinterPauser public rewardsToken;
    ERC20PresetMinterPauser public stakingToken;

    function init(address _stakingToken, address _rewardsToken) initializer public  {
        __Ownable_init();
        stakingToken = ERC20PresetMinterPauser(_stakingToken);
        rewardsToken = ERC20PresetMinterPauser(_rewardsToken);
        feeAddress = msg.sender;
        stakeTax = 2;
        unStakeTax = 2;
        rewardRate = 100;
    }

    function rewardPerToken() public view returns (uint256) {
        uint256 _totalSupply = stakingToken.balanceOf(address(this));

        if (_totalSupply == 0) {
            return 0;
        }
        return rewardPerTokenStored + (((block.number - lastUpdateBlock) * rewardRate * 1e18) / _totalSupply);
    }

    function earned(address account) public view returns (uint256) {
        if(_balances[account] == 0) {
            return  rewards[account];
        }
        return ((_balances[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18) + rewards[account];
    }

    function stakedAmount(address account) external view returns (uint256) {
        return _balances[account];
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateBlock = block.number;

        rewards[account] = earned(account);
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
        _;
    }

    function stake(uint256 _amount) external updateReward(msg.sender) {
        uint256 fee = 0;
        if(stakeTax > 0){
            fee = (_amount * stakeTax) / 100;
            stakingToken.transferFrom(msg.sender, feeAddress, fee);
        }
        _balances[msg.sender] += _amount - fee;
        stakingToken.transferFrom(msg.sender, address(this), _amount - fee);
    }

    function totalSupply() external view returns (uint256) {
        return stakingToken.balanceOf(address(this));
    }

    function withdraw(uint256 _amount) external updateReward(msg.sender) {
        require(_balances[msg.sender] >= _amount, "Insuficient balance");
        _balances[msg.sender] -= _amount;
        uint256 fee = 0;
        if(unStakeTax > 0){
            fee = (_amount * stakeTax) / 100;
            stakingToken.transfer(feeAddress, fee);
        }

        stakingToken.transfer(msg.sender, _amount - fee);
    }

    function getReward() external updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        rewards[msg.sender] = 0;
        rewardsToken.mint(msg.sender, reward);
    }

    function setRewardRate(uint256 rate) external onlyOwner {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateBlock = block.number;
        rewardRate = rate;
    }

    function setFeeAddress(address newAddress) external onlyOwner {
        require(address(feeAddress) != newAddress, "New address is the same as old address");
        require(newAddress != address(0), "New address cannot be 0x00");
        feeAddress = newAddress;
    }

    function setStakeTax(uint8 tax) external onlyOwner {
        require(tax <= 100, "Tax cannot be greater than 100%");
        stakeTax = tax;
    }

    function setUnStakeTax(uint8 tax) external onlyOwner {
        require(tax <= 100, "Tax cannot be greater than 100%");
        unStakeTax = tax;
    }

    function destroy() external onlyOwner {
        require(stakingToken.balanceOf(address(this)) == 0, "Tokens still in pool");
        selfdestruct(payable(msg.sender));
    }
}
pragma solidity ^0.8.0;

/**
 * @dev This is a base contract to aid in writing upgradeable contracts, or any kind of contract that will be deployed
 * behind a proxy. Since a proxied contract can't have a constructor, it's common to move constructor logic to an
 * external initializer function, usually called `initialize`. It then becomes necessary to protect this initializer
 * function so it can only be called once. The {initializer} modifier provided by this contract will have this effect.
 *
 * TIP: To avoid leaving the proxy in an uninitialized state, the initializer function should be called as early as
 * possible by providing the encoded function call as the `_data` argument to {ERC1967Proxy-constructor}.
 *
 * CAUTION: When used with inheritance, manual care must be taken to not invoke a parent initializer twice, or to ensure
 * that all initializers are idempotent. This is not verified automatically as constructors are by Solidity.
 */
abstract contract Initializable {
    /**
     * @dev Indicates that the contract has been initialized.
     */
    bool private _initialized;

    /**
     * @dev Indicates that the contract is in the process of being initialized.
     */
    bool private _initializing;

    /**
     * @dev Modifier to protect an initializer function from being invoked twice.
     */
    modifier initializer() {
        require(_initializing || !_initialized, "Initializable: contract is already initialized");

        bool isTopLevelCall = !_initializing;
        if (isTopLevelCall) {
            _initializing = true;
            _initialized = true;
        }

        _;

        if (isTopLevelCall) {
            _initializing = false;
        }
    }
}
pragma solidity ^0.8.0;

import "../utils/ContextUpgradeable.sol";
import "../proxy/utils/Initializable.sol";

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
abstract contract OwnableUpgradeable is Initializable, ContextUpgradeable {
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
        _setOwner(_msgSender());
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
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
        _setOwner(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        _setOwner(newOwner);
    }

    function _setOwner(address newOwner) private {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
    uint256[49] private __gap;
}
pragma solidity ^0.8.0;
import "../proxy/utils/Initializable.sol";

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
abstract contract ContextUpgradeable is Initializable {
    function __Context_init() internal initializer {
        __Context_init_unchained();
    }

    function __Context_init_unchained() internal initializer {
    }
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
    uint256[50] private __gap;
}
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";

import "../interfaces/IFundManager.sol";
import "./lib/SwapUtils.sol";
import "./lib/PresaleUtils.sol";
import "./LiquidityTimeLock.sol";

contract InitialOTC is AccessControl {
    event TokensPurchased(
        address purchaser,
        address beneficiary,
        uint256 value,
        uint256 amount
    );

    event TokensSold(
        address seller,
        address beneficiary,
        uint256 value,
        uint256 amount
    );

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    uint64 public constant LAUNCH_PRICE = 60 * 1e14;

    uint256 public swapSlippage = 50; // 0.5%
    uint256 public currentPhase;
    uint256 public rawCapitalRaised;

    address public liquidityLock;
    // Reference to the BUSD contract
    ERC20 public busd;
    ERC20PresetMinterPauser public token;

    // We use the router to swap our tokens as needed
    IUniswapV2Router02 public router;
    IFund public fund;

    PresaleUtils.PresalePhase[4] public phases;
    mapping(address => uint256) public balance;

    constructor( address _token) {
        require(_token != address(0), "ICO: token is the zero address");
        token = ERC20PresetMinterPauser(_token);

        busd = ERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
        router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(MANAGER_ROLE, msg.sender);
        // TODO: Change this to expected values
       configurePhase(0, 
            48 * 1e14, // 0.0048 $
            4568 * 1e12, // 0.00456 $
            500 * 1e18, // 50$
            3000 * 1e18, // 3000$
            300_000 * 1e18 // 300,000$
        );

        configurePhase(1, 
            51 * 1e14, // 0.0051 $
            4568 * 1e12, // 0.00456 $
            50 * 1e18, // 50$
            6000 * 1e18, // 3000$
            618_750 * 1e18 // 318,750$
        );

        configurePhase(2, 
            54 * 1e14, 
            4568 * 1e12, 
            50 * 1e18, 
            8000 * 1e18, 
            956_250 * 1e18 
        );
        
        configurePhase(3, 
            57 * 1e14, 
            4568 * 1e12,
            50 * 1e18,
            10000 * 1e18, 
            1_312_500 * 1e18 
        );
    }

    function configurePhase(
        uint256 _pid,
        uint256 _rate,
        uint256 _sellRate,
        uint256 _minPurchase,
        uint256 _maxPurchase,
        uint256 _hardCap
    ) public onlyRole(MANAGER_ROLE){
        PresaleUtils.PresalePhase storage phase = phases[_pid];
        phase.rate = _rate;
        phase.sellRate = _sellRate;
        phase.minPurchase = _minPurchase;
        phase.maxPurchase = _maxPurchase;
        phase.hardCap = _hardCap;
    }

    function endCurrentPhase() external onlyRole(MANAGER_ROLE) {
        require(phases[currentPhase].status == 1, "Invalid status");
        phases[currentPhase].status = 2;

        if(currentPhase < phases.length - 1) {
            currentPhase++;
        }
    }

    function startNextPhase() external onlyRole(MANAGER_ROLE) {
        require(currentPhase < phases.length, "Invalid phase");
        if(currentPhase > 0) {
            require(phases[currentPhase - 1].status == 2, "Invalid status");
        }
        phases[currentPhase].status = 1;
    }

    receive() external payable {
        buyWithChainCoin(_msgSender());
    }

    function buy(uint256 amount) external {
        address beneficiary = msg.sender;
        uint256 tokens = _getTokenAmount(amount);
        _preValidatePurchase(beneficiary, amount, tokens);
        busd.transferFrom(address(msg.sender), address(this), amount);
        _processPurchase(beneficiary, amount, tokens);
        emit TokensPurchased(_msgSender(), beneficiary, amount, tokens);
    }

    function buyWithChainCoin(address beneficiary) public payable {
        uint256 weiAmount = msg.value;

        // Buy busd with 0.5% slippage
        uint256 amount = SwapUtils.swapExactETHForTokens(router, busd, weiAmount, swapSlippage); // no checks required for this? 
        
        uint256 tokens = _getTokenAmount(amount);
        _preValidatePurchase(beneficiary, amount, tokens);
        _processPurchase(beneficiary, amount, tokens);
        emit TokensPurchased(_msgSender(), beneficiary, amount, tokens);
    }

    function sellTokens(uint256 amount) external {
        address beneficiary = address(msg.sender);
        require(beneficiary != address(0),"Sale: beneficiary is the zero address");
        require(amount > 0, "Sale: tokenAmount is 0");
        require(balance[msg.sender] >= amount, "Balance to low");

        _drainTokens(_msgSender(), amount);
        balance[msg.sender] -= amount;

        uint256 netAmount = _getRefundAmount(amount);
        rawCapitalRaised -= netAmount; 
        if(phases[currentPhase]._capital >= netAmount){
            phases[currentPhase]._capital -= netAmount; 
        }
        _processSell(beneficiary, netAmount);
        emit TokensSold(_msgSender(), beneficiary, netAmount, amount);
    }

    function _preValidatePurchase(address beneficiary, uint256 amount, uint256 tokens) internal view {
        PresaleUtils.PresalePhase memory phase= phases[currentPhase]; 
        PresaleUtils.preValidatePurchase(phase, beneficiary, amount);
        require(rawCapitalRaised + amount <= phase.hardCap, "Buy: Hardcap reached");
        require(balance[beneficiary] + tokens >= _getTokenAmount(phase.minPurchase), "Must buy min mount");
        require(balance[beneficiary] + tokens <= _getTokenAmount(phase.maxPurchase), "Address cap reached");
        require(address(fund) != address(0), "Fund not set");
    }

    function _deliverTokens(address beneficiary, uint256 tokenAmount) internal {
        token.transfer(beneficiary, tokenAmount);
    }

    function _drainTokens(address seller, uint256 tokenAmount) internal {
        token.transferFrom(seller, address(this), tokenAmount);
    }

    function _processPurchase(address beneficiary, uint256 usdAmount, uint256 tokenAmount) internal {
        balance[msg.sender] += tokenAmount;
        phases[currentPhase]._capital += usdAmount;
        rawCapitalRaised += usdAmount;
        uint256 fee = usdAmount - _getRefundAmount(tokenAmount); 
        busd.increaseAllowance(address(fund), fee);
        fund.investBUSD(fee);
        _deliverTokens(beneficiary, tokenAmount);
    }

    function _processSell(address beneficiary, uint256 weiAmount) internal {
        busd.transfer(beneficiary, weiAmount);
    }

    function _getTokenAmount(uint256 amount) internal view returns (uint256) {
        return (amount / rate()) * 10 ** token.decimals();
    }

    function _getRefundAmount(uint256 tokenAmount) internal view returns (uint256) {
        return (tokenAmount * sellRate()) / 10 ** token.decimals();
    }

    function setFund(address _address) external onlyRole(MANAGER_ROLE) {
        require(_address != address(0), "Fund address cannot be 0x00");
        fund = IFund(_address);
    }

    function capital() public view returns (uint256) {
        return busd.balanceOf(address(this));
    }

    function saleSupply() public view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function rate() public view returns(uint256) {
        return phases[currentPhase].rate;
    }

    function sellRate() public view returns(uint256) {
        return phases[currentPhase].sellRate;
    }

    function setSwapSlippage(uint256 slipapge) external onlyRole(MANAGER_ROLE) {
        require(slipapge <= 10_000, "Slippage cannot be > 100%"); 
        swapSlippage = slipapge;
    }

     function endPresaleAndLock(address lockOwner) external onlyRole(MANAGER_ROLE)  {
        require(currentPhase == phases.length - 1, "Cannot end");
        uint256 busdBalance = busd.balanceOf(address(this));
        uint256 liquidity = (busdBalance * 95) / 100;
        uint256 tokenLiquidityAmount = liquidity / LAUNCH_PRICE;

        token.mint(address(this), tokenLiquidityAmount);
        token.increaseAllowance(address(router), tokenLiquidityAmount);
        busd.increaseAllowance(address(router), liquidity);


        liquidityLock = PresaleUtils.lockLiquidity(
                router,
                token,
                busd,
                tokenLiquidityAmount,
                liquidity,
                lockOwner
        );
        busd.transfer(lockOwner, busd.balanceOf(address(this)));
        token.burn(token.balanceOf(address(this)));
    }


    /// Can only be destroyed by multisign
    function destroy() external onlyRole(DEFAULT_ADMIN_ROLE) {
        busd.transfer(msg.sender, busd.balanceOf(address(this)));
        token.transfer(msg.sender, token.balanceOf(address(this))); 
        selfdestruct(payable(msg.sender));
    }
}
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IFeeManager.sol";
import "./lib/SwapUtils.sol";
import "../interfaces/IFundManager.sol";


contract FeeManager is IFeeManager, Ownable {
    //  Should we swap the fee
    bool public swapFees = false;

    //Dev wallet cut from fees in %
    uint8 public DEV_ALLOCATION = 14;

    // Marketing wallet cut from fees in %
    uint8 public MARKETING_ALLOCATION = 20;

    // Fund Manager cut from fees in %
    uint8 public INVESTMENT_ALLOCATION = 66;

    // The router used to swap the fee into BNB or stable coin
    IUniswapV2Router02 public router;

    // The dev wallet
    address public devAddress;

    // Marketing wallet
    address public marketingAddress;

    // The Fund Manager Contract instance
    IFund public investmentAddress;

    ERC20 public token;
    ERC20 public busd = ERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);

    modifier addressesAreSet() {
        require(devAddress != address(0), "Dev address cannot be 0");
        require(marketingAddress != address(0), "Marketing address cannot be 0");
        require(address(investmentAddress) != address(0),"Investment address cannot be 0");
        _; 
    }

    constructor(ERC20 _token, IUniswapV2Router02 _router) {
        token = _token;
        router = _router;
    }

    function processFee() external override  {
        uint256 balance = token.balanceOf(address(this));
        require(balance > 0, "Token balance cannot be 0 when processing");

        if(swapFees){
            // Swap the tokens to BUSD use a 1% slippage
            try SwapUtils.swapTokensForTokens(router, token, busd, balance, 100) {
                distributeBusdFees();
            } catch { 
                distributeFees();
            }
        } else {
            distributeFees();
        }
    }

    function processBusdFee(uint256 amount) external override {
        busd.transferFrom(address(msg.sender), address(this), amount);
        distributeBusdFees();
    }

    function distributeBusdFees() override public addressesAreSet() {
        uint256 amount = busd.balanceOf(address(this));

        require(amount > 0, "Not enough balance");
      
        // Calculate amounts to be received by each of the wallets
        (uint256 devTokens ,uint256 marketingTokens ,uint256 investmentTokens ) = calculateFeeDistribution(amount);
        

        busd.transfer(devAddress, devTokens);
        busd.transfer(marketingAddress, marketingTokens);

        busd.increaseAllowance(address(investmentAddress), investmentTokens);
        investmentAddress.investBUSD(investmentTokens);
    }

    function distributeETHFees() override public addressesAreSet() {
        uint256 ethBalance = address(this).balance;

        require(ethBalance > 0, "Not enough balance");
        // Calculate amounts to be received by each of the wallets
        (uint256 devTokens ,uint256 marketingTokens ,uint256 investmentTokens ) = calculateFeeDistribution(ethBalance);
        
        // Transfer the tokens
        payable(devAddress).transfer(devTokens);
        payable(marketingAddress).transfer(marketingTokens);
        investmentAddress.invest{value: investmentTokens}();
    }

    function distributeFees() public addressesAreSet() { 
        uint256 balance = token.balanceOf(address(this));

        require(balance > 0, "Not enough balance");
        token.transfer(marketingAddress, balance / 2);
        token.transfer(devAddress, token.balanceOf(address(this)));
    }

    function calculateFeeDistribution(uint256 amount) internal view returns(uint256, uint256, uint256) {
        uint256 devTokens = (amount * DEV_ALLOCATION) / 100;
        uint256 marketingTokens = (amount * MARKETING_ALLOCATION) / 100;
        uint256 investmentTokens = (amount * INVESTMENT_ALLOCATION) / 100;
        return (devTokens, marketingTokens, investmentTokens);
    }

    function setDevAddress(address newAddress) external onlyOwner { 
        require(address(0) != newAddress, "New address cannot be 0");
        require(devAddress != newAddress, "New address is the same as old address");
        devAddress = newAddress;
    }

    function setMarketingAddress(address newAddress) external onlyOwner { 
        require(address(0) != newAddress, "New address cannot be 0");
        require(marketingAddress != newAddress, "New address is the same as old address");
        marketingAddress = newAddress;
    }

    function setInvestmentAddress(address newAddress) external onlyOwner {
        require(address(0) != newAddress, "New address cannot be 0");
        require(address(investmentAddress) != newAddress, "New address is the same as old address");
        investmentAddress = IFund(newAddress);
    }

    function setTokenAddress(address newAddress) external onlyOwner {
        require(address(0) != newAddress, "New address cannot be 0");
        require(address(token) != newAddress,"New address is the same as old address");
        token = ERC20(newAddress);
    }

    function setAllocation(uint8 dev, uint8 marketing, uint8 investment) external onlyOwner {
        require( dev + marketing + investment == 100, "Ivalid distribution");
        DEV_ALLOCATION = dev;
        MARKETING_ALLOCATION = marketing;
        INVESTMENT_ALLOCATION = investment;
    }

    function setFeeSwapStatus(bool status) external onlyOwner {
        require(status != swapFees, "Status already set");
        swapFees = status;
    }

    function setRouterAddress(address newAddress) public onlyOwner {
        require(address(0) != newAddress, "New address cannot be 0");
        require(address(router) != newAddress, "New address is the same as old address");
        router = IUniswapV2Router02(newAddress);
    }

    function destroy() external onlyOwner {
        // Distribute any remaning tokens  
        uint256 tokenBalance = token.balanceOf(address(this));

        require(tokenBalance == 0 , "Contract still has tokens");
        require(busd.balanceOf(address(this)) == 0 , "Contract still has busd");

        // Call self destruct and send remaing ETH to owner
        selfdestruct(payable(owner()));
    }

    receive() external payable {} 
}
pragma solidity 0.8.9;
import "./IInvestmentStrategy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
   Stash rewards until they are ready to be claimed
*/
interface IVault {
  event TransferERC20(address asserAddress, uint256 amount);
  event TransferETH(uint256 amount);
  event AddCapital(IInvestmentStrategy strategyAddress, address assetAddress, uint256 amount);
  event AddETHCapital(IInvestmentStrategy strategyAddress, uint256 amount);
  event InvestBUSD(address fundAddress, uint256 amount);
  event InvestETH(address fundAddress, uint256 amount);
  
  // Add amount to stash
  function transferERC20Asset(IERC20 asset, uint256 amount, address destination) external ;

  // Remove amount from stash
  function transferETH(uint256 amount, address destination) external;

  // Inject capital into a strategy
  function addAssetCapitalToStrategy(IInvestmentStrategy strategy, address assetAddress, uint256 amount) external;
  function addBusdCapitalToStrategy(IInvestmentStrategy strategy, uint256 amount) external;
  function addCapitalToStrategy(IInvestmentStrategy strategy, uint256 amount) external;
}
pragma solidity 0.8.9;

import "../interfaces/IMasterChef.sol";
import "../interfaces/IBiswapPair.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IFundManager.sol";
import "../interfaces/IInvestmentStrategy.sol";

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


/**
    Capital vault used to safely store our investment capital
 */
contract CapitalVault is IVault, Ownable, AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    
    ERC20 public busd = ERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
    
    IFund public fund;
    modifier mustHaveFundSet() {
        require(address(fund) != address(0), "No Fund contract was set");
        _;
    }

    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(MANAGER_ROLE, msg.sender);
    }

    function investCapitalIntoFund(uint256 amount) external mustHaveFundSet onlyRole(MANAGER_ROLE) {
        require(address(this).balance >= amount, "Insufficient balance");
        fund.invest{value: amount}();
    }

    function investBusdCapitalIntoFund(uint256 amount) external mustHaveFundSet onlyRole(MANAGER_ROLE) {
        require(busd.balanceOf(address(this)) >= amount, "Insufficient balance" );
        
        busd.increaseAllowance(address(fund), amount);
        fund.investBUSD(amount);
    }

    // Transfer ERC20 Asset out of the vault
    function transferERC20Asset(IERC20 asset, uint256 amount, address destination) external override onlyOwner {
        require(asset.balanceOf(address(this)) >= amount, "Insufficient balance");
        require(address(0) !=  destination, "Cannot send to 0 address");

        asset.safeTransfer(destination, amount);
        emit TransferERC20(destination, amount);
    }

    // Transfer ETH Asset out of the vault
    function transferETH(uint256 amount, address destination) external override onlyOwner {
        require(address(this).balance >= amount, "Insufficient balance"); 
        payable(destination).transfer(amount);
    }

    // Inject Asset capital into a strategy
    function addAssetCapitalToStrategy(IInvestmentStrategy strategy, address assetAddress, uint256 amount) external override onlyRole(MANAGER_ROLE) {
        // Check to see if the strategy is registerd with the current fund 
        checkStrategy(address(strategy));
       
        ERC20 asset = ERC20(assetAddress);
        require(asset.balanceOf(address(this)) >= amount, "Insufficient balance");

        asset.increaseAllowance(address(strategy), amount);
        strategy.addAssetCapital(amount);
    }

    // Inject BUSD capital into a strategy
    function addBusdCapitalToStrategy(IInvestmentStrategy strategy, uint256 amount) external override onlyRole(MANAGER_ROLE) {
        // Check to see if the strategy is registerd with the current fund 
        checkStrategy(address(strategy));
       
        require(busd.balanceOf(address(this)) >= amount, "Insufficient balance");

        busd.increaseAllowance(address(strategy), amount);
        strategy.addBusdCapital(amount);
    }

    // Inject ETH capital into a strategy
    function addCapitalToStrategy(IInvestmentStrategy strategy, uint256 amount) external override onlyRole(MANAGER_ROLE) {
        checkStrategy(address(strategy));
       
        require(address(this).balance >= amount, "Insufficient balance");
        strategy.addCapital{value: amount}();
    }

    function lockedBusd() external view returns(uint256) {
        return busd.balanceOf(address(this));
    }

    function checkStrategy(address strategyAddress) internal view mustHaveFundSet {
        (,bool exists, ) = fund.getStrategyByAddress(strategyAddress);
        require(exists, "Strategy not registerd with current fund");
    }

    function setFundAddress(address newAddress) public onlyOwner {
        require(address(fund) != newAddress, "New address is the same as old address");
        require(address(0) != newAddress, "Fund address cannot be address(0)");
        fund = IFund(newAddress);
    }

    function destroy(address receiver) external onlyOwner {
        selfdestruct(payable(receiver)); 
    }
    
    receive() external payable {}
}
pragma solidity 0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "../../interfaces/IFundManager.sol";
import "../lib/SwapUtils.sol";
import "../../interfaces/IFeeManager.sol";

contract Exchange is Ownable {
    event TokensPurchased(
        address purchaser,
        address beneficiary,
        uint256 value,
        uint256 amount
    );

    event TokensSold(
        address seller,
        address beneficiary,
        uint256 value,
        uint256 amount
    );

    bool public feeDistributionEnabled;
    uint256 public buyFee = 80;
    uint256 public sellFee = 120;

    // Reference to the BUSD contract
    ERC20 public busd;
    ERC20 public token;

    // We use the router to swap our tokens as needed
    IUniswapV2Router02 public router;

    // Fee manager address
    IFeeManager public feeManager;

    constructor(address _token, address _feeManager) {
        require(_token != address(0), "EX: token is the zero address");
        require(_feeManager != address(0), "EX: feeManager is the zero address");

        token = ERC20(_token);
        feeManager = IFeeManager(_feeManager);
        feeDistributionEnabled = true;
        busd = ERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
        router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    }

    function buy(uint256 amount, uint256 minTokens) external {
        address beneficiary = msg.sender;
        _preValidateTransaction(beneficiary, amount);
        busd.transferFrom(address(msg.sender), address(this), amount);

        uint256 fee = (amount * buyFee) / 1000;
        uint256 exchangeAmount = amount - fee;
        uint256 result = swapExactERC20(busd, token, exchangeAmount, minTokens);
        token.transfer(beneficiary, result);
        busd.transfer(address(feeManager), busd.balanceOf(address(this)));
        if(feeDistributionEnabled) {
            feeManager.distributeBusdFees();
        }
        emit TokensPurchased(_msgSender(), beneficiary, amount, minTokens);
    }

    function buyWithChainCoin(uint256 minTokens) external payable {
        uint256 weiAmount = msg.value;
        _preValidateTransaction(msg.sender, weiAmount);
        uint256 fee = (weiAmount * buyFee) / 1000;
        uint256 exchangeAmount = weiAmount - fee;
      
        uint256 result = swapExactETHForTokens(token, exchangeAmount, minTokens);
        token.transfer(msg.sender, result);
        payable(address(feeManager)).transfer(address(this).balance);
        if(feeDistributionEnabled) {
            feeManager.distributeETHFees();
        }
        emit TokensPurchased(_msgSender(), msg.sender, weiAmount, minTokens);
    }

    function sellTokens(uint256 amount, uint256 minAmount) external {
        address beneficiary = address(msg.sender);
        _preValidateTransaction(beneficiary, amount);
        _drainTokens(msg.sender, amount);

        uint256 output = swapExactERC20(token, busd, amount, minAmount);
        uint256 fee = (output * sellFee) / 1000;

        busd.transfer(beneficiary, output - fee);
        busd.transfer(address(feeManager), busd.balanceOf(address(this)));

        emit TokensSold(_msgSender(), beneficiary, output - fee, amount);
    }

    function sellTokensForChainCoin(uint256 amount, uint256 minEth) external {
        address beneficiary = address(msg.sender);
        _preValidateTransaction(beneficiary, amount);
        _drainTokens(msg.sender, amount);

        uint256 output = swapExactTokensForETH(token, amount, minEth);
        uint256 fee = (output * sellFee) / 1000;

        payable(address(beneficiary)).transfer(output - fee);
        payable(address(feeManager)).transfer(address(this).balance);
        emit TokensSold(_msgSender(), beneficiary, output - fee, amount);
    }

    function ethRate() public view returns (uint256 buyRate, uint256 sellRate) {
        address[] memory path = new address[](3);
        path[0] = router.WETH();
        path[1] = address(busd);
        path[2] = address(token);

        buyRate = router.getAmountsOut(10**token.decimals(), path)[2];

        path[0] = address(token);
        path[1] = address(busd);
        path[2] = router.WETH();

        sellRate = router.getAmountsOut(10**token.decimals(), path)[2];
    }

    function busdRate() public view returns (uint256 buyRate, uint256 sellRate) {
        address[] memory path = new address[](2);

        path[0] = address(busd);
        path[1] = address(token);

        buyRate = router.getAmountsOut(10**token.decimals(), path)[1];
        
        path[0] = address(token);
        path[1] = address(busd);

        sellRate = router.getAmountsOut(10**token.decimals(), path)[1];
    }

    function _preValidateTransaction(address beneficiary, uint256 amount) internal pure {
        require(beneficiary != address(0), "Beneficiary is the zero address"); 
        require(amount > 0, "Amount is 0");
    }

    function _drainTokens(address seller, uint256 tokenAmount) internal {
        token.transferFrom(seller, address(this), tokenAmount);
    }

    function swapExactTokensForETH( ERC20 _token, uint256 amount, uint256 minAmount) internal returns (uint256) {
        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](3);
        path[0] = address(_token);
        path[1] = address(busd);
        path[2] = router.WETH();

        _token.increaseAllowance(address(router), amount);
        uint256[] memory amounts = router.swapExactTokensForETH(amount, minAmount, path, address(this), block.timestamp);

        return amounts[2];
    }

    function swapExactETHForTokens( ERC20 _token, uint256 ethAmount, uint256 minAmount) internal returns (uint256) {
        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](3);
        path[0] = router.WETH();
        path[1] = address(busd);
        path[2] = address(_token);

        uint256[] memory amounts = router.swapExactETHForTokens{
            value: ethAmount
        }(minAmount, path, address(this), block.timestamp);

        return amounts[2];
    }

    function swapExactERC20( ERC20 from, ERC20 to, uint256 amount, uint256 minAmount) internal returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = address(from);
        path[1] = address(to);

        from.increaseAllowance(address(router), amount);
        // make the swap
        uint256 resultAmount = router.swapExactTokensForTokens(
            amount,
            minAmount,
            path,
            address(this),
            block.timestamp
        )[1];

        return resultAmount;
    }

    function setFeeManager(address newAddress) external onlyOwner {
        require(address(0) != newAddress, "Fee Manager cannot be 0");
        require(address(feeManager) != newAddress, "Fee Manager same old"); 
        feeManager = IFeeManager(newAddress);
    }

    function setFeeDistributionEnabled(bool status) external onlyOwner {
        require(status != feeDistributionEnabled, "Fee Manager same old");
        feeDistributionEnabled = status;
    }

    function destroy() external onlyOwner {
        selfdestruct(payable(owner()));
    }

    function setFee(uint256 _buyFee, uint256 _sellFee) external onlyOwner { 
        require(_buyFee <= 1000 && _sellFee <= 1000, "Out of bounds");
        buyFee = _buyFee;
        sellFee = _sellFee;
    }
    
    receive() external payable { }
}
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract DevFundsSplitter is Ownable {
    using SafeERC20 for IERC20;
    address[4] addresses;

    constructor(
        address _addr1,
        address _addr2,
        address _addr3,
        address _addr4

    ) {
        addresses[0] = _addr1;
        addresses[1] = _addr2;
        addresses[2] = _addr3;
        addresses[3] = _addr4;
    }

    function distribute(IERC20 token) external {
        uint256 amount = token.balanceOf(address(this));
        if (
            amount == 0 ||
            addresses[0] == address(0) ||
            addresses[1] == address(0) ||
            addresses[2] == address(0) ||
            addresses[3] == address(0)

        ) {
            return;
        }

        token.safeTransfer(addresses[0], (amount * 30) / 100);
        token.safeTransfer(addresses[1], (amount * 30) / 100);
        token.safeTransfer(addresses[2], (amount * 30) / 100);
        token.safeTransfer(addresses[3], token.balanceOf(address(this)));
    }

    function setAddress(uint256 index, address newAddress) external onlyOwner { 
        require(address(0) != newAddress, "Address cannot be 0");
        addresses[index] = newAddress;
    }

    function getAddress(uint256 index) external view onlyOwner returns(address)  {
        return addresses[index];
    }

    function saveTokens(IERC20 token, address destination) external onlyOwner {
        token.safeTransfer(destination, token.balanceOf(address(this)));
    }
}
