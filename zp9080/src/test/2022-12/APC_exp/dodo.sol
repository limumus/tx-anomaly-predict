pragma solidity 0.8.16;

import {D3Trading} from "./D3Trading.sol";
import {IFeeRateModel} from "../../intf/IFeeRateModel.sol";
import {ID3Maker} from "../intf/ID3Maker.sol";

contract D3MM is D3Trading {
    /// @notice init D3MM pool
    function init(
        address creator,
        address maker,
        address vault,
        address oracle,
        address feeRateModel,
        address maintainer
    ) external {
        initOwner(creator);
        state._CREATOR_ = creator;
        state._D3_VAULT_ = vault;
        state._ORACLE_ = oracle;
        state._MAKER_ = maker;
        state._FEE_RATE_MODEL_ = feeRateModel;
        state._MAINTAINER_ = maintainer;
    }

    // ============= Set ====================
    function setNewMaker(address newMaker) external onlyOwner {
        state._MAKER_ = newMaker;
        allFlag = 0;
    }

    // ============= View =================
    function _CREATOR_() external view returns(address) {
        return state._CREATOR_;
    }

    function getFeeRate(address token) external view returns(uint256 feeRate) {
        return IFeeRateModel(state._FEE_RATE_MODEL_).getFeeRate(token);
    }

    function getPoolTokenlist() external view returns(address[] memory) {
        return ID3Maker(state._MAKER_).getPoolTokenListFromMaker();
    }

    function getDepositedTokenList() external view returns (address[] memory) {
        return state.depositedTokenList;
    }

    /// @notice get basic pool info
    function getD3MMInfo() external view returns (address vault, address oracle, address maker, address feeRateModel, address maintainer) {
        vault = state._D3_VAULT_;
        oracle = state._ORACLE_;
        maker = state._MAKER_;
        feeRateModel = state._FEE_RATE_MODEL_;
        maintainer = state._MAINTAINER_;
    }

    /// @notice get a token's reserve in pool
    function getTokenReserve(address token) external view returns (uint256) {
        return state.balances[token];
    }

    /// @notice get D3MM contract version
    function version() external pure virtual returns (string memory) {
        return "D3MM 1.0.0";
    }
}
pragma solidity ^0.8.0;

interface AggregatorV3Interface {
  function decimals() external view returns (uint8);

  function description() external view returns (string memory);

  function version() external view returns (uint256);

  function getRoundData(uint80 _roundId)
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );

  function latestRoundData()
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );
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

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuard {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and making it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        // On the first call to nonReentrant, _status will be _NOT_ENTERED
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");

        // Any calls to nonReentrant after this point will fail
        _status = _ENTERED;
    }

    function _nonReentrantAfter() private {
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = _NOT_ENTERED;
    }

    /**
     * @dev Returns true if the reentrancy guard is currently set to "entered", which indicates there is a
     * `nonReentrant` function in the call stack.
     */
    function _reentrancyGuardEntered() internal view returns (bool) {
        return _status == _ENTERED;
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
 * @dev Interface of the ERC20 Permit extension allowing approvals to be made via signatures, as defined in
 * https://eips.ethereum.org/EIPS/eip-2612[EIP-2612].
 *
 * Adds the {permit} method, which can be used to change an account's ERC20 allowance (see {IERC20-allowance}) by
 * presenting a message signed by the account. By not relying on {IERC20-approve}, the token holder account doesn't
 * need to send a transaction, and thus is not required to hold Ether at all.
 */
interface IERC20Permit {
    /**
     * @dev Sets `value` as the allowance of `spender` over ``owner``'s tokens,
     * given ``owner``'s signed approval.
     *
     * IMPORTANT: The same issues {IERC20-approve} has related to transaction
     * ordering also apply here.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `deadline` must be a timestamp in the future.
     * - `v`, `r` and `s` must be a valid `secp256k1` signature from `owner`
     * over the EIP712-formatted function arguments.
     * - the signature must use ``owner``'s current nonce (see {nonces}).
     *
     * For more information on the signature format, see the
     * https://eips.ethereum.org/EIPS/eip-2612#specification[relevant EIP
     * section].
     */
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /**
     * @dev Returns the current nonce for `owner`. This value must be
     * included whenever a signature is generated for {permit}.
     *
     * Every successful call to {permit} increases ``owner``'s nonce by one. This
     * prevents a signature from being used multiple times.
     */
    function nonces(address owner) external view returns (uint256);

    /**
     * @dev Returns the domain separator used in the encoding of the signature for {permit}, as defined by {EIP712}.
     */
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32);
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
pragma solidity ^0.8.0;

import "../IERC20.sol";
import "../extensions/IERC20Permit.sol";
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

    /**
     * @dev Transfer `value` amount of `token` from the calling contract to `to`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     */
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    /**
     * @dev Transfer `value` amount of `token` from `from` to `to`, spending the approval given by `from` to the
     * calling contract. If `token` returns no value, non-reverting calls are assumed to be successful.
     */
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }

    /**
     * @dev Deprecated. This function has issues similar to the ones found in
     * {IERC20-approve}, and its usage is discouraged.
     *
     * Whenever possible, use {safeIncreaseAllowance} and
     * {safeDecreaseAllowance} instead.
     */
    function safeApprove(IERC20 token, address spender, uint256 value) internal {
        // safeApprove should only be called when setting an initial allowance,
        // or when resetting it to zero. To increase and decrease it, use
        // 'safeIncreaseAllowance' and 'safeDecreaseAllowance'
        require(
            (value == 0) || (token.allowance(address(this), spender) == 0),
            "SafeERC20: approve from non-zero to non-zero allowance"
        );
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, value));
    }

    /**
     * @dev Increase the calling contract's allowance toward `spender` by `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     */
    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 oldAllowance = token.allowance(address(this), spender);
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, oldAllowance + value));
    }

    /**
     * @dev Decrease the calling contract's allowance toward `spender` by `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     */
    function safeDecreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        unchecked {
            uint256 oldAllowance = token.allowance(address(this), spender);
            require(oldAllowance >= value, "SafeERC20: decreased allowance below zero");
            _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, oldAllowance - value));
        }
    }

    /**
     * @dev Set the calling contract's allowance toward `spender` to `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful. Compatible with tokens that require the approval to be set to
     * 0 before setting it to a non-zero value.
     */
    function forceApprove(IERC20 token, address spender, uint256 value) internal {
        bytes memory approvalCall = abi.encodeWithSelector(token.approve.selector, spender, value);

        if (!_callOptionalReturnBool(token, approvalCall)) {
            _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, 0));
            _callOptionalReturn(token, approvalCall);
        }
    }

    /**
     * @dev Use a ERC-2612 signature to set the `owner` approval toward `spender` on `token`.
     * Revert on invalid signature.
     */
    function safePermit(
        IERC20Permit token,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        uint256 nonceBefore = token.nonces(owner);
        token.permit(owner, spender, value, deadline, v, r, s);
        uint256 nonceAfter = token.nonces(owner);
        require(nonceAfter == nonceBefore + 1, "SafeERC20: permit did not succeed");
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     */
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves. We use {Address-functionCall} to perform this call, which verifies that
        // the target address contains contract code and also asserts for success in the low-level call.

        bytes memory returndata = address(token).functionCall(data, "SafeERC20: low-level call failed");
        require(returndata.length == 0 || abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     *
     * This is a variant of {_callOptionalReturn} that silents catches all reverts and returns a bool instead.
     */
    function _callOptionalReturnBool(IERC20 token, bytes memory data) private returns (bool) {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves. We cannot use {Address-functionCall} here since this should return false
        // and not revert is the subcall reverts.

        (bool success, bytes memory returndata) = address(token).call(data);
        return
            success && (returndata.length == 0 || abi.decode(returndata, (bool))) && Address.isContract(address(token));
    }
}
pragma solidity ^0.8.1;

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
     *
     * Furthermore, `isContract` will also return true if the target contract within
     * the same transaction is already scheduled for destruction by `SELFDESTRUCT`,
     * which only has an effect at the end of a transaction.
     * ====
     *
     * [IMPORTANT]
     * ====
     * You shouldn't rely on `isContract` to protect against flash loan attacks!
     *
     * Preventing calls from contracts is highly discouraged. It breaks composability, breaks support for smart wallets
     * like Gnosis Safe, and does not provide security since it can be circumvented by calling from a contract
     * constructor.
     * ====
     */
    function isContract(address account) internal view returns (bool) {
        // This method relies on extcodesize/address.code.length, which returns 0
        // for contracts in construction, since the code is only stored at the end
        // of the constructor execution.

        return account.code.length > 0;
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
     * https://consensys.net/diligence/blog/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.8.0/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
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
        return functionCallWithValue(target, data, 0, "Address: low-level call failed");
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
    function functionCallWithValue(address target, bytes memory data, uint256 value) internal returns (bytes memory) {
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
        (bool success, bytes memory returndata) = target.call{value: value}(data);
        return verifyCallResultFromTarget(target, success, returndata, errorMessage);
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
        (bool success, bytes memory returndata) = target.staticcall(data);
        return verifyCallResultFromTarget(target, success, returndata, errorMessage);
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
        (bool success, bytes memory returndata) = target.delegatecall(data);
        return verifyCallResultFromTarget(target, success, returndata, errorMessage);
    }

    /**
     * @dev Tool to verify that a low level call to smart-contract was successful, and revert (either by bubbling
     * the revert reason or using the provided one) in case of unsuccessful call or if target was not a contract.
     *
     * _Available since v4.8._
     */
    function verifyCallResultFromTarget(
        address target,
        bool success,
        bytes memory returndata,
        string memory errorMessage
    ) internal view returns (bytes memory) {
        if (success) {
            if (returndata.length == 0) {
                // only check isContract if the call was successful and the return data is empty
                // otherwise we already know that it was a contract
                require(isContract(target), "Address: call to non-contract");
            }
            return returndata;
        } else {
            _revert(returndata, errorMessage);
        }
    }

    /**
     * @dev Tool to verify that a low level call was successful, and revert if it wasn't, either by bubbling the
     * revert reason or using the provided one.
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
            _revert(returndata, errorMessage);
        }
    }

    function _revert(bytes memory returndata, string memory errorMessage) private pure {
        // Look for revert reason and bubble it up if present
        if (returndata.length > 0) {
            // The easiest way to bubble the revert reason is using memory via assembly
            /// @solidity memory-safe-assembly
            assembly {
                let returndata_size := mload(returndata)
                revert(add(32, returndata), returndata_size)
            }
        } else {
            revert(errorMessage);
        }
    }
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
 * @dev Standard math utilities missing in the Solidity language.
 */
library Math {
    enum Rounding {
        Down, // Toward negative infinity
        Up, // Toward infinity
        Zero // Toward zero
    }

    /**
     * @dev Returns the largest of two numbers.
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
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
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /**
     * @notice Calculates floor(x * y / denominator) with full precision. Throws if result overflows a uint256 or denominator == 0
     * @dev Original credit to Remco Bloemen under MIT license (https://xn--2-umb.com/21/muldiv)
     * with further edits by Uniswap Labs also under MIT license.
     */
    function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = x * y. Compute the product mod 2^256 and mod 2^256 - 1, then use
            // use the Chinese Remainder Theorem to reconstruct the 512 bit result. The result is stored in two 256
            // variables such that product = prod1 * 2^256 + prod0.
            uint256 prod0; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly {
                let mm := mulmod(x, y, not(0))
                prod0 := mul(x, y)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow cases, 256 by 256 division.
            if (prod1 == 0) {
                // Solidity will revert if denominator == 0, unlike the div opcode on its own.
                // The surrounding unchecked block does not change this fact.
                // See https://docs.soliditylang.org/en/latest/control-structures.html#checked-or-unchecked-arithmetic.
                return prod0 / denominator;
            }

            // Make sure the result is less than 2^256. Also prevents denominator == 0.
            require(denominator > prod1, "Math: mulDiv overflow");

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [prod1 prod0].
            uint256 remainder;
            assembly {
                // Compute remainder using mulmod.
                remainder := mulmod(x, y, denominator)

                // Subtract 256 bit number from 512 bit number.
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator and compute largest power of two divisor of denominator. Always >= 1.
            // See https://cs.stackexchange.com/q/138556/92363.

            // Does not overflow because the denominator cannot be zero at this stage in the function.
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                // Divide denominator by twos.
                denominator := div(denominator, twos)

                // Divide [prod1 prod0] by twos.
                prod0 := div(prod0, twos)

                // Flip twos such that it is 2^256 / twos. If twos is zero, then it becomes one.
                twos := add(div(sub(0, twos), twos), 1)
            }

            // Shift in bits from prod1 into prod0.
            prod0 |= prod1 * twos;

            // Invert denominator mod 2^256. Now that denominator is an odd number, it has an inverse modulo 2^256 such
            // that denominator * inv = 1 mod 2^256. Compute the inverse by starting with a seed that is correct for
            // four bits. That is, denominator * inv = 1 mod 2^4.
            uint256 inverse = (3 * denominator) ^ 2;

            // Use the Newton-Raphson iteration to improve the precision. Thanks to Hensel's lifting lemma, this also works
            // in modular arithmetic, doubling the correct bits in each step.
            inverse *= 2 - denominator * inverse; // inverse mod 2^8
            inverse *= 2 - denominator * inverse; // inverse mod 2^16
            inverse *= 2 - denominator * inverse; // inverse mod 2^32
            inverse *= 2 - denominator * inverse; // inverse mod 2^64
            inverse *= 2 - denominator * inverse; // inverse mod 2^128
            inverse *= 2 - denominator * inverse; // inverse mod 2^256

            // Because the division is now exact we can divide by multiplying with the modular inverse of denominator.
            // This will give us the correct result modulo 2^256. Since the preconditions guarantee that the outcome is
            // less than 2^256, this is the final result. We don't need to compute the high bits of the result and prod1
            // is no longer required.
            result = prod0 * inverse;
            return result;
        }
    }

    /**
     * @notice Calculates x * y / denominator with full precision, following the selected rounding direction.
     */
    function mulDiv(uint256 x, uint256 y, uint256 denominator, Rounding rounding) internal pure returns (uint256) {
        uint256 result = mulDiv(x, y, denominator);
        if (rounding == Rounding.Up && mulmod(x, y, denominator) > 0) {
            result += 1;
        }
        return result;
    }

    /**
     * @dev Returns the square root of a number. If the number is not a perfect square, the value is rounded down.
     *
     * Inspired by Henry S. Warren, Jr.'s "Hacker's Delight" (Chapter 11).
     */
    function sqrt(uint256 a) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }

        // For our first guess, we get the biggest power of 2 which is smaller than the square root of the target.
        //
        // We know that the "msb" (most significant bit) of our target number `a` is a power of 2 such that we have
        // `msb(a) <= a < 2*msb(a)`. This value can be written `msb(a)=2**k` with `k=log2(a)`.
        //
        // This can be rewritten `2**log2(a) <= a < 2**(log2(a) + 1)`
        // → `sqrt(2**k) <= sqrt(a) < sqrt(2**(k+1))`
        // → `2**(k/2) <= sqrt(a) < 2**((k+1)/2) <= 2**(k/2 + 1)`
        //
        // Consequently, `2**(log2(a) / 2)` is a good first approximation of `sqrt(a)` with at least 1 correct bit.
        uint256 result = 1 << (log2(a) >> 1);

        // At this point `result` is an estimation with one bit of precision. We know the true value is a uint128,
        // since it is the square root of a uint256. Newton's method converges quadratically (precision doubles at
        // every iteration). We thus need at most 7 iteration to turn our partial result with one bit of precision
        // into the expected uint128 result.
        unchecked {
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            return min(result, a / result);
        }
    }

    /**
     * @notice Calculates sqrt(a), following the selected rounding direction.
     */
    function sqrt(uint256 a, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = sqrt(a);
            return result + (rounding == Rounding.Up && result * result < a ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 2, rounded down, of a positive value.
     * Returns 0 if given 0.
     */
    function log2(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >> 128 > 0) {
                value >>= 128;
                result += 128;
            }
            if (value >> 64 > 0) {
                value >>= 64;
                result += 64;
            }
            if (value >> 32 > 0) {
                value >>= 32;
                result += 32;
            }
            if (value >> 16 > 0) {
                value >>= 16;
                result += 16;
            }
            if (value >> 8 > 0) {
                value >>= 8;
                result += 8;
            }
            if (value >> 4 > 0) {
                value >>= 4;
                result += 4;
            }
            if (value >> 2 > 0) {
                value >>= 2;
                result += 2;
            }
            if (value >> 1 > 0) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 2, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log2(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log2(value);
            return result + (rounding == Rounding.Up && 1 << result < value ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 10, rounded down, of a positive value.
     * Returns 0 if given 0.
     */
    function log10(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >= 10 ** 64) {
                value /= 10 ** 64;
                result += 64;
            }
            if (value >= 10 ** 32) {
                value /= 10 ** 32;
                result += 32;
            }
            if (value >= 10 ** 16) {
                value /= 10 ** 16;
                result += 16;
            }
            if (value >= 10 ** 8) {
                value /= 10 ** 8;
                result += 8;
            }
            if (value >= 10 ** 4) {
                value /= 10 ** 4;
                result += 4;
            }
            if (value >= 10 ** 2) {
                value /= 10 ** 2;
                result += 2;
            }
            if (value >= 10 ** 1) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 10, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log10(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log10(value);
            return result + (rounding == Rounding.Up && 10 ** result < value ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 256, rounded down, of a positive value.
     * Returns 0 if given 0.
     *
     * Adding one to the result gives the number of pairs of hex symbols needed to represent `value` as a hex string.
     */
    function log256(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >> 128 > 0) {
                value >>= 128;
                result += 16;
            }
            if (value >> 64 > 0) {
                value >>= 64;
                result += 8;
            }
            if (value >> 32 > 0) {
                value >>= 32;
                result += 4;
            }
            if (value >> 16 > 0) {
                value >>= 16;
                result += 2;
            }
            if (value >> 8 > 0) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 256, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log256(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log256(value);
            return result + (rounding == Rounding.Up && 1 << (result << 3) < value ? 1 : 0);
        }
    }
}
pragma solidity 0.8.16;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../lib/DecimalMath.sol";
import "../intf/ID3Vault.sol";
import "../../intf/ID3Oracle.sol";
import "./D3Storage.sol";

/// @notice pool funding model, manage pool borrow/repay and maker deposi/withdraw
contract D3Funding is D3Storage {
    using SafeERC20 for IERC20;

    /// @notice borrow tokens from vault
    function borrow(address token, uint256 amount) external onlyOwner nonReentrant poolOngoing {
        // call vault's poolBorrow function
        ID3Vault(state._D3_VAULT_).poolBorrow(token, amount);
        // approve max, ensure vault could force liquidate
        uint256 allowance = IERC20(token).allowance(address(this), state._D3_VAULT_);
        if(allowance < type(uint256).max) {
            IERC20(token).forceApprove(state._D3_VAULT_, type(uint256).max);
        }

        _updateReserve(token);
        require(checkSafe(), Errors.NOT_SAFE);
        require(checkBorrowSafe(), Errors.NOT_BORROW_SAFE);
    }

    /// @notice repay vault with certain amount of borrowed assets 
    function repay(address token, uint256 amount) external onlyOwner nonReentrant poolOngoing {
        // call vault's poolRepay
        ID3Vault(state._D3_VAULT_).poolRepay(token, amount);

        _updateReserve(token);
        require(checkSafe(), Errors.NOT_SAFE);
    }

    /// @notice repay vault all debt of this token
    function repayAll(address token) external onlyOwner nonReentrant poolOngoing {
        ID3Vault(state._D3_VAULT_).poolRepayAll(token);

        _updateReserve(token);
        require(checkSafe(), Errors.NOT_SAFE);

    }

    /// @notice used through liquidation
    function updateReserveByVault(address token) external onlyVault {
        uint256 allowance = IERC20(token).allowance(address(this), state._D3_VAULT_);
        if(allowance < type(uint256).max) {
            IERC20(token).forceApprove(state._D3_VAULT_, type(uint256).max);
        }
        _updateReserve(token);
    }

    /// @notice maker deposit, anyone could deposit but only maker could withdraw
    function makerDeposit(address token) external nonReentrant poolOngoing {
        require(ID3Oracle(state._ORACLE_).isFeasible(token), Errors.TOKEN_NOT_FEASIBLE);
        if (!state.hasDepositedToken[token]) {
            state.hasDepositedToken[token] = true;
            state.depositedTokenList.push(token);
        }
        // transfer in from proxies
        uint256 tokenInAmount = IERC20(token).balanceOf(address(this)) - state.balances[token];
        _updateReserve(token);
        // if token in tokenlist, approve max, ensure vault could force liquidate
        uint256 allowance = IERC20(token).allowance(address(this), state._D3_VAULT_);
        if(_checkTokenInTokenlist(token) && allowance < type(uint256).max) {
            IERC20(token).forceApprove(state._D3_VAULT_, type(uint256).max);
        }
        require(checkSafe(), Errors.NOT_SAFE);

        emit MakerDeposit(token, tokenInAmount);
    }

    function makerWithdraw(address to, address token, uint256 amount) external onlyOwner nonReentrant poolOngoing {
        IERC20(token).safeTransfer(to, amount);

        _updateReserve(token);
        require(checkSafe(), Errors.NOT_SAFE);
        require(checkBorrowSafe(), Errors.NOT_BORROW_SAFE);

        emit MakerWithdraw(to, token, amount);
    }

    // below IM: not safe!
    function checkSafe() public view returns (bool) {
        return ID3Vault(state._D3_VAULT_).checkSafe(address(this));
    }

    // check when borrowing asset
    function checkBorrowSafe() public view returns (bool) {
        return ID3Vault(state._D3_VAULT_).checkBorrowSafe(address(this));
    }

    // blow MM: dangerous!
    function checkCanBeLiquidated() public view returns (bool) {
        return ID3Vault(state._D3_VAULT_).checkCanBeLiquidated(address(this));
    }

    function startLiquidation() external onlyVault {
        isInLiquidation = true;
    }

    function finishLiquidation() external onlyVault {
        isInLiquidation = false;
    }

    function _updateReserve(address token) internal {
        state.balances[token] = IERC20(token).balanceOf(address(this));
    }

    function _checkTokenInTokenlist(address token) internal view returns(bool){
        return ID3Vault(state._D3_VAULT_).tokens(token); 
    }
}
pragma solidity 0.8.16;

import "../lib/MakerTypes.sol";
import "../lib/Types.sol";
import "../lib/InitializableOwnable.sol";
import "../lib/Errors.sol";
import {ID3MM} from "../intf/ID3MM.sol";

/// @notice D3Maker is a dependent price controll model. Maker could set token price and other price 
/// parameters to control swap. The key part is MakerState(in D3Maker) and flag(in D3MM) parameter. MakerState 
/// contains token price, amount and swap fee. Specially for token price, which is supposed to be set frequently,
/// we use one slot to compress 3 token price with dependent price array. Flags in D3MM decide whether this token's 
/// cumulative volumn change, which means resetting integral start point. Every function should reset cumulative
/// volumn.
/// @dev maker could not delete token function
contract D3Maker is InitializableOwnable {
    MakerTypes.MakerState internal state;
    address public _POOL_;
    address[] internal poolTokenlist;

    // ============== Event =============
    // use operatorIndex to distinct different setting, 1 = setMaxInterval  2 = setTokensPrice, 3 = setNSPriceSlot,
    // 4 = setStablePriceSlot, 5 = setTokensAmounts, 6 = setTokensKs
    event SetPoolInfo(uint256 indexed operatorIndex);
    event SetNewToken(address indexed token);

    // ============== init =============
    function init(address owner, address pool, uint256 maxInterval) external {
        initOwner(owner);
        _POOL_ = pool;
        state.heartBeat.maxInterval = maxInterval;
    }

    // ============= Read for tokenMMInfo =================
    function getTokenMMInfoForPool(address token)
        external
        view
        returns (Types.TokenMMInfo memory tokenMMInfo, uint256 tokenIndex)
    {
        if (state.tokenMMInfoMap[token].amountInfo == 0) {
            // invalid token
            return (tokenMMInfo, 0);
        }
        // get mtFee
        uint256 mtFeeRate = ID3MM(_POOL_).getFeeRate(token);
        // deal with priceInfo
        uint80 priceInfo = getOneTokenPriceSet(token);
        (
            tokenMMInfo.askUpPrice,
            tokenMMInfo.askDownPrice,
            tokenMMInfo.bidUpPrice,
            tokenMMInfo.bidDownPrice,
            tokenMMInfo.swapFeeRate
        ) = MakerTypes.parseAllPrice(priceInfo);
        // lpfee add mtFee
        tokenMMInfo.mtFeeRate = mtFeeRate;
        uint64 amountInfo = state.tokenMMInfoMap[token].amountInfo;
        tokenMMInfo.askAmount = MakerTypes.parseAskAmount(amountInfo);
        tokenMMInfo.bidAmount = MakerTypes.parseBidAmount(amountInfo);
        tokenMMInfo.kAsk = MakerTypes.parseK(state.tokenMMInfoMap[token].kAsk);
        tokenMMInfo.kBid = MakerTypes.parseK(state.tokenMMInfoMap[token].kBid);
        tokenIndex = uint256(getOneTokenOriginIndex(token));
    }

    // ================== Read parameters ==============

    /// @notice give one token's address, give back token's priceInfo
    function getOneTokenPriceSet(address token) public view returns (uint80 priceSet) {
        require(state.priceListInfo.tokenIndexMap[token] > 0, Errors.INVALID_TOKEN);
        uint256 tokenOriIndex = state.priceListInfo.tokenIndexMap[token] - 1;
        uint256 tokenIndex = (tokenOriIndex / 2);
        uint256 tokenIndexInnerSlot = tokenIndex % MakerTypes.PRICE_QUANTITY_IN_ONE_SLOT;

        uint256 curAllPrices = tokenOriIndex % 2 == 1
            ? state.priceListInfo.tokenPriceNS[tokenIndex / MakerTypes.PRICE_QUANTITY_IN_ONE_SLOT]
            : state.priceListInfo.tokenPriceStable[tokenIndex / MakerTypes.PRICE_QUANTITY_IN_ONE_SLOT];
        curAllPrices = curAllPrices >> (MakerTypes.ONE_PRICE_BIT * tokenIndexInnerSlot);
        priceSet = uint80(curAllPrices & ((2 ** (MakerTypes.ONE_PRICE_BIT)) - 1));
    }

    /// @notice get one token index. odd for none-stable, even for stable,  true index = (tokenIndex[address] - 1) / 2
    function getOneTokenOriginIndex(address token) public view returns (int256) {
        //require(state.priceListInfo.tokenIndexMap[token] > 0, Errors.INVALID_TOKEN);
        return int256(state.priceListInfo.tokenIndexMap[token]) - 1;
    }

    /// @notice get all stable token Info
    /// @return numberOfStable stable tokens' quantity
    /// @return tokenPriceStable stable tokens' price slot array. each data contains up to 3 token prices
    function getStableTokenInfo()
        external
        view
        returns (uint256 numberOfStable, uint256[] memory tokenPriceStable, uint256 curFlag)
    {
        numberOfStable = state.priceListInfo.numberOfStable;
        tokenPriceStable = state.priceListInfo.tokenPriceStable;
        curFlag = ID3MM(_POOL_).allFlag();
    }

    /// @notice get all non-stable token Info
    /// @return number stable tokens' quantity
    /// @return tokenPrices stable tokens' price slot array. each data contains up to 3 token prices
    function getNSTokenInfo() external view returns (uint256 number, uint256[] memory tokenPrices, uint256 curFlag) {
        number = state.priceListInfo.numberOfNS;
        tokenPrices = state.priceListInfo.tokenPriceNS;
        curFlag = ID3MM(_POOL_).allFlag();
    }

    /// @notice used for construct several price in one price slot
    /// @param priceSlot origin price slot
    /// @param slotInnerIndex token index in slot
    /// @param priceSet the token info needed to update
    function stickPrice(
        uint256 priceSlot,
        uint256 slotInnerIndex,
        uint256 priceSet
    ) public pure returns (uint256 newPriceSlot) {
        uint256 leftPriceSet = priceSlot >> ((slotInnerIndex + 1) * MakerTypes.ONE_PRICE_BIT);
        uint256 rightPriceSet = priceSlot & ((2 ** (slotInnerIndex * MakerTypes.ONE_PRICE_BIT)) - 1);
        newPriceSlot = (leftPriceSet << ((slotInnerIndex + 1) * MakerTypes.ONE_PRICE_BIT))
            + (priceSet << (slotInnerIndex * MakerTypes.ONE_PRICE_BIT)) + rightPriceSet;
    }

    function checkHeartbeat() public view returns (bool) {
        if (block.timestamp - state.heartBeat.lastHeartBeat <= state.heartBeat.maxInterval) {
            return true;
        } else {
            return false;
        }
    }

    function getPoolTokenListFromMaker() external view returns(address[] memory tokenlist) {
        return poolTokenlist;
    }

    // ============= Set params ===========

    /// @notice maker could use multicall to set different params in one tx.
    function multicall(bytes[] calldata data) external returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);

            if (!success) {
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }

            results[i] = result;
        }
    }

    /// @notice maker set a new token info
    /// @param token token's address
    /// @param priceSet packed price, [mid price(16) | mid price decimal(8) | fee rate(16) | ask up rate (16) | bid down rate(16)]
    /// @param amountSet describe ask and bid amount and K, [ask amounts(16) | ask amounts decimal(8) | bid amounts(16) | bid amounts decimal(8) ] = one slot could contains 4 token info
    /// @param stableOrNot describe this token is stable or not, true = stable coin
    /// @param kAsk k of ask curve
    /// @param kBid k of bid curve
    function setNewToken(
        address token,
        bool stableOrNot,
        uint80 priceSet,
        uint64 amountSet,
        uint16 kAsk,
        uint16 kBid
    ) external onlyOwner {
        require(state.priceListInfo.tokenIndexMap[token] == 0, Errors.HAVE_SET_TOKEN_INFO);
        // check amount
        require(kAsk >= 0 && kAsk <= 10000, Errors.K_LIMIT);
        require(kBid >= 0 && kBid <= 10000, Errors.K_LIMIT);
        poolTokenlist.push(token);

        // set new token info
        state.tokenMMInfoMap[token].priceInfo = priceSet;
        state.tokenMMInfoMap[token].amountInfo = amountSet;
        state.tokenMMInfoMap[token].kAsk = kAsk;
        state.tokenMMInfoMap[token].kBid = kBid;
        state.heartBeat.lastHeartBeat = block.timestamp;

        // set token price index
        uint256 tokenIndex;
        if (stableOrNot) {
            // is stable
            tokenIndex = state.priceListInfo.numberOfStable * 2;
            uint256 innerSlotIndex = state.priceListInfo.numberOfStable % MakerTypes.PRICE_QUANTITY_IN_ONE_SLOT;
            uint256 slotIndex = state.priceListInfo.numberOfStable / MakerTypes.PRICE_QUANTITY_IN_ONE_SLOT;
            if (innerSlotIndex == 0) {
                state.priceListInfo.tokenPriceStable.push(priceSet);
            } else {
                state.priceListInfo.tokenPriceStable[slotIndex] = (
                    uint256(priceSet) << (MakerTypes.ONE_PRICE_BIT * innerSlotIndex)
                ) + state.priceListInfo.tokenPriceStable[slotIndex];
            }
            state.priceListInfo.numberOfStable++;
        } else {
            tokenIndex = state.priceListInfo.numberOfNS * 2 + 1;
            uint256 innerSlotIndex = state.priceListInfo.numberOfNS % MakerTypes.PRICE_QUANTITY_IN_ONE_SLOT;
            uint256 slotIndex = state.priceListInfo.numberOfNS / MakerTypes.PRICE_QUANTITY_IN_ONE_SLOT;
            if (innerSlotIndex == 0) {
                state.priceListInfo.tokenPriceNS.push(priceSet);
            } else {
                state.priceListInfo.tokenPriceNS[slotIndex] = (
                    uint256(priceSet) << (MakerTypes.ONE_PRICE_BIT * innerSlotIndex)
                ) + state.priceListInfo.tokenPriceNS[slotIndex];
            }
            state.priceListInfo.numberOfNS++;
        }
        // to avoid reset the same token, tokenIndexMap record index from 1, but actualIndex = tokenIndex[address] - 1
        state.priceListInfo.tokenIndexMap[token] = tokenIndex + 1;
        state.tokenMMInfoMap[token].tokenIndex = uint16(tokenIndex);

        emit SetNewToken(token);
    }

    /// @notice set token prices
    /// @param tokens token address set
    /// @param tokenPrices token prices set, each number pack one token all price.Each format is the same with priceSet
    /// [mid price(16) | mid price decimal(8) | fee rate(16) | ask up rate (16) | bid down rate(16)] = one slot could contains 3 token info
    function setTokensPrice(
        address[] calldata tokens,
        uint80[] calldata tokenPrices
    ) external onlyOwner {
        require(tokens.length == tokenPrices.length, Errors.PRICES_LENGTH_NOT_MATCH);
        uint256[] memory haveWrittenToken = new uint256[](tokens.length);
        uint256 curFlag = ID3MM(_POOL_).allFlag();

        for (uint256 i = 0; i < tokens.length; ++i) {
            if (haveWrittenToken[i] == 1) continue;

            haveWrittenToken[i] = 1;
            address curToken = tokens[i];
            uint80 curTokenPriceSet = tokenPrices[i];
            //_checkUpAndDownPrice(curTokenPriceSet);

            {
                uint256 tokenIndex = state.priceListInfo.tokenIndexMap[curToken] - 1;
                curFlag = curFlag & ~(1 << tokenIndex);
            }

            // get slot price
            uint256 curTokenIndex = (state.priceListInfo.tokenIndexMap[curToken] - 1) / 2;
            uint256 slotIndex = curTokenIndex / MakerTypes.PRICE_QUANTITY_IN_ONE_SLOT;
            uint256 priceInfoSet = (state.priceListInfo.tokenIndexMap[curToken] - 1) % 2 == 1
                ? state.priceListInfo.tokenPriceNS[slotIndex]
                : state.priceListInfo.tokenPriceStable[slotIndex];

            priceInfoSet = stickPrice(
                priceInfoSet, curTokenIndex % MakerTypes.PRICE_QUANTITY_IN_ONE_SLOT, uint256(curTokenPriceSet)
            );

            // find one slot token
            for (uint256 j = i + 1; j < tokens.length; ++j) {
                address tokenJ = tokens[j];
                uint256 tokenJOriIndex = (state.priceListInfo.tokenIndexMap[tokenJ] - 1);
                if (
                    haveWrittenToken[j] == 1 // have written
                        || (state.priceListInfo.tokenIndexMap[curToken] - 1) % 2 != tokenJOriIndex % 2 // not the same stable type
                        || tokenJOriIndex / 2 / MakerTypes.PRICE_QUANTITY_IN_ONE_SLOT != slotIndex
                ) {
                    // not one slot
                    continue;
                }
                //_checkUpAndDownPrice(tokenPrices[j]);
                priceInfoSet = stickPrice(
                    priceInfoSet, (tokenJOriIndex / 2) % MakerTypes.PRICE_QUANTITY_IN_ONE_SLOT, uint256(tokenPrices[j])
                );

                haveWrittenToken[j] = 1;
                {
                    uint256 tokenIndex = state.priceListInfo.tokenIndexMap[tokenJ] - 1;
                    curFlag = curFlag & ~(1 << tokenIndex);
                }
            }

            if ((state.priceListInfo.tokenIndexMap[curToken] - 1) % 2 == 1) {
                state.priceListInfo.tokenPriceNS[slotIndex] = priceInfoSet;
            } else {
                state.priceListInfo.tokenPriceStable[slotIndex] = priceInfoSet;
            }
        }
        state.heartBeat.lastHeartBeat = block.timestamp;
        ID3MM(_POOL_).setNewAllFlag(curFlag);

        emit SetPoolInfo(2);
    }

    /// @notice user set PriceListInfo.tokenPriceNS price info, only for none-stable coin
    /// @param slotIndex tokenPriceNS index
    /// @param priceSlots tokenPriceNS price info, every data has packed all 3 token price info
    /// @param newAllFlag maker update token cumulative status,
    /// for allFlag, tokenOriIndex represent bit index in allFlag. eg: tokenA has origin index 3, that means (allFlag >> 3) & 1 = token3's flag
    /// flag = 0 means to reset cumulative. flag = 1 means not to reset cumulative.
    /// @dev maker should be responsible for data availability
    function setNSPriceSlot(
        uint256[] calldata slotIndex,
        uint256[] calldata priceSlots,
        uint256 newAllFlag
    ) external onlyOwner {
        require(slotIndex.length == priceSlots.length, Errors.PRICE_SLOT_LENGTH_NOT_MATCH);
        for (uint256 i = 0; i < slotIndex.length; ++i) {
            state.priceListInfo.tokenPriceNS[slotIndex[i]] = priceSlots[i];
        }
        ID3MM(_POOL_).setNewAllFlag(newAllFlag);
        state.heartBeat.lastHeartBeat = block.timestamp;

        emit SetPoolInfo(3);
    }

    /// @notice user set PriceListInfo.tokenPriceStable price info, only for stable coin
    /// @param slotIndex tokenPriceStable index
    /// @param priceSlots tokenPriceStable price info, every data has packed all 3 token price info
    /// @param newAllFlag maker update token cumulative status,
    /// for allFlag, tokenOriIndex represent bit index in allFlag. eg: tokenA has origin index 3, that means (allFlag >> 3) & 1 = token3's flag
    /// flag = 0 means to reset cumulative. flag = 1 means not to reset cumulative.
    /// @dev maker should be responsible for data availability
    function setStablePriceSlot(
        uint256[] calldata slotIndex,
        uint256[] calldata priceSlots,
        uint256 newAllFlag
    ) external onlyOwner {
        require(slotIndex.length == priceSlots.length, Errors.PRICE_SLOT_LENGTH_NOT_MATCH);
        for (uint256 i = 0; i < slotIndex.length; ++i) {
            state.priceListInfo.tokenPriceStable[slotIndex[i]] = priceSlots[i];
        }
        ID3MM(_POOL_).setNewAllFlag(newAllFlag);
        state.heartBeat.lastHeartBeat = block.timestamp;

        emit SetPoolInfo(4);
    }

    /// @notice set token Amounts
    /// @param tokens token address set
    /// @param tokenAmounts token amounts set, each number pack one token all amounts.Each format is the same with amountSetAndK
    /// [ask amounts(16) | ask amounts decimal(8) | bid amounts(16) | bid amounts decimal(8) ]
    function setTokensAmounts(
        address[] calldata tokens,
        uint64[] calldata tokenAmounts
    ) external onlyOwner {
        require(tokens.length == tokenAmounts.length, Errors.AMOUNTS_LENGTH_NOT_MATCH);
        uint256 curFlag = ID3MM(_POOL_).allFlag();
        for (uint256 i = 0; i < tokens.length; ++i) {
            address curToken = tokens[i];
            uint64 curTokenAmountSet = tokenAmounts[i];

            state.tokenMMInfoMap[curToken].amountInfo = curTokenAmountSet;
            {
                uint256 tokenIndex = state.priceListInfo.tokenIndexMap[curToken] - 1;
                curFlag = curFlag & ~(1 << tokenIndex);
            }
        }
        state.heartBeat.lastHeartBeat = block.timestamp;
        ID3MM(_POOL_).setNewAllFlag(curFlag);

        emit SetPoolInfo(5);
    }

    /// @notice set token Ks
    /// @param tokens token address set
    /// @param tokenKs token k_ask and k_bid, structure like [kAsk(16) | kBid(16)]
    function setTokensKs(address[] calldata tokens, uint32[] calldata tokenKs) external onlyOwner {
        require(tokens.length == tokenKs.length, Errors.K_LENGTH_NOT_MATCH);
        uint256 curFlag = ID3MM(_POOL_).allFlag();
        for (uint256 i = 0; i < tokens.length; ++i) {
            address curToken = tokens[i];
            uint32 curTokenK = tokenKs[i];
            uint16 kAsk = uint16(curTokenK >> 16);
            uint16 kBid = uint16(curTokenK & 0xffff);

            require(kAsk >= 0 && kAsk <= 10000, Errors.K_LIMIT);
            require(kBid >= 0 && kBid <= 10000, Errors.K_LIMIT);

            state.tokenMMInfoMap[curToken].kAsk = kAsk;
            state.tokenMMInfoMap[curToken].kBid = kBid;

            {
                uint256 tokenIndex = state.priceListInfo.tokenIndexMap[curToken] - 1;
                curFlag = curFlag & ~(1 << tokenIndex);
            }
        }
        state.heartBeat.lastHeartBeat = block.timestamp;
        ID3MM(_POOL_).setNewAllFlag(curFlag);

        emit SetPoolInfo(6);
    }

    /// @notice set acceptable setting interval, if setting gap > maxInterval, swap will revert.
    function setHeartbeat(uint256 newMaxInterval) public onlyOwner {
        state.heartBeat.maxInterval = newMaxInterval;

        emit SetPoolInfo(1);
    }
}
pragma solidity 0.8.16;

import "../lib/Types.sol";
import "../lib/Errors.sol";
import "../lib/InitializableOwnable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract D3Storage is ReentrancyGuard, InitializableOwnable {
    Types.D3MMState internal state;
    // record all token flag
    // for allFlag, tokenOriIndex represent bit index in allFlag. eg: tokenA has origin index 3, that means (allFlag >> 3) & 1 = token3's flag
    // flag = 0 means to reset cumulative. flag = 1 means not to reset cumulative.
    uint256 public allFlag;
    // cumulative records
    mapping(address => Types.TokenCumulative) public tokenCumMap;
    bool public isInLiquidation;

    // ============= Events ==========
    event MakerDeposit(address indexed token, uint256 amount);
    event MakerWithdraw(address indexed to, address indexed token, uint256 amount);

    // sellOrNot = 0 means sell, 1 means buy.
    event Swap(
        address to,
        address fromToken,
        address toToken,
        uint256 payFromAmount,
        uint256 receiveToAmount,
        uint256 swapFee,
        uint256 mtFee,
        uint256 sellOrNot
    );

    modifier poolOngoing() {
        require(isInLiquidation == false, Errors.POOL_NOT_ONGOING);
        _;
    }

    modifier onlyVault() {
        require(msg.sender == state._D3_VAULT_, Errors.NOT_VAULT);
        _;
    }
}
pragma solidity 0.8.16;

