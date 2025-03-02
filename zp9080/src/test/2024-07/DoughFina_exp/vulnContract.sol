pragma solidity =0.8.24;

import { DoughCore } from "../libraries/DoughCore.sol";
import { IPool } from "@aave/core-v3/contracts/interfaces/IPool.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { FlashLoanReceiverBase, IPoolAddressesProvider } from "@aave/core-v3/contracts/flashloan/base/FlashLoanReceiverBase.sol";
import { IDoughIndex, IDoughRealHF, IDoughDsa, IConnectorParaswapFlashloan, ILiquidationManager, CustomError} from "../Interfaces.sol";

/**
* $$$$$$$\                                $$\             $$$$$$$$\ $$\                                                   
* $$  __$$\                               $$ |            $$  _____|\__|                                                  
* $$ |  $$ | $$$$$$\  $$\   $$\  $$$$$$\  $$$$$$$\        $$ |      $$\ $$$$$$$\   $$$$$$\  $$$$$$$\   $$$$$$$\  $$$$$$\  
* $$ |  $$ |$$  __$$\ $$ |  $$ |$$  __$$\ $$  __$$\       $$$$$\    $$ |$$  __$$\  \____$$\ $$  __$$\ $$  _____|$$  __$$\ 
* $$ |  $$ |$$ /  $$ |$$ |  $$ |$$ /  $$ |$$ |  $$ |      $$  __|   $$ |$$ |  $$ | $$$$$$$ |$$ |  $$ |$$ /      $$$$$$$$ |
* $$ |  $$ |$$ |  $$ |$$ |  $$ |$$ |  $$ |$$ |  $$ |      $$ |      $$ |$$ |  $$ |$$  __$$ |$$ |  $$ |$$ |      $$   ____|
* $$$$$$$  |\$$$$$$  |\$$$$$$  |\$$$$$$$ |$$ |  $$ |      $$ |      $$ |$$ |  $$ |\$$$$$$$ |$$ |  $$ |\$$$$$$$\ \$$$$$$$\ 
* \_______/  \______/  \______/  \____$$ |\__|  \__|      \__|      \__|\__|  \__| \_______|\__|  \__| \_______| \_______|
*                               $$\   $$ |                                                                                
*                               \$$$$$$  |                                                                                
*                                \______/                                                                                 
* 
* @title ConnectorDeleverageParaswap
* @notice This connector is used deleverage DSA positions in Aave V3 with Flashloan and Paraswap
* @custom:version 1.0 - Initial release - Connector ID 22
* @author Liberalite https://github.com/liberalite
* @custom:coauthor 0xboga https://github.com/0xboga
*/
contract ConnectorDeleverageParaswap is FlashLoanReceiverBase {
    using SafeERC20 for IERC20;

    /* ========== LAYOUT ========== */
    address public dsaOwner;
    address public doughIndex;
    address public immutable doughRealHF;
    address public immutable liqManager;

    struct FlashloanVars {
        address dsaAddress;
        address srcToken;
        address destToken;
        address paraSwapContract;
        address tokenTransferProxy;
        uint256 srcAmount;
        uint256 destAmount;
        bool opt; // deloop 100% or in multiple steps
        bool sent;
        bytes paraswapCallData;
        bytes[] multiTokenSwapData;
        address[] debtTokens;
        address[] collateralTokens;
        uint256[] debtAmounts;
        uint256[] debtRateMode;
        uint256[] collateralAmounts;
    }

    struct FlashloanData {
        address[] debtTokens;
        address[] collateralTokens;
        uint256[] debtAmounts;
        uint256[] debtRateMode;
        uint256[] collateralAmounts;
    }

    /**
     * @notice Constructor to set the Dough Index, Dough Real HF and Liquidation Manager contract addresses
     * @param _doughIndex The address of the DoughIndex contract
     * @param _doughRealHF The address of the DoughRealHF contract
     * @param _liqManager The address of the LiquidationManager contract
     */
    constructor(address _doughIndex, address _doughRealHF, address _liqManager) FlashLoanReceiverBase(IPoolAddressesProvider(DoughCore.AAVE_V3_POOL_ADDRESS_PROVIDER)) {
        if (_doughIndex == address(0)) revert CustomError("invalid _doughIndex");
        if (_doughRealHF == address(0)) revert CustomError("invalid _doughRealHF");
        if (_liqManager == address(0)) revert CustomError("invalid _liqManager");
        doughIndex = _doughIndex;
        doughRealHF = _doughRealHF;
        liqManager = _liqManager;
    }

    function _getParaswapData(bytes memory _swapData) private pure returns (address, address, uint256, uint256, address, address, bytes memory) {
        // srcToken, destToken, srcAmount, destAmount, paraSwapContract, tokenTransferProxy, paraswapCallData
        return abi.decode(_swapData, (address, address, uint256, uint256, address, address, bytes));
    }

    // delegate Call
    function delegateDoughCall(uint256, address, uint256, bool _opt, bytes[] calldata _swapData) external {
        uint256 healthFactor = IDoughRealHF(doughRealHF).getDoughHFData(address(this));
        if (healthFactor > IDoughIndex(doughIndex).minDeleveragingRatio()) {
            bool isFlaggedForLiquidation = ILiquidationManager(liqManager).dsaLiquidationStatus(address(this));
            if(!isFlaggedForLiquidation) revert CustomError("Above minDeleveragingRatio");
        }
        deloopDebtPositions(_opt, _swapData);
    }

    function deloopDebtPositions (bool _opt, bytes[] memory _swapData) private {
        // get connectorFlashloan address
        address _connectorFlashloan = IDoughIndex(doughIndex).getDoughConnector(DoughCore.CONNECTOR_ID22);
        if (_connectorFlashloan == address(0)) revert CustomError("Unregistered Flashloan Connector");

        FlashloanData memory data;

        if(_opt) {
            (data.debtTokens, data.debtAmounts, data.debtRateMode, data.collateralTokens, data.collateralAmounts) = calculateCollateralAndDebtBeforeFlashLoanData();
            IConnectorParaswapFlashloan(_connectorFlashloan).flashloanReq(_opt, data.debtTokens, data.debtAmounts, data.debtRateMode, data.collateralTokens, data.collateralAmounts, _swapData);
        } else {
            (data.debtTokens, data.debtAmounts, data.debtRateMode, data.collateralTokens, data.collateralAmounts) = calculateCollateralAndDebtFromSwapData(_swapData);
            IConnectorParaswapFlashloan(_connectorFlashloan).flashloanReq(_opt, data.debtTokens, data.debtAmounts, data.debtRateMode, data.collateralTokens, data.collateralAmounts, _swapData);
        }
    }

    function flashloanReq(bool _opt, address[] memory debtTokens, uint256[] memory debtAmounts, uint256[] memory debtRateMode, address[] memory collateralTokens, uint256[] memory collateralAmounts, bytes[] memory swapData) external {
        bytes memory data = abi.encode(_opt, msg.sender, collateralTokens, collateralAmounts, swapData);
        IPool(address(POOL)).flashLoan(address(this), debtTokens, debtAmounts, debtRateMode, address(this), data, 0);
    }

    function calculateCollateralAndDebtBeforeFlashLoanData() private returns (address[] memory, uint256[] memory, uint256[] memory, address[] memory, uint256[] memory) {
        address[] memory whitelistedTokenList = IDoughIndex(doughIndex).getWhitelistedTokenList();
        uint256 length = whitelistedTokenList.length;

        address[] memory debtTokens = new address[](length);
        address[] memory collateralTokens = new address[](length);
        uint256[] memory collateralAmounts = new uint256[](length);
        uint256[] memory debtAmounts = new uint256[](length);
        uint256[] memory debtRateMode = new uint256[](length);

        uint256 actualAddedCollateral = 0;
        uint256 actualAdded = 0;

        for (uint256 i = 0; i < length;) {
            address tokenAddress = whitelistedTokenList[i];
            (uint256 currentATokenBalance, , uint256 currentVariableDebt, , , , , ,) = DoughCore._I_AAVE_V3_DATA_PROVIDER.getUserReserveData(tokenAddress, address(this));

            if (currentATokenBalance > 0) {
                if (currentVariableDebt > 0) {
                    if (currentATokenBalance >= currentVariableDebt) {
                        // Repay all debt with collateral
                        DoughCore.repayWithATokens(tokenAddress, currentVariableDebt);
                        IDoughIndex(doughIndex).updateBorrowDate(DoughCore.CONNECTOR_ID22, 0, address(this), tokenAddress);

                        uint256 remainingCollateral = currentATokenBalance - currentVariableDebt;
                        if (remainingCollateral > 0) {
                            // Leave 1 wei of collateral to avoid over-withdrawal
                            collateralTokens[actualAddedCollateral] = tokenAddress;
                            collateralAmounts[actualAddedCollateral] = remainingCollateral - 1;
                            actualAddedCollateral++;
                        }
                    } else {
                        // Partial repayment, remaining debt for flash loan
                        DoughCore.repayWithATokens(tokenAddress, currentATokenBalance);
                        uint256 remainingDebt = currentVariableDebt - currentATokenBalance;
                        debtTokens[actualAdded] = tokenAddress;
                        debtAmounts[actualAdded] = remainingDebt + 1; // Request 1 extra wei to ensure full repayment
                        debtRateMode[actualAdded] = DoughCore.FLASHLOAN_RATE_MODE;
                        actualAdded++;
                    }
                } else {
                    // No debt, track collateral
                    if (currentATokenBalance > 1) {
                        // Leave 1 wei of collateral to avoid over-withdrawal
                        collateralTokens[actualAddedCollateral] = tokenAddress;
                        collateralAmounts[actualAddedCollateral] = currentATokenBalance - 1;
                        actualAddedCollateral++;
                    }
                }
            } else if (currentVariableDebt > 0) {
                // No collateral, debt for flash loan
                debtTokens[actualAdded] = tokenAddress;
                debtAmounts[actualAdded] = currentVariableDebt + 1; // Request 1 extra wei to ensure full repayment
                debtRateMode[actualAdded] = DoughCore.FLASHLOAN_RATE_MODE;
                actualAdded++;
            }

            unchecked { i++; }
        }

        // Resize arrays to actual size
        assembly {
            mstore(debtTokens, actualAdded)
            mstore(debtAmounts, actualAdded)
            mstore(debtRateMode, actualAdded)
            mstore(collateralTokens, actualAddedCollateral)
            mstore(collateralAmounts, actualAddedCollateral)
        }

        return (debtTokens, debtAmounts, debtRateMode, collateralTokens, collateralAmounts);
    }

    function calculateCollateralAndDebtFromSwapData(bytes[] memory _swapData) private returns (address[] memory, uint256[] memory, uint256[] memory, address[] memory, uint256[] memory) {
        address[] memory whitelistedTokenList = IDoughIndex(doughIndex).getWhitelistedTokenList();
        uint256 length = whitelistedTokenList.length;

        repayWithCollateral(length, whitelistedTokenList);

        FlashloanVars memory flashloanVars;
        (flashloanVars.debtTokens, flashloanVars.debtAmounts, flashloanVars.debtRateMode, flashloanVars.collateralTokens, flashloanVars.collateralAmounts) = extractDeloopFromSwapData(_swapData);

        return (flashloanVars.debtTokens, flashloanVars.debtAmounts, flashloanVars.debtRateMode, flashloanVars.collateralTokens, flashloanVars.collateralAmounts);
    }

    function extractDeloopFromSwapData(bytes[] memory _swapData) private pure returns (address[] memory, uint256[] memory, uint256[] memory, address[] memory, uint256[] memory) {
        uint256 length = _swapData.length;
        
        address[] memory debtTokens = new address[](length);
        uint256[] memory debtAmounts = new uint256[](length);
        uint256[] memory debtRateMode = new uint256[](length);
        address[] memory collateralTokens = new address[](length);
        uint256[] memory collateralAmounts = new uint256[](length);
        
        uint256 actualAdded = 0;

        FlashloanVars memory flashloanVars;
        for (uint i = 0; i < _swapData.length;) {
            (flashloanVars.srcToken, flashloanVars.destToken, flashloanVars.srcAmount, flashloanVars.destAmount,,,) = _getParaswapData(_swapData[i]);
            debtTokens[actualAdded] = flashloanVars.destToken;
            debtAmounts[actualAdded] = flashloanVars.destAmount - (flashloanVars.destAmount / 1000); // Request 1 extra wei to ensure full repayment
            debtRateMode[actualAdded] = DoughCore.FLASHLOAN_RATE_MODE;
            collateralTokens[actualAdded] = flashloanVars.srcToken;
            collateralAmounts[actualAdded] = flashloanVars.srcAmount; // add 10% buffer for slippage
            actualAdded++;
            unchecked { i++; }
        }

        // Resize arrays to actual size
        assembly {
            mstore(debtTokens, actualAdded)
            mstore(debtAmounts, actualAdded)
            mstore(debtRateMode, actualAdded)
            mstore(collateralTokens, actualAdded)
            mstore(collateralAmounts, actualAdded)
        }

        return (debtTokens, debtAmounts, debtRateMode, collateralTokens, collateralAmounts);
    }

    function repayWithCollateral(uint256 length, address[] memory whitelistedTokenList) private {
        for (uint256 i = 0; i < length;) {
            address tokenAddress = whitelistedTokenList[i];
            (uint256 currentATokenBalance, , uint256 currentVariableDebt, , , , , ,) = DoughCore._I_AAVE_V3_DATA_PROVIDER.getUserReserveData(tokenAddress, address(this));

            if (currentATokenBalance > 0) {
                if (currentVariableDebt > 0) {
                    if (currentATokenBalance >= currentVariableDebt) {
                        // Repay all debt with collateral
                        DoughCore.repayWithATokens(tokenAddress, currentVariableDebt);
                        IDoughIndex(doughIndex).updateBorrowDate(DoughCore.CONNECTOR_ID22, 0, address(this), tokenAddress);
                    } else {
                        // Partial repayment, remaining debt for flash loan
                        DoughCore.repayWithATokens(tokenAddress, currentATokenBalance);
                    }
                }
            }

            unchecked { i++; }
        }
    }

    function executeOperation(address[] memory assets, uint256[] memory amounts, uint256[] memory premiums, address initiator, bytes calldata data) external override returns (bool) {
        if (initiator != address(this)) revert CustomError("not-same-sender");
        if (msg.sender != address(POOL)) revert CustomError("not-aave-sender");

        FlashloanVars memory flashloanVars;
        (flashloanVars.opt, flashloanVars.dsaAddress, flashloanVars.collateralTokens, flashloanVars.collateralAmounts, flashloanVars.multiTokenSwapData) = abi.decode(data, (bool, address, address[], uint256[], bytes[]));

        deloopInOneOrMultipleTransactions(flashloanVars.opt, flashloanVars.dsaAddress, assets, amounts, premiums, flashloanVars.collateralTokens, flashloanVars.collateralAmounts, flashloanVars.multiTokenSwapData);

        return true;
    }

    function deloopInOneOrMultipleTransactions(bool opt, address _dsaAddress, address[] memory assets, uint256[] memory amounts, uint256[] memory premiums, address[] memory collateralTokens, uint256[] memory collateralAmounts, bytes[] memory multiTokenSwapData) private {
        // Repay all flashloan assets or withdraw all collaterals
        repayAllDebtAssetsWithFlashLoan(opt, _dsaAddress, assets, amounts);

        // Extract all collaterals
        extractAllCollaterals(_dsaAddress, collateralTokens, collateralAmounts); 

        // Deloop all collaterals
        deloopAllCollaterals(multiTokenSwapData);

        // Repay all flashloan assets or withdraw all collaterals
        repayFlashloansAndTransferToTreasury(opt, _dsaAddress, assets, amounts, premiums);
    }

    function repayFlashloansAndTransferToTreasury(bool opt, address _dsaAddress, address[] memory assets, uint256[] memory amounts, uint256[] memory premiums) private {
        address[] memory whitelistedTokenList = IDoughIndex(doughIndex).getWhitelistedTokenList();
        address treasury = IDoughIndex(doughIndex).treasury();

        for (uint i = 0; i < whitelistedTokenList.length; i++) {
            address token = whitelistedTokenList[i];
            uint256 balance = IERC20(token).balanceOf(address(this));

            if (balance > 0) {
                // Initialize the transfer amount to the full balance
                uint256 transferAmount = balance;

                // Look through the assets to check if this token was involved in a flash loan
                for (uint j = 0; j < assets.length; j++) {
                    if (token == assets[j]) {
                        uint256 repaymentTotal = amounts[j] + premiums[j];
                        if (balance >= repaymentTotal) {
                            transferAmount = balance - repaymentTotal;
                        }
                        IERC20(token).safeIncreaseAllowance(address(POOL), repaymentTotal);
                        break;  // Break once the token is found in the assets array
                    }
                }

                // Perform the transfer if there is any amount to transfer
                if (transferAmount > 0) {
                    if(opt) {
                        // Transfer to treasury
                        IERC20(token).safeTransfer(treasury, transferAmount);
                    } else {
                        // Supply to AaveV3
                        IERC20(token).safeIncreaseAllowance(DoughCore.AAVE_V3_POOL_ADDRESS, transferAmount);
                        DoughCore._I_AAVE_V3_POOL.supply(token, transferAmount, _dsaAddress, 0);
                    }
                }
            }
        }
    }

    function extractAllCollaterals(address dsaAddress, address[] memory collateralTokens, uint256[] memory collateralAmounts) private {
        // Repay all asset flash loan
        for (uint i = 0; i < collateralTokens.length;) {
            IDoughDsa(dsaAddress).executeAction(DoughCore.CONNECTOR_ID22, collateralTokens[i], 0, collateralTokens[i], collateralAmounts[i], 1);
            IERC20(collateralTokens[i]).safeTransferFrom(dsaAddress, address(this), collateralAmounts[i]);
            unchecked { i++; }
        }
    }

    function deloopAllCollaterals(bytes[] memory multiTokenSwapData) private {        
        FlashloanVars memory flashloanVars;

        for (uint i = 0; i < multiTokenSwapData.length;) {
            // Deloop
            (flashloanVars.srcToken, flashloanVars.destToken, flashloanVars.srcAmount, flashloanVars.destAmount, flashloanVars.paraSwapContract, flashloanVars.tokenTransferProxy, flashloanVars.paraswapCallData) = _getParaswapData(multiTokenSwapData[i]);

            // using ParaSwap
            IERC20(flashloanVars.srcToken).safeIncreaseAllowance(flashloanVars.tokenTransferProxy, flashloanVars.srcAmount);
            (flashloanVars.sent, ) = flashloanVars.paraSwapContract.call(flashloanVars.paraswapCallData);
            if (!flashloanVars.sent) revert CustomError("ParaSwap deloop failed");

            unchecked { i++; }
        }
    }

    function repayAllDebtAssetsWithFlashLoan(bool opt, address dsaAddress, address[] memory assets, uint256[] memory amounts) private {
        for (uint i = 0; i < assets.length;) {
            IERC20(assets[i]).safeIncreaseAllowance(dsaAddress, amounts[i]);
            IDoughDsa(dsaAddress).executeAction(DoughCore.CONNECTOR_ID22, assets[i], amounts[i], assets[i], 0, 1);
            if(opt) IDoughIndex(doughIndex).updateBorrowDate(DoughCore.CONNECTOR_ID22, 0, dsaAddress, assets[i]);
            unchecked { i++; }
        }
    }

    /**
     * @notice Function to set new dough index address after upgrade
     * @param _newDoughIndex The address of the new DoughIndex contract
     * @dev The new DoughIndex address should not be the zero address
     * @dev Only the multisig of DoughIndex can call this function
     */
    function setNewDoughIndex(address _newDoughIndex) external {
        if (msg.sender != IDoughIndex(doughIndex).multisig()) revert CustomError("not multisig of doughIndex");
        if (_newDoughIndex == address(0)) revert CustomError("invalid _newDoughIndex");
        doughIndex = _newDoughIndex;
    }

    /** @notice Function to get the Dough Multisig address */
    function getDoughMultisig() external view returns (address) {
        return IDoughIndex(doughIndex).multisig();
    }

    /** @notice Function to get the Dough Index address */
    function getDoughIndex() external view returns (address) {
        return doughIndex;
    }

    /**
    * @notice Function to withdraw accidentaly sent ETH/ERC20 tokens to the connector
    * @param _asset The address of the ETH/ERC20 token
    * @param _treasury The address of the treasury
    * @param _amount The amount of ETH/ERC20 token to withdraw
    */
    function withdrawToken(address _asset, address _treasury, uint256 _amount) external {
        if (msg.sender != IDoughIndex(doughIndex).multisig()) revert CustomError("not multisig of doughIndex");
        if (_treasury == address(0)) revert CustomError("invalid _treasury");
        if (_amount == 0) revert CustomError("must be greater than zero");
        if (_asset == DoughCore.ETH) {
            payable(_treasury).transfer(_amount);
        } else {
            uint256 balanceOfToken = IERC20(_asset).balanceOf(address(this));
            uint256 transferAmount = _amount;
            if (_amount > balanceOfToken) {
                transferAmount = balanceOfToken;
            }
            IERC20(_asset).safeTransfer(_treasury, transferAmount);
        }
    }

}
pragma solidity ^0.8.0;

