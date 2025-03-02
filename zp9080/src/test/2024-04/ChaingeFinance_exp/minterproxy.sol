pragma solidity ^0.8.9;
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
}

abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    constructor() {
        _transferOwnership(_msgSender());
    }

    function owner() public view virtual returns (address) {
        return _owner;
    }

    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(
            newOwner != address(0),
            "Ownable: new owner is the zero address"
        );
        _transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

abstract contract Controller is Ownable {
    event ControllerAdded(address controller);
    event ControllerRemoved(address controller);
    mapping(address => bool) public controllers;
    uint8 public controllerCnt = 0;

    modifier onlyController() {
        require(isController(_msgSender()), "no controller rights");
        _;
    }

    function isController(address _controller) public view returns (bool) {
        return _controller == owner() || controllers[_controller];
    }

    function addController(address _controller) public onlyOwner {
        if (controllers[_controller] == false) {
            controllers[_controller] = true;
            controllerCnt++;
        }
        emit ControllerAdded(_controller);
    }

    function removeController(address _controller) public onlyOwner {
        if (controllers[_controller] == true) {
            controllers[_controller] = false;
            controllerCnt--;
        }
        emit ControllerRemoved(_controller);
    }
}
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
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );

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
    function allowance(
        address owner,
        address spender
    ) external view returns (uint256);

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
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
}
interface IWETH is IERC20 {
    /**
     * @notice Emitted when Ether is deposited to get wrapper tokens.
     */
    event Deposit(address indexed dst, uint256 wad);

    /**
     * @notice Emitted when wrapper tokens is withdrawn as Ether.
     */
    event Withdrawal(address indexed src, uint256 wad);

    /**
     * @notice Deposit Ether to get wrapper tokens.
     */
    function deposit() external payable;

    /**
     * @notice Withdraw wrapped tokens as Ether.
     * @param amount Amount of wrapped tokens to withdraw.
     */
    function withdraw(uint256 amount) external;
}

library OpAddress {
    function isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }

    function sendValue(address payable recipient, uint256 amount) internal {
        require(
            address(this).balance >= amount,
            "Address: insufficient balance"
        );

        (bool success, ) = recipient.call{value: amount}("");
        require(
            success,
            "Address: unable to send value, recipient may have reverted"
        );
    }

    function functionCall(
        address target,
        bytes memory data
    ) internal returns (bytes memory) {
        return
            functionCallWithValue(
                target,
                data,
                0,
                "Address: low-level call failed"
            );
    }

    function functionCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0, errorMessage);
    }

    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value
    ) internal returns (bytes memory) {
        return
            functionCallWithValue(
                target,
                data,
                value,
                "Address: low-level call with value failed"
            );
    }

    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value,
        string memory errorMessage
    ) internal returns (bytes memory) {
        require(
            address(this).balance >= value,
            "Address: insufficient balance for call"
        );
        (bool success, bytes memory returndata) = target.call{value: value}(
            data
        );
        return
            verifyCallResultFromTarget(
                target,
                success,
                returndata,
                errorMessage
            );
    }

    function functionStaticCall(
        address target,
        bytes memory data
    ) internal view returns (bytes memory) {
        return
            functionStaticCall(
                target,
                data,
                "Address: low-level static call failed"
            );
    }

    function functionStaticCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal view returns (bytes memory) {
        (bool success, bytes memory returndata) = target.staticcall(data);
        return
            verifyCallResultFromTarget(
                target,
                success,
                returndata,
                errorMessage
            );
    }

    function functionDelegateCall(
        address target,
        bytes memory data
    ) internal returns (bytes memory) {
        return
            functionDelegateCall(
                target,
                data,
                "Address: low-level delegate call failed"
            );
    }

    function functionDelegateCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal returns (bytes memory) {
        (bool success, bytes memory returndata) = target.delegatecall(data);
        return
            verifyCallResultFromTarget(
                target,
                success,
                returndata,
                errorMessage
            );
    }

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

    function _revert(
        bytes memory returndata,
        string memory errorMessage
    ) private pure {
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
library SafeERC20 {
    using OpAddress for address;

    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(
            token,
            abi.encodeWithSelector(token.transfer.selector, to, value)
        );
    }

    function safeTransferFrom(
        IERC20 token,
        address from,
        address to,
        uint256 value
    ) internal {
        _callOptionalReturn(
            token,
            abi.encodeWithSelector(token.transferFrom.selector, from, to, value)
        );
    }

    function safeApprove(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        require(
            (value == 0) || (token.allowance(address(this), spender) == 0),
            "SafeERC20: approve from non-zero to non-zero allowance"
        );
        _callOptionalReturn(
            token,
            abi.encodeWithSelector(token.approve.selector, spender, value)
        );
    }

    function safeIncreaseAllowance(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        uint256 oldAllowance = token.allowance(address(this), spender);
        _callOptionalReturn(
            token,
            abi.encodeWithSelector(
                token.approve.selector,
                spender,
                oldAllowance + value
            )
        );
    }

    function safeDecreaseAllowance(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        unchecked {
            uint256 oldAllowance = token.allowance(address(this), spender);
            require(
                oldAllowance >= value,
                "SafeERC20: decreased allowance below zero"
            );
            _callOptionalReturn(
                token,
                abi.encodeWithSelector(
                    token.approve.selector,
                    spender,
                    oldAllowance - value
                )
            );
        }
    }

    function forceApprove(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        bytes memory approvalCall = abi.encodeWithSelector(
            token.approve.selector,
            spender,
            value
        );

        if (!_callOptionalReturnBool(token, approvalCall)) {
            _callOptionalReturn(
                token,
                abi.encodeWithSelector(token.approve.selector, spender, 0)
            );
            _callOptionalReturn(token, approvalCall);
        }
    }

    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        bytes memory returndata = address(token).functionCall(
            data,
            "SafeERC20: low-level call failed"
        );
        require(
            returndata.length == 0 || abi.decode(returndata, (bool)),
            "SafeERC20: ERC20 operation did not succeed"
        );
    }

    function _callOptionalReturnBool(
        IERC20 token,
        bytes memory data
    ) private returns (bool) {
        (bool success, bytes memory returndata) = address(token).call(data);
        return
            success &&
            (returndata.length == 0 || abi.decode(returndata, (bool))) &&
            OpAddress.isContract(address(token));
    }

    /**
     * @notice Safely deposits a specified amount of Ether into the IWETH contract. Consumes less gas then regular `IWETH.deposit`.
     * @param weth The IWETH token contract.
     * @param amount The amount of Ether to deposit into the IWETH contract.
     */
    function safeDeposit(IWETH weth, uint256 amount) internal {
        if (amount > 0) {
            bytes4 selector = IWETH.deposit.selector;
            assembly ("memory-safe") {
                // solhint-disable-line no-inline-assembly
                mstore(0, selector)
                if iszero(call(gas(), weth, amount, 0, 4, 0, 0)) {
                    let ptr := mload(0x40)
                    returndatacopy(ptr, 0, returndatasize())
                    revert(ptr, returndatasize())
                }
            }
        }
    }

    /**
     * @notice Safely withdraws a specified amount of wrapped Ether from the IWETH contract. Consumes less gas then regular `IWETH.withdraw`.
     * @dev Uses inline assembly to interact with the IWETH contract.
     * @param weth The IWETH token contract.
     * @param amount The amount of wrapped Ether to withdraw from the IWETH contract.
     */
    function safeWithdraw(IWETH weth, uint256 amount) internal {
        bytes4 selector = IWETH.withdraw.selector;
        assembly ("memory-safe") {
            // solhint-disable-line no-inline-assembly
            mstore(0, selector)
            mstore(4, amount)
            if iszero(call(gas(), weth, 0, 0, 0x24, 0, 0)) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
        }
    }
    uint256 private constant _RAW_CALL_GAS_LIMIT = 5000;
    /**
     * @notice Safely withdraws a specified amount of wrapped Ether from the IWETH contract to a specified recipient.
     * Consumes less gas then regular `IWETH.withdraw`.
     * @param weth The IWETH token contract.
     * @param amount The amount of wrapped Ether to withdraw from the IWETH contract.
     * @param to The recipient of the withdrawn Ether.
     */
    function safeWithdrawTo(IWETH weth, uint256 amount, address to) internal {
        safeWithdraw(weth, amount);
        if (to != address(this)) {
            assembly ("memory-safe") {
                // solhint-disable-line no-inline-assembly
                if iszero(call(_RAW_CALL_GAS_LIMIT, to, amount, 0, 0, 0, 0)) {
                    let ptr := mload(0x40)
                    returndatacopy(ptr, 0, returndatasize())
                    revert(ptr, returndatasize())
                }
            }
        }
    }
}