import "../lib/PMMRangeOrder.sol";
import "../lib/Errors.sol";
import {IDODOSwapCallback} from "../intf/IDODOSwapCallback.sol";
import {ID3Maker} from "../intf/ID3Maker.sol";
import {ID3Vault} from "../intf/ID3Vault.sol";
import {D3Funding} from "./D3Funding.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract D3Trading is D3Funding {
    using SafeERC20 for IERC20;

    modifier onlyMaker() {
        require(msg.sender == state._MAKER_, "not maker");
        _;
    }

    // =============== Read ===============

    /// @notice for external users to read tokenMMInfo
    function getTokenMMPriceInfoForRead(
        address token
    )
        external
        view
        returns (uint256 askDownPrice, uint256 askUpPrice, uint256 bidDownPrice, uint256 bidUpPrice, uint256 swapFee)
    {
        (Types.TokenMMInfo memory tokenMMInfo, ) =
            ID3Maker(state._MAKER_).getTokenMMInfoForPool(token);

        askDownPrice = tokenMMInfo.askDownPrice;
        askUpPrice = tokenMMInfo.askUpPrice;
        bidDownPrice = tokenMMInfo.bidDownPrice;
        bidUpPrice = tokenMMInfo.bidUpPrice;
        swapFee = tokenMMInfo.swapFeeRate;
    }

    function getTokenMMOtherInfoForRead(
        address token
    )
        external
        view
        returns (
            uint256 askAmount,
            uint256 bidAmount,
            uint256 kAsk,
            uint256 kBid,
            uint256 cumulativeAsk,
            uint256 cumulativeBid
        )
    {
        (Types.TokenMMInfo memory tokenMMInfo, uint256 tokenIndex) =
            ID3Maker(state._MAKER_).getTokenMMInfoForPool(token);
        cumulativeAsk = allFlag >> (tokenIndex) & 1 == 0 ? 0 : tokenCumMap[token].cumulativeAsk;
        cumulativeBid = allFlag >> (tokenIndex) & 1 == 0 ? 0 : tokenCumMap[token].cumulativeBid;

        bidAmount = tokenMMInfo.bidAmount;
        askAmount = tokenMMInfo.askAmount;
        kAsk = tokenMMInfo.kAsk;
        kBid = tokenMMInfo.kBid;
    }

    // ============ Swap =============
    /// @notice get swap status for internal swap
    function getRangeOrderState(
        address fromToken,
        address toToken
    ) public view returns (Types.RangeOrderState memory roState) {
        roState.oracle = state._ORACLE_;
        uint256 fromTokenIndex;
        uint256 toTokenIndex;
        (roState.fromTokenMMInfo, fromTokenIndex) = ID3Maker(state._MAKER_).getTokenMMInfoForPool(fromToken);
        (roState.toTokenMMInfo, toTokenIndex) = ID3Maker(state._MAKER_).getTokenMMInfoForPool(toToken);

        // deal with update flag

        roState.fromTokenMMInfo.cumulativeAsk =
            allFlag >> (fromTokenIndex) & 1 == 0 ? 0 : tokenCumMap[fromToken].cumulativeAsk;
        roState.fromTokenMMInfo.cumulativeBid =
            allFlag >> (fromTokenIndex) & 1 == 0 ? 0 : tokenCumMap[fromToken].cumulativeBid;
        roState.toTokenMMInfo.cumulativeAsk =
            allFlag >> (toTokenIndex) & 1 == 0 ? 0 : tokenCumMap[toToken].cumulativeAsk;
        roState.toTokenMMInfo.cumulativeBid =
            allFlag >> (toTokenIndex) & 1 == 0 ? 0 : tokenCumMap[toToken].cumulativeBid;
    }

    /// @notice user sell a certain amount of fromToken,  get toToken
    function sellToken(
        address to,
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 minReceiveAmount,
        bytes calldata data
    ) external poolOngoing nonReentrant returns (uint256) {
        require(ID3Maker(state._MAKER_).checkHeartbeat(), Errors.HEARTBEAT_CHECK_FAIL);

        _updateCumulative(fromToken);
        _updateCumulative(toToken);

        (uint256 payFromAmount, uint256 receiveToAmount, uint256 vusdAmount, uint256 swapFee, uint256 mtFee) =
            querySellTokens(fromToken, toToken, fromAmount);
        require(receiveToAmount >= minReceiveAmount, Errors.MINRES_NOT_ENOUGH);

        _transferOut(to, toToken, receiveToAmount);

        // external call & swap callback
        IDODOSwapCallback(msg.sender).d3MMSwapCallBack(fromToken, fromAmount, data);
        // transfer mtFee to maintainer
        if(mtFee > 0) {
            _transferOut(state._MAINTAINER_, toToken, mtFee);
        }

        require(
            IERC20(fromToken).balanceOf(address(this)) - state.balances[fromToken] >= fromAmount,
            Errors.FROMAMOUNT_NOT_ENOUGH
        );

        // record swap
        uint256 toTokenDec = IERC20Metadata(toToken).decimals();
        _recordSwap(fromToken, toToken, vusdAmount, Types.parseRealAmount(receiveToAmount + swapFee, toTokenDec));
        require(checkSafe(), Errors.BELOW_IM_RATIO);

        emit Swap(to, fromToken, toToken, payFromAmount, receiveToAmount, swapFee, mtFee, 0);
        return receiveToAmount;
    }

    /// @notice user ask for a certain amount of toToken, fromToken's amount will be determined by toToken's amount
    function buyToken(
        address to,
        address fromToken,
        address toToken,
        uint256 quoteAmount,
        uint256 maxPayAmount,
        bytes calldata data
    ) external poolOngoing nonReentrant returns (uint256) {
        require(ID3Maker(state._MAKER_).checkHeartbeat(), Errors.HEARTBEAT_CHECK_FAIL);

        _updateCumulative(fromToken);
        _updateCumulative(toToken);

        // query amount and transfer out
        (uint256 payFromAmount, uint256 receiveToAmount, uint256 vusdAmount, uint256 swapFee, uint256 mtFee) =
            queryBuyTokens(fromToken, toToken, quoteAmount);
        require(payFromAmount <= maxPayAmount, Errors.MAXPAY_NOT_ENOUGH);

        _transferOut(to, toToken, receiveToAmount);

        // external call & swap callback
        IDODOSwapCallback(msg.sender).d3MMSwapCallBack(fromToken, payFromAmount, data);
        // transfer mtFee to maintainer
        if(mtFee > 0 ) {
            _transferOut(state._MAINTAINER_, toToken, mtFee);
        }

        require(
            IERC20(fromToken).balanceOf(address(this)) - state.balances[fromToken] >= payFromAmount,
            Errors.FROMAMOUNT_NOT_ENOUGH
        );

        // record swap
        uint256 toTokenDec = IERC20Metadata(toToken).decimals();
        _recordSwap(fromToken, toToken, vusdAmount, Types.parseRealAmount(receiveToAmount + swapFee, toTokenDec));
        require(checkSafe(), Errors.BELOW_IM_RATIO);

        emit Swap(to, fromToken, toToken, payFromAmount, receiveToAmount, swapFee, mtFee, 1);
        return payFromAmount;
    }

    /// @notice user could query sellToken result deducted swapFee, assign fromAmount
    /// @return payFromAmount fromToken's amount = fromAmount
    /// @return receiveToAmount toToken's amount
    /// @return vusdAmount fromToken bid vusd
    /// @return swapFee dodo takes the fee
    function querySellTokens(
        address fromToken,
        address toToken,
        uint256 fromAmount
    ) public view returns (uint256 payFromAmount, uint256 receiveToAmount, uint256 vusdAmount, uint256 swapFee, uint256 mtFee) {
        require(fromAmount > 1000, Errors.AMOUNT_TOO_SMALL);
        Types.RangeOrderState memory D3State = getRangeOrderState(fromToken, toToken);

        {
        uint256 fromTokenDec = IERC20Metadata(fromToken).decimals();
        uint256 toTokenDec = IERC20Metadata(toToken).decimals();
        uint256 fromAmountWithDec18 = Types.parseRealAmount(fromAmount, fromTokenDec);
        uint256 receiveToAmountWithDec18;
        ( , receiveToAmountWithDec18, vusdAmount) =
            PMMRangeOrder.querySellTokens(D3State, fromToken, toToken, fromAmountWithDec18);

        receiveToAmount = Types.parseDec18Amount(receiveToAmountWithDec18, toTokenDec);
        payFromAmount = fromAmount;
        }

        receiveToAmount = receiveToAmount > state.balances[toToken] ? state.balances[toToken] : receiveToAmount;

        uint256 swapFeeRate = D3State.fromTokenMMInfo.swapFeeRate +  D3State.toTokenMMInfo.swapFeeRate;
        swapFee = DecimalMath.mulFloor(receiveToAmount, swapFeeRate);
        uint256 mtFeeRate = D3State.fromTokenMMInfo.mtFeeRate +  D3State.toTokenMMInfo.mtFeeRate;
        mtFee = DecimalMath.mulFloor(receiveToAmount, mtFeeRate);

        return (payFromAmount, receiveToAmount - mtFee, vusdAmount, swapFee, mtFee);
    }

    /// @notice user could query sellToken result deducted swapFee, assign toAmount
    /// @return payFromAmount fromToken's amount
    /// @return receiveToAmount toToken's amount = toAmount
    /// @return vusdAmount fromToken bid vusd
    /// @return swapFee dodo takes the fee
    function queryBuyTokens(
        address fromToken,
        address toToken,
        uint256 toAmount
    ) public view returns (uint256 payFromAmount, uint256 receiveToAmount, uint256 vusdAmount, uint256 swapFee, uint256 mtFee) {
        require(toAmount > 1000, Errors.AMOUNT_TOO_SMALL);
        Types.RangeOrderState memory D3State = getRangeOrderState(fromToken, toToken);

        // query amount and transfer out
        uint256 toAmountWithFee;
        {
        uint256 swapFeeRate = D3State.fromTokenMMInfo.swapFeeRate +  D3State.toTokenMMInfo.swapFeeRate;
        swapFee = DecimalMath.mulFloor(toAmount, swapFeeRate);
        uint256 mtFeeRate = D3State.fromTokenMMInfo.mtFeeRate +  D3State.toTokenMMInfo.mtFeeRate;
        mtFee = DecimalMath.mulFloor(toAmount, mtFeeRate);
        toAmountWithFee = toAmount + mtFee;
        }

        require(toAmountWithFee <= state.balances[toToken], Errors.BALANCE_NOT_ENOUGH);

        uint256 fromTokenDec = IERC20Metadata(fromToken).decimals();
        uint256 toTokenDec = IERC20Metadata(toToken).decimals();
        uint256 toFeeAmountWithDec18 = Types.parseRealAmount(toAmountWithFee, toTokenDec);
        uint256 payFromAmountWithDec18;
        (payFromAmountWithDec18, , vusdAmount) =
            PMMRangeOrder.queryBuyTokens(D3State, fromToken, toToken, toFeeAmountWithDec18);
        payFromAmount = Types.parseDec18Amount(payFromAmountWithDec18, fromTokenDec);
        if(payFromAmount == 0) {
            payFromAmount = 1;
        }

        return (payFromAmount, toAmount, vusdAmount, swapFee, mtFee);
    }

    // ================ internal ==========================

    function _recordSwap(address fromToken, address toToken, uint256 fromAmount, uint256 toAmount) internal {
        tokenCumMap[fromToken].cumulativeBid += fromAmount;
        tokenCumMap[toToken].cumulativeAsk += toAmount;

        _updateReserve(fromToken);
        _updateReserve(toToken);
    }

    function _updateCumulative(address token) internal {
        uint256 tokenIndex = uint256(ID3Maker(state._MAKER_).getOneTokenOriginIndex(token));
        uint256 tokenFlag = (allFlag >> tokenIndex) & 1;
        if (tokenFlag == 0) {
            tokenCumMap[token].cumulativeAsk = 0;
            tokenCumMap[token].cumulativeBid = 0;
            allFlag |= (1 << tokenIndex);
        }
    }

    function _transferOut(address to, address token, uint256 amount) internal {
        IERC20(token).safeTransfer(to, amount);
    }

    // ================ call by maker ==========================
    function setNewAllFlag(uint256 newFlag) external onlyMaker {
        allFlag = newFlag;
    }
}
pragma solidity 0.8.16;

