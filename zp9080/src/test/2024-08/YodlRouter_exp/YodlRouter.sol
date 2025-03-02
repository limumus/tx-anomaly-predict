pragma solidity ^0.8.26;

import "../routers/YodlTransferRouter.sol";
import "../routers/YodlCurveRouter.sol";
import "../routers/YodlUniswapRouter.sol";

contract YodlRouter is YodlTransferRouter, YodlCurveRouter, YodlUniswapRouter {
    constructor()
        AbstractYodlRouter()
        YodlTransferRouter()
        YodlCurveRouter(0x99a58482BD75cbab83b27EC03CA68fF489b5788f)
        YodlUniswapRouter(0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45)
    {
        version = "vSam";
        yodlFeeBps = 20;
        yodlFeeTreasury = 0x9C48d180e4eEE0dA2A899EE1E4c533cA5e92db77;
        wrappedNativeToken = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    }
}
pragma solidity ^0.8.26;

import "../AbstractYodlRouter.sol";
import "../interfaces/IBeforeHook.sol";

abstract contract YodlTransferRouter is AbstractYodlRouter {
    struct YodlTransferParams {
        // The message attached to the payment. If present, the router will take a fee.
        bytes32 memo;
        // The amount to pay before any price feeds are applied. This amount will be converted by the price feeds and then the sender will pay the converted amount in the given token.
        uint256 amount;
        // Array of Chainlink price feeds. See `exchangeRate` method for more details.
        address[2] priceFeeds;
        // Token address to be used for the payment. Either an ERC20 token or the native token address.
        address token;
        // Address to receive the payment
        address receiver;
        // Address to receive an extra fee that is taken from the payment amount
        address extraFeeReceiver;
        // Size of the extra fee in terms of basis points (or 0 for none)
        uint256 extraFeeBps;
        // Metadata tracker for the payment
        uint256 yd;
        // List of YApps that are allowed to be called with IBeforeHook.beforeHook extension
        YApp[] yAppList;
    }

    /**
     * @notice Handles payments when sending tokens directly without DEX.
     * ## Example: Pay without pricefeeds, e.g. USDC transfer
     *
     * yodlWithToken(
     *   "tx-123",         // memo
     *   5*10**18,         // 5$
     *   [0x0, 0x0],  // no pricefeeds
     *   0xUSDC,           // usdc token address
     *   0xAlice           // receiver token address
     * )
     *
     * ## Example: Pay with pricefeeds (EUR / USD)
     *
     * The user entered the amount in EUR, which gets converted into
     * USD by the on-chain pricefeed.
     *
     * yodlWithToken(
     *     "tx-123",               // memo
     *     4.5*10**18,             // 4.5 EUR (~5$).
     *     [0xEURUSD, 0x0],   // EUR/USD price feed
     *     0xUSDC,                 // usdc token address
     *     0xAlice                 // receiver token address
     * )
     *
     *
     * ## Example: Pay with extra fee
     *
     * 3rd parties can receive an extra fee that is taken directly from
     * the receivable amount.
     *
     * yodlWithToken(
     *     "tx-123",               // memo
     *     4.5*10**18,             // 4.5 EUR (~5$).
     *     [0xEURUSD, 0x0],   //
     *     0xUSDC,                 // usdc token address
     *     0xAlice,                // receiver token address
     *     0x3rdParty              // extra fee for 3rd party provider
     *     50,                    // extra fee bps 0.5%
     * )
     * @dev This is the most gas efficient payment method. It supports currency conversion using price feeds. The
     * native token (ETH, AVAX, MATIC) is represented by the NATIVE_TOKEN constant.
     * @param params Struct that contains all the relevant parameters. See `YodlNativeParams` for more details.
     * @return Amount received by the receiver
     */
    function yodlWithToken(YodlTransferParams calldata params) external payable returns (uint256) {
        require(params.amount != 0, "invalid amount");

        uint256 finalAmount = params.amount;

        // transform amount with priceFeeds
        if (params.priceFeeds[0] != address(0) || params.priceFeeds[1] != address(0)) {
            {
                int256[2] memory prices;
                address[2] memory priceFeedsUsed;
                (finalAmount, priceFeedsUsed, prices) = exchangeRate(params.priceFeeds, params.amount);
                emit Convert(priceFeedsUsed[0], priceFeedsUsed[1], prices[0], prices[1]);
            }
        }

        if (params.token != NATIVE_TOKEN) {
            // ERC20 token
            require(IERC20(params.token).allowance(msg.sender, address(this)) >= finalAmount, "insufficient allowance");
        } else {
            // Native ether
            require(msg.value >= finalAmount, "insufficient gas provided");
        }

        uint256 totalFee = 0;

        if (params.memo != "") {
            totalFee += calculateFee(finalAmount, yodlFeeBps);
        }

        if (params.extraFeeReceiver != address(0)) {
            // 50% maximum extra fee
            require(params.extraFeeBps < MAX_EXTRA_FEE_BPS, "extraFeeBps too high");

            totalFee += transferFee(
                finalAmount,
                params.extraFeeBps,
                params.token,
                params.token == NATIVE_TOKEN ? address(this) : msg.sender,
                params.extraFeeReceiver
            );
        }

        uint256 receivedAmount = finalAmount - totalFee;
        if (params.yAppList.length > 0) {
            for (uint256 i = 0; i < params.yAppList.length; i++) {
                IBeforeHook(params.yAppList[i].yApp).beforeHook(
                    msg.sender,
                    params.receiver,
                    receivedAmount,
                    params.token,
                    params.yAppList[i].sessionId,
                    params.yAppList[i].payload
                );
            }
        }

        // Transfer to receiver
        if (params.token != NATIVE_TOKEN) {
            // ERC20 token
            TransferHelper.safeTransferFrom(params.token, msg.sender, params.receiver, receivedAmount);
        } else {
            // Native ether
            (bool success,) = params.receiver.call{value: receivedAmount}("");
            require(success, "transfer of the native token to the recipient failed");
            emit YodlNativeTokenTransfer(msg.sender, params.receiver, receivedAmount);
        }

        emit Yodl(msg.sender, params.receiver, params.token, finalAmount, totalFee, params.memo);

        return receivedAmount;
    }
}
pragma solidity ^0.8.26;

