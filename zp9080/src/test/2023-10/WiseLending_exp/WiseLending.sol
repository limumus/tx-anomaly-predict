pragma solidity =0.8.21;

/**
 * @author Christoph Krpoun
 * @author Ren&#233; Hochmuth
 * @author Vitally Marinchenko
 */

import "./PoolManager.sol";

/**
 * @dev WISE lending is an automated lending platform on which users can collateralize
 * their assets and borrow tokens against them.
 *
 * Users need to pay borrow rates for debt tokens, which are reflected in a borrow APY for
 * each asset type (pool). This borrow rate is variable over time and determined through the
 * utilization of the pool. The bounding curve is a family of different bonding curves adjusted
 * automatically by LASA (Lending Automated Scaling Algorithm). For more information, see:
 * [https://wisesoft.gitbook.io/wise/wise-lending-protocol/lasa-ai]
 *
 * In addition to normal deposit, withdraw, borrow, and payback functions, there are other
 * interacting modes:
 *
 * - Solely deposit and withdraw allows the user to keep their funds private, enabling
 *    them to withdraw even when the pools are borrowed empty.
 *
 * - Aave pools  allow for maximal capital efficiency by earning aave supply APY for not
 *   borrowed funds.
 *
 * - Special curve pools nside beefy farms can be used as collateral, opening up new usage
 *   possibilities for these asset types.
 *
 * - Users can pay back their borrow with lending shares of the same asset type, making it
 *   easier to manage their positions.
 *
 * - Users save their collaterals and borrows inside a position NFT, making it possible
 *   to trade their whole positions or use them in second-layer contracts
 *   (e.g., spot trading with PTP NFT trading platforms).
 */