type Address is uint256;
library AddressLib {
    uint256 private constant _LOW_160_BIT_MASK = (1 << 160) - 1;

    function get(Address a) internal pure returns (address) {
        return address(uint160(Address.unwrap(a) & _LOW_160_BIT_MASK));
    }

    function getFlag(Address a, uint256 flag) internal pure returns (bool) {
        return (Address.unwrap(a) & flag) != 0;
    }

    function getUint32(
        Address a,
        uint256 offset
    ) internal pure returns (uint32) {
        return uint32(Address.unwrap(a) >> offset);
    }

    function getUint64(
        Address a,
        uint256 offset
    ) internal pure returns (uint64) {
        return uint64(Address.unwrap(a) >> offset);
    }
}

type MakerTraits is uint256;

library MakerTraitsLib {
    // Low 200 bits are used for allowed sender, expiration, nonceOrEpoch, and series
    uint256 private constant _ALLOWED_SENDER_MASK = type(uint80).max;
    uint256 private constant _EXPIRATION_OFFSET = 80;
    uint256 private constant _EXPIRATION_MASK = type(uint40).max;
    uint256 private constant _NONCE_OR_EPOCH_OFFSET = 120;
    uint256 private constant _NONCE_OR_EPOCH_MASK = type(uint40).max;
    uint256 private constant _SERIES_OFFSET = 160;
    uint256 private constant _SERIES_MASK = type(uint40).max;

    uint256 private constant _NO_PARTIAL_FILLS_FLAG = 1 << 255;
    uint256 private constant _ALLOW_MULTIPLE_FILLS_FLAG = 1 << 254;
    uint256 private constant _PRE_INTERACTION_CALL_FLAG = 1 << 252;
    uint256 private constant _POST_INTERACTION_CALL_FLAG = 1 << 251;
    uint256 private constant _NEED_CHECK_EPOCH_MANAGER_FLAG = 1 << 250;
    uint256 private constant _HAS_EXTENSION_FLAG = 1 << 249;
    uint256 private constant _USE_PERMIT2_FLAG = 1 << 248;
    uint256 private constant _UNWRAP_WETH_FLAG = 1 << 247;

    /**
     * @notice Checks if the order has the extension flag set.
     * @dev If the `HAS_EXTENSION_FLAG` is set in the makerTraits, then the protocol expects that the order has extension(s).
     * @param makerTraits The traits of the maker.
     * @return result A boolean indicating whether the flag is set.
     */
    function hasExtension(
        MakerTraits makerTraits
    ) internal pure returns (bool) {
        return (MakerTraits.unwrap(makerTraits) & _HAS_EXTENSION_FLAG) != 0;
    }

    /**
     * @notice Checks if the maker allows a specific taker to fill the order.
     * @param makerTraits The traits of the maker.
     * @param sender The address of the taker to be checked.
     * @return result A boolean indicating whether the taker is allowed.
     */
    function isAllowedSender(
        MakerTraits makerTraits,
        address sender
    ) internal pure returns (bool) {
        uint160 allowedSender = uint160(
            MakerTraits.unwrap(makerTraits) & _ALLOWED_SENDER_MASK
        );
        return
            allowedSender == 0 ||
            allowedSender == uint160(sender) & _ALLOWED_SENDER_MASK;
    }

    /**
     * @notice Checks if the order has expired.
     * @param makerTraits The traits of the maker.
     * @return result A boolean indicating whether the order has expired.
     */
    function isExpired(MakerTraits makerTraits) internal view returns (bool) {
        uint256 expiration = (MakerTraits.unwrap(makerTraits) >>
            _EXPIRATION_OFFSET) & _EXPIRATION_MASK;
        return expiration != 0 && expiration < block.timestamp; // solhint-disable-line not-rely-on-time
    }

    /**
     * @notice Returns the nonce or epoch of the order.
     * @param makerTraits The traits of the maker.
     * @return result The nonce or epoch of the order.
     */
    function nonceOrEpoch(
        MakerTraits makerTraits
    ) internal pure returns (uint256) {
        return
            (MakerTraits.unwrap(makerTraits) >> _NONCE_OR_EPOCH_OFFSET) &
            _NONCE_OR_EPOCH_MASK;
    }

    /**
     * @notice Returns the series of the order.
     * @param makerTraits The traits of the maker.
     * @return result The series of the order.
     */
    function series(MakerTraits makerTraits) internal pure returns (uint256) {
        return
            (MakerTraits.unwrap(makerTraits) >> _SERIES_OFFSET) & _SERIES_MASK;
    }

    /**
     * @notice Determines if the order allows partial fills.
     * @dev If the _NO_PARTIAL_FILLS_FLAG is not set in the makerTraits, then the order allows partial fills.
     * @param makerTraits The traits of the maker, determining their preferences for the order.
     * @return result A boolean indicating whether the maker allows partial fills.
     */
    function allowPartialFills(
        MakerTraits makerTraits
    ) internal pure returns (bool) {
        return (MakerTraits.unwrap(makerTraits) & _NO_PARTIAL_FILLS_FLAG) == 0;
    }

    /**
     * @notice Checks if the maker needs pre-interaction call.
     * @param makerTraits The traits of the maker.
     * @return result A boolean indicating whether the maker needs a pre-interaction call.
     */
    function needPreInteractionCall(
        MakerTraits makerTraits
    ) internal pure returns (bool) {
        return
            (MakerTraits.unwrap(makerTraits) & _PRE_INTERACTION_CALL_FLAG) != 0;
    }

    /**
     * @notice Checks if the maker needs post-interaction call.
     * @param makerTraits The traits of the maker.
     * @return result A boolean indicating whether the maker needs a post-interaction call.
     */
    function needPostInteractionCall(
        MakerTraits makerTraits
    ) internal pure returns (bool) {
        return
            (MakerTraits.unwrap(makerTraits) & _POST_INTERACTION_CALL_FLAG) !=
            0;
    }

    /**
     * @notice Determines if the order allows multiple fills.
     * @dev If the _ALLOW_MULTIPLE_FILLS_FLAG is set in the makerTraits, then the maker allows multiple fills.
     * @param makerTraits The traits of the maker, determining their preferences for the order.
     * @return result A boolean indicating whether the maker allows multiple fills.
     */
    function allowMultipleFills(
        MakerTraits makerTraits
    ) internal pure returns (bool) {
        return
            (MakerTraits.unwrap(makerTraits) & _ALLOW_MULTIPLE_FILLS_FLAG) != 0;
    }

    /**
     * @notice Determines if an order should use the bit invalidator or remaining amount validator.
     * @dev The bit invalidator can be used if the order does not allow partial or multiple fills.
     * @param makerTraits The traits of the maker, determining their preferences for the order.
     * @return result A boolean indicating whether the bit invalidator should be used.
     * True if the order requires the use of the bit invalidator.
     */
    function useBitInvalidator(
        MakerTraits makerTraits
    ) internal pure returns (bool) {
        return
            !allowPartialFills(makerTraits) || !allowMultipleFills(makerTraits);
    }

    /**
     * @notice Checks if the maker needs to check the epoch.
     * @param makerTraits The traits of the maker.
     * @return result A boolean indicating whether the maker needs to check the epoch manager.
     */
    function needCheckEpochManager(
        MakerTraits makerTraits
    ) internal pure returns (bool) {
        return
            (MakerTraits.unwrap(makerTraits) &
                _NEED_CHECK_EPOCH_MANAGER_FLAG) != 0;
    }

    /**
     * @notice Checks if the maker uses permit2.
     * @param makerTraits The traits of the maker.
     * @return result A boolean indicating whether the maker uses permit2.
     */
    function usePermit2(MakerTraits makerTraits) internal pure returns (bool) {
        return MakerTraits.unwrap(makerTraits) & _USE_PERMIT2_FLAG != 0;
    }

    /**
     * @notice Checks if the maker needs to unwraps WETH.
     * @param makerTraits The traits of the maker.
     * @return result A boolean indicating whether the maker needs to unwrap WETH.
     */
    function unwrapWeth(MakerTraits makerTraits) internal pure returns (bool) {
        return MakerTraits.unwrap(makerTraits) & _UNWRAP_WETH_FLAG != 0;
    }
}