import {IFlashLoanReceiver} from '../interfaces/IFlashLoanReceiver.sol';
import {IPoolAddressesProvider} from '../../interfaces/IPoolAddressesProvider.sol';
import {IPool} from '../../interfaces/IPool.sol';

/**
 * @title FlashLoanReceiverBase
 * @author Aave
 * @notice Base contract to develop a flashloan-receiver contract.
 */
abstract contract FlashLoanReceiverBase is IFlashLoanReceiver {
  IPoolAddressesProvider public immutable override ADDRESSES_PROVIDER;
  IPool public immutable override POOL;

  constructor(IPoolAddressesProvider provider) {
    ADDRESSES_PROVIDER = provider;
    POOL = IPool(provider.getPool());
  }
}
pragma solidity ^0.8.0;

import {IPoolAddressesProvider} from '../../interfaces/IPoolAddressesProvider.sol';
import {IPool} from '../../interfaces/IPool.sol';

/**
 * @title IFlashLoanReceiver
 * @author Aave
 * @notice Defines the basic interface of a flashloan-receiver contract.
 * @dev Implement this interface to develop a flashloan-compatible flashLoanReceiver contract
 */
interface IFlashLoanReceiver {
  /**
   * @notice Executes an operation after receiving the flash-borrowed assets
   * @dev Ensure that the contract can return the debt + premium, e.g., has
   *      enough funds to repay and has approved the Pool to pull the total amount
   * @param assets The addresses of the flash-borrowed assets
   * @param amounts The amounts of the flash-borrowed assets
   * @param premiums The fee of each flash-borrowed asset
   * @param initiator The address of the flashloan initiator
   * @param params The byte-encoded params passed when initiating the flashloan
   * @return True if the execution of the operation succeeds, false otherwise
   */
  function executeOperation(
    address[] calldata assets,
    uint256[] calldata amounts,
    uint256[] calldata premiums,
    address initiator,
    bytes calldata params
  ) external returns (bool);

  function ADDRESSES_PROVIDER() external view returns (IPoolAddressesProvider);

  function POOL() external view returns (IPool);
}
pragma solidity ^0.8.0;

import {IPoolAddressesProvider} from './IPoolAddressesProvider.sol';
import {DataTypes} from '../protocol/libraries/types/DataTypes.sol';

/**
 * @title IPool
 * @author Aave
 * @notice Defines the basic interface for an Aave Pool.
 */
interface IPool {
  /**
   * @dev Emitted on mintUnbacked()
   * @param reserve The address of the underlying asset of the reserve
   * @param user The address initiating the supply
   * @param onBehalfOf The beneficiary of the supplied assets, receiving the aTokens
   * @param amount The amount of supplied assets
   * @param referralCode The referral code used
   */
  event MintUnbacked(
    address indexed reserve,
    address user,
    address indexed onBehalfOf,
    uint256 amount,
    uint16 indexed referralCode
  );

