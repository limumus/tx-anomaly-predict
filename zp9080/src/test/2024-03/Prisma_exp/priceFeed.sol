pragma solidity 0.8.19;
import "IAggregatorV3Interface.sol";
import "Address.sol";
import "PrismaMath.sol";
import "PrismaOwnable.sol";

/**
    @title Prisma Multi Token Price Feed
    @notice Based on Gravita's PriceFeed:
            https://github.com/Gravita-Protocol/Gravita-SmartContracts/blob/9b69d555f3567622b0f84df8c7f1bb5cd9323573/contracts/PriceFeed.sol

            Prisma's implementation additionally caches price values within a block and incorporates exchange rate settings for derivative tokens (e.g. stETH -> wstETH).
 */
contract PriceFeed is PrismaOwnable {
    struct OracleRecord {
        IAggregatorV3Interface chainLinkOracle;
        uint8 decimals;
        uint32 heartbeat;
        bytes4 sharePriceSignature;
        uint8 sharePriceDecimals;
        bool isFeedWorking;
        bool isEthIndexed;
    }

    struct PriceRecord {
        uint96 scaledPrice;
        uint32 timestamp;
        uint32 lastUpdated;
        uint80 roundId;
    }

    struct FeedResponse {
        uint80 roundId;
        int256 answer;
        uint256 timestamp;
        bool success;
    }

    // Custom Errors --------------------------------------------------------------------------------------------------

    error PriceFeed__InvalidFeedResponseError(address token);
    error PriceFeed__FeedFrozenError(address token);
    error PriceFeed__UnknownFeedError(address token);
    error PriceFeed__HeartbeatOutOfBoundsError();

    // Events ---------------------------------------------------------------------------------------------------------

    event NewOracleRegistered(address token, address chainlinkAggregator, bool isEthIndexed);
    event PriceFeedStatusUpdated(address token, address oracle, bool isWorking);
    event PriceRecordUpdated(address indexed token, uint256 _price);

    /** Constants ---------------------------------------------------------------------------------------------------- */

    // Used to convert a chainlink price answer to an 18-digit precision uint
    uint256 public constant TARGET_DIGITS = 18;

    // Responses are considered stale this many seconds after the oracle's heartbeat
    uint256 public constant RESPONSE_TIMEOUT_BUFFER = 1 hours;

    // Maximum deviation allowed between two consecutive Chainlink oracle prices. 18-digit precision.
    uint256 public constant MAX_PRICE_DEVIATION_FROM_PREVIOUS_ROUND = 5e17; // 50%

    // State ------------------------------------------------------------------------------------------------------------

    mapping(address => OracleRecord) public oracleRecords;
    mapping(address => PriceRecord) public priceRecords;

    struct OracleSetup {
        address token;
        address chainlink;
        uint32 heartbeat;
        bytes4 sharePriceSignature;
        uint8 sharePriceDecimals;
        bool isEthIndexed;
    }

    constructor(address _prismaCore, address ethFeed, OracleSetup[] memory oracles) PrismaOwnable(_prismaCore) {
        _setOracle(address(0), ethFeed, 3600, 0, 0, false);
        for (uint i = 0; i < oracles.length; i++) {
            OracleSetup memory o = oracles[i];
            _setOracle(o.token, o.chainlink, o.heartbeat, o.sharePriceSignature, o.sharePriceDecimals, o.isEthIndexed);
        }
    }

    // Admin routines ---------------------------------------------------------------------------------------------------

    /**
        @notice Set the oracle for a specific token
        @param _token Address of the LST to set the oracle for
        @param _chainlinkOracle Address of the chainlink oracle for this LST
        @param _heartbeat Oracle heartbeat, in seconds
        @param sharePriceSignature Four byte function selector to be used when calling `_collateral`, in order to obtain the share price
        @param sharePriceDecimals Decimal precision used in the returned share price
        @param _isEthIndexed True if the base currency is ETH
     */
    function setOracle(
        address _token,
        address _chainlinkOracle,
        uint32 _heartbeat,
        bytes4 sharePriceSignature,
        uint8 sharePriceDecimals,
        bool _isEthIndexed
    ) external onlyOwner {
        _setOracle(_token, _chainlinkOracle, _heartbeat, sharePriceSignature, sharePriceDecimals, _isEthIndexed);
    }

    function _setOracle(
        address _token,
        address _chainlinkOracle,
        uint32 _heartbeat,
        bytes4 sharePriceSignature,
        uint8 sharePriceDecimals,
        bool _isEthIndexed
    ) internal {
        if (_heartbeat > 86400) revert PriceFeed__HeartbeatOutOfBoundsError();
        IAggregatorV3Interface newFeed = IAggregatorV3Interface(_chainlinkOracle);
        (FeedResponse memory currResponse, FeedResponse memory prevResponse, ) = _fetchFeedResponses(newFeed, 0);

        if (!_isFeedWorking(currResponse, prevResponse)) {
            revert PriceFeed__InvalidFeedResponseError(_token);
        }
        if (_isPriceStale(currResponse.timestamp, _heartbeat)) {
            revert PriceFeed__FeedFrozenError(_token);
        }

        OracleRecord memory record = OracleRecord({
            chainLinkOracle: newFeed,
            decimals: newFeed.decimals(),
            heartbeat: _heartbeat,
            sharePriceSignature: sharePriceSignature,
            sharePriceDecimals: sharePriceDecimals,
            isFeedWorking: true,
            isEthIndexed: _isEthIndexed
        });

        oracleRecords[_token] = record;
        PriceRecord memory _priceRecord = priceRecords[_token];

        _processFeedResponses(_token, record, currResponse, prevResponse, _priceRecord);
        emit NewOracleRegistered(_token, _chainlinkOracle, _isEthIndexed);
    }

    // Public functions -------------------------------------------------------------------------------------------------

    /**
        @notice Get the latest price returned from the oracle
        @dev You can obtain these values by calling `TroveManager.fetchPrice()`
             rather than directly interacting with this contract.
        @param _token Token to fetch the price for
        @return The latest valid price for the requested token
     */
    function fetchPrice(address _token) public returns (uint256) {
        PriceRecord memory priceRecord = priceRecords[_token];
        OracleRecord memory oracle = oracleRecords[_token];

        uint256 scaledPrice = priceRecord.scaledPrice;
        // We short-circuit only if the price was already correct in the current block
        if (priceRecord.lastUpdated != block.timestamp) {
            if (priceRecord.lastUpdated == 0) {
                revert PriceFeed__UnknownFeedError(_token);
            }

            (FeedResponse memory currResponse, FeedResponse memory prevResponse, bool updated) = _fetchFeedResponses(
                oracle.chainLinkOracle,
                priceRecord.roundId
            );

            if (updated) {
                scaledPrice = _processFeedResponses(_token, oracle, currResponse, prevResponse, priceRecord);
            } else {
                if (_isPriceStale(priceRecord.timestamp, oracle.heartbeat)) {
                    revert PriceFeed__FeedFrozenError(_token);
                }

                priceRecord.lastUpdated = uint32(block.timestamp);
                priceRecords[_token] = priceRecord;
            }
        }

        if (oracle.isEthIndexed) {
            uint256 ethPrice = fetchPrice(address(0));
            return (ethPrice * scaledPrice) / 1 ether;
        }
        return scaledPrice;
    }

    // Internal functions -----------------------------------------------------------------------------------------------

    function _processFeedResponses(
        address _token,
        OracleRecord memory oracle,
        FeedResponse memory _currResponse,
        FeedResponse memory _prevResponse,
        PriceRecord memory priceRecord
    ) internal returns (uint256) {
        uint8 decimals = oracle.decimals;
        bool isValidResponse = _isFeedWorking(_currResponse, _prevResponse) &&
            !_isPriceStale(_currResponse.timestamp, oracle.heartbeat) &&
            !_isPriceChangeAboveMaxDeviation(_currResponse, _prevResponse, decimals);
        if (isValidResponse) {
            uint256 scaledPrice = _scalePriceByDigits(uint256(_currResponse.answer), decimals);
            if (oracle.sharePriceSignature != 0) {
                (bool success, bytes memory returnData) = _token.staticcall(abi.encode(oracle.sharePriceSignature));
                require(success, "Share price not available");
                scaledPrice = (scaledPrice * abi.decode(returnData, (uint256))) / (10 ** oracle.sharePriceDecimals);
            }
            if (!oracle.isFeedWorking) {
                _updateFeedStatus(_token, oracle, true);
            }
            _storePrice(_token, scaledPrice, _currResponse.timestamp, _currResponse.roundId);
            return scaledPrice;
        } else {
            if (oracle.isFeedWorking) {
                _updateFeedStatus(_token, oracle, false);
            }
            if (_isPriceStale(priceRecord.timestamp, oracle.heartbeat)) {
                revert PriceFeed__FeedFrozenError(_token);
            }
            return priceRecord.scaledPrice;
        }
    }

    function _fetchFeedResponses(
        IAggregatorV3Interface oracle,
        uint80 lastRoundId
    ) internal view returns (FeedResponse memory currResponse, FeedResponse memory prevResponse, bool updated) {
        currResponse = _fetchCurrentFeedResponse(oracle);
        if (lastRoundId == 0 || currResponse.roundId > lastRoundId) {
            prevResponse = _fetchPrevFeedResponse(oracle, currResponse.roundId);
            updated = true;
        }
    }

    function _isPriceStale(uint256 _priceTimestamp, uint256 _heartbeat) internal view returns (bool) {
        return block.timestamp - _priceTimestamp > _heartbeat + RESPONSE_TIMEOUT_BUFFER;
    }

    function _isFeedWorking(
        FeedResponse memory _currentResponse,
        FeedResponse memory _prevResponse
    ) internal view returns (bool) {
        return _isValidResponse(_currentResponse) && _isValidResponse(_prevResponse);
    }

    function _isValidResponse(FeedResponse memory _response) internal view returns (bool) {
        return
            (_response.success) &&
            (_response.roundId != 0) &&
            (_response.timestamp != 0) &&
            (_response.timestamp <= block.timestamp) &&
            (_response.answer != 0);
    }

    function _isPriceChangeAboveMaxDeviation(
        FeedResponse memory _currResponse,
        FeedResponse memory _prevResponse,
        uint8 decimals
    ) internal pure returns (bool) {
        uint256 currentScaledPrice = _scalePriceByDigits(uint256(_currResponse.answer), decimals);
        uint256 prevScaledPrice = _scalePriceByDigits(uint256(_prevResponse.answer), decimals);

        uint256 minPrice = PrismaMath._min(currentScaledPrice, prevScaledPrice);
        uint256 maxPrice = PrismaMath._max(currentScaledPrice, prevScaledPrice);

        /*
         * Use the larger price as the denominator:
         * - If price decreased, the percentage deviation is in relation to the previous price.
         * - If price increased, the percentage deviation is in relation to the current price.
         */
        uint256 percentDeviation = ((maxPrice - minPrice) * PrismaMath.DECIMAL_PRECISION) / maxPrice;

        return percentDeviation > MAX_PRICE_DEVIATION_FROM_PREVIOUS_ROUND;
    }

    function _scalePriceByDigits(uint256 _price, uint256 _answerDigits) internal pure returns (uint256) {
        if (_answerDigits == TARGET_DIGITS) {
            return _price;
        } else if (_answerDigits < TARGET_DIGITS) {
            // Scale the returned price value up to target precision
            return _price * (10 ** (TARGET_DIGITS - _answerDigits));
        } else {
            // Scale the returned price value down to target precision
            return _price / (10 ** (_answerDigits - TARGET_DIGITS));
        }
    }

    function _updateFeedStatus(address _token, OracleRecord memory _oracle, bool _isWorking) internal {
        oracleRecords[_token].isFeedWorking = _isWorking;
        emit PriceFeedStatusUpdated(_token, address(_oracle.chainLinkOracle), _isWorking);
    }

    function _storePrice(address _token, uint256 _price, uint256 _timestamp, uint80 roundId) internal {
        priceRecords[_token] = PriceRecord({
            scaledPrice: uint96(_price),
            timestamp: uint32(_timestamp),
            lastUpdated: uint32(block.timestamp),
            roundId: roundId
        });
        emit PriceRecordUpdated(_token, _price);
    }

    function _fetchCurrentFeedResponse(
        IAggregatorV3Interface _priceAggregator
    ) internal view returns (FeedResponse memory response) {
        try _priceAggregator.latestRoundData() returns (
            uint80 roundId,
            int256 answer,
            uint256 /* startedAt */,
            uint256 timestamp,
            uint80 /* answeredInRound */
        ) {
            // If call to Chainlink succeeds, return the response and success = true
            response.roundId = roundId;
            response.answer = answer;
            response.timestamp = timestamp;
            response.success = true;
        } catch {
            // If call to Chainlink aggregator reverts, return a zero response with success = false
            return response;
        }
    }

    function _fetchPrevFeedResponse(
        IAggregatorV3Interface _priceAggregator,
        uint80 _currentRoundId
    ) internal view returns (FeedResponse memory prevResponse) {
        if (_currentRoundId == 0) {
            return prevResponse;
        }
        unchecked {
            try _priceAggregator.getRoundData(_currentRoundId - 1) returns (
                uint80 roundId,
                int256 answer,
                uint256 /* startedAt */,
                uint256 timestamp,
                uint80 /* answeredInRound */
            ) {
                prevResponse.roundId = roundId;
                prevResponse.answer = answer;
                prevResponse.timestamp = timestamp;
                prevResponse.success = true;
            } catch {}
        }
    }
}
pragma solidity 0.8.19;