type TakerTraits is uint256;
library TakerTraitsLib {
    uint256 private constant _MAKER_AMOUNT_FLAG = 1 << 255;
    uint256 private constant _UNWRAP_WETH_FLAG = 1 << 254;
    uint256 private constant _SKIP_ORDER_PERMIT_FLAG = 1 << 253;
    uint256 private constant _USE_PERMIT2_FLAG = 1 << 252;
    uint256 private constant _ARGS_HAS_TARGET = 1 << 251;

    uint256 private constant _ARGS_EXTENSION_LENGTH_OFFSET = 224;
    uint256 private constant _ARGS_EXTENSION_LENGTH_MASK = 0xffffff;
    uint256 private constant _ARGS_INTERACTION_LENGTH_OFFSET = 200;
    uint256 private constant _ARGS_INTERACTION_LENGTH_MASK = 0xffffff;

    uint256 private constant _AMOUNT_MASK =
        0x000000000000000000ffffffffffffffffffffffffffffffffffffffffffffff;
    function argsHasTarget(
        TakerTraits takerTraits
    ) internal pure returns (bool) {
        return (TakerTraits.unwrap(takerTraits) & _ARGS_HAS_TARGET) != 0;
    }

    function argsExtensionLength(
        TakerTraits takerTraits
    ) internal pure returns (uint256) {
        return
            (TakerTraits.unwrap(takerTraits) >> _ARGS_EXTENSION_LENGTH_OFFSET) &
            _ARGS_EXTENSION_LENGTH_MASK;
    }

    function argsInteractionLength(
        TakerTraits takerTraits
    ) internal pure returns (uint256) {
        return
            (TakerTraits.unwrap(takerTraits) >>
                _ARGS_INTERACTION_LENGTH_OFFSET) &
            _ARGS_INTERACTION_LENGTH_MASK;
    }

    function isMakingAmount(
        TakerTraits takerTraits
    ) internal pure returns (bool) {
        return (TakerTraits.unwrap(takerTraits) & _MAKER_AMOUNT_FLAG) != 0;
    }

    function unwrapWeth(TakerTraits takerTraits) internal pure returns (bool) {
        return (TakerTraits.unwrap(takerTraits) & _UNWRAP_WETH_FLAG) != 0;
    }

    function skipMakerPermit(
        TakerTraits takerTraits
    ) internal pure returns (bool) {
        return (TakerTraits.unwrap(takerTraits) & _SKIP_ORDER_PERMIT_FLAG) != 0;
    }

    function usePermit2(TakerTraits takerTraits) internal pure returns (bool) {
        return (TakerTraits.unwrap(takerTraits) & _USE_PERMIT2_FLAG) != 0;
    }

    function threshold(
        TakerTraits takerTraits
    ) internal pure returns (uint256) {
        return TakerTraits.unwrap(takerTraits) & _AMOUNT_MASK;
    }
}

