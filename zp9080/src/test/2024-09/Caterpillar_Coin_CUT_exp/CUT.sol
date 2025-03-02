pragma solidity ^0.8.26;
import "./interface.sol";

contract BEP20USDT is Context, IBEP20, Ownable,ReentrancyGuard {
  using SafeMath for uint256;

  mapping (address => uint256) private _balances;
  mapping (address => mapping (address => uint256)) private _allowances;

  uint256 private _totalSupply;
  uint8   public _decimals;
  string public _symbol;
  string public _name;
  
  
  mapping (address => address) private _leaderAddressList;
  uint256 private _checkSetLeaderTransferAmount;
  uint256 private _leaderLPRate;
  uint256 public _maxRewardsLPDynamicAmount;
  uint256 private _minHasAmountToGetPersonAward;
  
  address private _deadHoleAddress;
  address private _circulationAddress;
  address public _routerContractAddress;
  address public _swapPlatformSendAddress;
  address private _safeCheckContractAddress;
  address private _transferFunDealTypeContractAddress;
  address private _lpFutureYieldContractAddress;
  address private _feeSpecialRecieverAddress;
  mapping (address => bool) private _isWhiteAddress;

  uint256 private _lpBurnRate = 1;
  uint256 private _blackWholeRate = 10;
  uint256 private _lpSwitchAddrRate = 10;
  uint256 private _upleaderLPLevelRate = 200;
  uint256 private _baseRateAmount = 1000;
  
  uint256 private _lastLPBurnTime;
  uint256 private _changeStateRateTimeAfterOpen = 90 * 86400;

  uint256 private _firstStatelimitBuyAmount = 4000 * 10 ** _decimals;
  uint256 private _firstStateCheckTimeAfterOpen = 7 * 86400; 
  mapping(address => uint256) private _firstStateBuyTotalAmount;
  uint256 private _dynamicReawardAccountTransferLimit = 500;

  uint256 private _openPlatfromTime;
  uint256 private _transferTimeLimit;
  mapping( address => uint256 ) private _addressTransfer;

  mapping (address => uint256) private userEffectiveDirectPushCount;
  uint256 private _minLpUsdtInvestMoney;
  mapping (address=>bool) private _isFirstTimeInvestmentAccount;
  uint256 private _lpLeaderRewardRate;
  address private _otherPairContractAddress;
  bool private _isOpenLpSpecialDealFlag;
  mapping(address=>bool) private _isDynamicReawardAccountFlag;
  uint256 private _removeLPToBlackWholeRate = 20;

  constructor(
    address safeCheckContractAddress,
    address transferFunDealTypeContractAddress,
    address lpFutureYieldContractAddress,
    address circulationAddress,
    address feeSpecialRecieverAddress
    )  {
    _safeCheckContractAddress = safeCheckContractAddress;
    _transferFunDealTypeContractAddress = transferFunDealTypeContractAddress;
    _lpFutureYieldContractAddress = lpFutureYieldContractAddress;
    _feeSpecialRecieverAddress    = feeSpecialRecieverAddress;

    _name = "CUT";
    _symbol = "CUT";
    _decimals = 6;
    _totalSupply = 210000000 * 10 ** _decimals;
    _maxRewardsLPDynamicAmount = 207000000 * 10 ** _decimals;
    // First circulation address, used for adding pools and subsequent operations
    _balances[circulationAddress] = _totalSupply - _maxRewardsLPDynamicAmount;
    _isWhiteAddress[circulationAddress] = true;
    _circulationAddress = circulationAddress;
    _checkSetLeaderTransferAmount = 100;
    _leaderLPRate = 200;
    _minHasAmountToGetPersonAward = 2000000;
    _deadHoleAddress = address(0);
    _minLpUsdtInvestMoney = 28 * 10 ** 18;
    _lpLeaderRewardRate = 200;
    // Router address for testing environment： 0xD99D1c33F9fC3444f8101754aBC46c52416550D1
    // Router address for formal environment：  0x10ED43C718714eb63d5aA57B78B54704E256024E
    _routerContractAddress = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    // USDT address for testing environment：   0x55d398326f99059fF775485246999027B3197955
    // USDT address for formal environment：    0x55d398326f99059fF775485246999027B3197955
    _otherPairContractAddress = 0x55d398326f99059fF775485246999027B3197955;
    _swapPlatformSendAddress = IPancakeFactory(IPancakeRouter01(_routerContractAddress).factory()).createPair( _otherPairContractAddress, address(this) );
    _openPlatfromTime = block.timestamp + 86400 * 3;
  }


  function initConfig() public onlyOwner{
    ISecurityChecker(_safeCheckContractAddress).addWhitelist(_routerContractAddress);
    ISecurityChecker(_safeCheckContractAddress).addWhitelist(_swapPlatformSendAddress);
    ISecurityChecker(_safeCheckContractAddress).addWhitelist(IPancakeRouter01(_routerContractAddress).factory());
    ISecurityChecker(_safeCheckContractAddress).addWhitelist(address(this));
    ISecurityChecker(_safeCheckContractAddress).addWhitelist(_otherPairContractAddress);
    ISecurityChecker(_safeCheckContractAddress).addWhitelist(0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768);
    ISecurityChecker(_safeCheckContractAddress).addWhitelist(0xd77C2afeBf3dC665af07588BF798bd938968c72E);
    ILPFutureYieldContract(_lpFutureYieldContractAddress).setLPAddress(_swapPlatformSendAddress);
    ILPFutureYieldContract(_lpFutureYieldContractAddress).setAtokenAddress(address(this));
    IActCheckContract(_transferFunDealTypeContractAddress).setInitUpdate( _routerContractAddress ,  _swapPlatformSendAddress ,_lpFutureYieldContractAddress,address(this) ,_minLpUsdtInvestMoney );
  }

  // Remember to synchronize the functions used for updating reserves
  function _updateReserves() private {
      IPancakePair pair = IPancakePair(_swapPlatformSendAddress);
      pair.sync();  // Ensure that the reserve of the liquidity pool matches the current balance of the pool
  }

  // Bottom pool combustion
  function lpBurnATokenAct() private {   
    if(  SafeMath.div(_lastLPBurnTime,3600,"SafeMath: division by zero") < SafeMath.div(block.timestamp,3600,"SafeMath: division by zero") ){
      uint256 modifyAmount = SafeMath.div(_balances[_swapPlatformSendAddress] *  _lpBurnRate ,_baseRateAmount,"SafeMath: division by zero");
      if( _balances[_swapPlatformSendAddress] > modifyAmount ){
        _transferOrigin(_swapPlatformSendAddress, _deadHoleAddress, modifyAmount);
        _lastLPBurnTime = block.timestamp;
        _updateReserves();
      }    
    }
  }

  // Transaction behavior detection of dynamic accounts
  function dynamicReawardAccountActCheck(address addr,uint256 checkAmount) private view returns(bool flag){
    flag = true;
    if( _isDynamicReawardAccountFlag[addr] == true ){
         // Calculate the amount of USDT added, and the USDT value added to the pool is: USDT quantity * 2
        uint256 usdtValue = IActCheckContract(_transferFunDealTypeContractAddress).calculateUSDTAmountB( _swapPlatformSendAddress, address(this) ,  checkAmount );
        if(  usdtValue < _minLpUsdtInvestMoney ){
          flag = false;
        }
    }
    return flag;
  }

  function moreUserInsertAddLP(address[] calldata users, uint256 lpAmount, uint256 usdtValue) public onlyOwner{
    uint256[] memory orderlist;
    address[] memory userlist;
    (orderlist , userlist) = IActCheckContract(_transferFunDealTypeContractAddress).moreUserInsertAddLP( users , lpAmount ,  usdtValue );
    uint256 addressAmount;
    for (uint256 i = 0; i < orderlist.length; i++) {
        addLPExtendDeal( userlist[i] , orderlist[i] );
        addressAmount = ILPFutureYieldContract(_lpFutureYieldContractAddress).activeOrdersByAddressTrueModify( userlist[i] );
        _isFirstTimeInvestmentAccount[userlist[i]] = true;
        _balances[userlist[i]] = _balances[userlist[i]].add(addressAmount);
    }
  }

  // Add Pool
  function actDealLPAddBehavior(address sender, address recipient, uint256 amount) private {
    sender;
    recipient;
    amount;
    uint256 orderId;
    bool isSuccessed;
    (isSuccessed , orderId) = IActCheckContract(_transferFunDealTypeContractAddress).actDealLPAddBehaviorTrue(sender,recipient,amount);
    require(isSuccessed == true,"actDealLPAddBehavior is Deny! Please Check!");
    addLPExtendDeal( sender , orderId );
  }

  function addLPExtendDeal( address sender, uint256 orderId ) private {
    address tmpuser = sender;
    for (uint256 i = 0; i < 3; i++) {
      if( _leaderAddressList[tmpuser] != address(0) ){
        ILPFutureYieldContract(_lpFutureYieldContractAddress).addReward(  orderId , _leaderAddressList[tmpuser] , _lpLeaderRewardRate , (i+1) );
        tmpuser = _leaderAddressList[tmpuser];
      }else{
        break;
      }
    }
    // Record status
    if(_leaderAddressList[sender] != address(0)){
      userEffectiveDirectPushCount[ _leaderAddressList[sender] ] += 1; 
      ILPFutureYieldContract(_lpFutureYieldContractAddress).updateLeaderTeamEffectiveNum( _leaderAddressList[sender] , userEffectiveDirectPushCount[ _leaderAddressList[sender] ]   );
    }
  }

 

  // Remove the pool
  function actDealLPRemoveBehavior(address sender, address recipient, uint256 amount) private{
    IActCheckContract(_transferFunDealTypeContractAddress).actDealLPRemoveBehaviorTrue(sender , recipient , amount);
     // Reduce the number of effective users under the direct leadership of superiors
    if( _leaderAddressList[recipient] != address(0) ){
      if( userEffectiveDirectPushCount[_leaderAddressList[recipient]] > 0){
        userEffectiveDirectPushCount[_leaderAddressList[recipient]] -= 1;
        ILPFutureYieldContract(_lpFutureYieldContractAddress).updateLeaderTeamEffectiveNum( _leaderAddressList[recipient] , userEffectiveDirectPushCount[ _leaderAddressList[sender] ]   );
      }
    }   

   _transferOrigin(sender,recipient,amount);
    // Price protection mechanism
    if( _isFirstTimeInvestmentAccount[recipient] == false){
      if( _maxRewardsLPDynamicAmount > 0 ){
          uint256 leftAmount = IActCheckContract(_transferFunDealTypeContractAddress).valuePreservationByRemoveLP(recipient,amount);
          if( leftAmount <=  amount){
            _transferOrigin(recipient,_deadHoleAddress,amount - leftAmount);
          }else{
            _balances[recipient] = _balances[recipient].add( leftAmount -  amount );
          }
          uint256 feeDealAmount = SafeMath.div(leftAmount * _removeLPToBlackWholeRate,_baseRateAmount,"SafeMath: division by zero");
          if(  _balances[recipient] >= feeDealAmount ){
            _transferOrigin(recipient,_deadHoleAddress,feeDealAmount);
          }
      }
    }else{
      _transferOrigin(recipient,_deadHoleAddress,amount);
    }
  }

  function dealTransferFun(address sender, address recipient, uint256 amount) private{
    address activateAddr = sender;
    if( _swapPlatformSendAddress == sender && _swapPlatformSendAddress != recipient){
      activateAddr = recipient;
    }
    if( _swapPlatformSendAddress != sender && _swapPlatformSendAddress == recipient){
      activateAddr = sender;
    }
    activateAddressReward(activateAddr);
    uint256 actFlag = IActCheckContract(_transferFunDealTypeContractAddress).actionTransferDeal(_routerContractAddress , _swapPlatformSendAddress , address(this) , msg.sender ,  sender , recipient  ,  amount );
    require(_balances[sender] >= amount, "BEP20: transfer amount more than balances.");
    // The amount cannot be fully transferred, at least 1 wei should be retained
    if(_balances[sender] == amount && amount >= 1){
        amount = amount - 1;
    }
    require(amount != 0, "BEP20: transfer zero balance");

    if (actFlag == 1) {
      require(_openPlatfromTime < block.timestamp || _isWhiteAddress[sender],"_transfer deny is 1!");
      if( _isOpenLpSpecialDealFlag == false ){
        actDealCommonTransfer( sender , recipient , amount);
      }else{
        actDealLPAddBehavior( sender , recipient , amount);
        actDealCommonTransfer( sender , recipient , amount);
      }
      transferTimeCheck(sender);
      
    } else if (actFlag == 2) {
      require(_openPlatfromTime < block.timestamp || _isWhiteAddress[recipient],"_transfer deny is 2!");
      
      if( _isOpenLpSpecialDealFlag == false ){
        actDealCommonTransfer( sender , recipient , amount);
      }else{
         actDealLPRemoveBehavior( sender , recipient , amount);
      }
      transferTimeCheck(recipient);
      
    } else if (actFlag == 3) {
      require(_openPlatfromTime < block.timestamp || _isWhiteAddress[recipient],"_transfer deny is 3!");
      
      if( _openPlatfromTime!= 0 ){
        _firstStateBuyTotalAmount[recipient] = _firstStateBuyTotalAmount[recipient] + amount;
        if( _openPlatfromTime + _firstStateCheckTimeAfterOpen >= block.timestamp ){
          require(_firstStatelimitBuyAmount >= _firstStateBuyTotalAmount[recipient],"_firstStatelimitBuyAmount Deny!");
        }
      }

      ILPFutureYieldContract(_lpFutureYieldContractAddress).updatePrice();
      actDealBuyThingsSwap( sender , recipient , amount);
      transferTimeCheck(recipient);
    } else if (actFlag == 4) {
      require(_openPlatfromTime < block.timestamp || _isWhiteAddress[sender],"_transfer deny is 4!");
      // Restrictions on dynamic accounts
      require(  dynamicReawardAccountActCheck( sender , amount )  == true , "Denamic Account Amount is too low!"    );
      // Bottom pool combustion
      lpBurnATokenAct();
     
      ILPFutureYieldContract(_lpFutureYieldContractAddress).updatePrice();
      actDealSellThingSwap( sender , recipient , amount);
      transferTimeCheck(sender);
    } else {
      // Restrictions on dynamic accounts
      if( dynamicReawardAccountActCheck( sender , amount )  == false ){
        require(  amount <= _dynamicReawardAccountTransferLimit, "Denamic Account Amount is too low!"    );
      }
      actDealCommonTransfer( sender , recipient , amount);
      transferTimeCheck(sender);
    }
  }
  
  function transferTimeCheck(address addr) private{
    if( _transferTimeLimit > 0){
      require( (block.timestamp - _addressTransfer[addr])  > _transferTimeLimit , "The trading time is very close!");
      _addressTransfer[addr] = block.timestamp;
    }
  }

  function activateAddressReward(address addr) private{
    uint256 senderReward     =  ILPFutureYieldContract(_lpFutureYieldContractAddress).activeOrdersByAddressTrueModify(addr);
    if( _maxRewardsLPDynamicAmount > senderReward ){
      _maxRewardsLPDynamicAmount = _maxRewardsLPDynamicAmount - senderReward;
    }else{
      _maxRewardsLPDynamicAmount = 0;
    }
   _balances[addr] = _balances[addr].add(senderReward);
  }
  
  function _transfer(address sender, address recipient, uint256 amount) internal nonReentrant {
    require(sender    != address(0), "BEP20: transfer from the zero address");
    require(recipient != address(0), "BEP20: transfer to the zero address");
    require(sender    != recipient,  "BEP20: sender and recipient is same!");
    if(_lpSwitchAddrRate > 0 && _openPlatfromTime + _changeStateRateTimeAfterOpen <= block.timestamp && _openPlatfromTime != 0){_lpSwitchAddrRate = 0;}
    ISecurityChecker(_safeCheckContractAddress).botTransferCheck( tx.origin , msg.sender ,sender , recipient , amount); 
    // Activate leadership relationships
    updateLeaderByTransfer(sender,recipient,amount);
    dealTransferFun(sender, recipient, amount);
  }

  function updateLeaderByTransfer(address sender, address recipient, uint256 amount) private{
    if( amount == _checkSetLeaderTransferAmount ){
        if ( !isInSwapPlatformAddressList(sender) && 
          !isInSwapPlatformAddressList(recipient) && 
          getManagerUpAddressByAddress(sender)  == address(0) && 
          ISecurityChecker(_safeCheckContractAddress).isContract(sender) == false &&
          ISecurityChecker(_safeCheckContractAddress).isContract(recipient) == false &&
          sender != address(0) &&
          recipient != address(0)
        ){
          bool isChangeFlag;
          address leaderTmpAddress;
          for (uint256 i; i<4; i++) {
            leaderTmpAddress = _leaderAddressList[recipient];
            if( leaderTmpAddress == address(0 )){
              isChangeFlag = true;
              break;
            }
            require( leaderTmpAddress != sender , "updateLeaderByTransfer error" );
            if(i == 3){  isChangeFlag = true;  }
          }
          if( isChangeFlag == true ){
              _leaderAddressList[sender]  = recipient;
              emit SetManagerUpAddress(sender, recipient);
              if( _isDynamicReawardAccountFlag[recipient] == false){_isDynamicReawardAccountFlag[recipient] = true;}
            
              if( ILPFutureYieldContract(_lpFutureYieldContractAddress).getInvestLPValidUser(sender) == true ){
                userEffectiveDirectPushCount[recipient] += 1;
                ILPFutureYieldContract(_lpFutureYieldContractAddress).updateLeaderTeamEffectiveNum( _leaderAddressList[recipient] , userEffectiveDirectPushCount[ _leaderAddressList[sender] ]   );
              }
          }
          
       } 
    }
  }

  // Ordinary transfer
  function actDealCommonTransfer(address sender, address recipient, uint256 amount) private{
    _transferOrigin(sender,recipient,amount);
  }

  // purchase
  function actDealBuyThingsSwap(address sender, address recipient, uint256 amount) private{
    uint256 _destroyFee = SafeMath.div(amount * _blackWholeRate,_baseRateAmount,"SafeMath: division by zero");
    uint256 _lpFee      = SafeMath.div(amount * _lpSwitchAddrRate,_baseRateAmount,"SafeMath: division by zero");
    _transferOrigin(sender,recipient,amount-_destroyFee-_lpFee);
    _transferOrigin(sender,_deadHoleAddress,_destroyFee);
    _transferOrigin(sender,_feeSpecialRecieverAddress,_lpFee);
  }

  // sell out
  function actDealSellThingSwap(address sender, address recipient, uint256 amount) private{
      uint256 _destroyFee = SafeMath.div(amount * _blackWholeRate,_baseRateAmount,"SafeMath: division by zero");
      uint256 _lpFee      = SafeMath.div(amount * _lpSwitchAddrRate,_baseRateAmount,"SafeMath: division by zero");
      _transferOrigin(sender,_deadHoleAddress,_destroyFee);
      _transferOrigin(sender,_feeSpecialRecieverAddress,_lpFee);
      _transferOrigin(sender,recipient,amount - _destroyFee - _lpFee);
  }

  /*
  // Base Function ---- Start
  */
  event SetManagerUpAddress(address indexed downPeople, address indexed upPeople);
  function decimals() public override view returns (uint8) {
    return _decimals;
  }
  function getOwner() public override view returns (address) {
    return owner();
  }
  function totalSupply() public override view returns (uint256) {
    return _totalSupply;
  }
  function symbol() public override view returns (string memory) {
    return _symbol;
  }
  function name() public override view returns (string memory) {
    return _name;
  }
  function balanceOf(address account)  public override  view returns (uint256) {
    if(account == _swapPlatformSendAddress || account == _routerContractAddress || account == _otherPairContractAddress || account == address(this)){
       return _balances[account];
    }else{
      return _balances[account] + ILPFutureYieldContract(_lpFutureYieldContractAddress).activeOrdersByAddressReadOnly(account);
    }
  }
  function allowance(address owner, address spender) public override view returns (uint256) {
    return _allowances[owner][spender];
  }
  function transfer(address recipient, uint256 amount) public override returns (bool) {
    _transfer(_msgSender(), recipient, amount);
    return true;
  }
  function approve(address spender, uint256 amount) public override returns (bool) {
    ISecurityChecker(_safeCheckContractAddress).botTransferCheck( tx.origin , msg.sender ,msg.sender , spender , amount);
    _approve(_msgSender(), spender, amount);
    return true;
  }
  function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
    _transfer(sender, recipient, amount);
    _approve(sender, _msgSender(), _allowances[sender][_msgSender()].sub(amount, "BEP20: transfer amount exceeds allowance"));
    return true;
  }
  function increaseAllowance(address spender, uint256 addedValue) public returns (bool) {
    _approve(_msgSender(), spender, _allowances[_msgSender()][spender].add(addedValue));
    return true;
  }
  function decreaseAllowance(address spender, uint256 subtractedValue) public returns (bool) {
    _approve(_msgSender(), spender, _allowances[_msgSender()][spender].sub(subtractedValue, "BEP20: decreased allowance below zero"));
    return true;
  }
  function _transferOrigin(address sender, address recipient, uint256 amount) private{
    if( amount > 0 ){
      _balances[sender] = _balances[sender].sub(amount, "BEP20: transfer amount exceeds balance");
      _balances[recipient] = _balances[recipient].add(amount);
      emit Transfer(sender, recipient, amount);
    }
  }
  function _approve(address owner, address spender, uint256 amount) internal {
    require(owner != address(0), "BEP20: approve from the zero address");
    require(spender != address(0), "BEP20: approve to the zero address");
    _allowances[owner][spender] = amount;
    emit Approval(owner, spender, amount);
  }

  /*
  // Base Function ---- End
  */

  /*
  // Read State Function ---- Start
  */
  function teamEffectiveAcountNum(address account)  public  view returns (uint256) {
    return userEffectiveDirectPushCount[account] * 10 ** _decimals;
  }

  function getMaxRewardsLPDynamicAmount() public view returns(uint256){
    return _maxRewardsLPDynamicAmount;
  }

  function getManagerUpAddressByAddress(address selfAddress) private view returns(address){
      return _leaderAddressList[selfAddress];
  }

  function isInSwapPlatformAddressList(address checkAddress) private view returns(bool){
      bool flag = false;
      if( checkAddress == _swapPlatformSendAddress){flag = true;}
      return flag;
  }
  /*
  // Read State Function ---- End
  */
  
  /*
  // Set State Function ---- Start
  */
  function setOpenPlatfromTime(uint256 openPlatfromTime) public onlyOwner{
    _openPlatfromTime = openPlatfromTime;
  }

  function setWhiteAddressFlag(address addr,bool flag) public onlyOwner{
    _isWhiteAddress[addr] = flag;
  }

  function setManagerUpAddressByAddress(address selfAddress,address leaderAddress) public onlyOwner {
      _leaderAddressList[selfAddress] = leaderAddress;
  }

  function setSwapPlatformAddress(address swap_platformSendAddress) public onlyOwner{
      _swapPlatformSendAddress = swap_platformSendAddress;
  }

  function setChangeStateRateTimeAfterOpen(uint256 timeUnix) public onlyOwner{
    _changeStateRateTimeAfterOpen = timeUnix;
  }
  
  function setSafeCheckContractAddress( address addr ) public onlyOwner{
    _safeCheckContractAddress = addr;
  }

  function settransferFunDealTypeContractAddress( address addr ) public onlyOwner{
    _transferFunDealTypeContractAddress = addr;
  }

  function setLpFutureYieldContractAddress(address addr) public onlyOwner{
    _lpFutureYieldContractAddress = addr;
  }

  function setMinLpUsdtInvestMoney(uint256 amount) public onlyOwner{
    _minLpUsdtInvestMoney = amount;
  }

  function setIsOpenLpSpecialDealFlag(bool flag) public onlyOwner{
    _isOpenLpSpecialDealFlag = flag;
  }

  function setFeeSpecialRecieverAddress(address addr) public onlyOwner{
    _feeSpecialRecieverAddress = addr;
  }

  function setDynamicReawardAccountTransferLimit(uint256 num) public onlyOwner{
    _dynamicReawardAccountTransferLimit = num;
  }

  function setFirstStateCheckTimeAfterOpen(uint256 time) public onlyOwner{
    _firstStateCheckTimeAfterOpen = time;
  }

  function setFirstStatelimitBuyAmount(uint256 amount) public onlyOwner{
    _firstStatelimitBuyAmount = amount;
  }

  function setLpBurnRate(uint256 lpBurnRate) public onlyOwner{
    _lpBurnRate = lpBurnRate;
  }

  function setUpleaderLPLevelRate(uint256 upleaderLPLevelRate) public onlyOwner{
    _upleaderLPLevelRate = upleaderLPLevelRate;
  }

  function setLpSwitchAddrRate(uint256 lpSwitchAddrRate) public onlyOwner{
    _lpSwitchAddrRate = lpSwitchAddrRate;
  }

  function setBlackWholeRate(uint256 blackWholeRate) public onlyOwner{
    _blackWholeRate = blackWholeRate;
  }

  function setCheckSetLeaderTransferAmount(uint256 checkSetLeaderTransferAmount) public onlyOwner{
    _checkSetLeaderTransferAmount = checkSetLeaderTransferAmount;
  }

  function setTransferTimeLimit(uint256 transferTimeLimit)  public onlyOwner {
    _transferTimeLimit = transferTimeLimit;
  }

  function setRemoveLPToBlackWholeRate(uint256 removeLPToBlackWholeRate) public onlyOwner{
    _removeLPToBlackWholeRate = removeLPToBlackWholeRate;
  }
   /*
  // Set State Function ---- End
  */

}
pragma solidity ^0.8.26;
interface IBEP20 {
  function totalSupply() external view returns (uint256);
  function decimals() external view returns (uint8);
  function symbol() external view returns (string memory);
  function name() external view returns (string memory);
  function getOwner() external view returns (address);
  function balanceOf(address account) external view returns (uint256);
  function transfer(address recipient, uint256 amount) external returns (bool);
  function allowance(address _owner, address spender) external view returns (uint256);
  function approve(address spender, uint256 amount) external returns (bool);
  function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
  event Transfer(address indexed from, address indexed to, uint256 value);
  event Approval(address indexed owner, address indexed spender, uint256 value);
}
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
interface IPancakeFactory {
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
interface IPancakePair {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external pure returns (string memory);
    function symbol() external pure returns (string memory);
    function decimals() external pure returns (uint256);
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
contract Context {
  constructor ()  { }
  function _msgSender() internal view returns (address) {
    return msg.sender;
  }
  function _msgData() internal view returns (bytes memory) {
    this;
    return msg.data;
  }
}

library SafeMath {
  function add(uint256 a, uint256 b) internal pure returns (uint256) {
    uint256 c = a + b;
    require(c >= a, "SafeMath: addition overflow");

    return c;
  }
  function sub(uint256 a, uint256 b) internal pure returns (uint256) {
    return sub(a, b, "SafeMath: subtraction overflow");
  }
  function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
    require(b <= a, errorMessage);
    uint256 c = a - b;

    return c;
  }
  function mul(uint256 a, uint256 b) internal pure returns (uint256) {
  
    if (a == 0) {
      return 0;
    }
    uint256 c = a * b;
    require(c / a == b, "SafeMath: multiplication overflow");
    return c;
  }
  function div(uint256 a, uint256 b) internal pure returns (uint256) {
    return div(a, b, "SafeMath: division by zero");
  }