contract WiseLending is PoolManager {

    /**
     * @dev Standard receive functions forwarding
     * directly send ETH to the master address.
     */
    receive()
        external
        payable
    {
        if (msg.sender == WETH_ADDRESS) {
            return;
        }

        payable(master).transfer(
            msg.value
        );
    }

    /**
     * @dev Runs the LASA algorithm known as
     * Lending Automated Scaling Algorithm
     * and updates pool data based on token
     */
    modifier syncPool(
        address _poolToken
    ) {
        _syncPoolBeforeCodeExecution(
            _poolToken
        );
        _;
        _syncPoolAfterCodeExecution(
            _poolToken
        );
    }

    constructor(
        address _master,
        address _wiseOracleHubAddress,
        address _nftContract,
        address _wethContract
    )
        WiseLendingDeclaration(
            _master,
            _wiseOracleHubAddress,
            _nftContract,
            _wethContract
        )
    {}

    /**
     * @dev First part of pool sync updating pseudo
     * amounts. Is skipped when powerFarms or aaveHub
     * is calling the function.
     */
    function _syncPoolBeforeCodeExecution(
        address _poolToken
    )
        private
    {
        if (_byPassCase(msg.sender) == true) {
            return;
        }

        _preparePool(
            _poolToken
        );
    }

    /**
     * @dev Second part of pool sync updating
     * the borrow rate of the pool.
     */
    function _syncPoolAfterCodeExecution(
        address _poolToken
    )
        private
    {
        _newBorrowRate(
            _poolToken
        );
    }

    /**
     * @dev Allows to give permission for onBehalf function
     * execution, allowing 3rd party to perform actions such as
     * borrowOnBehalf and withdrawOnBehalf with amount limit
     */
    function approve(
        address _spender,
        address _poolToken,
        uint256 _amount
    )
        external
    {
        allowance[msg.sender][_poolToken][_spender] = _amount;

        emit Approve(
            _spender,
            _poolToken,
            msg.sender,
            _amount,
            block.timestamp
        );
    }

    /**
     * @dev Enables _poolToken to be used as a collateral.
     */
    function collateralizeDeposit(
        uint256 _nftId,
        address _poolToken
    )
        external
        syncPool(_poolToken)
    {
        WISE_SECURITY.checksCollateralizeDeposit(
            _nftId,
            msg.sender,
            _poolToken
        );

        userLendingData[_nftId][_poolToken].deCollteralized = false;
    }

    /**
     * @dev Disables _poolToken to be used as a collateral.
     */
    function deCollateralizeDeposit(
        uint256 _nftId,
        address _poolToken
    )
        external
        syncPool(_poolToken)
    {
        WISE_SECURITY.checkOwnerPosition(
            _nftId,
            msg.sender
        );

        _prepareAssociatedTokens(
            _nftId,
            _poolToken
        );

        userLendingData[_nftId][_poolToken].deCollteralized = true;

        WISE_SECURITY.checksDecollateralizeDeposit(
            _nftId,
            _poolToken
        );
    }

    // --------------- Deposit Functions -------------

    /**
     * @dev Allows to supply funds using ETH.
     * Without converting to WETH, use ETH directly.
     */
    function depositExactAmountETH(
        uint256 _nftId
    )
        external
        payable
        syncPool(WETH_ADDRESS)
        returns (uint256)
    {
        return _depositExactAmountETH(
            _nftId
        );
    }

    function _depositExactAmountETH(
        uint256 _nftId
    )
        internal
        returns (uint256)
    {
        uint256 shareAmount = calculateLendingShares(
            WETH_ADDRESS,
            msg.value
        );

        _handleDeposit(
            msg.sender,
            _nftId,
            WETH_ADDRESS,
            msg.value,
            shareAmount
        );

        _wrapETH(
            msg.value
        );

        return shareAmount;
    }

    /**
     * @dev Allows to supply funds using ETH.
     * Without converting to WETH, use ETH directly,
     * also mints position to avoid extra transaction.
     */
    function depositExactAmountETHMint()
        external
        payable
        returns (uint256)
    {
        return _depositExactAmountETH(
            _reservePosition()
        );
    }

    /**
     * @dev Allows to supply _poolToken and user
     * can decide if _poolToken should be collateralized,
     * also mints position to avoid extra transaction.
     */
    function depositExactAmountMint(
        address _poolToken,
        uint256 _amount
    )
        external
        returns (uint256)
    {
        return depositExactAmount(
            _reservePosition(),
            _poolToken,
            _amount
        );
    }

    /**
     * @dev Allows to supply _poolToken and user
     * can decide if _poolToken should be collateralized.
     */
    function depositExactAmount(
        uint256 _nftId,
        address _poolToken,
        uint256 _amount
    )
        public
        syncPool(_poolToken)
        returns (uint256)
    {
        uint256 shareAmount = calculateLendingShares(
            _poolToken,
            _amount
        );

        _handleDeposit(
            msg.sender,
            _nftId,
            _poolToken,
            _amount,
            shareAmount
        );

        _safeTransferFrom(
            _poolToken,
            msg.sender,
            address(this),
            _amount
        );

        return shareAmount;
    }

    /**
     * @dev Allows to supply funds using ETH in solely mode,
     * which does not earn APY, but keeps the funds private.
     * Other users are restricted from borrowing these funds,
     * owner can always withdraw even if all funds are borrowed.
     * Also mints position to avoid extra transaction.
     */
    function solelyDepositETHMint()
        external
        payable
    {
        solelyDepositETH(
            _reservePosition()
        );
    }

    /**
     * @dev Allows to supply funds using ETH in solely mode,
     * which does not earn APY, but keeps the funds private.
     * Other users are restricted from borrowing these funds,
     * owner can always withdraw even if all funds are borrowed.
     */
    function solelyDepositETH(
        uint256 _nftId
    )
        public
        payable
        syncPool(WETH_ADDRESS)
    {
        _handleSolelyDeposit(
            msg.sender,
            _nftId,
            WETH_ADDRESS,
            msg.value
        );

        _wrapETH(
            msg.value
        );

        emit FundsSolelyDeposited(
            msg.sender,
            _nftId,
            WETH_ADDRESS,
            msg.value,
            block.timestamp
        );
    }

    /**
     * @dev Allows to supply funds using ERC20 in solely mode,
     * which does not earn APY, but keeps the funds private.
     * Other users are restricted from borrowing these funds,
     * owner can always withdraw even if all funds are borrowed.
     * Also mints position to avoid extra transaction.
     */
    function solelyDepositMint(
        address _poolToken,
        uint256 _amount
    )
        external
    {
        solelyDeposit(
            _reservePosition(),
            _poolToken,
            _amount
        );
    }

    /**
     * @dev Allows to supply funds using ERC20 in solely mode,
     * which does not earn APY, but keeps the funds private.
     * Other users are restricted from borrowing these funds,
     * owner can always withdraw even if all funds are borrowed.
     */
    function solelyDeposit(
        uint256 _nftId,
        address _poolToken,
        uint256 _amount
    )
        public
        syncPool(_poolToken)
    {
        _handleSolelyDeposit(
            msg.sender,
            _nftId,
            _poolToken,
            _amount
        );

        _safeTransferFrom(
            _poolToken,
            msg.sender,
            address(this),
            _amount
        );

        emit FundsSolelyDeposited(
            msg.sender,
            _nftId,
            _poolToken,
            _amount,
            block.timestamp
        );
    }

    // --------------- Withdraw Functions -------------

    /**
     * @dev Allows to withdraw publicly
     * deposited ETH funds using exact amount.
     */
    function withdrawExactAmountETH(
        uint256 _nftId,
        uint256 _amount
    )
        external
        syncPool(WETH_ADDRESS)
        returns (uint256)
    {
        uint256 withdrawShares = _preparationsWithdraw(
            _nftId,
            msg.sender,
            WETH_ADDRESS,
            _amount
        );

        _coreWithdrawToken(
            msg.sender,
            _nftId,
            WETH_ADDRESS,
            _amount,
            withdrawShares
        );

        _unwrapETH(
            _amount
        );

        payable(msg.sender).transfer(
            _amount
        );

        emit FundsWithdrawn(
            msg.sender,
            _nftId,
            WETH_ADDRESS,
            _amount,
            withdrawShares,
            block.timestamp
        );

        return withdrawShares;
    }

    /**
     * @dev Allows to withdraw publicly
     * deposited ETH funds using exact shares.
     */
    function withdrawExactSharesETH(
        uint256 _nftId,
        uint256 _shares
    )
        external
        syncPool(WETH_ADDRESS)
        returns (uint256)
    {
        WISE_SECURITY.checkOwnerPosition(
            _nftId,
            msg.sender
        );

        uint256 withdrawAmount = cashoutAmount(
            WETH_ADDRESS,
            _shares
        );

        _coreWithdrawToken(
            msg.sender,
            _nftId,
            WETH_ADDRESS,
            withdrawAmount,
            _shares
        );

        _unwrapETH(
            withdrawAmount
        );

        payable(msg.sender).transfer(
            withdrawAmount
        );

        emit FundsWithdrawn(
            msg.sender,
            _nftId,
            WETH_ADDRESS,
            withdrawAmount,
            _shares,
            block.timestamp
        );

        return withdrawAmount;
    }

    /**
     * @dev Allows to withdraw publicly
     * deposited ERC20 funds using exact amount.
     */
    function withdrawExactAmount(
        uint256 _nftId,
        address _poolToken,
        uint256 _withdrawAmount
    )
        external
        syncPool(_poolToken)
        returns (uint256)
    {
        uint256 withdrawShares = _preparationsWithdraw(
            _nftId,
            msg.sender,
            _poolToken,
            _withdrawAmount
        );

        _coreWithdrawToken(
            msg.sender,
            _nftId,
            _poolToken,
            _withdrawAmount,
            withdrawShares
        );

        _safeTransfer(
            _poolToken,
            msg.sender,
            _withdrawAmount
        );

        emit FundsWithdrawn(
            msg.sender,
            _nftId,
            _poolToken,
            _withdrawAmount,
            withdrawShares,
            block.timestamp
        );

        return withdrawShares;
    }

    /**
     * @dev Allows to withdraw privately
     * deposited ETH funds using input amount.
     */
    function solelyWithdrawETH(
        uint256 _nftId,
        uint256 withdrawAmount
    )
        external
        syncPool(WETH_ADDRESS)
    {
        WISE_SECURITY.checkOwnerPosition(
            _nftId,
            msg.sender
        );

        _coreSolelyWithdraw(
            msg.sender,
            _nftId,
            WETH_ADDRESS,
            withdrawAmount
        );

        _unwrapETH(
            withdrawAmount
        );

        payable(msg.sender).transfer(
            withdrawAmount
        );

        emit FundsSolelyWithdrawn(
            msg.sender,
            _nftId,
            WETH_ADDRESS,
            withdrawAmount,
            block.timestamp
        );
    }

    /**
     * @dev Allows to withdraw privately
     * deposited ERC20 funds using input amount.
     */
    function solelyWithdraw(
        uint256 _nftId,
        address _poolToken,
        uint256 _withdrawAmount
    )
        external
        syncPool(_poolToken)
    {
        WISE_SECURITY.checkOwnerPosition(
            _nftId,
            msg.sender
        );

        _coreSolelyWithdraw(
            msg.sender,
            _nftId,
            _poolToken,
            _withdrawAmount
        );

        _safeTransfer(
            _poolToken,
            msg.sender,
            _withdrawAmount
        );

        emit FundsSolelyWithdrawn(
            msg.sender,
            _nftId,
            _poolToken,
            _withdrawAmount,
            block.timestamp
        );
    }

    /**
     * @dev Allows to withdraw privately
     * deposited ERC20 on behalf of owner.
     * Requires approval by _nftId owner.
     */
    function solelyWithdrawOnBehalf(
        uint256 _nftId,
        address _poolToken,
        uint256 _withdrawAmount
    )
        external
        syncPool(_poolToken)
    {
        _reduceAllowance(
            _nftId,
            _poolToken,
            msg.sender,
            _withdrawAmount
        );

        _coreSolelyWithdraw(
            msg.sender,
            _nftId,
            _poolToken,
            _withdrawAmount
        );

        _safeTransfer(
            _poolToken,
            msg.sender,
            _withdrawAmount
        );

        emit FundsSolelyWithdrawnOnBehalf(
            msg.sender,
            _nftId,
            _poolToken,
            _withdrawAmount,
            block.timestamp
        );
    }

    /**
     * @dev Allows to withdraw privately
     * deposited ERC20 on behalf of owner.
     * Requires approval by _nftId owner.
     */
    function withdrawOnBehalfExactAmount(
        uint256 _nftId,
        address _poolToken,
        uint256 _withdrawAmount
    )
        external
        syncPool(_poolToken)
        returns (uint256)
    {
        _reduceAllowance(
            _nftId,
            _poolToken,
            msg.sender,
            _withdrawAmount
        );

        uint256 withdrawShares = calculateLendingShares(
            _poolToken,
            _withdrawAmount
        );

        _coreWithdrawToken(
            msg.sender,
            _nftId,
            _poolToken,
            _withdrawAmount,
            withdrawShares
        );

        _safeTransfer(
            _poolToken,
            msg.sender,
            _withdrawAmount
        );

        emit FundsWithdrawnOnBehalf(
            msg.sender,
            _nftId,
            _poolToken,
            _withdrawAmount,
            withdrawShares,
            block.timestamp
        );

        return withdrawShares;
    }

    /**
     * @dev Allows to withdraw ERC20
     * funds using shares as input value
     */
    function withdrawExactShares(
        uint256 _nftId,
        address _poolToken,
        uint256 _shares
    )
        external
        syncPool(_poolToken)
        returns (uint256)
    {
        WISE_SECURITY.checkOwnerPosition(
            _nftId,
            msg.sender
        );

        uint256 withdrawAmount = cashoutAmount(
            _poolToken,
            _shares
        );

        _coreWithdrawToken(
            msg.sender,
            _nftId,
            _poolToken,
            withdrawAmount,
            _shares
        );

        _safeTransfer(
            _poolToken,
            msg.sender,
            withdrawAmount
        );

        emit FundsWithdrawn(
            msg.sender,
            _nftId,
            _poolToken,
            withdrawAmount,
            _shares,
            block.timestamp
        );

        return withdrawAmount;
    }

    /**
     * @dev Withdraws ERC20 funds on behalf
     * of _nftId owner, requires approval.
     */
    function withdrawOnBehalfExactShares(
        uint256 _nftId,
        address _poolToken,
        uint256 _shares
    )
        external
        syncPool(_poolToken)
        returns (uint256)
    {
        uint256 withdrawAmount = cashoutAmount(
            _poolToken,
            _shares
        );

        _reduceAllowance(
            _nftId,
            _poolToken,
            msg.sender,
            withdrawAmount
        );

        _coreWithdrawToken(
            msg.sender,
            _nftId,
            _poolToken,
            withdrawAmount,
            _shares
        );

        _safeTransfer(
            _poolToken,
            msg.sender,
            withdrawAmount
        );

        emit FundsWithdrawnOnBehalf(
            msg.sender,
            _nftId,
            _poolToken,
            withdrawAmount,
            _shares,
            block.timestamp
        );

        return withdrawAmount;
    }

    // --------------- Borrow Functions -------------

    /**
     * @dev Allows to borrow ETH funds
     * Requires user to have collateral.
     */
    function borrowExactAmountETH(
        uint256 _nftId,
        uint256 _amount
    )
        external
        syncPool(WETH_ADDRESS)
        returns (uint256)
    {
        WISE_SECURITY.checkOwnerPosition(
            _nftId,
            msg.sender
        );

        uint256 shares = calculateBorrowShares(
            WETH_ADDRESS,
            _amount
        );

        _coreBorrowTokens(
            msg.sender,
            _nftId,
            WETH_ADDRESS,
            _amount,
            shares
        );

        _unwrapETH(
            _amount
        );

        payable(msg.sender).transfer(
            _amount
        );

        emit FundsBorrowed(
            msg.sender,
            _nftId,
            WETH_ADDRESS,
            _amount,
            shares,
            block.timestamp
        );

        return shares;
    }

    /**
     * @dev Allows to borrow ERC20 funds
     * Requires user to have collateral.
     */
    function borrowExactAmount(
        uint256 _nftId,
        address _poolToken,
        uint256 _amount
    )
        external
        syncPool(_poolToken)
        returns (uint256)
    {
        WISE_SECURITY.checkOwnerPosition(
            _nftId,
            msg.sender
        );

        uint256 shares = calculateBorrowShares(
            _poolToken,
            _amount
        );

        _coreBorrowTokens(
            msg.sender,
            _nftId,
            _poolToken,
            _amount,
            shares
        );

        _safeTransfer(
            _poolToken,
            msg.sender,
            _amount
        );

        emit FundsBorrowed(
            msg.sender,
            _nftId,
            _poolToken,
            _amount,
            shares,
            block.timestamp
        );

        return shares;
    }

    /**
     * @dev Allows to borrow ERC20 funds
     * on behalf of _nftId owner, if approved.
     */
    function borrowOnBehalfExactAmount(
        uint256 _nftId,
        address _poolToken,
        uint256 _amount
    )
        external
        syncPool(_poolToken)
        returns (uint256)
    {
        _reduceAllowance(
            _nftId,
            _poolToken,
            msg.sender,
            _amount
        );

        uint256 shares = calculateBorrowShares(
            _poolToken,
            _amount
        );

        _coreBorrowTokens(
            msg.sender,
            _nftId,
            _poolToken,
            _amount,
            shares
        );

        _safeTransfer(
            _poolToken,
            msg.sender,
            _amount
        );

        emit FundsBorrowedOnBehalf(
            msg.sender,
            _nftId,
            _poolToken,
            _amount,
            shares,
            block.timestamp
        );

        return shares;
    }

    // --------------- Payback Functions ------------

    /**
     * @dev Ability to payback ETH loans
     * by providing exact payback amount.
     */
    function paybackExactAmountETH(
        uint256 _nftId
    )
        external
        payable
        syncPool(WETH_ADDRESS)
        returns (uint256)
    {
        _checkPositionLocked(
            _nftId,
            msg.sender
        );

        uint256 maxBorrowShares = getPositionBorrowShares(
            _nftId,
            WETH_ADDRESS
        );

        uint256 maxPaybackAmount = paybackAmount(
            WETH_ADDRESS,
            maxBorrowShares
        );

        uint256 paybackShares = calculateBorrowShares(
            WETH_ADDRESS,
            msg.value
        );

        uint256 refundAmount;
        uint256 requiredAmount = msg.value;

        if (msg.value > maxPaybackAmount) {

            refundAmount = msg.value
                - maxPaybackAmount;

            requiredAmount = requiredAmount
                - refundAmount;

            paybackShares = maxBorrowShares;
        }

        _handlePayback(
            msg.sender,
            _nftId,
            WETH_ADDRESS,
            requiredAmount,
            paybackShares
        );

        _wrapETH(
            requiredAmount
        );

        if (refundAmount > 0) {
            payable(msg.sender).transfer(
                refundAmount
            );
        }

        return paybackShares;
    }

    /**
     * @dev Ability to payback ERC20 loans
     * by providing exact payback amount.
     */
    function paybackExactAmount(
        uint256 _nftId,
        address _poolToken,
        uint256 _amount
    )
        public
        syncPool(_poolToken)
        returns (uint256)
    {
        _checkPositionLocked(
            _nftId,
            msg.sender
        );

        uint256 paybackShares = calculateBorrowShares(
            _poolToken,
            _amount
        );

        _handlePayback(
            msg.sender,
            _nftId,
            _poolToken,
            _amount,
            paybackShares
        );

        _safeTransferFrom(
            _poolToken,
            msg.sender,
            address(this),
            _amount
        );

        return paybackShares;
    }

    /**
     * @dev Ability to payback ERC20 loans
     * by providing exact payback shares.
     */
    function paybackExactShares(
        uint256 _nftId,
        address _poolToken,
        uint256 _shares
    )
        public
        syncPool(_poolToken)
        returns (uint256)
    {
        _checkPositionLocked(
            _nftId,
            msg.sender
        );

        uint256 paybackAmount = paybackAmount(
            _poolToken,
            _shares
        );

        _handlePayback(
            msg.sender,
            _nftId,
            _poolToken,
            paybackAmount,
            _shares
        );

        _safeTransferFrom(
            _poolToken,
            msg.sender,
            address(this),
            paybackAmount
        );

        return paybackAmount;
    }

    /**
     * @dev Ability to payback ERC20 loans
     * by providing exact lending shares.
     */
    function paybackExactLendingShares(
        uint256 _nftIdCaller,
        uint256 _nftIdReceiver,
        address _poolToken,
        uint256 _lendingShares
    )
        public
        syncPool(_poolToken)
        returns (uint256)
    {
        _prepareAssociatedTokens(
            _nftIdCaller,
            _poolToken
        );

        uint256 paybackAmount = cashoutAmount(
            _poolToken,
            _lendingShares
        );

        WISE_SECURITY.checkPaybackLendingShares(
            _nftIdReceiver,
            _nftIdCaller,
            msg.sender,
            _poolToken,
            paybackAmount
        );

        _corePaybackLendingShares(
            _poolToken,
            paybackAmount,
            _lendingShares,
            _nftIdCaller,
            _nftIdReceiver
        );

        emit FundsReturnedWithLendingShares(
            msg.sender,
            _poolToken,
            _nftIdCaller,
            paybackAmount,
            _lendingShares,
            block.timestamp
        );

        if (getPositionBorrowShares(_nftIdReceiver, _poolToken) > 0) {
            return paybackAmount;
        }

        _removePositionData({
            _nftId: _nftIdReceiver,
            _poolToken: _poolToken,
            _getPositionTokenLength: getPositionBorrowTokenLength,
            _getPositionTokenByIndex: getPositionBorrowTokenByIndex,
            _deleteLastPositionData: _deleteLastPositionBorrowData,
            isLending: false
        });

        return paybackAmount;
    }

    // --------------- Liquidation Functions ------------

    /**
     * @dev Function to liquidate a postion which reaches
     * a debt ratio greater than 100%. The liquidator can choose
     * token to payback and receive. (Both can differ!). The
     * amount is in shares of the payback token. The liquidator
     * gets an incentive which is calculated inside the liquidation
     * logic.
     */
    function liquidatePartiallyFromTokens(
        uint256 _nftId,
        uint256 _nftIdLiquidator,
        address _paybackToken,
        address _receiveToken,
        uint256 _shareAmountToPay
    )
        external
        returns (uint256)
    {
        _preparationCollaterals(
            _nftId,
            ZERO_ADDRESS
        );

        _preparationBorrows(
            _nftId,
            ZERO_ADDRESS
        );

        _checkPositionLocked(
            _nftId,
            msg.sender
        );

        WISE_SECURITY.checksLiquidation(
            _nftId,
            _paybackToken,
            _shareAmountToPay
        );

        uint256 paybackAmount = paybackAmount(
            _paybackToken,
            _shareAmountToPay
        );

        return _coreLiquidation(
            _nftId,
            _nftIdLiquidator,
            msg.sender,
            msg.sender,
            _paybackToken,
            _receiveToken,
            paybackAmount,
            _shareAmountToPay,
            WISE_SECURITY.maxFeeUSD(),
            WISE_SECURITY.baseRewardLiquidation()
        );
    }

    /**
     * @dev Wrapper function for liqudaiton flow of
     * power farms.
     */
    function coreLiquidationIsolationPools(
        uint256 _nftId,
        uint256 _nftIdLiquidator,
        address _caller,
        address _receiver,
        address _paybackToken,
        address _receiveToken,
        uint256 _paybackAmount,
        uint256 _shareAmountToPay
    )
        external
        returns (uint256)
    {
        _onlyIsolationPool(
            msg.sender
        );

        return _coreLiquidation(
            _nftId,
            _nftIdLiquidator,
            _caller,
            _receiver,
            _paybackToken,
            _receiveToken,
            _paybackAmount,
            _shareAmountToPay,
            WISE_SECURITY.maxFeeFarmUSD(),
            WISE_SECURITY.baseRewardLiquidationFarm()
        );
    }

    /**
     * @dev Allows to sync pool manually
     * so that the pool is up to date.
     */
    function syncManually(
        address _poolToken
    )
        external
        syncPool(_poolToken)
    {
        emit PoolSynced(
            _poolToken,
            block.timestamp
        );
    }

    /**
     * @dev Registers position _nftId
     * for isolation pool functionality
     */
    function setRegistrationIsolationPool(
        uint256 _nftId,
        bool _registerState
    )
        external
    {
        _onlyIsolationPool(
            msg.sender
        );

        positionLocked[_nftId] = _registerState;

        emit RegisteredForIsolationPool(
            msg.sender,
            block.timestamp,
            _registerState
        );
    }

    /**
     * @dev Wrapper for isolation pool
     * check.
     */
    function _onlyIsolationPool(
        address _poolAddress
    )
        private
        view
    {
        if (veryfiedIsolationPool[_poolAddress] == false) {
            revert();
        }
    }
}
pragma solidity =0.8.21;