interface IAggregatorV3Interface {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function version() external view returns (uint256);

    // getRoundData and latestRoundData should both raise "No data present"
    // if they do not have data to report, instead of returning unset values
    // which could be misinterpreted as actual reported values.
    function getRoundData(
        uint80 _roundId
    )
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
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
pragma solidity 0.8.19;

library PrismaMath {
    uint256 internal constant DECIMAL_PRECISION = 1e18;

    /* Precision for Nominal ICR (independent of price). Rationale for the value:
     *
     * - Making it “too high” could lead to overflows.
     * - Making it “too low” could lead to an ICR equal to zero, due to truncation from Solidity floor division.
     *
     * This value of 1e20 is chosen for safety: the NICR will only overflow for numerator > ~1e39,
     * and will only truncate to 0 if the denominator is at least 1e20 times greater than the numerator.
     *
     */
    uint256 internal constant NICR_PRECISION = 1e20;

    function _min(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return (_a < _b) ? _a : _b;
    }

    function _max(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return (_a >= _b) ? _a : _b;
    }

    /*
     * Multiply two decimal numbers and use normal rounding rules:
     * -round product up if 19'th mantissa digit >= 5
     * -round product down if 19'th mantissa digit < 5
     *
     * Used only inside the exponentiation, _decPow().
     */
    function decMul(uint256 x, uint256 y) internal pure returns (uint256 decProd) {
        uint256 prod_xy = x * y;

        decProd = (prod_xy + (DECIMAL_PRECISION / 2)) / DECIMAL_PRECISION;
    }

    /*
     * _decPow: Exponentiation function for 18-digit decimal base, and integer exponent n.
     *
     * Uses the efficient "exponentiation by squaring" algorithm. O(log(n)) complexity.
     *
     * Called by two functions that represent time in units of minutes:
     * 1) TroveManager._calcDecayedBaseRate
     * 2) CommunityIssuance._getCumulativeIssuanceFraction
     *
     * The exponent is capped to avoid reverting due to overflow. The cap 525600000 equals
     * "minutes in 1000 years": 60 * 24 * 365 * 1000
     *
     * If a period of > 1000 years is ever used as an exponent in either of the above functions, the result will be
     * negligibly different from just passing the cap, since:
     *
     * In function 1), the decayed base rate will be 0 for 1000 years or > 1000 years
     * In function 2), the difference in tokens issued at 1000 years and any time > 1000 years, will be negligible
     */
    function _decPow(uint256 _base, uint256 _minutes) internal pure returns (uint256) {
        if (_minutes > 525600000) {
            _minutes = 525600000;
        } // cap to avoid overflow

        if (_minutes == 0) {
            return DECIMAL_PRECISION;
        }

        uint256 y = DECIMAL_PRECISION;
        uint256 x = _base;
        uint256 n = _minutes;

        // Exponentiation-by-squaring
        while (n > 1) {
            if (n % 2 == 0) {
                x = decMul(x, x);
                n = n / 2;
            } else {
                // if (n % 2 != 0)
                y = decMul(x, y);
                x = decMul(x, x);
                n = (n - 1) / 2;
            }
        }

        return decMul(x, y);
    }

    function _getAbsoluteDifference(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return (_a >= _b) ? _a - _b : _b - _a;
    }

    function _computeNominalCR(uint256 _coll, uint256 _debt) internal pure returns (uint256) {
        if (_debt > 0) {
            return (_coll * NICR_PRECISION) / _debt;
        }
        // Return the maximal value for uint256 if the Trove has a debt of 0. Represents "infinite" CR.
        else {
            // if (_debt == 0)
            return 2 ** 256 - 1;
        }
    }

    function _computeCR(uint256 _coll, uint256 _debt, uint256 _price) internal pure returns (uint256) {
        if (_debt > 0) {
            uint256 newCollRatio = (_coll * _price) / _debt;

            return newCollRatio;
        }
        // Return the maximal value for uint256 if the Trove has a debt of 0. Represents "infinite" CR.
        else {
            // if (_debt == 0)
            return 2 ** 256 - 1;
        }
    }

    function _computeCR(uint256 _coll, uint256 _debt) internal pure returns (uint256) {
        if (_debt > 0) {
            uint256 newCollRatio = (_coll) / _debt;

            return newCollRatio;
        }
        // Return the maximal value for uint256 if the Trove has a debt of 0. Represents "infinite" CR.
        else {
            // if (_debt == 0)
            return 2 ** 256 - 1;
        }
    }
}
pragma solidity 0.8.19;

import "IPrismaCore.sol";

/**
    @title Prisma Ownable
    @notice Contracts inheriting `PrismaOwnable` have the same owner as `PrismaCore`.
            The ownership cannot be independently modified or renounced.
 */
contract PrismaOwnable {
    IPrismaCore public immutable PRISMA_CORE;

    constructor(address _prismaCore) {
        PRISMA_CORE = IPrismaCore(_prismaCore);
    }

    modifier onlyOwner() {
        require(msg.sender == PRISMA_CORE.owner(), "Only owner");
        _;
    }

    function owner() public view returns (address) {
        return PRISMA_CORE.owner();
    }

    function guardian() public view returns (address) {
        return PRISMA_CORE.guardian();
    }
}
pragma solidity ^0.8.0;

interface IPrismaCore {
    event FeeReceiverSet(address feeReceiver);
    event GuardianSet(address guardian);
    event NewOwnerAccepted(address oldOwner, address owner);
    event NewOwnerCommitted(address owner, address pendingOwner, uint256 deadline);
    event NewOwnerRevoked(address owner, address revokedOwner);
    event Paused();
    event PriceFeedSet(address priceFeed);
    event Unpaused();

    function acceptTransferOwnership() external;

    function commitTransferOwnership(address newOwner) external;

    function revokeTransferOwnership() external;

    function setFeeReceiver(address _feeReceiver) external;

    function setGuardian(address _guardian) external;

    function setPaused(bool _paused) external;

    function setPriceFeed(address _priceFeed) external;

    function OWNERSHIP_TRANSFER_DELAY() external view returns (uint256);

    function feeReceiver() external view returns (address);

    function guardian() external view returns (address);

    function owner() external view returns (address);

    function ownershipTransferDeadline() external view returns (uint256);

    function paused() external view returns (bool);

    function pendingOwner() external view returns (address);

    function priceFeed() external view returns (address);

    function startTime() external view returns (uint256);
}