import "./D3VaultFunding.sol";
import "./D3VaultLiquidation.sol";

contract D3Vault is D3VaultFunding, D3VaultLiquidation {
    using SafeERC20 for IERC20;
    using DecimalMath for uint256;

    // ---------- Setting ----------

    function addD3PoolByFactory(address pool) external onlyFactory {
        require(allPoolAddrMap[pool] == false, Errors.POOL_ALREADY_ADDED);
        allPoolAddrMap[pool] = true;
        address creator = ID3MM(pool)._CREATOR_();
        creatorPoolMap[creator].push(pool);
        emit AddPool(pool);
    }

    function addD3Pool(address pool) external onlyOwner {
        require(allPoolAddrMap[pool] == false, Errors.POOL_ALREADY_ADDED);
        allPoolAddrMap[pool] = true;
        address creator = ID3MM(pool)._CREATOR_();
        creatorPoolMap[creator].push(pool);
        emit AddPool(pool);
    }

    // ================= Remove Pool Steps ===================

    /// @notice When removing a pool
    /// @notice if the pool has enough assets to repay all borrows, we can just repay:
    /// @notice removeD3Pool() -> pendingRemovePoolRepayAll(token) -> finishPoolRemove()
    /// @notice if not, should go through liquidation process by DODO before repaying token:
    /// @notice removeD3Pool() -> liquidateByDODO() -> pendingRemovePoolRepayAll(token) -> finishPoolRemove()
    /// @notice if the pool has bad debt, then should go through normal liquidation process instead of repaying token
    /// @notice startLiquidation() -> liquidateByDODO() -> finishLiquidation()
    /// @notice if the pool doesn't have borrows, we just need two steps:
    /// @notice removeD3Pool() -> finishPoolRemove()
    function removeD3Pool(address pool) external onlyOwner {
        require(_PENDING_REMOVE_POOL_ == address(0), Errors.HAS_POOL_PENDING_REMOVE);
        require(allPoolAddrMap[pool] == true, Errors.POOL_NOT_ADDED);
        ID3MM(pool).startLiquidation();

        allPoolAddrMap[pool] = false;
        _PENDING_REMOVE_POOL_ = pool;
        address creator = ID3MM(pool)._CREATOR_();
        address[] memory poolList = creatorPoolMap[creator];
        for (uint256 i = 0; i < poolList.length; i++) {
            if (poolList[i] == pool) {
                poolList[i] = poolList[poolList.length - 1];
                creatorPoolMap[creator] = poolList;
                creatorPoolMap[creator].pop();
                break;
            }
        }
    }

    function pendingRemovePoolRepayAll(address token) external onlyOwner {
        _poolRepayAll(_PENDING_REMOVE_POOL_, token);
        ID3MM(_PENDING_REMOVE_POOL_).updateReserveByVault(token);
    }

    function finishPoolRemove() external onlyOwner {
        ID3MM(_PENDING_REMOVE_POOL_).finishLiquidation();
        emit RemovePool(_PENDING_REMOVE_POOL_);
        _PENDING_REMOVE_POOL_ = address(0);
    }

    // ====================================================

    function setCloneFactory(address cloneFactory) external onlyOwner {
        _CLONE_FACTORY_ = cloneFactory;
        emit SetCloneFactory(cloneFactory);
    }

    function setNewD3Factory(address newFactory) external onlyOwner {
        _D3_FACTORY_ = newFactory;
        emit SetD3Factory(newFactory);
    }

    function setNewD3UserQuota(address newQuota) external onlyOwner {
        _USER_QUOTA_ = newQuota;
        emit SetD3UserQuota(newQuota);
    }

    function setNewD3PoolQuota(address newQuota) external onlyOwner {
        _POOL_QUOTA_ = newQuota;
        emit SetD3PoolQuota(newQuota);
    }

    function setNewOracle(address newOracle) external onlyOwner {
        _ORACLE_ = newOracle;
        emit SetOracle(newOracle);
    }

    function setNewRateManager(address newRateManager) external onlyOwner {
        _RATE_MANAGER_ = newRateManager;
        emit SetRateManager(newRateManager);
    }

    function setMaintainer(address maintainer) external onlyOwner {
        _MAINTAINER_ = maintainer;
        emit SetMaintainer(maintainer);
    }

    function setIM(uint256 newIM) external onlyOwner {
        IM = newIM;
        emit SetIM(newIM);
    }

    function setMM(uint256 newMM) external onlyOwner {
        MM = newMM;
        emit SetMM(newMM);
    }

    function setDiscount(uint256 discount) external onlyOwner {
        DISCOUNT = discount;
        emit SetDiscount(discount);
    }

    function setDTokenTemplate(address dTokenTemplate) external onlyOwner {
        _D3TOKEN_LOGIC_ = dTokenTemplate;
        emit SetDTokenTemplate(dTokenTemplate);
    }

    function addRouter(address router) external onlyOwner {
        allowedRouter[router] = true;
        emit AddRouter(router);
    }

    function removeRouter(address router) external onlyOwner {
        allowedRouter[router] = false;
        emit RemoveRouter(router);
    }

    function addLiquidator(address liquidator) external onlyOwner {
        allowedLiquidator[liquidator] = true;
        emit AddLiquidator(liquidator);
    }

    function removeLiquidator(address liquidator) external onlyOwner {
        allowedLiquidator[liquidator] = false;
        emit RemoveLiquidator(liquidator);
    }

    function addNewToken(
        address token,
        uint256 maxDeposit,
        uint256 maxCollateral,
        uint256 collateralWeight,
        uint256 debtWeight,
        uint256 reserveFactor
    ) external onlyOwner {
        require(!tokens[token], Errors.TOKEN_ALREADY_EXIST);
        require(collateralWeight < 1e18 && debtWeight > 1e18, Errors.WRONG_WEIGHT);
        require(reserveFactor < 1e18, Errors.WRONG_RESERVE_FACTOR);
        tokens[token] = true;
        tokenList.push(token);
        address dToken = createDToken(token);
        AssetInfo storage info = assetInfo[token];
        info.dToken = dToken;
        info.reserveFactor = reserveFactor;
        info.borrowIndex = 1e18;
        info.accrualTime = block.timestamp;
        info.maxDepositAmount = maxDeposit;
        info.maxCollateralAmount = maxCollateral;
        info.collateralWeight = collateralWeight;
        info.debtWeight = debtWeight;
        emit AddToken(token);
    }

    function createDToken(address token) internal returns (address) {
        address d3Token = ICloneFactory(_CLONE_FACTORY_).clone(_D3TOKEN_LOGIC_);
        IDToken(d3Token).init(token, address(this));
        return d3Token;
    }

    function setToken(
        address token,
        uint256 maxDeposit,
        uint256 maxCollateral,
        uint256 collateralWeight,
        uint256 debtWeight,
        uint256 reserveFactor
    ) external onlyOwner {
        require(tokens[token], Errors.TOKEN_NOT_EXIST);
        require(collateralWeight < 1e18 && debtWeight > 1e18, Errors.WRONG_WEIGHT);
        require(reserveFactor < 1e18, Errors.WRONG_RESERVE_FACTOR);
        AssetInfo storage info = assetInfo[token];
        info.maxDepositAmount = maxDeposit;
        info.maxCollateralAmount = maxCollateral;
        info.collateralWeight = collateralWeight;
        info.debtWeight = debtWeight;
        info.reserveFactor = reserveFactor;
        emit SetToken(token);
    }

    function withdrawReserves(address token, uint256 amount) external nonReentrant allowedToken(token) onlyOwner {
        require(_MAINTAINER_ != address(0), Errors.MAINTAINER_NOT_SET);
        accrueInterest(token);
        AssetInfo storage info = assetInfo[token];
        uint256 totalReserves = info.totalReserves;
        uint256 withdrawnReserves = info.withdrawnReserves;
        require(amount <= totalReserves - withdrawnReserves, Errors.WITHDRAW_AMOUNT_EXCEED);
        info.withdrawnReserves = info.withdrawnReserves + amount;
        info.balance = info.balance - amount;
        IERC20(token).safeTransfer(_MAINTAINER_, amount);
        emit WithdrawReserves(token, amount);
    }

    /// @notice If someone directly transfer large amounts of a token into vault, may block the userDeposit() function
    /// @notice Owner can use this function to transfer out the token to unblock deposition.
    // function withdrawLeft(address token) external nonReentrant allowedToken(token) onlyOwner {
    //     require(_MAINTAINER_ != address(0), Errors.MAINTAINER_NOT_SET);
    //     AssetInfo storage info = assetInfo[token];
    //     uint256 balance = IERC20(token).balanceOf(address(this));
    //     if (balance > info.balance) {
    //         IERC20(token).safeTransfer(_MAINTAINER_, balance - info.balance);
    //     }
    // }

    // ---------- View ----------

    function getAssetInfo(address token)
        external
        view
        returns (
            address dToken,
            uint256 totalBorrows,
            uint256 totalReserves,
            uint256 reserveFactor,
            uint256 borrowIndex,
            uint256 accrualTime,
            uint256 maxDepositAmount,
            uint256 collateralWeight,
            uint256 debtWeight,
            uint256 withdrawnReserves,
            uint256 balance
        )
    {
        AssetInfo storage info = assetInfo[token];
        balance = info.balance;
        dToken = info.dToken;
        totalBorrows = info.totalBorrows;
        totalReserves = info.totalReserves;
        reserveFactor = info.reserveFactor;
        borrowIndex = info.borrowIndex;
        accrualTime = info.accrualTime;
        maxDepositAmount = info.maxDepositAmount;
        collateralWeight = info.collateralWeight;
        debtWeight = info.debtWeight;
        withdrawnReserves = info.withdrawnReserves;
    }

    function getIMMM() external view returns (uint256, uint256) {
        return (IM, MM);
    }

    function getTokenList() external view returns (address[] memory) {
        return tokenList;
    }
}
pragma solidity 0.8.16;

import {ICloneFactory} from "../lib/CloneFactory.sol";
import "./D3VaultStorage.sol";
import "../../intf/ID3Oracle.sol";
import "../intf/ID3UserQuota.sol";
import "../intf/ID3PoolQuota.sol";
import "../intf/ID3MM.sol";
import "../intf/IDToken.sol";
import "../intf/ID3RateManager.sol";