import "./WiseCore.sol";
import "./Babylonian.sol";

abstract contract PoolManager is WiseCore {

    struct CreatePool {
        bool allowBorrow;
        address poolToken;
        uint256 poolMulFactor;
        uint256 poolCollFactor;
        uint256 maxDepositAmount;
    }

    struct CurvePoolSettings {
        CurveSwapStructToken curveSecuritySwapsToken;
        CurveSwapStructData curveSecuritySwapsData;
    }

    function setParamsLASA(
        address _poolToken,
        uint256 _poolMulFactor,
        uint256 _upperBoundMaxRate,
        uint256 _lowerBoundMaxRate,
        bool _steppingDirection,
        bool _isFinal
    )
        external
        onlyMaster
    {
        if (parametersLocked[_poolToken] == true) {
            revert ParametersLocked();
        }

        parametersLocked[_poolToken] = _isFinal;
        algorithmData[_poolToken].increasePole = _steppingDirection;

        uint256 staticMinPole = _getMinPole(
            _poolMulFactor,
            _upperBoundMaxRate
        );

        uint256 staticMaxPole = _getMaxPole(
            _poolMulFactor,
            _lowerBoundMaxRate
        );

        uint256 staticDeltaPole = _getDeltaPole(
            staticMaxPole,
            staticMinPole
        );

        uint256 startValuePole = _getStartValue(
            staticMaxPole,
            staticMinPole
        );

        borrowRatesData[_poolToken] = BorrowRatesEntry({
            pole: startValuePole,
            deltaPole: staticDeltaPole,
            minPole: staticMinPole,
            maxPole: staticMaxPole,
            multiplicativeFactor: _poolMulFactor
        });

        algorithmData[_poolToken].bestPole = startValuePole;
        algorithmData[_poolToken].maxValue = lendingPoolData[_poolToken].totalDepositShares;
    }

    function setPoolParameters(
        address _poolToken,
        uint256 _collateralFactor,
        uint256 _maximumDeposit
    )
        external
        onlyMaster
    {
        if (_maximumDeposit > 0) {
            maxDepositValueToken[_poolToken] = _maximumDeposit;
        }

        if (_collateralFactor > 0) {
            lendingPoolData[_poolToken].collateralFactor = _collateralFactor;
        }

        if (_collateralFactor > PRECISION_FACTOR_E18) {
            revert ForbiddenValue();
        }
    }

    /**
     * @dev Allow to verify isolation pool.
     */
    function setVeryfiedIsolationPool(
        address _isolationPool,
        bool _state
    )
        external
        onlyMaster
    {
        veryfiedIsolationPool[_isolationPool] = _state;
    }

    function createPool(
        CreatePool memory _params
    )
        external
        onlyMaster
    {
        _createPool(
            _params
        );

    }

    function createCurvePool(
        CreatePool memory _params,
        CurvePoolSettings memory _settings
    )
        external
        onlyMaster
    {
        _createPool(
            _params
        );

        WISE_SECURITY.prepareCurvePools(
            _params.poolToken,
            _settings.curveSecuritySwapsData,
            _settings.curveSecuritySwapsToken
        );
    }

    function _createPool(
        CreatePool memory _params
    )
        private
    {
        if (timestampsPoolData[_params.poolToken].timeStamp > 0) {
            revert AlreadyCreated();
        }

        // Default boundary values for pool creation.
        uint256 LOWER_BOUND_MAX_RATE = 100 * PRECISION_FACTOR_E16;
        uint256 UPPER_BOUND_MAX_RATE = 300 * PRECISION_FACTOR_E16;

        // Calculating lower bound for the pole
        uint256 staticMinPole = _getMinPole(
            _params.poolMulFactor,
            UPPER_BOUND_MAX_RATE
        );

        // Calculating upper bound for the pole
        uint256 staticMaxPole = _getMaxPole(
            _params.poolMulFactor,
            LOWER_BOUND_MAX_RATE
        );

        // Calculating fraction for algorithm step
        uint256 staticDeltaPole = _getDeltaPole(
            staticMaxPole,
            staticMinPole
        );

        maxDepositValueToken[_params.poolToken] = _params.maxDepositAmount;

        FEE_MANAGER.addPoolTokenAddress(
            _params.poolToken
        );

        globalPoolData[_params.poolToken] = GlobalPoolEntry({
            totalPool: 0,
            utilization: 0,
            totalBareToken: 0,
            poolFee: 20 * PRECISION_FACTOR_E16
        });

        // Setting start value as mean of min and max value
        uint256 startValuePole = _getStartValue(
            staticMaxPole,
            staticMinPole
        );

        // Rates Pool Data
        borrowRatesData[_params.poolToken] = BorrowRatesEntry({
            pole: startValuePole,
            deltaPole: staticDeltaPole,
            minPole: staticMinPole,
            maxPole: staticMaxPole,
            multiplicativeFactor: _params.poolMulFactor
        });

        // Borrow Pool Data
        borrowPoolData[_params.poolToken] = BorrowPoolEntry({
            allowBorrow: _params.allowBorrow,
            pseudoTotalBorrowAmount: 1,
            totalBorrowShares: 1,
            borrowRate: 0
        });

        // Algorithm Pool Data
        algorithmData[_params.poolToken] = AlgorithmEntry({
            bestPole: startValuePole,
            maxValue: 0,
            previousValue: 0,
            increasePole: false
        });

        uint256 fetchBalance = IERC20(_params.poolToken).balanceOf(
            address(this)
        );

        if (fetchBalance > 0) {
            _safeTransfer(
                _params.poolToken,
                master,
                fetchBalance
            );
        }

        // Lending Pool Data
        lendingPoolData[_params.poolToken] = LendingPoolEntry({
            pseudoTotalPool: 1,
            totalDepositShares: 1,
            collateralFactor: _params.poolCollFactor
        });

        // Timestamp Pool Data
        timestampsPoolData[_params.poolToken] = TimestampsPoolEntry({
            timeStamp: block.timestamp,
            timeStampScaling: block.timestamp
        });
    }

    function _getMaxPole(
        uint256 _poolMulFactor,
        uint256 _lowerBoundMaxRate
    )
        private
        pure
        returns (uint256)
    {
        return PRECISION_FACTOR_E18 / 2
            + Babylonian.sqrt(PRECISION_FACTOR_E36 / 4
                + _poolMulFactor
                    * PRECISION_FACTOR_E36
                    / _lowerBoundMaxRate
            );
    }

    function _getMinPole(
        uint256 _poolMulFactor,
        uint256 _upperBoundMaxRate
    )
        private
        pure
        returns (uint256)
    {
        return PRECISION_FACTOR_E18 / 2
            + Babylonian.sqrt(PRECISION_FACTOR_E36 / 4
                + _poolMulFactor
                    * PRECISION_FACTOR_E36
                    / _upperBoundMaxRate
            );
    }

    function _getDeltaPole(
        uint256 _maxPole,
        uint256 _minPole
    )
        private
        pure
        returns (uint256)
    {
        return (_maxPole - _minPole) / NORMALISATION_FACTOR;
    }

    function _getStartValue(
        uint256 _maxPole,
        uint256 _minPole
    )
        private
        pure
        returns (uint256)
    {
        return (_maxPole + _minPole) / 2;
    }
}
pragma solidity =0.8.21;

library Babylonian {

    function sqrt(
        uint256 x
    )
        internal
        pure
        returns (uint256)
    {
        if (x == 0) return 0;

        uint256 xx = x;
        uint256 r = 1;
        if (xx >= 0x100000000000000000000000000000000) {
            xx >>= 128;
            r <<= 64;
        }
        if (xx >= 0x10000000000000000) {
            xx >>= 64;
            r <<= 32;
        }
        if (xx >= 0x100000000) {
            xx >>= 32;
            r <<= 16;
        }
        if (xx >= 0x10000) {
            xx >>= 16;
            r <<= 8;
        }
        if (xx >= 0x100) {
            xx >>= 8;
            r <<= 4;
        }
        if (xx >= 0x10) {
            xx >>= 4;
            r <<= 2;
        }
        if (xx >= 0x8) {
            r <<= 1;
        }
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;

        uint256 r1 = x / r;
        return (r < r1 ? r : r1);
    }
}
pragma solidity =0.8.21;

import "./MainHelper.sol";

