pragma solidity ^0.8.17;

import "Utils.sol";
import "DefaultAccess.sol";
import "IDiscountPolicy.sol";
import "IOracleConnector.sol";
import "ReentrancyGuard.sol";
import "ERC20.sol";
import "SafeERC20.sol";


interface IUniswapRouterV3 {
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
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    function WETH9() external view returns (address);
}

interface IPancakeRouterV3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    function WETH9() external view returns (address);
}

contract SpotVault is Utils, DefaultAccess, ReentrancyGuard, ERC20 {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for ERC20;
    using Address for address;
    using Address for address payable;

    enum SlippageType{ SWAP, AUM, NAV }

    enum FeeType { DEPOSIT, REDEEM, ROTATION }

    struct TxParams {
        uint nav;
        uint nominalFinalAum;
        uint aum;
        address[] assets;
        uint256[] prices;
        uint256[] usdValues;
        address feeRecipient;
        address feeAsset;
        uint256 totalSupply;
    }

    struct RotationParams {
        uint256 startAum;
        uint256 srcTokenSize;
        uint256 dstTokenSize;
        bool srcTokenLessThanBefore;
        address nativeToken;
    }

    uint256 public maxAssets;
    mapping (SlippageType => uint256) public slippageTolerances;

    IOracleConnector public oracle;

    // fee variables
    address payable public feeRecipient;
    mapping (FeeType => uint256) public feePercentages;
    address public feeAsset;
    bool public useUniswap;
    IDiscountPolicy public discountPolicy;
    mapping (uint256 => uint256) public feeRecord;
    mapping (address => uint24) public directPoolSwapFee;
    uint256 public immutable FEE_INTERVAL;
    uint256 constant MAX_FEE_PERCENTAGE = 10 * UNIT / 100;

    // immutables
    address public immutable ONE_INCH_AGG_ROUTER;
    address public immutable DIRECT_SWAP_ROUTER;
    address public immutable NATIVE_TOKEN;
    uint256 constant SLIPPAGE_LOWER_BOUND = 5 * UNIT / 1000; // 0.5%
    uint256 constant SLIPPAGE_UPPER_BOUND = UNIT / 5; // 20%

    // constants
    bytes32 public constant ROTATOR = keccak256('ROTATOR');
    bytes32 public constant ORACLE_MGR = keccak256('ORACLE_MGR');
    uint256 public constant UNIT = 10 ** 18;

    EnumerableSet.AddressSet private portfolio;
    EnumerableSet.AddressSet private depositableAssets;

    event DepositableAssetUpdated(address indexed token, bool indexed added);
    event DiscountPolicyUpdated(address discountPolicy);
    event FeeCollected(address indexed feeCollectionToken, uint256 feeAmount);
    event FeeDetailsUpdated(uint256 depositFeePercentage, uint256 redeemFeePercentage, uint256 rotationFeePercentage,
        address feeRecipient, address feeAsset);
    event MaxAssetsUpdated(uint256 newMaxAssets);
    event OracleUpdated(address newAddress);
    event RotationFeeCollected(uint256 indexed weekNumber, uint256 usdValue);
    event SlippageToleranceUpdated(SlippageType indexed slippageType, uint256 tolerance);
    event Transaction(bool indexed isDeposit, address indexed user, address indexed txAsset, uint256 txAmount, uint256 shares);

    modifier reimburseGas() {
        uint256 initialGas = gasleft();
        _;
        payable(msg.sender).sendValue((initialGas - gasleft()) * tx.gasprice);
    }

    constructor(
        string memory name, string memory symbol, address nativeToken,
        address oneinchRouter, address directSwapRouter, uint256 feeInterval,
        address initFeeAsset
    )
    ERC20(name, symbol)
    {
        require(nativeToken != address(0), "z1");
        require(oneinchRouter != address(0), "z2");
        require(directSwapRouter != address(0), "z3");
        require(initFeeAsset != address(0), "z4");

        NATIVE_TOKEN = nativeToken;
        ONE_INCH_AGG_ROUTER = oneinchRouter; // 0x1111111254EEB25477B68fb85Ed929f73A960582;
        DIRECT_SWAP_ROUTER = directSwapRouter;
        _initDefaultAccess(msg.sender);
        _setRoleAdmin(ROTATOR, MASTER);
        _grantRole(ROTATOR, msg.sender);
        _setRoleAdmin(ORACLE_MGR, MASTER);
        _grantRole(ORACLE_MGR, msg.sender);

        FEE_INTERVAL = feeInterval;
        feeRecipient = payable(msg.sender);

        feeAsset = initFeeAsset;
        emit FeeDetailsUpdated(0, 0, 0, msg.sender, initFeeAsset);
    }

    receive() external payable {
        require((msg.sender == ONE_INCH_AGG_ROUTER) || (msg.sender == DIRECT_SWAP_ROUTER), "n1");
    }

    /* Restricted ROTATOR Functions */

    function rotationSwaps(
        address[] calldata srcTokens,
        address[] calldata dstTokens,
        bytes[] calldata dataList,
        uint256[] calldata nativeAmounts
    ) external reimburseGas onlyRole(ROTATOR) nonReentrant
    {
        require(srcTokens.length == dstTokens.length, "l");
        require(srcTokens.length == dataList.length, "l");
        require(nativeAmounts.length == dataList.length, "l");

        RotationParams memory rp;

        rp.startAum = _getAum();
        rp.nativeToken = NATIVE_TOKEN;

        {
            for (uint256 i = 0; i < dataList.length; i++) {
                rp.dstTokenSize = dstTokens[i] == rp.nativeToken ? address(this).balance : ERC20(dstTokens[i]).balanceOf(address(this));
                if (srcTokens[i] != rp.nativeToken) {
                    rp.srcTokenSize = ERC20(srcTokens[i]).balanceOf(address(this));
                    ONE_INCH_AGG_ROUTER.functionCall(dataList[i]);
                    rp.srcTokenLessThanBefore = ERC20(srcTokens[i]).balanceOf(address(this)) < rp.srcTokenSize;
                } else {
                    rp.srcTokenSize = address(this).balance;
                    ONE_INCH_AGG_ROUTER.functionCallWithValue(dataList[i], nativeAmounts[i]);
                    rp.srcTokenLessThanBefore = address(this).balance < rp.srcTokenSize;
                }
                require(rp.srcTokenLessThanBefore, "b2");
                require(
                    (dstTokens[i] == rp.nativeToken ? address(this).balance : ERC20(dstTokens[i]).balanceOf(address(this))) > rp.dstTokenSize,
                    "b3"
                );
                _updatePortfolio(ERC20(srcTokens[i]));
                _updatePortfolio(ERC20(dstTokens[i]));
            }
        }

        require(portfolio.length() <= maxAssets, "m2");
        require(absSlippage(rp.startAum, _getAum(), UNIT) <= slippageTolerances[SlippageType.AUM], "s2");
    }

    /* Restricted OPERATOR Functions */

    function collectFee() external reimburseGas onlyRole(OPERATOR)
    {
        uint256 weekNumber = block.timestamp / FEE_INTERVAL;
        require(feeRecord[weekNumber] == 0, "wf");
        uint256 feeValueInUsd = feePercentages[FeeType.ROTATION] * _getAum() / UNIT;

        (int256 price, uint8 priceDecimals, uint256 timestamp) = oracle.getPriceInUsd(feeAsset);
        ERC20 token = ERC20(feeAsset);

        uint256 tokenSize = feeValueInUsd * (10 ** (priceDecimals + token.decimals())) / uint256(price) / UNIT;
        feeRecord[weekNumber] = feeValueInUsd;
        token.safeTransfer(feeRecipient, tokenSize);
        emit RotationFeeCollected(weekNumber, feeValueInUsd);
    }

    function approveAsset(ERC20 token, address spender, uint256 amount) external reimburseGas onlyRole(OPERATOR)
    {
        require((spender == ONE_INCH_AGG_ROUTER) || (spender == DIRECT_SWAP_ROUTER), "a1");
        token.approve(spender, amount);
    }

    function updateDiscountPolicy(address newDiscountPolicy) external onlyRole(OPERATOR) {
        require(newDiscountPolicy.code.length > 0, "dp");
        discountPolicy = IDiscountPolicy(newDiscountPolicy);
        emit DiscountPolicyUpdated(newDiscountPolicy);
    }

    function updateFeeDetails(
        uint256 newDepositFeePercentage,
        uint256 newRedeemFeePercentage,
        uint256 newRotationFeePercentage,
        address payable newFeeRecipient,
        address newFeeAsset,
        bool useUniswapFlag
    )
    external onlyRole(OPERATOR)
    {
        require(
             (newDepositFeePercentage <= MAX_FEE_PERCENTAGE) &&
                (newRedeemFeePercentage <= MAX_FEE_PERCENTAGE) &&
                (newRotationFeePercentage <= MAX_FEE_PERCENTAGE),
            "mf"
        );
        require(newFeeRecipient != address(0), "z4");
        require(newFeeAsset.code.length > 0, "fa");
        feePercentages[FeeType.DEPOSIT] = newDepositFeePercentage;
        feePercentages[FeeType.REDEEM] = newRedeemFeePercentage;
        feePercentages[FeeType.ROTATION] = newRotationFeePercentage;
        feeRecipient = newFeeRecipient;
        feeAsset = newFeeAsset;
        useUniswap = useUniswapFlag;
        emit FeeDetailsUpdated(
            newDepositFeePercentage, newRedeemFeePercentage, newRotationFeePercentage,
            newFeeRecipient, newFeeAsset);
    }

    function updateMaxAssets(uint256 newMaxAssets) external onlyRole(OPERATOR) {
        require(newMaxAssets >= 2, "m1");
        maxAssets = newMaxAssets;
        emit MaxAssetsUpdated(newMaxAssets);
    }

    function updateSlippageTolerance(SlippageType slippageType, uint256 tolerance) external onlyRole(OPERATOR) {
        require(tolerance >= SLIPPAGE_LOWER_BOUND, "sl");
        require(tolerance <= SLIPPAGE_UPPER_BOUND, "su");
        emit SlippageToleranceUpdated(slippageType, tolerance);
        slippageTolerances[slippageType] = tolerance;
    }

    function addDepositableAsset(address token, uint24 fee) external onlyRole(OPERATOR) {
        require(oracle.isTokenSupported(token), "st");
        depositableAssets.add(token);
        directPoolSwapFee[token] = fee;
        if (token != NATIVE_TOKEN) {
            ERC20(token).approve(DIRECT_SWAP_ROUTER, type(uint256).max);
        }
        emit DepositableAssetUpdated(token, true);
    }

    function removeDepositableAsset(address token) external onlyRole(OPERATOR) {
        require(depositableAssets.contains(token), "da");
        depositableAssets.remove(token);
        directPoolSwapFee[token] = 0;
        if (token != NATIVE_TOKEN) {
            ERC20(token).approve(DIRECT_SWAP_ROUTER, 0);
        }
        emit DepositableAssetUpdated(token, false);
    }

    /* Restricted ORACLE_MGR Functions */
    function updateOracle(address newOracle) external onlyRole(ORACLE_MGR)
    {
        require(newOracle.code.length > 0, "oc");
        oracle = IOracleConnector(newOracle);
        emit OracleUpdated(newOracle);
    }

    /* User Functions */
    function redeem(
        uint256 sharesToRedeem,
        address receivingAsset,
        uint256 minTokensToReceive,
        bytes[] calldata dataList,
        bool useDiscount
    )
    external nonReentrant
    returns (uint256 tokensToReturn)
    {
        require(depositableAssets.contains(receivingAsset), "da");
        TxParams memory dp;
        (dp.aum, dp.assets, dp.prices, dp.usdValues) = _getAllocations(0);
        dp.nav = getNav();
        dp.nominalFinalAum = dp.aum - (dp.nav * sharesToRedeem / UNIT);
        require(dataList.length == dp.assets.length, "l");
        dp.totalSupply = totalSupply();
        uint256 rcvTokenAccumulator =
        (receivingAsset == NATIVE_TOKEN ? address(this).balance : ERC20(receivingAsset).balanceOf(address(this)))
         * sharesToRedeem / dp.totalSupply;

        for (uint256 i = 0; i < dp.assets.length; i++) {
            if (dp.assets[i] == receivingAsset) {
                continue;
            }
            uint256 rcvTokenSize = receivingAsset == NATIVE_TOKEN ? address(this).balance :
                ERC20(receivingAsset).balanceOf(address(this));

            if (dp.assets[i] != NATIVE_TOKEN) {
                ONE_INCH_AGG_ROUTER.functionCall(dataList[i]);
            } else {
                uint256 sizeToSwap = address(this).balance * sharesToRedeem / dp.totalSupply;
                ONE_INCH_AGG_ROUTER.functionCallWithValue(dataList[i], sizeToSwap);
            }

            rcvTokenAccumulator += receivingAsset == NATIVE_TOKEN ? address(this).balance - rcvTokenSize :
                ERC20(receivingAsset).balanceOf(address(this)) - rcvTokenSize;
        }
        _burn(msg.sender, sharesToRedeem);

        uint256 feePortion = rcvTokenAccumulator * feePercentages[FeeType.REDEEM] / UNIT;
        dp.feeRecipient = feeRecipient;
        if (useDiscount) {
            (uint256 discountTokensToSpend, uint256 discountMultiplier) = discountPolicy.computeDiscountTokensToSpend(_getUsdValue(receivingAsset, feePortion));
            ERC20(discountPolicy.discountToken()).safeTransferFrom(msg.sender, dp.feeRecipient, discountTokensToSpend);
            feePortion = feePortion * discountMultiplier / (10 ** discountPolicy.decimals());
            emit FeeCollected(discountPolicy.discountToken(), discountTokensToSpend);
        }

        tokensToReturn = rcvTokenAccumulator - feePortion;
        require((tokensToReturn) >= minTokensToReceive, "s4");
        if (receivingAsset == NATIVE_TOKEN) {
            payable(msg.sender).sendValue(tokensToReturn);
        } else {
            ERC20(receivingAsset).safeTransfer(msg.sender, tokensToReturn);
        }

        if (feePortion > 0) {
            uint256 feeTokenAmount;
            dp.feeAsset = feeAsset;
            if (receivingAsset == dp.feeAsset) {
                feeTokenAmount = feePortion;
            }
            else {
                feeTokenAmount = _directSwapForFee(
                    feePortion,
                    0, // don't hinder redemptions due to low liquidity for the fee conversion.
                    receivingAsset,
                    dp.feeAsset
                );
            }

            ERC20(dp.feeAsset).safeTransfer(dp.feeRecipient, feeTokenAmount);
            emit FeeCollected(dp.feeAsset, feeTokenAmount);
        }

        require(absSlippage(dp.nav, getNav(), UNIT) <= slippageTolerances[SlippageType.NAV], "s3");
        _postSwapHandler(receivingAsset, dp);

        emit Transaction(false, msg.sender, receivingAsset, tokensToReturn, sharesToRedeem);
    }

    function deposit(
        ERC20 token,
        uint256 amountIn,
        uint256 minSharesToReceive,
        bytes[] calldata dataList,
        bytes calldata feeSwapData,
        bool useDiscount
    )
    external nonReentrant
    returns (uint256 sharesToMint)
    {
        require(address(token) != NATIVE_TOKEN, "n2");

        // handle discount
        uint256 feeAmount = amountIn * feePercentages[FeeType.DEPOSIT] / UNIT;
        if (useDiscount) {
            (uint256 discountTokensToSpend, uint256 discountMultiplier) = discountPolicy.computeDiscountTokensToSpend(_getUsdValue(address(token), feeAmount));
            ERC20(discountPolicy.discountToken()).safeTransferFrom(msg.sender, feeRecipient, discountTokensToSpend);
            feeAmount = feeAmount * discountMultiplier / (10 ** discountPolicy.decimals());
            emit FeeCollected(discountPolicy.discountToken(), discountTokensToSpend);
        }
        uint256 effectiveAmount = amountIn - feeAmount;

        // compute swap allocation, do this before moving in the deposited token.
        TxParams memory dp = _preSwapHandler(token, minSharesToReceive);
        dp.nominalFinalAum = dp.aum + _getUsdValue(address(token), effectiveAmount);
        require(dp.assets.length == dataList.length, "l");

        // move deposited token in.
        token.safeTransferFrom(msg.sender, address(this), amountIn);

        // swap and get fees
        if (feeAmount > 0) {
            uint256 feeTokenDeltaBal;
            ERC20 feeToken = ERC20(feeAsset);
            if (feeToken != token) {
                uint256 feeTokenBeforeBal = feeToken.balanceOf(address(this));
                ONE_INCH_AGG_ROUTER.functionCall(feeSwapData);
                feeTokenDeltaBal = feeToken.balanceOf(address(this)) - feeTokenBeforeBal;
            } else {
                feeTokenDeltaBal = feeAmount;
            }
            feeToken.safeTransfer(feeRecipient, feeTokenDeltaBal);
            emit FeeCollected(address(feeToken), feeTokenDeltaBal);
        }

        // perform swaps
        for (uint256 i = 0; i < dp.assets.length; i++) {
            if (dp.assets[i] == address(token)) {
                continue;
            }
            ONE_INCH_AGG_ROUTER.functionCall(dataList[i]);
        }
        if (dp.nav != 0) {
            uint256 endAum = _postSwapHandler(address(token), dp);
            sharesToMint = (endAum * UNIT / dp.nav) - totalSupply();

            require(sharesToMint >= minSharesToReceive, "s4");
            _mint(msg.sender, sharesToMint);
            require(absSlippage(dp.nav, getNav(), UNIT) <= slippageTolerances[SlippageType.NAV], "s3");
        } else { // cold start
            _updatePortfolio(token);
            sharesToMint = _getAum();
            _mint(msg.sender, sharesToMint);
        }
        emit Transaction(true, msg.sender, address(token), amountIn, sharesToMint);
    }

    function depositNative(
        uint256 minSharesToReceive,
        bytes[] calldata dataList,
        uint256[] calldata nativeAmounts,
        bytes calldata feeSwapData,
        bool useDiscount
    )
    payable external nonReentrant
    returns (uint256 sharesToMint)
    {
        require(depositableAssets.contains(NATIVE_TOKEN), "da");

        // handle discount
        uint256 feeAmount = msg.value * feePercentages[FeeType.DEPOSIT] / UNIT;
        if (useDiscount) {
            (uint256 discountTokensToSpend, uint256 discountMultipler) = discountPolicy.computeDiscountTokensToSpend(_getUsdValue(NATIVE_TOKEN, feeAmount));
            ERC20(discountPolicy.discountToken()).safeTransferFrom(msg.sender, feeRecipient, discountTokensToSpend);
            feeAmount = feeAmount * discountMultipler / (10 ** discountPolicy.decimals());
            emit FeeCollected(discountPolicy.discountToken(), discountTokensToSpend);
        }

        uint256 amount = msg.value - feeAmount;
        if (feeAmount > 0) {
            ERC20 feeToken = ERC20(feeAsset);
            uint256 feeTokenBeforeBal = feeToken.balanceOf(address(this));
            ONE_INCH_AGG_ROUTER.functionCallWithValue(feeSwapData, feeAmount);
            uint256 feeTokenDeltaBal = feeToken.balanceOf(address(this)) - feeTokenBeforeBal;
            feeToken.safeTransfer(feeRecipient, feeTokenDeltaBal);
            emit FeeCollected(address(feeToken), feeTokenDeltaBal);
        }

        // compute swap allocation. account for deposited native token that has already
        // arrived in contract at beginning of function.
        TxParams memory dp;
        dp.totalSupply = totalSupply();
        (dp.aum, dp.assets, dp.prices, dp.usdValues) = _getAllocations(amount);
        if (dp.aum == 0) {
            dp.nav = 0;
        } else {
            dp.nav = dp.aum * UNIT / dp.totalSupply;
        }
        dp.nominalFinalAum = dp.aum + _getUsdValue(NATIVE_TOKEN, amount);
        require(dp.assets.length == dataList.length, "l");


        // perform swaps
        for (uint256 i = 0; i < dp.assets.length; i++) {
            if (dp.assets[i] == NATIVE_TOKEN) {
                continue;
            }

            ONE_INCH_AGG_ROUTER.functionCallWithValue(dataList[i], nativeAmounts[i]);
        }

        if (dp.nav != 0) {
            uint256 endAum = _postSwapHandler(NATIVE_TOKEN, dp);
            sharesToMint = (endAum * UNIT / dp.nav) - dp.totalSupply;

            require(sharesToMint >= minSharesToReceive, "s4");
            _mint(msg.sender, sharesToMint);
            require(absSlippage(dp.nav, getNav(), UNIT) <= slippageTolerances[SlippageType.NAV], "s3");
        } else { // cold start
            _updatePortfolio(ERC20(NATIVE_TOKEN));
            sharesToMint = _getAum();
            _mint(msg.sender, sharesToMint);
        }
        emit Transaction(true, msg.sender, NATIVE_TOKEN, msg.value, sharesToMint);
    }

    /* Private Write Functions */

    function _directSwapForFee(
        uint256 amountIn,
        uint256 amountOutMin,
        address srcToken,
        address dstToken
    ) private returns (uint256 actualAmountOut){
        if (useUniswap) {
            IUniswapRouterV3.ExactInputSingleParams memory data;
            data.amountIn = amountIn;
            data.amountOutMinimum = amountOutMin;
            data.tokenIn = srcToken == NATIVE_TOKEN ? IUniswapRouterV3(DIRECT_SWAP_ROUTER).WETH9() : srcToken;
            data.tokenOut = dstToken;
            data.recipient = address(this);
            data.sqrtPriceLimitX96 = 0;
            data.fee = directPoolSwapFee[srcToken];
            data.deadline = block.timestamp + 60;
            actualAmountOut = srcToken == NATIVE_TOKEN ?
                IUniswapRouterV3(DIRECT_SWAP_ROUTER).exactInputSingle{value: amountIn}(data) :
                IUniswapRouterV3(DIRECT_SWAP_ROUTER).exactInputSingle(data);
        } else {
            IPancakeRouterV3.ExactInputSingleParams memory data;
            data.amountIn = amountIn;
            data.amountOutMinimum = amountOutMin;
            data.tokenIn = srcToken == NATIVE_TOKEN ? IPancakeRouterV3(DIRECT_SWAP_ROUTER).WETH9() : srcToken;
            data.tokenOut = dstToken;
            data.recipient = address(this);
            data.sqrtPriceLimitX96 = 0;
            data.fee = directPoolSwapFee[srcToken];
            actualAmountOut = srcToken == NATIVE_TOKEN ?
                IPancakeRouterV3(DIRECT_SWAP_ROUTER).exactInputSingle{value: amountIn}(data) :
                IPancakeRouterV3(DIRECT_SWAP_ROUTER).exactInputSingle(data);
        }
    }

    function _preSwapHandler(
        ERC20 token,
        uint256 minSharesToReceive
    ) private returns (TxParams memory dp) {
        require(depositableAssets.contains(address(token)), "da");
        (dp.aum, dp.assets, dp.prices, dp.usdValues) = _getAllocations(0);
        dp.nav = dp.aum == 0 ? 0 : getNav();
        return dp;
    }

    function _postSwapHandler(address token, TxParams memory dp)
    private returns (uint256 endAum) {
        if (!portfolio.contains(token)) {
                require(
                (token == NATIVE_TOKEN ? address(this).balance: ERC20(token).balanceOf(address(this))) == 0, "b1");
            }
        uint256[] memory newUsdValues;
        (endAum, newUsdValues) = _getAllocationsWithPrices(dp.assets, dp.prices);
        require(absSlippage(dp.nominalFinalAum, endAum, UNIT) <= slippageTolerances[SlippageType.AUM], "s2");

        // check that the allocations are not unreasonably skewed
        for (uint256 i = 0; i < dp.assets.length; i++) {
            uint256 initialAlloc = dp.usdValues[i] * UNIT / dp.aum;
            uint256 newAlloc = newUsdValues[i] * UNIT / endAum;
            require(absSlippage(initialAlloc, newAlloc, UNIT) <= slippageTolerances[SlippageType.SWAP], "s1");
        }
    }

    function _updatePortfolio(ERC20 token) private {
        uint256 balance = address(token) == NATIVE_TOKEN ? address(this).balance : token.balanceOf(address(this));
        if (balance > 0) {
            require(oracle.isTokenSupported(address(token)), "st");
            portfolio.add(address(token));
        } else {
            require(address(token) != NATIVE_TOKEN, "p1");
            require(address(token) != feeAsset, "p2");
            portfolio.remove(address(token));
        }
    }

    /* View Functions */

    function getAllocations()
    external view
    returns (uint256 aumInUsd, address[] memory assets, uint256[] memory prices, uint256[] memory usdValues)
    {
        return _getAllocations(0);
    }

    function getDepositableAssets()
    external view
    returns (address[] memory)
    {
        return depositableAssets.values();
    }

    function getNav() public view returns (uint256 nav) {
        return _getAum() * UNIT / totalSupply();
    }

    function _getAllocations(uint256 nativeIn) private view
    returns (uint256 aumInUsd, address[] memory assets, uint256[] memory prices, uint256[] memory usdValues)
    {
        uint256 len = portfolio.length();
        aumInUsd = 0;
        assets = new address[](len);
        usdValues = new uint256[](len);
        prices = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            address token = portfolio.at(i);
            uint256 size = address(token) == NATIVE_TOKEN ? address(this).balance - nativeIn : ERC20(token).balanceOf(address(this));
            uint256 priceUnit18 = _getPriceUnit18(token);
            uint256 usdValue = _getUsdValueUnit18(token, size, priceUnit18);
            aumInUsd += usdValue;
            assets[i] = token;
            usdValues[i] = usdValue;
            prices[i] = priceUnit18;
        }
    }

    function _getAllocationsWithPrices(address[] memory tokens, uint256[] memory prices) private view
    returns (uint256 aumInUsd, uint256[] memory usdValues)
    {
        uint256 len = tokens.length;
        aumInUsd = 0;
        usdValues = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            address token = tokens[i];
            uint256 size = address(token) == NATIVE_TOKEN ? address(this).balance : ERC20(token).balanceOf(address(this));
            uint256 usdValue = _getUsdValueUnit18(token, size, prices[i]);
            aumInUsd += usdValue;
            usdValues[i] = usdValue;
        }
    }

    function _getAum() private view returns (uint256 aum) {
        (aum, , ,) = _getAllocations(0);
    }

    function _getPriceUnit18(address token) private view returns (uint256 priceUnit18) {
        (int256 price, uint8 priceDecimals, ) = oracle.getPriceInUsd(token);
        priceUnit18 = uint256(price) * (10 ** (18 - priceDecimals));  // does not support assets with decimals > 18
    }

    function _getUsdValue(address token, uint256 size) private view returns (uint256 usdValue) {
        uint256 unit = token == NATIVE_TOKEN ? 1e18 : 10 ** ERC20(token).decimals();
        (int256 price, uint8 priceDecimals, uint256 timestamp) = oracle.getPriceInUsd(token);
        usdValue = uint256(price) * size * UNIT / unit / (10 ** priceDecimals);
    }

    function _getUsdValueUnit18(address token, uint256 size, uint256 priceUnit18) private view returns (uint256 usdValueUnit18) {
        uint8 _decimals = token == NATIVE_TOKEN ? 18 : ERC20(token).decimals();
        usdValueUnit18 = priceUnit18 * size / (10 ** _decimals);
    }
}
pragma solidity ^0.8.0;
import "EnumerableSet.sol";

