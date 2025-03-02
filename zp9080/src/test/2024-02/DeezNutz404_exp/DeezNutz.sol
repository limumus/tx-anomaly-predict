pragma solidity ^0.8.4;

import "./DN404Reflect.sol";
import "./DN404Mirror.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract DeezNutz is DN404Reflect, Ownable {
    string private _name;
    string private _symbol;
    string private baseTokenURI;
    bool private isHidden;
    bool private tradingEnabled;
    address private uniswapV2Router;

    constructor(address uniswapV2Router_) Ownable(tx.origin) {
        _name = "DeezNutz";
        _symbol = "DN";
        isHidden = true;
        uniswapV2Router = uniswapV2Router_;
    }

    /*&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-*/
    /*                          METADATA                          */
    /*-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;*/

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function setTokenURI(string memory _tokenURI) public onlyOwner {
        baseTokenURI = _tokenURI;
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        if (!_exists(id)) revert TokenDoesNotExist();
        if (isHidden) return baseTokenURI;
        return string.concat(baseTokenURI, Strings.toString(id), ".json");
    }

    /*&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-*/
    /*                         TRANSFERS                          */
    /*-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;*/
    function transfer(
        address to,
        uint256 amount
    ) public override returns (bool) {
        if (!tradingEnabled) {
            require(msg.sender == owner(), "Trading is not enabled");
        }
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        if (!tradingEnabled) {
            require(
                msg.sender == owner() || (msg.sender == uniswapV2Router && from == owner()),
                "Trading is not enabled"
            );
        }
        DN404Storage storage $ = _getDN404Storage();
        uint256 allowed = $.allowance[from][msg.sender];

        if (allowed != type(uint256).max) {
            if (amount > allowed) revert InsufficientAllowance();
            unchecked {
                $.allowance[from][msg.sender] = allowed - amount;
            }
        }

        _transfer(from, to, amount);

        return true;
    }

    function _transferFromNFT(
        address from,
        address to,
        uint256 id,
        address msgSender
    ) internal override {
        if (!tradingEnabled) {
            require(msg.sender == owner(), "Trading is not enabled");
        }
        DN404Reflect._transferFromNFT(from, to, id, msgSender);
    }

    /*&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-*/
    /*                      ADMIN FUNCTIONS                       */
    /*-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;*/

    function initialize(
        uint96 totalSupply_,
        address owner_,
        uint256 wad,
        address mirror
    ) public onlyOwner() {
        _initializeDN404Reflect(
            totalSupply_,
            owner_,
            mirror,
            wad
        );
    }

    function reveal(string memory uri) public onlyOwner {
        baseTokenURI = uri;
        isHidden = false;
    }

    ///@dev exclude account from earning reflections
    function excludeAccount(address account) external onlyOwner {
        DN404Storage storage $ = _getDN404Storage();
        require(!$.functionsRenounced, "Function is renounced");
        AddressData storage accountAddressData = _addressData(account);

        require(!accountAddressData.isExcluded, "Account is already excluded");
        if (accountAddressData.rOwned > 0) {
            accountAddressData.tOwned = tokenFromReflection(
                accountAddressData.rOwned
            );
        }
        accountAddressData.isExcluded = true;
        $.excluded.push(account);
    }

    ///@dev include account to earn reflections
    function includeAccount(address account) external onlyOwner {
        DN404Storage storage $ = _getDN404Storage();
        AddressData storage accountAddressData = _addressData(account);

        require(!accountAddressData.isExcluded, "Account is already excluded");
        for (uint256 i = 0; i < $.excluded.length; i++) {
            if ($.excluded[i] == account) {
                $.excluded[i] = $.excluded[$.excluded.length - 1];
                accountAddressData.tOwned = 0;
                accountAddressData.isExcluded = false;
                $.excluded.pop();
                break;
            }
        }
    }

    /// @dev function to set reflections fee, cannot be invoked once ownership is renounced, 1-1000 for 1 decimal of precision
    // i.e. 50 = 5%, 25 = 2.5%, 1 = 0.1%
    function setTaxFee(uint256 fee) external onlyOwner {
        DN404Storage storage $ = _getDN404Storage();
        require(!$.functionsRenounced, "Function is renounced");
        require(fee <= 50, "Reflections fee must be 5% or less");
        $.taxFee = fee;
    }

    function getTaxFee() external returns (uint256) {
        return _getDN404Storage().taxFee;
    }

    /// @dev renounce setTaxFee and excludeAccount WARNING: CANNOT BE UNDONE
    function renounceFunctions() external onlyOwner {
        _getDN404Storage().functionsRenounced = true;
    }

    function enableTrading() external onlyOwner {
        tradingEnabled = true;
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
}
pragma solidity ^0.8.20;

/**
 * @dev Standard math utilities missing in the Solidity language.
 */
library Math {
    /**
     * @dev Muldiv operation overflow.
     */
    error MathOverflowedMulDiv();

    enum Rounding {
        Floor, // Toward negative infinity
        Ceil, // Toward positive infinity
        Trunc, // Toward zero
        Expand // Away from zero
    }

    /**
     * @dev Returns the addition of two unsigned integers, with an overflow flag.
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
     */
    function trySub(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b > a) return (false, 0);
            return (true, a - b);
        }
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, with an overflow flag.
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
     */
    function tryDiv(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b == 0) return (false, 0);
            return (true, a / b);
        }
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers, with a division by zero flag.
     */
    function tryMod(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b == 0) return (false, 0);
            return (true, a % b);
        }
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
     * This differs from standard division with `/` in that it rounds towards infinity instead
     * of rounding towards zero.
     */
    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) {
            // Guarantee the same behavior as in a regular Solidity division.
            return a / b;
        }

        // (a + b - 1) / b can overflow on addition, so we distribute.
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /**
     * @notice Calculates floor(x * y / denominator) with full precision. Throws if result overflows a uint256 or
     * denominator == 0.
     * @dev Original credit to Remco Bloemen under MIT license (https://xn--2-umb.com/21/muldiv) with further edits by
     * Uniswap Labs also under MIT license.
     */
    function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = x * y. Compute the product mod 2^256 and mod 2^256 - 1, then use
            // use the Chinese Remainder Theorem to reconstruct the 512 bit result. The result is stored in two 256
            // variables such that product = prod1 * 2^256 + prod0.
            uint256 prod0 = x * y; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly {
                let mm := mulmod(x, y, not(0))
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
            if (denominator <= prod1) {
                revert MathOverflowedMulDiv();
            }

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

            // Factor powers of two out of denominator and compute largest power of two divisor of denominator.
            // Always >= 1. See https://cs.stackexchange.com/q/138556/92363.

            uint256 twos = denominator & (0 - denominator);
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

            // Use the Newton-Raphson iteration to improve the precision. Thanks to Hensel's lifting lemma, this also
            // works in modular arithmetic, doubling the correct bits in each step.
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
        if (unsignedRoundsUp(rounding) && mulmod(x, y, denominator) > 0) {
            result += 1;
        }
        return result;
    }

    /**
     * @dev Returns the square root of a number. If the number is not a perfect square, the value is rounded
     * towards zero.
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
            return result + (unsignedRoundsUp(rounding) && result * result < a ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 2 of a positive value rounded towards zero.
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
            return result + (unsignedRoundsUp(rounding) && 1 << result < value ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 10 of a positive value rounded towards zero.
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
            return result + (unsignedRoundsUp(rounding) && 10 ** result < value ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 256 of a positive value rounded towards zero.
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
            return result + (unsignedRoundsUp(rounding) && 1 << (result << 3) < value ? 1 : 0);
        }
    }

    /**
     * @dev Returns whether a provided rounding mode is considered rounding up for unsigned integers.
     */
    function unsignedRoundsUp(Rounding rounding) internal pure returns (bool) {
        return uint8(rounding) % 2 == 1;
    }
}
pragma solidity ^0.8.20;

/**
 * @dev Standard signed math utilities missing in the Solidity language.
 */
library SignedMath {
    /**
     * @dev Returns the largest of two signed numbers.
     */
    function max(int256 a, int256 b) internal pure returns (int256) {
        return a > b ? a : b;
    }

    /**
     * @dev Returns the smallest of two signed numbers.
     */
    function min(int256 a, int256 b) internal pure returns (int256) {
        return a < b ? a : b;
    }

    /**
     * @dev Returns the average of two signed numbers without overflow.
     * The result is rounded towards zero.
     */
    function average(int256 a, int256 b) internal pure returns (int256) {
        // Formula from the book "Hacker's Delight"
        int256 x = (a & b) + ((a ^ b) >> 1);
        return x + (int256(uint256(x) >> 255) & (a ^ b));
    }

    /**
     * @dev Returns the absolute unsigned value of a signed value.
     */
    function abs(int256 n) internal pure returns (uint256) {
        unchecked {
            // must be unchecked in order to support `n = type(int256).min`
            return uint256(n >= 0 ? n : -n);
        }
    }
}
pragma solidity ^0.8.20;

import {Math} from "./math/Math.sol";
import {SignedMath} from "./math/SignedMath.sol";

/**
 * @dev String operations.
 */