abstract contract WiseCore is MainHelper {

    /**
     * @dev Wrapper function combining pool
     * preparations for borrow and collaterals.
     * Bypassed when called by powerFarms
     * or aaveHub.
     */
    function _prepareAssociatedTokens(
        uint256 _nftId,
        address _poolToken
    )
        internal
    {
        if (_byPassCase(msg.sender) == true) {
            return;
        }

        _preparationCollaterals(
            _nftId,
            _poolToken
        );

        _preparationBorrows(
            _nftId,
            _poolToken
        );
    }

    /**
     * @dev Core function combining withdraw
     * logic and security checks.
     */
    function _coreWithdrawToken(
        address _caller,
        uint256 _nftId,
        address _poolToken,
        uint256 _amount,
        uint256 _shares
    )
        internal
    {
        _prepareAssociatedTokens(
            _nftId,
            _poolToken
        );

        WISE_SECURITY.checksWithdraw(
            _nftId,
            _caller,
            _poolToken,
            _amount
        );

        _coreWithdrawBare(
            _nftId,
            _poolToken,
            _amount,
            _shares
        );
    }

    /**
     * @dev Internal function combining payback
     * logic and emit of an event.
     */
    function _handlePayback(
        address _caller,
        uint256 _nftId,
        address _poolToken,
        uint256 _amount,
        uint256 _shares
    )
        internal
    {
        _corePayback(
            _nftId,
            _poolToken,
            _amount,
            _shares
        );

        emit FundsReturned(
            _caller,
            _poolToken,
            _nftId,
            _amount,
            _shares,
            block.timestamp
        );
    }

    /**
     * @dev Internal function combining deposit
     * logic, security checks and event emit.
     */
    function _handleDeposit(
        address _caller,
        uint256 _nftId,
        address _poolToken,
        uint256 _amount,
        uint256 _shareAmount
    )
        internal
    {
        _checkDeposit(
            _nftId,
            _caller,
            _poolToken,
            _amount
        );

        _increasePositionLendingDeposit(
            _nftId,
            _poolToken,
            _shareAmount
        );

        _updatePoolStorage(
            _poolToken,
            _amount,
            _shareAmount,
            _increaseTotalPool,
            _increasePseudoTotalPool,
            _increaseTotalDepositShares
        );

        _addPositionTokenData(
            _nftId,
            _poolToken,
            hashMapPositionLending,
            positionLendingTokenData
        );

        emit FundsDeposited(
            _caller,
            _nftId,
            _poolToken,
            _amount,
            _shareAmount,
            block.timestamp
        );
    }

    /**
     * @dev External wrapper for
     * {_checkPositionLocked}.
     */
    function checkPositionLocked(
        uint256 _nftId,
        address _caller
    )
        external
        view
    {
        _checkPositionLocked(
            _nftId,
            _caller
        );
    }

    /**
     * @dev Checks if a postion is locked
     * for powerFarms. Get skipped when
     * aaveHub or a powerFarm itself is
     * the {msg.sender}.
     */
    function _checkPositionLocked(
        uint256 _nftId,
        address _caller
    )
        internal
        view
    {
        if (_byPassCase(_caller) == true) {
            return;
        }

        if (positionLocked[_nftId] == false) {
            return;
        }

        revert PositionLocked();
    }

    /**
     * @dev External wrapper for
     * {_checkDeposit}.
     */
    function checkDeposit(
        uint256 _nftId,
        address _caller,
        address _poolToken,
        uint256 _amount
    )
        external
        view
    {
        _checkDeposit(
            _nftId,
            _caller,
            _poolToken,
            _amount
        );
    }

    /**
     * @dev Internal function including
     * security checks for deposit logic.
     */
    function _checkDeposit(
        uint256 _nftId,
        address _caller,
        address _poolToken,
        uint256 _amount
    )
        internal
        view
    {
        _checkPositionLocked(
            _nftId,
            _caller
        );

        if (WISE_ORACLE.chainLinkIsDead(_poolToken) == true) {
            revert();
        }

        _checkMaxDepositValue(
            _poolToken,
            _amount
        );
    }

    /**
     * @dev Internal function checking
     * if the deposit amount for the
     * pool token is reached.
     */
    function _checkMaxDepositValue(
        address _poolToken,
        uint256 _amount
    )
        internal
        view
    {
        bool state = maxDepositValueToken[_poolToken]
            < getTotalBareToken(_poolToken)
            + getPseudoTotalPool(_poolToken)
            + _amount;

        if (state == true) {
            revert DepositCapReached();
        }
    }

    /**
     * @dev Core function combining
     * supply logic with security
     * checks for solely deposit.
     */
    function _handleSolelyDeposit(
        address _caller,
        uint256 _nftId,
        address _poolToken,
        uint256 _amount
    )
        internal
    {
        _checkDeposit(
            _nftId,
            _caller,
            _poolToken,
            _amount
        );

        _increaseMappingValue(
            positionPureCollateralAmount,
            _nftId,
            _poolToken,
            _amount
        );

        _increaseTotalBareToken(
            _poolToken,
            _amount
        );

        _addPositionTokenData(
            _nftId,
            _poolToken,
            hashMapPositionLending,
            positionLendingTokenData
        );
    }

    /**
     * @dev Low level core function combining
     * pure withdraw math (without security
     * checks).
     */
    function _coreWithdrawBare(
        uint256 _nftId,
        address _poolToken,
        uint256 _amount,
        uint256 _shares
    )
        internal
    {
        _updatePoolStorage(
            _poolToken,
            _amount,
            _shares,
            _decreaseTotalPool,
            _decreasePseudoTotalPool,
            _decreaseTotalDepositShares
        );

        _decreaseLendingShares(
            _nftId,
            _poolToken,
            _shares
        );

        _removeEmptyLendingData(
            _nftId,
            _poolToken
        );
    }

    /**
     * @dev Core function combining borrow
     * logic with security checks.
     */
    function _coreBorrowTokens(
        address _caller,
        uint256 _nftId,
        address _poolToken,
        uint256 _amount,
        uint256 _shares
    )
        internal
    {
        _prepareAssociatedTokens(
            _nftId,
            _poolToken
        );

        WISE_SECURITY.checksBorrow(
            _nftId,
            _caller,
            _poolToken,
            _amount
        );

        _updatePoolStorage(
            _poolToken,
            _amount,
            _shares,
            _increasePseudoTotalBorrowAmount,
            _decreaseTotalPool,
            _increaseTotalBorrowShares
        );

        _increaseMappingValue(
            userBorrowShares,
            _nftId,
            _poolToken,
            _shares
        );

        _addPositionTokenData(
            _nftId,
            _poolToken,
            hashMapPositionBorrow,
            positionBorrowTokenData
        );
    }

    /**
     * @dev Core function combining payback
     * logic with security checks.
     */
    function _corePayback(
        uint256 _nftId,
        address _poolToken,
        uint256 _amount,
        uint256 _shares
    )
        internal
    {
        _updatePoolStorage(
            _poolToken,
            _amount,
            _shares,
            _increaseTotalPool,
            _decreasePseudoTotalBorrowAmount,
            _decreaseTotalBorrowShares
        );

        _decreasePositionMappingValue(
            userBorrowShares,
            _nftId,
            _poolToken,
            _shares
        );

        if (getPositionBorrowShares(_nftId, _poolToken) > 0) {
            return;
        }

        _removePositionData({
            _nftId: _nftId,
            _poolToken: _poolToken,
            _getPositionTokenLength: getPositionBorrowTokenLength,
            _getPositionTokenByIndex: getPositionBorrowTokenByIndex,
            _deleteLastPositionData: _deleteLastPositionBorrowData,
            isLending: false
        });
    }

    /**
     * @dev External wrapper for
     * {_corePayback} logic callable
     * by feeMananger.
     */
    function corePaybackFeeManager(
        address _poolToken,
        uint256 _nftId,
        uint256 _amount,
        uint256 _shares
    )
        external
        onlyFeeManager
    {
        _corePayback(
            _nftId,
            _poolToken,
            _amount,
            _shares
        );
    }

    /**
     * @dev Core function combining
     * withdraw logic for solely
     * withdraw with security checks.
     */
    function _coreSolelyWithdraw(
        address _caller,
        uint256 _nftId,
        address _poolToken,
        uint256 _amount
    )
        internal
    {
        WISE_SECURITY.checksSolelyWithdraw(
            _nftId,
            _caller,
            _poolToken,
            _amount
        );

        _solelyWithdrawBase(
            _poolToken,
            _nftId,
            _amount
        );
    }

    /**
     * @dev Low level core function with
     * withdraw logic for solely
     * withdraw. (Without security checks)
     */
    function _solelyWithdrawBase(
        address _poolToken,
        uint256 _nftId,
        uint256 _amount
    )
        internal
    {
        _decreasePositionMappingValue(
            positionPureCollateralAmount,
            _nftId,
            _poolToken,
            _amount
        );

        _decreaseTotalBareToken(
            _poolToken,
            _amount
        );

        _removeEmptyLendingData(
            _nftId,
            _poolToken
        );
    }

    /**
     * @dev Core function combining payback
     * logic for paying back borrow with
     * lending shares of same asset type.
     */
    function _corePaybackLendingShares(
        address _poolToken,
        uint256 _tokenAmount,
        uint256 _lendingShares,
        uint256 _nftIdCaller,
        uint256 _nftIdReceiver
    )
        internal
    {
        uint256 borrowShareEquivalent = _borrowShareEquivalent(
            _poolToken,
            _lendingShares
        );

        _updatePoolStorage(
            _poolToken,
            _tokenAmount,
            _lendingShares,
            _decreasePseudoTotalPool,
            _decreasePseudoTotalBorrowAmount,
            _decreaseTotalDepositShares
        );

        _decreaseLendingShares(
            _nftIdCaller,
            _poolToken,
            _lendingShares
        );

        _decreaseTotalBorrowShares(
            _poolToken,
            borrowShareEquivalent
        );

        _decreasePositionMappingValue(
            userBorrowShares,
            _nftIdReceiver,
            _poolToken,
            borrowShareEquivalent
        );
    }

    /**
     * @dev Internal math function for liquidation logic
     * caluclating amount to withdraw from pure
     * collateral for liquidation.
     */
    function _withdrawPureCollateralLiquidation(
        uint256 _nftId,
        address _poolToken,
        uint256 _percentLiquidation
    )
        internal
        returns (uint256 transfereAmount)
    {
        transfereAmount = _percentLiquidation
            * positionPureCollateralAmount[_nftId][_poolToken]
            / PRECISION_FACTOR_E18;

        _decreasePositionMappingValue(
            positionPureCollateralAmount,
            _nftId,
            _poolToken,
            transfereAmount
        );

        _decreaseTotalBareToken(
            _poolToken,
            transfereAmount
        );
    }

    /**
     * @dev Internal math function for liquidation logic
     * which checks if pool has enough token to pay out
     * liquidator. If not, liquidator get corresponding
     * shares for later withdraw.
     */
    function _withdrawOrAllocateSharesLiquidation(
        uint256 _nftId,
        uint256 _nftIdLiquidator,
        address _poolToken,
        uint256 _percantageWishCollat
    )
        internal
        returns (uint256)
    {
        uint256 cashoutShares = _percantageWishCollat
            * getPositionLendingShares(
                _nftId,
                _poolToken
            ) / PRECISION_FACTOR_E18;

        uint256 cashoutAmount = cashoutAmount(
            _poolToken,
            cashoutShares
        );

        uint256 totalPoolToken = getTotalPool(
            _poolToken
        );

        if (cashoutAmount <= totalPoolToken) {

            _coreWithdrawBare(
                _nftId,
                _poolToken,
                cashoutAmount,
                cashoutShares
            );

            return cashoutAmount;
        }

        uint256 totalPoolInShares = calculateLendingShares(
            _poolToken,
            totalPoolToken
        );

        uint256 shareDifference = cashoutShares
            - totalPoolInShares;

        _coreWithdrawBare(
            _nftId,
            _poolToken,
            totalPoolToken,
            totalPoolInShares
        );

        _decreaseLendingShares(
            _nftId,
            _poolToken,
            shareDifference
        );

        _increasePositionLendingDeposit(
            _nftIdLiquidator,
            _poolToken,
            shareDifference
        );

        _addPositionTokenData(
            _nftId,
            _poolToken,
            hashMapPositionLending,
            positionLendingTokenData
        );

        return totalPoolToken;
    }

    /**
     * @dev Internal math function combining functionallity
     * of {_withdrawPureCollateralLiquidation} and
     * {_withdrawOrAllocateSharesLiquidation}.
     */
    function _calculateReceiveAmount(
        uint256 _nftId,
        uint256 _nftIdLiquidator,
        address _receiveTokens,
        uint256 _removePercentage
    )
        internal
        returns (uint256)
    {
        uint256 receiveAmount = _withdrawPureCollateralLiquidation(
            _nftId,
            _receiveTokens,
            _removePercentage
        );

        if (isDecollteralized(_nftId, _receiveTokens) == true) {
            return receiveAmount;
        }

        return _withdrawOrAllocateSharesLiquidation(
            _nftId,
            _nftIdLiquidator,
            _receiveTokens,
            _removePercentage
        ) + receiveAmount;
    }

    /**
     * @dev Core liquidation function for
     * security checks and liquidation math.
     */
    function _coreLiquidation(
        uint256 _nftId,
        uint256 _nftIdLiquidator,
        address _caller,
        address _receiver,
        address _tokenToPayback,
        address _tokenToRecieve,
        uint256 _paybackAmount,
        uint256 _shareAmountToPay,
        uint256 _maxFeeUSD,
        uint256 _baseRewardLiquidation
    )
        internal
        returns (uint256 receiveAmount)
    {
        uint256 paybackUSD = WISE_ORACLE.getTokensInUSD(
            _tokenToPayback,
            _paybackAmount
        );

        uint256 collateralPercenage = WISE_SECURITY.calculateWishPercentage(
            _nftId,
            _tokenToRecieve,
            paybackUSD,
            _maxFeeUSD,
            _baseRewardLiquidation
        );

        if (collateralPercenage > PRECISION_FACTOR_E18) {
            revert CollateralTooSmall();
        }

        _corePayback(
            _nftId,
            _tokenToPayback,
            _paybackAmount,
            _shareAmountToPay
        );

        receiveAmount = _calculateReceiveAmount(
            _nftId,
            _nftIdLiquidator,
            _tokenToRecieve,
            collateralPercenage
        );

        WISE_SECURITY.checkBadDebt(
            _nftId
        );

        _safeTransferFrom(
            _tokenToPayback,
            _caller,
            address(this),
            _paybackAmount
        );

        _safeTransfer(
            _tokenToRecieve,
            _receiver,
            receiveAmount
        );
    }
}
pragma solidity =0.8.21;