/// @title D3VaultFunding
/// @notice This contract defines the fund management of D3Vault.
/// @notice Users (LP) deposit funds into vault to earn interests; D3Pools borrows funds from vault to make market.
/// @notice Part of the borrow interests will become the reserve fund.
/// @notice The borrow interest rate is dynamicly changing with fund utilization ratio, and is caculated by D3RateManager.
/// @notice The fund utilization ratio is defined as U = borrows / (cash + borrows - reserves)
/// @notice Users who deposit funds into vault will receive certain amounts of corresponding dToken. The amount is calculated by the exchange rate.
/// @notice The exchange rate between dToken and underlying token is defined as exchangeRate = (cash + totalBorrows -reserves) / dTokenSupply
/// @notice As time passes, totalBorrows will increase, so does the dToken exchangeRate. That's how users earn interests with dToken.
contract D3VaultFunding is D3VaultStorage {
    using SafeERC20 for IERC20;
    using DecimalMath for uint256;

    // ---------- LP user Fund ----------

    /// @notice user should transfer token to vault before call this function
    function userDeposit(address user, address token) external nonReentrant allowedToken(token) returns(uint256 dTokenAmount) {
        accrueInterest(token);

        AssetInfo storage info = assetInfo[token];
        uint256 realBalance = IERC20(token).balanceOf(address(this));
        uint256 amount = realBalance  - info.balance;
        require(ID3UserQuota(_USER_QUOTA_).checkQuota(user, token, amount), Errors.EXCEED_QUOTA);
        uint256 exchangeRate = _getExchangeRate(token);
        uint256 totalDToken = IDToken(info.dToken).totalSupply();
        require(totalDToken.mul(exchangeRate) + amount <= info.maxDepositAmount, Errors.EXCEED_MAX_DEPOSIT_AMOUNT);
        dTokenAmount = amount.div(exchangeRate);

        IDToken(info.dToken).mint(user, dTokenAmount);
        info.balance = realBalance;

        emit UserDeposit(user, token, amount, dTokenAmount);
    }

    /// @param to who receive tokens
    /// @param user who pay dTokens
    /// @param token original token address
    /// @param dTokenAmount dtoken the token record amount
    function userWithdraw(address to, address user, address token, uint256 dTokenAmount) external nonReentrant allowedToken(token) returns(uint256 amount) {
        accrueInterest(token);
        AssetInfo storage info = assetInfo[token];
        require(dTokenAmount <= IDToken(info.dToken).balanceOf(msg.sender), Errors.DTOKEN_BALANCE_NOT_ENOUGH);

        amount = dTokenAmount.mul(_getExchangeRate(token));
        IDToken(info.dToken).burn(msg.sender, dTokenAmount);
        IERC20(token).safeTransfer(to, amount);
        info.balance = info.balance - amount;

        // used for calculate user withdraw amount
        // this function could be called from d3Proxy, so we need "user" param
        // In the meantime, some users may hope to use this function directly,
        // to prevent these users fill "user" param with wrong addresses,
        // we use "msg.sender" param to check.
        emit UserWithdraw(msg.sender, user, token, amount, dTokenAmount);
    }

    // ---------- Pool Fund ----------
    function poolBorrow(address token, uint256 amount) external nonReentrant allowedToken(token) onlyPool {
        uint256 quota = ID3PoolQuota(_POOL_QUOTA_).getPoolQuota(msg.sender, token);
        accrueInterest(token);

        AssetInfo storage info = assetInfo[token];
        BorrowRecord storage record = info.borrowRecord[msg.sender];
        uint256 usedQuota = _borrowAmount(record.amount, record.interestIndex, info.borrowIndex); // borrowAmount = record.amount * newIndex / oldIndex
        require(amount + usedQuota <= quota, Errors.EXCEED_QUOTA);
        require(amount <= info.balance - (info.totalReserves - info.withdrawnReserves), Errors.AMOUNT_EXCEED_VAULT_BALANCE);

        uint256 interests = usedQuota - record.amount;

        record.amount = usedQuota + amount;
        record.interestIndex = info.borrowIndex;
        info.totalBorrows = info.totalBorrows + amount;
        info.balance = info.balance - amount; 
        IERC20(token).safeTransfer(msg.sender, amount);

        emit PoolBorrow(msg.sender, token, amount, interests);
    }

    function poolRepay(address token, uint256 amount) external nonReentrant allowedToken(token) onlyPool {
        require(!ID3MM(msg.sender).isInLiquidation(), Errors.ALREADY_IN_LIQUIDATION);

        accrueInterest(token);

        AssetInfo storage info = assetInfo[token];
        BorrowRecord storage record = info.borrowRecord[msg.sender];
        uint256 borrows = _borrowAmount(record.amount, record.interestIndex, info.borrowIndex); // borrowAmount = record.amount * newIndex / oldIndex
        require(amount <= borrows, Errors.AMOUNT_EXCEED);

        uint256 interests = borrows - record.amount;

        record.amount = borrows - amount;
        record.interestIndex = info.borrowIndex;
        if (info.totalBorrows < amount) {
            info.totalBorrows = 0;
        } else {
            info.totalBorrows = info.totalBorrows - amount;
        }
        info.balance = info.balance + amount;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit PoolRepay(msg.sender, token, amount, interests);
    }

    function poolRepayAll(address token) external nonReentrant allowedToken(token) onlyPool {
        require(!ID3MM(msg.sender).isInLiquidation(), Errors.ALREADY_IN_LIQUIDATION);
        _poolRepayAll(msg.sender, token);
    }

    function _poolRepayAll(address pool, address token) internal {
        accrueInterest(token);

        AssetInfo storage info = assetInfo[token];
        BorrowRecord storage record = info.borrowRecord[pool];
        uint256 amount = _borrowAmount(record.amount, record.interestIndex, info.borrowIndex); // borrowAmount = record.amount * newIndex / oldIndex

        uint256 interests = amount - record.amount;

        record.amount = 0;
        record.interestIndex = info.borrowIndex;
        if (info.totalBorrows < amount) {
            info.totalBorrows = 0;
        } else {
            info.totalBorrows = info.totalBorrows - amount;
        }
        info.balance = info.balance + amount;
        IERC20(token).safeTransferFrom(pool, address(this), amount);

        emit PoolRepay(pool, token, amount, interests);
    }

    // ---------- Interest ----------

    /// @notice Accrue interest for a token
    /// @notice Step1: get time past
    /// @notice Step2: get borrow rate
    /// @notice Step3: calculate compound interest rate during the past time
    /// @notice Step4: calculate increased borrows, reserves
    /// @notice Step5: update borrows, reserves, accrual time, borrowIndex
    /// @notice borrowIndex is the accrual interest rate
    function accrueInterestForRead(address token) public view returns(uint256 totalBorrowsNew, uint256 totalReservesNew, uint256 borrowIndexNew, uint256 accrualTime) {
        AssetInfo storage info = assetInfo[token];

        uint256 currentTime = block.timestamp;
        uint256 deltaTime = currentTime - info.accrualTime;
        if (deltaTime == 0) return(info.totalBorrows, info.totalReserves, info.borrowIndex, currentTime);

        uint256 borrowsPrior = info.totalBorrows;
        uint256 reservesPrior = info.totalReserves;
        uint256 borrowIndexPrior = info.borrowIndex;

        uint256 borrowRate = ID3RateManager(_RATE_MANAGER_).getBorrowRate(token, getUtilizationRatio(token));
        uint256 borrowRatePerSecond = borrowRate / SECONDS_PER_YEAR;
        uint256 compoundInterestRate = getCompoundInterestRate(borrowRatePerSecond, deltaTime);
        totalBorrowsNew = borrowsPrior.mul(compoundInterestRate);
        totalReservesNew = reservesPrior + (totalBorrowsNew - borrowsPrior).mul(info.reserveFactor);
        borrowIndexNew = borrowIndexPrior.mul(compoundInterestRate);

        accrualTime = currentTime;
    }

    /// @notice Accrue interest for a token, change storage
    function accrueInterest(address token) public {
        (assetInfo[token].totalBorrows, assetInfo[token].totalReserves, assetInfo[token].borrowIndex, assetInfo[token].accrualTime) =
        accrueInterestForRead(token);
    }

    function accrueInterests() public {
        for (uint256 i; i < tokenList.length; i++) {
            address token = tokenList[i];
            accrueInterest(token);
        }
    }

    /// @dev r: interest rate per second (decimals 18)
    /// @dev t: total time in seconds
    /// @dev (1+r)^t = 1 + rt + t*(t-1)*r^2/2! + t*(t-1)*(t-2)*r^3/3! + ... + t*(t-1)...*(t-n+1)*r^n/n!
    function getCompoundInterestRate(uint256 r, uint256 t) public pure returns (uint256) {
        if (t < 1) {
            return 1e18;
        } else if (t < 2) {
            return 1e18 + r * t;
        } else {
            return 1e18 + r * t + r.powFloor(2) * t * (t - 1) / 2;
        }
    }

    // ----------- View ----------

    function getPoolLeftQuota(address pool, address token) public view returns(uint256 leftQuota) {
        uint256 quota = ID3PoolQuota(_POOL_QUOTA_).getPoolQuota(pool, token);
        uint256 oldInterestIndex = assetInfo[token].borrowRecord[pool].interestIndex;
        ( , ,uint256 currentInterestIndex, ) = accrueInterestForRead(token);
        uint256 usedQuota = _borrowAmount(assetInfo[token].borrowRecord[pool].amount, oldInterestIndex, currentInterestIndex); // borrowAmount = record.amount * newIndex / oldIndex
        leftQuota = quota > usedQuota ? quota - usedQuota : 0;
    }

    /// @notice U = borrows / (cash + borrows - reserves)
    function getUtilizationRatio(address token) public view returns (uint256) {
        uint256 borrows = getTotalBorrows(token);
        uint256 cash = getCash(token);
        uint256 reserves = getReservesInVault(token);
        if (borrows == 0) return 0;
        if (cash + borrows <= reserves) return 1e18;    // Utilization Ratio is 100%
        return borrows.div(cash + borrows - reserves);
    }

    function getBorrowRate(address token) public view returns (uint256 rate) {
        rate = ID3RateManager(_RATE_MANAGER_).getBorrowRate(token, getUtilizationRatio(token));
    }

    function getCash(address token) public view returns (uint256) {
        return assetInfo[token].balance;
    }

    function getTotalBorrows(address token) public view returns (uint256) {
        return assetInfo[token].totalBorrows;
    }

    function getReservesInVault(address token) public view returns (uint256) {
        AssetInfo storage info = assetInfo[token];
        return info.totalReserves - info.withdrawnReserves;
    }

    /// @notice exchangeRate = (cash + totalBorrows -reserves) / dTokenSupply
    /// @notice Make sure accrueInterests or accrueInterest(token) is called before
    function _getExchangeRate(address token) internal view returns (uint256) {
        AssetInfo storage info = assetInfo[token];
        uint256 cash = getCash(token);
        uint256 dTokenSupply = IERC20(info.dToken).totalSupply();
        if (dTokenSupply == 0) { return 1e18; }
        return (cash + info.totalBorrows - (info.totalReserves - info.withdrawnReserves)).div(dTokenSupply);
    } 

    /// @notice Make sure accrueInterests or accrueInterest(token) is called before
    function _getBalanceAndBorrows(address pool, address token) internal view returns (uint256, uint256) {
        AssetInfo storage info = assetInfo[token];
        BorrowRecord storage record = info.borrowRecord[pool];

        uint256 balance = ID3MM(pool).getTokenReserve(token);
        uint256 borrows = _borrowAmount(record.amount, record.interestIndex, info.borrowIndex); // borrowAmount = record.amount * newIndex / oldIndex

        return (balance, borrows);
    }

    /// @notice Make sure accrueInterests() is called before calling this function
    function _getTotalDebtValue(address pool) internal view returns (uint256 totalDebt) {
        for (uint256 i = 0; i < tokenList.length; i++) {
            address token = tokenList[i];
            AssetInfo storage info = assetInfo[token];
            BorrowRecord memory record = info.borrowRecord[pool];
            uint256 borrows = _borrowAmount(record.amount, record.interestIndex, info.borrowIndex); // borrowAmount = record.amount * newIndex / oldIndex
            uint256 price = ID3Oracle(_ORACLE_).getPrice(token);
            totalDebt += borrows.mul(price);
        }
    }

    function getTotalAssetsValue(address pool) public view returns (uint256 totalValue) {
        for (uint256 i = 0; i < tokenList.length; i++) {
            address token = tokenList[i];
            uint256 price = ID3Oracle(_ORACLE_).getPrice(token);
            totalValue += DecimalMath.mul(ID3MM(pool).getTokenReserve(token), price);
        }
    }

    /// @notice Make sure accrueInterests() is called before
    /// @notice net = balance - borrowed
    /// @notice collateral = sum(min(positive net, maxCollateralAmount）* weight * price)
    /// @notice debt = sum(negative net * weight * price)
    /// @notice collateralRatio = collateral / debt
    function _getCollateralRatio(address pool) internal view returns (uint256) {
        uint256 collateral = 0;
        uint256 debt = 0;
        for (uint256 i; i < tokenList.length; i++) {
            address token = tokenList[i];
            AssetInfo storage info = assetInfo[token];

            (uint256 balance, uint256 borrows) = _getBalanceAndBorrows(pool, token);
            uint256 price = ID3Oracle(_ORACLE_).getPrice(token);
            if (balance >= borrows) {
                collateral += min(balance - borrows, info.maxCollateralAmount).mul(info.collateralWeight).mul(price);
            } else {
                debt += (borrows - balance).mul(info.debtWeight).mul(price);
            }
        }
        return _ratioDiv(collateral, debt);
    }

    function checkSafe(address pool) public view returns (bool) {
        return getCollateralRatio(pool) >  1e18 + IM;
    }

    function checkBorrowSafe(address pool) public view returns (bool) {
        return getCollateralRatioBorrow(pool) > IM;
    }

    function checkCanBeLiquidated(address pool) public view returns (bool) {
        return getCollateralRatio(pool) < 1e18 + MM;
    }

    function checkCanBeLiquidatedAfterAccrue(address pool) public view returns (bool) {
        return _getCollateralRatio(pool) < 1e18 + MM;
    }

    function checkBadDebt(address pool) public view returns (bool) {
        uint256 totalAssetValue = getTotalAssetsValue(pool);
        uint256 totalDebtValue = getTotalDebtValue(pool);
        return totalAssetValue < totalDebtValue;
    }

    function checkBadDebtAfterAccrue(address pool) public view returns (bool) {
        uint256 totalAssetValue = getTotalAssetsValue(pool);
        uint256 totalDebtValue = _getTotalDebtValue(pool);
        return totalAssetValue < totalDebtValue;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a <= b ? a : b;
    }

    function _ratioDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 && b == 0) {
            return 1e18;
        } else if (a == 0 && b != 0) {
            return 0;
        } else if (a != 0 && b == 0) {
            return type(uint256).max;
        } else {
            return a.div(b);
        }
    }

    function _borrowAmount(uint256 amount, uint256 oldIndex, uint256 newIndex) internal pure returns (uint256) {
        if (oldIndex == 0) { oldIndex = 1e18; }
        if (oldIndex > newIndex) { oldIndex = newIndex; }
        return amount * newIndex / oldIndex;
    }

    // ======================= Read Only =======================

    function getExchangeRate(address token) public view returns(uint256 exchangeRate) {
        (uint256 totalBorrows, uint256 totalReserves, ,) = accrueInterestForRead(token);
        uint256 cash = getCash(token);
        uint256 dTokenSupply = IERC20(assetInfo[token].dToken).totalSupply();
        if (dTokenSupply == 0) { return 1e18; }
        exchangeRate = (cash + totalBorrows - (totalReserves - assetInfo[token].withdrawnReserves)).div(dTokenSupply);
    }

    function getLatestBorrowIndex(address token) public view returns (uint256 borrowIndex) {
        AssetInfo storage info = assetInfo[token];
        uint256 deltaTime = block.timestamp - info.accrualTime;
        uint256 borrowRate = getBorrowRate(token);
        uint256 borrowRatePerSecond = borrowRate / SECONDS_PER_YEAR;
        uint256 compoundInterestRate = getCompoundInterestRate(borrowRatePerSecond, deltaTime);
        borrowIndex = info.borrowIndex.mul(compoundInterestRate);
    }

    function getPoolBorrowAmount(address pool, address token) public view returns (uint256 amount) {
        BorrowRecord storage record = assetInfo[token].borrowRecord[pool];
        uint256 borrowIndex = getLatestBorrowIndex(token);
        amount = _borrowAmount(record.amount, record.interestIndex, borrowIndex); // borrowAmount = record.amount * newIndex / oldIndex
    }

    function getTotalDebtValue(address pool) public view returns (uint256 totalDebt) {
        for (uint256 i = 0; i < tokenList.length; i++) {
            address token = tokenList[i];
            uint256 borrowAmount = getPoolBorrowAmount(pool, token);
            uint256 price = ID3Oracle(_ORACLE_).getPrice(token);
            totalDebt += borrowAmount.mul(price);
        }
    }

    function getBalanceAndBorrows(address pool, address token) public view returns (uint256, uint256) {
        uint256 balance = ID3MM(pool).getTokenReserve(token);
        uint256 borrows = getPoolBorrowAmount(pool, token);
        return (balance, borrows);
    }

    function getCollateralRatio(address pool) public view returns (uint256) {
        uint256 collateral = 0;
        uint256 debt = 0;
        for (uint256 i; i < tokenList.length; i++) {
            address token = tokenList[i];
            AssetInfo storage info = assetInfo[token];

            (uint256 balance, uint256 borrows) = getBalanceAndBorrows(pool, token);
            uint256 price = ID3Oracle(_ORACLE_).getPrice(token);
            
            if (balance >= borrows) {
                collateral += min(balance - borrows, info.maxCollateralAmount).mul(info.collateralWeight).mul(price);
            } else {
                debt += (borrows - balance).mul(info.debtWeight).mul(price);
            }
        }
        return _ratioDiv(collateral, debt);
    }
    
    /// @notice collateralRatioBorrow = ∑[min(maxCollateralAmount，balance - borrows）] / ∑borrows
    function getCollateralRatioBorrow(address pool) public view returns (uint256) {
        uint256 balanceSumPositive = 0;
        uint256 balanceSumNegative = 0;
        uint256 borrowedSum = 0;
        for (uint256 i; i < tokenList.length; i++) {
            address token = tokenList[i];

            (uint256 balance, uint256 borrows) = getBalanceAndBorrows(pool, token);
            uint256 price = ID3Oracle(_ORACLE_).getPrice(token);

            if (balance >= borrows) {
                balanceSumPositive += min(balance - borrows, assetInfo[token].maxCollateralAmount).mul(price);
            } else {
                balanceSumNegative += (borrows - balance).mul(price);
            }

            borrowedSum += borrows.mul(price);
        }
        
        uint256 balanceSum = balanceSumPositive < balanceSumNegative ? 0 : balanceSumPositive - balanceSumNegative;
        return _ratioDiv(balanceSum, borrowedSum);
    }

    function getCumulativeBorrowRate(address pool, address token) external view returns (uint256 cumulativeRate, uint256 currentAmount) {
        BorrowRecord storage record = assetInfo[token].borrowRecord[pool];
        uint256 borrowIndex = getLatestBorrowIndex(token);
        cumulativeRate = borrowIndex.div(record.interestIndex == 0 ? 1e18 : record.interestIndex);
        currentAmount = record.amount;
    }
}
pragma solidity 0.8.16;

import "./D3VaultFunding.sol";

contract D3VaultLiquidation is D3VaultFunding {
    using SafeERC20 for IERC20;
    using DecimalMath for uint256;

    function isPositiveNetWorthAsset(address pool, address token) internal view returns (bool) {
        (uint256 balance, uint256 borrows) = _getBalanceAndBorrows(pool, token);
        return balance >= borrows;
    }

    function getPositiveNetWorthAsset(address pool, address token) internal view returns (uint256) {
        (uint256 balance, uint256 borrows) = _getBalanceAndBorrows(pool, token);
        if (balance > borrows) {
            return balance - borrows;
        } else {
            return 0;
        }
    }

    /// @notice public liquidate function, repay pool negative worth token and get collateral tokens with discount
    /// @param pool pool address, must be in belowMM
    /// @param collateral pool collateral, any positive worth token pool has
    /// @param collateralAmount collateral amount liquidator claim
    /// @param debt pool debt, any negative worth token pool has
    /// @param debtToCover debt amount liquidator repay
    function liquidate(
        address pool,
        address collateral,
        uint256 collateralAmount,
        address debt,
        uint256 debtToCover
    ) external nonReentrant {
        accrueInterests();

        require(!ID3MM(pool).isInLiquidation(), Errors.ALREADY_IN_LIQUIDATION);
        require(!checkBadDebtAfterAccrue(pool), Errors.HAS_BAD_DEBT);
        require(checkCanBeLiquidatedAfterAccrue(pool), Errors.CANNOT_BE_LIQUIDATED);
        require(isPositiveNetWorthAsset(pool, collateral), Errors.INVALID_COLLATERAL_TOKEN);
        require(!isPositiveNetWorthAsset(pool, debt), Errors.INVALID_DEBT_TOKEN);
        require(getPositiveNetWorthAsset(pool, collateral) >= collateralAmount, Errors.COLLATERAL_AMOUNT_EXCEED);
        
        uint256 collateralTokenPrice = ID3Oracle(_ORACLE_).getPrice(collateral);
        uint256 debtTokenPrice = ID3Oracle(_ORACLE_).getPrice(debt);
        uint256 collateralAmountMax = debtToCover.mul(debtTokenPrice).div(collateralTokenPrice.mul(DISCOUNT));
        require(collateralAmount <= collateralAmountMax, Errors.COLLATERAL_AMOUNT_EXCEED);

        AssetInfo storage info = assetInfo[debt];
        BorrowRecord storage record = info.borrowRecord[pool];
        uint256 borrows = _borrowAmount(record.amount, record.interestIndex, info.borrowIndex); // borrowAmount = record.amount * newIndex / oldIndex
        require(debtToCover <= borrows, Errors.DEBT_TO_COVER_EXCEED);
        IERC20(debt).safeTransferFrom(msg.sender, address(this), debtToCover);
        
        if (info.totalBorrows < debtToCover) {
            info.totalBorrows = 0;
        } else {
            info.totalBorrows = info.totalBorrows - debtToCover;
        }
        info.balance = info.balance + debtToCover;

        record.amount = borrows - debtToCover;
        record.interestIndex = info.borrowIndex;
        IERC20(collateral).safeTransferFrom(pool, msg.sender, collateralAmount);
        ID3MM(pool).updateReserveByVault(collateral);
        
        emit Liquidate(pool, collateral, collateralAmount, debt, debtToCover);
    }

    // ---------- Liquidate by DODO team ----------
    /// @notice if occuring bad debt, dodo team will start liquidation to balance debt
    function startLiquidation(address pool) external onlyLiquidator nonReentrant {
        accrueInterests();

        require(!ID3MM(pool).isInLiquidation(), Errors.ALREADY_IN_LIQUIDATION);
        require(checkCanBeLiquidatedAfterAccrue(pool), Errors.CANNOT_BE_LIQUIDATED);
        ID3MM(pool).startLiquidation();

        uint256 totalAssetValue = getTotalAssetsValue(pool);
        uint256 totalDebtValue = _getTotalDebtValue(pool);
        require(totalAssetValue < totalDebtValue, Errors.NO_BAD_DEBT);

        uint256 ratio = totalAssetValue.div(totalDebtValue);

        for (uint256 i; i < tokenList.length; i++) {
            address token = tokenList[i];
            AssetInfo storage info = assetInfo[token];
            BorrowRecord storage record = info.borrowRecord[pool];
            uint256 debt = _borrowAmount(record.amount, record.interestIndex, info.borrowIndex).mul(ratio); // borrowAmount = record.amount * newIndex / oldIndex
            liquidationTarget[pool][token] = debt;
        }
        emit StartLiquidation(pool);
    }

    function liquidateByDODO(
        address pool,
        LiquidationOrder calldata order,
        bytes calldata routeData,
        address router
    ) external onlyLiquidator onlyRouter(router) nonReentrant {
        require(ID3MM(pool).isInLiquidation(), Errors.NOT_IN_LIQUIDATION);

        uint256 toTokenReserve = IERC20(order.toToken).balanceOf(address(this));
        uint256 fromTokenValue = DecimalMath.mul(ID3Oracle(_ORACLE_).getPrice(order.fromToken), order.fromAmount);

        // swap using Route
        {
            IERC20(order.fromToken).safeTransferFrom(pool, router, order.fromAmount);
            (bool success, bytes memory data) = router.call(routeData);
            if (!success) {
                assembly {
                    revert(add(data, 32), mload(data))
                }
            }
        }

        // the transferred-in toToken USD value should not be less than 95% of the transferred-out fromToken
        uint256 receivedToToken = IERC20(order.toToken).balanceOf(address(this)) - toTokenReserve;
        uint256 toTokenValue = DecimalMath.mul(ID3Oracle(_ORACLE_).getPrice(order.toToken), receivedToToken);

        require(toTokenValue >= fromTokenValue.mul(DISCOUNT), Errors.EXCEED_DISCOUNT);
        IERC20(order.toToken).safeTransfer(pool, receivedToToken);
        ID3MM(pool).updateReserveByVault(order.fromToken);
        ID3MM(pool).updateReserveByVault(order.toToken);
    }

    function finishLiquidation(address pool) external onlyLiquidator nonReentrant {
        require(ID3MM(pool).isInLiquidation(), Errors.NOT_IN_LIQUIDATION);
        accrueInterests();

        bool hasPositiveBalance;
        bool hasNegativeBalance;
        for (uint256 i; i < tokenList.length; i++) {
            address token = tokenList[i];
            AssetInfo storage info = assetInfo[token];
            uint256 balance = IERC20(token).balanceOf(pool);
            uint256 debt = liquidationTarget[pool][token];
            int256 difference = int256(balance) - int256(debt);
            if (difference > 0) {
                require(!hasNegativeBalance, Errors.LIQUIDATION_NOT_DONE);
                hasPositiveBalance = true;
            } else if (difference < 0) {
                require(!hasPositiveBalance, Errors.LIQUIDATION_NOT_DONE);
                hasNegativeBalance = true;
                debt = balance; // if balance is less than target amount, just repay with balance
            }

            BorrowRecord storage record = info.borrowRecord[pool];
            uint256 borrows = record.amount;
            if (borrows == 0) continue;

            // note: During liquidation process, the pool's debt will slightly increase due to the generated interests. 
            // The liquidation process will not repay the interests. Thus all dToken holders will share the loss equally.
            uint256 realDebt = _borrowAmount(borrows, record.interestIndex, info.borrowIndex); // borrowAmount = record.amount * newIndex / oldIndex
            IERC20(token).safeTransferFrom(pool, address(this), debt);

            if (info.totalBorrows < realDebt) {
                info.totalBorrows = 0;
            } else {
                info.totalBorrows = info.totalBorrows - realDebt;
            }
            info.balance = info.balance + debt;
            record.amount = 0;
        }

        ID3MM(pool).finishLiquidation();
        emit FinishLiquidation(pool);
    }
}
pragma solidity 0.8.16;

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "../lib/DecimalMath.sol";
import "./Errors.sol";

struct LiquidationOrder {
    address fromToken;
    address toToken;
    uint256 fromAmount;
}

