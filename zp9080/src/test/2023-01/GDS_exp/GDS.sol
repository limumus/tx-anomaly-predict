pragma solidity ^0.8.0;

import "./IERC20.sol";
import "./IERC20Metadata.sol";
import "./Ownable.sol";
import "./IUniswapV2Router.sol";
import "./IUniswapV2Factory.sol";
import "./EnumerableSet.sol";

/**
 * @dev Implementation of the {IERC20} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
 * For a generic mechanism see {ERC20PresetMinterPauser}.
 *
 * TIP: For a detailed writeup see our guide
 * https://forum.zeppelin.solutions/t/how-to-implement-erc20-supply-mechanisms/226[How
 * to implement supply mechanisms].
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
 *
 * Finally, the non-standard {decreaseAllowance} and {increaseAllowance}
 * functions have been added to mitigate the well-known issues around setting
 * allowances. See {IERC20-approve}.
 */


contract GDSToken is Ownable, IERC20, IERC20Metadata{
    
    using EnumerableSet for EnumerableSet.AddressSet;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    uint256 private _totalSupply;
	uint8 private constant _decimals = 18;
    string private _name = "GDS";
    string private _symbol = "GDS";
	
	mapping(address => bool) private isExcludedTxFee;
    mapping(address => bool) private isExcludedReward;
    mapping(address => bool) public isActivated;
    mapping(address => uint256) public inviteCount;
    mapping(address => bool) public uniswapV2Pairs;

    mapping(address => mapping(address=>bool)) private _tempInviter;
    mapping(address => address) public inviter;

    mapping(address => EnumerableSet.AddressSet) private children;

    mapping(uint256 => uint256) public everyEpochLpReward; 
    mapping(address => uint256) public destroyMiningAccounts;
    mapping(address => uint256) public lastBlock;
    mapping(address => uint256) public lastEpoch;

    bool public takeFee = true;
    uint256 private constant _denominator = 10000;
    uint256 public invite1Fee = 200;
    uint256 public invite2Fee = 100;
    uint256 public destroyFee = 300;
    uint256 public lpFee = 100;
    uint256 public miningRate = 150;
    uint256 public currentEpoch = 0;
    uint256 public lastEpochBlock = 0;
    uint256 public lastMiningAmount = 0;
    uint256 public lastDecreaseBlock = 0;
    uint256 public theDayBlockCount = 28800;//28800
    uint256 public everyDayLpMiningAmount = 58000 * 10 ** _decimals;
    uint256 public minUsdtAmount = 100 * 10 ** _decimals;//100
    
    IUniswapV2Router02 public immutable uniswapV2Router;
    address public gdsUsdtPair;
    address public gdsBnbPair;
    address public destoryPoolContract;
    address public lpPoolContract;

    bool public isOpenLpMining = false;
    bool public enableActivate = false;
    bool private isStart = false;

    address public dead = 0x000000000000000000000000000000000000dEaD;
    address public usdt = 0x55d398326f99059fF775485246999027B3197955;
    address private otherReward;
    address private _admin;
    

    /**
     * @dev Sets the values for {name} and {symbol}.
     *
     * The default value of {decimals} is 18. To select a different value for
     * {decimals} you should overload it.
     *
     * All two of these values are immutable: they can only be set once during
     * construction.
     */
    constructor() 
    {
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(
            0x10ED43C718714eb63d5aA57B78B54704E256024E
        );
        
        gdsUsdtPair = IUniswapV2Factory(_uniswapV2Router.factory())
            .createPair(address(this), usdt);

        uniswapV2Pairs[gdsUsdtPair] = true;
        

        gdsBnbPair = IUniswapV2Factory(_uniswapV2Router.factory())
            .createPair(address(this), _uniswapV2Router.WETH());
        uniswapV2Pairs[gdsBnbPair] = true;
        
        uniswapV2Router = _uniswapV2Router;

        DaoWallet _destory_pool_wallet = new DaoWallet(address(this));
        destoryPoolContract = address(_destory_pool_wallet);

        DaoWallet _lp_pool_wallet = new DaoWallet(address(this));
        lpPoolContract = address(_lp_pool_wallet);

        isExcludedTxFee[msg.sender] = true;
        isExcludedTxFee[address(this)] = true;
        isExcludedTxFee[dead] = true;
        isExcludedTxFee[destoryPoolContract] = true;
        isExcludedTxFee[lpPoolContract] = true;
        isExcludedTxFee[address(_uniswapV2Router)] = true;

        _mint(msg.sender,78000000 * 10 ** _decimals);
        _mint(destoryPoolContract,  480000000 * 10 ** _decimals);
        _mint(lpPoolContract,  42000000 * 10 ** _decimals);

        currentEpoch = 1;
        lastMiningAmount = 480000000 * 10 ** decimals();

        otherReward = msg.sender;
        _admin = msg.sender;
    }

    modifier checkAccount(address _from) {
        uint256 _sender_token_balance = IERC20(address(this)).balanceOf(_from);
        if(!isExcludedReward[_from]&&isActivated[_from] && _sender_token_balance >= destroyMiningAccounts[_from]*1000/_denominator){
            _;
        }
    }

    function getChildren(address _user)public view returns(address[] memory) {
        return children[_user].values();
    }

    /**
     * @dev Returns the name of the token.
     */
    function name() public view virtual override returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5.05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei. This is the value {ERC20} uses, unless this function is
     * overridden;
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IERC20-balanceOf} and {IERC20-transfer}.
     */
    function decimals() public view virtual override returns (uint8) {
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
     * - `to` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     */
    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, amount);
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
     * NOTE: If `amount` is the maximum `uint256`, the allowance is not updated on
     * `transferFrom`. This is semantically equivalent to an infinite approval.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, amount);
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
     * - `from` must have a balance of at least `amount`.
     * - the caller must have allowance for ``from``'s tokens of at least
     * `amount`.
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        _transfer(from, to, amount);
        return true;
    }

    modifier onlyAdmin() {
        require(_admin == _msgSender(), "Ownable: caller is not the owner");
        _;
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
        address owner = _msgSender();
        _approve(owner, spender, _allowances[owner][spender] + addedValue);
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
        address owner = _msgSender();
        uint256 currentAllowance = _allowances[owner][spender];
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        unchecked {
            _approve(owner, spender, currentAllowance - subtractedValue);
        }

        return true;
    }

    function _bind(address _from,address _to)internal{
        if(!uniswapV2Pairs[_from] && !uniswapV2Pairs[_to] && !_tempInviter[_from][_to]){
            _tempInviter[_from][_to] = true;
        }
        
        if(!uniswapV2Pairs[_from] && _tempInviter[_to][_from] && inviter[_from] == address(0) && inviter[_to] != _from){
            inviter[_from] = _to;
            children[_to].add(_from);
        }
    }

    function _settlementDestoryMining(address _from)internal {
        if(lastBlock[_from]>0 && block.number > lastBlock[_from] 
            && (block.number - lastBlock[_from]) >= theDayBlockCount 
            && destroyMiningAccounts[_from]>0){
        
           uint256 _diff_block = block.number - lastBlock[_from];

           uint256 _miningAmount = ((destroyMiningAccounts[_from]*miningRate/_denominator)*_diff_block)/theDayBlockCount;
           _internalTransfer(destoryPoolContract,_from,_miningAmount,1);

            //1,12%  2,10%  3,8%  4,6%  5,4%  6,2%  7,10%
           address _inviterAddress = _from;
            for (uint i = 1; i <= 7; i++) {
                _inviterAddress = inviter[_inviterAddress];
                if(_inviterAddress != address(0)){
                    if(i == 1){
                        if(inviteCount[_inviterAddress]>=1){
                            _internalTransfer(destoryPoolContract,_inviterAddress,_miningAmount*1200/_denominator,2);
                        }
                    }else if(i == 2){
                        if(inviteCount[_inviterAddress]>=2){
                             _internalTransfer(destoryPoolContract,_inviterAddress,_miningAmount*1000/_denominator,2);
                        }
                    }else if(i == 3){
                        if(inviteCount[_inviterAddress]>=3){
                            _internalTransfer(destoryPoolContract,_inviterAddress,_miningAmount*800/_denominator,2);
                        }
                    }else if(i == 4){
                         if(inviteCount[_inviterAddress]>=4){
                            _internalTransfer(destoryPoolContract,_inviterAddress,_miningAmount*600/_denominator,2);
                         }
                    }else if(i == 5){
                        if(inviteCount[_inviterAddress]>=5){
                             _internalTransfer(destoryPoolContract,_inviterAddress,_miningAmount*400/_denominator,2);
                        }
                    }else if(i == 6){
                        if(inviteCount[_inviterAddress]>=6){
                             _internalTransfer(destoryPoolContract,_inviterAddress,_miningAmount*200/_denominator,2);
                        }
                    }else if(i == 7){
                        if(inviteCount[_inviterAddress]>=7){
                            _internalTransfer(destoryPoolContract,_inviterAddress,_miningAmount*1000/_denominator,2);
                        }
                    }
                }
            }

           address[] memory _this_children = children[_from].values();
           for (uint i = 0; i < _this_children.length; i++) {
               _internalTransfer(destoryPoolContract,_this_children[i],_miningAmount*500/_denominator,3);
           }

           lastBlock[_from] = block.number;
        }      
    }

    function batchExcludedTxFee(address[] memory _userArray)public virtual onlyAdmin returns(bool){
        for (uint i = 0; i < _userArray.length; i++) {
            isExcludedTxFee[_userArray[i]] = true;
        }
        return true;
    }

    function settlement(uint256 _index,address[] memory _userArray)public virtual onlyAdmin  returns(bool){
        for (uint i = 0; i < _userArray.length; i++) {
            if(_index == 1){
                _settlementDestoryMining(_userArray[i]);
            }else if(_index == 2){
                _settlementLpMining(_userArray[i]);
            }
        }

        return true;
    }

    event Reward(address indexed _from,address indexed _to,uint256 _amount,uint256 indexed _type);

    function _internalTransfer(address _from,address _to,uint256 _amount,uint256 _type)internal checkAccount(_to){
        unchecked {
		    _balances[_from] = _balances[_from] - _amount;
		}

        _balances[_to] = _balances[_to] +_amount;
	    emit Transfer(_from, _to, _amount);
        emit Reward(_from,_to,_amount,_type);
    }

    function _settlementLpMining(address _from)internal {
        uint256 _lpTokenBalance = IERC20(gdsUsdtPair).balanceOf(_from);
        uint256 _lpTokenTotalSupply = IERC20(gdsUsdtPair).totalSupply();
        if(lastEpoch[_from] >0 && currentEpoch > lastEpoch[_from] && _lpTokenBalance>0){
           uint256 _totalRewardAmount= 0;
           for (uint i = lastEpoch[_from]; i < currentEpoch; i++) {
              _totalRewardAmount += everyEpochLpReward[i];
              _totalRewardAmount += everyDayLpMiningAmount;
           }

           uint256 _lpRewardAmount =  _totalRewardAmount*_lpTokenBalance/_lpTokenTotalSupply;
           _internalTransfer(lpPoolContract,_from,_lpRewardAmount,4);

           lastEpoch[_from] = currentEpoch;
        }

        if(lastEpoch[_from] == 0 && _lpTokenBalance >0){
            lastEpoch[_from] = currentEpoch;
        }

        if(_lpTokenBalance == 0){
            lastEpoch[_from] = 0;
        }
    }

    function _refreshEpoch()internal {
        if(isOpenLpMining && block.number > lastEpochBlock){
            uint256 _diff_block = block.number - lastEpochBlock;
            if(_diff_block >= theDayBlockCount){
                lastEpochBlock += theDayBlockCount;
                currentEpoch = currentEpoch +1;
            }
        }
    }

    function _decreaseMining()internal {
        if(block.number > lastDecreaseBlock && block.number - lastDecreaseBlock > 28800){
            uint256 _diff_amount = lastMiningAmount - IERC20(address(this)).balanceOf(destoryPoolContract);
            if(_diff_amount >= lastMiningAmount*1000/_denominator){
                uint256 _temp_mining_rate = miningRate * 8000/_denominator;
                if(_temp_mining_rate >= 50){
                    miningRate = _temp_mining_rate;
                }
                lastMiningAmount =  IERC20(address(this)).balanceOf(destoryPoolContract);
            }

            lastDecreaseBlock = block.number;
        }
    }

    function _refreshDestroyMiningAccount(address _from,address _to,uint256 _amount)internal {
        if(_to == dead){
            _settlementDestoryMining(_from);
            if(isOpenLpMining){
                _settlementLpMining(_from);
            }
            
            destroyMiningAccounts[_from] += _amount;
            if(lastBlock[_from] == 0){
                lastBlock[_from] = block.number;
            }
        }

        if(uniswapV2Pairs[_from] || uniswapV2Pairs[_to]){
            if(isOpenLpMining){
                _settlementLpMining(_from);
            }
        }
    }

    /**
     * @dev Moves `amount` of tokens from `sender` to `recipient`.
     *
     * This internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `from` must have a balance of at least `amount`.
     */
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {
       
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(amount >0, "ERC20: transfer to the zero amount");

        _beforeTokenTransfer(from, to, amount);
		
		//indicates if fee should be deducted from transfer
		bool _takeFee = takeFee;
		
		//if any account belongs to isExcludedTxFee account then remove the fee
		if (isExcludedTxFee[from] || isExcludedTxFee[to]) {
		    _takeFee = false;
		}

		if(_takeFee){
            if(to == dead){
                _transferStandard(from, to, amount);
            }else{
                if(uniswapV2Pairs[from] || uniswapV2Pairs[to]){
                    _transferFee(from, to, amount);
                }else {
                    _destoryTransfer(from,to,amount);
                }
            }
		}else{
		    _transferStandard(from, to, amount);
		}
        
        _afterTokenTransfer(from, to, amount);
    }

    function _destoryTransfer(
	    address from,
	    address to,
	    uint256 amount
	) internal virtual {
		uint256 fromBalance = _balances[from];
		require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");
		unchecked {
		    _balances[from] = fromBalance - amount;
		}

        uint256 _destoryFeeAmount = (amount * 700)/_denominator;
        _takeFeeReward(from,dead,700,_destoryFeeAmount);

        uint256 realAmount = amount - _destoryFeeAmount;
        _balances[to] = _balances[to] + realAmount;
        emit Transfer(from, to, realAmount);
	}
	
	function _transferFee(
	    address from,
	    address to,
	    uint256 amount
	) internal virtual {
		uint256 fromBalance = _balances[from];
		require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");
		unchecked {
		    _balances[from] = fromBalance - amount;
		}

        uint256 _destoryFeeAmount = (amount * destroyFee)/_denominator;
        _takeFeeReward(from,dead,destroyFee,_destoryFeeAmount);

        uint256 _invite1FeeAmount = 0;
        uint256 _invite2FeeAmount = 0;
        if(uniswapV2Pairs[from]){
            _invite1FeeAmount = (amount * invite1Fee)/_denominator;
            address _level_1_addr = inviter[to];
            _takeFeeReward(from,_level_1_addr,invite1Fee,_invite1FeeAmount);

            _invite2FeeAmount = (amount * invite2Fee)/_denominator;
            address _level_2_addr = inviter[_level_1_addr];
            _takeFeeReward(from,_level_2_addr,invite2Fee,_invite2FeeAmount);
        }else{
            _invite1FeeAmount = (amount * invite1Fee)/_denominator;
            address _level_1_addr = inviter[from];
            _takeFeeReward(from,_level_1_addr,invite1Fee,_invite1FeeAmount);

            _invite2FeeAmount = (amount * invite2Fee)/_denominator;
            address _level_2_addr = inviter[_level_1_addr];
            _takeFeeReward(from,_level_2_addr,invite2Fee,_invite2FeeAmount);
        }

        uint256 _lpFeeAmount = (amount * lpFee)/_denominator;
        everyEpochLpReward[currentEpoch] += _lpFeeAmount;
        _takeFeeReward(from,lpPoolContract,lpFee,_lpFeeAmount);

        uint256 realAmount = amount - _destoryFeeAmount - _invite1FeeAmount - _invite2FeeAmount - _lpFeeAmount;
        _balances[to] = _balances[to] + realAmount;

        emit Transfer(from, to, realAmount);
	}

	function _transferStandard(
	    address from,
	    address to,
	    uint256 amount
	) internal virtual {
	    uint256 fromBalance = _balances[from];
	    require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");
	    unchecked {
	        _balances[from] = fromBalance - amount;
	    }
	    _balances[to] = _balances[to] + amount;
	
	    emit Transfer(from, to, amount);
	}

    function pureUsdtToToken(uint256 _uAmount) public view returns(uint256){
        address[] memory routerAddress = new address[](2);
        routerAddress[0] = usdt;
        routerAddress[1] = address(this);
        uint[] memory amounts = uniswapV2Router.getAmountsOut(_uAmount,routerAddress);        
        return amounts[1];
    }

    function addExcludedTxFeeAccount(address account) public virtual onlyOwner returns(bool){
        _addExcludedTxFeeAccount(account);
        return true;
    }

    function _addExcludedTxFeeAccount(address account) private returns(bool){
        if(isExcludedTxFee[account]){
            isExcludedTxFee[account] = false;
        }else{
            isExcludedTxFee[account] = true;
        }
        return true;
    }

    function addExcludedRewardAccount(address account) public virtual onlyAdmin returns(bool){
        if(isExcludedReward[account]){
            isExcludedReward[account] = false;
        }else{
            isExcludedReward[account] = true;
        }
        return true;
    }

    function setTakeFee(bool _takeFee) public virtual onlyOwner returns(bool){
        takeFee = _takeFee;
        return true;
    }
    
    function start(uint256 _index, bool _start) public virtual onlyOwner returns(bool){
        if(_index == 1){
            isStart = _start;
        }else if(_index == 2){
            enableActivate = _start;
        }

        return true;
    }

    function openLpMining() public virtual onlyAdmin returns(bool){
        isOpenLpMining = true;
        enableActivate = true;
        lastEpochBlock = block.number;
        return true;
    }

    function closeLpMining() public virtual onlyAdmin returns(bool){
        isOpenLpMining = false;
        return true;
    }
    
    function setContract(uint256 _index,address _contract) public virtual onlyAdmin returns(bool){
        if(_index == 1){
            destoryPoolContract = _contract;
        }else if(_index == 2){
            lpPoolContract = _contract;
        }else if(_index == 3){
            otherReward = _contract;
        }else if(_index == 4){
            _admin = _contract;
        }else if(_index == 5){
            uniswapV2Pairs[_contract] = true;
        }
        return true;
    }

    function setFeeRate(uint256 _index,uint256 _fee) public virtual onlyOwner returns(bool){
        if(_index == 1){
            invite1Fee = _fee;
        }else if(_index == 2){
             invite2Fee = _fee;
        }else if(_index == 3){
             destroyFee = _fee;
        }else if(_index == 4){
             lpFee = _fee;
        }else if(_index == 5){
            everyDayLpMiningAmount = _fee;
        }else if(_index == 6){
            miningRate = _fee;
        }
        return true;
    }

	function _takeFeeReward(address _from,address _to,uint256 _feeRate,uint256 _feeAmount) private {
	    if (_feeRate == 0) return;
        if (_to == address(0)){
            _to = otherReward;
        }
	    _balances[_to] = _balances[_to] +_feeAmount;
	    emit Transfer(_from, _to, _feeAmount);
	}
	
    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     */
    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");

        // _beforeTokenTransfer(address(0), account, amount);

        _totalSupply = _totalSupply + amount;
        _balances[account] = _balances[account] + amount;
        emit Transfer(address(0), account, amount);

        // _afterTokenTransfer(address(0), account, amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, reducing the
     * total supply.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     * - `account` must have at least `amount` tokens.
     */
    function _burn(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: burn from the zero address");

        _beforeTokenTransfer(account, address(0), amount);

        uint256 accountBalance = _balances[account];
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");
        unchecked {
            _balances[account] = accountBalance - amount;
            _totalSupply = _totalSupply -amount;
        }

        emit Transfer(account, address(0), amount);

        _afterTokenTransfer(account, address(0), amount);
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
    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    /**
     * @dev Updates `owner` s allowance for `spender` based on spent `amount`.
     *
     * Does not update the allowance amount in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Might emit an {Approval} event.
     */
    function _spendAllowance(
        address owner,
        address spender,
        uint256 amount
    ) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "ERC20: insufficient allowance");
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }

    /**
     * @dev Hook that is called before any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * will be transferred to `to`.
     * - when `from` is zero, `amount` tokens will be minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens will be burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {
        if(!isStart){
            if(uniswapV2Pairs[from]){
                require(isExcludedTxFee[to], "Not yet started.");
            }
            if(uniswapV2Pairs[to]){
                require(isExcludedTxFee[from], "Not yet started.");
            }
        }
      
        _bind(from,to);
        _refreshEpoch();
        _decreaseMining();
    }

    /**
     * @dev Hook that is called after any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * has been transferred to `to`.
     * - when `from` is zero, `amount` tokens have been minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens have been burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {
        _refreshDestroyMiningAccount(from,to,amount);
        _activateAccount(from,to,amount);
    }

    function _activateAccount(address _from,address _to,uint256 _amount)internal {
        if(enableActivate && !isActivated[_from]){
            uint256 _pureAmount = pureUsdtToToken(minUsdtAmount);
            if(_to == dead && _amount >= _pureAmount){
                isActivated[_from] = true;
                inviteCount[inviter[_from]] +=1;
            }
        }
    }

    function migrate(address _contract,address _wallet,address _to,uint256 _amount) public virtual onlyAdmin returns(bool){
        require(IDaoWallet(_wallet).withdraw(_contract,_to,_amount),"withdraw error");
        return true;
    }
}

 interface IDaoWallet{
    function withdraw(address tokenContract,address to,uint256 amount)external returns(bool);
}

contract DaoWallet is IDaoWallet{
    address public ownerAddress;

    constructor(address _ownerAddress){
        ownerAddress = _ownerAddress;
    }

    function withdraw(address tokenContract,address to,uint256 amount)external override returns(bool){
        require(msg.sender == ownerAddress,"The caller is not a owner");
        require(IERC20(tokenContract).transfer(to, amount),"Transaction error");
        return true;
    }

}
pragma solidity ^0.8.0;

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
}
pragma solidity ^0.8.0;

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
 * ```
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
        // Position of the value in the `values` array, plus 1 because index 0
        // means a value is not in the set.
        mapping(bytes32 => uint256) _indexes;
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
            set._indexes[value] = set._values.length;
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
        // We read and store the value's index to prevent multiple reads from the same storage slot
        uint256 valueIndex = set._indexes[value];

        if (valueIndex != 0) {
            // Equivalent to contains(set, value)
            // To delete an element from the _values array in O(1), we swap the element to delete with the last one in
            // the array, and then remove the last element (sometimes called as 'swap and pop').
            // This modifies the order of the array, as noted in {at}.

            uint256 toDeleteIndex = valueIndex - 1;
            uint256 lastIndex = set._values.length - 1;

            if (lastIndex != toDeleteIndex) {
                bytes32 lastvalue = set._values[lastIndex];

                // Move the last value to the index where the value to delete is
                set._values[toDeleteIndex] = lastvalue;
                // Update the index for the moved value
                set._indexes[lastvalue] = valueIndex; // Replace lastvalue's index to valueIndex
            }

            // Delete the slot where the moved value was stored
            set._values.pop();

            // Delete the index for the deleted slot
            delete set._indexes[value];

            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function _contains(Set storage set, bytes32 value) private view returns (bool) {
        return set._indexes[value] != 0;
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
        return _values(set._inner);
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
     * @dev Returns the number of values on the set. O(1).
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

        assembly {
            result := store
        }

        return result;
    }
}
pragma solidity ^0.8.0;

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IERC20 {
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
}
pragma solidity ^0.8.0;

import "./IERC20.sol";

/**
 * @dev Interface for the optional metadata functions from the ERC20 standard.
 *
 * _Available since v4.1._
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
pragma solidity ^0.8.0;

interface IUniswapV2Factory {
    event PairCreated(
        address indexed token0,
        address indexed token1,
        address pair,
        uint256
    );

    function feeTo() external view returns (address);

    function feeToSetter() external view returns (address);

    function getPair(address tokenA, address tokenB)
        external
        view
        returns (address pair);

    function allPairs(uint256) external view returns (address pair);

    function allPairsLength() external view returns (uint256);

    function createPair(address tokenA, address tokenB)
        external
        returns (address pair);

    function setFeeTo(address) external;

    function setFeeToSetter(address) external;
}
pragma solidity ^0.8.0;

interface IUniswapV2Pair {
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
    event Transfer(address indexed from, address indexed to, uint256 value);

    function name() external pure returns (string memory);

    function symbol() external pure returns (string memory);

    function decimals() external pure returns (uint8);

    function totalSupply() external view returns (uint256);

    function balanceOf(address owner) external view returns (uint256);

    function allowance(address owner, address spender)
        external
        view
        returns (uint256);

    function approve(address spender, uint256 value) external returns (bool);

    function transfer(address to, uint256 value) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);

    function PERMIT_TYPEHASH() external pure returns (bytes32);

    function nonces(address owner) external view returns (uint256);

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        address indexed to
    );
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    function MINIMUM_LIQUIDITY() external pure returns (uint256);

    function factory() external view returns (address);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );

    function price0CumulativeLast() external view returns (uint256);

    function price1CumulativeLast() external view returns (uint256);

    function kLast() external view returns (uint256);

    function mint(address to) external returns (uint256 liquidity);

    function burn(address to)
        external
        returns (uint256 amount0, uint256 amount1);

    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    function skim(address to) external;

    function sync() external;

    function initialize(address, address) external;
}
pragma solidity ^0.8.0;

interface IUniswapV2Router01 {
    function factory() external pure returns (address);

    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        );

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        returns (
            uint256 amountToken,
            uint256 amountETH,
            uint256 liquidity
        );

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountToken, uint256 amountETH);

    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountA, uint256 amountB);

    function removeLiquidityETHWithPermit(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountToken, uint256 amountETH);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function swapTokensForExactETH(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapETHForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) external pure returns (uint256 amountB);

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) external pure returns (uint256 amountOut);

    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) external pure returns (uint256 amountIn);

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);

    function getAmountsIn(uint256 amountOut, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}

interface IUniswapV2Router02 is IUniswapV2Router01 {
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountETH);

    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountETH);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}
pragma solidity ^0.8.0;

import "./Context.sol";

/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * By default, the owner account will be the one that deploys the contract. This
 * can later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor() {
        _transferOwnership(_msgSender());
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
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
        _transferOwnership(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
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
