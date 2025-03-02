pragma solidity 0.8.19;

import "./MTokenInterfaces.sol";

/**
 * @title Moonwell's MErc20Delegator Contract
 * @notice MTokens which wrap an EIP-20 underlying and delegate to an implementation
 * @author Moonwell
 */
contract MErc20Delegator is
    MTokenInterface,
    MErc20Interface,
    MDelegatorInterface
{
    /**
     * @notice Construct a new money market
     * @param underlying_ The address of the underlying asset
     * @param comptroller_ The address of the Comptroller
     * @param interestRateModel_ The address of the interest rate model
     * @param initialExchangeRateMantissa_ The initial exchange rate, scaled by 1e18
     * @param name_ ERC-20 name of this token
     * @param symbol_ ERC-20 symbol of this token
     * @param decimals_ ERC-20 decimal precision of this token
     * @param admin_ Address of the administrator of this token
     * @param implementation_ The address of the implementation the contract delegates to
     * @param becomeImplementationData The encoded args for becomeImplementation
     */
    constructor(
        address underlying_,
        ComptrollerInterface comptroller_,
        InterestRateModel interestRateModel_,
        uint initialExchangeRateMantissa_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address payable admin_,
        address implementation_,
        bytes memory becomeImplementationData
    ) {
        // Creator of the contract is admin during initialization
        admin = payable(msg.sender);

        // First delegate gets to initialize the delegator (i.e. storage contract)
        delegateTo(
            implementation_,
            abi.encodeWithSignature(
                "initialize(address,address,address,uint256,string,string,uint8)",
                underlying_,
                comptroller_,
                interestRateModel_,
                initialExchangeRateMantissa_,
                name_,
                symbol_,
                decimals_
            )
        );

        // New implementations always get set via the settor (post-initialize)
        _setImplementation(implementation_, false, becomeImplementationData);

        // Set the proper admin now that initialization is done
        admin = admin_;
    }

    /**
     * @notice Called by the admin to update the implementation of the delegator
     * @param implementation_ The address of the new implementation for delegation
     * @param allowResign Flag to indicate whether to call _resignImplementation on the old implementation
     * @param becomeImplementationData The encoded bytes data to be passed to _becomeImplementation
     */
    function _setImplementation(
        address implementation_,
        bool allowResign,
        bytes memory becomeImplementationData
    ) public override {
        require(
            msg.sender == admin,
            "MErc20Delegator::_setImplementation: Caller must be admin"
        );

        if (allowResign) {
            delegateToImplementation(
                abi.encodeWithSignature("_resignImplementation()")
            );
        }

        address oldImplementation = implementation;
        implementation = implementation_;

        delegateToImplementation(
            abi.encodeWithSignature(
                "_becomeImplementation(bytes)",
                becomeImplementationData
            )
        );

        emit NewImplementation(oldImplementation, implementation);
    }

    /**
     * @notice Sender supplies assets into the market and receives mTokens in exchange
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param mintAmount The amount of the underlying asset to supply
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function mint(uint mintAmount) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("mint(uint256)", mintAmount)
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Supply assets but without a 2-step approval process, EIP-2612
     * @dev Simply calls the underlying token's `permit()` function and then assumes things worked
     * @param mintAmount The amount of the underlying asset to supply
     * @param deadline The amount of the underlying asset to supply
     * @param v ECDSA recovery id for the signature
     * @param r ECDSA r parameter for the signature
     * @param s ECDSA s parameter for the signature
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function mintWithPermit(
        uint mintAmount,
        uint deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature(
                "mintWithPermit(uint256,uint256,uint8,bytes32,bytes32)",
                mintAmount,
                deadline,
                v,
                r,
                s
            )
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Sender redeems mTokens in exchange for the underlying asset
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param redeemTokens The number of mTokens to redeem into underlying
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function redeem(uint redeemTokens) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("redeem(uint256)", redeemTokens)
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Sender redeems mTokens in exchange for a specified amount of underlying asset
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param redeemAmount The amount of underlying to redeem
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function redeemUnderlying(
        uint redeemAmount
    ) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("redeemUnderlying(uint256)", redeemAmount)
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Sender borrows assets from the protocol to their own address
     * @param borrowAmount The amount of the underlying asset to borrow
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function borrow(uint borrowAmount) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("borrow(uint256)", borrowAmount)
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Sender repays their own borrow
     * @param repayAmount The amount to repay, or uint.max for the full outstanding amount
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function repayBorrow(uint repayAmount) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("repayBorrow(uint256)", repayAmount)
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Sender repays a borrow belonging to borrower
     * @param borrower the account with the debt being payed off
     * @param repayAmount The amount to repay, or uint.max for the full outstanding amount
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function repayBorrowBehalf(
        address borrower,
        uint repayAmount
    ) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature(
                "repayBorrowBehalf(address,uint256)",
                borrower,
                repayAmount
            )
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice The sender liquidates the borrowers collateral.
     *  The collateral seized is transferred to the liquidator.
     * @param borrower The borrower of this mToken to be liquidated
     * @param mTokenCollateral The market in which to seize collateral from the borrower
     * @param repayAmount The amount of the underlying borrowed asset to repay
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function liquidateBorrow(
        address borrower,
        uint repayAmount,
        MTokenInterface mTokenCollateral
    ) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature(
                "liquidateBorrow(address,uint256,address)",
                borrower,
                repayAmount,
                mTokenCollateral
            )
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Transfer `amount` tokens from `msg.sender` to `dst`
     * @param dst The address of the destination account
     * @param amount The number of tokens to transfer
     * @return Whether or not the transfer succeeded
     */
    function transfer(
        address dst,
        uint amount
    ) external override returns (bool) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("transfer(address,uint256)", dst, amount)
        );
        return abi.decode(data, (bool));
    }

    /**
     * @notice Transfer `amount` tokens from `src` to `dst`
     * @param src The address of the source account
     * @param dst The address of the destination account
     * @param amount The number of tokens to transfer
     * @return Whether or not the transfer succeeded
     */
    function transferFrom(
        address src,
        address dst,
        uint256 amount
    ) external override returns (bool) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)",
                src,
                dst,
                amount
            )
        );
        return abi.decode(data, (bool));
    }

    /**
     * @notice Approve `spender` to transfer up to `amount` from `src`
     * @dev This will overwrite the approval amount for `spender`
     *  and is subject to issues noted [here](https://eips.ethereum.org/EIPS/eip-20#approve)
     * @param spender The address of the account which may transfer tokens
     * @param amount The number of tokens that are approved (uint.max means infinite)
     * @return Whether or not the approval succeeded
     */
    function approve(
        address spender,
        uint256 amount
    ) external override returns (bool) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("approve(address,uint256)", spender, amount)
        );
        return abi.decode(data, (bool));
    }

    /**
     * @notice Get the current allowance from `owner` for `spender`
     * @param owner The address of the account which owns the tokens to be spent
     * @param spender The address of the account which may transfer tokens
     * @return The number of tokens allowed to be spent (uint.max means infinite)
     */
    function allowance(
        address owner,
        address spender
    ) external view override returns (uint) {
        bytes memory data = delegateToViewImplementation(
            abi.encodeWithSignature(
                "allowance(address,address)",
                owner,
                spender
            )
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Get the token balance of the `owner`
     * @param owner The address of the account to query
     * @return The number of tokens owned by `owner`
     */
    function balanceOf(address owner) external view override returns (uint) {
        bytes memory data = delegateToViewImplementation(
            abi.encodeWithSignature("balanceOf(address)", owner)
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Get the underlying balance of the `owner`
     * @dev This also accrues interest in a transaction
     * @param owner The address of the account to query
     * @return The amount of underlying owned by `owner`
     */
    function balanceOfUnderlying(
        address owner
    ) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("balanceOfUnderlying(address)", owner)
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Get a snapshot of the account's balances, and the cached exchange rate
     * @dev This is used by comptroller to more efficiently perform liquidity checks.
     * @param account Address of the account to snapshot
     * @return (possible error, token balance, borrow balance, exchange rate mantissa)
     */
    function getAccountSnapshot(
        address account
    ) external view override returns (uint, uint, uint, uint) {
        bytes memory data = delegateToViewImplementation(
            abi.encodeWithSignature("getAccountSnapshot(address)", account)
        );
        return abi.decode(data, (uint, uint, uint, uint));
    }

    /**
     * @notice Returns the current per-timestamp borrow interest rate for this mToken
     * @return The borrow interest rate per timestamp, scaled by 1e18
     */
    function borrowRatePerTimestamp() external view override returns (uint) {
        bytes memory data = delegateToViewImplementation(
            abi.encodeWithSignature("borrowRatePerTimestamp()")
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Returns the current per-timestamp supply interest rate for this mToken
     * @return The supply interest rate per timestamp, scaled by 1e18
     */
    function supplyRatePerTimestamp() external view override returns (uint) {
        bytes memory data = delegateToViewImplementation(
            abi.encodeWithSignature("supplyRatePerTimestamp()")
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Returns the current total borrows plus accrued interest
     * @return The total borrows with interest
     */
    function totalBorrowsCurrent() external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("totalBorrowsCurrent()")
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Accrue interest to updated borrowIndex and then calculate account's borrow balance using the updated borrowIndex
     * @param account The address whose balance should be calculated after updating borrowIndex
     * @return The calculated balance
     */
    function borrowBalanceCurrent(
        address account
    ) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("borrowBalanceCurrent(address)", account)
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Return the borrow balance of account based on stored data
     * @param account The address whose balance should be calculated
     * @return The calculated balance
     */
    function borrowBalanceStored(
        address account
    ) public view override returns (uint) {
        bytes memory data = delegateToViewImplementation(
            abi.encodeWithSignature("borrowBalanceStored(address)", account)
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Accrue interest then return the up-to-date exchange rate
     * @return Calculated exchange rate scaled by 1e18
     */
    function exchangeRateCurrent() public override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("exchangeRateCurrent()")
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Calculates the exchange rate from the underlying to the MToken
     * @dev This function does not accrue interest before calculating the exchange rate
     * @return Calculated exchange rate scaled by 1e18
     */
    function exchangeRateStored() public view override returns (uint) {
        bytes memory data = delegateToViewImplementation(
            abi.encodeWithSignature("exchangeRateStored()")
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Get cash balance of this mToken in the underlying asset
     * @return The quantity of underlying asset owned by this contract
     */
    function getCash() external view override returns (uint) {
        bytes memory data = delegateToViewImplementation(
            abi.encodeWithSignature("getCash()")
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Applies accrued interest to total borrows and reserves.
     * @dev This calculates interest accrued from the last checkpointed block
     *      up to the current block and writes new checkpoint to storage.
     */
    function accrueInterest() public override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("accrueInterest()")
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Transfers collateral tokens (this market) to the liquidator.
     * @dev Will fail unless called by another mToken during the process of liquidation.
     *  Its absolutely critical to use msg.sender as the borrowed mToken and not a parameter.
     * @param liquidator The account receiving seized collateral
     * @param borrower The account having collateral seized
     * @param seizeTokens The number of mTokens to seize
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function seize(
        address liquidator,
        address borrower,
        uint seizeTokens
    ) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature(
                "seize(address,address,uint256)",
                liquidator,
                borrower,
                seizeTokens
            )
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice A public function to sweep accidental ERC-20 transfers to this contract. Tokens are sent to admin (timelock)
     * @param token The address of the ERC-20 token to sweep
     */
    function sweepToken(EIP20NonStandardInterface token) external override {
        delegateToImplementation(
            abi.encodeWithSignature("sweepToken(address)", token)
        );
    }

    /*** Admin Functions ***/

    /**
     * @notice Begins transfer of admin rights. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
     * @dev Admin function to begin change of admin. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
     * @param newPendingAdmin New pending admin.
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setPendingAdmin(
        address payable newPendingAdmin
    ) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature(
                "_setPendingAdmin(address)",
                newPendingAdmin
            )
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Sets a new comptroller for the market
     * @dev Admin function to set a new comptroller
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setComptroller(
        ComptrollerInterface newComptroller
    ) public override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("_setComptroller(address)", newComptroller)
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice accrues interest and sets a new reserve factor for the protocol using _setReserveFactorFresh
     * @dev Admin function to accrue interest and set a new reserve factor
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setReserveFactor(
        uint newReserveFactorMantissa
    ) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature(
                "_setReserveFactor(uint256)",
                newReserveFactorMantissa
            )
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Accepts transfer of admin rights. msg.sender must be pendingAdmin
     * @dev Admin function for pending admin to accept role and update admin
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _acceptAdmin() external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("_acceptAdmin()")
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Accrues interest and adds reserves by transferring from admin
     * @param addAmount Amount of reserves to add
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _addReserves(uint addAmount) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("_addReserves(uint256)", addAmount)
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Accrues interest and reduces reserves by transferring to admin
     * @param reduceAmount Amount of reduction to reserves
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _reduceReserves(
        uint reduceAmount
    ) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature("_reduceReserves(uint256)", reduceAmount)
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Accrues interest and updates the interest rate model using _setInterestRateModelFresh
     * @dev Admin function to accrue interest and update the interest rate model
     * @param newInterestRateModel the new interest rate model to use
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setInterestRateModel(
        InterestRateModel newInterestRateModel
    ) public override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature(
                "_setInterestRateModel(address)",
                newInterestRateModel
            )
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice accrues interest and sets a new protocol seize share for the protocol using _setProtocolSeizeShareFresh
     * @dev Admin function to accrue interest and set a new protocol seize share
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setProtocolSeizeShare(
        uint newProtocolSeizeShareMantissa
    ) external override returns (uint) {
        bytes memory data = delegateToImplementation(
            abi.encodeWithSignature(
                "_setProtocolSeizeShare(uint256)",
                newProtocolSeizeShareMantissa
            )
        );
        return abi.decode(data, (uint));
    }

    /**
     * @notice Internal method to delegate execution to another contract
     * @dev It returns to the external caller whatever the implementation returns or forwards reverts
     * @param callee The contract to delegatecall
     * @param data The raw data to delegatecall
     * @return The returned bytes from the delegatecall
     */
    function delegateTo(
        address callee,
        bytes memory data
    ) internal returns (bytes memory) {
        (bool success, bytes memory returnData) = callee.delegatecall(data);
        assembly {
            if eq(success, 0) {
                revert(add(returnData, 0x20), returndatasize())
            }
        }
        return returnData;
    }

    /**
     * @notice Delegates execution to the implementation contract
     * @dev It returns to the external caller whatever the implementation returns or forwards reverts
     * @param data The raw data to delegatecall
     * @return The returned bytes from the delegatecall
     */
    function delegateToImplementation(
        bytes memory data
    ) public returns (bytes memory) {
        return delegateTo(implementation, data);
    }

    /**
     * @notice Delegates execution to an implementation contract
     * @dev It returns to the external caller whatever the implementation returns or forwards reverts
     *  There are an additional 2 prefix uints from the wrapper returndata, which we ignore since we make an extra hop.
     * @param data The raw data to delegatecall
     * @return The returned bytes from the delegatecall
     */
    function delegateToViewImplementation(
        bytes memory data
    ) public view returns (bytes memory) {
        (bool success, bytes memory returnData) = address(this).staticcall(
            abi.encodeWithSignature("delegateToImplementation(bytes)", data)
        );
        assembly {
            if eq(success, 0) {
                revert(add(returnData, 0x20), returndatasize())
            }
        }
        return abi.decode(returnData, (bytes));
    }

    /**
     * @notice Delegates execution to an implementation contract
     * @dev It returns to the external caller whatever the implementation returns or forwards reverts
     */
    fallback() external payable {
        require(
            msg.value == 0,
            "MErc20Delegator:fallback: cannot send value to fallback"
        );

        // delegate all other functions to current implementation
        (bool success, ) = implementation.delegatecall(msg.data);

        assembly {
            let free_mem_ptr := mload(0x40)
            returndatacopy(free_mem_ptr, 0, returndatasize())

            switch success
            case 0 {
                revert(free_mem_ptr, returndatasize())
            }
            default {
                return(free_mem_ptr, returndatasize())
            }
        }
    }
}
pragma solidity 0.8.19;

import "./ComptrollerInterface.sol";
import "./irm/InterestRateModel.sol";
import "./EIP20NonStandardInterface.sol";
import "./ErrorReporter.sol";

contract MTokenStorage {
    /// @dev Guard variable for re-entrancy checks
    bool internal _notEntered;

    /// @notice EIP-20 token name for this token
    string public name;

    /// @notice EIP-20 token symbol for this token
    string public symbol;

    /// @notice EIP-20 token decimals for this token
    uint8 public decimals;

    /// @notice Maximum borrow rate that can ever be applied (.0005% / block)
    uint internal constant borrowRateMaxMantissa = 0.0005e16;

    // @notice Maximum fraction of interest that can be set aside for reserves
    uint internal constant reserveFactorMaxMantissa = 1e18;

    /// @notice Administrator for this contract
    address payable public admin;

    /// @notice Pending administrator for this contract
    address payable public pendingAdmin;

    /// @notice Contract which oversees inter-mToken operations
    ComptrollerInterface public comptroller;

    /// @notice Model which tells what the current interest rate should be
    InterestRateModel public interestRateModel;

    // @notice Initial exchange rate used when minting the first MTokens (used when totalSupply = 0)
    uint internal initialExchangeRateMantissa;

    /// @notice Fraction of interest currently set aside for reserves
    uint public reserveFactorMantissa;

    /// @notice Block number that interest was last accrued at
    uint public accrualBlockTimestamp;

    /// @notice Accumulator of the total earned interest rate since the opening of the market
    uint public borrowIndex;

    /// @notice Total amount of outstanding borrows of the underlying in this market
    uint public totalBorrows;

    /// @notice Total amount of reserves of the underlying held in this market
    uint public totalReserves;

    /// @notice Total number of tokens in circulation
    uint public totalSupply;

    /// @notice Official record of token balances for each account
    mapping(address => uint) internal accountTokens;

    /// @notice Approved token transfer amounts on behalf of others
    mapping(address => mapping(address => uint)) internal transferAllowances;

    /**
     * @notice Container for borrow balance information
     * @member principal Total balance (with accrued interest), after applying the most recent balance-changing action
     * @member interestIndex Global borrowIndex as of the most recent balance-changing action
     */
    struct BorrowSnapshot {
        uint principal;
        uint interestIndex;
    }

    // @notice Mapping of account addresses to outstanding borrow balances
    mapping(address => BorrowSnapshot) internal accountBorrows;

    /// @notice Share of seized collateral that is added to reserves
    uint public protocolSeizeShareMantissa;
}

abstract contract MTokenInterface is MTokenStorage {
    /// @notice Indicator that this is a MToken contract (for inspection)
    bool public constant isMToken = true;

    /*** Market Events ***/

    /// @notice Event emitted when interest is accrued
    event AccrueInterest(
        uint cashPrior,
        uint interestAccumulated,
        uint borrowIndex,
        uint totalBorrows
    );

    /// @notice Event emitted when tokens are minted
    event Mint(address minter, uint mintAmount, uint mintTokens);

    /// @notice Event emitted when tokens are redeemed
    event Redeem(address redeemer, uint redeemAmount, uint redeemTokens);

    /// @notice Event emitted when underlying is borrowed
    event Borrow(
        address borrower,
        uint borrowAmount,
        uint accountBorrows,
        uint totalBorrows
    );

    /// @notice Event emitted when a borrow is repaid
    event RepayBorrow(
        address payer,
        address borrower,
        uint repayAmount,
        uint accountBorrows,
        uint totalBorrows
    );

    /// @notice Event emitted when a borrow is liquidated
    event LiquidateBorrow(
        address liquidator,
        address borrower,
        uint repayAmount,
        address mTokenCollateral,
        uint seizeTokens
    );

    /*** Admin Events ***/

    /// @notice Event emitted when pendingAdmin is changed
    event NewPendingAdmin(address oldPendingAdmin, address newPendingAdmin);

    /// @notice Event emitted when pendingAdmin is accepted, which means admin is updated
    event NewAdmin(address oldAdmin, address newAdmin);

    /// @notice Event emitted when comptroller is changed
    event NewComptroller(
        ComptrollerInterface oldComptroller,
        ComptrollerInterface newComptroller
    );

    /// @notice Event emitted when interestRateModel is changed
    event NewMarketInterestRateModel(
        InterestRateModel oldInterestRateModel,
        InterestRateModel newInterestRateModel
    );

    /// @notice Event emitted when the reserve factor is changed
    event NewReserveFactor(
        uint oldReserveFactorMantissa,
        uint newReserveFactorMantissa
    );

    /// @notice Event emitted when the protocol seize share is changed
    event NewProtocolSeizeShare(
        uint oldProtocolSeizeShareMantissa,
        uint newProtocolSeizeShareMantissa
    );

    /// @notice Event emitted when the reserves are added
    event ReservesAdded(
        address benefactor,
        uint addAmount,
        uint newTotalReserves
    );

    /// @notice Event emitted when the reserves are reduced
    event ReservesReduced(
        address admin,
        uint reduceAmount,
        uint newTotalReserves
    );

    /// @notice EIP20 Transfer event
    event Transfer(address indexed from, address indexed to, uint amount);

    /// @notice EIP20 Approval event
    event Approval(address indexed owner, address indexed spender, uint amount);

    /*** User Interface ***/

    function transfer(address dst, uint amount) external virtual returns (bool);
    function transferFrom(
        address src,
        address dst,
        uint amount
    ) external virtual returns (bool);
    function approve(
        address spender,
        uint amount
    ) external virtual returns (bool);
    function allowance(
        address owner,
        address spender
    ) external view virtual returns (uint);
    function balanceOf(address owner) external view virtual returns (uint);
    function balanceOfUnderlying(address owner) external virtual returns (uint);
    function getAccountSnapshot(
        address account
    ) external view virtual returns (uint, uint, uint, uint);
    function borrowRatePerTimestamp() external view virtual returns (uint);
    function supplyRatePerTimestamp() external view virtual returns (uint);
    function totalBorrowsCurrent() external virtual returns (uint);
    function borrowBalanceCurrent(
        address account
    ) external virtual returns (uint);
    function borrowBalanceStored(
        address account
    ) external view virtual returns (uint);
    function exchangeRateCurrent() external virtual returns (uint);
    function exchangeRateStored() external view virtual returns (uint);
    function getCash() external view virtual returns (uint);
    function accrueInterest() external virtual returns (uint);
    function seize(
        address liquidator,
        address borrower,
        uint seizeTokens
    ) external virtual returns (uint);

    /*** Admin Functions ***/

    function _setPendingAdmin(
        address payable newPendingAdmin
    ) external virtual returns (uint);
    function _acceptAdmin() external virtual returns (uint);
    function _setComptroller(
        ComptrollerInterface newComptroller
    ) external virtual returns (uint);
    function _setReserveFactor(
        uint newReserveFactorMantissa
    ) external virtual returns (uint);
    function _reduceReserves(uint reduceAmount) external virtual returns (uint);
    function _setInterestRateModel(
        InterestRateModel newInterestRateModel
    ) external virtual returns (uint);
    function _setProtocolSeizeShare(
        uint newProtocolSeizeShareMantissa
    ) external virtual returns (uint);
}

contract MErc20Storage {
    /// @notice Underlying asset for this MToken
    address public underlying;
}

abstract contract MErc20Interface is MErc20Storage {
    /*** User Interface ***/

    function mint(uint mintAmount) external virtual returns (uint);
    function mintWithPermit(
        uint mintAmount,
        uint deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external virtual returns (uint);
    function redeem(uint redeemTokens) external virtual returns (uint);
    function redeemUnderlying(
        uint redeemAmount
    ) external virtual returns (uint);
    function borrow(uint borrowAmount) external virtual returns (uint);
    function repayBorrow(uint repayAmount) external virtual returns (uint);
    function repayBorrowBehalf(
        address borrower,
        uint repayAmount
    ) external virtual returns (uint);
    function liquidateBorrow(
        address borrower,
        uint repayAmount,
        MTokenInterface mTokenCollateral
    ) external virtual returns (uint);
    function sweepToken(EIP20NonStandardInterface token) external virtual;

    /*** Admin Functions ***/

    function _addReserves(uint addAmount) external virtual returns (uint);
}

contract MDelegationStorage {
    /// @notice Implementation address for this contract
    address public implementation;
}

abstract contract MDelegatorInterface is MDelegationStorage {
    /// @notice Emitted when implementation is changed
    event NewImplementation(
        address oldImplementation,
        address newImplementation
    );

    /**
     * @notice Called by the admin to update the implementation of the delegator
     * @param implementation_ The address of the new implementation for delegation
     * @param allowResign Flag to indicate whether to call _resignImplementation on the old implementation
     * @param becomeImplementationData The encoded bytes data to be passed to _becomeImplementation
     */
    function _setImplementation(
        address implementation_,
        bool allowResign,
        bytes memory becomeImplementationData
    ) external virtual;
}

abstract contract MDelegateInterface is MDelegationStorage {
    /**
     * @notice Called by the delegator on a delegate to initialize it for duty
     * @dev Should revert if any issues arise which make it unfit for delegation
     * @param data The encoded bytes data for any initialization
     */
    function _becomeImplementation(bytes memory data) external virtual;

    /// @notice Called by the delegator on a delegate to forfeit its responsibility
    function _resignImplementation() external virtual;
}
pragma solidity 0.8.19;

abstract contract ComptrollerInterface {
    /// @notice Indicator that this is a Comptroller contract (for inspection)
    bool public constant isComptroller = true;

    /*** Assets You Are In ***/

    function enterMarkets(
        address[] calldata mTokens
    ) external virtual returns (uint[] memory);
    function exitMarket(address mToken) external virtual returns (uint);

    /*** Policy Hooks ***/

    function mintAllowed(
        address mToken,
        address minter,
        uint mintAmount
    ) external virtual returns (uint);

    function redeemAllowed(
        address mToken,
        address redeemer,
        uint redeemTokens
    ) external virtual returns (uint);

    // Do not remove, still used by MToken
    function redeemVerify(
        address mToken,
        address redeemer,
        uint redeemAmount,
        uint redeemTokens
    ) external pure virtual;

    function borrowAllowed(
        address mToken,
        address borrower,
        uint borrowAmount
    ) external virtual returns (uint);

    function repayBorrowAllowed(
        address mToken,
        address payer,
        address borrower,
        uint repayAmount
    ) external virtual returns (uint);

    function liquidateBorrowAllowed(
        address mTokenBorrowed,
        address mTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount
    ) external view virtual returns (uint);

    function seizeAllowed(
        address mTokenCollateral,
        address mTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens
    ) external virtual returns (uint);

    function transferAllowed(
        address mToken,
        address src,
        address dst,
        uint transferTokens
    ) external virtual returns (uint);

    /*** Liquidity/Liquidation Calculations ***/

    function liquidateCalculateSeizeTokens(
        address mTokenBorrowed,
        address mTokenCollateral,
        uint repayAmount
    ) external view virtual returns (uint, uint);
}

// The hooks that were patched out of the comptroller to make room for the supply caps, if we need them
abstract contract ComptrollerInterfaceWithAllVerificationHooks is
    ComptrollerInterface
{
    function mintVerify(
        address mToken,
        address minter,
        uint mintAmount,
        uint mintTokens
    ) external virtual;

    // Included in ComptrollerInterface already
    // function redeemVerify(address mToken, address redeemer, uint redeemAmount, uint redeemTokens) virtual external;

    function borrowVerify(
        address mToken,
        address borrower,
        uint borrowAmount
    ) external virtual;

    function repayBorrowVerify(
        address mToken,
        address payer,
        address borrower,
        uint repayAmount,
        uint borrowerIndex
    ) external virtual;

    function liquidateBorrowVerify(
        address mTokenBorrowed,
        address mTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount,
        uint seizeTokens
    ) external virtual;

    function seizeVerify(
        address mTokenCollateral,
        address mTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens
    ) external virtual;

    function transferVerify(
        address mToken,
        address src,
        address dst,
        uint transferTokens
    ) external virtual;
}
pragma solidity 0.8.19;

/**
 * @title Moonwell's InterestRateModel Interface
 * @author Moonwell
 */
abstract contract InterestRateModel {
    /// @notice Indicator that this is an InterestRateModel contract (for inspection)
    bool public constant isInterestRateModel = true;

    /**
     * @notice Calculates the current borrow interest rate per timestamp
     * @param cash The total amount of cash the market has
     * @param borrows The total amount of borrows the market has outstanding
     * @param reserves The total amount of reserves the market has
     * @return The borrow rate per timestamp (as a percentage, and scaled by 1e18)
     */
    function getBorrowRate(
        uint cash,
        uint borrows,
        uint reserves
    ) external view virtual returns (uint);

    /**
     * @notice Calculates the current supply interest rate per timestamp
     * @param cash The total amount of cash the market has
     * @param borrows The total amount of borrows the market has outstanding
     * @param reserves The total amount of reserves the market has
     * @param reserveFactorMantissa The current reserve factor the market has
     * @return The supply rate per timestamp (as a percentage, and scaled by 1e18)
     */
    function getSupplyRate(
        uint cash,
        uint borrows,
        uint reserves,
        uint reserveFactorMantissa
    ) external view virtual returns (uint);
}
pragma solidity 0.8.19;

/**
 * @title EIP20NonStandardInterface
 * @dev Version of ERC20 with no return values for `transfer` and `transferFrom`
 *  See https://medium.com/coinmonks/missing-return-value-bug-at-least-130-tokens-affected-d67bf08521ca
 */
interface EIP20NonStandardInterface {
    /**
     * @notice Get the total number of tokens in circulation
     * @return The supply of tokens
     */
    function totalSupply() external view returns (uint256);

    /**
     * @notice Gets the balance of the specified address
     * @param owner The address from which the balance will be retrieved
     * @return balance The balance
     */
    function balanceOf(address owner) external view returns (uint256 balance);

    ///
    /// !!!!!!!!!!!!!!
    /// !!! NOTICE !!! `transfer` does not return a value, in violation of the ERC-20 specification
    /// !!!!!!!!!!!!!!
    ///

    /**
     * @notice Transfer `amount` tokens from `msg.sender` to `dst`
     * @param dst The address of the destination account
     * @param amount The number of tokens to transfer
     */
    function transfer(address dst, uint256 amount) external;

    ///
    /// !!!!!!!!!!!!!!
    /// !!! NOTICE !!! `transferFrom` does not return a value, in violation of the ERC-20 specification
    /// !!!!!!!!!!!!!!
    ///

    /**
     * @notice Transfer `amount` tokens from `src` to `dst`
     * @param src The address of the source account
     * @param dst The address of the destination account
     * @param amount The number of tokens to transfer
     */
    function transferFrom(address src, address dst, uint256 amount) external;

    /**
     * @notice Approve `spender` to transfer up to `amount` from `src`
     * @dev This will overwrite the approval amount for `spender`
     *  and is subject to issues noted [here](https://eips.ethereum.org/EIPS/eip-20#approve)
     * @param spender The address of the account which may transfer tokens
     * @param amount The number of tokens that are approved
     * @return success Whether or not the approval succeeded
     */
    function approve(
        address spender,
        uint256 amount
    ) external returns (bool success);

    /**
     * @notice Get the current allowance from `owner` for `spender`
     * @param owner The address of the account which owns the tokens to be spent
     * @param spender The address of the account which may transfer tokens
     * @return remaining The number of tokens allowed to be spent
     */
    function allowance(
        address owner,
        address spender
    ) external view returns (uint256 remaining);

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 amount
    );
}
pragma solidity 0.8.19;

contract ComptrollerErrorReporter {
    enum Error {
        NO_ERROR,
        UNAUTHORIZED,
        COMPTROLLER_MISMATCH,
        INSUFFICIENT_SHORTFALL,
        INSUFFICIENT_LIQUIDITY,
        INVALID_CLOSE_FACTOR,
        INVALID_COLLATERAL_FACTOR,
        INVALID_LIQUIDATION_INCENTIVE,
        MARKET_NOT_ENTERED, // no longer possible
        MARKET_NOT_LISTED,
        MARKET_ALREADY_LISTED,
        MATH_ERROR,
        NONZERO_BORROW_BALANCE,
        PRICE_ERROR,
        REJECTION,
        SNAPSHOT_ERROR,
        TOO_MANY_ASSETS,
        TOO_MUCH_REPAY
    }

    enum FailureInfo {
        ACCEPT_ADMIN_PENDING_ADMIN_CHECK,
        ACCEPT_PENDING_IMPLEMENTATION_ADDRESS_CHECK,
        EXIT_MARKET_BALANCE_OWED,
        EXIT_MARKET_REJECTION,
        SET_CLOSE_FACTOR_OWNER_CHECK,
        SET_CLOSE_FACTOR_VALIDATION,
        SET_COLLATERAL_FACTOR_OWNER_CHECK,
        SET_COLLATERAL_FACTOR_NO_EXISTS,
        SET_COLLATERAL_FACTOR_VALIDATION,
        SET_COLLATERAL_FACTOR_WITHOUT_PRICE,
        SET_IMPLEMENTATION_OWNER_CHECK,
        SET_LIQUIDATION_INCENTIVE_OWNER_CHECK,
        SET_LIQUIDATION_INCENTIVE_VALIDATION,
        SET_MAX_ASSETS_OWNER_CHECK,
        SET_PENDING_ADMIN_OWNER_CHECK,
        SET_PENDING_IMPLEMENTATION_OWNER_CHECK,
        SET_PRICE_ORACLE_OWNER_CHECK,
        SUPPORT_MARKET_EXISTS,
        SUPPORT_MARKET_OWNER_CHECK,
        SET_PAUSE_GUARDIAN_OWNER_CHECK,
        SET_GAS_AMOUNT_OWNER_CHECK
    }

    /**
     * @dev `error` corresponds to enum Error; `info` corresponds to enum FailureInfo, and `detail` is an arbitrary
     * contract-specific code that enables us to report opaque error codes from upgradeable contracts.
     **/
    event Failure(uint error, uint info, uint detail);

    /**
     * @dev use this when reporting a known error from the money market or a non-upgradeable collaborator
     */
    function fail(Error err, FailureInfo info) internal returns (uint) {
        emit Failure(uint(err), uint(info), 0);

        return uint(err);
    }

    /**
     * @dev use this when reporting an opaque error from an upgradeable collaborator contract
     */
    function failOpaque(
        Error err,
        FailureInfo info,
        uint opaqueError
    ) internal returns (uint) {
        emit Failure(uint(err), uint(info), opaqueError);

        return uint(err);
    }
}

contract TokenErrorReporter {
    enum Error {
        NO_ERROR,
        UNAUTHORIZED,
        BAD_INPUT,
        COMPTROLLER_REJECTION,
        COMPTROLLER_CALCULATION_ERROR,
        INTEREST_RATE_MODEL_ERROR,
        INVALID_ACCOUNT_PAIR,
        INVALID_CLOSE_AMOUNT_REQUESTED,
        INVALID_COLLATERAL_FACTOR,
        MATH_ERROR,
        MARKET_NOT_FRESH,
        MARKET_NOT_LISTED,
        TOKEN_INSUFFICIENT_ALLOWANCE,
        TOKEN_INSUFFICIENT_BALANCE,
        TOKEN_INSUFFICIENT_CASH,
        TOKEN_TRANSFER_IN_FAILED,
        TOKEN_TRANSFER_OUT_FAILED
    }

    /*
     * Note: FailureInfo (but not Error) is kept in alphabetical order
     *       This is because FailureInfo grows significantly faster, and
     *       the order of Error has some meaning, while the order of FailureInfo
     *       is entirely arbitrary.
     */
    enum FailureInfo {
        ACCEPT_ADMIN_PENDING_ADMIN_CHECK,
        ACCRUE_INTEREST_ACCUMULATED_INTEREST_CALCULATION_FAILED,
        ACCRUE_INTEREST_BORROW_RATE_CALCULATION_FAILED,
        ACCRUE_INTEREST_NEW_BORROW_INDEX_CALCULATION_FAILED,
        ACCRUE_INTEREST_NEW_TOTAL_BORROWS_CALCULATION_FAILED,
        ACCRUE_INTEREST_NEW_TOTAL_RESERVES_CALCULATION_FAILED,
        ACCRUE_INTEREST_SIMPLE_INTEREST_FACTOR_CALCULATION_FAILED,
        BORROW_ACCUMULATED_BALANCE_CALCULATION_FAILED,
        BORROW_ACCRUE_INTEREST_FAILED,
        BORROW_CASH_NOT_AVAILABLE,
        BORROW_FRESHNESS_CHECK,
        BORROW_NEW_TOTAL_BALANCE_CALCULATION_FAILED,
        BORROW_NEW_ACCOUNT_BORROW_BALANCE_CALCULATION_FAILED,
        BORROW_MARKET_NOT_LISTED,
        BORROW_COMPTROLLER_REJECTION,
        LIQUIDATE_ACCRUE_BORROW_INTEREST_FAILED,
        LIQUIDATE_ACCRUE_COLLATERAL_INTEREST_FAILED,
        LIQUIDATE_COLLATERAL_FRESHNESS_CHECK,
        LIQUIDATE_COMPTROLLER_REJECTION,
        LIQUIDATE_COMPTROLLER_CALCULATE_AMOUNT_SEIZE_FAILED,
        LIQUIDATE_CLOSE_AMOUNT_IS_UINT_MAX,
        LIQUIDATE_CLOSE_AMOUNT_IS_ZERO,
        LIQUIDATE_FRESHNESS_CHECK,
        LIQUIDATE_LIQUIDATOR_IS_BORROWER,
        LIQUIDATE_REPAY_BORROW_FRESH_FAILED,
        LIQUIDATE_SEIZE_BALANCE_INCREMENT_FAILED,
        LIQUIDATE_SEIZE_BALANCE_DECREMENT_FAILED,
        LIQUIDATE_SEIZE_COMPTROLLER_REJECTION,
        LIQUIDATE_SEIZE_LIQUIDATOR_IS_BORROWER,
        LIQUIDATE_SEIZE_TOO_MUCH,
        MINT_ACCRUE_INTEREST_FAILED,
        MINT_COMPTROLLER_REJECTION,
        MINT_EXCHANGE_CALCULATION_FAILED,
        MINT_EXCHANGE_RATE_READ_FAILED,
        MINT_FRESHNESS_CHECK,
        MINT_NEW_ACCOUNT_BALANCE_CALCULATION_FAILED,
        MINT_NEW_TOTAL_SUPPLY_CALCULATION_FAILED,
        MINT_TRANSFER_IN_FAILED,
        MINT_TRANSFER_IN_NOT_POSSIBLE,
        REDEEM_ACCRUE_INTEREST_FAILED,
        REDEEM_COMPTROLLER_REJECTION,
        REDEEM_EXCHANGE_TOKENS_CALCULATION_FAILED,
        REDEEM_EXCHANGE_AMOUNT_CALCULATION_FAILED,
        REDEEM_EXCHANGE_RATE_READ_FAILED,
        REDEEM_FRESHNESS_CHECK,
        REDEEM_NEW_ACCOUNT_BALANCE_CALCULATION_FAILED,
        REDEEM_NEW_TOTAL_SUPPLY_CALCULATION_FAILED,
        REDEEM_TRANSFER_OUT_NOT_POSSIBLE,
        REDUCE_RESERVES_ACCRUE_INTEREST_FAILED,
        REDUCE_RESERVES_ADMIN_CHECK,
        REDUCE_RESERVES_CASH_NOT_AVAILABLE,
        REDUCE_RESERVES_FRESH_CHECK,
        REDUCE_RESERVES_VALIDATION,
        REPAY_BEHALF_ACCRUE_INTEREST_FAILED,
        REPAY_BORROW_ACCRUE_INTEREST_FAILED,
        REPAY_BORROW_ACCUMULATED_BALANCE_CALCULATION_FAILED,
        REPAY_BORROW_COMPTROLLER_REJECTION,
        REPAY_BORROW_FRESHNESS_CHECK,
        REPAY_BORROW_NEW_ACCOUNT_BORROW_BALANCE_CALCULATION_FAILED,
        REPAY_BORROW_NEW_TOTAL_BALANCE_CALCULATION_FAILED,
        REPAY_BORROW_TRANSFER_IN_NOT_POSSIBLE,
        SET_COLLATERAL_FACTOR_OWNER_CHECK,
        SET_COLLATERAL_FACTOR_VALIDATION,
        SET_COMPTROLLER_OWNER_CHECK,
        SET_INTEREST_RATE_MODEL_ACCRUE_INTEREST_FAILED,
        SET_INTEREST_RATE_MODEL_FRESH_CHECK,
        SET_INTEREST_RATE_MODEL_OWNER_CHECK,
        SET_MAX_ASSETS_OWNER_CHECK,
        SET_ORACLE_MARKET_NOT_LISTED,
        SET_PENDING_ADMIN_OWNER_CHECK,
        SET_RESERVE_FACTOR_ACCRUE_INTEREST_FAILED,
        SET_RESERVE_FACTOR_ADMIN_CHECK,
        SET_RESERVE_FACTOR_FRESH_CHECK,
        SET_RESERVE_FACTOR_BOUNDS_CHECK,
        TRANSFER_COMPTROLLER_REJECTION,
        TRANSFER_NOT_ALLOWED,
        TRANSFER_NOT_ENOUGH,
        TRANSFER_TOO_MUCH,
        ADD_RESERVES_ACCRUE_INTEREST_FAILED,
        ADD_RESERVES_FRESH_CHECK,
        ADD_RESERVES_TRANSFER_IN_NOT_POSSIBLE,
        SET_PROTOCOL_SEIZE_SHARE_ACCRUE_INTEREST_FAILED,
        SET_PROTOCOL_SEIZE_SHARE_OWNER_CHECK,
        SET_PROTOCOL_SEIZE_SHARE_FRESH_CHECK
    }

    /**
     * @dev `error` corresponds to enum Error; `info` corresponds to enum FailureInfo, and `detail` is an arbitrary
     * contract-specific code that enables us to report opaque error codes from upgradeable contracts.
     **/
    event Failure(uint error, uint info, uint detail);

    /**
     * @dev use this when reporting a known error from the money market or a non-upgradeable collaborator
     */
    function fail(Error err, FailureInfo info) internal returns (uint) {
        emit Failure(uint(err), uint(info), 0);

        return uint(err);
    }

    /**
     * @dev use this when reporting an opaque error from an upgradeable collaborator contract
     */
    function failOpaque(
        Error err,
        FailureInfo info,
        uint opaqueError
    ) internal returns (uint) {
        emit Failure(uint(err), uint(info), opaqueError);

        return uint(err);
    }
}