import "./WiseLowLevelHelper.sol";
import "./TransferHub/TransferHelper.sol";

abstract contract MainHelper is WiseLowLevelHelper, TransferHelper {

    /**
     * @dev Internal helper function for reservating a
     * position NFT id.
     */
    function _reservePosition()
        internal
        returns (uint256)
    {
        return POSITION_NFT.reservePositionForUser(
            msg.sender
        );
    }

    /**
     * @dev Helper function to convert {_amount}
     * of a certain pool with {_poolToken}
     * into lending shares. Includes devison
     * by zero and share security checks.
     * Needs latest pseudo amount for accurate
     * result.
     */
    function calculateLendingShares(
        address _poolToken,
        uint256 _amount
    )
        public
        view
        returns (uint256)
    {
        uint256 shares = getTotalDepositShares(
            _poolToken
        );

        if (shares <= 1) {
            return _amount;
        }

        uint256 pseudo = getPseudoTotalPool(
            _poolToken
        );

        if (pseudo == 0) {
            return _amount;
        }

        return _amount
            * shares
            / pseudo;
    }

    /**
     * @dev Helper function to convert {_amount}
     * of a certain pool with {_poolToken}
     * into borrow shares. Includes devison
     * by zero and share security checks.
     * Needs latest pseudo amount for accurate
     * result.
     */
    function calculateBorrowShares(
        address _poolToken,
        uint256 _amount
    )
        public
        view
        returns (uint256)
    {
        uint256 shares = getTotalBorrowShares(
            _poolToken
        );

        uint256 pseudo = getPseudoTotalBorrowAmount(
            _poolToken
        );

        if (shares <= 1) {
            return _amount;
        }

        if (pseudo == 0) {
            return _amount;
        }

        return _amount
            * shares
            / pseudo;
    }

    /**
     * @dev Helper function to convert {_shares}
     * of a certain pool with {_poolToken}
     * into lending token. Includes devison
     * by zero and share security checks.
     * Needs latest pseudo amount for accurate
     * result.
     */
    function cashoutAmount(
        address _poolToken,
        uint256 _shares
    )
        public
        view
        returns (uint256)
    {
        return _shares
            * getPseudoTotalPool(_poolToken)
            / getTotalDepositShares(_poolToken);
    }

    /**
     * @dev Helper function to convert {_shares}
     * of a certain pool with {_poolToken}
     * into borrow token. Includes devison
     * by zero and share security checks.
     * Needs latest pseudo amount for accurate
     * result.
     */
    function paybackAmount(
        address _poolToken,
        uint256 _shares
    )
        public
        view
        returns (uint256)
    {
        return _shares
            * getPseudoTotalBorrowAmount(_poolToken)
            / getTotalBorrowShares(_poolToken);
    }

    /**
     * @dev Internal helper combining one
     * security check with lending share
     * calculation for withdraw.
     */
    function _preparationsWithdraw(
        uint256 _nftId,
        address _caller,
        address _poolToken,
        uint256 _amount
    )
        internal
        view
        returns (uint256)
    {
        WISE_SECURITY.checkOwnerPosition(
            _nftId,
            _caller
        );

        return calculateLendingShares(
            _poolToken,
            _amount
        );
    }

    /**
     * @dev Internal helper calculating utilization
     * of pool with {_poolToken}. Includes math underflow
     * check.
     */
    function _getValueUtilization(
        address _poolToken
    )
        private
        view
        returns (uint256)
    {
        if (getTotalPool(_poolToken) >= getPseudoTotalPool(_poolToken)) {
            return 0;
        }

        return PRECISION_FACTOR_E18 - (PRECISION_FACTOR_E18
            * getTotalPool(_poolToken)
            / getPseudoTotalPool(_poolToken)
        );
    }

    /**
     * @dev Internal helper function setting new pool
     * utilization by calling {_getValueUtilization}.
     */
    function _updateUtilization(
        address _poolToken
    )
        private
    {
        globalPoolData[_poolToken].utilization = _getValueUtilization(
            _poolToken
        );
    }

    /**
     * @dev Internal helper function checking if
     * cleanup gathered new token to save into
     * pool variables.
     */
    function _checkCleanUp(
        uint256 _amountContract,
        uint256 _totalPool,
        uint256 _bareAmount
    )
        private
        pure
        returns (bool)
    {
        return _bareAmount + _totalPool >= _amountContract;
    }

    /**
     * @dev Internal helper function checking if falsely
     * sent token are inside the contract for the pool with
     * {_poolToken}. If this is the case it adds those token
     * to the pool by increasing pseudo and total amount.
     * In context of aToken from aave pools it gathers the
     * rebase amount from supply APY of aave pools.
     */
    function _cleanUp(
        address _poolToken
    )
        internal
    {
        uint256 amountContract = IERC20(_poolToken).balanceOf(
            address(this)
        );

        uint256 totalPool = getTotalPool(
            _poolToken
        );

        uint256 bareToken = getTotalBareToken(
            _poolToken
        );

        if (_checkCleanUp(amountContract, totalPool, bareToken)) {
            return;
        }

        uint256 diff = amountContract - (
            totalPool + bareToken
        );

        _increaseTotalAndPseudoTotalPool(
            _poolToken,
            diff
        );
    }

    /**
     * @dev External wrapper for {_preparePole}
     * Only callable by powerFarms, feeManager
     * and aaveHub.
     */
    function preparePool(
        address _poolToken
    )
        external
        onlyAllowedContracts
    {
        _preparePool(
            _poolToken
        );
    }

    /**
     * @dev External wrapper for {_newBorrowRate}
     * Only callable by powerFarms, feeManager
     * and aaveHub.
     */
    function newBorrowRate(
        address _poolToken
    )
        external
        onlyAllowedContracts
    {
        _newBorrowRate(
            _poolToken
        );
    }

    /**
     * @dev Internal helper function for
     * updating pools and calling {_cleanUp}.
     * Also includes re-entrancy guard for
     * curve pools security checks.
     */
    function _preparePool(
        address _poolToken
    )
        internal
    {
        WISE_SECURITY.curveSecurityCheck(
            _poolToken
        );

        _cleanUp(
            _poolToken
        );

        _updatePseudoTotalAmounts(
            _poolToken
        );
    }

    /**
     * @dev Internal helper function for
     * updating all borrow tokens of a
     * position.
     */
    function _preparationBorrows(
        uint256 _nftId,
        address _poolToken
    )
        internal
    {
        _prepareTokens(
            _poolToken,
            positionBorrowTokenData[_nftId]
        );
    }

    /**
     * @dev Internal helper function for
     * updating all lending tokens of a
     * position.
     */
    function _preparationCollaterals(
        uint256 _nftId,
        address _poolToken
    )
        internal
    {
        _prepareTokens(
            _poolToken,
            positionLendingTokenData[_nftId]
        );
    }

    /**
     * @dev Internal helper function for
     * updating pseudo amounts of a pool
     * inside {tokens} array and sets new
     * borrow rates.
     */
    function _prepareTokens(
        address _poolToken,
        address[] memory tokens
    )
        private
    {
        address currentAddress;

        for (uint8 i = 0; i < tokens.length; ++i) {

            currentAddress = tokens[i];

            if (currentAddress == _poolToken) {
                continue;
            }

            _preparePool(
                currentAddress
            );

            _newBorrowRate(
                currentAddress
            );
        }
    }

    /**
     * @dev Internal helper function
     * updating pseudo amounts and
     * printing fee shares for the
     * feeManager proportional to the
     * fee percentage of the pool.
     */
    function _updatePseudoTotalAmounts(
        address _poolToken
    )
        internal
    {
        uint256 currentTime = block.timestamp;

        uint256 bareIncrease = borrowPoolData[_poolToken].borrowRate
            * (currentTime - getTimeStamp(_poolToken))
            * getPseudoTotalBorrowAmount(_poolToken)
            + bufferIncrease[_poolToken];

        if (bareIncrease < PRECISION_FACTOR_E18_YEAR) {
            bufferIncrease[_poolToken] = bareIncrease;

            _setTimeStamp(
                _poolToken,
                currentTime
            );

            return;
        }

        delete bufferIncrease[_poolToken];

        uint256 amountInterest = bareIncrease
            / PRECISION_FACTOR_E18_YEAR;

        uint256 feeAmount = amountInterest
            * globalPoolData[_poolToken].poolFee
            / PRECISION_FACTOR_E18;

        _increasePseudoTotalBorrowAmount(
            _poolToken,
            amountInterest
        );

        _increasePseudoTotalPool(
            _poolToken,
            amountInterest
        );

        if (feeAmount == 0) {
            return;
        }

        uint256 feeShares = feeAmount
            * getTotalDepositShares(_poolToken)
            / (getPseudoTotalPool(_poolToken) - feeAmount);

        _increasePositionLendingDeposit(
            FEE_MANAGER_NFT,
            _poolToken,
            feeShares
        );

        _increaseTotalDepositShares(
            _poolToken,
            feeShares
        );

        _setTimeStamp(
            _poolToken,
            currentTime
        );
    }

    /**
     * @dev Internal increas function for
     * lending shares of a postion {_nftId}
     * and {_poolToken}.
     */
    function _increasePositionLendingDeposit(
        uint256 _nftId,
        address _poolToken,
        uint256 _shares
    )
        internal
    {
        userLendingData[_nftId][_poolToken].shares += _shares;
    }

    /**
     * @dev Internal decrease function for
     * lending shares of a postion {_nftId}
     * and {_poolToken}.
     */
    function _decreaseLendingShares(
        uint256 _nftId,
        address _poolToken,
        uint256 _shares
    )
        internal
    {
        userLendingData[_nftId][_poolToken].shares -= _shares;
    }

    /**
     * @dev Internal helper function adding a new
     * {_poolToken} token to {userTokenData} if needed.
     * Check is done by using hash maps.
     */
    function _addPositionTokenData(
        uint256 _nftId,
        address _poolToken,
        mapping(bytes32 => bool) storage hashMap,
        mapping(uint256 => address[]) storage userTokenData
    )
        internal
    {
        bytes32 hashData = _getHash(
            _nftId,
            _poolToken
        );

        if (hashMap[hashData] == true) {
            return;
        }

        hashMap[hashData] = true;

        userTokenData[_nftId].push(
            _poolToken
        );
    }

    /**
     * @dev Internal helper calculating
     * a hash out of {_nftId} and {_poolToken}
     * using keccak256.
     */
    function _getHash(
        uint256 _nftId,
        address _poolToken
    )
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                _nftId,
                _poolToken
            )
        );
    }

    /**
     * @dev Internal helper function deleting an
     * entry in {_deleteLastPositionData}.
     */
    function _removePositionData(
        uint256 _nftId,
        address _poolToken,
        function(uint256) view returns (uint256) _getPositionTokenLength,
        function(uint256, uint256) view returns (address) _getPositionTokenByIndex,
        function(uint256, address) internal _deleteLastPositionData,
        bool isLending
    )
        internal
    {
        uint256 length = _getPositionTokenLength(
            _nftId
        );

        if (length == 1) {
            _deleteLastPositionData(
                _nftId,
                _poolToken
            );

            return;
        }

        uint8 index;
        uint256 endPosition = length - 1;

        while (index < length) {

            if (_getPositionTokenByIndex(_nftId, index) != _poolToken) {
                index += 1;
                continue;
            }

            address poolToken = _getPositionTokenByIndex(
                _nftId,
                endPosition
            );

            isLending
                ? positionLendingTokenData[_nftId][index] = poolToken
                : positionBorrowTokenData[_nftId][index] = poolToken;

            _deleteLastPositionData(
                _nftId,
                _poolToken
            );

            break;
        }
    }

    /**
     * @dev Internal helper deleting last entry
     * of postion lending data.
     */
    function _deleteLastPositionLendingData(
        uint256 _nftId,
        address _poolToken
    )
        internal
    {
        positionLendingTokenData[_nftId].pop();
        hashMapPositionLending[
            _getHash(
                _nftId,
                _poolToken
            )
        ] = false;
    }

    /**
     * @dev Internal helper deleting last entry
     * of postion borrow data.
     */
    function _deleteLastPositionBorrowData(
        uint256 _nftId,
        address _poolToken
    )
        internal
    {
        positionBorrowTokenData[_nftId].pop();
        hashMapPositionBorrow[
            _getHash(
                _nftId,
                _poolToken
            )
        ] = false;
    }

    /**
     * @dev Internal helper function calculating
     * returning if a {_poolToken} of a {_nftId}
     * is decollateralized.
     */
    function isDecollteralized(
        uint256 _nftId,
        address _poolToken
    )
        public
        view
        returns (bool)
    {
        return userLendingData[_nftId][_poolToken].deCollteralized;
    }

    /**
     * @dev Internal helper function calculating
     * the borrow share amount corresponding to
     * certain {_lendingShares}.
     */
    function _borrowShareEquivalent(
        address _poolToken,
        uint256 _lendingShares
    )
        internal
        view
        returns (uint256)
    {
        return _lendingShares
            * getPseudoTotalPool(_poolToken)
            * getTotalBorrowShares(_poolToken)
            / getTotalDepositShares(_poolToken)
            / getPseudoTotalBorrowAmount(_poolToken);
    }

    /**
     * @dev Internal helper function
     * checking if {_nftId} as no
     * {_poolToken} left.
     */
    function checkLendingDataEmpty(
        uint256 _nftId,
        address _poolToken
    )
        public
        view
        returns (bool)
    {
        return userLendingData[_nftId][_poolToken].shares == 0
            && positionPureCollateralAmount[_nftId][_poolToken] == 0;
    }

    /**
     * @dev Internal helper function
     * calculating new borrow rates
     * for {_poolToken}. Uses smooth
     * functions of the form
     * f(x) = a * x /(p(p-x)) with
     * p > 1E18 the {pole} and
     * a the {mulFactor}.
     */

    function _calculateNewBorrowRate(
        address _poolToken
    )
        internal
    {
        uint256 pole = borrowRatesData[_poolToken].pole;
        uint256 utilization = globalPoolData[_poolToken].utilization;

        uint256 baseDivider = pole
            * (pole - utilization);

        _setBorrowRate(
            _poolToken,
            borrowRatesData[_poolToken].multiplicativeFactor
                * PRECISION_FACTOR_E18
                * utilization
                / baseDivider
        );
    }

    /**
     * @dev Internal helper function
     * updating utilization of the pool
     * with {_poolToken}, calculating the
     * new borrow rate and running LASA if
     * the time intervall of three hours has
     * passed.
     */
    function _newBorrowRate(
        address _poolToken
    )
        internal
    {
        _updateUtilization(
            _poolToken
        );

        _calculateNewBorrowRate(
            _poolToken
        );

        if (_aboveThreshold(_poolToken) == false) {
            return;
        }

        _scalingAlgorithm(
            _poolToken
        );
    }

    /**
     * @dev Internal helper function
     * checking if time interval for
     * next LASA call has passed.
     */
    function _aboveThreshold(
        address _poolToken
    )
        private
        view
        returns (bool)
    {
        return block.timestamp - _getTimeStampScaling(_poolToken) >= THREE_HOURS;
    }

    /**
     * @dev function that tries to maximise totalDepositShares of the pool.
     * Reacting to negative and positive feedback by changing the resonance
     * factor of the pool. Method similar to one parameter monte-carlo methods
     */
    function _scalingAlgorithm(
        address _poolToken
    )
        private
    {
        uint256 totalShares = getTotalDepositShares(
            _poolToken
        );

        if (algorithmData[_poolToken].maxValue <= totalShares) {

            _newMaxPoolShares(
                _poolToken,
                totalShares
            );

            _saveUp(
                _poolToken,
                totalShares
            );

            return;
        }

        _resonanceOutcome(_poolToken, totalShares) == true
            ? _resetResonanceFactor(_poolToken, totalShares)
            : _updateResonanceFactor(_poolToken, totalShares);

        _saveUp(
            _poolToken,
            totalShares
        );
    }

    /**
     * @dev Sets the new max value in shares
     * and saves the corresponding resonance factor.
     */
    function _newMaxPoolShares(
        address _poolToken,
        uint256 _shareValue
    )
        private
    {
        _setMaxValue(
            _poolToken,
            _shareValue
        );

        _setBestPole(
            _poolToken,
            borrowRatesData[_poolToken].pole
        );
    }

    /**
     * @dev Internal function setting {previousValue}
     * and {timestampScaling} for LASA of pool with
     * {_poolToken}.
     */
    function _saveUp(
        address _poolToken,
        uint256 _shareValue
    )
        private
    {
        _setPreviousValue(
            _poolToken,
            _shareValue
        );

        _setTimeStampScaling(
            _poolToken,
            block.timestamp
        );
    }

    /**
     * @dev Returns bool to determine if resonance
     * factor needs to be reset to last best value.
     */
    function _resonanceOutcome(
        address _poolToken,
        uint256 _shareValue
    )
        private
        view
        returns (bool)
    {
        return _shareValue < THRESHOLD_RESET_RESONANCE_FACTOR
            * algorithmData[_poolToken].maxValue
            / PRECISION_FACTOR_E18;
    }

    /**
     * @dev Resets resonance factor to old best value when system
     * evolves into too bad state and sets current totalDepositShares
     * amount to new maxPoolShares to exclude eternal loops and that
     * unorganic peaks do not set maxPoolShares forever.
     */
    function _resetResonanceFactor(
        address _poolToken,
        uint256 _shareValue
    )
        private
    {
        _setPole(
            _poolToken,
            algorithmData[_poolToken].bestPole
        );

        _setMaxValue(
            _poolToken,
            _shareValue
        );

        _revertDirectionSteppingState(
            _poolToken
        );
    }

    /**
     * @dev Reverts the flag for stepping direction from LASA.
     */
    function _revertDirectionSteppingState(
        address _poolToken
    )
        private
    {
        _setIncreasePole(
            _poolToken,
            !algorithmData[_poolToken].increasePole
        );
    }

    /**
     * @dev Function combining all possible stepping scenarios.
     * Depending how share values has changed compared to last time.
     */
    function _updateResonanceFactor(
        address _poolToken,
        uint256 _shareValues
    )
        private
    {
        _shareValues < THRESHOLD_SWITCH_DIRECTION * algorithmData[_poolToken].previousValue / PRECISION_FACTOR_E18
            ? _reversedChangingResonanceFactor(_poolToken)
            : _changingResonanceFactor(_poolToken);
    }

    /**
     * @dev Does a revert stepping and swaps stepping state in opposite flag.
     */
    function _reversedChangingResonanceFactor(
        address _poolToken
    )
        private
    {
        algorithmData[_poolToken].increasePole
            ? _decreaseResonanceFactor(_poolToken)
            : _increaseResonanceFactor(_poolToken);

        _revertDirectionSteppingState(
            _poolToken
        );
    }

    /**
     * @dev Increasing or decresing resonance factor depending on flag value.
     */
    function _changingResonanceFactor(
        address _poolToken
    )
        private
    {
        algorithmData[_poolToken].increasePole
            ? _increaseResonanceFactor(_poolToken)
            : _decreaseResonanceFactor(_poolToken);
    }

    /**
     * @dev stepping function increasing the resonance factor
     * depending on the time past in the last time interval.
     * Checks if current resonance factor is bigger than max value.
     * If this is the case sets current value to maximal value
     */
    function _increaseResonanceFactor(
        address _poolToken
    )
        private
    {
        BorrowRatesEntry memory borrowData = borrowRatesData[
            _poolToken
        ];

        uint256 delta = borrowData.deltaPole
            * (block.timestamp - _getTimeStampScaling(_poolToken));

        uint256 sum = delta
            + borrowData.pole;

        uint256 setValue = sum > borrowData.maxPole
            ? borrowData.maxPole
            : sum;

        _setPole(
            _poolToken,
            setValue
        );
    }

    /**
     * @dev Stepping function decresing the resonance factor
     * depending on the time past in the last time interval.
     * Checks if current resonance factor undergoes the min value,
     * if this is the case sets current value to minimal value.
     */
    function _decreaseResonanceFactor(
        address _poolToken
    )
        private
    {
        uint256 minValue = borrowRatesData[_poolToken].minPole;

        uint256 delta = borrowRatesData[_poolToken].deltaPole
            * (block.timestamp - _getTimeStampScaling(_poolToken));

        uint256 sub = borrowRatesData[_poolToken].pole > delta
            ? borrowRatesData[_poolToken].pole - delta
            : 0;

        uint256 setValue = sub < minValue
            ? minValue
            : sub;

        _setPole(
            _poolToken,
            setValue
        );
    }

    /**
     * @dev Internal helper function for removing token address
     * from lending data array if all shares are removed. When
     * feeManager (nftId = 0) is calling this function is skipped
     * to save gase for continues fee accounting.
     */
    function _removeEmptyLendingData(
        uint256 _nftId,
        address _poolToken
    )
        internal
    {
        if (_nftId == 0) {
            return;
        }

        if (checkLendingDataEmpty(_nftId, _poolToken) == false) {
            return;
        }

        _removePositionData({
            _nftId: _nftId,
            _poolToken: _poolToken,
            _getPositionTokenLength: getPositionLendingTokenLength,
            _getPositionTokenByIndex: getPositionLendingTokenByIndex,
            _deleteLastPositionData: _deleteLastPositionLendingData,
            isLending: true
        });
    }

    /**
     * @dev Internal helper function grouping several function
     * calls into one function for refactoring and code size
     * reduction.
     */
    function _updatePoolStorage(
        address _poolToken,
        uint256 _amount,
        uint256 _shares,
        function(address, uint256) functionAmountA,
        function(address, uint256) functionAmountB,
        function(address, uint256) functionSharesA
    )
        internal
    {
        functionAmountA(
            _poolToken,
            _amount
        );

        functionAmountB(
            _poolToken,
            _amount
        );

        functionSharesA(
            _poolToken,
            _shares
        );
    }
}
pragma solidity =0.8.21;