abstract contract Utils {
    function absSlippage(uint256 start, uint256 end, uint256 unit) internal pure returns (uint256) {
        uint256 diff = start > end ? start - end : end - start;
        return (diff * unit) / start;
    }
}
pragma solidity ^0.8.20;

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
 * ```solidity
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
 *
 * [WARNING]
 * ====
 * Trying to delete such a structure from storage will likely result in data corruption, rendering the structure
 * unusable.
 * See https://github.com/ethereum/solidity/pull/11843[ethereum/solidity#11843] for more info.
 *
 * In order to clean an EnumerableSet, you can either remove all elements one by one or create a fresh instance using an
 * array of EnumerableSet.
 * ====
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
        // Position is the index of the value in the `values` array plus 1.
        // Position 0 is used to mean a value is not in the set.
        mapping(bytes32 value => uint256) _positions;
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
            set._positions[value] = set._values.length;
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
        // We cache the value's position to prevent multiple reads from the same storage slot
        uint256 position = set._positions[value];

        if (position != 0) {
            // Equivalent to contains(set, value)
            // To delete an element from the _values array in O(1), we swap the element to delete with the last one in
            // the array, and then remove the last element (sometimes called as 'swap and pop').
            // This modifies the order of the array, as noted in {at}.

            uint256 valueIndex = position - 1;
            uint256 lastIndex = set._values.length - 1;

            if (valueIndex != lastIndex) {
                bytes32 lastValue = set._values[lastIndex];

                // Move the lastValue to the index where the value to delete is
                set._values[valueIndex] = lastValue;
                // Update the tracked position of the lastValue (that was just moved)
                set._positions[lastValue] = position;
            }

            // Delete the slot where the moved value was stored
            set._values.pop();

            // Delete the tracked position for the deleted slot
            delete set._positions[value];

            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function _contains(Set storage set, bytes32 value) private view returns (bool) {
        return set._positions[value] != 0;
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
        bytes32[] memory store = _values(set._inner);
        bytes32[] memory result;

        /// @solidity memory-safe-assembly
        assembly {
            result := store
        }

        return result;
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

        /// @solidity memory-safe-assembly
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
     * @dev Returns the number of values in the set. O(1).
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

        /// @solidity memory-safe-assembly
        assembly {
            result := store
        }

        return result;
    }
}
pragma solidity ^0.8.0;
import "AccessControlEnumerable.sol";

abstract contract DefaultAccess is AccessControlEnumerable {
    bytes32 public constant MASTER = keccak256('MASTER');
    bytes32 public constant OPERATOR = keccak256('OPERATOR');

    function _initDefaultAccess(address admin_) internal {
        _grantRole(MASTER, admin_);
        _setRoleAdmin(MASTER, MASTER);
        _grantRole(OPERATOR, admin_);
        _setRoleAdmin(OPERATOR, MASTER);
    }
}
pragma solidity ^0.8.20;

import {IAccessControlEnumerable} from "IAccessControlEnumerable.sol";
import {AccessControl} from "AccessControl.sol";
import {EnumerableSet} from "EnumerableSet.sol";

/**
 * @dev Extension of {AccessControl} that allows enumerating the members of each role.
 */
abstract contract AccessControlEnumerable is IAccessControlEnumerable, AccessControl {
    using EnumerableSet for EnumerableSet.AddressSet;

    mapping(bytes32 role => EnumerableSet.AddressSet) private _roleMembers;

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
    function getRoleMember(bytes32 role, uint256 index) public view virtual returns (address) {
        return _roleMembers[role].at(index);
    }

    /**
     * @dev Returns the number of accounts that have `role`. Can be used
     * together with {getRoleMember} to enumerate all bearers of a role.
     */
    function getRoleMemberCount(bytes32 role) public view virtual returns (uint256) {
        return _roleMembers[role].length();
    }

    /**
     * @dev Overload {AccessControl-_grantRole} to track enumerable memberships
     */
    function _grantRole(bytes32 role, address account) internal virtual override returns (bool) {
        bool granted = super._grantRole(role, account);
        if (granted) {
            _roleMembers[role].add(account);
        }
        return granted;
    }

    /**
     * @dev Overload {AccessControl-_revokeRole} to track enumerable memberships
     */
    function _revokeRole(bytes32 role, address account) internal virtual override returns (bool) {
        bool revoked = super._revokeRole(role, account);
        if (revoked) {
            _roleMembers[role].remove(account);
        }
        return revoked;
    }
}
pragma solidity ^0.8.20;

import {IAccessControl} from "IAccessControl.sol";

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
pragma solidity ^0.8.20;

/**
 * @dev External interface of AccessControl declared to support ERC165 detection.
 */
interface IAccessControl {
    /**
     * @dev The `account` is missing a role.
     */
    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);

    /**
     * @dev The caller of a function is not the expected one.
     *
     * NOTE: Don't confuse with {AccessControlUnauthorizedAccount}.
     */
    error AccessControlBadConfirmation();

    /**
     * @dev Emitted when `newAdminRole` is set as ``role``'s admin role, replacing `previousAdminRole`
     *
     * `DEFAULT_ADMIN_ROLE` is the starting admin for all roles, despite
     * {RoleAdminChanged} not being emitted signaling this.
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
     * - the caller must be `callerConfirmation`.
     */
    function renounceRole(bytes32 role, address callerConfirmation) external;
}
pragma solidity ^0.8.20;

import {IAccessControl} from "IAccessControl.sol";
import {Context} from "Context.sol";
import {ERC165} from "ERC165.sol";

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
 * ```solidity
 * bytes32 public constant MY_ROLE = keccak256("MY_ROLE");
 * ```
 *
 * Roles can be used to represent a set of permissions. To restrict access to a
 * function call, use {hasRole}:
 *
 * ```solidity
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
 * accounts that have been granted it. We recommend using {AccessControlDefaultAdminRules}
 * to enforce additional security measures for this role.
 */