type Offsets is uint256;
library OffsetsLib {
    error OffsetOutOfBounds();
    function get(
        Offsets offsets,
        bytes calldata concat,
        uint256 index
    ) internal pure returns (bytes calldata result) {
        bytes4 exception = OffsetOutOfBounds.selector;
        assembly ("memory-safe") {
            // solhint-disable-line no-inline-assembly
            let bitShift := shl(5, index) // bitShift = index * 32
            let begin := and(0xffffffff, shr(bitShift, shl(32, offsets))) // begin = offsets[ bitShift : bitShift + 32 ]
            let end := and(0xffffffff, shr(bitShift, offsets)) // end   = offsets[ bitShift + 32 : bitShift + 64 ]
            result.offset := add(concat.offset, begin)
            result.length := sub(end, begin)
            if gt(end, concat.length) {
                mstore(0, exception)
                revert(0, 4)
            }
        }
    }
}

library ExtensionLib {
    using AddressLib for Address;
    using OffsetsLib for Offsets;

    enum DynamicField {
        MakerAssetSuffix,
        TakerAssetSuffix,
        MakingAmountData,
        TakingAmountData,
        Predicate,
        MakerPermit,
        PreInteractionData,
        PostInteractionData,
        CustomData
    }

    function makerAssetSuffix(
        bytes calldata extension
    ) internal pure returns (bytes calldata) {
        return _get(extension, DynamicField.MakerAssetSuffix);
    }
    function takerAssetSuffix(
        bytes calldata extension
    ) internal pure returns (bytes calldata) {
        return _get(extension, DynamicField.TakerAssetSuffix);
    }

    function makingAmountData(
        bytes calldata extension
    ) internal pure returns (bytes calldata) {
        return _get(extension, DynamicField.MakingAmountData);
    }

    function takingAmountData(
        bytes calldata extension
    ) internal pure returns (bytes calldata) {
        return _get(extension, DynamicField.TakingAmountData);
    }

    function predicate(
        bytes calldata extension
    ) internal pure returns (bytes calldata) {
        return _get(extension, DynamicField.Predicate);
    }

    function makerPermit(
        bytes calldata extension
    ) internal pure returns (bytes calldata) {
        return _get(extension, DynamicField.MakerPermit);
    }

    function preInteractionTargetAndData(
        bytes calldata extension
    ) internal pure returns (bytes calldata) {
        return _get(extension, DynamicField.PreInteractionData);
    }

    function postInteractionTargetAndData(
        bytes calldata extension
    ) internal pure returns (bytes calldata) {
        return _get(extension, DynamicField.PostInteractionData);
    }

    function customData(
        bytes calldata extension
    ) internal pure returns (bytes calldata) {
        if (extension.length < 0x20) return msg.data[:0];
        uint256 offsets = uint256(bytes32(extension));
        unchecked {
            return extension[0x20 + (offsets >> 224):];
        }
    }

    function _get(
        bytes calldata extension,
        DynamicField field
    ) private pure returns (bytes calldata) {
        if (extension.length < 0x20) return msg.data[:0];

        Offsets offsets;
        bytes calldata concat;
        assembly ("memory-safe") {
            // solhint-disable-line no-inline-assembly
            offsets := calldataload(extension.offset)
            concat.offset := add(extension.offset, 0x20)
            concat.length := sub(extension.length, 0x20)
        }

        return offsets.get(concat, uint256(field));
    }
}