  /**
   * @dev Emitted on backUnbacked()
   * @param reserve The address of the underlying asset of the reserve
   * @param backer The address paying for the backing
   * @param amount The amount added as backing
   * @param fee The amount paid in fees
   */
  event BackUnbacked(address indexed reserve, address indexed backer, uint256 amount, uint256 fee);

  /**
   * @dev Emitted on supply()
   * @param reserve The address of the underlying asset of the reserve
   * @param user The address initiating the supply
   * @param onBehalfOf The beneficiary of the supply, receiving the aTokens
   * @param amount The amount supplied
   * @param referralCode The referral code used
   */
  event Supply(
    address indexed reserve,
    address user,
    address indexed onBehalfOf,
    uint256 amount,
    uint16 indexed referralCode
  );

  /**
   * @dev Emitted on withdraw()
   * @param reserve The address of the underlying asset being withdrawn
   * @param user The address initiating the withdrawal, owner of aTokens
   * @param to The address that will receive the underlying
   * @param amount The amount to be withdrawn
   */
  event Withdraw(address indexed reserve, address indexed user, address indexed to, uint256 amount);

  /**
   * @dev Emitted on borrow() and flashLoan() when debt needs to be opened
   * @param reserve The address of the underlying asset being borrowed
   * @param user The address of the user initiating the borrow(), receiving the funds on borrow() or just
   * initiator of the transaction on flashLoan()
   * @param onBehalfOf The address that will be getting the debt
   * @param amount The amount borrowed out
   * @param interestRateMode The rate mode: 1 for Stable, 2 for Variable
   * @param borrowRate The numeric rate at which the user has borrowed, expressed in ray
   * @param referralCode The referral code used
   */
  event Borrow(
    address indexed reserve,
    address user,
    address indexed onBehalfOf,
    uint256 amount,
    DataTypes.InterestRateMode interestRateMode,
    uint256 borrowRate,
    uint16 indexed referralCode
  );

  /**
   * @dev Emitted on repay()
   * @param reserve The address of the underlying asset of the reserve
   * @param user The beneficiary of the repayment, getting his debt reduced
   * @param repayer The address of the user initiating the repay(), providing the funds
   * @param amount The amount repaid
   * @param useATokens True if the repayment is done using aTokens, `false` if done with underlying asset directly
   */
  event Repay(
    address indexed reserve,
    address indexed user,
    address indexed repayer,
    uint256 amount,
    bool useATokens
  );

  /**
   * @dev Emitted on swapBorrowRateMode()
   * @param reserve The address of the underlying asset of the reserve
   * @param user The address of the user swapping his rate mode
   * @param interestRateMode The current interest rate mode of the position being swapped: 1 for Stable, 2 for Variable
   */
  event SwapBorrowRateMode(
    address indexed reserve,
    address indexed user,
    DataTypes.InterestRateMode interestRateMode
  );

  /**
   * @dev Emitted on borrow(), repay() and liquidationCall() when using isolated assets
   * @param asset The address of the underlying asset of the reserve
   * @param totalDebt The total isolation mode debt for the reserve
   */
  event IsolationModeTotalDebtUpdated(address indexed asset, uint256 totalDebt);

  /**
   * @dev Emitted when the user selects a certain asset category for eMode
   * @param user The address of the user
   * @param categoryId The category id
   */
  event UserEModeSet(address indexed user, uint8 categoryId);

  /**
   * @dev Emitted on setUserUseReserveAsCollateral()
   * @param reserve The address of the underlying asset of the reserve
   * @param user The address of the user enabling the usage as collateral
   */
  event ReserveUsedAsCollateralEnabled(address indexed reserve, address indexed user);

  /**
   * @dev Emitted on setUserUseReserveAsCollateral()
   * @param reserve The address of the underlying asset of the reserve
   * @param user The address of the user enabling the usage as collateral
   */
  event ReserveUsedAsCollateralDisabled(address indexed reserve, address indexed user);

  /**
   * @dev Emitted on rebalanceStableBorrowRate()
   * @param reserve The address of the underlying asset of the reserve
   * @param user The address of the user for which the rebalance has been executed
   */
  event RebalanceStableBorrowRate(address indexed reserve, address indexed user);

  /**
   * @dev Emitted on flashLoan()
   * @param target The address of the flash loan receiver contract
   * @param initiator The address initiating the flash loan
   * @param asset The address of the asset being flash borrowed
   * @param amount The amount flash borrowed
   * @param interestRateMode The flashloan mode: 0 for regular flashloan, 1 for Stable debt, 2 for Variable debt
   * @param premium The fee flash borrowed
   * @param referralCode The referral code used
   */
  event FlashLoan(
    address indexed target,
    address initiator,
    address indexed asset,
    uint256 amount,
    DataTypes.InterestRateMode interestRateMode,
    uint256 premium,
    uint16 indexed referralCode
  );

  /**
   * @dev Emitted when a borrower is liquidated.
   * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of the liquidation
   * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
   * @param user The address of the borrower getting liquidated
   * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
   * @param liquidatedCollateralAmount The amount of collateral received by the liquidator
   * @param liquidator The address of the liquidator
   * @param receiveAToken True if the liquidators wants to receive the collateral aTokens, `false` if he wants
   * to receive the underlying collateral asset directly
   */
  event LiquidationCall(
    address indexed collateralAsset,
    address indexed debtAsset,
    address indexed user,
    uint256 debtToCover,
    uint256 liquidatedCollateralAmount,
    address liquidator,
    bool receiveAToken
  );

  /**
   * @dev Emitted when the state of a reserve is updated.
   * @param reserve The address of the underlying asset of the reserve
   * @param liquidityRate The next liquidity rate
   * @param stableBorrowRate The next stable borrow rate
   * @param variableBorrowRate The next variable borrow rate
   * @param liquidityIndex The next liquidity index
   * @param variableBorrowIndex The next variable borrow index
   */
  event ReserveDataUpdated(
    address indexed reserve,
    uint256 liquidityRate,
    uint256 stableBorrowRate,
    uint256 variableBorrowRate,
    uint256 liquidityIndex,
    uint256 variableBorrowIndex
  );

  /**
   * @dev Emitted when the protocol treasury receives minted aTokens from the accrued interest.
   * @param reserve The address of the reserve
   * @param amountMinted The amount minted to the treasury
   */
  event MintedToTreasury(address indexed reserve, uint256 amountMinted);

  /**
   * @notice Mints an `amount` of aTokens to the `onBehalfOf`
   * @param asset The address of the underlying asset to mint
   * @param amount The amount to mint
   * @param onBehalfOf The address that will receive the aTokens
   * @param referralCode Code used to register the integrator originating the operation, for potential rewards.
   *   0 if the action is executed directly by the user, without any middle-man
   */
  function mintUnbacked(
    address asset,
    uint256 amount,
    address onBehalfOf,
    uint16 referralCode
  ) external;

  /**
   * @notice Back the current unbacked underlying with `amount` and pay `fee`.
   * @param asset The address of the underlying asset to back
   * @param amount The amount to back
   * @param fee The amount paid in fees
   * @return The backed amount
   */
  function backUnbacked(address asset, uint256 amount, uint256 fee) external returns (uint256);

  /**
   * @notice Supplies an `amount` of underlying asset into the reserve, receiving in return overlying aTokens.
   * - E.g. User supplies 100 USDC and gets in return 100 aUSDC
   * @param asset The address of the underlying asset to supply
   * @param amount The amount to be supplied
   * @param onBehalfOf The address that will receive the aTokens, same as msg.sender if the user
   *   wants to receive them on his own wallet, or a different address if the beneficiary of aTokens
   *   is a different wallet
   * @param referralCode Code used to register the integrator originating the operation, for potential rewards.
   *   0 if the action is executed directly by the user, without any middle-man
   */
  function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

  /**
   * @notice Supply with transfer approval of asset to be supplied done via permit function
   * see: https://eips.ethereum.org/EIPS/eip-2612 and https://eips.ethereum.org/EIPS/eip-713
   * @param asset The address of the underlying asset to supply
   * @param amount The amount to be supplied
   * @param onBehalfOf The address that will receive the aTokens, same as msg.sender if the user
   *   wants to receive them on his own wallet, or a different address if the beneficiary of aTokens
   *   is a different wallet
   * @param deadline The deadline timestamp that the permit is valid
   * @param referralCode Code used to register the integrator originating the operation, for potential rewards.
   *   0 if the action is executed directly by the user, without any middle-man
   * @param permitV The V parameter of ERC712 permit sig
   * @param permitR The R parameter of ERC712 permit sig
   * @param permitS The S parameter of ERC712 permit sig
   */
  function supplyWithPermit(
    address asset,
    uint256 amount,
    address onBehalfOf,
    uint16 referralCode,
    uint256 deadline,
    uint8 permitV,
    bytes32 permitR,
    bytes32 permitS
  ) external;

  /**
   * @notice Withdraws an `amount` of underlying asset from the reserve, burning the equivalent aTokens owned
   * E.g. User has 100 aUSDC, calls withdraw() and receives 100 USDC, burning the 100 aUSDC
   * @param asset The address of the underlying asset to withdraw
   * @param amount The underlying amount to be withdrawn
   *   - Send the value type(uint256).max in order to withdraw the whole aToken balance
   * @param to The address that will receive the underlying, same as msg.sender if the user
   *   wants to receive it on his own wallet, or a different address if the beneficiary is a
   *   different wallet
   * @return The final amount withdrawn
   */
  function withdraw(address asset, uint256 amount, address to) external returns (uint256);

  /**
   * @notice Allows users to borrow a specific `amount` of the reserve underlying asset, provided that the borrower
   * already supplied enough collateral, or he was given enough allowance by a credit delegator on the
   * corresponding debt token (StableDebtToken or VariableDebtToken)
   * - E.g. User borrows 100 USDC passing as `onBehalfOf` his own address, receiving the 100 USDC in his wallet
   *   and 100 stable/variable debt tokens, depending on the `interestRateMode`
   * @param asset The address of the underlying asset to borrow
   * @param amount The amount to be borrowed
   * @param interestRateMode The interest rate mode at which the user wants to borrow: 1 for Stable, 2 for Variable
   * @param referralCode The code used to register the integrator originating the operation, for potential rewards.
   *   0 if the action is executed directly by the user, without any middle-man
   * @param onBehalfOf The address of the user who will receive the debt. Should be the address of the borrower itself
   * calling the function if he wants to borrow against his own collateral, or the address of the credit delegator
   * if he has been given credit delegation allowance
   */
  function borrow(
    address asset,
    uint256 amount,
    uint256 interestRateMode,
    uint16 referralCode,
    address onBehalfOf
  ) external;

  /**
   * @notice Repays a borrowed `amount` on a specific reserve, burning the equivalent debt tokens owned
   * - E.g. User repays 100 USDC, burning 100 variable/stable debt tokens of the `onBehalfOf` address
   * @param asset The address of the borrowed underlying asset previously borrowed
   * @param amount The amount to repay
   * - Send the value type(uint256).max in order to repay the whole debt for `asset` on the specific `debtMode`
   * @param interestRateMode The interest rate mode at of the debt the user wants to repay: 1 for Stable, 2 for Variable
   * @param onBehalfOf The address of the user who will get his debt reduced/removed. Should be the address of the
   * user calling the function if he wants to reduce/remove his own debt, or the address of any other
   * other borrower whose debt should be removed
   * @return The final amount repaid
   */
  function repay(
    address asset,
    uint256 amount,
    uint256 interestRateMode,
    address onBehalfOf
  ) external returns (uint256);