import "../interfaces/ICurveRouter.sol";
import "../AbstractYodlRouter.sol";
import "../interfaces/IBeforeHook.sol";

abstract contract YodlCurveRouter is AbstractYodlRouter {
    ICurveRouter private curveRouter;

    /// @notice Parameters for a payment through Curve
    /// @dev The`route`, `swapParams` and `factoryAddresses` should be determined client-side by the CurveJS client.
    struct YodlCurveParams {
        address sender;
        address receiver;
        uint256 amountIn; // amount of tokenIn needed to satisfy amountOut
        // The exact amount expected by merchant in tokenOut
        // If we are using price feeds, this is in terms of the invoice amount, but it must have the same decimals as tokenOut
        uint256 amountOut;
        bytes32 memo;
        address[9] route;
        uint256[3][4] swapParams; // [i, j, swap_type] where i and j are the coin index for the n'th pool in route
        address[4] factoryAddresses;
        address[2] priceFeeds;
        address extraFeeReceiver;
        uint256 extraFeeBps;
        uint256 yd;
        // List of YApps that are allowed to be called with IBeforeHook.beforeHook extension
        YApp[] yAppList;
    }

    constructor(address _curveRouter) {
        curveRouter = ICurveRouter(_curveRouter);
    }

    /// @notice Handles a payment with a swap through Curve
    /// @dev This needs to have a valid Curve router or it will revert. Excess tokens from the swap as a result
    /// of slippage are in terms of the token out.
    /// @param params Struct that contains all the relevant parameters. See `YodlCurveParams` for more details.
    /// @return The amount received in terms of token out by the Curve swap
    function yodlWithCurve(YodlCurveParams calldata params) external payable returns (uint256) {
        require(address(curveRouter) != address(0), "curve router not present");
        (address tokenOut, address tokenIn) = decodeTokenOutTokenInCurve(params.route);

        // This is how much the recipient needs to receive
        uint256 amountOutExpected;
        if (params.priceFeeds[0] != address(0) || params.priceFeeds[1] != address(0)) {
            // Convert amountOut from invoice currency to swap currency using price feed
            int256[2] memory prices;
            address[2] memory priceFeeds;
            (amountOutExpected, priceFeeds, prices) = exchangeRate(params.priceFeeds, params.amountOut);
            emit Convert(priceFeeds[0], priceFeeds[1], prices[0], prices[1]);
        } else {
            amountOutExpected = params.amountOut;
        }
        if (params.yAppList.length > 0) {
            for (uint256 i = 0; i < params.yAppList.length; i++) {
                IBeforeHook(params.yAppList[i].yApp).beforeHook(
                    msg.sender,
                    params.receiver,
                    amountOutExpected,
                    tokenOut,
                    params.yAppList[i].sessionId,
                    params.yAppList[i].payload
                );
            }
        }

        // There should be no other situation in which we send a transaction with native token
        if (msg.value != 0) {
            // Wrap the native token
            require(msg.value >= params.amountIn, "insufficient gas provided");
            wrappedNativeToken.deposit{value: params.amountIn}();

            // Update the tokenIn to wrapped native token
            // wrapped native token has the same number of decimals as native token
            // wrapped native token is already the first token in the route parameter
            tokenIn = address(wrappedNativeToken);
        } else {
            // Transfer the ERC20 token from the sender to the YodlRouter
            TransferHelper.safeTransferFrom(tokenIn, msg.sender, address(this), params.amountIn);
        }
        TransferHelper.safeApprove(tokenIn, address(curveRouter), params.amountIn);

        // Make the swap - the YodlRouter will receive the tokens
        uint256 amountOut = curveRouter.exchange_multiple(
            params.route,
            params.swapParams,
            params.amountIn,
            amountOutExpected, // this will revert if we do not get at least this amount
            params.factoryAddresses, // this is for zap contracts
            address(this) // the Yodl router will receive the tokens
        );
        require(amountOut >= amountOutExpected, "amountOut is less then amountOutExpected");

        // Handle fees for the transaction - in terms out the token out
        uint256 totalFee = 0;
        if (params.memo != "") {
            totalFee += calculateFee(amountOutExpected, yodlFeeBps);
        }

        // Handle extra fees
        if (params.extraFeeReceiver != address(0)) {
            // 50% maximum extra fee
            require(params.extraFeeBps < MAX_EXTRA_FEE_BPS, "extraFeeBps too high");

            totalFee +=
                transferFee(amountOutExpected, params.extraFeeBps, tokenOut, address(this), params.extraFeeReceiver);
        }
        if (tokenOut == NATIVE_TOKEN) {
            // Handle unwrapping wrapped native token
            uint256 balance = IWETH9(wrappedNativeToken).balanceOf(address(this));
            // Unwrap and use NATIVE_TOKEN address as tokenOut
            require(balance >= amountOutExpected, "Wrapped balance is less then amountOutExpected");
            IWETH9(wrappedNativeToken).withdraw(balance);
            // Need to transfer native token to receiver
            (bool success,) = params.receiver.call{value: amountOutExpected - totalFee}("");
            require(success, "transfer of native to receiver failed");
            emit YodlNativeTokenTransfer(params.sender, params.receiver, amountOutExpected - totalFee);
        } else {
            // Transfer tokens to receiver
            TransferHelper.safeTransfer(tokenOut, params.receiver, amountOutExpected - totalFee);
        }
        emit Yodl(params.sender, params.receiver, tokenOut, amountOutExpected, totalFee, params.memo);

        return amountOut;
    }

    /// @notice Helper method to determine the token in and out from a Curve route
    /// @param route Route for a Curve swap in the form of [token, pool address, token...] with zero addresses once the
    /// swap has completed
    /// @return The tokenOut and tokenIn
    function decodeTokenOutTokenInCurve(address[9] memory route) internal pure returns (address, address) {
        address tokenIn = route[0];
        address tokenOut = route[2];
        // Output tokens can be located at indices 2, 4, 6 or 8, if the loop finds nothing, then it is index 2
        for (uint256 i = 4; i >= 2; i--) {
            if (route[i * 2] != address(0)) {
                tokenOut = route[i * 2];
                break;
            }
        }
        require(tokenOut != address(0), "Invalid route parameter");
        return (tokenOut, tokenIn);
    }
}
pragma solidity ^0.8.26;