contract D3VaultStorage is ReentrancyGuard, Ownable {
    address public _D3_FACTORY_;
    address public _D3TOKEN_LOGIC_;
    address public _CLONE_FACTORY_;
    address public _USER_QUOTA_;
    address public _POOL_QUOTA_;
    address public _ORACLE_;
    address public _RATE_MANAGER_;
    address public _MAINTAINER_;
    address public _PENDING_REMOVE_POOL_;
    address[] public tokenList;
    uint256 public IM; // 1e18 = 100%
    uint256 public MM; // 1e18 = 100%
    uint256 public DISCOUNT = 95e16; // 95%
    uint256 internal constant SECONDS_PER_YEAR = 31536000;

    mapping(address => uint256) public accrualTimestampMap;
    mapping(address => bool) public allPoolAddrMap;
    mapping(address => address[]) public creatorPoolMap; // user => pool[]
    mapping(address => bool) public tokens;
    mapping(address => AssetInfo) public assetInfo;
    mapping(address => bool) public allowedRouter;
    mapping(address => bool) public allowedLiquidator;
    mapping(address => mapping(address => uint256)) public liquidationTarget; // pool => (token => amount)

    struct AssetInfo {
        address dToken;
        uint256 balance;
        // borrow info
        uint256 totalBorrows;
        uint256 borrowIndex;
        uint256 accrualTime;
        // reserve info
        uint256 totalReserves;
        uint256 withdrawnReserves;
        uint256 reserveFactor;
        // other info
        uint256 maxDepositAmount;
        uint256 maxCollateralAmount; // the max amount of token that a pool can use as collateral
        uint256 collateralWeight; // 1e18 = 100%; collateralWeight < 1e18
        uint256 debtWeight; // 1e18 = 100%; debtWeight > 1e18
        mapping(address => BorrowRecord) borrowRecord; // pool address => BorrowRecord
    }

    struct BorrowRecord {
        uint256 amount;
        uint256 interestIndex;
    }

    event PoolBorrow(address indexed pool, address indexed token, uint256 amount, uint256 interests);
    event PoolRepay(address indexed pool, address indexed token, uint256 amount, uint256 interests);
    event UserDeposit(address indexed user, address indexed token, uint256 amount, uint256 dTokenAmount);
    event UserWithdraw(address indexed msgSender, address indexed user, address indexed token, uint256 amount, uint256 dTokenAmount);
    event AddPool(address pool);
    event RemovePool(address pool);

    event SetCloneFactory(address cloneFactory);
    event SetD3Factory(address factory);
    event SetD3UserQuota(address userQuota);
    event SetD3PoolQuota(address poolQuota);
    event SetOracle(address oracle);
    event SetRateManager(address rateManager);
    event SetMaintainer(address maintainer);
    event SetIM(uint256 IM);
    event SetMM(uint256 MM);
    event SetDiscount(uint256 discount);
    event SetDTokenTemplate(address template);
    
    event AddRouter(address router);
    event RemoveRouter(address router);
    
    event AddLiquidator(address liquidator);
    event RemoveLiquidator(address liquidator);
    
    event AddToken(address token);
    event SetToken(address token);

    event Liquidate(address indexed pool, address indexed collateral, uint256 collateralAmount, address indexed debt, uint256 debtAmount);
    event StartLiquidation(address pool);
    event FinishLiquidation(address pool);

    event WithdrawReserves(address indexed token, uint256 amount);

    modifier onlyLiquidator() {
        require(allowedLiquidator[msg.sender], Errors.NOT_ALLOWED_LIQUIDATOR);
        _;
    }

    modifier onlyRouter(address router) {
        require(allowedRouter[router], Errors.NOT_ALLOWED_ROUTER);
        _;
    }

    modifier onlyPool() {
        require(allPoolAddrMap[msg.sender], Errors.NOT_D3POOL);
        _;
    }

    modifier allowedToken(address token) {
        require(tokens[token], Errors.NOT_ALLOWED_TOKEN);
        _;
    }

    modifier onlyFactory() {
        require(msg.sender == _D3_FACTORY_, Errors.NOT_D3_FACTORY);
        _;
    }

    modifier onlyRemovingPool() {
        require(msg.sender == _PENDING_REMOVE_POOL_, Errors.NOT_PENDING_REMOVE_POOL);
        _;
    }
}
pragma solidity 0.8.16;

library Errors {
    string public constant POOL_ALREADY_ADDED = "D3VAULT_POOL_ALREADY_ADDED";
    string public constant POOL_NOT_ADDED = "D3VAULT_POOL_NOT_ADDED";
    string public constant HAS_POOL_PENDING_REMOVE = "D3VAULT_HAS_POOL_PENDING_REMOVE";
    string public constant AMOUNT_EXCEED_VAULT_BALANCE = "D3VAULT_AMOUNT_EXCEED_VAULT_BALANCE";
    string public constant NOT_ALLOWED_ROUTER = "D3VAULT_NOT_ALLOWED_ROUTER";
    string public constant NOT_ALLOWED_LIQUIDATOR = "D3VAULT_NOT_ALLOWED_LIQUIDATOR";
    string public constant NOT_PENDING_REMOVE_POOL = "D3VAULT_NOT_PENDING_REMOVE_POOL";
    string public constant NOT_D3POOL = "D3VAULT_NOT_D3POOL";
    string public constant NOT_ALLOWED_TOKEN = "D3VAULT_NOT_ALLOWED_TOKEN";
    string public constant NOT_D3_FACTORY = "D3VAULT_NOT_D3_FACTORY";
    string public constant TOKEN_ALREADY_EXIST = "D3VAULT_TOKEN_ALREADY_EXIST";
    string public constant TOKEN_NOT_EXIST = "D3VAULT_TOKEN_NOT_EXIST";
    string public constant WRONG_WEIGHT = "D3VAULT_WRONG_WEIGHT";
    string public constant WRONG_RESERVE_FACTOR = "D3VAULT_RESERVE_FACTOR";
    string public constant WITHDRAW_AMOUNT_EXCEED = "D3VAULT_WITHDRAW_AMOUNT_EXCEED";
    string public constant MAINTAINER_NOT_SET = "D3VAULT_MAINTAINER_NOT_SET";

    // ---------- funding ----------
    string public constant EXCEED_QUOTA = "D3VAULT_EXCEED_QUOTA";
    string public constant EXCEED_MAX_DEPOSIT_AMOUNT = "D3VAULT_EXCEED_MAX_DEPOSIT_AMOUNT";
    string public constant DTOKEN_BALANCE_NOT_ENOUGH = "D3TOKEN_BALANCE_NOT_ENOUGH";
    string public constant POOL_NOT_SAFE = "D3VAULT_POOL_NOT_SAFE";
    string public constant NOT_ENOUGH_COLLATERAL_FOR_BORROW = "D3VAULT_NOT_ENOUGH_COLLATERAL_FOR_BORROW";
    string public constant AMOUNT_EXCEED = "D3VAULT_AMOUNT_EXCEED";
    string public constant NOT_RATE_MANAGER = "D3VAULT_NOT_RATE_MANAGER";

    // ---------- liquidation ----------
    string public constant COLLATERAL_AMOUNT_EXCEED = "D3VAULT_COLLATERAL_AMOUNT_EXCEED";
    string public constant CANNOT_BE_LIQUIDATED = "D3VAULT_CANNOT_BE_LIQUIDATED";
    string public constant INVALID_COLLATERAL_TOKEN = "D3VAULT_INVALID_COLLATERAL_TOKEN";
    string public constant INVALID_DEBT_TOKEN = "D3VAULT_INVALID_DEBT_TOKEN";
    string public constant DEBT_TO_COVER_EXCEED = "D3VAULT_DEBT_TO_COVER_EXCEED";
    string public constant ALREADY_IN_LIQUIDATION = "D3VAULT_ALREADY_IN_LIQUIDATION";
    string public constant STILL_UNDER_MM = "D3VAULT_STILL_UNDER_MM";
    string public constant NO_BAD_DEBT = "D3VAULT_NO_BAD_DEBT";
    string public constant NOT_IN_LIQUIDATION = "D3VAULT_NOT_IN_LIQUIDATION";
    string public constant EXCEED_DISCOUNT = "D3VAULT_EXCEED_DISCOUNT";
    string public constant LIQUIDATION_NOT_DONE = "D3VAULT_LIQUIDATION_NOT_DONE";
    string public constant HAS_BAD_DEBT = "D3VAULT_HAS_BAD_DEBT";
}
pragma solidity 0.8.16;

import "@openzeppelin/contracts/access/Ownable.sol";

contract D3PoolQuota is Ownable {
    // token => bool
    mapping(address => bool) public isUsingQuota;
    // token => bool
    mapping(address => bool) public hasDefaultQuota;
    // token => quota
    mapping(address => uint256) public defaultQuota;
    // token => (pool => quota)
    mapping(address => mapping(address => uint256)) public poolQuota;

    /// @notice Set pool quota
    /// @param token The token address
    /// @param pools The list of pool addresses
    /// @param quotas The list of quota corresponding to the pool list
    function setPoolQuota(address token, address[] calldata pools, uint256[] calldata quotas) external onlyOwner {
        require(pools.length == quotas.length, "PARAMS_LENGTH_NOT_MATCH");
        for (uint256 i = 0; i < pools.length; i++) {
            poolQuota[token][pools[i]] = quotas[i];
        }
    }

    /// @notice Enable quota for a token
    function enableQuota(address token, bool status) external onlyOwner {
        isUsingQuota[token] = status;
    }

    /// @notice Enable default quota for a token
    function enableDefaultQuota(address token, bool status) external onlyOwner {
        hasDefaultQuota[token] = status;
    }

    /// @notice Set default quota for a token
    /// @notice Default quota means every pool has the same quota
    function setDefaultQuota(address token, uint256 amount) external onlyOwner {
        defaultQuota[token] = amount;
    }

    /// @notice Get the pool quota for a token
    function getPoolQuota(address pool, address token) external view returns (uint256) {
        if (isUsingQuota[token]) {
            if (hasDefaultQuota[token]) {
                return defaultQuota[token];
            } else {
                return poolQuota[token][pool];
            }
        } else {
            return type(uint256).max;
        }
    }
}
pragma solidity 0.8.16;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../../lib/DecimalMath.sol";
import "../../intf/ID3Vault.sol";
/// @title RateManager
/// @notice  This contract is responsible for calculating the borrowing interest rate.
contract D3RateManager is Ownable {
    using DecimalMath for uint256;

    struct RateStrategy {
        uint256 baseRate; // 1e18 = 100%
        uint256 slope1; // 1e18 = 100%;
        uint256 slope2; // 1e18 = 100%;
        uint256 optimalUsage; // 1e18 = 100%
    }

    mapping(address => RateStrategy) public rateStrategyMap; // token => RateStrategy
    mapping(address => uint256) public tokenTypeMap; // 1: stable; 2: volatile

    /// @notice  Set stable interest rate curve parameters. 
    /// @param token Token address
    /// @param baseRate Initial interest rate.
    /// @param slope1 Initial segment interest rate.
    /// @param slope2 Second segment interest rate.
    /// @param optimalUsage Boundary between the first segment interest rate and the second segment interest rate.
    function setStableCurve(
        address token,
        uint256 baseRate,
        uint256 slope1,
        uint256 slope2,
        uint256 optimalUsage
    ) external onlyOwner {
        rateStrategyMap[token] = RateStrategy(baseRate, slope1, slope2, optimalUsage);
        tokenTypeMap[token] = 1;
    }

    /// @notice  Set volatile interest rate curve parameters. 
    /// @param token Token address
    /// @param baseRate Initial interest rate.
    /// @param slope1 Initial segment interest rate.
    /// @param slope2 Second segment interest rate.
    /// @param optimalUsage Boundary between the first segment interest rate and the second segment interest rate.
    function setVolatileCurve(
        address token,
        uint256 baseRate,
        uint256 slope1,
        uint256 slope2,
        uint256 optimalUsage
    ) external onlyOwner {
        rateStrategyMap[token] = RateStrategy(baseRate, slope1, slope2, optimalUsage);
        tokenTypeMap[token] = 2;
    }

    /// @notice  Set token new type 
    function setTokenType(address token, uint256 tokenType) external onlyOwner {
        tokenTypeMap[token] = tokenType;
    }
    /// @notice  Get the borrowing interest rate for the token.
    /// @param token Token address
    /// @param utilizationRatio Token utilization rate.
    function getBorrowRate(address token, uint256 utilizationRatio) public view returns (uint256 rate) {
        RateStrategy memory s = rateStrategyMap[token];
        if (utilizationRatio <= s.optimalUsage) {
            rate = s.baseRate + utilizationRatio.mul(s.slope1);
        } else {
            rate = s.baseRate + s.optimalUsage.mul(s.slope1) + (utilizationRatio - s.optimalUsage).mul(s.slope2);
        }
    }
}
pragma solidity 0.8.16;

import "../../lib/InitializableOwnable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title D3Token
/// @notice When LP deposit token into D3MM pool, they receive certain amount of corresponding D3Token.
/// @notice D3Token acts as an interest bearing LP token.
contract D3Token is InitializableOwnable, ERC20("DODOV3 Token", "D3Token") {
    address public originToken;
    string private _symbol;
    string private _name;

    // ============ Events ============

    event Mint(address indexed user, uint256 value);

    event Burn(address indexed user, uint256 value);

    // ============ Functions ============

    function init(address token, address pool) external {
        initOwner(pool);
        originToken = token;
        _symbol = string.concat("d3", IERC20Metadata(token).symbol());
        _name = string.concat(_symbol, "_", addressToShortString(pool));
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function decimals() public view override returns (uint8) {
        return IERC20Metadata(originToken).decimals();
    }

    /// @dev Transfer token for a specified address
    /// @param to The address to transfer to.
    /// @param amount The amount to be transferred.
    function transfer(address to, uint256 amount) public override returns (bool) {
        address owner = _msgSender();
        require(amount <= balanceOf(owner), "BALANCE_NOT_ENOUGH");
        _transfer(owner, to, amount);
        return true;
    }

    /// @dev Transfer tokens from one address to another
    /// @param from address The address which you want to send tokens from
    /// @param to address The address which you want to transfer to
    /// @param amount uint256 the amount of tokens to be transferred
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(amount <= balanceOf(from), "BALANCE_NOT_ENOUGH");
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        _transfer(from, to, amount);
        return true;
    }

    /// @notice Mint certain amount of token for user
    function mint(address user, uint256 value) external onlyOwner {
        _mint(user, value);
        emit Mint(user, value);
    }

    /// @notice Burn certain amount of token on user account
    function burn(address user, uint256 value) external onlyOwner {
        _burn(user, value);
        emit Burn(user, value);
    }

    /// @notice Convert the address to a shorter string
    function addressToShortString(address _addr) public pure returns (string memory) {
        bytes32 value = bytes32(uint256(uint160(_addr)));
        bytes memory alphabet = "0123456789abcdef";

        bytes memory str = new bytes(8);
        for (uint256 i = 0; i < 4; i++) {
            str[i * 2] = alphabet[uint8(value[i + 12] >> 4)];
            str[1 + i * 2] = alphabet[uint8(value[i + 12] & 0x0f)];
        }
        return string(str);
    }
}
pragma solidity 0.8.16;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "../../../intf/IERC20.sol";
import {ID3UserQuota} from "../../intf/ID3UserQuota.sol";
import {ID3Vault} from "../../intf/ID3Vault.sol";
import "../../../intf/ID3Oracle.sol";
import "../../lib/DecimalMath.sol";

/// @title UserQuota
/// @notice This contract is used to set/get user's quota, i.e., determine the amount of token user can deposit into the pool.
contract D3UserQuota is Ownable, ID3UserQuota {
    using DecimalMath for uint256;

    // only user who holds vToken can deposit money
    address public _vTOKEN_;
    // tiers based on the amount of vToken user holds
    mapping(address => uint256[]) public vTokenTiers;
    // token => [quota on each tier]
    mapping(address => uint256[]) public quotaOnTiers;
    // token => bool, if false, a token is not using quota, can deposit unlimit amount
    mapping(address => bool) public isUsingQuota;
    // token => bool, if true, using global quota instead of vToken quota
    mapping(address => bool) public isGlobalQuota;
    // token => quota
    mapping(address => uint256) public globalQuota;

    ID3Vault public d3Vault;

    constructor(address vToken, address d3VaultAddress) {
        _vTOKEN_ = vToken;
        d3Vault = ID3Vault(d3VaultAddress);
    }

    /// @notice Enable quota for a token
    function enableQuota(address token, bool status) external onlyOwner {
        isUsingQuota[token] = status;
    }

    /// @notice Enable global quota for a token
    function enableGlobalQuota(address token, bool status) external onlyOwner {
        isGlobalQuota[token] = status;
    }

    /// @notice Set global quota for a token
    /// @notice Global quota means every user has the same quota, no matter how many vToken they hold
    function setGlobalQuota(address token, uint256 amount) external onlyOwner {
        globalQuota[token] = amount;
    }

    // @notice Set vToken address
    function setVToken(address vToken) external onlyOwner {
        _vTOKEN_ = vToken;
    }

    /// @notice Set the amount of tokens held and their corresponding quotas
    /// @notice for example, tiers = [100, 200, 300, 400], amounts = [1000, 4000, 6000, 10000]
    /// @notice user who holds 100 vToken, can deposit 1000 token
    /// @notice user who holds 200 vToken, can deposit 4000 token
    /// @notice user who holds 300 vToken, can deposit 6000 token
    /// @notice user who holds 400 vToken, can deposit 10000 token
    function setTiers(address token, uint256[] calldata tiers, uint256[] calldata amounts) external onlyOwner {
        require(tiers.length > 0 && tiers.length == amounts.length, "D3UserQuota: length not match");
        vTokenTiers[token] = tiers;
        quotaOnTiers[token] = amounts;
    }

    /// @notice Get the user quota based on tier
    function getTierQuota(address user, address token) public view returns (uint256 quota) {
        uint256 vTokenBalance = IERC20(_vTOKEN_).balanceOf(user);
        uint256[] memory tiers = vTokenTiers[token];
        uint256[] memory amounts = quotaOnTiers[token];
        for (uint256 i = 0; i < tiers.length; i++) {
            if (vTokenBalance < tiers[i]) {
                return quota = amounts[i];
            }
        }
        quota = amounts[amounts.length - 1];
    }

    /// @notice Get the used quota
    function getUsedQuota(address user, address token) public view returns (uint256) {
        (address dToken,,,,,,,,,,) = d3Vault.getAssetInfo(token);
        uint256 dTokenBalance = IERC20(dToken).balanceOf(user);
        uint256 exchangeRate = d3Vault.getExchangeRate(token);
        return dTokenBalance.mul(exchangeRate);
    }

    /// @notice Get the user quota for a token
    function getUserQuota(address user, address token) public view returns (uint256) {
        uint256 usedQuota = getUsedQuota(user, token);
        if (isUsingQuota[token]) {
            if (isGlobalQuota[token]) {
                return globalQuota[token] - usedQuota;
            } else {
                return getTierQuota(user, token) - usedQuota;
            }
        } else {
            return type(uint256).max;
        }
    }

    /// @notice Check if the quantity of tokens deposited by the user is allowed.
    function checkQuota(address user, address token, uint256 amount) public view returns (bool) {
        return (amount <= getUserQuota(user, token));
    }
}
pragma solidity 0.8.16;

interface ID3Factory {
    function breedD3Pool(address poolCreator, address maker, uint256 poolType) external returns (address newPool);
}
pragma solidity 0.8.16;

import "../lib/Types.sol";

interface ID3Maker {
    function init(address, address, uint256) external;
    function getTokenMMInfoForPool(address token)
        external
        view
        returns (Types.TokenMMInfo memory tokenMMInfo, uint256 tokenIndex);
    function checkHeartbeat() external view returns (bool);
    function getOneTokenOriginIndex(address token) external view returns (int256);
    function getPoolTokenListFromMaker() external view returns(address[] memory tokenlist);
}
pragma solidity 0.8.16;

interface ID3MM {
    function _CREATOR_() external view returns(address);
    function getFeeRate(address) external view returns(uint256);
    function allFlag() external view returns(uint256);
    function checkSafe() external view returns (bool);
    function checkBorrowSafe() external view returns (bool);
    function startLiquidation() external;
    function finishLiquidation() external;
    function isInLiquidation() external view returns (bool);
    function updateReserveByVault(address) external;
    function setNewAllFlag(uint256) external;

    function init(
        address creator,
        address maker,
        address vault,
        address oracle,
        address feeRateModel,
        address maintainer
    ) external;

    function sellToken(
        address to,
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 minReceiveAmount,
        bytes calldata data
    ) external returns (uint256);

    function buyToken(
        address to,
        address fromToken,
        address toToken,
        uint256 quoteAmount,
        uint256 maxPayAmount,
        bytes calldata data
    ) external returns (uint256);

    function lpDeposit(address lp, address token) external;
    function makerDeposit(address token) external;
    function getTokenReserve(address token) external view returns (uint256);
}
pragma solidity 0.8.16;

interface ID3PoolQuota {
    function getPoolQuota(address pool, address token) external view returns (uint256);
}
pragma solidity 0.8.16;

interface ID3RateManager {
    function getBorrowRate(address token, uint256 utilizationRatio) external view returns (uint256);
}
pragma solidity 0.8.16;

interface ID3Token {
    function init(address, address) external;
    function mint(address, uint256) external;
    function burn(address, uint256) external;
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}
pragma solidity 0.8.16;

interface ID3UserQuota {
    function getUserQuota(address user, address token) external view returns (uint256);
    function checkQuota(address user, address token, uint256 amount) external view returns (bool);
}
pragma solidity 0.8.16;

interface ID3Vault {
    function tokens(address) external view returns(bool);
    function _ORACLE_() external view returns (address);
    function allPoolAddrMap(address) external view returns (bool);
    function poolBorrow(address token, uint256 amount) external;
    function poolRepay(address token, uint256 bTokenAmount) external;
    function poolRepayAll(address token) external;
    function poolBorrowLpFee(address token, uint256 amount) external;
    function getBorrowed(address pool, address token) external view returns (uint256);
    function getAssetInfo(address token)
        external
        view
        returns (
            address dToken,
            uint256 totalBorrows,
            uint256 totalReserves,
            uint256 reserveFactor,
            uint256 borrowIndex,
            uint256 accrualTime,
            uint256 maxDepositAmount,
            uint256 collateralWeight,
            uint256 debtWeight,
            uint256 withdrawnReserves,
            uint256 balance
        );
    function getIMMM() external view returns (uint256, uint256);
    function getUtilizationRate(address token) external view returns (uint256);
    function checkSafe(address pool) external view returns (bool);
    function checkCanBeLiquidated(address pool) external view returns (bool);
    function checkBorrowSafe(address pool) external view returns (bool);
    function allowedLiquidator(address liquidator) external view returns (bool);
    function getTotalDebtValue(address pool) external view returns (uint256);
    function getTotalAssetsValue(address pool) external view returns (uint256);
    function getTokenList() external view returns (address[] memory);
    function addD3PoolByFactory(address) external;

    function userDeposit(address user, address token) external returns(uint256);
    function userWithdraw(address to, address user, address token, uint256 dTokenAmount) external returns (uint256);

    function getExchangeRate(address token) external view returns (uint256);
}
pragma solidity ^0.8.16;

interface IDODOLiquidator {
    function liquidate(
        address sender,
        address[] calldata tokens,
        uint256[] calldata balances,
        uint256[] calldata debts
    ) external;
}
pragma solidity 0.8.16;
pragma experimental ABIEncoderV2;