  /**
   * @notice Repay with transfer approval of asset to be repaid done via permit function
   * see: https://eips.ethereum.org/EIPS/eip-2612 and https://eips.ethereum.org/EIPS/eip-713
   * @param asset The address of the borrowed underlying asset previously borrowed
   * @param amount The amount to repay
   * - Send the value type(uint256).max in order to repay the whole debt for `asset` on the specific `debtMode`
   * @param interestRateMode The interest rate mode at of the debt the user wants to repay: 1 for Stable, 2 for Variable
   * @param onBehalfOf Address of the user who will get his debt reduced/removed. Should be the address of the
   * user calling the function if he wants to reduce/remove his own debt, or the address of any other
   * other borrower whose debt should be removed
   * @param deadline The deadline timestamp that the permit is valid
   * @param permitV The V parameter of ERC712 permit sig
   * @param permitR The R parameter of ERC712 permit sig
   * @param permitS The S parameter of ERC712 permit sig
   * @return The final amount repaid
   */
  function repayWithPermit(
    address asset,
    uint256 amount,
    uint256 interestRateMode,
    address onBehalfOf,
    uint256 deadline,
    uint8 permitV,
    bytes32 permitR,
    bytes32 permitS
  ) external returns (uint256);

  /**
   * @notice Repays a borrowed `amount` on a specific reserve using the reserve aTokens, burning the
   * equivalent debt tokens
   * - E.g. User repays 100 USDC using 100 aUSDC, burning 100 variable/stable debt tokens
   * @dev  Passing uint256.max as amount will clean up any residual aToken dust balance, if the user aToken
   * balance is not enough to cover the whole debt
   * @param asset The address of the borrowed underlying asset previously borrowed
   * @param amount The amount to repay
   * - Send the value type(uint256).max in order to repay the whole debt for `asset` on the specific `debtMode`
   * @param interestRateMode The interest rate mode at of the debt the user wants to repay: 1 for Stable, 2 for Variable
   * @return The final amount repaid
   */
  function repayWithATokens(
    address asset,
    uint256 amount,
    uint256 interestRateMode
  ) external returns (uint256);

  /**
   * @notice Allows a borrower to swap his debt between stable and variable mode, or vice versa
   * @param asset The address of the underlying asset borrowed
   * @param interestRateMode The current interest rate mode of the position being swapped: 1 for Stable, 2 for Variable
   */
  function swapBorrowRateMode(address asset, uint256 interestRateMode) external;

  /**
   * @notice Rebalances the stable interest rate of a user to the current stable rate defined on the reserve.
   * - Users can be rebalanced if the following conditions are satisfied:
   *     1. Usage ratio is above 95%
   *     2. the current supply APY is below REBALANCE_UP_THRESHOLD * maxVariableBorrowRate, which means that too
   *        much has been borrowed at a stable rate and suppliers are not earning enough
   * @param asset The address of the underlying asset borrowed
   * @param user The address of the user to be rebalanced
   */
  function rebalanceStableBorrowRate(address asset, address user) external;

  /**
   * @notice Allows suppliers to enable/disable a specific supplied asset as collateral
   * @param asset The address of the underlying asset supplied
   * @param useAsCollateral True if the user wants to use the supply as collateral, false otherwise
   */
  function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external;

  /**
   * @notice Function to liquidate a non-healthy position collateral-wise, with Health Factor below 1
   * - The caller (liquidator) covers `debtToCover` amount of debt of the user getting liquidated, and receives
   *   a proportionally amount of the `collateralAsset` plus a bonus to cover market risk
   * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of the liquidation
   * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
   * @param user The address of the borrower getting liquidated
   * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
   * @param receiveAToken True if the liquidators wants to receive the collateral aTokens, `false` if he wants
   * to receive the underlying collateral asset directly
   */
  function liquidationCall(
    address collateralAsset,
    address debtAsset,
    address user,
    uint256 debtToCover,
    bool receiveAToken
  ) external;

  /**
   * @notice Allows smartcontracts to access the liquidity of the pool within one transaction,
   * as long as the amount taken plus a fee is returned.
   * @dev IMPORTANT There are security concerns for developers of flashloan receiver contracts that must be kept
   * into consideration. For further details please visit https://docs.aave.com/developers/
   * @param receiverAddress The address of the contract receiving the funds, implementing IFlashLoanReceiver interface
   * @param assets The addresses of the assets being flash-borrowed
   * @param amounts The amounts of the assets being flash-borrowed
   * @param interestRateModes Types of the debt to open if the flash loan is not returned:
   *   0 -> Don't open any debt, just revert if funds can't be transferred from the receiver
   *   1 -> Open debt at stable rate for the value of the amount flash-borrowed to the `onBehalfOf` address
   *   2 -> Open debt at variable rate for the value of the amount flash-borrowed to the `onBehalfOf` address
   * @param onBehalfOf The address  that will receive the debt in the case of using on `modes` 1 or 2
   * @param params Variadic packed params to pass to the receiver as extra information
   * @param referralCode The code used to register the integrator originating the operation, for potential rewards.
   *   0 if the action is executed directly by the user, without any middle-man
   */
  function flashLoan(
    address receiverAddress,
    address[] calldata assets,
    uint256[] calldata amounts,
    uint256[] calldata interestRateModes,
    address onBehalfOf,
    bytes calldata params,
    uint16 referralCode
  ) external;

  /**
   * @notice Allows smartcontracts to access the liquidity of the pool within one transaction,
   * as long as the amount taken plus a fee is returned.
   * @dev IMPORTANT There are security concerns for developers of flashloan receiver contracts that must be kept
   * into consideration. For further details please visit https://docs.aave.com/developers/
   * @param receiverAddress The address of the contract receiving the funds, implementing IFlashLoanSimpleReceiver interface
   * @param asset The address of the asset being flash-borrowed
   * @param amount The amount of the asset being flash-borrowed
   * @param params Variadic packed params to pass to the receiver as extra information
   * @param referralCode The code used to register the integrator originating the operation, for potential rewards.
   *   0 if the action is executed directly by the user, without any middle-man
   */
  function flashLoanSimple(
    address receiverAddress,
    address asset,
    uint256 amount,
    bytes calldata params,
    uint16 referralCode
  ) external;

  /**
   * @notice Returns the user account data across all the reserves
   * @param user The address of the user
   * @return totalCollateralBase The total collateral of the user in the base currency used by the price feed
   * @return totalDebtBase The total debt of the user in the base currency used by the price feed
   * @return availableBorrowsBase The borrowing power left of the user in the base currency used by the price feed
   * @return currentLiquidationThreshold The liquidation threshold of the user
   * @return ltv The loan to value of The user
   * @return healthFactor The current health factor of the user
   */
  function getUserAccountData(
    address user
  )
    external
    view
    returns (
      uint256 totalCollateralBase,
      uint256 totalDebtBase,
      uint256 availableBorrowsBase,
      uint256 currentLiquidationThreshold,
      uint256 ltv,
      uint256 healthFactor
    );

  /**
   * @notice Initializes a reserve, activating it, assigning an aToken and debt tokens and an
   * interest rate strategy
   * @dev Only callable by the PoolConfigurator contract
   * @param asset The address of the underlying asset of the reserve
   * @param aTokenAddress The address of the aToken that will be assigned to the reserve
   * @param stableDebtAddress The address of the StableDebtToken that will be assigned to the reserve
   * @param variableDebtAddress The address of the VariableDebtToken that will be assigned to the reserve
   * @param interestRateStrategyAddress The address of the interest rate strategy contract
   */
  function initReserve(
    address asset,
    address aTokenAddress,
    address stableDebtAddress,
    address variableDebtAddress,
    address interestRateStrategyAddress
  ) external;

  /**
   * @notice Drop a reserve
   * @dev Only callable by the PoolConfigurator contract
   * @param asset The address of the underlying asset of the reserve
   */
  function dropReserve(address asset) external;

  /**
   * @notice Updates the address of the interest rate strategy contract
   * @dev Only callable by the PoolConfigurator contract
   * @param asset The address of the underlying asset of the reserve
   * @param rateStrategyAddress The address of the interest rate strategy contract
   */
  function setReserveInterestRateStrategyAddress(
    address asset,
    address rateStrategyAddress
  ) external;

  /**
   * @notice Sets the configuration bitmap of the reserve as a whole
   * @dev Only callable by the PoolConfigurator contract
   * @param asset The address of the underlying asset of the reserve
   * @param configuration The new configuration bitmap
   */
  function setConfiguration(
    address asset,
    DataTypes.ReserveConfigurationMap calldata configuration
  ) external;

  /**
   * @notice Returns the configuration of the reserve
   * @param asset The address of the underlying asset of the reserve
   * @return The configuration of the reserve
   */
  function getConfiguration(
    address asset
  ) external view returns (DataTypes.ReserveConfigurationMap memory);

  /**
   * @notice Returns the configuration of the user across all the reserves
   * @param user The user address
   * @return The configuration of the user
   */
  function getUserConfiguration(
    address user
  ) external view returns (DataTypes.UserConfigurationMap memory);

  /**
   * @notice Returns the normalized income of the reserve
   * @param asset The address of the underlying asset of the reserve
   * @return The reserve's normalized income
   */
  function getReserveNormalizedIncome(address asset) external view returns (uint256);

  /**
   * @notice Returns the normalized variable debt per unit of asset
   * @dev WARNING: This function is intended to be used primarily by the protocol itself to get a
   * "dynamic" variable index based on time, current stored index and virtual rate at the current
   * moment (approx. a borrower would get if opening a position). This means that is always used in
   * combination with variable debt supply/balances.
   * If using this function externally, consider that is possible to have an increasing normalized
   * variable debt that is not equivalent to how the variable debt index would be updated in storage
   * (e.g. only updates with non-zero variable debt supply)
   * @param asset The address of the underlying asset of the reserve
   * @return The reserve normalized variable debt
   */
  function getReserveNormalizedVariableDebt(address asset) external view returns (uint256);

  /**
   * @notice Returns the state and configuration of the reserve
   * @param asset The address of the underlying asset of the reserve
   * @return The state and configuration data of the reserve
   */
  function getReserveData(address asset) external view returns (DataTypes.ReserveData memory);

  /**
   * @notice Validates and finalizes an aToken transfer
   * @dev Only callable by the overlying aToken of the `asset`
   * @param asset The address of the underlying asset of the aToken
   * @param from The user from which the aTokens are transferred
   * @param to The user receiving the aTokens
   * @param amount The amount being transferred/withdrawn
   * @param balanceFromBefore The aToken balance of the `from` user before the transfer
   * @param balanceToBefore The aToken balance of the `to` user before the transfer
   */
  function finalizeTransfer(
    address asset,
    address from,
    address to,
    uint256 amount,
    uint256 balanceFromBefore,
    uint256 balanceToBefore
  ) external;

  /**
   * @notice Returns the list of the underlying assets of all the initialized reserves
   * @dev It does not include dropped reserves
   * @return The addresses of the underlying assets of the initialized reserves
   */
  function getReservesList() external view returns (address[] memory);

  /**
   * @notice Returns the address of the underlying asset of a reserve by the reserve id as stored in the DataTypes.ReserveData struct
   * @param id The id of the reserve as stored in the DataTypes.ReserveData struct
   * @return The address of the reserve associated with id
   */
  function getReserveAddressById(uint16 id) external view returns (address);

  /**
   * @notice Returns the PoolAddressesProvider connected to this contract
   * @return The address of the PoolAddressesProvider
   */
  function ADDRESSES_PROVIDER() external view returns (IPoolAddressesProvider);

  /**
   * @notice Updates the protocol fee on the bridging
   * @param bridgeProtocolFee The part of the premium sent to the protocol treasury
   */
  function updateBridgeProtocolFee(uint256 bridgeProtocolFee) external;

  /**
   * @notice Updates flash loan premiums. Flash loan premium consists of two parts:
   * - A part is sent to aToken holders as extra, one time accumulated interest
   * - A part is collected by the protocol treasury
   * @dev The total premium is calculated on the total borrowed amount
   * @dev The premium to protocol is calculated on the total premium, being a percentage of `flashLoanPremiumTotal`
   * @dev Only callable by the PoolConfigurator contract
   * @param flashLoanPremiumTotal The total premium, expressed in bps
   * @param flashLoanPremiumToProtocol The part of the premium sent to the protocol treasury, expressed in bps
   */
  function updateFlashloanPremiums(
    uint128 flashLoanPremiumTotal,
    uint128 flashLoanPremiumToProtocol
  ) external;