import "../AbstractYodlRouter.sol";
import "../../lib/swap-router-contracts/contracts/interfaces/ISwapRouter02.sol";
import "../interfaces/IBeforeHook.sol";

abstract contract YodlUniswapRouter is AbstractYodlRouter {
    ISwapRouter02 public uniswapRouter;

    enum SwapType {
        SINGLE,
        MULTI
    }

    /// @notice Parameters for a payment through Uniswap
    struct YodlUniswapParams {
        address sender;
        address receiver;
        uint256 amountIn; // amount of tokenIn needed to satisfy amountOut
        uint256 amountOut; // The exact amount expected by merchant in tokenOut
        bytes32 memo;
        bytes path; // (address: tokenOut, uint24 poolfee, address: tokenIn) OR (address: tokenOut, uint24 poolfee2, address: tokenBase, uint24 poolfee1, tokenIn)
        address[2] priceFeeds;
        address extraFeeReceiver;
        uint256 extraFeeBps;
        SwapType swapType;
        uint256 yd;
        // List of YApps that are allowed to be called with IBeforeHook.beforeHook extension
        YApp[] yAppList;
    }

    constructor(address _uniswapRouter) {
        uniswapRouter = ISwapRouter02(_uniswapRouter);
    }

    /// @notice Handles a payment with a swap through Uniswap
    /// @dev This needs to have a valid Uniswap router or it will revert. Excess tokens from the swap as a result
    /// of slippage are in terms of the token in.
    /// @param params Struct that contains all the relevant parameters. See `YodlUniswapParams` for more details.
    /// @return The amount spent in terms of token in by Uniswap to complete this payment
    function yodlWithUniswap(YodlUniswapParams calldata params) external payable returns (uint256) {
        require(address(uniswapRouter) != address(0), "uniswap router not present");
        (address tokenOut, address tokenIn) = decodeTokenOutTokenInUniswap(params.path, params.swapType);
        uint256 amountSpent;

        // This is how much the recipient needs to receive
        uint256 amountOutExpected;
        if (params.priceFeeds[0] != address(0) || params.priceFeeds[1] != address(0)) {
            // Convert amountOut from invoice currency to swap currency using price feed
            int256[2] memory prices;
            address[2] memory priceFeeds;
            (amountOutExpected, priceFeeds, prices) = exchangeRate(params.priceFeeds, params.amountOut);
            emit Convert(priceFeeds[0], priceFeeds[1], prices[0], prices[1]);
        } else {
            amountOutExpected = params.amountOut;
        }
        if (params.yAppList.length > 0) {
            for (uint256 i = 0; i < params.yAppList.length; i++) {
                IBeforeHook(params.yAppList[i].yApp).beforeHook(
                    tx.origin,
                    params.receiver,
                    amountOutExpected,
                    tokenOut,
                    params.yAppList[i].sessionId,
                    params.yAppList[i].payload
                );
            }
        }

        // There should be no other situation in which we send a transaction with native token
        if (msg.value != 0) {
            // Wrap the native token
            require(msg.value >= params.amountIn, "insufficient gas provided");
            wrappedNativeToken.deposit{value: params.amountIn}();

            // Update the tokenIn to wrapped native token
            tokenIn = address(wrappedNativeToken);
        } else {
            // Transfer the ERC20 token from the sender to the YodlRouter
            TransferHelper.safeTransferFrom(tokenIn, tx.origin, address(this), params.amountIn);
        }
        TransferHelper.safeApprove(tokenIn, address(uniswapRouter), params.amountIn);

        // Special case for when we want native token out
        bool useNativeToken = false;
        if (tokenOut == NATIVE_TOKEN) {
            useNativeToken = true;
            tokenOut = address(wrappedNativeToken);
        }

        if (params.swapType == SwapType.SINGLE) {
            IV3SwapRouter.ExactOutputSingleParams memory routerParams = IV3SwapRouter.ExactOutputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: decodeSinglePoolFee(params.path),
                recipient: address(this),
                amountOut: amountOutExpected,
                amountInMaximum: params.amountIn,
                sqrtPriceLimitX96: 0
            });

            amountSpent = uniswapRouter.exactOutputSingle(routerParams);
        } else {
            // We need to extract the path details so that we can use the tokenIn value from earlier which may have been replaced by WETH
            (, uint24 poolFee2, address tokenBase, uint24 poolFee1,) =
                abi.decode(params.path, (address, uint24, address, uint24, address));

            IV3SwapRouter.ExactOutputParams memory routerParams = IV3SwapRouter.ExactOutputParams({
                path: abi.encodePacked(tokenOut, poolFee2, tokenBase, poolFee1, tokenIn),
                recipient: address(this),
                amountOut: amountOutExpected,
                amountInMaximum: params.amountIn
            });

            amountSpent = uniswapRouter.exactOutput(routerParams);
        }

        // Handle unwrapping wrapped native token
        if (useNativeToken) {
            // Unwrap and use NATIVE_TOKEN address as tokenOut
            IWETH9(wrappedNativeToken).withdraw(amountOutExpected);
            tokenOut = NATIVE_TOKEN;
        }

        // Calculate fee from amount out
        uint256 totalFee = 0;
        if (params.memo != "") {
            totalFee += calculateFee(amountOutExpected, yodlFeeBps);
        }

        // Handle extra fees
        if (params.extraFeeReceiver != address(0)) {
            // 50% maximum extra fee
            require(params.extraFeeBps < MAX_EXTRA_FEE_BPS, "extraFeeBps too high");

            totalFee +=
                transferFee(amountOutExpected, params.extraFeeBps, tokenOut, address(this), params.extraFeeReceiver);
        }

        if (tokenOut == NATIVE_TOKEN) {
            (bool success,) = params.receiver.call{value: amountOutExpected - totalFee}("");
            require(success, "transfer failed");
            emit YodlNativeTokenTransfer(params.sender, params.receiver, amountOutExpected - totalFee);
        } else {
            // transfer tokens to receiver
            TransferHelper.safeTransfer(tokenOut, params.receiver, amountOutExpected - totalFee);
        }

        emit Yodl(params.sender, params.receiver, tokenOut, amountOutExpected, totalFee, params.memo);

        TransferHelper.safeApprove(tokenIn, address(uniswapRouter), 0);

        return amountSpent;
    }

    /// @notice Helper method to determine the token in and out from a Uniswap path
    /// @param path The path for a Uniswap swap
    /// @param swapType Enum for whether the swap is a single hop or multiple hop
    /// @return The tokenOut and tokenIn
    function decodeTokenOutTokenInUniswap(bytes memory path, SwapType swapType)
        internal
        pure
        returns (address, address)
    {
        address tokenOut;
        address tokenIn;
        if (swapType == SwapType.SINGLE) {
            (tokenOut,, tokenIn) = abi.decode(path, (address, uint24, address));
        } else {
            (tokenOut,,,, tokenIn) = abi.decode(path, (address, uint24, address, uint24, address));
        }
        return (tokenOut, tokenIn);
    }

    /// @notice Helper method to get the fee for a single hop swap for Uniswap
    /// @param path The path for a Uniswap swap
    /// @return The pool fee for given swap path
    function decodeSinglePoolFee(bytes memory path) internal pure returns (uint24) {
        (, uint24 poolFee,) = abi.decode(path, (address, uint24, address));
        return poolFee;
    }
}
pragma solidity ^0.8.26;