interface IOrderMixin {
    struct Order {
        uint256 salt;
        Address maker;
        Address receiver;
        Address makerAsset;
        Address takerAsset;
        uint256 makingAmount;
        uint256 takingAmount;
        MakerTraits makerTraits;
    }
}

library ECDSA {
    uint256 private constant _S_BOUNDARY =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0 + 1;
    uint256 private constant _COMPACT_S_MASK =
        0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    uint256 private constant _COMPACT_V_SHIFT = 255;

    function recover(
        bytes32 hash,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal view returns (address signer) {
        assembly ("memory-safe") {
            // solhint-disable-line no-inline-assembly
            if lt(s, _S_BOUNDARY) {
                let ptr := mload(0x40)

                mstore(ptr, hash)
                mstore(add(ptr, 0x20), v)
                mstore(add(ptr, 0x40), r)
                mstore(add(ptr, 0x60), s)
                mstore(0, 0)
                pop(staticcall(gas(), 0x1, ptr, 0x80, 0, 0x20))
                signer := mload(0)
            }
        }
    }

    function recover(
        bytes32 hash,
        bytes32 r,
        bytes32 vs
    ) internal view returns (address signer) {
        assembly ("memory-safe") {
            // solhint-disable-line no-inline-assembly
            let s := and(vs, _COMPACT_S_MASK)
            if lt(s, _S_BOUNDARY) {
                let ptr := mload(0x40)

                mstore(ptr, hash)
                mstore(add(ptr, 0x20), add(27, shr(_COMPACT_V_SHIFT, vs)))
                mstore(add(ptr, 0x40), r)
                mstore(add(ptr, 0x60), s)
                mstore(0, 0)
                pop(staticcall(gas(), 0x1, ptr, 0x80, 0, 0x20))
                signer := mload(0)
            }
        }
    }

    function recover(
        bytes32 hash,
        bytes calldata signature
    ) internal view returns (address signer) {
        assembly ("memory-safe") {
            // solhint-disable-line no-inline-assembly
            let ptr := mload(0x40)

            // memory[ptr:ptr+0x80] = (hash, v, r, s)
            switch signature.length
            case 65 {
                // memory[ptr+0x20:ptr+0x80] = (v, r, s)
                mstore(
                    add(ptr, 0x20),
                    byte(0, calldataload(add(signature.offset, 0x40)))
                )
                calldatacopy(add(ptr, 0x40), signature.offset, 0x40)
            }
            case 64 {
                // memory[ptr+0x20:ptr+0x80] = (v, r, s)
                let vs := calldataload(add(signature.offset, 0x20))
                mstore(add(ptr, 0x20), add(27, shr(_COMPACT_V_SHIFT, vs)))
                calldatacopy(add(ptr, 0x40), signature.offset, 0x20)
                mstore(add(ptr, 0x60), and(vs, _COMPACT_S_MASK))
            }
            default {
                ptr := 0
            }

            if ptr {
                if lt(mload(add(ptr, 0x60)), _S_BOUNDARY) {
                    // memory[ptr:ptr+0x20] = (hash)
                    mstore(ptr, hash)

                    mstore(0, 0)
                    pop(staticcall(gas(), 0x1, ptr, 0x80, 0, 0x20))
                    signer := mload(0)
                }
            }
        }
    }

    function toEthSignedMessageHash(
        bytes32 hash
    ) internal pure returns (bytes32 res) {
        // 32 is the length in bytes of hash, enforced by the type signature above
        // return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
        assembly ("memory-safe") {
            // solhint-disable-line no-inline-assembly
            mstore(
                0,
                0x19457468657265756d205369676e6564204d6573736167653a0a333200000000
            ) // "\x19Ethereum Signed Message:\n32"
            mstore(28, hash)
            res := keccak256(0, 60)
        }
    }

    function toTypedDataHash(
        bytes32 domainSeparator,
        bytes32 structHash
    ) internal pure returns (bytes32 res) {
        // return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        assembly ("memory-safe") {
            // solhint-disable-line no-inline-assembly
            let ptr := mload(0x40)
            mstore(
                ptr,
                0x1901000000000000000000000000000000000000000000000000000000000000
            ) // "\x19\x01"
            mstore(add(ptr, 0x02), domainSeparator)
            mstore(add(ptr, 0x22), structHash)
            res := keccak256(ptr, 66)
        }
    }
}

library AmountCalculatorLib {
    function getMakingAmount(
        uint256 orderMakerAmount,
        uint256 orderTakerAmount,
        uint256 swapTakerAmount
    ) internal pure returns (uint256) {
        if ((swapTakerAmount | orderMakerAmount) >> 128 == 0) {
            unchecked {
                return (swapTakerAmount * orderMakerAmount) / orderTakerAmount;
            }
        }
        return (swapTakerAmount * orderMakerAmount) / orderTakerAmount;
    }

    /// @notice Calculates taker amount
    /// @return Result Ceiled taker amount
    function getTakingAmount(
        uint256 orderMakerAmount,
        uint256 orderTakerAmount,
        uint256 swapMakerAmount
    ) internal pure returns (uint256) {
        if ((swapMakerAmount | orderTakerAmount) >> 128 == 0) {
            unchecked {
                return
                    (swapMakerAmount *
                        orderTakerAmount +
                        orderMakerAmount -
                        1) / orderMakerAmount;
            }
        }
        return
            (swapMakerAmount * orderTakerAmount + orderMakerAmount - 1) /
            orderMakerAmount;
    }
}