interface IDODOSwapCallback {
    function d3MMSwapCallBack(address token, uint256 value, bytes calldata data) external;
}
pragma solidity 0.8.16;

interface IDToken {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function mint(address account, uint256 amount) external;
    function burn(address account, uint256 amount) external;
    function init(address token, address owner) external;
}
pragma solidity 0.8.16;

interface ICloneFactory {
    function clone(address prototype) external returns (address proxy);
}

// introduction of proxy mode design: https://docs.openzeppelin.com/upgrades/2.8/
// minimum implementation of transparent proxy: https://eips.ethereum.org/EIPS/eip-1167

contract CloneFactory is ICloneFactory {
    function clone(address prototype) external override returns (address proxy) {
        bytes20 targetBytes = bytes20(prototype);
        assembly {
            let clone := mload(0x40)
            mstore(clone, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone, 0x14), targetBytes)
            mstore(add(clone, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            proxy := create(0, clone, 0x37)
        }
        return proxy;
    }
}
pragma solidity 0.8.16;
pragma experimental ABIEncoderV2;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title DecimalMath
 * @author DODO Breeder
 *
 * @notice Functions for fixed point number with 18 decimals
 */

library DecimalMath {
    uint256 internal constant ONE = 10 ** 18;
    uint256 internal constant ONE2 = 10 ** 36;

    function mul(uint256 target, uint256 d) internal pure returns (uint256) {
        return target * d / (10 ** 18);
    }

    function mulFloor(uint256 target, uint256 d) internal pure returns (uint256) {
        return target * d / (10 ** 18);
    }

    function mulCeil(uint256 target, uint256 d) internal pure returns (uint256) {
        return _divCeil(target * d, 10 ** 18);
    }

    function div(uint256 target, uint256 d) internal pure returns (uint256) {
        return target * (10 ** 18) / d;
    }

    function divFloor(uint256 target, uint256 d) internal pure returns (uint256) {
        return target * (10 ** 18) / d;
    }

    function divCeil(uint256 target, uint256 d) internal pure returns (uint256) {
        return _divCeil(target * (10 ** 18), d);
    }

    function reciprocalFloor(uint256 target) internal pure returns (uint256) {
        return uint256(10 ** 36) / target;
    }

    function reciprocalCeil(uint256 target) internal pure returns (uint256) {
        return _divCeil(uint256(10 ** 36), target);
    }

    function sqrt(uint256 target) internal pure returns (uint256) {
        return Math.sqrt(target * ONE);
    }

    function powFloor(uint256 target, uint256 e) internal pure returns (uint256) {
        if (e == 0) {
            return 10 ** 18;
        } else if (e == 1) {
            return target;
        } else {
            uint256 p = powFloor(target, e / 2);
            p = p * p / (10 ** 18);
            if (e % 2 == 1) {
                p = p * target / (10 ** 18);
            }
            return p;
        }
    }

    function _divCeil(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 quotient = a / b;
        uint256 remainder = a - quotient * b;
        if (remainder > 0) {
            return quotient + 1;
        } else {
            return quotient;
        }
    }
}
pragma solidity 0.8.16;
pragma experimental ABIEncoderV2;

import {DecimalMath} from "./DecimalMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title DODOMath
 * @author DODO Breeder
 *
 * @notice Functions for complex calculating. Including ONE Integration and TWO Quadratic solutions
 */
library DODOMath {
    /*
        Integrate dodo curve from V1 to V2
        require V0>=V1>=V2>0
        res = (1-k)i(V1-V2)+ikV0*V0(1/V2-1/V1)
        let V1-V2=delta
        res = i*delta*(1-k+k(V0^2/V1/V2))

        i is the price of V-res trading pair

        support k=1 & k=0 case

        [round down]
    */
    function _GeneralIntegrate(
        uint256 V0,
        uint256 V1,
        uint256 V2,
        uint256 i,
        uint256 k
    ) internal pure returns (uint256) {
        require(V0 > 0, "TARGET_IS_ZERO");
        uint256 fairAmount = i * (V1 - V2); // i*delta
        if (k == 0) {
            return fairAmount / DecimalMath.ONE;
        }
        uint256 V0V0V1V2 = DecimalMath.divFloor(V0 * V0 / V1, V2);
        uint256 penalty = DecimalMath.mulFloor(k, V0V0V1V2); // k(V0^2/V1/V2)
        return (DecimalMath.ONE - k + penalty) * fairAmount / DecimalMath.ONE2;
    }

    /*
        Follow the integration expression above, we have:
        i*deltaB = (Q2-Q1)*(1-k+kQ0^2/Q1/Q2)
        Given Q1 and deltaB, solve Q2
        This is a quadratic function and the standard version is
        aQ2^2 + bQ2 + c = 0, where
        a=1-k
        -b=(1-k)Q1-kQ0^2/Q1+i*deltaB
        c=-kQ0^2 
        and Q2=(-b+sqrt(b^2+4(1-k)kQ0^2))/2(1-k)
        note: another root is negative, abondan

        if deltaBSig=true, then Q2>Q1, user sell Q and receive B
        if deltaBSig=false, then Q2<Q1, user sell B and receive Q
        return |Q1-Q2|

        as we only support sell amount as delta, the deltaB is always negative
        the input ideltaB is actually -ideltaB in the equation

        i is the price of delta-V trading pair

        support k=1 & k=0 case

        [round down]
    */
    function _SolveQuadraticFunctionForTrade(
        uint256 V0,
        uint256 V1,
        uint256 delta,
        uint256 i,
        uint256 k
    ) internal pure returns (uint256) {
        require(V0 > 0, "TARGET_IS_ZERO");
        if (delta == 0) {
            return 0;
        }

        if (k == 0) {
            // why v1
            return DecimalMath.mulFloor(i, delta) > V1 ? V1 : DecimalMath.mulFloor(i, delta);
        }

        if (k == DecimalMath.ONE) {
            // if k==1
            // Q2=Q1/(1+ideltaBQ1/Q0/Q0)
            // temp = ideltaBQ1/Q0/Q0
            // Q2 = Q1/(1+temp)
            // Q1-Q2 = Q1*(1-1/(1+temp)) = Q1*(temp/(1+temp))
            // uint256 temp = i.mul(delta).mul(V1).div(V0.mul(V0));
            uint256 temp;
            uint256 idelta = i * (delta);
            if (idelta == 0) {
                temp = 0;
            } else if ((idelta * V1) / idelta == V1) {
                temp = (idelta * V1) / (V0 * (V0));
            } else {
                temp = delta * (V1) / (V0) * (i) / (V0);
            }
            return V1 * (temp) / (temp + (DecimalMath.ONE));
        }

        // calculate -b value and sig
        // b = kQ0^2/Q1-i*deltaB-(1-k)Q1
        // part1 = (1-k)Q1 >=0
        // part2 = kQ0^2/Q1-i*deltaB >=0
        // bAbs = abs(part1-part2)
        // if part1>part2 => b is negative => bSig is false
        // if part2>part1 => b is positive => bSig is true
        uint256 part2 = k * (V0) / (V1) * (V0) + (i * (delta)); // kQ0^2/Q1-i*deltaB
        uint256 bAbs = (DecimalMath.ONE - k) * (V1); // (1-k)Q1

        bool bSig;
        if (bAbs >= part2) {
            bAbs = bAbs - part2;
            bSig = false;
        } else {
            bAbs = part2 - bAbs;
            bSig = true;
        }
        bAbs = bAbs / (DecimalMath.ONE);

        // calculate sqrt
        uint256 squareRoot = DecimalMath.mulFloor((DecimalMath.ONE - k) * (4), DecimalMath.mulFloor(k, V0) * (V0)); // 4(1-k)kQ0^2
        squareRoot = Math.sqrt((bAbs * bAbs) + squareRoot); // sqrt(b*b+4(1-k)kQ0*Q0)

        // final res
        uint256 denominator = (DecimalMath.ONE - k) * 2; // 2(1-k)
        uint256 numerator;
        if (bSig) {
            numerator = squareRoot - bAbs;
        } else {
            numerator = bAbs + squareRoot;
        }

        uint256 V2 = DecimalMath.divCeil(numerator, denominator);
        if (V2 > V1) {
            return 0;
        } else {
            return V1 - V2;
        }
    }
}
pragma solidity 0.8.16;

library Errors {
    // ============= pool funding state =================
    string public constant NOT_SAFE = "D3MM_NOT_SAFE";
    string public constant NOT_BORROW_SAFE = "D3MM_NOT_BORROW_SAFE";
    string public constant NOT_VAULT = "D3MM_NOT_VAULT";
    string public constant NOT_IN_LIQUIDATION = "D3MM_NOT_IN_LIQUIDATION";
    string public constant POOL_NOT_ONGOING = "D3MM_POOL_NOT_ONGOING";
    string public constant TOKEN_NOT_FEASIBLE = "D3MM_TOKEN_NOT_FEASIBLE";

    // ============== pool trade =======================
    string public constant BALANCE_NOT_ENOUGH = "D3MM_BALANCE_NOT_ENOUGH";
    string public constant AMOUNT_TOO_SMALL = "D3MM_AMOUNT_TOO_SMALL";
    string public constant FROMAMOUNT_NOT_ENOUGH = "D3MM_FROMAMOUNT_NOT_ENOUGH";
    string public constant MINRES_NOT_ENOUGH = "D3MM_MINRESERVE_NOT_ENOUGH";
    string public constant MAXPAY_NOT_ENOUGH = "D3MM_MAXPAYAMOUNT_NOT_ENOUGH";
    string public constant BELOW_IM_RATIO = "D3MM_BELOW_IM_RATIO";
    string public constant HEARTBEAT_CHECK_FAIL = "D3MM_HEARTBEAT_CHECK_FAIL";

    // =============== d3 maker =========================
    string public constant K_LIMIT = "D3MAKER_K_LIMIT_ERROR";
    string public constant PRICE_UP_BELOW_PRICE_DOWN = "D3MAKER_PRICE_UP_BELOW_PRICE_DOWN";
    string public constant HAVE_SET_TOKEN_INFO = "D3MAKER_HAVE_SET_TOKEN_INFO";
    string public constant K_LENGTH_NOT_MATCH = "D3MAKER_K_LENGTH_NOT_MATCH";
    string public constant AMOUNTS_LENGTH_NOT_MATCH = "D3MAKER_AMOUNTS_LENGTH_NOT_MATCH";
    string public constant PRICES_LENGTH_NOT_MATCH = "D3MAKER_PRICES_LENGTH_NOT_MATCH";
    string public constant PRICE_SLOT_LENGTH_NOT_MATCH = "D3MAKER_PRICE_SLOT_LENGTH_NOT_MATCH";
    string public constant INVALID_TOKEN = "D3MAKER_INVALID_TOKEN";

    // =============== pmmRangeOrder ====================
    string public constant RO_ORACLE_PROTECTION = "PMMRO_ORACLE_PRICE_PROTECTION";
    string public constant RO_VAULT_RESERVE = "PMMRO_VAULT_RESERVE_NOT_ENOUGH";
    string public constant RO_AMOUNT_ZERO = "PMMRO_AMOUNT_ZERO";
    string public constant RO_PRICE_ZERO = "PMMRO_PRICE_ZERO";
    string public constant RO_PRICE_DIFF_TOO_SMALL = "PMMRO_PRICE_DIFF_TOO_SMALL";
    string public constant RO_BID_AMOUNT = "PMMRO_BIDAMOUNT_NOT_ENOUGH";

    
}
pragma solidity 0.8.16;

/**
 * @title Ownable
 * @author DODO Breeder
 * @notice Ownership related functions
 */
contract InitializableOwnable {
    address public _OWNER_;
    address public _NEW_OWNER_;
    bool internal _INITIALIZED_;

    // ============ Events ============

    event OwnershipTransferPrepared(address indexed previousOwner, address indexed newOwner);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ============ Modifiers ============

    modifier notInitialized() {
        require(!_INITIALIZED_, "DODO_INITIALIZED");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == _OWNER_, "NOT_OWNER");
        _;
    }

    // ============ Functions ============

    function initOwner(address newOwner) public notInitialized {
        _INITIALIZED_ = true;
        _OWNER_ = newOwner;
    }

    function transferOwnership(address newOwner) public onlyOwner {
        emit OwnershipTransferPrepared(_OWNER_, newOwner);
        _NEW_OWNER_ = newOwner;
    }

    function claimOwnership() public {
        require(msg.sender == _NEW_OWNER_, "INVALID_CLAIM");
        emit OwnershipTransferred(_OWNER_, _NEW_OWNER_);
        _OWNER_ = _NEW_OWNER_;
        _NEW_OWNER_ = address(0);
    }
}
pragma solidity 0.8.16;

import {DecimalMath} from "./DecimalMath.sol";

library MakerTypes {
    struct MakerState {
        HeartBeat heartBeat;
        // price list to package prices in one slot
        PriceListInfo priceListInfo;
        // =============== Swap Storage =================
        mapping(address => TokenMMInfoWithoutCum) tokenMMInfoMap;
    }

    struct TokenMMInfoWithoutCum {
        // [mid price(16) | mid price decimal(8) | fee rate(16) | ask up rate (16) | bid down rate(16)]
        // midprice unit is 1e18
        // all rate unit is 10000
        uint80 priceInfo;
        // [ask amounts(16) | ask amounts decimal(8) | bid amounts(16) | bid amounts decimal(8) ]
        uint64 amountInfo;
        // k is [0, 10000]
        uint16 kAsk;
        uint16 kBid;
        uint16 tokenIndex;
    }

    // package three token price in one slot
    struct PriceListInfo {
        // to avoid reset the same token, tokenIndexMap record index from 1, but actualIndex = tokenIndex[address] - 1
        // odd for none-stable, even for stable,  true index = actualIndex / 2 = (tokenIndex[address] - 1) / 2
        mapping(address => uint256) tokenIndexMap;
        uint256 numberOfNS; // quantity of not stable token
        uint256 numberOfStable; // quantity of stable token
        // [mid price(16) | mid price decimal(8) | fee rate(16) | ask up rate (16) | bid down rate(16)] = 72 bit
        // one slot contain = 72 * 3, 3 token price
        // [2 | 1 | 0]
        uint256[] tokenPriceNS; // not stable token price
        uint256[] tokenPriceStable; // stable token price
    }

    struct HeartBeat {
        uint256 lastHeartBeat;
        uint256 maxInterval;
    }

    uint16 internal constant ONE_PRICE_BIT = 72;
    uint256 internal constant PRICE_QUANTITY_IN_ONE_SLOT = 3;
    uint16 internal constant ONE_AMOUNT_BIT = 24;
    uint256 internal constant ONE = 10 ** 18;

    // [ask amounts(16) | ask amounts decimal(8) | bid amounts(16) | bid amounts decimal(8) ]
    function parseAskAmount(uint64 amountInfo) internal pure returns (uint256 amountWithDecimal) {
        uint256 askAmount = (amountInfo >> (ONE_AMOUNT_BIT + 8)) & 0xffff;
        uint256 askAmountDecimal = (amountInfo >> ONE_AMOUNT_BIT) & 255;
        amountWithDecimal = askAmount * (10 ** askAmountDecimal);
    }

    // [ask amounts(16) | ask amounts decimal(8) | bid amounts(16) | bid amounts decimal(8) ]
    function parseBidAmount(uint64 amountInfo) internal pure returns (uint256 amountWithDecimal) {
        uint256 bidAmount = (amountInfo >> 8) & 0xffff;
        uint256 bidAmountDecimal = amountInfo & 255;
        amountWithDecimal = bidAmount * (10 ** bidAmountDecimal);
    }

    function parseAllPrice(uint80 priceInfo)
        internal
        pure
        returns (uint256 askUpPrice, uint256 askDownPrice, uint256 bidUpPrice, uint256 bidDownPrice, uint256 swapFee)
    {
        {
        uint256 midPrice = (priceInfo >> 56) & 0xffff;
        uint256 midPriceDecimal = (priceInfo >> 48) & 255;
        uint256 midPriceWithDecimal = midPrice * (10 ** midPriceDecimal);

        uint256 swapFeeRate = (priceInfo >> 32) & 0xffff;
        uint256 askUpRate = (priceInfo >> 16) & 0xffff;
        uint256 bidDownRate = priceInfo & 0xffff;

        // swap fee rate standarlize
        swapFee = swapFeeRate * (10 ** 14);
        uint256 swapFeeSpread = DecimalMath.mul(midPriceWithDecimal, swapFee);

        // ask price standarlize
        askDownPrice = midPriceWithDecimal + swapFeeSpread;
        askUpPrice = midPriceWithDecimal + midPriceWithDecimal * askUpRate / (10 ** 4);
        require(askDownPrice <= askUpPrice, "ask price invalid");

        // bid price standarlize
        uint reversalBidUp = midPriceWithDecimal - swapFeeSpread;
        uint reversalBidDown = midPriceWithDecimal - midPriceWithDecimal * bidDownRate / (10 ** 4);
        require(reversalBidDown <= reversalBidUp, "bid price invalid");
        bidDownPrice = DecimalMath.reciprocalCeil(reversalBidUp);
        bidUpPrice = DecimalMath.reciprocalCeil(reversalBidDown);
        }
    }

    function parseK(uint16 originK) internal pure returns (uint256) {
        return uint256(originK) * (10 ** 14);
    }
}
pragma solidity 0.8.16;

import {DecimalMath} from "contracts/DODOV3MM/lib/DecimalMath.sol";
import {DODOMath} from "contracts/DODOV3MM/lib/DODOMath.sol";

/**
 * @title PMMPricing
 * @author DODO Breeder
 *
 * @notice DODO Pricing model
 */
library PMMPricing {
    struct PMMState {
        uint256 i;
        uint256 K;
        uint256 B;
        uint256 B0;
        uint256 BMaxAmount;
        uint256 BLeft;
    }

    function _queryBuyBaseToken(PMMState memory state, uint256 amount) internal pure returns (uint256 payQuote) {
        payQuote = _BuyBaseToken(state, amount, state.B, state.B0);
    }

    function _querySellQuoteToken(
        PMMState memory state,
        uint256 payQuoteAmount
    ) internal pure returns (uint256 receiveBaseAmount) {
        receiveBaseAmount = _SellQuoteToken(state, payQuoteAmount);
    }

    // ============ R > 1 cases ============

    function _BuyBaseToken(
        PMMState memory state,
        uint256 amount,
        uint256 baseBalance,
        uint256 targetBaseAmount
    ) internal pure returns (uint256 payQuoteToken) {
        require(amount < baseBalance, "DODOstate.BNOT_ENOUGH");
        uint256 B2 = baseBalance - amount;
        return DODOMath._GeneralIntegrate(targetBaseAmount, baseBalance, B2, state.i, state.K);
    }

    function _SellQuoteToken(
        PMMState memory state,
        uint256 payQuoteAmount
    ) internal pure returns (uint256 receiveBaseToken) {
        return DODOMath._SolveQuadraticFunctionForTrade(
            state.B0, state.B, payQuoteAmount, DecimalMath.reciprocalFloor(state.i), state.K
        );
    }
}
pragma solidity 0.8.16;

import "./PMMPricing.sol";
import "./Errors.sol";
import "./Types.sol";
import {ID3Oracle} from "contracts/intf/ID3Oracle.sol";

library PMMRangeOrder {
    uint256 internal constant ONE = 10 ** 18;

    // use fromToken bid curve and toToken ask curve
    function querySellTokens(
        Types.RangeOrderState memory roState,
        address fromToken,
        address toToken,
        uint256 fromTokenAmount
    ) internal view returns (uint256 fromAmount, uint256 receiveToToken, uint256 vusdAmount) {
        // contruct fromToken state and swap to vUSD
        uint256 receiveVUSD;
        {
            PMMPricing.PMMState memory fromTokenState = _contructTokenState(roState, true, false);
            receiveVUSD = PMMPricing._querySellQuoteToken(fromTokenState, fromTokenAmount);

            receiveVUSD = receiveVUSD > fromTokenState.BLeft ? fromTokenState.BLeft : receiveVUSD;
        }

        // construct toToken state and swap from vUSD to toToken
        {
            PMMPricing.PMMState memory toTokenState = _contructTokenState(roState, false, true);
            receiveToToken = PMMPricing._querySellQuoteToken(toTokenState, receiveVUSD);

            receiveToToken = receiveToToken > toTokenState.BLeft ? toTokenState.BLeft : receiveToToken;
        }

        // oracle protect
        {
            uint256 oracleToAmount = ID3Oracle(roState.oracle).getMaxReceive(fromToken, toToken, fromTokenAmount);
            require(oracleToAmount >= receiveToToken, Errors.RO_ORACLE_PROTECTION);
        }
        return (fromTokenAmount, receiveToToken, receiveVUSD);
    }

    // use fromToken bid curve and toToken ask curve
    function queryBuyTokens(
        Types.RangeOrderState memory roState,
        address fromToken,
        address toToken,
        uint256 toTokenAmount
    ) internal view returns (uint256 payFromToken, uint256 toAmount, uint256 vusdAmount) {
        // contruct fromToken to vUSD
        uint256 payVUSD;
        {
            PMMPricing.PMMState memory toTokenState = _contructTokenState(roState, false, true);
            require(
                toTokenAmount <= toTokenState.BMaxAmount - roState.toTokenMMInfo.cumulativeAsk, Errors.RO_VAULT_RESERVE
            );
            payVUSD = PMMPricing._queryBuyBaseToken(toTokenState, toTokenAmount);
        }

        // construct vUSD to toToken
        {
            PMMPricing.PMMState memory fromTokenState = _contructTokenState(roState, true, false);
            require(payVUSD <= fromTokenState.BLeft, Errors.RO_BID_AMOUNT);
            payFromToken = PMMPricing._queryBuyBaseToken(fromTokenState, payVUSD);
        }

        // oracle protect
        {
            uint256 oracleToAmount = ID3Oracle(roState.oracle).getMaxReceive(fromToken, toToken, payFromToken);
            require(oracleToAmount >= toTokenAmount, Errors.RO_ORACLE_PROTECTION);
        }

        return (payFromToken, toTokenAmount, payVUSD);
    }

    // ========= internal ==========
    function _contructTokenState(
        Types.RangeOrderState memory roState,
        bool fromTokenOrNot,
        bool askOrNot
    ) internal pure returns (PMMPricing.PMMState memory tokenState) {
        Types.TokenMMInfo memory tokenMMInfo = fromTokenOrNot ? roState.fromTokenMMInfo : roState.toTokenMMInfo;

        // bMax,k
        tokenState.BMaxAmount = askOrNot ? tokenMMInfo.askAmount : tokenMMInfo.bidAmount;

        // amount = 0 protection
        require(tokenState.BMaxAmount > 0, Errors.RO_AMOUNT_ZERO);
        tokenState.K = askOrNot ? tokenMMInfo.kAsk : tokenMMInfo.kBid;

        // i, B0
        uint256 upPrice;
        (tokenState.i, upPrice) = askOrNot
            ? (tokenMMInfo.askDownPrice, tokenMMInfo.askUpPrice)
            : (tokenMMInfo.bidDownPrice, tokenMMInfo.bidUpPrice);
        // price = 0 protection
        require(tokenState.i > 0, Errors.RO_PRICE_ZERO);
        tokenState.B0 = _calB0WithPriceLimit(upPrice, tokenState.K, tokenState.i, tokenState.BMaxAmount);
        // B
        tokenState.B = askOrNot ? tokenState.B0 - tokenMMInfo.cumulativeAsk : tokenState.B0 - tokenMMInfo.cumulativeBid;

        // BLeft
        tokenState.BLeft = askOrNot
            ? tokenState.BMaxAmount - tokenMMInfo.cumulativeAsk
            : tokenState.BMaxAmount - tokenMMInfo.cumulativeBid;

        return tokenState;
    }

    // P_up = i(1 - k + k*(B0 / B0 - amount)^2), record amount = A
    // (P_up + i*k - i) / i*k = (B0 / (B0 - A))^2
    // B0 = A + A / (sqrt((P_up + i*k - i) / i*k) - 1)
    // i = priceDown
    function _calB0WithPriceLimit(
        uint256 priceUp,
        uint256 k,
        uint256 i,
        uint256 amount
    ) internal pure returns (uint256 baseTarget) {
        // (P_up + i*k - i)
        // temp1 = PriceUp + DecimalMath.mul(i, k) - i
        // temp1 price

        // i*k
        // temp2 = DecimalMath.mul(i, k)
        // temp2 price

        // (P_up + i*k - i)/i*k
        // temp3 = DecimalMath(temp1, temp2)
        // temp3 ONE

        // temp4 = sqrt(temp3 * ONE)
        // temp4 ONE

        // temp5 = temp4 - ONE
        // temp5 ONE

        // B0 = amount + DecimalMath.div(amount, temp5)
        // B0 amount
        if (k == 0) {
            baseTarget = amount;
        } else {
            uint256 temp1 = priceUp * ONE + i * k - i * ONE;
            uint256 temp2 = i * k;
            uint256 temp3 = DecimalMath.div(temp1, temp2);
            uint256 temp5 = DecimalMath.sqrt(temp3) - ONE;
            require(temp5 > 0, Errors.RO_PRICE_DIFF_TOO_SMALL);
            baseTarget = amount + DecimalMath.div(amount, temp5);
        }
    }
}
pragma solidity 0.8.16;