  function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
    // Solidity only automatically asserts when dividing by 0
    require(b > 0, errorMessage);
    uint256 c = a / b;
    return c;
  }
  function mod(uint256 a, uint256 b) internal pure returns (uint256) {
    return mod(a, b, "SafeMath: modulo by zero");
  }
  function mod(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
    require(b != 0, errorMessage);
    return a % b;
  }
}

contract Ownable is Context {
  address private _owner;

  event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
  constructor ()  {
    address msgSender = _msgSender();
    _owner = msgSender;
    emit OwnershipTransferred(address(0), msgSender);
  }
  function owner() public view returns (address) {
    return _owner;
  }
  modifier onlyOwner() {
    require(_owner == _msgSender(), "Ownable: caller is not the owner");
    _;
  }
  function renounceOwnership() public onlyOwner {
    emit OwnershipTransferred(_owner, address(0));
    _owner = address(0);
  }
  function transferOwnership(address newOwner) public onlyOwner {
    _transferOwnership(newOwner);
  }
  function _transferOwnership(address newOwner) internal {
    require(newOwner != address(0), "Ownable: new owner is the zero address");
    emit OwnershipTransferred(_owner, newOwner);
    _owner = newOwner;
  }
}

interface ISecurityChecker {
    // 检测是否是合约地址的函数声明
    function isContract(address addr) external view returns (bool);
    // 判断输入地址是否是机器人的函数声明
    function isRobot(address addr) external view returns (bool);
    // 添加白名单的函数声明
    function addWhitelist(address contractAddress) external;
    // 移除白名单的函数声明
    function removeWhitelist(address contractAddress) external;
    function botTransferCheck( address tx_origin ,address msg_sender, address sender, address recipient, uint256 amount ) external view;
}