type RemainingInvalidator is uint256;
library RemainingInvalidatorLib {
    error RemainingInvalidatedOrder();

    function isNewOrder(
        RemainingInvalidator invalidator
    ) internal pure returns (bool) {
        return RemainingInvalidator.unwrap(invalidator) == 0;
    }

    function remaining(
        RemainingInvalidator invalidator
    ) internal pure returns (uint256) {
        uint256 value = RemainingInvalidator.unwrap(invalidator);
        if (value == 0) {
            revert RemainingInvalidatedOrder();
        }
        unchecked {
            return ~value;
        }
    }

    function remaining(
        RemainingInvalidator invalidator,
        uint256 orderMakerAmount
    ) internal pure returns (uint256) {
        uint256 value = RemainingInvalidator.unwrap(invalidator);
        if (value == 0) {
            return orderMakerAmount;
        }
        unchecked {
            return ~value;
        }
    }

    function remains(
        uint256 remainingMakingAmount,
        uint256 makingAmount
    ) internal pure returns (RemainingInvalidator) {
        unchecked {
            return
                RemainingInvalidator.wrap(
                    ~(remainingMakingAmount - makingAmount)
                );
        }
    }
    function fullyFilled() internal pure returns (RemainingInvalidator) {
        return RemainingInvalidator.wrap(type(uint256).max);
    }
}
library OrderLib {
    using AddressLib for Address;
    using MakerTraitsLib for MakerTraits;
    using ExtensionLib for bytes;

    /// @dev Error to be thrown when the extension data of an order is missing.
    error MissingOrderExtension();
    /// @dev Error to be thrown when the order has an unexpected extension.
    error UnexpectedOrderExtension();
    /// @dev Error to be thrown when the order extension hash is invalid.
    error InvalidExtensionHash();

    /// @dev The typehash of the order struct.
    bytes32 internal constant _LIMIT_ORDER_TYPEHASH =
        keccak256(
            "Order("
            "uint256 salt,"
            "address maker,"
            "address receiver,"
            "address makerAsset,"
            "address takerAsset,"
            "uint256 makingAmount,"
            "uint256 takingAmount,"
            "uint256 makerTraits"
            ")"
        );
    uint256 internal constant _ORDER_STRUCT_SIZE = 0x100;
    uint256 internal constant _DATA_HASH_SIZE = 0x120;

    function hash(
        IOrderMixin.Order calldata order
    ) internal pure returns (bytes32 result) {
        bytes32 typehash = _LIMIT_ORDER_TYPEHASH;
        assembly ("memory-safe") {
            // solhint-disable-line no-inline-assembly
            let ptr := mload(0x40)

            // keccak256(abi.encode(_LIMIT_ORDER_TYPEHASH, order));
            mstore(ptr, typehash)
            calldatacopy(add(ptr, 0x20), order, _ORDER_STRUCT_SIZE)
            result := keccak256(ptr, _DATA_HASH_SIZE)
        }
        result = ECDSA.toTypedDataHash("0x", result);
    }

    function getReceiver(
        IOrderMixin.Order calldata order
    ) internal pure returns (address /*receiver*/) {
        address receiver = order.receiver.get();
        return receiver != address(0) ? receiver : order.maker.get();
    }

    function isValidExtension(
        IOrderMixin.Order calldata order,
        bytes calldata extension
    ) internal pure returns (bool, bytes4) {
        if (order.makerTraits.hasExtension()) {
            if (extension.length == 0)
                return (false, MissingOrderExtension.selector);
            // Lowest 160 bits of the order salt must be equal to the lowest 160 bits of the extension hash
            if (
                uint256(keccak256(extension)) & type(uint160).max !=
                order.salt & type(uint160).max
            ) return (false, InvalidExtensionHash.selector);
        } else {
            if (extension.length > 0)
                return (false, UnexpectedOrderExtension.selector);
        }
        return (true, 0x00000000);
    }
}

interface IPostInteraction {
    /**
     * @notice Callback method that gets called after all fund transfers
     * @param order Order being processed
     * @param extension Order extension data
     * @param orderHash Hash of the order being processed
     * @param taker Taker address
     * @param makingAmount Actual making amount
     * @param takingAmount Actual taking amount
     * @param remainingMakingAmount Order remaining making amount
     * @param extraData Extra data
     */
    function postInteraction(
        IOrderMixin.Order calldata order,
        bytes calldata extension,
        bytes32 orderHash,
        address taker,
        uint256 makingAmount,
        uint256 takingAmount,
        uint256 remainingMakingAmount,
        bytes calldata extraData
    ) external;
}