library Types {
    struct D3MMState {
        // the D3vault contract
        address _D3_VAULT_;
        // the creator of pool
        address _CREATOR_;
        // maker contract address
        address _MAKER_;
        address _ORACLE_;
        address _FEE_RATE_MODEL_;
        address _MAINTAINER_;
        // token balance
        mapping(address => uint256) balances;
        // the tokens have been deposited into pool
        address[] depositedTokenList;
        // record if a token has been deposited before
        mapping(address => bool) hasDepositedToken;
    }

    struct TokenCumulative {
        uint256 cumulativeAsk;
        uint256 cumulativeBid;
    }

    struct TokenMMInfo {
        // ask price with decimal
        uint256 askDownPrice;
        uint256 askUpPrice;
        // bid price with decimal
        uint256 bidDownPrice;
        uint256 bidUpPrice;
        uint256 askAmount;
        uint256 bidAmount;
        // k, unit is 1e18
        uint256 kAsk;
        uint256 kBid;
        // cumulative
        uint256 cumulativeAsk;
        uint256 cumulativeBid;
        // swap fee, unit is 1e18
        uint256 swapFeeRate;
        uint256 mtFeeRate;
    }

    struct RangeOrderState {
        address oracle;
        TokenMMInfo fromTokenMMInfo;
        TokenMMInfo toTokenMMInfo;
    }

    function parseRealAmount(uint256 realAmount, uint256 tokenDec) internal pure returns(uint256 amountWithDec18) {
        if(tokenDec < 18) {
            uint256 fixDec = 18 - tokenDec;
            amountWithDec18 = realAmount * (10 ** fixDec);
        } else if(tokenDec == 18) {
            amountWithDec18 = realAmount;
        } else {
            uint256 fixDec = tokenDec - 18;
            amountWithDec18 = realAmount / (10 ** fixDec);
        }
    }

    function parseDec18Amount(uint256 amountWithDec18, uint256 tokenDec) internal pure returns(uint256 realAmount) {
        if(tokenDec < 18) {
            uint256 fixDec = 18 - tokenDec;
            realAmount = amountWithDec18 / (10 ** fixDec);
        } else if(tokenDec == 18) {
            realAmount = amountWithDec18;
        } else {
            uint256 fixDec = tokenDec - 18;
            realAmount = amountWithDec18 * (10 ** fixDec);
        }
    }
}
pragma solidity 0.8.16;

import {ID3MM} from "../intf/ID3MM.sol";
import {ID3Maker} from "../intf/ID3Maker.sol";
import {ID3Vault} from "../intf/ID3Vault.sol";
import {InitializableOwnable} from "../lib/InitializableOwnable.sol";
import {ICloneFactory} from "../lib/CloneFactory.sol";

/**
 * @title D3MMFactory
 * @author DODO Breeder
 * @notice This factory contract is used to create/register D3MM pools.
 */
contract D3MMFactory is InitializableOwnable {
    // different index means different tmeplate, 0 is for normal d3 pool.
    mapping(uint256 => address) public _D3POOL_TEMPS;
    mapping(uint256 => address) public _D3MAKER_TEMPS_;
    address public _CLONE_FACTORY_;
    address public _ORACLE_;
    ID3Vault public d3Vault;
    address public _FEE_RATE_MODEL_;
    address public _MAINTAINER_;

    // ============ Events ============

    event D3Birth(address newD3, address creator);
    event AddRouter(address router);
    event RemoveRouter(address router);

    // ============ Constructor Function ============

    constructor(
        address owner,
        address[] memory d3Temps,
        address[] memory d3MakerTemps,
        address cloneFactory,
        address d3VaultAddress,
        address oracleAddress,
        address feeRateModel,
        address maintainer
    ) {
        require(d3MakerTemps.length == d3Temps.length, "temps not match");

        for (uint256 i = 0; i < d3Temps.length; i++) {
            _D3POOL_TEMPS[i] = d3Temps[i];
            _D3MAKER_TEMPS_[i] = d3MakerTemps[i];
        }
        _CLONE_FACTORY_ = cloneFactory;
        _ORACLE_ = oracleAddress;
        d3Vault = ID3Vault(d3VaultAddress);
        _FEE_RATE_MODEL_ = feeRateModel;
        _MAINTAINER_ = maintainer;
        initOwner(owner);
    }

    // ============ Admin Function ============

    /// @notice Set new D3MM template
    function setD3Temp(uint256 poolType, address newTemp) public onlyOwner {
        _D3POOL_TEMPS[poolType] = newTemp;
    }
    /// @notice Set new D3Maker template
    function setD3MakerTemp(uint256 poolType, address newMakerTemp) public onlyOwner {
        _D3MAKER_TEMPS_[poolType] = newMakerTemp;
    }

    /// @notice Set new CloneFactory contract address
    function setCloneFactory(address cloneFactory) external onlyOwner {
        _CLONE_FACTORY_ = cloneFactory;
    }

    /// @notice Set new oracle
    function setOracle(address oracle) external onlyOwner {
        _ORACLE_ = oracle;
    }
    /// @notice Set new maintainer
    function setMaintainer(address maintainer) external onlyOwner {
        _MAINTAINER_ = maintainer;
    }
    /// @notice Set new feeRateModel
    function setFeeRate(address feeRateModel) external onlyOwner {
        _FEE_RATE_MODEL_ = feeRateModel;
    }

    // ============ Breed DODO Function ============

    /// @notice Create new D3MM pool and maker, and register to vault
    /// @param poolCreator Pool owner
    /// @param maker Maker owner
    /// @param maxInterval Maximum interval for heartbeat detection.
    /// @param poolType Pool template type.
    /// @return newPool New pool address
    function breedD3Pool(
        address poolCreator,
        address maker,
        uint256 maxInterval,
        uint256 poolType
    ) external onlyOwner returns (address newPool) {
        address newMaker = ICloneFactory(_CLONE_FACTORY_).clone(_D3MAKER_TEMPS_[poolType]);
        newPool = ICloneFactory(_CLONE_FACTORY_).clone(_D3POOL_TEMPS[poolType]);

        ID3MM(newPool).init(
            poolCreator,
            newMaker,
            address(d3Vault),
            _ORACLE_,
            _FEE_RATE_MODEL_,
            _MAINTAINER_
        );
        
        ID3Maker(newMaker).init(maker, newPool, maxInterval);

        d3Vault.addD3PoolByFactory(newPool);

        emit D3Birth(newPool, poolCreator);
        return newPool;
    }
}
pragma solidity 0.8.16;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract D3MMLiquidationRouter {
    using SafeERC20 for IERC20;

    address public immutable _DODO_APPROVE_;

    constructor(address dodoApprove) {
        _DODO_APPROVE_ = dodoApprove;
    }

    struct LiquidationOrder {
        address fromToken;
        address toToken;
        uint256 fromAmount;
    }

    /// @notice D3MM call this function to do liquidation swap
    /// @param order The liquidation order
    /// @param router The router contract address
    /// @param routeData The data will be parsed to router call
    function D3Callee(LiquidationOrder calldata order, address router, bytes calldata routeData) external {
        IERC20(order.fromToken).forceApprove(_DODO_APPROVE_, type(uint256).max);
        (bool success, bytes memory data) = router.call(routeData);
        if (!success) {
            assembly {
                revert(add(data, 32), mload(data))
            }
        }
        IERC20(order.toToken).safeTransfer(msg.sender, IERC20(order.toToken).balanceOf(address(this)));
    }
}
pragma solidity 0.8.16;

import {InitializableOwnable} from "../lib/InitializableOwnable.sol";
import {ID3Oracle} from "../../intf/ID3Oracle.sol";
import "../lib/DecimalMath.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

struct PriceSource {
    address oracle;
    bool isWhitelisted;
    uint256 priceTolerance;
    uint8 priceDecimal;
    uint8 tokenDecimal;
    uint256 heartBeat;
}

contract D3Oracle is ID3Oracle, InitializableOwnable {
    // originToken => priceSource
    mapping(address => PriceSource) public priceSources;
    address public sequencerFeed;

    uint256 private constant GRACE_PERIOD_TIME = 3600;

    error SequencerDown();
    error GracePeriodNotOver();

    /// @notice Onwer is set in constructor
    constructor() {
        initOwner(msg.sender);
    }

    /// @notice Set sequencer feed address
    /// @notice For non-L2 network, should be address(0)
    /// @notice For a list of available Sequencer Uptime Feed proxy addresses, 
    /// @notice see: https://docs.chain.link/docs/data-feeds/l2-sequencer-feeds
    function setSequencer(address addr) external onlyOwner {
        sequencerFeed = addr;
    }

    /// @notice Set the price source for a token
    /// @param token The token address
    /// @param source The price source for the token
    function setPriceSource(address token, PriceSource calldata source) external onlyOwner {
        priceSources[token] = source;
        require(source.priceTolerance <= DecimalMath.ONE && source.priceTolerance >= 1e10, "INVALID_PRICE_TOLERANCE");
    }

    /// @notice Enable or disable oracle for a token
    /// @dev Owner could stop oracle feed price in emergency
    /// @param token The token address
    /// @param isAvailable Whether the oracle is available for the token
    function setTokenOracleFeasible(address token, bool isAvailable) external onlyOwner {
        priceSources[token].isWhitelisted = isAvailable;
    }

    /// @notice Get the price for a token
    /// @dev The price definition is: how much virtual USD the token values if token amount is 1e18.
    /// @dev Example 1: if the token decimals is 18, and worth 2 USD, then price is 2e18.
    /// @dev Example 2: if the token decimals is 8, and worth 2 USD, then price is 2e28.
    /// @param token The token address
    function getPrice(address token) public view override returns (uint256) {
        uint256 price = getPriceFromFeed(token);
        return price * 10 ** (36 - priceSources[token].priceDecimal - priceSources[token].tokenDecimal);
    }

    /// @notice Return the original price from price feed
    /// @notice For example, if WBTC price is 30000e8, return (30000e8, 8)
    function getOriginalPrice(address token) public view override returns (uint256, uint8) {
        uint256 price = getPriceFromFeed(token);
        uint8 priceDecimal = priceSources[token].priceDecimal;
        return (price, priceDecimal);
    }

    /// @notice If the price decimals is not 18, parse it to 18
    /// @notice For example, if WBTC price is 30000e8, return 30000e18
    function getDec18Price(address token) public view override returns (uint256) {
        uint256 price = getPriceFromFeed(token);
        return price * 10 ** (18 - priceSources[token].priceDecimal);
    }

    /// @notice Return if oracle is feasible for a token
    /// @param token The token address
    function isFeasible(address token) external view override returns (bool) {
        return priceSources[token].isWhitelisted;
    }

    /// @notice Given certain amount of fromToken, get the max return amount of toToken
    /// @param fromToken The from token address
    /// @param toToken The to token address
    /// @param fromAmount The from token amount
    /// @dev This function is only used in PMMRangeOrder, which assumes both tokens have 18 decimals.
    /// @dev PMMRangeOrder will parse token amount if the decimals is not 18
    /// @dev Do not use this function in other place. If use, make sure both tokens' decimals are 18
    function getMaxReceive(address fromToken, address toToken, uint256 fromAmount) external view returns (uint256) {
        uint256 fromTlr = priceSources[fromToken].priceTolerance;
        uint256 toTlr = priceSources[toToken].priceTolerance;

        return DecimalMath.div((fromAmount * getDec18Price(fromToken)) / getDec18Price(toToken), DecimalMath.mul(fromTlr, toTlr));
    }

    function getPriceFromFeed(address token) internal view returns (uint256) {
        checkSequencerActive();
        require(priceSources[token].isWhitelisted, "INVALID_TOKEN");
        AggregatorV3Interface priceFeed = AggregatorV3Interface(priceSources[token].oracle);
        (uint80 roundID, int256 price,, uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();
        require(price > 0, "Chainlink: Incorrect Price");
        require(block.timestamp - updatedAt < priceSources[token].heartBeat, "Chainlink: Stale Price");
        require(answeredInRound >= roundID, "Chainlink: Stale Price");
        return uint256(price);
    }

    function checkSequencerActive() internal view {
        // for non-L2 network, sequencerFeed should be set to address(0)
        if (sequencerFeed == address(0)) return;
        (, int256 answer, uint256 startedAt, ,) = AggregatorV3Interface(sequencerFeed).latestRoundData();
        // Answer == 0: Sequencer is up
        // Answer == 1: Sequencer is down
        if (answer == 1) revert SequencerDown();
        // Make sure the grace period has passed after the
        // sequencer is back up.
        if (block.timestamp - startedAt <= GRACE_PERIOD_TIME) revert GracePeriodNotOver();
    }
}
pragma solidity 0.8.16;

import "../lib/PMMRangeOrder.sol";
import "../lib/Errors.sol";
import {ID3MM} from "../intf/ID3MM.sol";
import {ID3Factory} from "../intf/ID3Factory.sol";
import {IWETH} from "contracts/intf/IWETH.sol";
import {IDODOSwapCallback} from "../intf/IDODOSwapCallback.sol";
import {IDODOApproveProxy} from "contracts/intf/IDODOApproveProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ID3Vault} from "../intf/ID3Vault.sol";

contract D3Proxy is IDODOSwapCallback {
    using SafeERC20 for IERC20;

    address public immutable _DODO_APPROVE_PROXY_;
    address public immutable _WETH_;
    address public immutable _D3_VAULT_;
    address public immutable _ETH_ADDRESS_ = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    struct SwapCallbackData {
        bytes data;
        address payer;
    }

    // ============ Modifiers ============

    modifier judgeExpired(uint256 deadLine) {
        require(deadLine >= block.timestamp, "D3PROXY_EXPIRED");
        _;
    }

    // ============ Constructor ============

    constructor(address approveProxy, address weth, address d3Vault) {
        _DODO_APPROVE_PROXY_ = approveProxy;
        _WETH_ = weth;
        _D3_VAULT_ = d3Vault;
    }

    // ======================================

    fallback() external payable {}

    receive() external payable {
        require(msg.sender == _WETH_, "D3PROXY_NOT_WETH9");
    }

    // ======================================

    /// @notice Call multiple functions in the current contract and return the data from all of them if they all succeed
    /// @param data The encoded function data for each of the calls to make to this contract
    /// @return results The results from each of the calls passed in via data
    function multicall(bytes[] calldata data) public payable returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);

            if (!success) {
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }

            results[i] = result;
        }
    }

    /// @notice Sell certain amount of tokens, i.e., fromToken amount is known
    /// @param pool The address of the pool to which you want to sell tokens
    /// @param to The address to receive the return back token
    /// @param fromToken The address of the fromToken
    /// @param toToken The address of the toToken
    /// @param fromAmount The amount of the fromToken you want to sell
    /// @param minReceiveAmount The minimal amount you expect to receive
    /// @param data Any data to be passed through to the callback
    /// @param deadLine The transaction should be processed before the deadline
    function sellTokens(
        address pool,
        address to,
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 minReceiveAmount,
        bytes calldata data,
        uint256 deadLine
    ) public payable judgeExpired(deadLine) returns (uint256 receiveToAmount) {
        SwapCallbackData memory swapData;
        swapData.data = data;
        swapData.payer = msg.sender;

        if (fromToken == _ETH_ADDRESS_) {
            require(msg.value == fromAmount, "D3PROXY_VALUE_INVALID");
            receiveToAmount = ID3MM(pool).sellToken(to, _WETH_, toToken, fromAmount, minReceiveAmount, abi.encode(swapData));
        } else if (toToken == _ETH_ADDRESS_) {
            receiveToAmount =
                ID3MM(pool).sellToken(address(this), fromToken, _WETH_, fromAmount, minReceiveAmount, abi.encode(swapData));
            _withdrawWETH(to, receiveToAmount);
            // multicall withdraw weth to user
        } else {
            receiveToAmount = ID3MM(pool).sellToken(to, fromToken, toToken, fromAmount, minReceiveAmount, abi.encode(swapData));
        }
    }

    /// @notice Buy certain amount of tokens, i.e., toToken amount is known
    /// @param pool The address of the pool to which you want to sell tokens
    /// @param to The address to receive the return back token
    /// @param fromToken The address of the fromToken
    /// @param toToken The address of the toToken
    /// @param quoteAmount The amount of the toToken you want to buy
    /// @param maxPayAmount The maximum amount of fromToken you would like to pay
    /// @param data Any data to be passed through to the callback
    /// @param deadLine The transaction should be processed before the deadline
    function buyTokens(
        address pool,
        address to,
        address fromToken,
        address toToken,
        uint256 quoteAmount,
        uint256 maxPayAmount,
        bytes calldata data,
        uint256 deadLine
    ) public payable judgeExpired(deadLine) returns (uint256 payFromAmount) {
        SwapCallbackData memory swapData;
        swapData.data = data;
        swapData.payer = msg.sender;

        if (fromToken == _ETH_ADDRESS_) {
            payFromAmount = ID3MM(pool).buyToken(to, _WETH_, toToken, quoteAmount, maxPayAmount, abi.encode(swapData));
            // multicall refund eth to user
        } else if (toToken == _ETH_ADDRESS_) {
            payFromAmount = ID3MM(pool).buyToken(address(this), fromToken, _WETH_, quoteAmount, maxPayAmount, abi.encode(swapData));
            _withdrawWETH(to, quoteAmount);
            // multicall withdraw weth to user
        } else {
            payFromAmount = ID3MM(pool).buyToken(to, fromToken, toToken, quoteAmount, maxPayAmount, abi.encode(swapData));
        }
    }

    /// @notice This callback is used to deposit token into D3MM
    /// @param token The address of token
    /// @param value The amount of token need to deposit to D3MM
    /// @param _data Any data to be passed through to the callback
    function d3MMSwapCallBack(address token, uint256 value, bytes calldata _data) external override {
        require(ID3Vault(_D3_VAULT_).allPoolAddrMap(msg.sender), "D3PROXY_CALLBACK_INVALID");
        SwapCallbackData memory decodeData;
        decodeData = abi.decode(_data, (SwapCallbackData));
        _deposit(decodeData.payer, msg.sender, token, value);
    }

    /// @notice LP deposit token into pool
    /// @param user the one who own dtokens
    /// @param  token The address of token
    /// @param amount The amount of token
    function userDeposit(address user, address token, uint256 amount, uint256 minDtokenAmount) external payable {
        uint256 dTokenAmount;
        if (token == _ETH_ADDRESS_) {
            require(msg.value == amount, "D3PROXY_PAYMENT_NOT_MATCH");
            _deposit(msg.sender, _D3_VAULT_, _WETH_, amount);
            dTokenAmount = ID3Vault(_D3_VAULT_).userDeposit(user, _WETH_);
        } else {
            _deposit(msg.sender, _D3_VAULT_, token, amount);
            dTokenAmount = ID3Vault(_D3_VAULT_).userDeposit(user, token);
        }
        require(dTokenAmount >= minDtokenAmount, "D3PROXY_MIN_DTOKEN_AMOUNT_FAIL");
    }

    function userWithdraw(address to, address token, uint256 dTokenAmount, uint256 minReceiveAmount) external payable returns(uint256 amount){
        if (token != _ETH_ADDRESS_) {
            (address dToken,,,,,,,,,,) = ID3Vault(_D3_VAULT_).getAssetInfo(token);
            _deposit(msg.sender, address(this), dToken, dTokenAmount);
            amount = ID3Vault(_D3_VAULT_).userWithdraw(to, msg.sender, token, dTokenAmount);    
        } else {
            (address dToken,,,,,,,,,,) = ID3Vault(_D3_VAULT_).getAssetInfo(_WETH_);
            _deposit(msg.sender, address(this), dToken, dTokenAmount);
            amount = ID3Vault(_D3_VAULT_).userWithdraw(address(this), msg.sender, _WETH_, dTokenAmount);
            _withdrawWETH(to, amount);
        }
        require(amount >= minReceiveAmount, "D3PROXY_MIN_RECEIVE_FAIL");
    }

    /// @notice Pool owner deposit token into pool
    /// @param pool The address of pool
    /// @param  token The address of token
    /// @param amount The amount of token
    function makerDeposit(address pool, address token, uint256 amount) external payable {
        if (token == _ETH_ADDRESS_) {
            require(msg.value == amount, "D3PROXY_PAYMENT_NOT_MATCH");
            _deposit(msg.sender, pool, _WETH_, amount);
            ID3MM(pool).makerDeposit(_WETH_);
        } else{
            _deposit(msg.sender, pool, token, amount);
            ID3MM(pool).makerDeposit(token);
        }
    }


    // ======= external refund =======

    /// @dev when fromToken = ETH and call buyTokens, call this function to refund user's eth
    function refundETH() external payable {
        if (address(this).balance > 0) {
            _safeTransferETH(msg.sender, address(this).balance);
        }
    }

    /// @dev when toToken == eth, call this function to get eth
    /// @param to The account address to receive ETH
    /// @param minAmount The minimum amount to withdraw
    function withdrawWETH(address to, uint256 minAmount) external payable {
        uint256 withdrawAmount = IWETH(_WETH_).balanceOf(address(this));
        require(withdrawAmount >= minAmount, "D3PROXY_WETH_NOT_ENOUGH");

        _withdrawWETH(to, withdrawAmount);
    }

    // ======= internal =======

    /// @notice Before the first pool swap, contract call _deposit to get ERC20 token through DODOApprove / transfer ETH to WETH
    /// @dev ETH transfer is allowed
    /// @param from The address which will transfer token out
    /// @param to The address which will receive the token
    /// @param token The token address
    /// @param value The token amount
    function _deposit(address from, address to, address token, uint256 value) internal {
        if (token == _WETH_ && address(this).balance >= value) {
            // pay with WETH9
            IWETH(_WETH_).deposit{value: value}(); // wrap only what is needed to pay
            IWETH(_WETH_).transfer(to, value);
        } else {
            // pull payment
            IDODOApproveProxy(_DODO_APPROVE_PROXY_).claimTokens(token, from, to, value);
        }
    }

    /// @dev Withdraw ETH from WETH
    /// @param to The account address to receive ETH
    /// @param withdrawAmount The amount to withdraw
    function _withdrawWETH(address to, uint256 withdrawAmount) internal {
        IWETH(_WETH_).withdraw(withdrawAmount);
        _safeTransferETH(to, withdrawAmount);
    }

    /// @notice Transfers ETH to the recipient address
    /// @dev Fails with `ETH_TRANSFER_FAIL`
    /// @param to The destination of the transfer
    /// @param value The value to be transferred
    function _safeTransferETH(address to, uint256 value) internal {
        (bool success,) = to.call{value: value}(new bytes(0));
        require(success, "D3PROXY_ETH_TRANSFER_FAIL");
    }
}
pragma solidity 0.8.16;