import "./CallOptionalReturn.sol";

contract TransferHelper is CallOptionalReturn {

    bytes4 constant transfer = IERC20
        .transfer
        .selector;

    bytes4 constant transferFrom = IERC20
        .transferFrom
        .selector;

    /**
     * @dev
     * Allows to execute safe transfer for a token
     */
    function _safeTransfer(
        address _token,
        address _to,
        uint256 _value
    )
        internal
    {
        _callOptionalReturn(
            _token,
            abi.encodeWithSelector(
                transfer,
                _to,
                _value
            )
        );
    }

    /**
     * @dev
     * Allows to execute safe transferFrom for a token
     */
    function _safeTransferFrom(
        address _token,
        address _from,
        address _to,
        uint256 _value
    )
        internal
    {
        _callOptionalReturn(
            _token,
            abi.encodeWithSelector(
                transferFrom,
                _from,
                _to,
                _value
            )
        );
    }
}
pragma solidity =0.8.21;

import "./WiseLendingDeclaration.sol";

abstract contract WiseLowLevelHelper is WiseLendingDeclaration {

    modifier onlyFeeManager() {
        _onlyFeeManager();
        _;
    }

    function _onlyFeeManager()
        private
        view
    {
        if (msg.sender == address(FEE_MANAGER)) {
            return;
        }

        revert InvalidCaller();
    }

    modifier onlyAllowedContracts() {
        _onlyAllowedContracts();
        _;
    }

    function _onlyAllowedContracts()
        private
        view
    {
        if (_byPassCase(msg.sender) == true) {
            return;
        }

        if (msg.sender == address(FEE_MANAGER)) {
            return;
        }

        revert InvalidCaller();
    }

    // --- Basic Public Views Functions ----

    function getTotalPool(
        address _poolToken
    )
        public
        view
        returns (uint256)
    {
        return globalPoolData[_poolToken].totalPool;
    }

    function getPseudoTotalPool(
        address _poolToken
    )
        public
        view
        returns (uint256)
    {
        return lendingPoolData[_poolToken].pseudoTotalPool;
    }

    function getTotalBareToken(
        address _poolToken
    )
        public
        view
        returns (uint256)
    {
        return globalPoolData[_poolToken].totalBareToken;
    }

    function getPseudoTotalBorrowAmount(
        address _poolToken
    )
        public
        view
        returns (uint256)
    {
        return borrowPoolData[_poolToken].pseudoTotalBorrowAmount;
    }

    function getTotalDepositShares(
        address _poolToken
    )
        public
        view
        returns (uint256)
    {
        return lendingPoolData[_poolToken].totalDepositShares;
    }

    function getTotalBorrowShares(
        address _poolToken
    )
        public
        view
        returns (uint256)
    {
        return borrowPoolData[_poolToken].totalBorrowShares;
    }

    function getPositionLendingShares(
        uint256 _nftId,
        address _poolToken
    )
        public
        view
        returns (uint256)
    {
        return userLendingData[_nftId][_poolToken].shares;
    }

    function getPositionBorrowShares(
        uint256 _nftId,
        address _poolToken
    )
        public
        view
        returns (uint256)
    {
        return userBorrowShares[_nftId][_poolToken];
    }

    function getPureCollateralAmount(
        uint256 _nftId,
        address _poolToken
    )
        public
        view
        returns (uint256)
    {
        return positionPureCollateralAmount[_nftId][_poolToken];
    }

    // --- Basic Internal Get Functions ----

    function getTimeStamp(
        address _poolToken
    )
        public
        view
        returns (uint256)
    {
        return timestampsPoolData[_poolToken].timeStamp;
    }

    function _getTimeStampScaling(
        address _poolToken
    )
        internal
        view
        returns (uint256)
    {
        return timestampsPoolData[_poolToken].timeStampScaling;
    }

    function getPositionLendingTokenByIndex(
        uint256 _nftId,
        uint256 _index
    )
        public
        view
        returns (address)
    {
        return positionLendingTokenData[_nftId][_index];
    }

    function getPositionLendingTokenLength(
        uint256 _nftId
    )
        public
        view
        returns (uint256)
    {
        return positionLendingTokenData[_nftId].length;
    }

    function getPositionBorrowTokenByIndex(
        uint256 _nftId,
        uint256 _index
    )
        public
        view
        returns (address)
    {
        return positionBorrowTokenData[_nftId][_index];
    }

    function getPositionBorrowTokenLength(
        uint256 _nftId
    )
        public
        view
        returns (uint256)
    {
        return positionBorrowTokenData[_nftId].length;
    }

    // --- Basic Internal Set Functions ----

    function _setMaxValue(
        address _poolToken,
        uint256 _value
    )
        internal
    {
        algorithmData[_poolToken].maxValue = _value;
    }

    function _setPreviousValue(
        address _poolToken,
        uint256 _value
    )
        internal
    {
        algorithmData[_poolToken].previousValue = _value;
    }

    function _setBestPole(
        address _poolToken,
        uint256 _value
    )
        internal
    {
        algorithmData[_poolToken].bestPole = _value;
    }

    function _setIncreasePole(
        address _poolToken,
        bool _state
    )
        internal
    {
        algorithmData[_poolToken].increasePole = _state;
    }

    function _setPole(
        address _poolToken,
        uint256 _value
    )
        internal
    {
        borrowRatesData[_poolToken].pole = _value;
    }

    function _increaseTotalPool(
        address _poolToken,
        uint256 _amount
    )
        internal
    {
        globalPoolData[_poolToken].totalPool += _amount;
    }

    function _decreaseTotalPool(
        address _poolToken,
        uint256 _amount
    )
        internal
    {
        globalPoolData[_poolToken].totalPool -= _amount;
    }

    function _increaseTotalDepositShares(
        address _poolToken,
        uint256 _amount
    )
        internal
    {
        lendingPoolData[_poolToken].totalDepositShares += _amount;
    }

    function _decreaseTotalDepositShares(
        address _poolToken,
        uint256 _amount
    )
        internal
    {
        lendingPoolData[_poolToken].totalDepositShares -= _amount;
    }

    function _increasePseudoTotalBorrowAmount(
        address _poolToken,
        uint256 _amount
    )
        internal
    {
        borrowPoolData[_poolToken].pseudoTotalBorrowAmount += _amount;
    }

    function _decreasePseudoTotalBorrowAmount(
        address _poolToken,
        uint256 _amount
    )
        internal
    {
        borrowPoolData[_poolToken].pseudoTotalBorrowAmount -= _amount;
    }

    function _increaseTotalBorrowShares(
        address _poolToken,
        uint256 _amount
    )
        internal
    {
        borrowPoolData[_poolToken].totalBorrowShares += _amount;
    }

    function _decreaseTotalBorrowShares(
        address _poolToken,
        uint256 _amount
    )
        internal
    {
        borrowPoolData[_poolToken].totalBorrowShares -= _amount;
    }

    function _increasePseudoTotalPool(
        address _poolToken,
        uint256 _amount
    )
        internal
    {
        lendingPoolData[_poolToken].pseudoTotalPool += _amount;
    }

    function _decreasePseudoTotalPool(
        address _poolToken,
        uint256 _amount
    )
        internal
    {
        lendingPoolData[_poolToken].pseudoTotalPool -= _amount;
    }

    function _setBorrowRate(
        address _poolToken,
        uint256 _amount
    )
        internal
    {
        borrowPoolData[_poolToken].borrowRate = _amount;
    }

    function _setTimeStamp(
        address _poolToken,
        uint256 _time
    )
        internal
    {
        timestampsPoolData[_poolToken].timeStamp = _time;
    }

    function _setTimeStampScaling(
        address _poolToken,
        uint256 _time
    )
        internal
    {
        timestampsPoolData[_poolToken].timeStampScaling = _time;
    }

    function _increaseTotalBareToken(
        address _poolToken,
        uint256 _amount
    )
        internal
    {
        globalPoolData[_poolToken].totalBareToken += _amount;
    }

    function _decreaseTotalBareToken(
        address _poolToken,
        uint256 _amount
    )
        internal
    {
        globalPoolData[_poolToken].totalBareToken -= _amount;
    }

    function _reduceAllowance(
        uint256 _nftId,
        address _poolToken,
        address _spender,
        uint256 _amount
    )
        internal
    {
        if (POSITION_NFT.getApproved(_nftId) == _spender) {
            return;
        }

        address owner = POSITION_NFT.ownerOf(
            _nftId
        );

        if (allowance[owner][_poolToken][_spender] != type(uint256).max) {
            allowance[owner][_poolToken][_spender] -= _amount;
        }
    }

    function _decreasePositionMappingValue(
        mapping(uint256 => mapping(address => uint256)) storage userMapping,
        uint256 _nftId,
        address _poolToken,
        uint256 _amount
    )
        internal
    {
        userMapping[_nftId][_poolToken] -= _amount;
    }

    function _increaseMappingValue(
        mapping(uint256 => mapping(address => uint256)) storage userMapping,
        uint256 _nftId,
        address _poolToken,
        uint256 _amount
    )
        internal
    {
        userMapping[_nftId][_poolToken] += _amount;
    }

    function _byPassCase(
        address _sender
    )
        internal
        view
        returns (bool)
    {
        if (_sender == AAVE_HUB) {
            return true;
        }

        if (veryfiedIsolationPool[_sender] == true) {
            return true;
        }

        return false;
    }

    function _increaseTotalAndPseudoTotalPool(
        address _poolToken,
        uint256 _amount
    )
        internal
    {
        _increasePseudoTotalPool(
            _poolToken,
            _amount
        );

        _increaseTotalPool(
            _poolToken,
            _amount
        );
    }

    function setPoolFee(
        address _poolToken,
        uint256 _newFee
    )
        external
        onlyFeeManager
    {
        globalPoolData[_poolToken].poolFee = _newFee;
    }
}
pragma solidity =0.8.21;