library Strings {
    bytes16 private constant HEX_DIGITS = "0123456789abcdef";
    uint8 private constant ADDRESS_LENGTH = 20;

    /**
     * @dev The `value` string doesn't fit in the specified `length`.
     */
    error StringsInsufficientHexLength(uint256 value, uint256 length);

    /**
     * @dev Converts a `uint256` to its ASCII `string` decimal representation.
     */
    function toString(uint256 value) internal pure returns (string memory) {
        unchecked {
            uint256 length = Math.log10(value) + 1;
            string memory buffer = new string(length);
            uint256 ptr;
            /// @solidity memory-safe-assembly
            assembly {
                ptr := add(buffer, add(32, length))
            }
            while (true) {
                ptr--;
                /// @solidity memory-safe-assembly
                assembly {
                    mstore8(ptr, byte(mod(value, 10), HEX_DIGITS))
                }
                value /= 10;
                if (value == 0) break;
            }
            return buffer;
        }
    }

    /**
     * @dev Converts a `int256` to its ASCII `string` decimal representation.
     */
    function toStringSigned(int256 value) internal pure returns (string memory) {
        return string.concat(value < 0 ? "-" : "", toString(SignedMath.abs(value)));
    }

    /**
     * @dev Converts a `uint256` to its ASCII `string` hexadecimal representation.
     */
    function toHexString(uint256 value) internal pure returns (string memory) {
        unchecked {
            return toHexString(value, Math.log256(value) + 1);
        }
    }

    /**
     * @dev Converts a `uint256` to its ASCII `string` hexadecimal representation with fixed length.
     */
    function toHexString(uint256 value, uint256 length) internal pure returns (string memory) {
        uint256 localValue = value;
        bytes memory buffer = new bytes(2 * length + 2);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 2 * length + 1; i > 1; --i) {
            buffer[i] = HEX_DIGITS[localValue & 0xf];
            localValue >>= 4;
        }
        if (localValue != 0) {
            revert StringsInsufficientHexLength(value, length);
        }
        return string(buffer);
    }

    /**
     * @dev Converts an `address` with fixed length of 20 bytes to its not checksummed ASCII `string` hexadecimal
     * representation.
     */
    function toHexString(address addr) internal pure returns (string memory) {
        return toHexString(uint256(uint160(addr)), ADDRESS_LENGTH);
    }

    /**
     * @dev Returns true if the two strings are equal.
     */
    function equal(string memory a, string memory b) internal pure returns (bool) {
        return bytes(a).length == bytes(b).length && keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
pragma solidity ^0.8.4;

/// @title DN404Mirror
/// @notice DN404Mirror provides an interface for interacting with the
/// NFT tokens in a DN404 implementation.
///
/// @author vectorized.eth (@optimizoor)
/// @author Quit (@0xQuit)
/// @author Michael Amadi (@AmadiMichaels)
/// @author cygaar (@0xCygaar)
/// @author Thomas (@0xjustadev)
/// @author Harrison (@PopPunkOnChain)
///
/// @dev Note:
/// - The ERC721 data is stored in the base DN404 contract.
contract DN404Mirror {
    /*&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-*/
    /*                           EVENTS                           */
    /*-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;*/

    /// @dev Emitted when token `id` is transferred from `from` to `to`.
    event Transfer(address indexed from, address indexed to, uint256 indexed id);

    /// @dev Emitted when `owner` enables `account` to manage the `id` token.
    event Approval(address indexed owner, address indexed account, uint256 indexed id);

    /// @dev Emitted when `owner` enables or disables `operator` to manage all of their tokens.
    event ApprovalForAll(address indexed owner, address indexed operator, bool isApproved);

    /// @dev `keccak256(bytes("Transfer(address,address,uint256)"))`.
    uint256 private constant _TRANSFER_EVENT_SIGNATURE =
        0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    /// @dev `keccak256(bytes("Approval(address,address,uint256)"))`.
    uint256 private constant _APPROVAL_EVENT_SIGNATURE =
        0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925;

    /// @dev `keccak256(bytes("ApprovalForAll(address,address,bool)"))`.
    uint256 private constant _APPROVAL_FOR_ALL_EVENT_SIGNATURE =
        0x17307eab39ab6107e8899845ad3d59bd9653f200f220920489ca2b5937696c31;

    /*&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-*/
    /*                        CUSTOM ERRORS                       */
    /*-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;*/

    /// @dev Thrown when a call for an NFT function did not originate
    /// from the base DN404 contract.
    error SenderNotBase();

    /// @dev Thrown when a call for an NFT function did not originate from the deployer.
    error SenderNotDeployer();

    /// @dev Thrown when transferring an NFT to a contract address that
    /// does not implement ERC721Receiver.
    error TransferToNonERC721ReceiverImplementer();

    /// @dev Thrown when linking to the DN404 base contract and the
    /// DN404 supportsInterface check fails or the call reverts.
    error CannotLink();

    /// @dev Thrown when a linkMirrorContract call is received and the
    /// NFT mirror contract has already been linked to a DN404 base contract.
    error AlreadyLinked();

    /// @dev Thrown when retrieving the base DN404 address when a link has not
    /// been established.
    error NotLinked();

    /*&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-*/
    /*                          STORAGE                           */
    /*-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;*/

    /// @dev Struct contain the NFT mirror contract storage.
    struct DN404NFTStorage {
        address baseERC20;
        address deployer;
    }

    /// @dev Returns a storage pointer for DN404NFTStorage.
    function _getDN404NFTStorage() internal pure virtual returns (DN404NFTStorage storage $) {
        /// @solidity memory-safe-assembly
        assembly {
            // `uint72(bytes9(keccak256("DN404_MIRROR_STORAGE")))`.
            $.slot := 0x3602298b8c10b01230 // Truncate to 9 bytes to reduce bytecode size.
        }
    }

    /*&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-*/
    /*                        CONSTRUCTOR                         */
    /*-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;*/

    constructor(address deployer) {
        // For non-proxies, we will store the deployer so that only the deployer can
        // link the base contract.
        _getDN404NFTStorage().deployer = deployer;
    }

    /*&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-*/
    /*                     ERC721 OPERATIONS                      */
    /*-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;*/

    /// @dev Returns the token collection name from the base DN404 contract.
    function name() public view virtual returns (string memory result) {
        address base = baseERC20();
        /// @solidity memory-safe-assembly
        assembly {
            result := mload(0x40)
            mstore(0x00, 0x06fdde03) // `name()`.
            if iszero(staticcall(gas(), base, 0x1c, 0x04, 0x00, 0x00)) {
                returndatacopy(result, 0x00, returndatasize())
                revert(result, returndatasize())
            }
            returndatacopy(0x00, 0x00, 0x20)
            returndatacopy(result, mload(0x00), 0x20)
            returndatacopy(add(result, 0x20), add(mload(0x00), 0x20), mload(result))
            mstore(0x40, add(add(result, 0x20), mload(result)))
        }
    }

    /// @dev Returns the token collection symbol from the base DN404 contract.
    function symbol() public view virtual returns (string memory result) {
        address base = baseERC20();
        /// @solidity memory-safe-assembly
        assembly {
            result := mload(0x40)
            mstore(0x00, 0x95d89b41) // `symbol()`.
            if iszero(staticcall(gas(), base, 0x1c, 0x04, 0x00, 0x00)) {
                returndatacopy(result, 0x00, returndatasize())
                revert(result, returndatasize())
            }
            returndatacopy(0x00, 0x00, 0x20)
            returndatacopy(result, mload(0x00), 0x20)
            returndatacopy(add(result, 0x20), add(mload(0x00), 0x20), mload(result))
            mstore(0x40, add(add(result, 0x20), mload(result)))
        }
    }

    /// @dev Returns the Uniform Resource Identifier (URI) for token `id` from
    /// the base DN404 contract.
    function tokenURI(uint256 id) public view virtual returns (string memory result) {
        address base = baseERC20();
        /// @solidity memory-safe-assembly
        assembly {
            result := mload(0x40)
            mstore(0x20, id)
            mstore(0x00, 0xc87b56dd) // `tokenURI()`.
            if iszero(staticcall(gas(), base, 0x1c, 0x24, 0x00, 0x00)) {
                returndatacopy(result, 0x00, returndatasize())
                revert(result, returndatasize())
            }
            returndatacopy(0x00, 0x00, 0x20)
            returndatacopy(result, mload(0x00), 0x20)
            returndatacopy(add(result, 0x20), add(mload(0x00), 0x20), mload(result))
            mstore(0x40, add(add(result, 0x20), mload(result)))
        }
    }

    /// @dev Returns the total NFT supply from the base DN404 contract.
    function totalSupply() public view virtual returns (uint256 result) {
        address base = baseERC20();
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, 0xe2c79281) // `totalNFTSupply()`.
            if iszero(
                and(gt(returndatasize(), 0x1f), staticcall(gas(), base, 0x1c, 0x04, 0x00, 0x20))
            ) {
                returndatacopy(mload(0x40), 0x00, returndatasize())
                revert(mload(0x40), returndatasize())
            }
            result := mload(0x00)
        }
    }

    /// @dev Returns the number of NFT tokens owned by `owner` from the base DN404 contract.
    ///
    /// Requirements:
    /// - `owner` must not be the zero address.
    function balanceOf(address owner) public view virtual returns (uint256 result) {
        address base = baseERC20();
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x20, shr(96, shl(96, owner)))
            mstore(0x00, 0xf5b100ea) // `balanceOfNFT(address)`.
            if iszero(
                and(gt(returndatasize(), 0x1f), staticcall(gas(), base, 0x1c, 0x24, 0x00, 0x20))
            ) {
                returndatacopy(mload(0x40), 0x00, returndatasize())
                revert(mload(0x40), returndatasize())
            }
            result := mload(0x00)
        }
    }

    /// @dev Returns the owner of token `id` from the base DN404 contract.
    ///
    /// Requirements:
    /// - Token `id` must exist.
    function ownerOf(uint256 id) public view virtual returns (address result) {
        address base = baseERC20();
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, 0x6352211e) // `ownerOf(uint256)`.
            mstore(0x20, id)
            if iszero(
                and(gt(returndatasize(), 0x1f), staticcall(gas(), base, 0x1c, 0x24, 0x00, 0x20))
            ) {
                returndatacopy(mload(0x40), 0x00, returndatasize())
                revert(mload(0x40), returndatasize())
            }
            result := shr(96, mload(0x0c))
        }
    }

    /// @dev Sets `spender` as the approved account to manage token `id` in
    /// the base DN404 contract.
    ///
    /// Requirements:
    /// - Token `id` must exist.
    /// - The caller must be the owner of the token,
    ///   or an approved operator for the token owner.
    ///
    /// Emits an {Approval} event.
    function approve(address spender, uint256 id) public virtual {
        address base = baseERC20();
        /// @solidity memory-safe-assembly
        assembly {
            spender := shr(96, shl(96, spender))
            let m := mload(0x40)
            mstore(0x00, 0xd10b6e0c) // `approveNFT(address,uint256,address)`.
            mstore(0x20, spender)
            mstore(0x40, id)
            mstore(0x60, caller())
            if iszero(
                and(
                    gt(returndatasize(), 0x1f),
                    call(gas(), base, callvalue(), 0x1c, 0x64, 0x00, 0x20)
                )
            ) {
                returndatacopy(m, 0x00, returndatasize())
                revert(m, returndatasize())
            }
            mstore(0x40, m) // Restore the free memory pointer.
            mstore(0x60, 0) // Restore the zero pointer.
            // Emit the {Approval} event.
            log4(codesize(), 0x00, _APPROVAL_EVENT_SIGNATURE, shr(96, mload(0x0c)), spender, id)
        }
    }

    /// @dev Returns the account approved to manage token `id` from
    /// the base DN404 contract.
    ///
    /// Requirements:
    /// - Token `id` must exist.
    function getApproved(uint256 id) public view virtual returns (address result) {
        address base = baseERC20();
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, 0x081812fc) // `getApproved(uint256)`.
            mstore(0x20, id)
            if iszero(
                and(gt(returndatasize(), 0x1f), staticcall(gas(), base, 0x1c, 0x24, 0x00, 0x20))
            ) {
                returndatacopy(mload(0x40), 0x00, returndatasize())
                revert(mload(0x40), returndatasize())
            }
            result := shr(96, mload(0x0c))
        }
    }

    /// @dev Sets whether `operator` is approved to manage the tokens of the caller in
    /// the base DN404 contract.
    ///
    /// Emits an {ApprovalForAll} event.
    function setApprovalForAll(address operator, bool approved) public virtual {
        address base = baseERC20();
        /// @solidity memory-safe-assembly
        assembly {
            operator := shr(96, shl(96, operator))
            let m := mload(0x40)
            mstore(0x00, 0x813500fc) // `setApprovalForAll(address,bool,address)`.
            mstore(0x20, operator)
            mstore(0x40, iszero(iszero(approved)))
            mstore(0x60, caller())
            if iszero(
                and(eq(mload(0x00), 1), call(gas(), base, callvalue(), 0x1c, 0x64, 0x00, 0x20))
            ) {
                returndatacopy(m, 0x00, returndatasize())
                revert(m, returndatasize())
            }
            // Emit the {ApprovalForAll} event.
            log3(0x40, 0x20, _APPROVAL_FOR_ALL_EVENT_SIGNATURE, caller(), operator)
            mstore(0x40, m) // Restore the free memory pointer.
            mstore(0x60, 0) // Restore the zero pointer.
        }
    }

    /// @dev Returns whether `operator` is approved to manage the tokens of `owner` from
    /// the base DN404 contract.
    function isApprovedForAll(address owner, address operator)
        public
        view
        virtual
        returns (bool result)
    {
        address base = baseERC20();
        /// @solidity memory-safe-assembly
        assembly {
            let m := mload(0x40)
            mstore(0x40, operator)
            mstore(0x2c, shl(96, owner))
            mstore(0x0c, 0xe985e9c5000000000000000000000000) // `isApprovedForAll(address,address)`.
            if iszero(
                and(gt(returndatasize(), 0x1f), staticcall(gas(), base, 0x1c, 0x44, 0x00, 0x20))
            ) {
                returndatacopy(m, 0x00, returndatasize())
                revert(m, returndatasize())
            }
            mstore(0x40, m) // Restore the free memory pointer.
            result := iszero(iszero(mload(0x00)))
        }
    }

    /// @dev Transfers token `id` from `from` to `to`.
    ///
    /// Requirements:
    ///
    /// - Token `id` must exist.
    /// - `from` must be the owner of the token.
    /// - `to` cannot be the zero address.
    /// - The caller must be the owner of the token, or be approved to manage the token.
    ///
    /// Emits a {Transfer} event.
    function transferFrom(address from, address to, uint256 id) public virtual {
        address base = baseERC20();
        /// @solidity memory-safe-assembly
        assembly {
            from := shr(96, shl(96, from))
            to := shr(96, shl(96, to))
            let m := mload(0x40)
            mstore(m, 0xe5eb36c8) // `transferFromNFT(address,address,uint256,address)`.
            mstore(add(m, 0x20), from)
            mstore(add(m, 0x40), to)
            mstore(add(m, 0x60), id)
            mstore(add(m, 0x80), caller())
            if iszero(
                and(eq(mload(m), 1), call(gas(), base, callvalue(), add(m, 0x1c), 0x84, m, 0x20))
            ) {
                returndatacopy(m, 0x00, returndatasize())
                revert(m, returndatasize())
            }
            // Emit the {Transfer} event.
            log4(codesize(), 0x00, _TRANSFER_EVENT_SIGNATURE, from, to, id)
        }
    }

    /// @dev Equivalent to `safeTransferFrom(from, to, id, "")`.
    function safeTransferFrom(address from, address to, uint256 id) public payable virtual {
        transferFrom(from, to, id);

        if (_hasCode(to)) _checkOnERC721Received(from, to, id, "");
    }

    /// @dev Transfers token `id` from `from` to `to`.
    ///
    /// Requirements:
    ///
    /// - Token `id` must exist.
    /// - `from` must be the owner of the token.
    /// - `to` cannot be the zero address.
    /// - The caller must be the owner of the token, or be approved to manage the token.
    /// - If `to` refers to a smart contract, it must implement
    ///   {IERC721Receiver-onERC721Received}, which is called upon a safe transfer.
    ///
    /// Emits a {Transfer} event.
    function safeTransferFrom(address from, address to, uint256 id, bytes calldata data)
        public
        virtual
    {
        transferFrom(from, to, id);

        if (_hasCode(to)) _checkOnERC721Received(from, to, id, data);
    }

    /// @dev Returns true if this contract implements the interface defined by `interfaceId`.
    /// See: https://eips.ethereum.org/EIPS/eip-165
    /// This function call must use less than 30000 gas.
    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool result) {
        /// @solidity memory-safe-assembly
        assembly {
            let s := shr(224, interfaceId)
            // ERC165: 0x01ffc9a7, ERC721: 0x80ac58cd, ERC721Metadata: 0x5b5e139f.
            result := or(or(eq(s, 0x01ffc9a7), eq(s, 0x80ac58cd)), eq(s, 0x5b5e139f))
        }
    }

    /*&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-*/
    /*                     MIRROR OPERATIONS                      */
    /*-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;*/

    /// @dev Returns the address of the base DN404 contract.
    function baseERC20() public view virtual returns (address base) {
        base = _getDN404NFTStorage().baseERC20;
        if (base == address(0)) revert NotLinked();
    }

    /// @dev Fallback modifier to execute calls from the base DN404 contract.
    modifier dn404NFTFallback() virtual {
        DN404NFTStorage storage $ = _getDN404NFTStorage();

        uint256 fnSelector = _calldataload(0x00) >> 224;

        // `logTransfer(uint256[])`.
        if (fnSelector == 0x263c69d6) {
            if (msg.sender != $.baseERC20) revert SenderNotBase();
            /// @solidity memory-safe-assembly
            assembly {
                // When returndatacopy copies 1 or more out-of-bounds bytes, it reverts.
                returndatacopy(0x00, returndatasize(), lt(calldatasize(), 0x20))
                let o := add(0x24, calldataload(0x04)) // Packed logs offset.
                returndatacopy(0x00, returndatasize(), lt(calldatasize(), o))
                let end := add(o, shl(5, calldataload(sub(o, 0x20))))
                returndatacopy(0x00, returndatasize(), lt(calldatasize(), end))

                for {} iszero(eq(o, end)) { o := add(0x20, o) } {
                    let d := calldataload(o) // Entry in the packed logs.
                    let a := shr(96, d) // The address.
                    let b := and(1, d) // Whether it is a burn.
                    log4(
                        codesize(),
                        0x00,
                        _TRANSFER_EVENT_SIGNATURE,
                        mul(a, b),
                        mul(a, iszero(b)),
                        shr(168, shl(160, d))
                    )
                }
                mstore(0x00, 0x01)
                return(0x00, 0x20)
            }
        }
        // `linkMirrorContract(address)`.
        if (fnSelector == 0x0f4599e5) {
            if ($.deployer != address(0)) {
                if (address(uint160(_calldataload(0x04))) != $.deployer) {
                    revert SenderNotDeployer();
                }
            }
            if ($.baseERC20 != address(0)) revert AlreadyLinked();
            $.baseERC20 = msg.sender;
            /// @solidity memory-safe-assembly
            assembly {
                mstore(0x00, 0x01)
                return(0x00, 0x20)
            }
        }
        _;
    }

    /// @dev Fallback function for calls from base DN404 contract.
    fallback() external payable virtual dn404NFTFallback {}

    receive() external payable virtual {}

    /*&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-*/
    /*                      PRIVATE HELPERS                       */
    /*-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;*/

    /// @dev Returns the calldata value at `offset`.
    function _calldataload(uint256 offset) private pure returns (uint256 value) {
        /// @solidity memory-safe-assembly
        assembly {
            value := calldataload(offset)
        }
    }

    /// @dev Returns if `a` has bytecode of non-zero length.
    function _hasCode(address a) private view returns (bool result) {
        /// @solidity memory-safe-assembly
        assembly {
            result := extcodesize(a) // Can handle dirty upper bits.
        }
    }

    /// @dev Perform a call to invoke {IERC721Receiver-onERC721Received} on `to`.
    /// Reverts if the target does not support the function correctly.
    function _checkOnERC721Received(address from, address to, uint256 id, bytes memory data)
        private
    {
        /// @solidity memory-safe-assembly
        assembly {
            // Prepare the calldata.
            let m := mload(0x40)
            let onERC721ReceivedSelector := 0x150b7a02
            mstore(m, onERC721ReceivedSelector)
            mstore(add(m, 0x20), caller()) // The `operator`, which is always `msg.sender`.
            mstore(add(m, 0x40), shr(96, shl(96, from)))
            mstore(add(m, 0x60), id)
            mstore(add(m, 0x80), 0x80)
            let n := mload(data)
            mstore(add(m, 0xa0), n)
            if n { pop(staticcall(gas(), 4, add(data, 0x20), n, add(m, 0xc0), n)) }
            // Revert if the call reverts.
            if iszero(call(gas(), to, 0, add(m, 0x1c), add(n, 0xa4), m, 0x20)) {
                if returndatasize() {
                    // Bubble up the revert if the call reverts.
                    returndatacopy(m, 0x00, returndatasize())
                    revert(m, returndatasize())
                }
            }
            // Load the returndata and compare it.
            if iszero(eq(mload(m), shl(224, onERC721ReceivedSelector))) {
                mstore(0x00, 0xd1a57ed6) // `TransferToNonERC721ReceiverImplementer()`.
                revert(0x1c, 0x04)
            }
        }
    }
}
pragma solidity ^0.8.4;
import "./DN404Mirror.sol";