import "../lib/chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "../lib/v3-periphery/contracts/interfaces/external/IWETH9.sol";
import "../lib/v3-periphery/contracts/libraries/TransferHelper.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

abstract contract AbstractYodlRouter {
    string public version;
    address public yodlFeeTreasury;
    uint256 public yodlFeeBps;
    IWETH9 public wrappedNativeToken;
    address public constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint256 public constant MAX_EXTRA_FEE_BPS = 5_000; // 50%

    /// @notice Emitted when a payment goes through
    /// @param sender The address who has made the payment
    /// @param receiver The address who has received the payment
    /// @param token The address of the token that was used for the payment. Either an ERC20 token or the native token
    /// address.
    /// @param amount The amount paid by the sender in terms of the token
    /// @param fees The fees taken by the Yodl router from the amount paid
    /// @param memo The message attached to the payment
    event Yodl(
        address indexed sender, address indexed receiver, address token, uint256 amount, uint256 fees, bytes32 memo
    );

    /// @notice Emitted when a native token transfer occurs
    /// @param sender The address who has made the payment
    /// @param receiver The address who has received the payment
    /// @param amount The amount paid by the sender in terms of the native token
    event YodlNativeTokenTransfer(address indexed sender, address indexed receiver, uint256 indexed amount);

    /// @notice Emitted when a conversion has occurred from one currency to another using a Chainlink price feed
    /// @param priceFeed0 The address of the price feed used for conversion
    /// @param priceFeed1 The address of the price feed used for conversion
    /// @param exchangeRate0 The rate used from the price feed at the time of conversion
    /// @param exchangeRate1 The rate used from the price feed at the time of conversion
    event Convert(address indexed priceFeed0, address indexed priceFeed1, int256 exchangeRate0, int256 exchangeRate1);

    /**
     * @notice Struct to hold the YApp address and the YD ID
     * @param yApp The address of the YApp
     * @param yd The ID of the YD
     * @param payload The payload to be sent to the YApp
     */
    struct YApp {
        address yApp;
        uint256 sessionId;
        bytes[] payload;
    }

    /// @notice Enables the contract to receive Ether
    /// @dev We need a receive method for when we withdraw WETH to the router. It does not need to do anything.
    receive() external payable {}

    /**
     * @notice Calculates exchange rates from a given price feed
     * @dev At most we can have 2 price feeds.
     *
     * We will use a zero address to determine if we need to inverse a singular price feeds.
     *
     * For multiple price feeds, we will always pass them in such that we multiply by the first and divide by the second.
     * This works because all of our price feeds have USD as the quote currency.
     *
     * a) CHF_USD/_______    =>  85 CHF invoiced, 100 USD sent
     * b) _______/CHF_USD    => 100 USD invoiced,  85 CHF sent
     * c) ETH_USD/CHF_USD    => ETH invoiced,         CHF sent
     *
     * The second pricefeed is inversed. So in b) and c) `CHF_USD` turns into `USD_CHF`.
     *
     * @param priceFeeds Array of Chainlink price feeds
     * @param amount Amount to be converted by the price feed exchange rates
     * @return converted The amount after conversion
     * @return priceFeedsUsed The price feeds in the order they were used
     * @return prices The exchange rates from the price feeds
     */
    function exchangeRate(address[2] calldata priceFeeds, uint256 amount)
        public
        view
        returns (uint256 converted, address[2] memory priceFeedsUsed, int256[2] memory prices)
    {
        require(priceFeeds[0] != address(0) || priceFeeds[1] != address(0), "invalid pricefeeds");

        bool shouldInverse;

        AggregatorV3Interface priceFeedOne;
        AggregatorV3Interface priceFeedTwo; // might not exist

        if (priceFeeds[0] == address(0)) {
            // Inverse the price feed. invoiceAmount: USD, settlementAmount: CHF
            shouldInverse = true;
            priceFeedOne = AggregatorV3Interface(priceFeeds[1]);
        } else {
            // No need to inverse. invoiceAmount: CHF, settlementAmount: USD
            priceFeedOne = AggregatorV3Interface(priceFeeds[0]);
            if (priceFeeds[1] != address(0)) {
                // Multiply by the first, divide by the second
                // Will always be A -> USD -> B
                priceFeedTwo = AggregatorV3Interface(priceFeeds[1]);
            }
        }

        // Calculate the converted value using price feeds
        uint256 decimals = uint256(10 ** uint256(priceFeedOne.decimals()));
        (, int256 price,,,) = priceFeedOne.latestRoundData();
        prices[0] = price;
        if (shouldInverse) {
            converted = (amount * decimals) / uint256(price);
        } else {
            converted = (amount * uint256(price)) / decimals;
        }

        // We will always divide by the second price feed
        if (address(priceFeedTwo) != address(0)) {
            decimals = uint256(10 ** uint256(priceFeedTwo.decimals()));
            (, price,,,) = priceFeedTwo.latestRoundData();
            prices[1] = price;
            converted = (converted * decimals) / uint256(price);
        }

        return (converted, [address(priceFeedOne), address(priceFeedTwo)], prices);
    }

    /// @notice Helper function to calculate fees
    /// @dev A basis point is 0.01% -> 1/10000 is one basis point
    /// So multiplying by the amount of basis points then dividing by 10000
    /// will give us the fee as a portion of the original amount, expressed in terms of basis points.
    ///
    /// Overflows are allowed to occur at ridiculously large amounts.
    /// @param amount The amount to calculate the fee for
    /// @param feeBps The size of the fee in terms of basis points
    /// @return The fee
    function calculateFee(uint256 amount, uint256 feeBps) public pure returns (uint256) {
        return (amount * feeBps) / 10_000;
    }

    /// @notice Transfers all fees or slippage collected by the router to the treasury address
    /// @param token The address of the token we want to transfer from the router
    function sweep(address token) external {
        if (token == NATIVE_TOKEN) {
            // transfer native token out of contract
            (bool success,) = yodlFeeTreasury.call{value: address(this).balance}("");
            require(success, "transfer failed in sweep");
        } else {
            // transfer ERC20 contract
            TransferHelper.safeTransfer(token, yodlFeeTreasury, IERC20(token).balanceOf(address(this)));
        }
    }

    /// @notice Calculates and transfers fee directly from an address to another
    /// @dev This can be used for directly transferring the Yodl fee from the sender to the treasury, or transferring
    /// the extra fee to the extra fee receiver.
    /// @param amount Amount from which to calculate the fee
    /// @param feeBps The size of the fee in basis points
    /// @param token The token which is being used to pay the fee. Can be an ERC20 token or the native token
    /// @param from The address from which we are transferring the fee
    /// @param to The address to which the fee will be sent
    /// @return The fee sent
    function transferFee(uint256 amount, uint256 feeBps, address token, address from, address to)
        public
        returns (uint256)
    {
        uint256 fee = calculateFee(amount, feeBps);
        if (fee > 0) {
            if (token != NATIVE_TOKEN) {
                // ERC20 token
                if (from == address(this)) {
                    TransferHelper.safeTransfer(token, to, fee);
                } else {
                    // safeTransferFrom requires approval
                    TransferHelper.safeTransferFrom(token, from, to, fee);
                }
            } else {
                require(from == address(this), "can only transfer eth from the router address");

                // Native ether
                (bool success,) = to.call{value: fee}("");
                require(success, "transfer failed in transferFee");
            }
            return fee;
        } else {
            return 0;
        }
    }
}
pragma solidity ^0.8.26;