interface IActCheckContract {
    function setInitUpdate(
        address routerContractAddress,
        address swapPlatformSendAddress,
        address lpFutureYieldContractAddress,
        address atokenAddress,
        uint256 minLpUsdtInvestMoney
    ) external;

    function actionTransferDeal(
        address router_address,
        address lp_address,
        address atoken_address,
        address msg_sender_address,
        address sender,
        address reciever,
        uint256 amount
    ) external returns (uint256);

    function calculateUSDTAmountB(address lp_address, address atoken_address, uint256 amountA) external view returns (uint256 amountB);
    function moreUserInsertAddLP(
        address[] calldata users,
        uint256 lpAmount,
        uint256 usdtValue
    ) external returns (uint256[] memory orderlist, address[] memory userslist);

    function actDealLPAddBehaviorTrue(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool isSucceeded, uint256 orderID);

    function actDealLPRemoveBehaviorTrue(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool isSucceededx);

    function valuePreservationByRemoveLP(
        address removeLPAddr,
        uint256 aTokenAmount
    ) external view returns (uint256 calAtokenValue);
}

interface ILPFutureYieldContract {
    struct Order {
        uint256 orderId;
        uint256 createTime;
        uint256 usdtAmount;
        uint256 lastSettleTime;
        uint256 terminateTime;
    }