abstract contract AccessControl is Context, IAccessControl, ERC165 {
    struct RoleData {
        mapping(address account => bool) hasRole;
        bytes32 adminRole;
    }

    mapping(bytes32 role => RoleData) private _roles;

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    /**
     * @dev Modifier that checks that an account has a specific role. Reverts
     * with an {AccessControlUnauthorizedAccount} error including the required role.
     */
    modifier onlyRole(bytes32 role) {
        _checkRole(role);
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
    function hasRole(bytes32 role, address account) public view virtual returns (bool) {
        return _roles[role].hasRole[account];
    }

    /**
     * @dev Reverts with an {AccessControlUnauthorizedAccount} error if `_msgSender()`
     * is missing `role`. Overriding this function changes the behavior of the {onlyRole} modifier.
     */
    function _checkRole(bytes32 role) internal view virtual {
        _checkRole(role, _msgSender());
    }

    /**
     * @dev Reverts with an {AccessControlUnauthorizedAccount} error if `account`
     * is missing `role`.
     */
    function _checkRole(bytes32 role, address account) internal view virtual {
        if (!hasRole(role, account)) {
            revert AccessControlUnauthorizedAccount(account, role);
        }
    }

    /**
     * @dev Returns the admin role that controls `role`. See {grantRole} and
     * {revokeRole}.
     *
     * To change a role's admin, use {_setRoleAdmin}.
     */
    function getRoleAdmin(bytes32 role) public view virtual returns (bytes32) {
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
     *
     * May emit a {RoleGranted} event.
     */
    function grantRole(bytes32 role, address account) public virtual onlyRole(getRoleAdmin(role)) {
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
     *
     * May emit a {RoleRevoked} event.
     */
    function revokeRole(bytes32 role, address account) public virtual onlyRole(getRoleAdmin(role)) {
        _revokeRole(role, account);
    }

    /**
     * @dev Revokes `role` from the calling account.
     *
     * Roles are often managed via {grantRole} and {revokeRole}: this function's
     * purpose is to provide a mechanism for accounts to lose their privileges
     * if they are compromised (such as when a trusted device is misplaced).
     *
     * If the calling account had been revoked `role`, emits a {RoleRevoked}
     * event.
     *
     * Requirements:
     *
     * - the caller must be `callerConfirmation`.
     *
     * May emit a {RoleRevoked} event.
     */
    function renounceRole(bytes32 role, address callerConfirmation) public virtual {
        if (callerConfirmation != _msgSender()) {
            revert AccessControlBadConfirmation();
        }

        _revokeRole(role, callerConfirmation);
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

    /**
     * @dev Attempts to grant `role` to `account` and returns a boolean indicating if `role` was granted.
     *
     * Internal function without access restriction.
     *
     * May emit a {RoleGranted} event.
     */
    function _grantRole(bytes32 role, address account) internal virtual returns (bool) {
        if (!hasRole(role, account)) {
            _roles[role].hasRole[account] = true;
            emit RoleGranted(role, account, _msgSender());
            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Attempts to revoke `role` to `account` and returns a boolean indicating if `role` was revoked.
     *
     * Internal function without access restriction.
     *
     * May emit a {RoleRevoked} event.
     */
    function _revokeRole(bytes32 role, address account) internal virtual returns (bool) {
        if (hasRole(role, account)) {
            _roles[role].hasRole[account] = false;
            emit RoleRevoked(role, account, _msgSender());
            return true;
        } else {
            return false;
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

import {IERC165} from "IERC165.sol";

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
 */
abstract contract ERC165 is IERC165 {
    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}
pragma solidity ^0.8.20;

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
pragma solidity ^0.8.0;

interface IDiscountPolicy {

    function computeDiscountTokensToSpend(uint256 undiscountedFeeInUsd)
    external view returns (uint256 discountTokensToSpend, uint256 discountMultiplier);

    function discountToken() external view returns (address);
    function discountTokenRate() external view returns (uint256);
    function discountRate() external view returns (uint256);
    function decimals() external view returns (uint8);

    event DiscountTokenRateUpdated(uint256 indexed newDiscountRate);
    event DiscountRateUpdated(uint256 indexed newDiscountRate);

}
pragma solidity ^0.8.0;

interface IOracleConnector {
    function getPriceInUsd(address token) external view returns (int256, uint8, uint256);
    function getSupportedTokens() external view returns (address[] memory);
    function isTokenSupported(address token) external view returns (bool);
}
pragma solidity ^0.8.20;

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
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    uint256 private _status;

    /**
     * @dev Unauthorized reentrant call.
     */
    error ReentrancyGuardReentrantCall();

    constructor() {
        _status = NOT_ENTERED;
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
        // On the first call to nonReentrant, _status will be NOT_ENTERED
        if (_status == ENTERED) {
            revert ReentrancyGuardReentrantCall();
        }

        // Any calls to nonReentrant after this point will fail
        _status = ENTERED;
    }

    function _nonReentrantAfter() private {
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = NOT_ENTERED;
    }

    /**
     * @dev Returns true if the reentrancy guard is currently set to "entered", which indicates there is a
     * `nonReentrant` function in the call stack.
     */
    function _reentrancyGuardEntered() internal view returns (bool) {
        return _status == ENTERED;
    }
}
pragma solidity ^0.8.20;

import {IERC20} from "IERC20.sol";
import {IERC20Metadata} from "IERC20Metadata.sol";
import {Context} from "Context.sol";
import {IERC20Errors} from "draft-IERC6093.sol";

/**
 * @dev Implementation of the {IERC20} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
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
 */
abstract contract ERC20 is Context, IERC20, IERC20Metadata, IERC20Errors {
    mapping(address account => uint256) private _balances;

    mapping(address account => mapping(address spender => uint256)) private _allowances;

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
    function name() public view virtual returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view virtual returns (string memory) {
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
    function decimals() public view virtual returns (uint8) {
        return 18;
    }

    /**
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() public view virtual returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IERC20-balanceOf}.
     */
    function balanceOf(address account) public view virtual returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - the caller must have a balance of at least `value`.
     */
    function transfer(address to, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, value);
        return true;
    }

    /**
     * @dev See {IERC20-allowance}.
     */
    function allowance(address owner, address spender) public view virtual returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * NOTE: If `value` is the maximum `uint256`, the allowance is not updated on
     * `transferFrom`. This is semantically equivalent to an infinite approval.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, value);
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
     * - `from` must have a balance of at least `value`.
     * - the caller must have allowance for ``from``'s tokens of at least
     * `value`.
     */
    function transferFrom(address from, address to, uint256 value) public virtual returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transfer(from, to, value);
        return true;
    }

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to`.
     *
     * This internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead.
     */
    function _transfer(address from, address to, uint256 value) internal {
        if (from == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        if (to == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _update(from, to, value);
    }

    /**
     * @dev Transfers a `value` amount of tokens from `from` to `to`, or alternatively mints (or burns) if `from`
     * (or `to`) is the zero address. All customizations to transfers, mints, and burns should be done by overriding
     * this function.
     *
     * Emits a {Transfer} event.
     */
    function _update(address from, address to, uint256 value) internal virtual {
        if (from == address(0)) {
            // Overflow check required: The rest of the code assumes that totalSupply never overflows
            _totalSupply += value;
        } else {
            uint256 fromBalance = _balances[from];
            if (fromBalance < value) {
                revert ERC20InsufficientBalance(from, fromBalance, value);
            }
            unchecked {
                // Overflow not possible: value <= fromBalance <= totalSupply.
                _balances[from] = fromBalance - value;
            }
        }

        if (to == address(0)) {
            unchecked {
                // Overflow not possible: value <= totalSupply or value <= fromBalance <= totalSupply.
                _totalSupply -= value;
            }
        } else {
            unchecked {
                // Overflow not possible: balance + value is at most totalSupply, which we know fits into a uint256.
                _balances[to] += value;
            }
        }

        emit Transfer(from, to, value);
    }

    /**
     * @dev Creates a `value` amount of tokens and assigns them to `account`, by transferring it from address(0).
     * Relies on the `_update` mechanism
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead.
     */
    function _mint(address account, uint256 value) internal {
        if (account == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _update(address(0), account, value);
    }

    /**
     * @dev Destroys a `value` amount of tokens from `account`, lowering the total supply.
     * Relies on the `_update` mechanism.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead
     */
    function _burn(address account, uint256 value) internal {
        if (account == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        _update(account, address(0), value);
    }

    /**
     * @dev Sets `value` as the allowance of `spender` over the `owner` s tokens.
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
     *
     * Overrides to this logic should be done to the variant with an additional `bool emitEvent` argument.
     */
    function _approve(address owner, address spender, uint256 value) internal {
        _approve(owner, spender, value, true);
    }

    /**
     * @dev Variant of {_approve} with an optional flag to enable or disable the {Approval} event.
     *
     * By default (when calling {_approve}) the flag is set to true. On the other hand, approval changes made by
     * `_spendAllowance` during the `transferFrom` operation set the flag to false. This saves gas by not emitting any
     * `Approval` event during `transferFrom` operations.
     *
     * Anyone who wishes to continue emitting `Approval` events on the`transferFrom` operation can force the flag to
     * true using the following override:
     * ```
     * function _approve(address owner, address spender, uint256 value, bool) internal virtual override {
     *     super._approve(owner, spender, value, true);
     * }
     * ```
     *
     * Requirements are the same as {_approve}.
     */
    function _approve(address owner, address spender, uint256 value, bool emitEvent) internal virtual {
        if (owner == address(0)) {
            revert ERC20InvalidApprover(address(0));
        }
        if (spender == address(0)) {
            revert ERC20InvalidSpender(address(0));
        }
        _allowances[owner][spender] = value;
        if (emitEvent) {
            emit Approval(owner, spender, value);
        }
    }

    /**
     * @dev Updates `owner` s allowance for `spender` based on spent `value`.
     *
     * Does not update the allowance value in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Does not emit an {Approval} event.
     */
    function _spendAllowance(address owner, address spender, uint256 value) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < value) {
                revert ERC20InsufficientAllowance(spender, currentAllowance, value);
            }
            unchecked {
                _approve(owner, spender, currentAllowance - value, false);
            }
        }
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

import {IERC20} from "IERC20.sol";

/**
 * @dev Interface for the optional metadata functions from the ERC20 standard.
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
pragma solidity ^0.8.20;

/**
 * @dev Standard ERC20 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC20 tokens.
 */
interface IERC20Errors {
    /**
     * @dev Indicates an error related to the current `balance` of a `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param balance Current balance for the interacting account.
     * @param needed Minimum amount required to perform a transfer.
     */
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);

    /**
     * @dev Indicates a failure with the token `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     */
    error ERC20InvalidSender(address sender);

    /**
     * @dev Indicates a failure with the token `receiver`. Used in transfers.
     * @param receiver Address to which tokens are being transferred.
     */
    error ERC20InvalidReceiver(address receiver);

    /**
     * @dev Indicates a failure with the `spender`’s `allowance`. Used in transfers.
     * @param spender Address that may be allowed to operate on tokens without being their owner.
     * @param allowance Amount of tokens a `spender` is allowed to operate with.
     * @param needed Minimum amount required to perform a transfer.
     */
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    /**
     * @dev Indicates a failure with the `approver` of a token to be approved. Used in approvals.
     * @param approver Address initiating an approval operation.
     */
    error ERC20InvalidApprover(address approver);

    /**
     * @dev Indicates a failure with the `spender` to be approved. Used in approvals.
     * @param spender Address that may be allowed to operate on tokens without being their owner.
     */
    error ERC20InvalidSpender(address spender);
}

/**
 * @dev Standard ERC721 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC721 tokens.
 */
interface IERC721Errors {
    /**
     * @dev Indicates that an address can't be an owner. For example, `address(0)` is a forbidden owner in EIP-20.
     * Used in balance queries.
     * @param owner Address of the current owner of a token.
     */
    error ERC721InvalidOwner(address owner);

    /**
     * @dev Indicates a `tokenId` whose `owner` is the zero address.
     * @param tokenId Identifier number of a token.
     */
    error ERC721NonexistentToken(uint256 tokenId);

    /**
     * @dev Indicates an error related to the ownership over a particular token. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param tokenId Identifier number of a token.
     * @param owner Address of the current owner of a token.
     */
    error ERC721IncorrectOwner(address sender, uint256 tokenId, address owner);

    /**
     * @dev Indicates a failure with the token `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     */
    error ERC721InvalidSender(address sender);

    /**
     * @dev Indicates a failure with the token `receiver`. Used in transfers.
     * @param receiver Address to which tokens are being transferred.
     */
    error ERC721InvalidReceiver(address receiver);

    /**
     * @dev Indicates a failure with the `operator`’s approval. Used in transfers.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     * @param tokenId Identifier number of a token.
     */
    error ERC721InsufficientApproval(address operator, uint256 tokenId);

    /**
     * @dev Indicates a failure with the `approver` of a token to be approved. Used in approvals.
     * @param approver Address initiating an approval operation.
     */
    error ERC721InvalidApprover(address approver);

    /**
     * @dev Indicates a failure with the `operator` to be approved. Used in approvals.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     */
    error ERC721InvalidOperator(address operator);
}

/**
 * @dev Standard ERC1155 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC1155 tokens.
 */
interface IERC1155Errors {
    /**
     * @dev Indicates an error related to the current `balance` of a `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param balance Current balance for the interacting account.
     * @param needed Minimum amount required to perform a transfer.
     * @param tokenId Identifier number of a token.
     */
    error ERC1155InsufficientBalance(address sender, uint256 balance, uint256 needed, uint256 tokenId);

    /**
     * @dev Indicates a failure with the token `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     */
    error ERC1155InvalidSender(address sender);

    /**
     * @dev Indicates a failure with the token `receiver`. Used in transfers.
     * @param receiver Address to which tokens are being transferred.
     */
    error ERC1155InvalidReceiver(address receiver);

    /**
     * @dev Indicates a failure with the `operator`’s approval. Used in transfers.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     * @param owner Address of the current owner of a token.
     */
    error ERC1155MissingApprovalForAll(address operator, address owner);

    /**
     * @dev Indicates a failure with the `approver` of a token to be approved. Used in approvals.
     * @param approver Address initiating an approval operation.
     */
    error ERC1155InvalidApprover(address approver);

    /**
     * @dev Indicates a failure with the `operator` to be approved. Used in approvals.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     */
    error ERC1155InvalidOperator(address operator);

    /**
     * @dev Indicates an array length mismatch between ids and values in a safeBatchTransferFrom operation.
     * Used in batch transfers.
     * @param idsLength Length of the array of token identifiers
     * @param valuesLength Length of the array of token amounts
     */
    error ERC1155InvalidArrayLength(uint256 idsLength, uint256 valuesLength);
}
pragma solidity ^0.8.20;

import {IERC20} from "IERC20.sol";
import {IERC20Permit} from "IERC20Permit.sol";
import {Address} from "Address.sol";

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