/**
 * @title IBeforeHook
 * @notice Interface for a hook that is called before a transfer is executed.
 */
interface IBeforeHook {
    /**
     * @notice Hook that is called before a transfer is executed. Hook should revert if the transfer should not be executed.
     * @param sender The address that initiates the transfer.
     * @param receiver The address that receives the transfer.
     * @param tokenOutAmount The amount of tokens that are transferred.
     * @param tokenOutAddress The address of the token that is transferred.
     * @param yd ID of the extension.
     * @param payload Any arbitrary payload attached to the transfer.
     * @return Any arbitrary uint256 value.
     */
    function beforeHook(
        address sender,
        address receiver,
        uint256 tokenOutAmount,
        address tokenOutAddress,
        uint256 yd,
        bytes[] calldata payload
    ) external view returns (uint256);
}File 7 of 20 : ICurveRouter.solpragma solidity ^0.8.26;

interface ICurveRouter {
    function exchange_multiple(
        address[9] calldata _route,
        uint256[3][4] calldata _swap_params,
        uint256 _amount,
        uint256 _expected,
        address[4] calldata _pools,
        address _receiver
    ) external payable returns (uint256);
}
pragma solidity >=0.7.5;
pragma abicoder v2;

import '@uniswap/v3-periphery/contracts/interfaces/ISelfPermit.sol';