import "./InterfaceHub/IWETH.sol";
import "./InterfaceHub/IPositionNFTs.sol";
import "./InterfaceHub/IWiseSecurity.sol";
import "./InterfaceHub/IWiseOracleHub.sol";
import "./InterfaceHub/IFeeManagerLight.sol";

import "./OwnableMaster.sol";

error InvalidCaller();
error AlreadyCreated();
error PositionLocked();
error ForbiddenValue();
error ParametersLocked();
error DepositCapReached();
error CollateralTooSmall();

contract WiseLendingDeclaration is OwnableMaster {

    event FundsDeposited(
        address indexed sender,
        uint256 indexed nftId,
        address indexed token,
        uint256 amount,
        uint256 shares,
        uint256 timestamp
    );

    event FundsSolelyDeposited(
        address indexed sender,
        uint256 indexed nftId,
        address indexed token,
        uint256 amount,
        uint256 timestamp
    );

    event FundsWithdrawn(
        address indexed sender,
        uint256 indexed nftId,
        address indexed token,
        uint256 amount,
        uint256 shares,
        uint256 timestamp
    );

    event FundsWithdrawnOnBehalf(
        address indexed sender,
        uint256 indexed nftId,
        address indexed token,
        uint256 amount,
        uint256 shares,
        uint256 timestamp
    );

    event FundsSolelyWithdrawn(
        address indexed sender,
        uint256 indexed nftId,
        address indexed token,
        uint256 amount,
        uint256 timestamp
    );

    event FundsSolelyWithdrawnOnBehalf(
        address indexed sender,
        uint256 indexed nftId,
        address indexed token,
        uint256 amount,
        uint256 timestamp
    );

    event FundsBorrowed(
        address indexed borrower,
        uint256 indexed nftId,
        address indexed token,
        uint256 amount,
        uint256 shares,
        uint256 timestamp
    );

    event FundsBorrowedOnBehalf(
        address indexed sender,
        uint256 indexed nftId,
        address indexed token,
        uint256 amount,
        uint256 shares,
        uint256 timestamp
    );

    event FundsReturned(
        address indexed sender,
        address indexed token,
        uint256 indexed nftId,
        uint256 totalPayment,
        uint256 totalPaymentShares,
        uint256 timestamp
    );

    event FundsReturnedWithLendingShares(
        address indexed sender,
        address indexed token,
        uint256 indexed nftId,
        uint256 totalPayment,
        uint256 totalPaymentShares,
        uint256 timestamp
    );

    event Approve(
        address indexed sender,
        address indexed token,
        address indexed user,
        uint256 amount,
        uint256 timestamp
    );

    event PoolSynced(
        address pool,
        uint256 timestamp
    );

    event RegisteredForIsolationPool(
        address user,
        uint256 timestamp,
        bool registration
    );

    constructor(
        address _master,
        address _wiseOracleHub,
        address _nftContract,
        address _wethContract
    )
        OwnableMaster(
            _master
        )
    {
        WETH_ADDRESS = _wethContract;

        WETH = IWETH(
            _wethContract
        );

        WISE_ORACLE = IWiseOracleHub(
            _wiseOracleHub
        );

        POSITION_NFT = IPositionNFTs(
            _nftContract
        );
    }

    function setSecurity(
        address _wiseSecurity
    )
        external
        onlyMaster
    {
        WISE_SECURITY = IWiseSecurity(
            _wiseSecurity
        );

        FEE_MANAGER = IFeeManagerLight(
            WISE_SECURITY.FEE_MANAGER()
        );

        AAVE_HUB = WISE_SECURITY.AAVE_HUB();
    }

    /**
     * @dev Wrapper for wrapping
     * ETH call.
     */
    function _wrapETH(
        uint256 _value
    )
        internal
    {
        WETH.deposit{
            value: _value
        }();
    }

    /**
     * @dev Wrapper for unwrapping
     * ETH call.
     */
    function _unwrapETH(
        uint256 _value
    )
        internal
    {
        WETH.withdraw(
            _value
        );
    }

    // Variables -----------------------------------------

    // Aave address
    address public AAVE_HUB;

    // Wrapped ETH address
    address public immutable WETH_ADDRESS;

    // Nft id for feeManager
    uint256 constant FEE_MANAGER_NFT = 0;


    // Interfaces -----------------------------------------

    // Wrapped ETH interface
    IWETH immutable WETH;

    // WiseSecurity interface
    IWiseSecurity public WISE_SECURITY;

    // FeeManager interface
    IFeeManagerLight public FEE_MANAGER;

    // NFT contract interface for positions
    IPositionNFTs public immutable POSITION_NFT;

    // OraceHub interface
    IWiseOracleHub public immutable WISE_ORACLE;

    // Structs ------------------------------------------

    struct LendingEntry {
        uint256 shares;
        bool deCollteralized;
    }

    struct BorrowRatesEntry {
        uint256 pole;
        uint256 deltaPole;
        uint256 minPole;
        uint256 maxPole;
        uint256 multiplicativeFactor;
    }

    struct AlgorithmEntry {
        uint256 bestPole;
        uint256 maxValue;
        uint256 previousValue;
        bool increasePole;
    }

    struct GlobalPoolEntry {
        uint256 totalPool;
        uint256 utilization;
        uint256 totalBareToken;
        uint256 poolFee;
    }

    struct LendingPoolEntry {
        uint256 pseudoTotalPool;
        uint256 totalDepositShares;
        uint256 collateralFactor;
    }

    struct BorrowPoolEntry {
        bool allowBorrow;
        uint256 pseudoTotalBorrowAmount;
        uint256 totalBorrowShares;
        uint256 borrowRate;
    }

    struct TimestampsPoolEntry {
        uint256 timeStamp;
        uint256 timeStampScaling;
    }

    // Position mappings ------------------------------------------
    mapping(address => uint256) bufferIncrease;
    mapping(address => uint256) public maxDepositValueToken;

    mapping(uint256 => address[]) public positionBorrowTokenData;
    mapping(uint256 => address[]) public positionLendingTokenData;

    mapping(uint256 => mapping(address => uint256)) public userBorrowShares;
    mapping(uint256 => mapping(address => LendingEntry)) public userLendingData;
    mapping(uint256 => mapping(address => uint256)) public positionPureCollateralAmount;

    // Owner -> PoolToken -> Spender -> Allowance Value
    mapping(address => mapping(address => mapping(address => uint256))) public allowance;

    // Struct mappings -------------------------------------
    mapping(address => BorrowRatesEntry) public borrowRatesData;
    mapping(address => AlgorithmEntry) public algorithmData;
    mapping(address => GlobalPoolEntry) public globalPoolData;
    mapping(address => LendingPoolEntry) public lendingPoolData;
    mapping(address => BorrowPoolEntry) public borrowPoolData;
    mapping(address => TimestampsPoolEntry) public timestampsPoolData;

    // Bool mappings -------------------------------------
    mapping(uint256 => bool) public positionLocked;
    mapping(address => bool) public parametersLocked;
    mapping(address => bool) public veryfiedIsolationPool;

    // Hash mappings -------------------------------------
    mapping(bytes32 => bool) hashMapPositionBorrow;
    mapping(bytes32 => bool) hashMapPositionLending;

    // PRECISION FACTORS ------------------------------------
    uint256 constant PRECISION_FACTOR_E16 = 1E16;
    uint256 constant PRECISION_FACTOR_E18 = 1E18;
    uint256 constant PRECISION_FACTOR_E36 = PRECISION_FACTOR_E18 * PRECISION_FACTOR_E18;

    // TIME CONSTANTS --------------------------------------
    uint256 constant ONE_YEAR = 52 weeks;
    uint256 constant THREE_HOURS = 3 hours;
    uint256 constant PRECISION_FACTOR_E18_YEAR = PRECISION_FACTOR_E18 * ONE_YEAR;

    // Two months in seconds:
    // Norming change in pole value that it steps from min to max value
    // within two month (if nothing changes)
    uint256 constant NORMALISATION_FACTOR = 4838400;

    // LASA CONSTANTS -------------------------
    uint256 constant THRESHOLD_SWITCH_DIRECTION = 90 * PRECISION_FACTOR_E16;
    uint256 constant THRESHOLD_RESET_RESONANCE_FACTOR = 75 * PRECISION_FACTOR_E16;
}
pragma solidity =0.8.21;