  /**
   * @notice Configures a new category for the eMode.
   * @dev In eMode, the protocol allows very high borrowing power to borrow assets of the same category.
   * The category 0 is reserved as it's the default for volatile assets
   * @param id The id of the category
   * @param config The configuration of the category
   */
  function configureEModeCategory(uint8 id, DataTypes.EModeCategory memory config) external;

  /**
   * @notice Returns the data of an eMode category
   * @param id The id of the category
   * @return The configuration data of the category
   */
  function getEModeCategoryData(uint8 id) external view returns (DataTypes.EModeCategory memory);

  /**
   * @notice Allows a user to use the protocol in eMode
   * @param categoryId The id of the category
   */
  function setUserEMode(uint8 categoryId) external;

  /**
   * @notice Returns the eMode the user is using
   * @param user The address of the user
   * @return The eMode id
   */
  function getUserEMode(address user) external view returns (uint256);

  /**
   * @notice Resets the isolation mode total debt of the given asset to zero
   * @dev It requires the given asset has zero debt ceiling
   * @param asset The address of the underlying asset to reset the isolationModeTotalDebt
   */
  function resetIsolationModeTotalDebt(address asset) external;

  /**
   * @notice Returns the percentage of available liquidity that can be borrowed at once at stable rate
   * @return The percentage of available liquidity to borrow, expressed in bps
   */
  function MAX_STABLE_RATE_BORROW_SIZE_PERCENT() external view returns (uint256);

  /**
   * @notice Returns the total fee on flash loans
   * @return The total fee on flashloans
   */
  function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128);

  /**
   * @notice Returns the part of the bridge fees sent to protocol
   * @return The bridge fee sent to the protocol treasury
   */
  function BRIDGE_PROTOCOL_FEE() external view returns (uint256);

  /**
   * @notice Returns the part of the flashloan fees sent to protocol
   * @return The flashloan fee sent to the protocol treasury
   */
  function FLASHLOAN_PREMIUM_TO_PROTOCOL() external view returns (uint128);

  /**
   * @notice Returns the maximum number of reserves supported to be listed in this Pool
   * @return The maximum number of reserves supported
   */
  function MAX_NUMBER_RESERVES() external view returns (uint16);

  /**
   * @notice Mints the assets accrued through the reserve factor to the treasury in the form of aTokens
   * @param assets The list of reserves for which the minting needs to be executed
   */
  function mintToTreasury(address[] calldata assets) external;

  /**
   * @notice Rescue and transfer tokens locked in this contract
   * @param token The address of the token
   * @param to The address of the recipient
   * @param amount The amount of token to transfer
   */
  function rescueTokens(address token, address to, uint256 amount) external;

  /**
   * @notice Supplies an `amount` of underlying asset into the reserve, receiving in return overlying aTokens.
   * - E.g. User supplies 100 USDC and gets in return 100 aUSDC
   * @dev Deprecated: Use the `supply` function instead
   * @param asset The address of the underlying asset to supply
   * @param amount The amount to be supplied
   * @param onBehalfOf The address that will receive the aTokens, same as msg.sender if the user
   *   wants to receive them on his own wallet, or a different address if the beneficiary of aTokens
   *   is a different wallet
   * @param referralCode Code used to register the integrator originating the operation, for potential rewards.
   *   0 if the action is executed directly by the user, without any middle-man
   */
  function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}
pragma solidity ^0.8.0;

/**
 * @title IPoolAddressesProvider
 * @author Aave
 * @notice Defines the basic interface for a Pool Addresses Provider.
 */
interface IPoolAddressesProvider {
  /**
   * @dev Emitted when the market identifier is updated.
   * @param oldMarketId The old id of the market
   * @param newMarketId The new id of the market
   */
  event MarketIdSet(string indexed oldMarketId, string indexed newMarketId);

  /**
   * @dev Emitted when the pool is updated.
   * @param oldAddress The old address of the Pool
   * @param newAddress The new address of the Pool
   */
  event PoolUpdated(address indexed oldAddress, address indexed newAddress);

  /**
   * @dev Emitted when the pool configurator is updated.
   * @param oldAddress The old address of the PoolConfigurator
   * @param newAddress The new address of the PoolConfigurator
   */
  event PoolConfiguratorUpdated(address indexed oldAddress, address indexed newAddress);

  /**
   * @dev Emitted when the price oracle is updated.
   * @param oldAddress The old address of the PriceOracle
   * @param newAddress The new address of the PriceOracle
   */
  event PriceOracleUpdated(address indexed oldAddress, address indexed newAddress);

  /**
   * @dev Emitted when the ACL manager is updated.
   * @param oldAddress The old address of the ACLManager
   * @param newAddress The new address of the ACLManager
   */
  event ACLManagerUpdated(address indexed oldAddress, address indexed newAddress);

  /**
   * @dev Emitted when the ACL admin is updated.
   * @param oldAddress The old address of the ACLAdmin
   * @param newAddress The new address of the ACLAdmin
   */
  event ACLAdminUpdated(address indexed oldAddress, address indexed newAddress);

  /**
   * @dev Emitted when the price oracle sentinel is updated.
   * @param oldAddress The old address of the PriceOracleSentinel
   * @param newAddress The new address of the PriceOracleSentinel
   */
  event PriceOracleSentinelUpdated(address indexed oldAddress, address indexed newAddress);

  /**
   * @dev Emitted when the pool data provider is updated.
   * @param oldAddress The old address of the PoolDataProvider
   * @param newAddress The new address of the PoolDataProvider
   */
  event PoolDataProviderUpdated(address indexed oldAddress, address indexed newAddress);

  /**
   * @dev Emitted when a new proxy is created.
   * @param id The identifier of the proxy
   * @param proxyAddress The address of the created proxy contract
   * @param implementationAddress The address of the implementation contract
   */
  event ProxyCreated(
    bytes32 indexed id,
    address indexed proxyAddress,
    address indexed implementationAddress
  );

  /**
   * @dev Emitted when a new non-proxied contract address is registered.
   * @param id The identifier of the contract
   * @param oldAddress The address of the old contract
   * @param newAddress The address of the new contract
   */
  event AddressSet(bytes32 indexed id, address indexed oldAddress, address indexed newAddress);

  /**
   * @dev Emitted when the implementation of the proxy registered with id is updated
   * @param id The identifier of the contract
   * @param proxyAddress The address of the proxy contract
   * @param oldImplementationAddress The address of the old implementation contract
   * @param newImplementationAddress The address of the new implementation contract
   */
  event AddressSetAsProxy(
    bytes32 indexed id,
    address indexed proxyAddress,
    address oldImplementationAddress,
    address indexed newImplementationAddress
  );

  /**
   * @notice Returns the id of the Aave market to which this contract points to.
   * @return The market id
   */
  function getMarketId() external view returns (string memory);

  /**
   * @notice Associates an id with a specific PoolAddressesProvider.
   * @dev This can be used to create an onchain registry of PoolAddressesProviders to
   * identify and validate multiple Aave markets.
   * @param newMarketId The market id
   */
  function setMarketId(string calldata newMarketId) external;

  /**
   * @notice Returns an address by its identifier.
   * @dev The returned address might be an EOA or a contract, potentially proxied
   * @dev It returns ZERO if there is no registered address with the given id
   * @param id The id
   * @return The address of the registered for the specified id
   */
  function getAddress(bytes32 id) external view returns (address);

  /**
   * @notice General function to update the implementation of a proxy registered with
   * certain `id`. If there is no proxy registered, it will instantiate one and
   * set as implementation the `newImplementationAddress`.
   * @dev IMPORTANT Use this function carefully, only for ids that don't have an explicit
   * setter function, in order to avoid unexpected consequences
   * @param id The id
   * @param newImplementationAddress The address of the new implementation
   */
  function setAddressAsProxy(bytes32 id, address newImplementationAddress) external;

  /**
   * @notice Sets an address for an id replacing the address saved in the addresses map.
   * @dev IMPORTANT Use this function carefully, as it will do a hard replacement
   * @param id The id
   * @param newAddress The address to set
   */
  function setAddress(bytes32 id, address newAddress) external;

  /**
   * @notice Returns the address of the Pool proxy.
   * @return The Pool proxy address
   */
  function getPool() external view returns (address);

  /**
   * @notice Updates the implementation of the Pool, or creates a proxy
   * setting the new `pool` implementation when the function is called for the first time.
   * @param newPoolImpl The new Pool implementation
   */
  function setPoolImpl(address newPoolImpl) external;

  /**
   * @notice Returns the address of the PoolConfigurator proxy.
   * @return The PoolConfigurator proxy address
   */
  function getPoolConfigurator() external view returns (address);

  /**
   * @notice Updates the implementation of the PoolConfigurator, or creates a proxy
   * setting the new `PoolConfigurator` implementation when the function is called for the first time.
   * @param newPoolConfiguratorImpl The new PoolConfigurator implementation
   */
  function setPoolConfiguratorImpl(address newPoolConfiguratorImpl) external;

  /**
   * @notice Returns the address of the price oracle.
   * @return The address of the PriceOracle
   */
  function getPriceOracle() external view returns (address);

  /**
   * @notice Updates the address of the price oracle.
   * @param newPriceOracle The address of the new PriceOracle
   */
  function setPriceOracle(address newPriceOracle) external;

  /**
   * @notice Returns the address of the ACL manager.
   * @return The address of the ACLManager
   */
  function getACLManager() external view returns (address);

  /**
   * @notice Updates the address of the ACL manager.
   * @param newAclManager The address of the new ACLManager
   */
  function setACLManager(address newAclManager) external;

  /**
   * @notice Returns the address of the ACL admin.
   * @return The address of the ACL admin
   */
  function getACLAdmin() external view returns (address);

  /**
   * @notice Updates the address of the ACL admin.
   * @param newAclAdmin The address of the new ACL admin
   */
  function setACLAdmin(address newAclAdmin) external;

  /**
   * @notice Returns the address of the price oracle sentinel.
   * @return The address of the PriceOracleSentinel
   */
  function getPriceOracleSentinel() external view returns (address);

  /**
   * @notice Updates the address of the price oracle sentinel.
   * @param newPriceOracleSentinel The address of the new PriceOracleSentinel
   */
  function setPriceOracleSentinel(address newPriceOracleSentinel) external;

  /**
   * @notice Returns the address of the data provider.
   * @return The address of the DataProvider
   */
  function getPoolDataProvider() external view returns (address);

  /**
   * @notice Updates the address of the data provider.
   * @param newDataProvider The address of the new DataProvider
   */
  function setPoolDataProvider(address newDataProvider) external;
}
pragma solidity ^0.8.0;

import {IPoolAddressesProvider} from './IPoolAddressesProvider.sol';

/**
 * @title IPoolDataProvider
 * @author Aave
 * @notice Defines the basic interface of a PoolDataProvider
 */
interface IPoolDataProvider {
  struct TokenData {
    string symbol;
    address tokenAddress;
  }

  /**
   * @notice Returns the address for the PoolAddressesProvider contract.
   * @return The address for the PoolAddressesProvider contract
   */
  function ADDRESSES_PROVIDER() external view returns (IPoolAddressesProvider);

  /**
   * @notice Returns the list of the existing reserves in the pool.
   * @dev Handling MKR and ETH in a different way since they do not have standard `symbol` functions.
   * @return The list of reserves, pairs of symbols and addresses
   */
  function getAllReservesTokens() external view returns (TokenData[] memory);

  /**
   * @notice Returns the list of the existing ATokens in the pool.
   * @return The list of ATokens, pairs of symbols and addresses
   */
  function getAllATokens() external view returns (TokenData[] memory);