import './IV2SwapRouter.sol';
import './IV3SwapRouter.sol';
import './IApproveAndCall.sol';
import './IMulticallExtended.sol';

/// @title Router token swapping functionality
interface ISwapRouter02 is IV2SwapRouter, IV3SwapRouter, IApproveAndCall, IMulticallExtended, ISelfPermit {

}
pragma solidity ^0.8.0;

// solhint-disable-next-line interface-starts-with-i
interface AggregatorV3Interface {
  function decimals() external view returns (uint8);

  function description() external view returns (string memory);

  function version() external view returns (uint256);

  function getRoundData(
    uint80 _roundId
  ) external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

  function latestRoundData()
    external
    view
    returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
pragma solidity >=0.7.6;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/// @title Interface for WETH9
interface IWETH9 is IERC20 {
    /// @notice Deposit ether to get wrapped ether
    function deposit() external payable;

    /// @notice Withdraw wrapped ether to get ether
    function withdraw(uint256) external;
}
pragma solidity >=0.6.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

library TransferHelper {
    /// @notice Transfers tokens from the targeted address to the given destination
    /// @notice Errors with 'STF' if transfer fails
    /// @param token The contract address of the token to be transferred
    /// @param from The originating address from which the tokens will be transferred
    /// @param to The destination address of the transfer
    /// @param value The amount to be transferred
    function safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 value
    ) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'STF');
    }

    /// @notice Transfers tokens from msg.sender to a recipient
    /// @dev Errors with ST if transfer fails
    /// @param token The contract address of the token which will be transferred
    /// @param to The recipient of the transfer
    /// @param value The value of the transfer
    function safeTransfer(
        address token,
        address to,
        uint256 value
    ) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'ST');
    }

    /// @notice Approves the stipulated contract to spend the given allowance in the given token
    /// @dev Errors with 'SA' if transfer fails
    /// @param token The contract address of the token to be approved
    /// @param to The target of the approval
    /// @param value The amount of the given token the target will be allowed to spend
    function safeApprove(
        address token,
        address to,
        uint256 value
    ) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.approve.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'SA');
    }

    /// @notice Transfers ETH to the recipient address
    /// @dev Fails with `STE`
    /// @param to The destination of the transfer
    /// @param value The value to be transferred
    function safeTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success, 'STE');
    }
}
pragma solidity ^0.8.20;