import "../InterfaceHub/IERC20.sol";

error CallFailed();

contract CallOptionalReturn {

    /**
     * @dev
     * Helper function to do low-level call
     */
    function _callOptionalReturn(
        address token,
        bytes memory data
    )
        internal
        returns (bool call)
    {
        (
            bool success,
            bytes memory returndata
        ) = token.call(
            data
        );

        bool results = returndata.length == 0 || abi.decode(
            returndata,
            (bool)
        );

        call = success
            && results
            && token.code.length > 0;

        if (call == false) {
            revert CallFailed();
        }
    }
}
pragma solidity =0.8.21;

error NotMaster();
error NotProposed();

contract OwnableMaster {

    address public master;
    address public proposedMaster;

    address constant ZERO_ADDRESS = address(0x0);

    modifier onlyProposed() {
        _onlyProposed();
        _;
    }

    function _onlyMaster()
        private
        view
    {
        if (msg.sender == master) {
            return;
        }

        revert NotMaster();
    }

    modifier onlyMaster() {
        _onlyMaster();
        _;
    }

    function _onlyProposed()
        private
        view
    {
        if (msg.sender == proposedMaster) {
            return;
        }

        revert NotProposed();
    }

    constructor(
        address _master
    ) {
        master = _master;
    }

    /**
     * @dev Allows to propose next master.
     * Must be claimed by proposer.
     */
    function proposeOwner(
        address _proposedOwner
    )
        external
        onlyMaster
    {
        proposedMaster = _proposedOwner;
    }

    /**
     * @dev Allows to claim master role.
     * Must be called by proposer.
     */
    function claimOwnership()
        external
        onlyProposed
    {
        master = proposedMaster;
    }

    /**
     * @dev Removes master role.
     * No ability to be in control.
     */
    function renounceOwnership()
        external
        onlyMaster
    {
        master = ZERO_ADDRESS;
        proposedMaster = ZERO_ADDRESS;
    }
}
pragma solidity =0.8.21;

interface IFeeManagerLight {
    function addPoolTokenAddress(
        address _poolToken
    )
        external;
}
pragma solidity =0.8.21;

interface IWiseOracleHub {

    function latestResolver(
        address _tokenAddress
    )
        external
        view
        returns (uint256);

    function getTokensFromUSD(
        address _tokenAddress,
        uint256 _usdValue
    )
        external
        view
        returns (uint256);

    function getTokensInUSD(
        address _tokenAddress,
        uint256 _amount
    )
        external
        view
        returns (uint256);

    function chainLinkIsDead(
        address _tokenAddress
    )
        external
        view
        returns (bool);

    function decimalsUSD()
        external
        pure
        returns (uint8);

    function previousValue(
        address _tokenAddress
    )
        external
        view
        returns (uint256);

    function setPreviousValue(
        address _tokenAddress
    )
        external;
}
pragma solidity =0.8.21;

struct CurveSwapStructToken {
    uint256 curvePoolTokenIndexFrom;
    uint256 curvePoolTokenIndexTo;
    uint256 curveMetaPoolTokenIndexFrom;
    uint256 curveMetaPoolTokenIndexTo;
}

struct CurveSwapStructData {
    address curvePool;
    address curveMetaPool;
    bytes swapBytesPool;
    bytes swapBytesMeta;
}

interface IWiseSecurity {

    function overallUSDBorrowHeartbeat(
        uint256 _nftId
    )
        external
        view
        returns (uint256 buffer);

    function checkBadDebt(
        uint256 _nftId
    )
        external;

    function getFullCollateralUSD(
        uint256 _nftId,
        address _poolToken
    )
        external
        view
        returns (uint256);

    function checksLiquidation(
        uint256 _nftIdLiquidate,
        address _tokenToPayback,
        uint256 _shareAmountToPay
    )
        external
        view;

    function getPositionBorrowAmount(
        uint256 _nftId,
        address _poolToken
    )
        external
        view
        returns (uint256);

    function getPositionLendingAmount(
        uint256 _nftId,
        address _poolToken
    )
        external
        view
        returns (uint256);

    function getLiveDebtratioNormalPool(
        uint256 _nftId
    )
        external
        view
        returns (uint256);

    function overallUSDCollateralsBare(
        uint256 _nftId
    )
        external
        view
        returns (uint256 amount);

    function FEE_MANAGER()
        external
        returns (address);

    function AAVE_HUB()
        external
        returns (address);

    function curveSecurityCheck(
        address _poolAddress
    )
        external;

    function prepareCurvePools(
        address _poolToken,
        CurveSwapStructData memory _curveSwapStructData,
        CurveSwapStructToken memory _curveSwapStructToken
    )
        external;

    function checksWithdraw(
        uint256 _nftId,
        address _caller,
        address _poolToken,
        uint256 _amount
    )
        external
        view;

    function checksBorrow(
        uint256 _nftId,
        address _caller,
        address _poolToken,
        uint256 _amount
    )
        external
        view;

    function checksSolelyWithdraw(
        uint256 _nftId,
        address _caller,
        address _poolToken,
        uint256 _amount
    )
        external
        view;

    function checkOwnerPosition(
        uint256 _nftId,
        address _caller
    )
        external
        view;

    function checksCollateralizeDeposit(
        uint256 _nftIdCaller,
        address _caller,
        address _poolAddress
    )
        external
        view;

    function calculateWishPercentage(
        uint256 _nftId,
        address _receiveToken,
        uint256 _paybackUSD,
        uint256 _maxFeeUSD,
        uint256 _baseRewardLiquidation
    )
        external
        view
        returns (uint256);

    function checksDecollateralizeDeposit(
        uint256 _nftIdCaller,
        address _poolToken
    )
        external
        view;

    function checkBorrowLimit(
        uint256 _nftId,
        address _poolToken,
        uint256 _amount
    )
        external
        view;

    function checkPositionLocked(
        uint256 _nftId,
        address _caller
    )
        external
        view;

    function checkPaybackLendingShares(
        uint256 _nftIdReceiver,
        uint256 _nftIdCaller,
        address _caller,
        address _poolToken,
        uint256 _amount
    )
        external
        view;

    function maxFeeUSD()
        external
        view
        returns (uint256);

    function maxFeeFarmUSD()
        external
        view
        returns (uint256);

    function baseRewardLiquidation()
        external
        view
        returns (uint256);

    function baseRewardLiquidationFarm()
        external
        view
        returns (uint256);

    function checksRegister(
        uint256 _nftId,
        address _caller
    )
        external
        view;

    function getLendingRate(
        address _poolToken
    )
        external
        view
        returns (uint256);
}
pragma solidity =0.8.21;

interface IPositionNFTs {

    function ownerOf(
        uint256 _nftId
    )
        external
        view
        returns (address);

    function getOwner(
        uint256 _nftId
    )
        external
        view
        returns (address);


    function totalSupply()
        external
        view
        returns (uint256);

    function reserved(
        address _owner
    )
        external
        view
        returns (uint256);

    function reservePosition()
        external;

    function mintPosition()
        external;

    function tokenOfOwnerByIndex(
        address _owner,
        uint256 _index
    )
        external
        view
        returns (uint256);

    function mintPositionForUser(
        address _user
    )
        external
        returns (uint256);

    function reservePositionForUser(
        address _user
    )
        external
        returns (uint256);

    function getApproved(
        uint256 _nftId
    )
        external
        returns (address);
}
pragma solidity =0.8.21;

import "./IERC20.sol";

interface IWETH is IERC20 {

    function deposit()
        external
        payable;

    function withdraw(
        uint256
    )
        external;
}
pragma solidity =0.8.21;

interface IERC20 {

    function totalSupply()
        external
        view
        returns (uint256);

    function balanceOf(
        address _account
    )
        external
        view
        returns (uint256);

    function transferFrom(
        address _sender,
        address _recipient,
        uint256 _amount
    )
        external
        returns (bool);

    function transfer(
        address _recipient,
        uint256 _amount
    )
        external
        returns (bool);

    function allowance(
        address owner,
        address spender
    )
        external
        view
        returns (uint256);

    function approve(
        address _spender,
        uint256 _amount
    )
        external
        returns (bool);

    function decimals()
        external
        view
        returns (uint8);

    event Transfer(
        address indexed from,
        address indexed to,
        uint256 value
    );

    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );

    event  Deposit(
        address indexed dst,
        uint wad
    );

    event  Withdrawal(
        address indexed src,
        uint wad
    );
}