  /**
   * @notice Returns the configuration data of the reserve
   * @dev Not returning borrow and supply caps for compatibility, nor pause flag
   * @param asset The address of the underlying asset of the reserve
   * @return decimals The number of decimals of the reserve
   * @return ltv The ltv of the reserve
   * @return liquidationThreshold The liquidationThreshold of the reserve
   * @return liquidationBonus The liquidationBonus of the reserve
   * @return reserveFactor The reserveFactor of the reserve
   * @return usageAsCollateralEnabled True if the usage as collateral is enabled, false otherwise
   * @return borrowingEnabled True if borrowing is enabled, false otherwise
   * @return stableBorrowRateEnabled True if stable rate borrowing is enabled, false otherwise
   * @return isActive True if it is active, false otherwise
   * @return isFrozen True if it is frozen, false otherwise
   */
  function getReserveConfigurationData(
    address asset
  )
    external
    view
    returns (
      uint256 decimals,
      uint256 ltv,
      uint256 liquidationThreshold,
      uint256 liquidationBonus,
      uint256 reserveFactor,
      bool usageAsCollateralEnabled,
      bool borrowingEnabled,
      bool stableBorrowRateEnabled,
      bool isActive,
      bool isFrozen
    );

  /**
   * @notice Returns the efficiency mode category of the reserve
   * @param asset The address of the underlying asset of the reserve
   * @return The eMode id of the reserve
   */
  function getReserveEModeCategory(address asset) external view returns (uint256);

  /**
   * @notice Returns the caps parameters of the reserve
   * @param asset The address of the underlying asset of the reserve
   * @return borrowCap The borrow cap of the reserve
   * @return supplyCap The supply cap of the reserve
   */
  function getReserveCaps(
    address asset
  ) external view returns (uint256 borrowCap, uint256 supplyCap);

  /**
   * @notice Returns if the pool is paused
   * @param asset The address of the underlying asset of the reserve
   * @return isPaused True if the pool is paused, false otherwise
   */
  function getPaused(address asset) external view returns (bool isPaused);

  /**
   * @notice Returns the siloed borrowing flag
   * @param asset The address of the underlying asset of the reserve
   * @return True if the asset is siloed for borrowing
   */
  function getSiloedBorrowing(address asset) external view returns (bool);

  /**
   * @notice Returns the protocol fee on the liquidation bonus
   * @param asset The address of the underlying asset of the reserve
   * @return The protocol fee on liquidation
   */
  function getLiquidationProtocolFee(address asset) external view returns (uint256);

  /**
   * @notice Returns the unbacked mint cap of the reserve
   * @param asset The address of the underlying asset of the reserve
   * @return The unbacked mint cap of the reserve
   */
  function getUnbackedMintCap(address asset) external view returns (uint256);

  /**
   * @notice Returns the debt ceiling of the reserve
   * @param asset The address of the underlying asset of the reserve
   * @return The debt ceiling of the reserve
   */
  function getDebtCeiling(address asset) external view returns (uint256);

  /**
   * @notice Returns the debt ceiling decimals
   * @return The debt ceiling decimals
   */
  function getDebtCeilingDecimals() external pure returns (uint256);

  /**
   * @notice Returns the reserve data
   * @param asset The address of the underlying asset of the reserve
   * @return unbacked The amount of unbacked tokens
   * @return accruedToTreasuryScaled The scaled amount of tokens accrued to treasury that is to be minted
   * @return totalAToken The total supply of the aToken
   * @return totalStableDebt The total stable debt of the reserve
   * @return totalVariableDebt The total variable debt of the reserve
   * @return liquidityRate The liquidity rate of the reserve
   * @return variableBorrowRate The variable borrow rate of the reserve
   * @return stableBorrowRate The stable borrow rate of the reserve
   * @return averageStableBorrowRate The average stable borrow rate of the reserve
   * @return liquidityIndex The liquidity index of the reserve
   * @return variableBorrowIndex The variable borrow index of the reserve
   * @return lastUpdateTimestamp The timestamp of the last update of the reserve
   */
  function getReserveData(
    address asset
  )
    external
    view
    returns (
      uint256 unbacked,
      uint256 accruedToTreasuryScaled,
      uint256 totalAToken,
      uint256 totalStableDebt,
      uint256 totalVariableDebt,
      uint256 liquidityRate,
      uint256 variableBorrowRate,
      uint256 stableBorrowRate,
      uint256 averageStableBorrowRate,
      uint256 liquidityIndex,
      uint256 variableBorrowIndex,
      uint40 lastUpdateTimestamp
    );

  /**
   * @notice Returns the total supply of aTokens for a given asset
   * @param asset The address of the underlying asset of the reserve
   * @return The total supply of the aToken
   */
  function getATokenTotalSupply(address asset) external view returns (uint256);

  /**
   * @notice Returns the total debt for a given asset
   * @param asset The address of the underlying asset of the reserve
   * @return The total debt for asset
   */
  function getTotalDebt(address asset) external view returns (uint256);

  /**
   * @notice Returns the user data in a reserve
   * @param asset The address of the underlying asset of the reserve
   * @param user The address of the user
   * @return currentATokenBalance The current AToken balance of the user
   * @return currentStableDebt The current stable debt of the user
   * @return currentVariableDebt The current variable debt of the user
   * @return principalStableDebt The principal stable debt of the user
   * @return scaledVariableDebt The scaled variable debt of the user
   * @return stableBorrowRate The stable borrow rate of the user
   * @return liquidityRate The liquidity rate of the reserve
   * @return stableRateLastUpdated The timestamp of the last update of the user stable rate
   * @return usageAsCollateralEnabled True if the user is using the asset as collateral, false
   *         otherwise
   */
  function getUserReserveData(
    address asset,
    address user
  )
    external
    view
    returns (
      uint256 currentATokenBalance,
      uint256 currentStableDebt,
      uint256 currentVariableDebt,
      uint256 principalStableDebt,
      uint256 scaledVariableDebt,
      uint256 stableBorrowRate,
      uint256 liquidityRate,
      uint40 stableRateLastUpdated,
      bool usageAsCollateralEnabled
    );

  /**
   * @notice Returns the token addresses of the reserve
   * @param asset The address of the underlying asset of the reserve
   * @return aTokenAddress The AToken address of the reserve
   * @return stableDebtTokenAddress The StableDebtToken address of the reserve
   * @return variableDebtTokenAddress The VariableDebtToken address of the reserve
   */
  function getReserveTokensAddresses(
    address asset
  )
    external
    view
    returns (
      address aTokenAddress,
      address stableDebtTokenAddress,
      address variableDebtTokenAddress
    );

  /**
   * @notice Returns the address of the Interest Rate strategy
   * @param asset The address of the underlying asset of the reserve
   * @return irStrategyAddress The address of the Interest Rate strategy
   */
  function getInterestRateStrategyAddress(
    address asset
  ) external view returns (address irStrategyAddress);

  /**
   * @notice Returns whether the reserve has FlashLoans enabled or disabled
   * @param asset The address of the underlying asset of the reserve
   * @return True if FlashLoans are enabled, false otherwise
   */
  function getFlashLoanEnabled(address asset) external view returns (bool);
}
pragma solidity ^0.8.0;

library DataTypes {
  struct ReserveData {
    //stores the reserve configuration
    ReserveConfigurationMap configuration;
    //the liquidity index. Expressed in ray
    uint128 liquidityIndex;
    //the current supply rate. Expressed in ray
    uint128 currentLiquidityRate;
    //variable borrow index. Expressed in ray
    uint128 variableBorrowIndex;
    //the current variable borrow rate. Expressed in ray
    uint128 currentVariableBorrowRate;
    //the current stable borrow rate. Expressed in ray
    uint128 currentStableBorrowRate;
    //timestamp of last update
    uint40 lastUpdateTimestamp;
    //the id of the reserve. Represents the position in the list of the active reserves
    uint16 id;
    //aToken address
    address aTokenAddress;
    //stableDebtToken address
    address stableDebtTokenAddress;
    //variableDebtToken address
    address variableDebtTokenAddress;
    //address of the interest rate strategy
    address interestRateStrategyAddress;
    //the current treasury balance, scaled
    uint128 accruedToTreasury;
    //the outstanding unbacked aTokens minted through the bridging feature
    uint128 unbacked;
    //the outstanding debt borrowed against this asset in isolation mode
    uint128 isolationModeTotalDebt;
  }

  struct ReserveConfigurationMap {
    //bit 0-15: LTV
    //bit 16-31: Liq. threshold
    //bit 32-47: Liq. bonus
    //bit 48-55: Decimals
    //bit 56: reserve is active
    //bit 57: reserve is frozen
    //bit 58: borrowing is enabled
    //bit 59: stable rate borrowing enabled
    //bit 60: asset is paused
    //bit 61: borrowing in isolation mode is enabled
    //bit 62: siloed borrowing enabled
    //bit 63: flashloaning enabled
    //bit 64-79: reserve factor
    //bit 80-115 borrow cap in whole tokens, borrowCap == 0 => no cap
    //bit 116-151 supply cap in whole tokens, supplyCap == 0 => no cap
    //bit 152-167 liquidation protocol fee
    //bit 168-175 eMode category
    //bit 176-211 unbacked mint cap in whole tokens, unbackedMintCap == 0 => minting disabled
    //bit 212-251 debt ceiling for isolation mode with (ReserveConfiguration::DEBT_CEILING_DECIMALS) decimals
    //bit 252-255 unused

    uint256 data;
  }

  struct UserConfigurationMap {
    /**
     * @dev Bitmap of the users collaterals and borrows. It is divided in pairs of bits, one pair per asset.
     * The first bit indicates if an asset is used as collateral by the user, the second whether an
     * asset is borrowed by the user.
     */
    uint256 data;
  }

  struct EModeCategory {
    // each eMode category has a custom ltv and liquidation threshold
    uint16 ltv;
    uint16 liquidationThreshold;
    uint16 liquidationBonus;
    // each eMode category may or may not have a custom oracle to override the individual assets price oracles
    address priceSource;
    string label;
  }

  enum InterestRateMode {NONE, STABLE, VARIABLE}

  struct ReserveCache {
    uint256 currScaledVariableDebt;
    uint256 nextScaledVariableDebt;
    uint256 currPrincipalStableDebt;
    uint256 currAvgStableBorrowRate;
    uint256 currTotalStableDebt;
    uint256 nextAvgStableBorrowRate;
    uint256 nextTotalStableDebt;
    uint256 currLiquidityIndex;
    uint256 nextLiquidityIndex;
    uint256 currVariableBorrowIndex;
    uint256 nextVariableBorrowIndex;
    uint256 currLiquidityRate;
    uint256 currVariableBorrowRate;
    uint256 reserveFactor;
    ReserveConfigurationMap reserveConfiguration;
    address aTokenAddress;
    address stableDebtTokenAddress;
    address variableDebtTokenAddress;
    uint40 reserveLastUpdateTimestamp;
    uint40 stableDebtLastUpdateTimestamp;
  }

  struct ExecuteLiquidationCallParams {
    uint256 reservesCount;
    uint256 debtToCover;
    address collateralAsset;
    address debtAsset;
    address user;
    bool receiveAToken;
    address priceOracle;
    uint8 userEModeCategory;
    address priceOracleSentinel;
  }

  struct ExecuteSupplyParams {
    address asset;
    uint256 amount;
    address onBehalfOf;
    uint16 referralCode;
  }

  struct ExecuteBorrowParams {
    address asset;
    address user;
    address onBehalfOf;
    uint256 amount;
    InterestRateMode interestRateMode;
    uint16 referralCode;
    bool releaseUnderlying;
    uint256 maxStableRateBorrowSizePercent;
    uint256 reservesCount;
    address oracle;
    uint8 userEModeCategory;
    address priceOracleSentinel;
  }

  struct ExecuteRepayParams {
    address asset;
    uint256 amount;
    InterestRateMode interestRateMode;
    address onBehalfOf;
    bool useATokens;
  }

  struct ExecuteWithdrawParams {
    address asset;
    uint256 amount;
    address to;
    uint256 reservesCount;
    address oracle;
    uint8 userEModeCategory;
  }

  struct ExecuteSetUserEModeParams {
    uint256 reservesCount;
    address oracle;
    uint8 categoryId;
  }

  struct FinalizeTransferParams {
    address asset;
    address from;
    address to;
    uint256 amount;
    uint256 balanceFromBefore;
    uint256 balanceToBefore;
    uint256 reservesCount;
    address oracle;
    uint8 fromEModeCategory;
  }

  struct FlashloanParams {
    address receiverAddress;
    address[] assets;
    uint256[] amounts;
    uint256[] interestRateModes;
    address onBehalfOf;
    bytes params;
    uint16 referralCode;
    uint256 flashLoanPremiumToProtocol;
    uint256 flashLoanPremiumTotal;
    uint256 maxStableRateBorrowSizePercent;
    uint256 reservesCount;
    address addressesProvider;
    uint8 userEModeCategory;
    bool isAuthorizedFlashBorrower;
  }

  struct FlashloanSimpleParams {
    address receiverAddress;
    address asset;
    uint256 amount;
    bytes params;
    uint16 referralCode;
    uint256 flashLoanPremiumToProtocol;
    uint256 flashLoanPremiumTotal;
  }

  struct FlashLoanRepaymentParams {
    uint256 amount;
    uint256 totalPremium;
    uint256 flashLoanPremiumToProtocol;
    address asset;
    address receiverAddress;
    uint16 referralCode;
  }

  struct CalculateUserAccountDataParams {
    UserConfigurationMap userConfig;
    uint256 reservesCount;
    address user;
    address oracle;
    uint8 userEModeCategory;
  }

  struct ValidateBorrowParams {
    ReserveCache reserveCache;
    UserConfigurationMap userConfig;
    address asset;
    address userAddress;
    uint256 amount;
    InterestRateMode interestRateMode;
    uint256 maxStableLoanPercent;
    uint256 reservesCount;
    address oracle;
    uint8 userEModeCategory;
    address priceOracleSentinel;
    bool isolationModeActive;
    address isolationModeCollateralAddress;
    uint256 isolationModeDebtCeiling;
  }

  struct ValidateLiquidationCallParams {
    ReserveCache debtReserveCache;
    uint256 totalDebt;
    uint256 healthFactor;
    address priceOracleSentinel;
  }

  struct CalculateInterestRatesParams {
    uint256 unbacked;
    uint256 liquidityAdded;
    uint256 liquidityTaken;
    uint256 totalStableDebt;
    uint256 totalVariableDebt;
    uint256 averageStableBorrowRate;
    uint256 reserveFactor;
    address reserve;
    address aToken;
  }

  struct InitReserveParams {
    address asset;
    address aTokenAddress;
    address stableDebtAddress;
    address variableDebtAddress;
    address interestRateStrategyAddress;
    uint16 reservesCount;
    uint16 maxNumberReserves;
  }
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
pragma solidity >=0.5.0;

/// @title Callback for IUniswapV3PoolActions#swap
/// @notice Any contract that calls IUniswapV3PoolActions#swap must implement this interface
interface IUniswapV3SwapCallback {
    /// @notice Called to `msg.sender` after executing a swap via IUniswapV3Pool#swap.
    /// @dev In the implementation you must pay the pool tokens owed for the swap.
    /// The caller of this method must be checked to be a UniswapV3Pool deployed by the canonical UniswapV3Factory.
    /// amount0Delta and amount1Delta can both be 0 if no tokens were swapped.
    /// @param amount0Delta The amount of token0 that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token0 to the pool.
    /// @param amount1Delta The amount of token1 that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token1 to the pool.
    /// @param data Any data passed through by the caller via the IUniswapV3PoolActions#swap call
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external;
}
pragma solidity >=0.7.5;
pragma abicoder v2;

/// @title Quoter Interface
/// @notice Supports quoting the calculated amounts from exact input or exact output swaps
/// @dev These functions are not marked view because they rely on calling non-view functions and reverting
/// to compute the result. They are also not gas efficient and should not be called on-chain.
interface IQuoter {
    /// @notice Returns the amount out received for a given exact input swap without executing the swap
    /// @param path The path of the swap, i.e. each token pair and the pool fee
    /// @param amountIn The amount of the first token to swap
    /// @return amountOut The amount of the last token that would be received
    function quoteExactInput(bytes memory path, uint256 amountIn) external returns (uint256 amountOut);

    /// @notice Returns the amount out received for a given exact input but for a swap of a single pool
    /// @param tokenIn The token being swapped in
    /// @param tokenOut The token being swapped out
    /// @param fee The fee of the token pool to consider for the pair
    /// @param amountIn The desired input amount
    /// @param sqrtPriceLimitX96 The price limit of the pool that cannot be exceeded by the swap
    /// @return amountOut The amount of `tokenOut` that would be received
    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountOut);

    /// @notice Returns the amount in required for a given exact output swap without executing the swap
    /// @param path The path of the swap, i.e. each token pair and the pool fee. Path must be provided in reverse order
    /// @param amountOut The amount of the last token to receive
    /// @return amountIn The amount of first token required to be paid
    function quoteExactOutput(bytes memory path, uint256 amountOut) external returns (uint256 amountIn);

    /// @notice Returns the amount in required to receive the given exact output amount but for a swap of a single pool
    /// @param tokenIn The token being swapped in
    /// @param tokenOut The token being swapped out
    /// @param fee The fee of the token pool to consider for the pair
    /// @param amountOut The desired output amount
    /// @param sqrtPriceLimitX96 The price limit of the pool that cannot be exceeded by the swap
    /// @return amountIn The amount required as the input for the swap in order to receive `amountOut`
    function quoteExactOutputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountOut,
        uint160 sqrtPriceLimitX96
    ) external returns (uint256 amountIn);
}
pragma solidity >=0.7.5;
pragma abicoder v2;