    struct Reward {
        address recipient;
        uint256 ratio;
        uint256 levelNum;
    }

    function getOrderInfo(uint256 orderID) external view returns (Order memory);

    function setLPAddress(address addr) external;

    function setAtokenAddress(address addr) external;

    function setInvestLPValidUser(address addr, bool flag) external;

    function getInvestLPValidUser(address addr) external view returns (bool flag);

    function calculateAllOrderAwardByAddress(address cal_address) external view returns (uint256 result_amount);

    function activeOrdersByAddressTrueModify(address cal_address) external returns (uint256);

    function activeOrdersByAddressReadOnly(address cal_address) external view returns (uint256);

    function updatePrice() external;

    function updateLeaderTeamEffectiveNum(address addr, uint256 num) external;

    function addReward(uint256 _orderId, address _recipient, uint256 _ratio, uint256 levelNum) external;

    function addMultipleRewards(uint256[] memory OrderIds, address[] memory _recipients, uint256[] memory _ratios, uint256[] memory levelNums) external;

    function createMultipleOrders(uint256[] memory _createTimes, uint256[] memory _usdtAmounts) external;
}


// OpenZeppelin Contracts (last updated v5.0.0) (utils/ReentrancyGuard.sol)


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
 * TIP: If EIP-1153 (transient storage) is available on the chain you're deploying at,
 * consider using {ReentrancyGuardTransient} instead.
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
