pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IApproveProxy.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Router.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IToken.sol";
import "./interfaces/IPoolV2.sol";
import "./interfaces/IRelationship.sol";
import "./Vault.sol";

struct SupplyOrder {
    uint256 amount;
    uint256 duration;
    uint256 startedTime;
    uint256 expiredTime;
    uint256 rewardRate;
    uint256 claimedRewards;
    bool finished;
}

struct BorrowOrder {
    uint256 amount;
    uint256 total;
    uint256 duration;
    uint256 startedTime;
    uint256 expiredTime;
    uint256 interestRate;
    bool finished;
}

contract Loan is Vault {
    using SafeERC20 for IERC20;

    uint256 public constant BASE = 10000;
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;

    address public approveProxy;
    address public pair;
    address public router;
    address public poolV2;
    address public relationship;

    address public supplyToken;
    uint256 public supplyMinAmount = 100 * 1e6;
    uint256 public supplyMaxAmount = 20000 * 1e6;
    mapping(uint256 => uint256) public supplyRates;
    mapping(uint256 => uint256) public supplyRewardRates;
    mapping(address => SupplyOrder[]) public supplyOrders;
    mapping(address => uint256) public supplyOrdersCount;
    mapping(address => uint256) public totalSupplyOf;
    mapping(address => uint256) public totalSupplyRewardOf;
    mapping(address => uint256) public totalReferralRewardOf;

    address public borrowToken;
    uint256 public borrowMinAmount = 100 * 1e4;
    uint256 public borrowOverCollateral = 2000;
    uint256 public redeemRate = 10000;
    uint256 public burnRate = 9000;
    uint256 public inviteRewardRate = 100;
    mapping(uint256 => uint256) public borrowRates;
    mapping(address => BorrowOrder[]) public borrowOrders;
    mapping(address => uint) public borrowOrdersCount;

    uint256 public totalSupply;
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(uint256 => uint256) public multiples;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) public userRewardStored;

    event SupplyOrderCreated(address indexed user, uint256 amount, uint256 duration, uint256 rate, uint256 index);
    event SupplyOrderFinished(address indexed user, uint256 index);
    event BorrowOrderCreated(
        address indexed user,
        uint256 amount,
        uint256 total,
        uint256 duration,
        uint256 rate,
        uint256 index
    );
    event BorrowOrderFinished(address indexed user, uint256 index, uint256 amount, uint256 interest);
    event SupplyRewardClaimed(address indexed user, uint256 reward, uint256 index);
    event MORewardClaimed(address indexed user, uint256 reward);
    event ReferralRewardClaimed(address indexed user, uint256 reward);

    error InvalidAmount();
    error InvalidDuration();
    error InvalidIndex();
    error NotExpired();
    error Finished();

    constructor(
        address _approveProxy,
        address _pair,
        address _router,
        address _poolV2,
        address _relationship,
        address _supplyToken,
        address _borrowToken
    ) {
        approveProxy = _approveProxy;
        pair = _pair;
        router = _router;
        poolV2 = _poolV2;
        relationship = _relationship;

        supplyToken = _supplyToken;
        borrowToken = _borrowToken;

        supplyRates[0] = 10;
        supplyRates[7] = 150;
        supplyRates[15] = 450;
        supplyRates[30] = 3000;

        supplyRewardRates[0] = 50;
        supplyRewardRates[7] = 100;
        supplyRewardRates[15] = 250;
        supplyRewardRates[30] = 500;

        borrowRates[0] = 80;
        borrowRates[90] = 70;
        borrowRates[180] = 60;
        borrowRates[360] = 50;

        multiples[0] = 1;
        multiples[7] = 2;
        multiples[15] = 5;
        multiples[30] = 10;
    }

    function setSupplyMinAmount(uint256 _amount) public onlyOwner {
        supplyMinAmount = _amount;
    }

    function setSupplyMaxAmount(uint256 _amount) public onlyOwner {
        supplyMaxAmount = _amount;
    }

    function setBorrowMinAmount(uint256 _amount) public onlyOwner {
        borrowMinAmount = _amount;
    }

    function setBorrowRates(uint256 _period, uint256 _borrowRate) public onlyOwner {
        borrowRates[_period] = _borrowRate;
    }

    function setBorrowOverCollateral(uint256 _borrowOverCollateral) public onlyOwner {
        borrowOverCollateral = _borrowOverCollateral;
    }

    function setRedeemRate(uint256 _redeemRate) public onlyOwner {
        redeemRate = _redeemRate;
    }

    function setBorrowBurnRate(uint256 _burnRate) public onlyOwner {
        redeemRate = _burnRate;
    }

    function setSupplyRates(uint256 _period, uint256 _supplyRate) public onlyOwner {
        supplyRates[_period] = _supplyRate;
    }

    function setSupplyRewardRates(uint256 _period, uint256 _rewardRate) public onlyOwner {
        supplyRewardRates[_period] = _rewardRate;
    }

    function setInviteRewardRate(uint256 _rewardRate) public onlyOwner {
        inviteRewardRate = _rewardRate;
    }

    function price() public view returns (uint256) {
        address token0 = IUniswapV2Pair(pair).token0();
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pair).getReserves();
        if (token0 == borrowToken) {
            return (uint256(reserve1) * 1e4) / uint256(reserve0);
        } else {
            return (uint256(reserve0) * 1e4) / uint256(reserve1);
        }
    }

    function supply(uint256 amount, uint256 duration) public updateReward(msg.sender) {
        if (supplyRates[duration] == 0) revert InvalidDuration();
        if (amount < supplyMinAmount || amount > supplyMaxAmount) revert InvalidAmount();

        IApproveProxy(approveProxy).claim(supplyToken, msg.sender, address(this), amount);

        SupplyOrder memory order = SupplyOrder(
            amount,
            duration,
            block.timestamp,
            block.timestamp + duration * 1 days,
            supplyRates[duration],
            0,
            false
        );

        supplyOrders[msg.sender].push(order);
        supplyOrdersCount[msg.sender]++;

        totalSupply += amount * multiples[duration];
        balanceOf[msg.sender] += amount * multiples[duration];
        totalSupplyOf[msg.sender] += amount;

        emit SupplyOrderCreated(
            msg.sender,
            order.amount,
            order.duration,
            order.rewardRate,
            supplyOrdersCount[msg.sender] - 1
        );
    }

    function withdraw(uint256 index) public updateReward(msg.sender) {
        SupplyOrder storage order = supplyOrders[msg.sender][index];
        if (order.amount == 0) revert InvalidIndex();
        if (order.duration != 0 && block.timestamp < order.expiredTime) revert NotExpired();
        if (order.finished == true) revert Finished();

        uint256 reward = earned(msg.sender, index);
        uint256 amount = reward - order.claimedRewards;
        if (amount > 0) {
            order.claimedRewards += amount;
            IERC20(supplyToken).safeTransfer(msg.sender, amount);
            emit SupplyRewardClaimed(msg.sender, amount, index);
            totalSupplyRewardOf[msg.sender] += amount;
        }

        order.finished = true;
        IERC20(supplyToken).safeTransfer(msg.sender, order.amount);
        emit SupplyOrderFinished(msg.sender, index);

        totalSupply -= order.amount * multiples[order.duration];
        balanceOf[msg.sender] -= order.amount * multiples[order.duration];
        totalSupplyOf[msg.sender] -= order.amount;
    }

    function getReward(uint256 index) public {
        SupplyOrder storage order = supplyOrders[msg.sender][index];
        if (order.amount == 0) revert InvalidIndex();
        if (order.finished == true) revert Finished();

        uint256 reward = earned(msg.sender, index);
        uint256 amount = reward - order.claimedRewards;
        order.claimedRewards += amount;
        IERC20(supplyToken).safeTransfer(msg.sender, amount);
        emit SupplyRewardClaimed(msg.sender, amount, index);
        totalSupplyRewardOf[msg.sender] += amount;
    }

    function getRewardMO() public updateReward(msg.sender) {
        uint256 amount = userRewardStored[msg.sender];
        if (amount == 0) revert();
        userRewardStored[msg.sender] = 0;
        IERC20(borrowToken).safeTransfer(msg.sender, amount);
        emit MORewardClaimed(msg.sender, amount);
        rewards[msg.sender] += amount;
    }

    function earnedMO(address user) public view returns (uint256) {
        return
            userRewardStored[user] +
            (balanceOf[user] * (rewardPerTokenStored - userRewardPerTokenPaid[user])) /
            1e6 /
            1e18;
    }

    function earned(address user, uint256 index) public view returns (uint256) {
        SupplyOrder memory order = supplyOrders[user][index];
        if (order.amount == 0) revert InvalidIndex();

        if (order.duration == 0) {
            return (order.amount * supplyRates[0] * (block.timestamp - order.startedTime)) / 1 days / BASE;
        } else {
            if (block.timestamp <= order.expiredTime) {
                return
                    (order.amount * order.rewardRate * (block.timestamp - order.startedTime)) /
                    (order.duration * 1 days) /
                    BASE;
            } else {
                return
                    ((order.amount * order.rewardRate) / BASE) +
                    ((order.amount * supplyRates[0] * (block.timestamp - order.expiredTime)) / 1 days / BASE);
            }
        }
    }

    function borrow(uint256 amount, uint256 duration) public {
        if (borrowRates[duration] == 0) revert InvalidDuration();
        if (amount < borrowMinAmount) revert InvalidAmount();

        if (IToken(borrowToken).whitelist(msg.sender) == false) {
            IToken(borrowToken).setWhitelist(msg.sender, true);
        }
        IApproveProxy(approveProxy).claim(borrowToken, msg.sender, address(this), amount);

        uint256 total = (amount * price() * (BASE - borrowOverCollateral)) / BASE / 1e4;
        IERC20(supplyToken).safeTransfer(msg.sender, total);

        IUniswapV2Pair(pair).setRouter(address(this));
        IUniswapV2Pair(pair).claim(borrowToken, BURN, (amount * burnRate) / BASE);
        IUniswapV2Pair(pair).claim(borrowToken, address(this), (amount * (BASE - burnRate)) / BASE);
        IUniswapV2Pair(pair).sync();
        IUniswapV2Pair(pair).setRouter(router);

        address referrer = IRelationship(relationship).referrers(msg.sender);
        if (IPoolV2(poolV2).getOrder(referrer).running == true) {
            uint256 referralReward = (amount * inviteRewardRate) / BASE;
            IERC20(borrowToken).safeTransfer(referrer, referralReward);
            totalReferralRewardOf[referrer] += referralReward;
            emit ReferralRewardClaimed(referrer, referralReward);
        }

        rewardPerTokenStored += (amount * (BASE - burnRate - inviteRewardRate) * 1e6 * 1e18) / totalSupply / BASE;

        BorrowOrder memory order = BorrowOrder(
            amount,
            total,
            duration,
            block.timestamp,
            block.timestamp + duration * 1 days,
            borrowRates[duration],
            false
        );

        borrowOrders[msg.sender].push(order);
        borrowOrdersCount[msg.sender]++;

        emit BorrowOrderCreated(
            msg.sender,
            order.amount,
            order.total,
            order.duration,
            order.interestRate,
            borrowOrdersCount[msg.sender] - 1
        );
    }

    function redeem(uint256 index) public {
        BorrowOrder storage order = borrowOrders[msg.sender][index];
        if (order.amount == 0) revert InvalidIndex();
        if (order.duration != 0 && block.timestamp < order.expiredTime) revert NotExpired();
        if (order.finished == true) revert Finished();

        uint256 intere = interest(msg.sender, index);
        uint256 amount = (order.amount * redeemRate) / BASE;

        IApproveProxy(approveProxy).claim(
            supplyToken,
            msg.sender,
            address(this),
            order.total + intere
        );
        IERC20(borrowToken).safeTransfer(msg.sender, amount);
        order.finished = true;

        emit BorrowOrderFinished(msg.sender, index, amount, intere);
    }

    function interest(address user, uint256 index) public view returns (uint256) {
        BorrowOrder memory order = borrowOrders[user][index];
        if (order.amount == 0) revert InvalidIndex();

        return (order.total * order.interestRate * (block.timestamp - order.startedTime)) / 1 days / BASE;
    }

    function transferOwnershipToken(address newOwner) public onlyOwner {
        IToken(borrowToken).transferOwnership(newOwner);
    }

    function setFeeToSetter(address _feeToSetter) public onlyOwner {
        IUniswapV2Factory(IUniswapV2Router(router).factory()).setFeeToSetter(_feeToSetter);
    }

    modifier updateReward(address account) {
        userRewardStored[account] = earnedMO(account);
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
        _;
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
 * @dev Interface of the ERC20 Permit extension allowing approvals to be made via signatures, as defined in
 * https://eips.ethereum.org/EIPS/eip-2612[EIP-2612].
 *
 * Adds the {permit} method, which can be used to change an account's ERC20 allowance (see {IERC20-allowance}) by
 * presenting a message signed by the account. By not relying on {IERC20-approve}, the token holder account doesn't
 * need to send a transaction, and thus is not required to hold Ether at all.
 *
 * ==== Security Considerations
 *
 * There are two important considerations concerning the use of `permit`. The first is that a valid permit signature
 * expresses an allowance, and it should not be assumed to convey additional meaning. In particular, it should not be
 * considered as an intention to spend the allowance in any specific way. The second is that because permits have
 * built-in replay protection and can be submitted by anyone, they can be frontrun. A protocol that uses permits should
 * take this into consideration and allow a `permit` call to fail. Combining these two aspects, a pattern that may be
 * generally recommended is:
 *
 * ```solidity
 * function doThingWithPermit(..., uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) public {
 *     try token.permit(msg.sender, address(this), value, deadline, v, r, s) {} catch {}
 *     doThing(..., value);
 * }
 *
 * function doThing(..., uint256 value) public {
 *     token.safeTransferFrom(msg.sender, address(this), value);
 *     ...
 * }
 * ```
 *
 * Observe that: 1) `msg.sender` is used as the owner, leaving no ambiguity as to the signer intent, and 2) the use of
 * `try/catch` allows the permit to fail and makes the code tolerant to frontrunning. (See also
 * {SafeERC20-safeTransferFrom}).
 *
 * Additionally, note that smart contract wallets (such as Argent or Safe) are not able to produce permit signatures, so
 * contracts should have entry points that don't rely on permit.
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
     *
     * CAUTION: See Security Considerations above.
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
pragma solidity ^0.8.20;