import '@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol';

/// @title Router token swapping functionality
/// @notice Functions for swapping tokens via Uniswap V3
interface ISwapRouter is IUniswapV3SwapCallback {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another token
    /// @param params The parameters necessary for the swap, encoded as `ExactInputSingleParams` in calldata
    /// @return amountOut The amount of the received token
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another along the specified path
    /// @param params The parameters necessary for the multi-hop swap, encoded as `ExactInputParams` in calldata
    /// @return amountOut The amount of the received token
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps as little as possible of one token for `amountOut` of another token
    /// @param params The parameters necessary for the swap, encoded as `ExactOutputSingleParams` in calldata
    /// @return amountIn The amount of the input token
    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);

    struct ExactOutputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    /// @notice Swaps as little as possible of one token for `amountOut` of another along the specified path (reversed)
    /// @param params The parameters necessary for the multi-hop swap, encoded as `ExactOutputParams` in calldata
    /// @return amountIn The amount of the input token
    function exactOutput(ExactOutputParams calldata params) external payable returns (uint256 amountIn);
}
pragma solidity ^0.8.10;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

error CustomError(string errorMsg);

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint amount) external;
}

interface AaveActionsConnector {
    function executeAaveAction(address _dsaAddress, uint256 _connectorId, address _tokenIn, uint256 _inAmount, address _tokenOut, uint256 _outAmount, uint256 _actionId) external payable;
}

interface IDoughDsa {
    function doughCall(uint256 _connectorId, uint256 _actionId, address _token, uint256 _amount, bool _opt, bytes[] calldata _swapData) external payable;
    function executeAction(uint256 _connectorId, address tokenIn, uint256 inAmount, address tokenOut, uint256 outAmount, uint256 actionId) external payable;
    function dsaOwner() external view returns (address);
    function doughIndex() external view returns (address);
}

interface IDoughIndex {
    function aaveActionsAddress() external view returns (address);
    function setDsaMasterClone(address _dsaMasterCopy) external;
    function setNewBorrowFormula(address _newBorrowFormula) external;
    function setNewAaveActions(address _newAaveActions) external;
    function apyFee() external view returns (uint256);
    function getFlashBorrowers(address _flashBorrower) external view returns (bool);
    function deleverageAutomation() external view returns (address);
    function shieldAutomation() external view returns (address);
    function vaultAutomation() external view returns (address);
    function getWhitelistedTokenList() external view returns (address[] memory);
    function multisig() external view returns (address);
    function treasury() external view returns (address);
    function deleverageAsset() external view returns (address);
    function getDoughConnector (uint256 _connectorId) external view returns (address);
    function getOwnerOfDoughDsa(address dsaAddress) external view returns (address);
    function getDoughDsa(address dsaAddress) external view returns (address);
    function getTokenDecimals(address _token) external view returns (uint8);
    function getTokenMinInterest(address _token) external view returns (uint256);
    function getTokenIndex(address _token) external view returns (uint256);
    function borrowFormula (address _token, address _dsaAddress) external returns (uint256, uint256, uint256, uint256);
    function borrowFormulaInterest (address _token, address _dsaAddress) external returns (uint256);
    function getDsaBorrowStartDate (address _dsaAddress, address _token) external view returns (uint256);
    function updateBorrowDate(uint256 _connectorID, uint256 _time, address _dsaAddress, address _token) external;
    function minDeleveragingRatio() external view returns (uint256);
    function minHealthFactor() external view returns (uint256);
}

interface IDoughRealHF {
    function getDoughHFData(address _dsaAddress) external view returns (uint256 healthFactor);
    function getUserData(address _dsaAddress) external view returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 availableBorrowBase, uint256 currentLiquidationThreshold, uint256 ltv, uint256 healthFactor,uint256 scaledInterest);
    function calculateMaxBorrow(address _token, address _dsaAddress) external view returns (uint256 maxBorrowInTokens);
}

interface ILiquidationManager {
    function startDsaLiquidationInOneTx(address _dsaAddress, uint256 _blockNumber) external;
    function startDsaLiquidationInMultipleTX(address _dsaAddress, uint256 _blockNumber) external;
    function startDsaLiquidationStatusMulti(address[] calldata _dsaAddresses, uint256[] calldata _blockNumber) external;
    function resetDsaLiquidationStatus(address _dsaAddress) external;
    function dsaLiquidationBlockNumbers(address _dsaAddress) external view returns (uint256[] memory);
    function dsaLiquidationStatus(address _dsaAddress) external view returns (bool);
}

interface IDeleverageAutomation {
    function whitelistedAddresses(address) external view returns (bool);
    function whitelistedAddressesList() external view returns (address[] memory);
}

interface IBorrowManagementConnector {
    function borrowFormula(address _token, address _dsaAddress) external view returns (uint256, uint256, uint256, uint256);
    function borrowFormulaInterest(address _token, address _dsaAddress) external view returns (uint256);
}

// interface IConnectorMultiStepParaswapFlashloan {
//     function flashloanReq(bool opt, address[] calldata flashloanTokens, uint256[] calldata flashloanAmounts, uint256[] calldata flashLoanInterestRateModes, bytes[] calldata swapData) external;
// }

interface IConnectorParaswapFlashloan {
    function flashloanReq(bool opt, address[] memory flashloanTokens, uint256[] memory flashloanAmounts, uint256[] memory flashLoanInterestRateModes, address[] memory totalTokensCollateral, uint256[] memory totalAmountsCollateral, bytes[] memory swapData) external;
}

interface IConnectorMultiFlashloanOnchain {
    function flashloanReq(address[] memory flashloanTokens, uint256[] memory flashloanAmount, uint256[] memory flashLoanInterestRateModes, address[] memory flashLoanTokensCollateral, uint256[] memory flashLoanAmountsCollateral) external;
}

interface IConnectorFlashloan {
    function flashloanReq(address dsaOwnerAddress, address flashloanToken, uint256 flashloanAmount, uint256 flashActionId, bytes calldata _swapData) external;
}
pragma solidity =0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@aave/core-v3/contracts/interfaces/IPoolDataProvider.sol";
import "@aave/core-v3/contracts/interfaces/IPool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import { IWETH, IDoughIndex, CustomError } from "../Interfaces.sol";