/**
 * @dev Interface of the ERC-20 standard as defined in the ERC.
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
pragma solidity >=0.7.5;

/// @title Self Permit
/// @notice Functionality to call permit on any EIP-2612-compliant token for use in the route
interface ISelfPermit {
    /// @notice Permits this contract to spend a given token from `msg.sender`
    /// @dev The `owner` is always msg.sender and the `spender` is always address(this).
    /// @param token The address of the token spent
    /// @param value The amount that can be spent of token
    /// @param deadline A timestamp, the current blocktime must be less than or equal to this timestamp
    /// @param v Must produce valid secp256k1 signature from the holder along with `r` and `s`
    /// @param r Must produce valid secp256k1 signature from the holder along with `v` and `s`
    /// @param s Must produce valid secp256k1 signature from the holder along with `r` and `v`
    function selfPermit(
        address token,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable;

    /// @notice Permits this contract to spend a given token from `msg.sender`
    /// @dev The `owner` is always msg.sender and the `spender` is always address(this).
    /// Can be used instead of #selfPermit to prevent calls from failing due to a frontrun of a call to #selfPermit
    /// @param token The address of the token spent
    /// @param value The amount that can be spent of token
    /// @param deadline A timestamp, the current blocktime must be less than or equal to this timestamp
    /// @param v Must produce valid secp256k1 signature from the holder along with `r` and `s`
    /// @param r Must produce valid secp256k1 signature from the holder along with `v` and `s`
    /// @param s Must produce valid secp256k1 signature from the holder along with `r` and `v`
    function selfPermitIfNecessary(
        address token,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable;

    /// @notice Permits this contract to spend the sender's tokens for permit signatures that have the `allowed` parameter
    /// @dev The `owner` is always msg.sender and the `spender` is always address(this)
    /// @param token The address of the token spent
    /// @param nonce The current nonce of the owner
    /// @param expiry The timestamp at which the permit is no longer valid
    /// @param v Must produce valid secp256k1 signature from the holder along with `r` and `s`
    /// @param r Must produce valid secp256k1 signature from the holder along with `v` and `s`
    /// @param s Must produce valid secp256k1 signature from the holder along with `r` and `v`
    function selfPermitAllowed(
        address token,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable;

    /// @notice Permits this contract to spend the sender's tokens for permit signatures that have the `allowed` parameter
    /// @dev The `owner` is always msg.sender and the `spender` is always address(this)
    /// Can be used instead of #selfPermitAllowed to prevent calls from failing due to a frontrun of a call to #selfPermitAllowed.
    /// @param token The address of the token spent
    /// @param nonce The current nonce of the owner
    /// @param expiry The timestamp at which the permit is no longer valid
    /// @param v Must produce valid secp256k1 signature from the holder along with `r` and `s`
    /// @param r Must produce valid secp256k1 signature from the holder along with `v` and `s`
    /// @param s Must produce valid secp256k1 signature from the holder along with `r` and `v`
    function selfPermitAllowedIfNecessary(
        address token,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable;
}
pragma solidity >=0.7.5;
pragma abicoder v2;

/// @title Router token swapping functionality
/// @notice Functions for swapping tokens via Uniswap V2
interface IV2SwapRouter {
    /// @notice Swaps `amountIn` of one token for as much as possible of another token
    /// @dev Setting `amountIn` to 0 will cause the contract to look up its own balance,
    /// and swap the entire amount, enabling contracts to send tokens before calling this function.
    /// @param amountIn The amount of token to swap
    /// @param amountOutMin The minimum amount of output that must be received
    /// @param path The ordered list of tokens to swap through
    /// @param to The recipient address
    /// @return amountOut The amount of the received token
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to
    ) external payable returns (uint256 amountOut);

    /// @notice Swaps as little as possible of one token for an exact amount of another token
    /// @param amountOut The amount of token to swap for
    /// @param amountInMax The maximum amount of input that the caller will pay
    /// @param path The ordered list of tokens to swap through
    /// @param to The recipient address
    /// @return amountIn The amount of token to pay
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to
    ) external payable returns (uint256 amountIn);
}
pragma solidity >=0.7.5;
pragma abicoder v2;

import '@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol';

/// @title Router token swapping functionality
/// @notice Functions for swapping tokens via Uniswap V3
interface IV3SwapRouter is IUniswapV3SwapCallback {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another token
    /// @dev Setting `amountIn` to 0 will cause the contract to look up its own balance,
    /// and swap the entire amount, enabling contracts to send tokens before calling this function.
    /// @param params The parameters necessary for the swap, encoded as `ExactInputSingleParams` in calldata
    /// @return amountOut The amount of the received token
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another along the specified path
    /// @dev Setting `amountIn` to 0 will cause the contract to look up its own balance,
    /// and swap the entire amount, enabling contracts to send tokens before calling this function.
    /// @param params The parameters necessary for the multi-hop swap, encoded as `ExactInputParams` in calldata
    /// @return amountOut The amount of the received token
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps as little as possible of one token for `amountOut` of another token
    /// that may remain in the router after the swap.
    /// @param params The parameters necessary for the swap, encoded as `ExactOutputSingleParams` in calldata
    /// @return amountIn The amount of the input token
    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);

    struct ExactOutputParams {
        bytes path;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    /// @notice Swaps as little as possible of one token for `amountOut` of another along the specified path (reversed)
    /// that may remain in the router after the swap.
    /// @param params The parameters necessary for the multi-hop swap, encoded as `ExactOutputParams` in calldata
    /// @return amountIn The amount of the input token
    function exactOutput(ExactOutputParams calldata params) external payable returns (uint256 amountIn);
}
pragma solidity >=0.7.6;
pragma abicoder v2;

interface IApproveAndCall {
    enum ApprovalType {NOT_REQUIRED, MAX, MAX_MINUS_ONE, ZERO_THEN_MAX, ZERO_THEN_MAX_MINUS_ONE}

    /// @dev Lens to be called off-chain to determine which (if any) of the relevant approval functions should be called
    /// @param token The token to approve
    /// @param amount The amount to approve
    /// @return The required approval type
    function getApprovalType(address token, uint256 amount) external returns (ApprovalType);

    /// @notice Approves a token for the maximum possible amount
    /// @param token The token to approve
    function approveMax(address token) external payable;

    /// @notice Approves a token for the maximum possible amount minus one
    /// @param token The token to approve
    function approveMaxMinusOne(address token) external payable;

    /// @notice Approves a token for zero, then the maximum possible amount
    /// @param token The token to approve
    function approveZeroThenMax(address token) external payable;

    /// @notice Approves a token for zero, then the maximum possible amount minus one
    /// @param token The token to approve
    function approveZeroThenMaxMinusOne(address token) external payable;

    /// @notice Calls the position manager with arbitrary calldata
    /// @param data Calldata to pass along to the position manager
    /// @return result The result from the call
    function callPositionManager(bytes memory data) external payable returns (bytes memory result);

    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
    }

    /// @notice Calls the position manager's mint function
    /// @param params Calldata to pass along to the position manager
    /// @return result The result from the call
    function mint(MintParams calldata params) external payable returns (bytes memory result);

    struct IncreaseLiquidityParams {
        address token0;
        address token1;
        uint256 tokenId;
        uint256 amount0Min;
        uint256 amount1Min;
    }

    /// @notice Calls the position manager's increaseLiquidity function
    /// @param params Calldata to pass along to the position manager
    /// @return result The result from the call
    function increaseLiquidity(IncreaseLiquidityParams calldata params) external payable returns (bytes memory result);
}
pragma solidity >=0.7.5;
pragma abicoder v2;

import '@uniswap/v3-periphery/contracts/interfaces/IMulticall.sol';

/// @title MulticallExtended interface
/// @notice Enables calling multiple methods in a single call to the contract with optional validation
interface IMulticallExtended is IMulticall {
    /// @notice Call multiple functions in the current contract and return the data from all of them if they all succeed
    /// @dev The `msg.value` should not be trusted for any method callable from multicall.
    /// @param deadline The time by which this function must be called before failing
    /// @param data The encoded function data for each of the calls to make to this contract
    /// @return results The results from each of the calls passed in via data
    function multicall(uint256 deadline, bytes[] calldata data) external payable returns (bytes[] memory results);

    /// @notice Call multiple functions in the current contract and return the data from all of them if they all succeed
    /// @dev The `msg.value` should not be trusted for any method callable from multicall.
    /// @param previousBlockhash The expected parent blockHash
    /// @param data The encoded function data for each of the calls to make to this contract
    /// @return results The results from each of the calls passed in via data
    function multicall(bytes32 previousBlockhash, bytes[] calldata data)
        external
        payable
        returns (bytes[] memory results);
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
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
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

/// @title Multicall interface
/// @notice Enables calling multiple methods in a single call to the contract
interface IMulticall {
    /// @notice Call multiple functions in the current contract and return the data from all of them if they all succeed
    /// @dev The `msg.value` should not be trusted for any method callable from multicall.
    /// @param data The encoded function data for each of the calls to make to this contract
    /// @return results The results from each of the calls passed in via data
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
}