interface IPreInteraction {
    /**
     * @notice Callback method that gets called before any funds transfers
     * @param order Order being processed
     * @param extension Order extension data
     * @param orderHash Hash of the order being processed
     * @param taker Taker address
     * @param makingAmount Actual making amount
     * @param takingAmount Actual taking amount
     * @param remainingMakingAmount Order remaining making amount
     * @param extraData Extra data
     */
    function preInteraction(
        IOrderMixin.Order calldata order,
        bytes calldata extension,
        bytes32 orderHash,
        address taker,
        uint256 makingAmount,
        uint256 takingAmount,
        uint256 remainingMakingAmount,
        bytes calldata extraData
    ) external;
}
contract ChaingeOrder is Controller {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;
    using OrderLib for IOrderMixin.Order;
    using ExtensionLib for bytes;
    using AddressLib for Address;
    using MakerTraitsLib for MakerTraits;
    using TakerTraitsLib for TakerTraits;
    using RemainingInvalidatorLib for RemainingInvalidator;

    IWETH private _WETH;
    bool private _paused;

    event OrderFilled(bytes32 orderHash, uint256 remainingAmount);

    event OrderCancelled(bytes32 orderHash);

    mapping(address => mapping(bytes32 => RemainingInvalidator))
        private _remainingInvalidator;

    constructor(IWETH weth) {
        _WETH = weth;
        _paused = false;
    }
    modifier whenNotPaused() {
        require(!_paused, "MP: paused");
        _;
    }
    receive() external payable {}

    fallback() external payable {}

    function pause() external onlyOwner {
        _paused = true;
    }

    function unpause() external onlyOwner {
        _paused = false;
    }

    function setWToken(IWETH weth) external onlyOwner {
        _WETH = weth;
    }

    function cancelOrder(bytes32 orderHash) public {
        _remainingInvalidator[msg.sender][orderHash] = RemainingInvalidatorLib
            .fullyFilled();
        emit OrderCancelled(orderHash);
    }

    function cancelOrders(bytes32[] calldata orderHashes) external {
        unchecked {
            for (uint256 i = 0; i < orderHashes.length; i++) {
                cancelOrder(orderHashes[i]);
            }
        }
    }
    function hashOrder(
        IOrderMixin.Order calldata order
    ) external pure returns (bytes32) {
        return order.hash();
    }

    function fillContractOrderArgs(
        IOrderMixin.Order calldata order,
        bytes calldata signature,
        uint256 amount,
        TakerTraits takerTraits,
        bytes calldata args
    )
        external
        onlyController
        whenNotPaused
        returns (
            uint256 /* makingAmount */,
            uint256 /* takingAmount */,
            bytes32 /* orderHash */
        )
    {
        (
            address target,
            bytes calldata extension,
            bytes calldata interaction
        ) = _parseArgs(takerTraits, args);

        return
            _fillContractOrder(
                order,
                signature,
                amount,
                takerTraits,
                target,
                extension,
                interaction
            );
    }

    function _fillContractOrder(
        IOrderMixin.Order calldata order,
        bytes calldata /*signature*/,
        uint256 amount,
        TakerTraits takerTraits,
        address target,
        bytes calldata extension,
        bytes calldata interaction
    )
        private
        returns (uint256 makingAmount, uint256 takingAmount, bytes32 orderHash)
    {
        // Check signature only on the first fill
        orderHash = order.hash();
        uint256 remainingMakingAmount = _checkRemainingMakingAmount(
            order,
            orderHash
        );

        (makingAmount, takingAmount) = _fill(
            order,
            orderHash,
            remainingMakingAmount,
            amount,
            takerTraits,
            target,
            extension,
            interaction
        );
    }

    function _fill(
        IOrderMixin.Order calldata order,
        bytes32 orderHash,
        uint256 remainingMakingAmount,
        uint256 amount,
        TakerTraits takerTraits,
        address target,
        bytes calldata extension,
        bytes calldata /*interaction*/
    ) private returns (uint256 makingAmount, uint256 takingAmount) {
        require(!order.makerTraits.isExpired(), "OrderExpired");

        // Compute maker and taker assets amount
        if (takerTraits.isMakingAmount()) {
            makingAmount = amount < remainingMakingAmount
                ? amount
                : remainingMakingAmount;
            takingAmount = AmountCalculatorLib.getTakingAmount(
                order.makingAmount,
                order.takingAmount,
                remainingMakingAmount
            );

            uint256 threshold = takerTraits.threshold();
            if (threshold > 0) {
                // Check rate: takingAmount / makingAmount <= threshold / amount
                if (amount == makingAmount) {
                    // Gas optimization, no SafeMath.mul()
                    require(takingAmount <= threshold, "TakingAmountTooHigh");
                } else {
                    require(
                        takingAmount * amount <= threshold * makingAmount,
                        "TakingAmountTooHigh"
                    );
                }
            }
        } else {
            takingAmount = amount;
            makingAmount = AmountCalculatorLib.getMakingAmount(
                order.makingAmount,
                order.takingAmount,
                takingAmount
            );
            if (makingAmount > remainingMakingAmount) {
                // Try to decrease taking amount because computed making amount exceeds remaining amount
                makingAmount = remainingMakingAmount;

                takingAmount = AmountCalculatorLib.getTakingAmount(
                    order.makingAmount,
                    order.takingAmount,
                    makingAmount
                );
                require(takingAmount <= amount, "TakingAmountExceeded");
            }

            uint256 threshold = takerTraits.threshold();
            if (threshold > 0) {
                // Check rate: makingAmount / takingAmount >= threshold / amount
                if (amount == takingAmount) {
                    // Gas optimization, no SafeMath.mul()
                    require(makingAmount >= threshold, "MakingAmountTooLow");
                } else {
                    require(
                        makingAmount * amount >= threshold * takingAmount,
                        "MakingAmountTooLow"
                    );
                }
            }
        }
        if (!order.makerTraits.allowPartialFills()) {
            require(
                makingAmount == order.makingAmount,
                "PartialFillNotAllowed"
            );
        }
        require(makingAmount * takingAmount > 0, "SwapWithZeroAmount");

        // Pre interaction, where maker can prepare funds interactively
        {
            if (order.makerTraits.needPreInteractionCall()) {
                bytes calldata data = extension.preInteractionTargetAndData();
                address listener = order.maker.get();
                if (data.length > 19) {
                    listener = address(bytes20(data));
                    data = data[20:];
                }
                IPreInteraction(listener).preInteraction(
                    order,
                    extension,
                    orderHash,
                    msg.sender,
                    makingAmount,
                    takingAmount,
                    remainingMakingAmount,
                    data
                );
            }
        }

        // Maker => Taker
        {
            bool needUnwrap = order.makerAsset.get() == address(_WETH) &&
                takerTraits.unwrapWeth();
            address receiver = needUnwrap ? address(this) : target;
            bool success = _callTransferFromWithSuffix(
                order.makerAsset.get(),
                order.maker.get(),
                receiver,
                makingAmount,
                extension.makerAssetSuffix()
            );
            require(success, "TransferFromMakerToTakerFailed");
            if (needUnwrap) {
                _WETH.safeWithdrawTo(makingAmount, target);
            }
        }

        // Taker => Maker
        if (order.takerAsset.get() == address(_WETH) && msg.value > 0) {
            require(msg.value >= takingAmount, "InvalidMsgValue");
            if (msg.value > takingAmount) {
                unchecked {
                    // solhint-disable-next-line avoid-low-level-calls
                    (bool success, ) = msg.sender.call{
                        value: msg.value - takingAmount
                    }("");
                    require(success, "ETHTransferFailed");
                }
            }

            if (order.makerTraits.unwrapWeth()) {
                // solhint-disable-next-line avoid-low-level-calls
                (bool success, ) = order.getReceiver().call{
                    value: takingAmount
                }("");
                require(success, "ETHTransferFailed");
            } else {
                _WETH.safeDeposit(takingAmount);
                _WETH.safeTransfer(order.getReceiver(), takingAmount);
            }
        } else {
            require(msg.value == 0, "InvalidMsgValue");

            bool needUnwrap = order.takerAsset.get() == address(_WETH) &&
                order.makerTraits.unwrapWeth();
            address receiver = needUnwrap ? address(this) : order.getReceiver();
            require(
                _callTransferFromWithSuffix(
                    order.takerAsset.get(),
                    msg.sender,
                    receiver,
                    takingAmount,
                    extension.takerAssetSuffix()
                ),
                "TransferFromTakerToMakerFailed"
            );

            if (needUnwrap) {
                _WETH.safeWithdrawTo(takingAmount, order.getReceiver());
            }
        }

        // Post interaction, where maker can handle funds interactively
        if (order.makerTraits.needPostInteractionCall()) {
            bytes calldata data = extension.postInteractionTargetAndData();
            address listener = order.maker.get();
            if (data.length > 19) {
                listener = address(bytes20(data));
                data = data[20:];
            }
            IPostInteraction(listener).postInteraction(
                order,
                extension,
                orderHash,
                msg.sender,
                makingAmount,
                takingAmount,
                remainingMakingAmount,
                data
            );
        }

        emit OrderFilled(orderHash, remainingMakingAmount - makingAmount);
    }

    /**
     * @notice Processes the taker interaction arguments.
     * @param takerTraits The taker preferences for the order.
     * @param args The taker interaction arguments.
     * @return target The address to which the order is filled.
     * @return extension The extension calldata of the order.
     * @return interaction The interaction calldata.
     */
    function _parseArgs(
        TakerTraits takerTraits,
        bytes calldata args
    )
        private
        view
        returns (
            address target,
            bytes calldata extension,
            bytes calldata interaction
        )
    {
        if (takerTraits.argsHasTarget()) {
            target = address(bytes20(args));
            args = args[20:];
        } else {
            target = msg.sender;
        }

        uint256 extensionLength = takerTraits.argsExtensionLength();
        if (extensionLength > 0) {
            extension = args[:extensionLength];
            args = args[extensionLength:];
        } else {
            extension = msg.data[:0];
        }

        uint256 interactionLength = takerTraits.argsInteractionLength();
        if (interactionLength > 0) {
            interaction = args[:interactionLength];
        } else {
            interaction = msg.data[:0];
        }
    }

    /**
     * @notice Checks the remaining making amount for the order.
     * @dev If the order has been invalidated, the function will revert.
     * @param order The order to check.
     * @param orderHash The hash of the order.
     * @return remainingMakingAmount The remaining amount of the order.
     */
    function _checkRemainingMakingAmount(
        IOrderMixin.Order calldata order,
        bytes32 orderHash
    ) private view returns (uint256 remainingMakingAmount) {
        remainingMakingAmount = _remainingInvalidator[order.maker.get()][
            orderHash
        ].remaining(order.makingAmount);
        require(remainingMakingAmount > 0, "InvalidatedOrder");
    }

    /**
     * @notice Calls the transferFrom function with an arbitrary suffix.
     * @dev The suffix is appended to the end of the standard ERC20 transferFrom function parameters.
     * @param asset The token to be transferred.
     * @param from The address to transfer the token from.
     * @param to The address to transfer the token to.
     * @param amount The amount of the token to transfer.
     * @param suffix The suffix (additional data) to append to the end of the transferFrom call.
     * @return success A boolean indicating whether the transfer was successful.
     */
    function _callTransferFromWithSuffix(
        address asset,
        address from,
        address to,
        uint256 amount,
        bytes calldata suffix
    ) private returns (bool success) {
        bytes4 selector = IERC20.transferFrom.selector;
        assembly ("memory-safe") {
            // solhint-disable-line no-inline-assembly
            let data := mload(0x40)
            mstore(data, selector)
            mstore(add(data, 0x04), from)
            mstore(add(data, 0x24), to)
            mstore(add(data, 0x44), amount)
            if suffix.length {
                calldatacopy(add(data, 0x64), suffix.offset, suffix.length)
            }
            let status := call(
                gas(),
                asset,
                0,
                data,
                add(0x64, suffix.length),
                0x0,
                0x20
            )
            success := and(
                status,
                or(
                    iszero(returndatasize()),
                    and(gt(returndatasize(), 31), eq(mload(0), 1))
                )
            )
        }
    }
}