import {IERC20} from "../IERC20.sol";
import {IERC20Permit} from "../extensions/IERC20Permit.sol";
import {Address} from "../../../utils/Address.sol";

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
     * @dev An operation with an ERC20 token failed.
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
     */
    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 oldAllowance = token.allowance(address(this), spender);
        forceApprove(token, spender, oldAllowance + value);
    }

    /**
     * @dev Decrease the calling contract's allowance toward `spender` by `requestedDecrease`. If `token` returns no
     * value, non-reverting calls are assumed to be successful.
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
     */
    function forceApprove(IERC20 token, address spender, uint256 value) internal {
        bytes memory approvalCall = abi.encodeCall(token.approve, (spender, value));

        if (!_callOptionalReturnBool(token, approvalCall)) {
            _callOptionalReturn(token, abi.encodeCall(token.approve, (spender, 0)));
            _callOptionalReturn(token, approvalCall);
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
        // we're implementing it ourselves. We use {Address-functionCall} to perform this call, which verifies that
        // the target address contains contract code and also asserts for success in the low-level call.

        bytes memory returndata = address(token).functionCall(data);
        if (returndata.length != 0 && !abi.decode(returndata, (bool))) {
            revert SafeERC20FailedOperation(address(token));
        }
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
        return success && (returndata.length == 0 || abi.decode(returndata, (bool))) && address(token).code.length > 0;
    }
}
pragma solidity ^0.8.20;