/**
* $$$$$$$\                                $$\             $$$$$$$$\ $$\                                                   
* $$  __$$\                               $$ |            $$  _____|\__|                                                  
* $$ |  $$ | $$$$$$\  $$\   $$\  $$$$$$\  $$$$$$$\        $$ |      $$\ $$$$$$$\   $$$$$$\  $$$$$$$\   $$$$$$$\  $$$$$$\  
* $$ |  $$ |$$  __$$\ $$ |  $$ |$$  __$$\ $$  __$$\       $$$$$\    $$ |$$  __$$\  \____$$\ $$  __$$\ $$  _____|$$  __$$\ 
* $$ |  $$ |$$ /  $$ |$$ |  $$ |$$ /  $$ |$$ |  $$ |      $$  __|   $$ |$$ |  $$ | $$$$$$$ |$$ |  $$ |$$ /      $$$$$$$$ |
* $$ |  $$ |$$ |  $$ |$$ |  $$ |$$ |  $$ |$$ |  $$ |      $$ |      $$ |$$ |  $$ |$$  __$$ |$$ |  $$ |$$ |      $$   ____|
* $$$$$$$  |\$$$$$$  |\$$$$$$  |\$$$$$$$ |$$ |  $$ |      $$ |      $$ |$$ |  $$ |\$$$$$$$ |$$ |  $$ |\$$$$$$$\ \$$$$$$$\ 
* \_______/  \______/  \______/  \____$$ |\__|  \__|      \__|      \__|\__|  \__| \_______|\__|  \__| \_______| \_______|
*                               $$\   $$ |                                                                                
*                               \$$$$$$  |                                                                                
*                                \______/                                                                                 
* 
* @title DoughCoreEthereum
* @notice The core contract for Dough Finance
* @custom:version 1.0 - Initial release
* @author Liberalite https://github.com/liberalite
* @custom:coauthor 0xboga https://github.com/0xboga
*/
library DoughCore {
    using SafeERC20 for IERC20;

    // MAINNET
    uint256 public constant CHAIN_ID = 1;

    // TOKENS
    address public constant ADDRESS_ZERO = 0x0000000000000000000000000000000000000000;
    address public constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address public constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    // AAVE V3 CONFIG
    uint256 public constant FLASHLOAN_RATE_MODE = 0; // no borrow debt
    uint256 public constant VARIABLE_RATE_MODE = 2; // variable borrow rate 

    // AAVE V3 ADDRESSES
    address public constant AAVE_V3_POOL_ADDRESS = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address public constant AAVE_V3_DATA_PROVIDER_ADDRESS = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;
    address public constant AAVE_V3_POOL_ADDRESS_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address public constant AAVE_V3_PRICE_ORACLE = 0x54586bE62E3c3580375aE3723C145253060Ca0C2;

    // UNISWAP V2
    address public constant UNISWAP_V2_ROUTER_ADDRESS = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    // UNISWAP V3
    address public constant UNISWAP_V3_ROUTER_ADDRESS = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address public constant UNISWAP_V3_QUOTER_ADDRESS = 0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6;

    // UNISWAP V3 INTERFACES
    ISwapRouter public constant _I_UNISWAP_V3_ROUTER = ISwapRouter(UNISWAP_V3_ROUTER_ADDRESS);
    IQuoter public constant _I_UNISWAP_V3_QUOTER = IQuoter(UNISWAP_V3_QUOTER_ADDRESS);

    // AAVE V3 INTERFACES
    IPool public constant _I_AAVE_V3_POOL = IPool(AAVE_V3_POOL_ADDRESS);
    IPoolDataProvider public constant _I_AAVE_V3_DATA_PROVIDER = IPoolDataProvider(AAVE_V3_DATA_PROVIDER_ADDRESS);

    // DOUGH CONNECTORS ID
    uint256 public constant CONNECTOR_ID0 = 0;
    uint256 public constant CONNECTOR_ID1 = 1;
    uint256 public constant CONNECTOR_ID2 = 2;
    uint256 public constant CONNECTOR_ID3 = 3;
    uint256 public constant CONNECTOR_ID4 = 4;
    uint256 public constant CONNECTOR_ID5 = 5;
    uint256 public constant CONNECTOR_ID6 = 6;
    uint256 public constant CONNECTOR_ID7 = 7;
    uint256 public constant CONNECTOR_ID8 = 8;
    uint256 public constant CONNECTOR_ID9 = 9;
    uint256 public constant CONNECTOR_ID10 = 10;
    uint256 public constant CONNECTOR_ID11 = 11;
    uint256 public constant CONNECTOR_ID12 = 12;
    uint256 public constant CONNECTOR_ID13 = 13;
    uint256 public constant CONNECTOR_ID14 = 14;
    uint256 public constant CONNECTOR_ID15 = 15;
    uint256 public constant CONNECTOR_ID16 = 16;
    uint256 public constant CONNECTOR_ID17 = 17;
    uint256 public constant CONNECTOR_ID18 = 18;
    uint256 public constant CONNECTOR_ID19 = 19;
    uint256 public constant CONNECTOR_ID20 = 20;
    uint256 public constant CONNECTOR_ID21 = 21;
    uint256 public constant CONNECTOR_ID22 = 22;
    uint256 public constant CONNECTOR_ID23 = 23;
    uint256 public constant CONNECTOR_ID24 = 24;
    uint256 public constant CONNECTOR_ID25 = 25;
    uint256 public constant CONNECTOR_ID26 = 26;
    uint256 public constant CONNECTOR_ID27 = 27;
    uint256 public constant CONNECTOR_ID28 = 28;
    uint256 public constant CONNECTOR_ID29 = 29;
    uint256 public constant CONNECTOR_ID30 = 30;
    uint256 public constant CONNECTOR_ID31 = 31;
    uint256 public constant CONNECTOR_ID32 = 32;
    uint256 public constant CONNECTOR_ID33 = 33;

    /**
     * @notice Function to repay AAVE V3 debt with Aave Tokens
     * @param _tokenIn The token address to repay the debt
     * @param _inAmount The amount of the token to repay the debt
     * @dev The token should be whitelisted in the DoughIndex contract
     */
    function repayWithATokens(address _tokenIn, uint256 _inAmount) external {
        _I_AAVE_V3_POOL.repayWithATokens(_tokenIn, _inAmount, VARIABLE_RATE_MODE);
    }

    /**
    * @notice Collects the APY fees for all the whitelisted tokens
    * @param _doughIndex The DoughIndex address
    * @dev The APY fees are collected for all the whitelisted tokens
    */
    function collectApyFees(address _doughIndex) external {
        // Check if the flash borrower is the caller
        if(IDoughIndex(_doughIndex).getFlashBorrowers(address(this))) return;

        // Get the whitelisted tokens
        address[] memory whitelistedTokens = IDoughIndex(_doughIndex).getWhitelistedTokenList();

        // Iterate through the whitelisted tokens
        for (uint i = 0; i < whitelistedTokens.length;) {
            // Get the APY fees for the given token
            (, , uint256 scaledInterest, uint256 minInterest) = IDoughIndex(_doughIndex).borrowFormula(whitelistedTokens[i], address(this));

            // Check if the scaled interest is greater than the minimum interest
            if (scaledInterest > minInterest) collectTreasuryFees(_doughIndex, address(this), whitelistedTokens[i], scaledInterest);

            // Increment the counter
            unchecked { i++; }
        }
    }

    /**
    * @notice Collects the APY fees for the given token if minimum interest is met
    * @param _doughIndex The DoughIndex address
    * @param _token: The whitelisted token address
    */
    function collectAnyApyFees(address _doughIndex, address _token) external {
        // Check if the flash borrower is the caller
        if(IDoughIndex(_doughIndex).getFlashBorrowers(address(this))) return;
        
        // Get the APY fees for the given token
        (, , uint256 scaledInterest, uint256 minInterest) = IDoughIndex(_doughIndex).borrowFormula(_token, address(this));
        
        // Check if the scaled interest is greater than the minimum interest
        if (scaledInterest > minInterest) collectTreasuryFees(_doughIndex, address(this), _token, scaledInterest);
    }

    /**
    * @notice Collects the APY fees for the given token 
    * @param _doughIndex The DoughIndex address
    * @param _token: The whitelisted token address
    */
    function collectApyFeesInterest(address _doughIndex, address _token) external {
        // Check if the flash borrower is the caller
        if(IDoughIndex(_doughIndex).getFlashBorrowers(address(this))) return;
        
        // Get the time when the borrowing started
        (uint256 scaledInterest) = IDoughIndex(_doughIndex).borrowFormulaInterest(_token, address(this));

        // Check if the scaled interest is greater than 0
        if (scaledInterest > 0) collectTreasuryFees(_doughIndex, address(this), _token, scaledInterest);
    }

    /**
    * @notice Collects the APY fees for the given token partially
    * @param _doughIndex The DoughIndex address
    * @param _token: The whitelisted token address
    * @param _partialAmount The partial amount of APY fees
    */
    function collectApyFeesPartially(address _doughIndex, address _token, uint256 _partialAmount) private {
        // Check if the flash borrower is the caller
        if(IDoughIndex(_doughIndex).getFlashBorrowers(address(this))) return;

        // Get the time when the borrowing started
        uint256 timeStartedBorrow = IDoughIndex(_doughIndex).getDsaBorrowStartDate(address(this), _token);

        // Get the scaled interest for the given token
        (uint256 scaledInterest) = IDoughIndex(_doughIndex).borrowFormulaInterest(_token, address(this));

        // Check if the partial amount is greater than the scaled interest
        if (_partialAmount > scaledInterest) revert CustomError("partialAmount >= scaled interest");

        // Calculate the time difference between the current time and the time when the borrowing started
        uint256 timeDiff = block.timestamp - timeStartedBorrow;

        // Calculate the APY fees per second
        uint256 perSecond = scaledInterest / timeDiff;

        // Check if the perSecond is 0
        if (perSecond == 0) revert CustomError("perSecond is 0");

        // Calculate the back time in seconds
        uint256 backTimeInSeconds = (_partialAmount * 1e18) / perSecond;

        // Check if the backTimeInSeconds is 0
        uint256 actualBackTimeInSeconds = backTimeInSeconds / 1e18;

        // Check if the actualBackTimeInSeconds is 0
        if (actualBackTimeInSeconds == 0) revert CustomError("actualBackTimeInSeconds is 0");

        // Calculate the adjusted start time after partial APY fees collection
        uint256 adjustedStartTime = timeStartedBorrow + actualBackTimeInSeconds;

        // Collect the APY fees partially
        collectTreasuryFeesPartially(_doughIndex, _token, address(this), scaledInterest, _partialAmount, adjustedStartTime);
    }

    /**
    * @notice Collects the APY fees for the given token
    * @param _doughIndex The DoughIndex address
    * @param _dsaAddress The DSA address
    * @param _token: The whitelisted token address
    * @param _scaledInterest The scaled interest of APY fees
    */
    function collectTreasuryFees(address _doughIndex, address _dsaAddress, address _token, uint256 _scaledInterest) private {
        // Borrow the APY fees from the Aave V3 pool
        _I_AAVE_V3_POOL.borrow(_token, _scaledInterest, VARIABLE_RATE_MODE, 0, address(this));

        // Transfer the fee to the treasury
        IERC20(_token).safeTransfer(IDoughIndex(_doughIndex).treasury(), _scaledInterest);
        
        // Update the borrow start date to now, as a new fee period starts
        IDoughIndex(_doughIndex).updateBorrowDate(CONNECTOR_ID0, block.timestamp, _dsaAddress, _token);
    }

    /**
    * @notice Collects the APY fees for the given token partially
    * @param _token: The token address to collect the APY fees
    * @param _dsaAddress: The DSA address to collect the APY fees
    * @param _scaledInterest: The scaled interest to collect the APY fees
    * @param _partialAmount: The partial amount to collect the APY fees
    * @param _adjustedStartTime: The adjusted start time after partial APY fees collection
    */
    function collectTreasuryFeesPartially(address _doughIndex, address _token, address _dsaAddress, uint256 _scaledInterest, uint256 _partialAmount, uint256 _adjustedStartTime) private {
        // Check if the scaled interest is greater than the partial amount
        if (_scaledInterest >= _partialAmount) {
            // Borrow the APY fees from the Aave V3 pool
            _I_AAVE_V3_POOL.borrow(_token, _partialAmount, VARIABLE_RATE_MODE, 0, address(this));
            
            // Transfer the fee to the treasury
            IERC20(_token).safeTransfer(IDoughIndex(_doughIndex).treasury(), _partialAmount);
            
            // Update the borrow start date to now, as a new fee period starts
            IDoughIndex(_doughIndex).updateBorrowDate(CONNECTOR_ID0, _adjustedStartTime, _dsaAddress, _token);
        }
    }
}