/// @title DN404
/// @notice DN404 is a hybrid ERC20 and ERC721 implementation that mints
/// and burns NFTs based on an account's ERC20 token balance.
///
/// @author vectorized.eth (@optimizoor)
/// @author Quit (@0xQuit)
/// @author Michael Amadi (@AmadiMichaels)
/// @author cygaar (@0xCygaar)
/// @author Thomas (@0xjustadev)
/// @author Harrison (@PopPunkOnChain)
///
/// @dev Note:
/// - The ERC721 data is stored in this base DN404 contract, however a
///   DN404Mirror contract ***MUST*** be deployed and linked during
///   initialization.
abstract contract DN404Reflect {
    /*&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-*/
    /*                           EVENTS                           */
    /*-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;*/

    /// @dev Emitted when `amount` tokens is transferred from `from` to `to`.
    event Transfer(address indexed from, address indexed to, uint256 amount);

    /// @dev Emitted when `amount` tokens is approved by `owner` to be used by `spender`.
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 amount
    );

    /// @dev Emitted when `target` sets their skipNFT flag to `status`.
    event SkipNFTSet(address indexed target, bool status);

    /*&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-*/
    /*                        CUSTOM ERRORS                       */
    /*-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;*/

    /// @dev Thrown when attempting to double-initialize the contract.
    error DNAlreadyInitialized();

    /// @dev Thrown when attempting to transfer or burn more tokens than sender's balance.
    error InsufficientBalance();

    /// @dev Thrown when a spender attempts to transfer tokens with an insufficient allowance.
    error InsufficientAllowance();

    /// @dev Thrown when minting an amount of tokens that would overflow the max tokens.
    error TotalSupplyOverflow();

    /// @dev Thrown when the caller for a fallback NFT function is not the mirror contract.
    error SenderNotMirror();

    /// @dev Thrown when attempting to transfer tokens to the zero address.
    error TransferToZeroAddress();

    /// @dev Thrown when the mirror address provided for initialization is the zero address.
    error MirrorAddressIsZero();

    /// @dev Thrown when the link call to the mirror contract reverts.
    error LinkMirrorContractFailed();

    /// @dev Thrown when setting an NFT token approval
    /// and the caller is not the owner or an approved operator.
    error ApprovalCallerNotOwnerNorApproved();

    /// @dev Thrown when transferring an NFT
    /// and the caller is not the owner or an approved operator.
    error TransferCallerNotOwnerNorApproved();

    /// @dev Thrown when transferring an NFT and the from address is not the current owner.
    error TransferFromIncorrectOwner();

    /// @dev Thrown when checking the owner or approved address for an non-existent NFT.
    error TokenDoesNotExist();

    /// @dev Amount of token balance that is equal to one NFT.
    uint256 internal _WAD;

    /*&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-*/
    /*                         CONSTANTS                          */
    /*-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;*/

    /// @dev The maximum token ID allowed for an NFT.
    uint256 internal constant _MAX_TOKEN_ID = 0xffffffff;

    /// @dev The maximum possible token supply.
    uint256 internal constant _MAX_SUPPLY = 10 ** 18 * 0xffffffff - 1;

    /// @dev The flag to denote that the address data is initialized.
    uint8 internal constant _ADDRESS_DATA_INITIALIZED_FLAG = 1 << 0;

    /// @dev The flag to denote that the address should skip NFTs.
    uint8 internal constant _ADDRESS_DATA_SKIP_NFT_FLAG = 1 << 1;

    /*&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-*/
    /*                          STORAGE                           */
    /*-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;*/

    /// @dev Struct containing an address's token data and settings.
    struct AddressData {
        // Auxiliary data.
        uint88 aux;
        // Flags for `initialized` and `skipNFT`.
        uint8 flags;
        // The alias for the address. Zero means absence of an alias.
        uint32 addressAlias;
        // The number of NFT tokens.
        uint32 ownedLength;
        // The token balance in wei.
        uint96 balance;
        // tTotal for reflections
        uint256 tOwned;
        // rTotal for reflections
        uint256 rOwned;
        // Excluded from reflections
        bool isExcluded;
    }

    /// @dev A uint32 map in storage.
    struct Uint32Map {
        mapping(uint256 => uint256) map;
    }

    /// @dev Struct containing the base token contract storage.
    struct DN404Storage {
        // Current number of address aliases assigned.
        uint32 numAliases;
        // Next token ID to assign for an NFT mint.
        uint32 nextTokenId;
        // Total supply of minted NFTs.
        uint32 totalNFTSupply;
        // Total supply of tokens.
        uint96 totalSupply;
        // Total supply of tokens
        uint256 tTotal;
        // Reflections remaining
        uint256 rTotal;
        // Total transaction fees
        uint256 tFeeTotal;
        // Tax Fee (as percentage)
        uint256 taxFee;
        // Address of the NFT mirror contract.
        address mirrorERC721;
        // Mapping of a user alias number to their address.
        mapping(uint32 => address) aliasToAddress;
        // Mapping of user operator approvals for NFTs.
        mapping(address => mapping(address => bool)) operatorApprovals;
        // Mapping of NFT token approvals to approved operators.
        mapping(uint256 => address) tokenApprovals;
        // Mapping of user allowances for token spenders.
        mapping(address => mapping(address => uint256)) allowance;
        // Mapping of NFT token IDs owned by an address.
        mapping(address => Uint32Map) owned;
        // Even indices: owner aliases. Odd indices: owned indices.
        Uint32Map oo;
        // Mapping of user account AddressData
        mapping(address => AddressData) addressData;
        // array of excluded addresses
        address[] excluded;
        // Determines whether setTaxFee and ExcludeAccount can be called
        bool functionsRenounced;
        // Opens transfers for everyone
        bool tradingEnabled;
    }

    /// @dev Returns a storage pointer for DN404Storage.
    function _getDN404Storage()
        internal
        pure
        virtual
        returns (DN404Storage storage $)
    {
        /// @solidity memory-safe-assembly
        assembly {
            // `uint72(bytes9(keccak256("DN404_STORAGE")))`.
            $.slot := 0xa20d6e21d0e5255308 // Truncate to 9 bytes to reduce bytecode size.
        }
    }

    /*&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-*/
    /*                         INITIALIZER                        */
    /*-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;*/

    /// @dev Initializes the DN404 contract with an
    /// `initialTokenSupply`, `initialTokenOwner` and `mirror` NFT contract address.
    function _initializeDN404Reflect(
        uint256 initialTokenSupply,
        address initialSupplyOwner,
        address mirror,
        uint256 wad
    ) internal virtual {
        DN404Storage storage $ = _getDN404Storage();

        if ($.nextTokenId != 0) revert DNAlreadyInitialized();

        if (mirror == address(0)) revert MirrorAddressIsZero();
        _linkMirrorContract(mirror);

        $.nextTokenId = 1;
        $.mirrorERC721 = mirror;
        _WAD = wad;
        if (initialTokenSupply > 0) {
            if (initialSupplyOwner == address(0))
                revert TransferToZeroAddress();
            if (initialTokenSupply > _MAX_SUPPLY) revert TotalSupplyOverflow();

            $.totalSupply = uint96(initialTokenSupply);
            $.tTotal = uint256(initialTokenSupply);
            uint256 MAX = ~uint256(0);
            $.rTotal = (MAX - (MAX % $.tTotal));
            AddressData storage initialOwnerAddressData = _addressData(
                initialSupplyOwner
            );
            initialOwnerAddressData.balance = uint96(initialTokenSupply);
            initialOwnerAddressData.rOwned = $.rTotal;

            emit Transfer(address(0), initialSupplyOwner, initialTokenSupply);

            _setSkipNFT(initialSupplyOwner, true);
        }
    }

    /*&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-*/
    /*               METADATA FUNCTIONS TO OVERRIDE               */
    /*-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;*/

    /// @dev Returns the name of the token.
    function name() public view virtual returns (string memory);

    /// @dev Returns the symbol of the token.
    function symbol() public view virtual returns (string memory);

    /// @dev Returns the Uniform Resource Identifier (URI) for token `id`.
    function tokenURI(
        uint256 id
    ) public view virtual returns (string memory result);

    /*&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-*/
    /*                      ERC20 OPERATIONS                      */
    /*-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;*/

    /// @dev Returns the decimals places of the token. Always 18.
    function decimals() public pure returns (uint8) {
        return 18;
    }

    /// @dev Returns the amount of tokens in existence.
    function totalSupply() public view virtual returns (uint256) {
        return uint256(_getDN404Storage().totalSupply);
    }

    /// @dev Returns the amount of tokens owned by `owner`
    ///      Updated for reflections logic
    function balanceOf(address owner) public view virtual returns (uint256) {
        AddressData storage ownerAddressData = _getDN404Storage().addressData[
            owner
        ];
        if (ownerAddressData.isExcluded) return ownerAddressData.tOwned;
        return tokenFromReflection(ownerAddressData.rOwned);
    }

    /// @dev Returns the amount of tokens that `spender` can spend on behalf of `owner`.
    function allowance(
        address owner,
        address spender
    ) public view returns (uint256) {
        return _getDN404Storage().allowance[owner][spender];
    }

    /// @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
    ///
    /// Emits a {Approval} event.
    function approve(
        address spender,
        uint256 amount
    ) public virtual returns (bool) {
        DN404Storage storage $ = _getDN404Storage();

        $.allowance[msg.sender][spender] = amount;

        emit Approval(msg.sender, spender, amount);

        return true;
    }

    /// @dev Transfer `amount` tokens from the caller to `to`.
    ///
    /// Will burn sender NFTs if balance after transfer is less than
    /// the amount required to support the current NFT balance.
    ///
    /// Will mint NFTs to `to` if the recipient's new balance supports
    /// additional NFTs ***AND*** the `to` address's skipNFT flag is
    /// set to false.
    ///
    /// Requirements:
    /// - `from` must at least have `amount`.
    ///
    /// Emits a {Transfer} event.
    function transfer(
        address to,
        uint256 amount
    ) public virtual returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @dev Transfers `amount` tokens from `from` to `to`.
    ///
    /// Note: Does not update the allowance if it is the maximum uint256 value.
    ///
    /// Will burn sender NFTs if balance after transfer is less than
    /// the amount required to support the current NFT balance.
    ///
    /// Will mint NFTs to `to` if the recipient's new balance supports
    /// additional NFTs ***AND*** the `to` address's skipNFT flag is
    /// set to false.
    ///
    /// Requirements:
    /// - `from` must at least have `amount`.
    /// - The caller must have at least `amount` of allowance to transfer the tokens of `from`.
    ///
    /// Emits a {Transfer} event.
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual returns (bool) {
        DN404Storage storage $ = _getDN404Storage();
        uint256 allowed = $.allowance[from][msg.sender];

        if (allowed != type(uint256).max) {
            if (amount > allowed) revert InsufficientAllowance();
            unchecked {
                $.allowance[from][msg.sender] = allowed - amount;
            }
        }

        _transfer(from, to, amount);

        return true;
    }

    /*&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-*/
    /*                   REFLECTION OPERATIONS                    */
    /*-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;*/

    /// @dev reflects sender's wallet
    function reflect(uint256 tAmount) public {
        DN404Storage storage $ = _getDN404Storage();
        address sender = msg.sender;
        AddressData storage senderAddressData = _addressData(sender);
        require(
            !senderAddressData.isExcluded,
            "Excluded addresses cannot call this function"
        );
        (uint256 rAmount, , , , ) = _getValues(tAmount);
        senderAddressData.rOwned = senderAddressData.rOwned - rAmount;
        $.rTotal = $.rTotal - rAmount;
        $.tFeeTotal = $.tFeeTotal + tAmount;
    }
    /// @dev returns rAmount from amount of tokens
    function reflectionFromToken(
        uint256 tAmount,
        bool deductTransferFee
    ) public view returns (uint256) {
        require(
            tAmount <= _getDN404Storage().tTotal,
            "Amount must be less than supply"
        );
        if (!deductTransferFee) {
            (uint256 rAmount, , , , ) = _getValues(tAmount);
            return rAmount;
        } else {
            (, uint256 rTransferAmount, , , ) = _getValues(tAmount);
            return rTransferAmount;
        }
    }

    ///@dev returns token amount from rTotal (used for balanceOf)
    function tokenFromReflection(
        uint256 rAmount
    ) public view returns (uint256) {
        require(
            rAmount <= _getDN404Storage().rTotal,
            "Amount must be less than total reflections"
        );
        uint256 currentRate = _getRate();
        return rAmount / currentRate;
    }

    /*&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-*/
    /*                  INTERNAL MINT FUNCTIONS                   */
    /*-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;*/

    /// @dev Mints `amount` tokens to `to`, increasing the total supply.
    ///
    /// Will mint NFTs to `to` if the recipient's new balance supports
    /// additional NFTs ***AND*** the `to` address's skipNFT flag is
    /// set to false.
    ///
    /// Emits a {Transfer} event.
    function _mint(address to, uint256 amount) internal virtual {
        if (to == address(0)) revert TransferToZeroAddress();

        DN404Storage storage $ = _getDN404Storage();

        AddressData storage toAddressData = _addressData(to);

        unchecked {
            uint256 currentTokenSupply = uint256($.totalSupply) + amount;
            if (amount > _MAX_SUPPLY || currentTokenSupply > _MAX_SUPPLY) {
                revert TotalSupplyOverflow();
            }
            $.totalSupply = uint96(currentTokenSupply);

            uint256 toBalance = toAddressData.balance + amount;
            toAddressData.balance = uint96(toBalance);

            if (toAddressData.flags & _ADDRESS_DATA_SKIP_NFT_FLAG == 0) {
                Uint32Map storage toOwned = $.owned[to];
                uint256 toIndex = toAddressData.ownedLength;
                uint256 toEnd = toBalance / _WAD;
                _PackedLogs memory packedLogs = _packedLogsMalloc(
                    _zeroFloorSub(toEnd, toIndex)
                );

                if (packedLogs.logs.length != 0) {
                    uint256 maxNFTId = $.totalSupply / _WAD;
                    uint32 toAlias = _registerAndResolveAlias(
                        toAddressData,
                        to
                    );
                    uint256 id = $.nextTokenId;
                    $.totalNFTSupply += uint32(packedLogs.logs.length);
                    toAddressData.ownedLength = uint32(toEnd);
                    // Mint loop.
                    do {
                        while (_get($.oo, _ownershipIndex(id)) != 0) {
                            if (++id > maxNFTId) id = 1;
                        }
                        _set(toOwned, toIndex, uint32(id));
                        _setOwnerAliasAndOwnedIndex(
                            $.oo,
                            id,
                            toAlias,
                            uint32(toIndex++)
                        );
                        _packedLogsAppend(packedLogs, to, id, 0);
                        if (++id > maxNFTId) id = 1;
                    } while (toIndex != toEnd);
                    $.nextTokenId = uint32(id);
                    _packedLogsSend(packedLogs, $.mirrorERC721);
                }
            }
        }
        emit Transfer(address(0), to, amount);
    }

    /*&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-*/
    /*                  INTERNAL BURN FUNCTIONS                   */
    /*-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;*/

    /// @dev Burns `amount` tokens from `from`, reducing the total supply.
    ///
    /// Will burn sender NFTs if balance after transfer is less than
    /// the amount required to support the current NFT balance.
    ///
    /// Emits a {Transfer} event.
    function _burn(address from, uint256 amount) internal virtual {
        DN404Storage storage $ = _getDN404Storage();

        AddressData storage fromAddressData = _addressData(from);

        uint256 fromBalance = fromAddressData.balance;
        if (amount > fromBalance) revert InsufficientBalance();

        uint256 currentTokenSupply = $.totalSupply;

        unchecked {
            fromBalance -= amount;
            fromAddressData.balance = uint96(fromBalance);
            currentTokenSupply -= amount;
            $.totalSupply = uint96(currentTokenSupply);

            Uint32Map storage fromOwned = $.owned[from];
            uint256 fromIndex = fromAddressData.ownedLength;
            uint256 nftAmountToBurn = _zeroFloorSub(
                fromIndex,
                fromBalance / _WAD
            );

            if (nftAmountToBurn != 0) {
                $.totalNFTSupply -= uint32(nftAmountToBurn);

                _PackedLogs memory packedLogs = _packedLogsMalloc(
                    nftAmountToBurn
                );

                uint256 fromEnd = fromIndex - nftAmountToBurn;
                // Burn loop.
                do {
                    uint256 id = _get(fromOwned, --fromIndex);
                    _setOwnerAliasAndOwnedIndex($.oo, id, 0, 0);
                    delete $.tokenApprovals[id];
                    _packedLogsAppend(packedLogs, from, id, 1);
                } while (fromIndex != fromEnd);

                fromAddressData.ownedLength = uint32(fromIndex);
                _packedLogsSend(packedLogs, $.mirrorERC721);
            }
        }
        emit Transfer(from, address(0), amount);
    }

    /*&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-*/
    /*                INTERNAL TRANSFER FUNCTIONS                 */
    /*-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;*/

    /// @dev Moves `amount` of tokens from `from` to `to`.
    ///
    /// Will burn sender NFTs if balance after transfer is less than
    /// the amount required to support the current NFT balance.
    ///
    /// Will mint NFTs to `to` if the recipient's new balance supports
    /// additional NFTs ***AND*** the `to` address's skipNFT flag is
    /// set to false.
    ///
    /// Emits a {Transfer} event.
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {
        if (to == address(0)) revert TransferToZeroAddress();

        DN404Storage storage $ = _getDN404Storage();

        AddressData storage fromAddressData = _addressData(from);
        AddressData storage toAddressData = _addressData(to);

        _TransferTemps memory t;
        t.fromOwnedLength = fromAddressData.ownedLength;
        t.toOwnedLength = toAddressData.ownedLength;
        t.rOwnedFrom = fromAddressData.rOwned;
        t.rOwnedTo = toAddressData.rOwned;
        t.fromBalance = this.balanceOf(from);
        t.toBalance = this.balanceOf(to);
        if (amount > t.fromBalance) revert InsufficientBalance();

        unchecked {
            // Reflections transfer logic
            (
                uint256 rAmount,
                uint256 rTransferAmount,
                uint256 rFee,
                uint256 tTransferAmount,
                uint256 tFee
            ) = _getValues(amount);
  
            // Transfer from excluded address
            if (fromAddressData.isExcluded && !toAddressData.isExcluded) {
                t.tOwnedFrom = fromAddressData.tOwned - amount;
                t.rOwnedFrom = t.rOwnedFrom - rAmount;
                t.rOwnedTo = t.rOwnedTo + rTransferAmount;
                // Update temporary from and to balance
                t.fromBalance = t.tOwnedFrom;
                t.toBalance = tokenFromReflection(t.rOwnedTo);
            }
            // Transfer to excluded address
            else if (!fromAddressData.isExcluded && toAddressData.isExcluded) {
                t.rOwnedFrom = t.rOwnedFrom - rAmount;
                t.rOwnedTo = t.rOwnedTo + rTransferAmount;
                t.tOwnedTo = toAddressData.tOwned + tTransferAmount;
                // Update temporary from and to balance
                t.fromBalance = tokenFromReflection(t.rOwnedFrom);
                t.toBalance = t.tOwnedTo;
            }
            // Transfer between non-excluded addresses
            else if (!fromAddressData.isExcluded && !toAddressData.isExcluded) {
                t.rOwnedFrom = t.rOwnedFrom - rAmount;
                t.rOwnedTo = t.rOwnedTo + rTransferAmount;
                // Update temporary from and to balance
                t.fromBalance = tokenFromReflection(t.rOwnedFrom);
                t.toBalance = tokenFromReflection(t.rOwnedTo);
            }
            // Transfer between both excluded addresses
            else if (fromAddressData.isExcluded && toAddressData.isExcluded) {
                t.tOwnedFrom = fromAddressData.tOwned - amount;
                t.rOwnedFrom = t.rOwnedFrom - rAmount;
                t.rOwnedTo = t.rOwnedTo + rTransferAmount;
                t.tOwnedTo = toAddressData.tOwned + tTransferAmount;
                // Update temporary from and to balance
                t.fromBalance = t.tOwnedFrom;
                t.toBalance = t.tOwnedTo;
            } else {
                t.rOwnedFrom = t.rOwnedFrom - rAmount;
                t.rOwnedTo = t.rOwnedTo + rTransferAmount;
                // Update temporary from and to balance
                t.fromBalance = tokenFromReflection(t.rOwnedFrom);
                t.toBalance = tokenFromReflection(t.rOwnedTo);
            }
            // Reflect fees to all token holders
            _reflectFee(rFee, tFee);
            // Update address data rOwned and tOwned
            fromAddressData.rOwned = t.rOwnedFrom;
            toAddressData.rOwned = t.rOwnedTo;
            fromAddressData.tOwned = t.tOwnedFrom;
            toAddressData.tOwned = t.tOwnedTo;

            // Update address balances for nft transfer logic
            fromAddressData.balance = uint96(t.fromBalance);
            toAddressData.balance = uint96(t.toBalance);

            t.nftAmountToBurn = _zeroFloorSub(
                t.fromOwnedLength,
                t.fromBalance / _WAD
            );

            if (toAddressData.flags & _ADDRESS_DATA_SKIP_NFT_FLAG == 0) {
                if (from == to)
                    t.toOwnedLength = t.fromOwnedLength - t.nftAmountToBurn;
                t.nftAmountToMint = _zeroFloorSub(
                    t.toBalance / _WAD,
                    t.toOwnedLength
                );
            }

            _PackedLogs memory packedLogs = _packedLogsMalloc(
                t.nftAmountToBurn + t.nftAmountToMint
            );

            if (t.nftAmountToBurn != 0) {
                Uint32Map storage fromOwned = $.owned[from];
                uint256 fromIndex = t.fromOwnedLength;
                uint256 fromEnd = fromIndex - t.nftAmountToBurn;
                $.totalNFTSupply -= uint32(t.nftAmountToBurn);
                fromAddressData.ownedLength = uint32(fromEnd);
                // Burn loop.
                do {
                    uint256 id = _get(fromOwned, --fromIndex);
                    _setOwnerAliasAndOwnedIndex($.oo, id, 0, 0);
                    delete $.tokenApprovals[id];
                    _packedLogsAppend(packedLogs, from, id, 1);
                } while (fromIndex != fromEnd);
            }

            if (t.nftAmountToMint != 0) {
                Uint32Map storage toOwned = $.owned[to];
                uint256 toIndex = t.toOwnedLength;
                uint256 toEnd = toIndex + t.nftAmountToMint;
                uint32 toAlias = _registerAndResolveAlias(toAddressData, to);
                uint256 maxNFTId = $.totalSupply / _WAD;
                uint256 id = $.nextTokenId;
                $.totalNFTSupply += uint32(t.nftAmountToMint);
                toAddressData.ownedLength = uint32(toEnd);
                // Mint loop.
                do {
                    while (_get($.oo, _ownershipIndex(id)) != 0) {
                        if (++id > maxNFTId) id = 1;
                    }
                    _set(toOwned, toIndex, uint32(id));
                    _setOwnerAliasAndOwnedIndex(
                        $.oo,
                        id,
                        toAlias,
                        uint32(toIndex++)
                    );
                    _packedLogsAppend(packedLogs, to, id, 0);
                    if (++id > maxNFTId) id = 1;
                } while (toIndex != toEnd);
                $.nextTokenId = uint32(id);
            }

            if (packedLogs.logs.length != 0) {
                _packedLogsSend(packedLogs, $.mirrorERC721);
            }
        }
        // Should be taken care of by internal reflections transfer functions
        emit Transfer(from, to, amount);
    }

    /// @dev Transfers token `id` from `from` to `to`.
    ///
    /// Requirements:
    ///
    /// - Call must originate from the mirror contract.
    /// - Token `id` must exist.
    /// - `from` must be the owner of the token.
    /// - `to` cannot be the zero address.
    ///   `msgSender` must be the owner of the token, or be approved to manage the token.
    ///
    /// Emits a {Transfer} event.
    function _transferFromNFT(
        address from,
        address to,
        uint256 id,
        address msgSender
    ) internal virtual {
        DN404Storage storage $ = _getDN404Storage();
        if (to == address(0)) revert TransferToZeroAddress();

        address owner = $.aliasToAddress[_get($.oo, _ownershipIndex(id))];

        if (from != owner) revert TransferFromIncorrectOwner();

        if (msgSender != from) {
            if (!$.operatorApprovals[from][msgSender]) {
                if (msgSender != $.tokenApprovals[id]) {
                    revert TransferCallerNotOwnerNorApproved();
                }
            }
        }

        AddressData storage fromAddressData = _addressData(from);
        AddressData storage toAddressData = _addressData(to);

        // Transfer without taking reflection fee
        (uint256 rAmount, , , , ) = _getValues(_WAD);
        if (fromAddressData.isExcluded) {
            fromAddressData.tOwned -= _WAD;
        }
        if (toAddressData.isExcluded) {
            toAddressData.tOwned += _WAD;
        }
        fromAddressData.rOwned -= rAmount;
        fromAddressData.balance -= uint96(_WAD);

        unchecked {
            toAddressData.balance += uint96(_WAD);
            toAddressData.rOwned += rAmount;

            _set(
                $.oo,
                _ownershipIndex(id),
                _registerAndResolveAlias(toAddressData, to)
            );
            delete $.tokenApprovals[id];

            uint256 updatedId = _get(
                $.owned[from],
                --fromAddressData.ownedLength
            );
            _set($.owned[from], _get($.oo, _ownedIndex(id)), uint32(updatedId));

            uint256 n = toAddressData.ownedLength++;
            _set($.oo, _ownedIndex(updatedId), _get($.oo, _ownedIndex(id)));
            _set($.owned[to], n, uint32(id));
            _set($.oo, _ownedIndex(id), uint32(n));
        }
    
        emit Transfer(from, to, _WAD);
    }

    /*&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-*/
    /*                 DATA HITCHHIKING FUNCTIONS                 */
    /*-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;*/

    /// @dev Returns the auxiliary data for `owner`.
    /// Minting, transferring, burning the tokens of `owner` will not change the auxiliary data.
    /// Auxiliary data can be set for any address, even if it does not have any tokens.
    function _getAux(address owner) internal view virtual returns (uint88) {
        return _getDN404Storage().addressData[owner].aux;
    }

    /// @dev Set the auxiliary data for `owner` to `value`.
    /// Minting, transferring, burning the tokens of `owner` will not change the auxiliary data.
    /// Auxiliary data can be set for any address, even if it does not have any tokens.
    function _setAux(address owner, uint88 value) internal virtual {
        _getDN404Storage().addressData[owner].aux = value;
    }

    /*&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-*/
    /*                     SKIP NFT FUNCTIONS                     */
    /*-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;*/

    /// @dev Returns true if account `a` will skip NFT minting on token mints and transfers.
    /// Returns false if account `a` will mint NFTs on token mints and transfers.
    function getSkipNFT(address a) public view virtual returns (bool) {
        AddressData storage d = _getDN404Storage().addressData[a];
        if (d.flags & _ADDRESS_DATA_INITIALIZED_FLAG == 0) return _hasCode(a);
        return d.flags & _ADDRESS_DATA_SKIP_NFT_FLAG != 0;
    }

    /// @dev Sets the caller's skipNFT flag to `skipNFT`
    ///
    /// Emits a {SkipNFTSet} event.
    function setSkipNFT(bool skipNFT) public virtual {
        _setSkipNFT(msg.sender, skipNFT);
    }

    /// @dev Internal function to set account `a` skipNFT flag to `state`
    ///
    /// Initializes account `a` AddressData if it is not currently initialized.
    ///
    /// Emits a {SkipNFTSet} event.
    function _setSkipNFT(address a, bool state) internal virtual {
        AddressData storage d = _addressData(a);
        if ((d.flags & _ADDRESS_DATA_SKIP_NFT_FLAG != 0) != state) {
            d.flags ^= _ADDRESS_DATA_SKIP_NFT_FLAG;
        }
        emit SkipNFTSet(a, state);
    }

    /// @dev Returns a storage data pointer for account `a` AddressData
    ///
    /// Initializes account `a` AddressData if it is not currently initialized.
    function _addressData(
        address a
    ) internal virtual returns (AddressData storage d) {
        DN404Storage storage $ = _getDN404Storage();
        d = $.addressData[a];

        if (d.flags & _ADDRESS_DATA_INITIALIZED_FLAG == 0) {
            uint8 flags = _ADDRESS_DATA_INITIALIZED_FLAG;
            if (_hasCode(a)) flags |= _ADDRESS_DATA_SKIP_NFT_FLAG;
            d.flags = flags;
        }
    }

    /// @dev Returns the `addressAlias` of account `to`.
    ///
    /// Assigns and registers the next alias if `to` alias was not previously registered.
    function _registerAndResolveAlias(
        AddressData storage toAddressData,
        address to
    ) internal virtual returns (uint32 addressAlias) {
        DN404Storage storage $ = _getDN404Storage();
        addressAlias = toAddressData.addressAlias;
        if (addressAlias == 0) {
            addressAlias = ++$.numAliases;
            toAddressData.addressAlias = addressAlias;
            $.aliasToAddress[addressAlias] = to;
        }
    }

    /*&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-*/
    /*                     MIRROR OPERATIONS                      */
    /*-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;*/

    /// @dev Returns the address of the mirror NFT contract.
    function mirrorERC721() public view virtual returns (address) {
        return _getDN404Storage().mirrorERC721;
    }

    /// @dev Returns the total NFT supply.
    function _totalNFTSupply() internal view virtual returns (uint256) {
        return _getDN404Storage().totalNFTSupply;
    }

    /// @dev Returns `owner` NFT balance.
    function _balanceOfNFT(
        address owner
    ) internal view virtual returns (uint256) {
        return _getDN404Storage().addressData[owner].ownedLength;
    }

    /// @dev Returns the owner of token `id`.
    /// Returns the zero address instead of reverting if the token does not exist.
    function _ownerAt(uint256 id) internal view virtual returns (address) {
        DN404Storage storage $ = _getDN404Storage();
        return $.aliasToAddress[_get($.oo, _ownershipIndex(id))];
    }

    /// @dev Returns the owner of token `id`.
    ///
    /// Requirements:
    /// - Token `id` must exist.
    function _ownerOf(uint256 id) internal view virtual returns (address) {
        if (!_exists(id)) revert TokenDoesNotExist();
        return _ownerAt(id);
    }

    /// @dev Returns if token `id` exists.
    function _exists(uint256 id) internal view virtual returns (bool) {
        return _ownerAt(id) != address(0);
    }

    /// @dev Returns the account approved to manage token `id`.
    ///
    /// Requirements:
    /// - Token `id` must exist.
    function _getApproved(uint256 id) internal view virtual returns (address) {
        if (!_exists(id)) revert TokenDoesNotExist();
        return _getDN404Storage().tokenApprovals[id];
    }

    /// @dev Sets `spender` as the approved account to manage token `id`, using `msgSender`.
    ///
    /// Requirements:
    /// - `msgSender` must be the owner or an approved operator for the token owner.
    function _approveNFT(
        address spender,
        uint256 id,
        address msgSender
    ) internal virtual returns (address) {
        DN404Storage storage $ = _getDN404Storage();

        address owner = $.aliasToAddress[_get($.oo, _ownershipIndex(id))];

        if (msgSender != owner) {
            if (!$.operatorApprovals[owner][msgSender]) {
                revert ApprovalCallerNotOwnerNorApproved();
            }
        }

        $.tokenApprovals[id] = spender;

        return owner;
    }

    /// @dev Approve or remove the `operator` as an operator for `msgSender`,
    /// without authorization checks.
    function _setApprovalForAll(
        address operator,
        bool approved,
        address msgSender
    ) internal virtual {
        _getDN404Storage().operatorApprovals[msgSender][operator] = approved;
    }

    /// @dev Calls the mirror contract to link it to this contract.
    ///
    /// Reverts if the call to the mirror contract reverts.
    function _linkMirrorContract(address mirror) internal virtual {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, 0x0f4599e5) // `linkMirrorContract(address)`.
            mstore(0x20, caller())
            if iszero(
                and(
                    eq(mload(0x00), 1),
                    call(gas(), mirror, 0, 0x1c, 0x24, 0x00, 0x20)
                )
            ) {
                mstore(0x00, 0xd125259c) // `LinkMirrorContractFailed()`.
                revert(0x1c, 0x04)
            }
        }
    }

    /// @dev Fallback modifier to dispatch calls from the mirror NFT contract
    /// to internal functions in this contract.
    modifier dn404Fallback() virtual {
        DN404Storage storage $ = _getDN404Storage();

        uint256 fnSelector = _calldataload(0x00) >> 224;

        // `isApprovedForAll(address,address)`.
        if (fnSelector == 0xe985e9c5) {
            if (msg.sender != $.mirrorERC721) revert SenderNotMirror();
            if (msg.data.length < 0x44) revert();

            address owner = address(uint160(_calldataload(0x04)));
            address operator = address(uint160(_calldataload(0x24)));

            _return($.operatorApprovals[owner][operator] ? 1 : 0);
        }
        // `ownerOf(uint256)`.
        if (fnSelector == 0x6352211e) {
            if (msg.sender != $.mirrorERC721) revert SenderNotMirror();
            if (msg.data.length < 0x24) revert();

            uint256 id = _calldataload(0x04);

            _return(uint160(_ownerOf(id)));
        }
        // `transferFromNFT(address,address,uint256,address)`.
        if (fnSelector == 0xe5eb36c8) {
            if (msg.sender != $.mirrorERC721) revert SenderNotMirror();
            if (msg.data.length < 0x84) revert();

            address from = address(uint160(_calldataload(0x04)));
            address to = address(uint160(_calldataload(0x24)));
            uint256 id = _calldataload(0x44);
            address msgSender = address(uint160(_calldataload(0x64)));

            _transferFromNFT(from, to, id, msgSender);
            _return(1);
        }
        // `setApprovalForAll(address,bool,address)`.
        if (fnSelector == 0x813500fc) {
            if (msg.sender != $.mirrorERC721) revert SenderNotMirror();
            if (msg.data.length < 0x64) revert();

            address spender = address(uint160(_calldataload(0x04)));
            bool status = _calldataload(0x24) != 0;
            address msgSender = address(uint160(_calldataload(0x44)));

            _setApprovalForAll(spender, status, msgSender);
            _return(1);
        }
        // `approveNFT(address,uint256,address)`.
        if (fnSelector == 0xd10b6e0c) {
            if (msg.sender != $.mirrorERC721) revert SenderNotMirror();
            if (msg.data.length < 0x64) revert();

            address spender = address(uint160(_calldataload(0x04)));
            uint256 id = _calldataload(0x24);
            address msgSender = address(uint160(_calldataload(0x44)));

            _return(uint160(_approveNFT(spender, id, msgSender)));
        }
        // `getApproved(uint256)`.
        if (fnSelector == 0x081812fc) {
            if (msg.sender != $.mirrorERC721) revert SenderNotMirror();
            if (msg.data.length < 0x24) revert();

            uint256 id = _calldataload(0x04);

            _return(uint160(_getApproved(id)));
        }
        // `balanceOfNFT(address)`.
        if (fnSelector == 0xf5b100ea) {
            if (msg.sender != $.mirrorERC721) revert SenderNotMirror();
            if (msg.data.length < 0x24) revert();

            address owner = address(uint160(_calldataload(0x04)));

            _return(_balanceOfNFT(owner));
        }
        // `totalNFTSupply()`.
        if (fnSelector == 0xe2c79281) {
            if (msg.sender != $.mirrorERC721) revert SenderNotMirror();
            if (msg.data.length < 0x04) revert();

            _return(_totalNFTSupply());
        }
        // `implementsDN404()`.
        if (fnSelector == 0xb7a94eb8) {
            _return(1);
        }
        _;
    }

    /// @dev Fallback function for calls from mirror NFT contract.
    fallback() external payable virtual dn404Fallback {}

    receive() external payable virtual {}

    /*&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-*/
    /*                      PRIVATE HELPERS                       */
    /*-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;*/

    /// @dev Struct containing packed log data for `Transfer` events to be
    /// emitted by the mirror NFT contract.
    struct _PackedLogs {
        uint256[] logs;
        uint256 offset;
    }

    /// @dev Initiates memory allocation for packed logs with `n` log items.
    function _packedLogsMalloc(
        uint256 n
    ) private pure returns (_PackedLogs memory p) {
        /// @solidity memory-safe-assembly
        assembly {
            let logs := add(mload(0x40), 0x40) // Offset by 2 words for `_packedLogsSend`.
            mstore(logs, n)
            let offset := add(0x20, logs)
            mstore(0x40, add(offset, shl(5, n)))
            mstore(p, logs)
            mstore(add(0x20, p), offset)
        }
    }

    /// @dev Adds a packed log item to `p` with address `a`, token `id` and burn flag `burnBit`.
    function _packedLogsAppend(
        _PackedLogs memory p,
        address a,
        uint256 id,
        uint256 burnBit
    ) private pure {
        /// @solidity memory-safe-assembly
        assembly {
            let offset := mload(add(0x20, p))
            mstore(offset, or(or(shl(96, a), shl(8, id)), burnBit))
            mstore(add(0x20, p), add(offset, 0x20))
        }
    }

    /// @dev Calls the `mirror` NFT contract to emit Transfer events for packed logs `p`.
    function _packedLogsSend(_PackedLogs memory p, address mirror) private {
        /// @solidity memory-safe-assembly
        assembly {
            let logs := mload(p)
            let o := sub(logs, 0x40) // Start of calldata to send.
            mstore(o, 0x263c69d6) // `logTransfer(uint256[])`.
            mstore(add(o, 0x20), 0x20) // Offset of `logs` in the calldata to send.
            let n := add(0x44, shl(5, mload(logs))) // Length of calldata to send.
            if iszero(
                and(
                    eq(mload(o), 1),
                    call(gas(), mirror, 0, add(o, 0x1c), n, o, 0x20)
                )
            ) {
                revert(o, 0x00)
            }
        }
    }

    /// @dev Struct of temporary variables for transfers.
    struct _TransferTemps {
        uint256 nftAmountToBurn;
        uint256 nftAmountToMint;
        uint256 fromBalance;
        uint256 toBalance;
        uint256 fromOwnedLength;
        uint256 toOwnedLength;
        uint256 rOwnedFrom;
        uint256 rOwnedTo;
        uint256 tOwnedFrom;
        uint256 tOwnedTo;
    }

    /// @dev Returns if `a` has bytecode of non-zero length.
    function _hasCode(address a) private view returns (bool result) {
        /// @solidity memory-safe-assembly
        assembly {
            result := extcodesize(a) // Can handle dirty upper bits.
        }
    }

    /// @dev Returns the calldata value at `offset`.
    function _calldataload(
        uint256 offset
    ) private pure returns (uint256 value) {
        /// @solidity memory-safe-assembly
        assembly {
            value := calldataload(offset)
        }
    }

    /// @dev Executes a return opcode to return `x` and end the current call frame.
    function _return(uint256 x) private pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, x)
            return(0x00, 0x20)
        }
    }

    /// @dev Returns `max(0, x - y)`.
    function _zeroFloorSub(
        uint256 x,
        uint256 y
    ) private pure returns (uint256 z) {
        /// @solidity memory-safe-assembly
        assembly {
            z := mul(gt(x, y), sub(x, y))
        }
    }

    /// @dev Returns `i << 1`.
    function _ownershipIndex(uint256 i) private pure returns (uint256) {
        return i << 1;
    }

    /// @dev Returns `(i << 1) + 1`.
    function _ownedIndex(uint256 i) private pure returns (uint256) {
        unchecked {
            return (i << 1) + 1;
        }
    }

    /// @dev Returns the uint32 value at `index` in `map`.
    function _get(
        Uint32Map storage map,
        uint256 index
    ) private view returns (uint32 result) {
        result = uint32(map.map[index >> 3] >> ((index & 7) << 5));
    }

    /// @dev Updates the uint32 value at `index` in `map`.
    function _set(Uint32Map storage map, uint256 index, uint32 value) private {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x20, map.slot)
            mstore(0x00, shr(3, index))
            let s := keccak256(0x00, 0x40) // Storage slot.
            let o := shl(5, and(index, 7)) // Storage slot offset (bits).
            let v := sload(s) // Storage slot value.
            let m := 0xffffffff // Value mask.
            sstore(s, xor(v, shl(o, and(m, xor(shr(o, v), value)))))
        }
    }

    /// @dev Sets the owner alias and the owned index together.
    function _setOwnerAliasAndOwnedIndex(
        Uint32Map storage map,
        uint256 id,
        uint32 ownership,
        uint32 ownedIndex
    ) private {
        /// @solidity memory-safe-assembly
        assembly {
            let value := or(shl(32, ownedIndex), and(0xffffffff, ownership))
            mstore(0x20, map.slot)
            mstore(0x00, shr(2, id))
            let s := keccak256(0x00, 0x40) // Storage slot.
            let o := shl(6, and(id, 3)) // Storage slot offset (bits).
            let v := sload(s) // Storage slot value.
            let m := 0xffffffffffffffff // Value mask.
            sstore(s, xor(v, shl(o, and(m, xor(shr(o, v), value)))))
        }
    }

    /*&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-*/
    /*              PRIVATE FUNCTIONS FOR REFLECTIONS             */
    /*-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;*/

    /// @dev Reflects fee to all holders
    function _reflectFee(uint256 rFee, uint256 tFee) private {
        DN404Storage storage $ = _getDN404Storage();
        $.rTotal = $.rTotal - rFee;
        $.tFeeTotal = $.tFeeTotal + tFee;
    }

    function _getValues(
        uint256 tAmount
    ) private view returns (uint256, uint256, uint256, uint256, uint256) {
        (uint256 tTransferAmount, uint256 tFee) = _getTValues(tAmount);
        uint256 currentRate = _getRate();
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee) = _getRValues(
            tAmount,
            tFee,
            currentRate
        );
        return (rAmount, rTransferAmount, rFee, tTransferAmount, tFee);
    }

    function _getTValues(
        uint256 tAmount
    ) private view returns (uint256, uint256) {
        uint256 tFee = _calculateTaxFee(tAmount);
        uint256 tTransferAmount = tAmount - tFee;
        return (tTransferAmount, tFee);
    }

    function _getRValues(
        uint256 tAmount,
        uint256 tFee,
        uint256 currentRate
    ) private pure returns (uint256, uint256, uint256) {
        uint256 rAmount = tAmount * currentRate;
        uint256 rFee = tFee * currentRate;
        uint256 rTransferAmount = rAmount - rFee;
        return (rAmount, rTransferAmount, rFee);
    }

    function _getRate() private view returns (uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        return (rSupply / tSupply);
    }

    /// @dev returns current supply in terms of 'r' and 't'
    function _getCurrentSupply() private view returns (uint256, uint256) {
        DN404Storage storage $ = _getDN404Storage();
        uint256 rSupply = $.rTotal;
        uint256 tSupply = $.tTotal;
        for (uint256 i = 0; i < $.excluded.length; i++) {
            AddressData storage excludedAddressData = $.addressData[
                $.excluded[i]
            ];

            if (
                excludedAddressData.rOwned > rSupply ||
                excludedAddressData.tOwned > tSupply
            ) return ($.rTotal, $.tTotal);
            rSupply = rSupply - excludedAddressData.rOwned;
            tSupply = tSupply - excludedAddressData.tOwned;
        }
        if (rSupply < $.rTotal / $.tTotal) return ($.rTotal, $.tTotal);
        return (rSupply, tSupply);
    }

    /// @dev returns the total reflected tokens
    function getTotalReflections() public view returns (uint256) {
        return _getDN404Storage().tFeeTotal;
    }

    function _calculateTaxFee(uint256 amount) private view returns (uint256) {
        return (amount * _getDN404Storage().taxFee) / (10 ** 3);
    }

    /*&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-&#171;-*/
    /*                     ACCESS FUNCTIONS                       */
    /*-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;-&#187;*/
}