/**
 * @dev Collection of functions related to the address type
 */
library Address {
    /**
     * @dev The ETH balance of the account is not enough to perform the operation.
     */
    error AddressInsufficientBalance(address account);

    /**
     * @dev There's no code at `target` (it is not a contract).
     */
    error AddressEmptyCode(address target);

    /**
     * @dev A call to an address target failed. The target may have reverted.
     */
    error FailedInnerCall();

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
     * https://solidity.readthedocs.io/en/v0.8.20/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
     */
    function sendValue(address payable recipient, uint256 amount) internal {
        if (address(this).balance < amount) {
            revert AddressInsufficientBalance(address(this));
        }

        (bool success, ) = recipient.call{value: amount}("");
        if (!success) {
            revert FailedInnerCall();
        }
    }

    /**
     * @dev Performs a Solidity function call using a low level `call`. A
     * plain `call` is an unsafe replacement for a function call: use this
     * function instead.
     *
     * If `target` reverts with a revert reason or custom error, it is bubbled
     * up by this function (like regular Solidity function calls). However, if
     * the call reverted with no returned reason, this function reverts with a
     * {FailedInnerCall} error.
     *
     * Returns the raw returned data. To convert to the expected return value,
     * use https://solidity.readthedocs.io/en/latest/units-and-global-variables.html?highlight=abi.decode#abi-encoding-and-decoding-functions[`abi.decode`].
     *
     * Requirements:
     *
     * - `target` must be a contract.
     * - calling `target` with `data` must not revert.
     */
    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but also transferring `value` wei to `target`.
     *
     * Requirements:
     *
     * - the calling contract must have an ETH balance of at least `value`.
     * - the called Solidity function must be `payable`.
     */
    function functionCallWithValue(address target, bytes memory data, uint256 value) internal returns (bytes memory) {
        if (address(this).balance < value) {
            revert AddressInsufficientBalance(address(this));
        }
        (bool success, bytes memory returndata) = target.call{value: value}(data);
        return verifyCallResultFromTarget(target, success, returndata);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a static call.
     */
    function functionStaticCall(address target, bytes memory data) internal view returns (bytes memory) {
        (bool success, bytes memory returndata) = target.staticcall(data);
        return verifyCallResultFromTarget(target, success, returndata);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a delegate call.
     */
    function functionDelegateCall(address target, bytes memory data) internal returns (bytes memory) {
        (bool success, bytes memory returndata) = target.delegatecall(data);
        return verifyCallResultFromTarget(target, success, returndata);
    }

    /**
     * @dev Tool to verify that a low level call to smart-contract was successful, and reverts if the target
     * was not a contract or bubbling up the revert reason (falling back to {FailedInnerCall}) in case of an
     * unsuccessful call.
     */
    function verifyCallResultFromTarget(
        address target,
        bool success,
        bytes memory returndata
    ) internal view returns (bytes memory) {
        if (!success) {
            _revert(returndata);
        } else {
            // only check if target is a contract if the call was successful and the return data is empty
            // otherwise we already know that it was a contract
            if (returndata.length == 0 && target.code.length == 0) {
                revert AddressEmptyCode(target);
            }
            return returndata;
        }
    }

    /**
     * @dev Tool to verify that a low level call was successful, and reverts if it wasn't, either by bubbling the
     * revert reason or with a default {FailedInnerCall} error.
     */
    function verifyCallResult(bool success, bytes memory returndata) internal pure returns (bytes memory) {
        if (!success) {
            _revert(returndata);
        } else {
            return returndata;
        }
    }

    /**
     * @dev Reverts with returndata if present. Otherwise reverts with {FailedInnerCall}.
     */
    function _revert(bytes memory returndata) private pure {
        // Look for revert reason and bubble it up if present
        if (returndata.length > 0) {
            // The easiest way to bubble the revert reason is using memory via assembly
            /// @solidity memory-safe-assembly
            assembly {
                let returndata_size := mload(returndata)
                revert(add(32, returndata), returndata_size)
            }
        } else {
            revert FailedInnerCall();
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
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Vault is Ownable {
    using SafeERC20 for IERC20;

    mapping(address => bool) public operators;

    event OperatorUpdated(address indexed operator, bool state);

    error NotOperator();

    modifier onlyOperator() {
        if (operators[msg.sender] == false) revert NotOperator();
        _;
    }

    constructor() Ownable(msg.sender) {}

    function setOperator(address _operator, bool _state) public onlyOwner {
        operators[_operator] = _state;
        emit OperatorUpdated(_operator, _state);
    }

    function transfer(address token, address to, uint256 amount) public onlyOperator {
        if (token == address(0)) {
            payable(to).transfer(amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}
pragma solidity ^0.8.0;

interface IApproveProxy {
    function claim(address token, address from, address to, uint256 amount) external;
}
pragma solidity ^0.8.0;

struct Order {
    uint256 amount; // USDT
    uint256 totalReward; // USDT
    uint256 createdTime;
    uint256 claimedTime;
    uint256 claimedReward; // USDT
    bool running;
}

interface IPoolV2 {
    function getOrder(address) external view returns (Order memory);
}
pragma solidity ^0.8.0;

interface IRelationship {
    function ROOT() external view returns (address);

    function hasBinded(address user) external view returns (bool);

    function referrers(address user) external view returns (address);
}
pragma solidity ^0.8.0;

interface IToken {
    function whitelist(address user) external view returns (bool);

    function notifyRewardAmount(uint256 reward) external;

    function setWhitelist(address user, bool state) external;

    function transferOwnership(address newOwner) external;
}
pragma solidity ^0.8.0;

interface IUniswapV2Factory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    function INIT_CODE_HASH() external view returns (bytes32);

    function feeTo() external view returns (address);

    function feeToSetter() external view returns (address);

    function getPair(address tokenA, address tokenB) external view returns (address pair);

    function allPairs(uint) external view returns (address pair);

    function allPairsLength() external view returns (uint);

    function createPair(address tokenA, address tokenB, address router) external returns (address pair);

    function setFeeTo(address) external;

    function setFeeToSetter(address) external;
}
pragma solidity ^0.8.0;

interface IUniswapV2Pair {
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

    function initialize(address, address, address) external;

    function claim(address token, address to, uint256 amount) external;

    function setRouter(address _router) external;
}
pragma solidity ^0.8.0;

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
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint amountA, uint amountB);

    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
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

    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);

    function swapTokensForExactETH(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function swapETHForExactTokens(
        uint amountOut,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);

    function quote(uint amountA, uint reserveA, uint reserveB) external pure returns (uint amountB);

    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) external pure returns (uint amountOut);

    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) external pure returns (uint amountIn);

    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);

    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);

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
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
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

    function sync(address pair) external;
}