interface ID3Oracle {
    function getMaxReceive(address fromToken, address toToken, uint256 fromAmount) external view returns (uint256);
    function getPrice(address base) external view returns (uint256);
    function getDec18Price(address base) external view returns(uint256);
    function getOriginalPrice(address base) external view returns (uint256 price, uint8 priceDecimal);
    function isFeasible(address base) external view returns (bool);
}
pragma solidity 0.8.16;

interface IDODOApprove {
    function claimTokens(address token, address who, address dest, uint256 amount) external;
    function getDODOProxy() external view returns (address);
}
pragma solidity 0.8.16;

interface IDODOApproveProxy {
    function isAllowedProxy(address _proxy) external view returns (bool);
    function claimTokens(address token,address who,address dest,uint256 amount) external;
}
pragma solidity 0.8.16;

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
     * @dev Returns the symbol.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the name.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the decimals.
     */
    function decimals() external view returns (uint8);

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
pragma solidity 0.8.16;

interface IFeeRateModel {
    function getFeeRate(address token) external view returns (uint256);
}
pragma solidity 0.8.16;

interface IWETH {
    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function transfer(address recipient, uint256 amount) external returns (bool);

    function allowance(address owner, address spender) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function transferFrom(address src, address dst, uint256 wad) external returns (bool);

    function deposit() external payable;

    function withdraw(uint256 wad) external;
}
pragma solidity 0.8.16;

import {IFeeRateModel} from "../intf/IFeeRateModel.sol";
import "../DODOV3MM/lib/InitializableOwnable.sol";

contract D3FeeRateModel is IFeeRateModel, InitializableOwnable {
    mapping(address => bool) public isUsedFeeRate;
    mapping(address => uint256) public feeRateMap;
    uint256 public defaultFeeRate; 

    function init(address owner, uint256 _feeRate) public {
        initOwner(owner);
        defaultFeeRate = _feeRate;
    }

    function setDefaultFeeRate(uint256 newFeeRate) public onlyOwner {
        defaultFeeRate = newFeeRate;
    }

    function setIsUseFeeRate(address token, bool isUse) public onlyOwner {
        isUsedFeeRate[token] = isUse;
    }

    function setTokenFeeRate(address token, uint256 tokenFeeRate) public onlyOwner {
        feeRateMap[token] = tokenFeeRate;
    }

    function getFeeRate(address token) external view returns(uint256 feerate) {
        return isUsedFeeRate[token] ? feeRateMap[token] : defaultFeeRate;
    }
}
pragma solidity 0.8.16;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {InitializableOwnable} from "contracts/DODOV3MM/lib/InitializableOwnable.sol";

/**
 * @title DODOApprove
 * @author DODO Breeder
 *
 * @notice Handle authorizations in DODO platform
 */
contract DODOApprove is InitializableOwnable {
    using SafeERC20 for IERC20;

    // ============ Storage ============
    uint256 private constant _TIMELOCK_DURATION_ = 3 days;
    uint256 private constant _TIMELOCK_EMERGENCY_DURATION_ = 24 hours;
    uint256 public _TIMELOCK_;
    address public _PENDING_DODO_PROXY_;
    address public _DODO_PROXY_;

    // ============ Events ============

    event SetDODOProxy(address indexed oldProxy, address indexed newProxy);

    // ============ Modifiers ============
    modifier notLocked() {
        require(_TIMELOCK_ <= block.timestamp, "SetProxy is timelocked");
        _;
    }

    function init(address owner, address initProxyAddress) external {
        initOwner(owner);
        _DODO_PROXY_ = initProxyAddress;
    }

    function unlockSetProxy(address newDodoProxy) public onlyOwner {
        if (_DODO_PROXY_ == address(0)) {
            _TIMELOCK_ = block.timestamp + _TIMELOCK_EMERGENCY_DURATION_;
        } else {
            _TIMELOCK_ = block.timestamp + _TIMELOCK_DURATION_;
        }
        _PENDING_DODO_PROXY_ = newDodoProxy;
    }

    function lockSetProxy() public onlyOwner {
        _PENDING_DODO_PROXY_ = address(0);
        _TIMELOCK_ = 0;
    }

    function setDODOProxy() external onlyOwner notLocked {
        emit SetDODOProxy(_DODO_PROXY_, _PENDING_DODO_PROXY_);
        _DODO_PROXY_ = _PENDING_DODO_PROXY_;
        lockSetProxy();
    }

    function claimTokens(address token, address who, address dest, uint256 amount) external {
        require(msg.sender == _DODO_PROXY_, "DODOApprove:Access restricted");
        if (amount > 0) {
            IERC20(token).safeTransferFrom(who, dest, amount);
        }
    }

    function getDODOProxy() public view returns (address) {
        return _DODO_PROXY_;
    }

    // Make forge coverage ignore
    function testSuccess() public {}
}
pragma solidity 0.8.16;
pragma experimental ABIEncoderV2;

import {IDODOApprove} from "contracts/intf/IDODOApprove.sol";
import {InitializableOwnable} from "contracts/DODOV3MM/lib/InitializableOwnable.sol";

/**
 * @title DODOApproveProxy
 * @author DODO Breeder
 *
 * @notice Allow different version dodoproxy to claim from DODOApprove
 */
contract DODOApproveProxy is InitializableOwnable {
    // ============ Storage ============
    uint256 private constant _TIMELOCK_DURATION_ = 3;
    mapping(address => bool) public _IS_ALLOWED_PROXY_;
    uint256 public _TIMELOCK_;
    address public _PENDING_ADD_DODO_PROXY_;
    address public immutable _DODO_APPROVE_;

    // ============ Modifiers ============
    modifier notLocked() {
        require(_TIMELOCK_ <= block.timestamp, "SetProxy is timelocked");
        _;
    }

    constructor(address dodoApporve) {
        _DODO_APPROVE_ = dodoApporve;
    }

    function init(address owner, address[] memory proxies) external {
        initOwner(owner);
        for (uint256 i = 0; i < proxies.length; i++) {
            _IS_ALLOWED_PROXY_[proxies[i]] = true;
        }
    }

    function unlockAddProxy(address newDodoProxy) public onlyOwner {
        _TIMELOCK_ = block.timestamp + _TIMELOCK_DURATION_;
        _PENDING_ADD_DODO_PROXY_ = newDodoProxy;
    }

    function lockAddProxy() public onlyOwner {
        _PENDING_ADD_DODO_PROXY_ = address(0);
        _TIMELOCK_ = 0;
    }

    function addDODOProxy() external onlyOwner notLocked {
        _IS_ALLOWED_PROXY_[_PENDING_ADD_DODO_PROXY_] = true;
        lockAddProxy();
    }

    function removeDODOProxy(address oldDodoProxy) public onlyOwner {
        _IS_ALLOWED_PROXY_[oldDodoProxy] = false;
    }

    function claimTokens(address token, address who, address dest, uint256 amount) external {
        require(_IS_ALLOWED_PROXY_[msg.sender], "NOT_ALLOWED_PROXY");
        IDODOApprove(_DODO_APPROVE_).claimTokens(token, who, dest, amount);
    }

    function isAllowedProxy(address _proxy) external view returns (bool) {
        return _IS_ALLOWED_PROXY_[_proxy];
    }

    // Make forge coverage ignore
    function testSuccess() public {}
}
pragma solidity 0.8.16;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract MockChainlinkPriceFeed is AggregatorV3Interface {
    string public description;
    uint8 public decimals;
    uint256 public version = 1;
    int256 public price;
    uint80 public round;
    uint256 public startTime;
    uint256 public updateTime;

    constructor(string memory _description, uint8 _decimals) {
        description = _description;
        decimals = _decimals;
        startTime = block.timestamp;
    }

    function feedData(int256 _price) public {
        price = _price;
        round += 1;
        updateTime = block.timestamp;
    }

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        require(_roundId <= round, "wrong round id");
        roundId = _roundId;
        answer = price;
        startedAt = startTime;
        updatedAt = updateTime;
        answeredInRound = _roundId;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        roundId = round;
        answer = price;
        startedAt = startTime;
        updatedAt = block.timestamp;
        answeredInRound = round;
    }

    // Make forge coverage ignore
    function testSuccess() public {}
}
pragma solidity 0.8.16;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

// This mock can return price based on block.timestamp
contract MockChainlinkPriceFeed2 is AggregatorV3Interface {
    string public description;
    uint8 public decimals;
    uint256 public version = 1;
    int256 public price = 1e8; // default decimals is 8
    uint80 public round;
    uint256 public startTime;
    uint256 public updateTime;

    constructor(string memory _description, uint8 _decimals) {
        description = _description;
        decimals = _decimals;
        startTime = block.timestamp;
    }

    function feedData(int256 _price) public {
        price = _price;
        round += 1;
        updateTime = block.timestamp;
    }

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        require(_roundId <= round, "wrong round id");
        roundId = _roundId;
        answer = price;
        startedAt = startTime;
        updatedAt = updateTime;
        answeredInRound = _roundId;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        roundId = round;
        answer = price * (int256(block.timestamp) % 10000); // price will change based on timestamp
        startedAt = startTime;
        updatedAt = updateTime;
        answeredInRound = round;
    }

    // Make forge coverage ignore
    function testSuccess() public {}
}
pragma solidity 0.8.16;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockChainlinkPriceFeed3 is AggregatorV3Interface, Ownable {
    string public description;
    uint8 public decimals;
    uint256 public version = 1;
    int256 public price;
    uint80 public round;
    uint256 public startTime;
    uint256 public updateTime;

    constructor(string memory _description, uint8 _decimals) {
        description = _description;
        decimals = _decimals;
        startTime = block.timestamp;
    }

    function feedData(int256 _price) public {
        price = _price;
        round += 1;
        updateTime = block.timestamp;
    }

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        require(_roundId <= round, "wrong round id");
        roundId = _roundId;
        answer = price;
        startedAt = startTime;
        updatedAt = updateTime;
        answeredInRound = _roundId;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        roundId = round;
        answer = price;
        startedAt = startTime;
        updatedAt = updateTime;
        answeredInRound = round;
    }

    // Make forge coverage ignore
    function testSuccess() public {}
}
pragma solidity 0.8.16;

contract MockD3MM is D3MM {
    function updateReserve(address token) external {
        _updateReserve(token);
    }

    function setAllFlagByAnyone(uint256 newFlag) external {
        allFlag = newFlag;
    }

    function getTokenFlag(address token) external view returns (uint256){
        (, uint256 tokenIndex) = ID3Maker(state._MAKER_).getTokenMMInfoForPool(token);
        return (allFlag >> (tokenIndex) & 1);
    }
}
pragma solidity 0.8.16;

contract MockD3MMFactory is D3MMFactory {
    constructor(
        address owner,
        address[] memory d3Temps,
        address[] memory d3MakerTemps,
        address cloneFactory,
        address d3VaultAddress,
        address oracleAddress,
        address feeRateModel,
        address maintainer
    ) D3MMFactory(
        owner,
        d3Temps,
        d3MakerTemps,
        cloneFactory,
        d3VaultAddress,
        oracleAddress,
        feeRateModel,
        maintainer
    ) {}

    function addD3Pool(address pool) public {
        d3Vault.addD3PoolByFactory(pool);
    }
}
pragma solidity 0.8.16;

import {InitializableOwnable} from "../DODOV3MM/lib/InitializableOwnable.sol";
import {ID3Oracle} from "../intf/ID3Oracle.sol";
import "../DODOV3MM/lib/DecimalMath.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

struct PriceSource {
    uint256 price; // price in USD
    bool isWhitelisted;
    uint256 priceTolerance;
    uint8 priceDecimal;
}

contract MockD3Oracle is ID3Oracle, InitializableOwnable {
    // originToken => priceSource
    mapping(address => PriceSource) public priceSources;

    function setPriceSource(address token, PriceSource calldata source) external onlyOwner {
        priceSources[token] = source;
        require(source.priceTolerance <= DecimalMath.ONE, "INVALID_PRICE_TOLERANCE");
    }

    // return 1e18 decimal
    function getPrice(address token) public view override returns (uint256) {
        return priceSources[token].price;
    }

    function getDec18Price(address token) public view override returns (uint256) {
        return priceSources[token].price;
    }

    function isFeasible(address token) external view override returns (bool) {
        return priceSources[token].isWhitelisted;
    }

    // given the amount of fromToken, how much toToken can return at most
    function getMaxReceive(address fromToken, address toToken, uint256 fromAmount) external view returns (uint256) {
        uint256 fromTlr = priceSources[fromToken].priceTolerance;
        uint256 toTlr = priceSources[toToken].priceTolerance;

        return DecimalMath.div((fromAmount * getDec18Price(fromToken)) / getDec18Price(toToken), DecimalMath.mul(fromTlr, toTlr));
    }

    function getOriginalPrice(address token) public view override returns (uint256 price, uint8 priceDecimal) {
        return (getPrice(token), 8);
    }

    function testSuccess() public {}
}
pragma solidity 0.8.16;

contract MockD3Pool {
    address public _CREATOR_;
    uint256 public allFlag;
    
    constructor() {
        _CREATOR_ = msg.sender;
    }

    function setNewAllFlag(uint256 newFlag) public {
        allFlag = newFlag;
    }

    function getFeeRate(address) public pure returns(uint256){
        return 2 * (10 ** 14);
    }

    function testSuccess() public {}
}
pragma solidity 0.8.16;

import "contracts/DODOV3MM/lib/PMMRangeOrder.sol";
import {ID3MM} from "contracts/DODOV3MM/intf/ID3MM.sol";
import {IWETH} from "contracts/intf/IWETH.sol";
import {IDODOSwapCallback} from "contracts/DODOV3MM/intf/IDODOSwapCallback.sol";
import {IDODOApproveProxy} from "contracts/intf/IDODOApproveProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockFailD3Proxy is IDODOSwapCallback {
    using SafeERC20 for IERC20;

    address immutable public _DODO_APPROVE_PROXY_;
    address immutable public _WETH_;
    address immutable public _ETH_ADDRESS_ = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    struct SwapCallbackData {
        bytes data;
        address payer;
    }

    // ============ Modifiers ============

    modifier judgeExpired(uint256 deadLine) {
        require(deadLine >= block.timestamp, "DODORouteProxy: EXPIRED");
        _;
    }

    // ============ Constructor ============
    
    constructor(address approveProxy, address weth) {
        _DODO_APPROVE_PROXY_ = approveProxy;
        _WETH_ = weth;
    }

    function sellTokens(
        address pool,
        address to,
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 minReceiveAmount,
        bytes calldata data,
        uint256 deadLine
    ) public payable judgeExpired(deadLine) returns(uint256 receiveToAmount) {
        receiveToAmount = ID3MM(pool).sellToken(to, fromToken, toToken, fromAmount, minReceiveAmount, data);
    }

    function buyTokens(
        address pool,
        address to,
        address fromToken,
        address toToken,
        uint256 quoteAmount,
        uint256 maxPayAmount,
        bytes calldata data,
        uint256 deadLine
    ) public payable judgeExpired(deadLine) returns(uint256 payFromAmount) {
        payFromAmount = ID3MM(pool).buyToken(to, fromToken, toToken, quoteAmount, maxPayAmount, data);
    }

    function d3MMSwapCallBack(
        address token,
        uint256 /* value */,
        bytes calldata _data
    ) external override {
        SwapCallbackData memory decodeData;
        decodeData = abi.decode(_data, (SwapCallbackData));
        _deposit(decodeData.payer, msg.sender, token, 1000);
    }

    // ======= internal =======

    /// @notice before the first pool swap, contract call _deposit to get ERC20 token through DODOApprove/transfer ETH to WETH
    function _deposit(
        address from,
        address to,
        address token,
        uint256 value
    ) internal {
        if (token == _WETH_ && address(this).balance >= value) {
            // pay with WETH9
            IWETH(_WETH_).deposit{value: value}(); // wrap only what is needed to pay
            IWETH(_WETH_).transfer(to, value);
        } else if (from == address(this)) {
            // pay with tokens already in the contract (for the exact input multihop case)
            SafeERC20.safeTransfer(IERC20(token), to, value);
        } else {
            // pull payment
            IDODOApproveProxy(_DODO_APPROVE_PROXY_).claimTokens(token, from, to, value);
        }
    }

    function testSuccess() public {}
}
pragma solidity 0.8.16;

import "contracts/DODOV3MM/intf/ID3UserQuota.sol";

contract MockD3UserQuota is ID3UserQuota {
    mapping(address => mapping(address => uint256)) internal quota; // user => (token => amount)

    function setUserQuota(address user, address token, uint256 amount) external {
        quota[user][token] = amount;
    }

    function getUserQuota(address user, address token) external view returns (uint256) {
        return quota[user][token];
    }

    function checkQuota(address user, address token, uint256 amount) external view returns (bool) {
        return amount <= quota[user][token];
    }
}
pragma solidity 0.8.16;

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;

    mapping(address => uint256) internal balances;
    mapping(address => mapping(address => uint256)) internal allowed;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        require(to != address(0), "TO_ADDRESS_IS_EMPTY");
        require(amount <= balances[msg.sender], "BALANCE_NOT_ENOUGH");

        balances[msg.sender] = balances[msg.sender] - amount;
        balances[to] = balances[to] + amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function balanceOf(address owner) public view returns (uint256 balance) {
        return balances[owner];
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        require(to != address(0), "TO_ADDRESS_IS_EMPTY");
        require(amount <= balances[from], "BALANCE_NOT_ENOUGH");
        require(amount <= allowed[from][msg.sender], "ALLOWANCE_NOT_ENOUGH");

        balances[from] = balances[from] - amount;
        balances[to] = balances[to] + amount;
        allowed[from][msg.sender] = allowed[from][msg.sender] - amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowed[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function allowance(address owner, address spender) public view returns (uint256) {
        return allowed[owner][spender];
    }

    function mint(address account, uint256 amount) external {
        balances[account] = balances[account] + amount;
    }

    function burn(address account, uint256 amount) external {
        if (balances[account] < amount) {
            balances[account] = 0;
        } else {
            balances[account] = balances[account] - amount;
        }
    }

    // comment this function out because Ethersjs cannot tell two functions with same name
    // function mint(uint256 amount) external {
    //     balances[msg.sender] = balances[msg.sender] + amount;
    // }

    // Make forge coverage ignore
    function testSuccess() public {}
}
pragma solidity 0.8.16;

import {IFeeRateModel} from "../intf/IFeeRateModel.sol";
import "../DODOV3MM/lib/InitializableOwnable.sol";

contract MockFeeRateModel is IFeeRateModel, InitializableOwnable {
    mapping(address => bool) public isUsedFeeRate;
    mapping(address => uint256) public feeRateMap;
    uint256 public defaultFeeRate; 

    function init(address owner, uint256 _feeRate) public {
        initOwner(owner);
        defaultFeeRate = _feeRate;
    }

    function setDefaultFeeRate(uint256 newFeeRate) public onlyOwner {
        defaultFeeRate = newFeeRate;
    }

    function setIsUseFeeRate(address token, bool isUse) public onlyOwner {
        isUsedFeeRate[token] = isUse;
    }

    function setTokenFeeRate(address token, uint256 tokenFeeRate) public onlyOwner {
        feeRateMap[token] = tokenFeeRate;
    }

    function getFeeRate(address token) external view returns(uint256 feerate) {
        return isUsedFeeRate[token] ? feeRateMap[token] : defaultFeeRate;
    }

    function testSuccess() public {}
}
pragma solidity 0.8.16;

import "contracts/intf/ID3Oracle.sol";
import "./MockERC20.sol";

contract MockRouter {
    address public oracle;
    bool public enable = true;
    uint256 public slippage = 100;

    constructor(address _oracle) {
        oracle = _oracle;
    }

    function enableRouter() public {
        enable = true;
    }

    function disableRouter() public {
        enable = false;
    }

    function setSlippage(uint256 s) public {
        slippage = s;
    }

    function swap(address fromToken, address toToken, uint256 fromAmount) public {
        require(enable, "router not available");
        uint256 fromTokenPrice = ID3Oracle(oracle).getPrice(fromToken);
        uint256 toTokenPrice = ID3Oracle(oracle).getPrice(toToken);
        uint256 toAmount = (fromAmount * fromTokenPrice) / toTokenPrice;
        toAmount = toAmount * slippage / 100;
        MockERC20(toToken).transfer(msg.sender, toAmount);
    }

    // Make forge coverage ignore
    function testSuccess() public {}
}
pragma solidity 0.8.16;

contract WETH9 {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;

    event Approval(address indexed src, address indexed guy, uint256 wad);
    event Transfer(address indexed src, address indexed dst, uint256 wad);
    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    fallback() external payable {
        deposit();
    }

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) public {
        require(balanceOf[msg.sender] >= wad);
        balanceOf[msg.sender] -= wad;
        payable(msg.sender).transfer(wad);
        emit Withdrawal(msg.sender, wad);
    }

    function totalSupply() public view returns (uint256) {
        return address(this).balance;
    }

    function approve(address guy, uint256 wad) public returns (bool) {
        allowance[msg.sender][guy] = wad;
        emit Approval(msg.sender, guy, wad);
        return true;
    }

    function transfer(address dst, uint256 wad) public returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    function transferFrom(address src, address dst, uint256 wad) public returns (bool) {
        require(balanceOf[src] >= wad);

        if (src != msg.sender && allowance[src][msg.sender] != type(uint256).max) {
            require(allowance[src][msg.sender] >= wad);
            allowance[src][msg.sender] -= wad;
        }

        balanceOf[src] -= wad;
        balanceOf[dst] += wad;

        emit Transfer(src, dst, wad);

        return true;
    }

    function testSuccess() public {}
}
