pragma solidity ^0.8.0;

import '@uniswap/lib/contracts/libraries/TransferHelper.sol';

import './Interfaces/IRouter.sol';
import '../Oracle/PIDController.sol';
import '../XSD/XSDStablecoin.sol';
import '../XSD/Pools/RewardManager.sol';
import './BankXLibrary.sol';
import '../Utils/Initializable.sol';
import '../BEP20/IWBNB.sol';
import '../XSD/Pools/XSDWETHpool.sol';
import '../XSD/Pools/BankXWETHpool.sol';
//swap first
//then burn 10% using different function maybe
//recalculate price
// do not burn uXSD if there is a deficit
contract Router is IRouter, Initializable {

    address public WETH;
    address public collateral_pool_address;
    address public XSDWETH_pool_address;
    address public BankXWETH_pool_address;
    address public reward_manager_address;
    address public arbitrage;
    address public bankx_address;
    address public xsd_address;
    address public treasury;
    address public smartcontract_owner;
    uint public last_called;
    uint public pid_cooldown;
    bool public swap_paused;
    bool public liquidity_paused;
    XSDStablecoin private XSD;
    RewardManager private reward_manager;
    PIDController private pid_controller;
    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, 'BankXRouter: EXPIRED');
        _;
    }

     // called once by the smart contract owner at time of deployment
     // sets the pool&token addresses
    function initialize(address _bankx_address, address _xsd_address,address _XSDWETH_pool, address _BankXWETH_pool,address _collateral_pool,address _reward_manager_address,address _pid_address,uint _pid_cooldown,address _treasury, address _smartcontract_owner,address _WETH) public initializer {
        require((_bankx_address != address(0))
        &&(_xsd_address != address(0))
        &&(_XSDWETH_pool != address(0))
        &&(_BankXWETH_pool != address(0))
        &&(_collateral_pool != address(0))
        &&(_treasury != address(0))
        &&(_pid_address != address(0))
        &&(_pid_cooldown != 0)
        &&(_smartcontract_owner != address(0))
        &&(_WETH != address(0)), "Zero address detected");
        bankx_address = _bankx_address;
        xsd_address = _xsd_address;
        XSDWETH_pool_address = _XSDWETH_pool;
        BankXWETH_pool_address = _BankXWETH_pool;
        collateral_pool_address = _collateral_pool;
        reward_manager_address = _reward_manager_address;
        reward_manager = RewardManager(_reward_manager_address);
        pid_controller = PIDController(_pid_address);
        pid_cooldown = _pid_cooldown;
        XSD = XSDStablecoin(_xsd_address);
        treasury = _treasury;
        WETH = _WETH;
        smartcontract_owner = _smartcontract_owner;
    }

    receive() external payable {
        assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
    }
    // add a variable that keeps track of 10% swap burn.
    // **** ADD LIQUIDITY ****
    //creator may add XSD/BankX to their respective pools via this function
    function creatorProvideLiquidity(address pool) internal  {
        if(pool == XSDWETH_pool_address){
            reward_manager.creatorProvideXSDLiquidity();
        }
        else if(pool == BankXWETH_pool_address){
            reward_manager.creatorProvideBankXLiquidity();
        }
    }

    function userProvideLiquidity(address pool, address sender) internal  {
        if(pool == XSDWETH_pool_address){
            reward_manager.userProvideXSDLiquidity(sender);
        }
        else if(pool == BankXWETH_pool_address){
            reward_manager.userProvideBankXLiquidity(sender);
        }
    }

    function refreshPID() internal{
        if(block.timestamp>(last_called+pid_cooldown)){
            pid_controller.systemCalculations();
            last_called = block.timestamp;
        }
    }

    function creatorAddLiquidityTokens(
        address tokenB,
        uint amountB
    ) public override {
        require(msg.sender == treasury || msg.sender == smartcontract_owner, "ONLY TREASURY & SMARTCONTRACT OWNER");
        require(tokenB == xsd_address || tokenB == bankx_address, "token address is invalid");
        require(amountB>0, "Please enter a valid amount");
        if(tokenB == xsd_address){
            TransferHelper.safeTransferFrom(tokenB, msg.sender, XSDWETH_pool_address, amountB);
            reward_manager.creatorProvideXSDLiquidity();
    }
    else if(tokenB == bankx_address){
        TransferHelper.safeTransferFrom(tokenB, msg.sender, BankXWETH_pool_address, amountB);
        reward_manager.creatorProvideBankXLiquidity();
    }
    }

    function creatorAddLiquidityETH(
        address pool
    ) external payable override {
        require(msg.sender == treasury || msg.sender == smartcontract_owner, "ONLY TREASURY & SMARTCONTRACT OWNER");
        require(pool == XSDWETH_pool_address || pool == BankXWETH_pool_address, "Pool address is invalid");
        require(msg.value>0,"Please enter a valid amount");
        IWBNB(WETH).deposit{value: msg.value}();
        assert(IWBNB(WETH).transfer(pool, msg.value));
        creatorProvideLiquidity(pool);
    }

    function userAddLiquidityETH(
        address pool
    ) external  payable override{
        require(pool == XSDWETH_pool_address || pool == BankXWETH_pool_address || pool == collateral_pool_address, "Pool address is not valid");
        require(!liquidity_paused, "Liquidity providing has been paused");
        IWBNB(WETH).deposit{value: msg.value}();
        assert(IWBNB(WETH).transfer(pool, msg.value));
        if(pool==collateral_pool_address){
            reward_manager.userProvideCollatPoolLiquidity(msg.sender, msg.value);
        }
        else{
            userProvideLiquidity(pool, msg.sender);
        }
    }

    //this redemption only applies to the liquidity pools
    //collateral pool redemption happens in the same contract
    function userRedeemLiquidity(address pool) external override {
        if(pool == XSDWETH_pool_address){
            reward_manager.LiquidityRedemption(pool,msg.sender);
        }
        else if(pool == BankXWETH_pool_address){
            reward_manager.LiquidityRedemption(pool,msg.sender);
        }
        else if (pool == collateral_pool_address){
            reward_manager.LiquidityRedemption(pool,msg.sender);
        }
    }

    // **** SWAP ****
    /* 
    10% of swap amount is burnt after swapping
    swap amount can only burnt from the liquidity pools
    */
    // PID controller is called every hour to update calculations.
    function swapETHForXSD(uint amountOut)
        external
        payable
        override
    {
        require(!swap_paused, "Swaps have been paused");
        (uint reserveA, uint reserveB, ) = IXSDWETHpool(XSDWETH_pool_address).getReserves();
        uint amounts = BankXLibrary.quote(msg.value, reserveB, reserveA);
        require(amounts >= amountOut, 'BankXRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        IWBNB(WETH).deposit{value: msg.value}();
        assert(IWBNB(WETH).transfer(XSDWETH_pool_address, msg.value));
        IXSDWETHpool(XSDWETH_pool_address).swap(amountOut, 0, msg.sender);
        refreshPID();
    }
    //approve router to use users xsd
    //burn 10% of XSD when uXSD is +ve
    function swapXSDForETH(uint amountOut, uint amountInMax)
        external
        override
    {
        require(!swap_paused, "Swaps have been paused");
        (uint reserveA, uint reserveB, ) = IXSDWETHpool(XSDWETH_pool_address).getReserves();
        uint amounts = BankXLibrary.quote(amountOut, reserveB, reserveA);
        require(amounts <= amountInMax, 'BankXRouter: EXCESSIVE_INPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            xsd_address, msg.sender, XSDWETH_pool_address, amountInMax
        );
        XSDWETHpool(XSDWETH_pool_address).swap(0, amountOut, address(this));
        //function will fail if conditions are not met
        //XSDWETHpool(XSDWETH_pool_address).flush();
        IWBNB(WETH).withdraw(amountOut);
        TransferHelper.safeTransferETH(msg.sender, amountOut);
        //burn xsd here 
        //value of xsd liquidity pool has to be greater than 20% of the total xsd value
        if(XSD.totalSupply()-CollateralPool(payable(collateral_pool_address)).collat_XSD()>amountOut/10 && !pid_controller.bucket1()){
            XSD.burnpoolXSD(amountInMax/10);
        }
        refreshPID();
    }

    function swapETHForBankX(uint amountOut)
        external
        override
        payable
    {
        require(!swap_paused, "Swaps have been paused");
        (uint reserveA, uint reserveB, ) = IBankXWETHpool(BankXWETH_pool_address).getReserves();
        uint amounts = BankXLibrary.quote(msg.value, reserveB, reserveA);
        require(amounts >= amountOut, 'BankXRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        IWBNB(WETH).deposit{value: msg.value}();
        assert(IWBNB(WETH).transfer(BankXWETH_pool_address, msg.value));
        IBankXWETHpool(BankXWETH_pool_address).swap(amountOut, 0, msg.sender);
        refreshPID();
    }
    //approve the router to access users bankx
    //if bankx is inflationary burn 10% of tokens swapped into pool
    function swapBankXForETH(uint amountOut, uint amountInMax)
        external
        override
    {
        require(!swap_paused, "Swaps have been paused");
        (uint reserveA, uint reserveB, ) = IBankXWETHpool(BankXWETH_pool_address).getReserves();
        uint amounts = BankXLibrary.quote(amountOut, reserveB, reserveA);
        require(amounts <= amountInMax, 'BankXRouter: EXCESSIVE_INPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            bankx_address, msg.sender, BankXWETH_pool_address, amountInMax
        );
        IBankXWETHpool(BankXWETH_pool_address).swap(0,amountOut, address(this));
        IWBNB(WETH).withdraw(amountOut);
        TransferHelper.safeTransferETH(msg.sender, amountOut);
        if((BankXToken(bankx_address).totalSupply() - amountOut/10)>BankXToken(bankx_address).genesis_supply()){
            BankXToken(bankx_address).burnpoolBankX(amountOut/10);
        }
        refreshPID();
    }

    //swap for xsd for eth first
    //swap eth for bankx
    // release bankx to user
    function swapXSDForBankX(uint XSD_amount,address sender,uint256 slippage)
        external 
        override
    {   //only msg.sender or arbitrage contract
        require(!swap_paused, "Swaps have been paused");
        require(msg.sender == sender || msg.sender == arbitrage, "Router:UNVERIFIED ADDRESS");
        (uint reserveA, uint reserveB, ) = IXSDWETHpool(XSDWETH_pool_address).getReserves();
        (uint reserve1, uint reserve2, ) = IBankXWETHpool(BankXWETH_pool_address).getReserves();
        uint ethamount = BankXLibrary.quote(XSD_amount, reserveA, reserveB);
        ethamount = ethamount - ((ethamount*slippage)/100);
        uint bankxamount = BankXLibrary.quote(ethamount, reserve2, reserve1);
        bankxamount = bankxamount - ((bankxamount*slippage)/100);
        TransferHelper.safeTransferFrom(
            xsd_address, sender, XSDWETH_pool_address, XSD_amount
        );
        IXSDWETHpool(XSDWETH_pool_address).swap(0, ethamount, BankXWETH_pool_address);
        IBankXWETHpool(BankXWETH_pool_address).swap(bankxamount,0,sender);
    }

    //swap bankx for eth 
    //swap eth for xsd
    //release xsd to user
    function swapBankXForXSD(uint bankx_amount, address sender, uint256 slippage)
        external
        override
    {   // only msg.sender or arbitrage contract
        require(!swap_paused, "Swaps have been paused");
        require(msg.sender == sender || msg.sender == arbitrage, "Router:UNVERIFIED ADDRESS");
        (uint reserveA, uint reserveB, ) = IXSDWETHpool(XSDWETH_pool_address).getReserves();
        (uint reserve1, uint reserve2, ) = IBankXWETHpool(BankXWETH_pool_address).getReserves();
        uint ethamount = BankXLibrary.quote(bankx_amount, reserve1, reserve2);
        ethamount = ethamount - ((ethamount*slippage)/100);
        uint xsdamount = BankXLibrary.quote(ethamount, reserveB, reserveA);
        xsdamount = xsdamount - ((xsdamount*slippage)/100);
        TransferHelper.safeTransferFrom(
            bankx_address, sender, BankXWETH_pool_address, bankx_amount
        );
        IBankXWETHpool(BankXWETH_pool_address).swap(0, ethamount, XSDWETH_pool_address);
        IXSDWETHpool(XSDWETH_pool_address).swap(xsdamount,0,sender);
    }
    function setSmartContractOwner(address _smartcontract_owner) external{
        require(msg.sender == smartcontract_owner, "Only the smart contract owner can access this function");
        require(msg.sender != address(0), "Zero address detected");
        smartcontract_owner = _smartcontract_owner;
    }

    function renounceOwnership() external{
        require(msg.sender == smartcontract_owner, "Only the smart contract owner can access this function");
        smartcontract_owner = address(0);
    }

    //Need to setter function for PID cooldown
    
    // **** LIBRARY FUNCTIONS ****
    function quote(uint amountA, uint reserveA, uint reserveB) public pure  returns (uint amountB) {
        return BankXLibrary.quote(amountA, reserveA, reserveB);
    }

    function pauseSwaps() external {
        require(msg.sender == smartcontract_owner, "Only the smart contract owner can access this function");
        swap_paused = !swap_paused;
    }

    function pauseLiquidity() external {
        require(msg.sender == smartcontract_owner, "Only the smart contract owner can access this function");
        liquidity_paused = !liquidity_paused;
    }
    
    
    function setBankXAddress(address _bankx_address) external{
        require(msg.sender == smartcontract_owner, "Only the smart contract owner can access this function");
        bankx_address = _bankx_address;
    }

    function setXSDAddress(address _xsd_address) external{
        require(msg.sender == smartcontract_owner, "Only the smart contract owner can access this function");
        xsd_address = _xsd_address;
    }

    function setXSDPoolAddress(address _XSDWETH_pool) external{
        require(msg.sender == smartcontract_owner, "Only the smart contract owner can access this function");
        XSDWETH_pool_address = _XSDWETH_pool;
    }

    function setBankXPoolAddress(address _BankXWETH_pool) external{
        require(msg.sender == smartcontract_owner, "Only the smart contract owner can access this function");
        BankXWETH_pool_address = _BankXWETH_pool;
    }

    function setCollateralPool(address _collateral_pool) external{
        require(msg.sender == smartcontract_owner, "Only the smart contract owner can access this function");
        collateral_pool_address = _collateral_pool;
    }

    function setRewardManager(address _reward_manager_address) external{
        require(msg.sender == smartcontract_owner, "Only the smart contract owner can access this function");
        reward_manager_address = _reward_manager_address;
        reward_manager = RewardManager(_reward_manager_address);
    }

    function setPIDController(address _pid_address, uint _pid_cooldown) external{
        require(msg.sender == smartcontract_owner, "Only the smart contract owner can access this function");
        pid_controller = PIDController(_pid_address);
        pid_cooldown = _pid_cooldown;
    }

    function setArbitrageAddress(address _arbitrage) external{
        require(msg.sender == smartcontract_owner, "Only the smart contract owner can access this function");
        arbitrage = _arbitrage;
    }
}
pragma solidity ^0.8.0;


//must create interface for it
import '../XSDStablecoin.sol';
import '../../BankX/BankXToken.sol';
import '@openzeppelin/contracts/utils/math/Math.sol';
import '../../Utils/Initializable.sol';
import '../../Utils/UQ112x112.sol';
import '../../Oracle/Interfaces/IPIDController.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import './Interfaces/IBankXWETHpool.sol';

contract BankXWETHpool is IBankXWETHpool, Initializable, ReentrancyGuard{
    using UQ112x112 for uint224;

    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));
    bytes32 public constant override PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    mapping(address => uint) public override nonces;
    uint256 private constant PRICE_PRECISION = 1e6;
    address private bankxaddress;
    address private WETHaddress;
    address public smartcontract_owner;

    uint public bankxamount;

    IPIDController pid_controller;
    XSDStablecoin private XSD;
    BankXToken private BankX;

    uint112 private reserve0;           // uses single storage slot, accessible via getReserves
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves
    
    uint public override price0CumulativeLast;
    uint public override price1CumulativeLast;
    uint public override kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event
    uint public reserve0_residue;
    uint public reserve1_residue;

    function getReserves() public override view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'BANKXWETH: TRANSFER_FAILED');
    }

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
    constructor(address _smartcontract_owner, uint _reserve0_residue, uint _reserve1_residue){
        require(_smartcontract_owner != address(0), "Zero address detected");
        smartcontract_owner = _smartcontract_owner;
        reserve0_residue = _reserve0_residue;
        reserve1_residue = _reserve1_residue;
    }
    // called once by the smart contract owner at time of deployment
    function initialize(address _token0, address _token1, address _xsd_contract_address, address _pid_address) public initializer {
        require(msg.sender == smartcontract_owner, 'BankX/WETH: FORBIDDEN'); // sufficient check
        require((_token0 != address(0))
        &&(_token1 != address(0))
        &&(_xsd_contract_address != address(0))
        &&(_pid_address != address(0)), "Zero address detected");
        bankxaddress = _token0;
        BankX = BankXToken(bankxaddress);
        XSD = XSDStablecoin(_xsd_contract_address);
        WETHaddress = _token1;
        pid_controller = IPIDController(_pid_address);
    }

    // update reserves and, on the first call per block, price accumulators
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) internal {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, 'BANKXWETH: OVERFLOW');
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    // Returns dollar value of collateral held in this XSD pool
    function collatDollarBalance() public view override returns (uint256) {
            return ((IERC20(WETHaddress).balanceOf(address(this))*XSD.eth_usd_price())/PRICE_PRECISION);   
    }
    
    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint amount0Out, uint amount1Out, address to) external override nonReentrant{
        require(amount0Out > 0 || amount1Out > 0, 'BankXWETH: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        _reserve0 = uint112(_reserve0);
        _reserve1 = uint112(_reserve1);
        require(amount0Out < (_reserve0-(reserve0_residue)) && amount1Out < (_reserve1-(reserve1_residue)), 'BankXWETH: INSUFFICIENT_LIQUIDITY');
        // burn 10% of bankx after checking inflation and tvl.
        // send transaction every trade.
        uint balance0;
        uint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors
        address _token0 = bankxaddress;
        address _token1 = WETHaddress;
        require(to != _token0 && to != _token1, 'BankXWETH: INVALID_TO');
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        }
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'BankXWETH: INSUFFICIENT_INPUT_AMOUNT');
        require((balance0*balance1) >= uint(_reserve0)*(_reserve1), 'BankXWETH: K');
        if(amount1Out != 0) bankxamount = amount0In;
        _update(balance0, balance1,_reserve0,_reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    function skim(address to) external override nonReentrant {
        address _token0 = bankxaddress; // gas savings
        address _token1 = WETHaddress; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this))-(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this))-(reserve1));
    }

    // force reserves to match balances
    function sync() external override nonReentrant {
        _update(IERC20(bankxaddress).balanceOf(address(this)), IERC20(WETHaddress).balanceOf(address(this)), reserve0, reserve1);
        kLast = uint(reserve0)*(reserve1);
    }

    function setSmartContractOwner(address _smartcontract_owner) external{
        require(msg.sender == smartcontract_owner, "Only the smart contract owner can access this function");
        require(msg.sender != address(0), "Zero address detected");
        smartcontract_owner = _smartcontract_owner;
    }

    function renounceOwnership() external{
        require(msg.sender == smartcontract_owner, "Only the smart contract owner can access this function");
        smartcontract_owner = address(0);
    }

    function resetAddresses(address _token0, address _token1, address _xsd_contract_address, address _pid_address,uint _reserve0_residue, uint _reserve1_residue ) external{
        require(msg.sender == smartcontract_owner, 'BankX/WETH: FORBIDDEN'); // sufficient check
        require((_token0 != address(0))
        &&(_token1 != address(0))
        &&(_xsd_contract_address != address(0))
        &&(_pid_address != address(0)), "Zero address detected");
        bankxaddress = _token0;
        BankX = BankXToken(bankxaddress);
        XSD = XSDStablecoin(_xsd_contract_address);
        WETHaddress = _token1;
        pid_controller = IPIDController(_pid_address);
        reserve0_residue = _reserve0_residue;
        reserve1_residue = _reserve1_residue;
    }

    /* ========== EVENTS ========== */
    event ProvideLiquidity(address sender, uint amount0, uint amount1);
    event ProvideLiquidity2(address sender, uint amount1);

}
pragma solidity ^0.8.0;

import '@openzeppelin/contracts/utils/math/Math.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '../../Utils/Initializable.sol';
import '../../Utils/UQ112x112.sol';
import '../../Oracle/Interfaces/IPIDController.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '../XSDStablecoin.sol';
import '../../BankX/BankXToken.sol';
import './Interfaces/IXSDWETHpool.sol';

contract XSDWETHpool is IXSDWETHpool, Initializable, ReentrancyGuard{
    using UQ112x112 for uint224;

    //add a variable for tracking 10 percentage of burned tokens
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));
    bytes32 public constant override PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    mapping(address => uint) public override nonces;
    uint256 private constant PRICE_PRECISION = 1e6;
    address private XSDaddress;
    address private WETHaddress;
    address public smartcontract_owner;
    //keeps track of amount that needs to be burnt
    uint public xsdamount;

    IPIDController pid_controller;
    XSDStablecoin private XSD;
    BankXToken private BankX;

    uint112 private reserve0;           // uses single storage slot, accessible via getReserves
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves
    
    uint public override price0CumulativeLast;
    uint public override price1CumulativeLast;
    uint public override kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity even

    uint public reserve0_residue;
    uint public reserve1_residue;

    function getReserves() public override view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'XSDWETH: TRANSFER_FAILED');
    }


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
    constructor(address _smartcontract_owner, uint _reserve0_residue, uint _reserve1_residue){
        require(_smartcontract_owner != address(0), "Zero address detected");
        smartcontract_owner = _smartcontract_owner;
        reserve0_residue = _reserve0_residue;
        reserve1_residue = _reserve1_residue;
    }
    // called once by the smartcontract_address at time of deployment
    function initialize(address _token0, address _token1, address _bankx_contract_address, address _pid_address, address _collateral_pool_address) public initializer {
        require(msg.sender == smartcontract_owner, 'XSD/WETH: FORBIDDEN'); // sufficient check
        require((_token0 != address(0))
        &&(_token1 != address(0))
        &&(_bankx_contract_address != address(0))
        &&(_pid_address != address(0))
        &&(_collateral_pool_address != address(0)), "Zero address detected");
        XSDaddress = _token0;
        XSD = XSDStablecoin(XSDaddress);
        BankX = BankXToken(_bankx_contract_address);
        WETHaddress = _token1;
        pid_controller = IPIDController(_pid_address);
    }

    // update reserves and, on the first call per block, price accumulators
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, 'XSDWETH: OVERFLOW');
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    // Returns dollar value of collateral held in this XSD pool
    function collatDollarBalance() public view override returns (uint256) {
            return ((IERC20(WETHaddress).balanceOf(address(this))*(XSD.eth_usd_price()))/(PRICE_PRECISION));     
    }

    // this low-level function should be called from a contract which performs important safety checks
    //swap values changed for testing on goerli
    //if uXSD is +ve then burn 10% of all XSD swapped
    function swap(uint amount0Out, uint amount1Out, address to) external override nonReentrant {
        require(amount0Out > 0 || amount1Out > 0, 'XSDWETH: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        _reserve0 = uint112(_reserve0);
        _reserve1 = uint112(_reserve1);
        require(amount0Out < (_reserve0-reserve0_residue) && amount1Out < (_reserve1-reserve1_residue), 'XSDWETH: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors
        address _token0 = XSDaddress;
        address _token1 = WETHaddress;
        require(to != _token0 && to != _token1, 'XSDWETH: INVALID_TO');
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        }
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'XSDWETH: INSUFFICIENT_INPUT_AMOUNT');
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
        uint balance0Adjusted = balance0;
        uint balance1Adjusted = balance1;
        require(balance0Adjusted*(balance1Adjusted) >= uint(_reserve0)*(_reserve1), 'XSDWETH: K');
        }
        if(amount1Out != 0) xsdamount = amount0In;
        _update(balance0, balance1,_reserve0,_reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    function skim(address to) external override nonReentrant {
        address _token0 = XSDaddress; // gas savings
        address _token1 = WETHaddress; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this))-(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this))-(reserve1));
    }

    // force reserves to match balances
    function sync() external override nonReentrant {
        _update(IERC20(XSDaddress).balanceOf(address(this)), IERC20(WETHaddress).balanceOf(address(this)), reserve0, reserve1);
        kLast = uint(reserve0)*(reserve1);
    }

    function setSmartContractOwner(address _smartcontract_owner) external{
        require(msg.sender == smartcontract_owner, "Only the smart contract owner can access this function");
        require(msg.sender != address(0), "Zero address detected");
        smartcontract_owner = _smartcontract_owner;
    }

    function renounceOwnership() external{
        require(msg.sender == smartcontract_owner, "Only the smart contract owner can access this function");
        smartcontract_owner = address(0);
    }

    function resetAddresses(address _token0, address _token1, address _bankx_contract_address, address _pid_address, address _collateral_pool_address) external{
        require(msg.sender == smartcontract_owner, 'XSD/WETH: FORBIDDEN'); // sufficient check
        require((_token0 != address(0))
        &&(_token1 != address(0))
        &&(_bankx_contract_address != address(0))
        &&(_pid_address != address(0))
        &&(_collateral_pool_address != address(0)), "Zero address detected");
        XSDaddress = _token0;
        XSD = XSDStablecoin(XSDaddress);
        BankX = BankXToken(_bankx_contract_address);
        WETHaddress = _token1;
        pid_controller = IPIDController(_pid_address);
    }
    /* ========== EVENTS ========== */
    event ProvideLiquidity(address sender, uint amount0, uint amount1);
    event ProvideLiquidity2(address sender, uint amount1);
    

}
pragma solidity ^0.8.0;

interface IWBNB {
    function deposit() external payable;
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address src, address dst, uint wad) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function withdraw(uint) external;
}
pragma solidity >=0.4.24;


/**
 * @title Initializable
 *
 * @dev Helper contract to support initializer functions. To use it, replace
 * the constructor with a function that has the `initializer` modifier.
 * WARNING: Unlike constructors, initializer functions must be manually
 * invoked. This applies both to deploying an Initializable contract, as well
 * as extending an Initializable contract via inheritance.
 * WARNING: When used with inheritance, manual care must be taken to not invoke
 * a parent initializer twice, or ensure that all initializers are idempotent,
 * because this is not dealt with automatically as with constructors.
 */
contract Initializable {

  /**
   * @dev Indicates that the contract has been initialized.
   */
  bool private initialized;

  /**
   * @dev Indicates that the contract is in the process of being initialized.
   */
  bool private initializing;

  /**
   * @dev Modifier to use in the initializer function of a contract.
   */
  modifier initializer() {
    require(initializing || isConstructor() || !initialized, "Contract instance has already been initialized");

    bool isTopLevelCall = !initializing;
    if (isTopLevelCall) {
      initializing = true;
      initialized = true;
    }

    _;

    if (isTopLevelCall) {
      initializing = false;
    }
  }

  /// @dev Returns true if and only if the function is running in the constructor
  function isConstructor() private view returns (bool) {
    // extcodesize checks the size of the code stored in an address, and
    // address returns the current address. Since the code is still not
    // deployed when running a constructor, any checks on its code size will
    // yield zero, making it an effective way to detect if a contract is
    // under construction or not.
    address self = address(this);
    uint256 cs;
    assembly { cs := extcodesize(self) }
    return cs == 0;
  }

  // Reserved storage space to allow for layout changes in the future.
  uint256[50] private ______gap;
}
pragma solidity ^0.8.0;


library BankXLibrary {

    // given some amount of an asset and pair reserves, returns an equivalent amount of the other asset
    function quote(uint amountA, uint reserveA, uint reserveB) internal pure returns (uint amountB) {
        require(amountA > 0, 'BankXLibrary: INSUFFICIENT_AMOUNT');
        require(reserveA > 0 && reserveB > 0, 'BankXLibrary: INSUFFICIENT_LIQUIDITY');
        amountB = (amountA*reserveB) / reserveA;
    }
}
pragma solidity ^0.8.0;
import '../../Utils/Initializable.sol';
import './Interfaces/IBankXWETHpool.sol';
import './Interfaces/IXSDWETHpool.sol';
import "../XSDStablecoin.sol";
import "../../BankX/BankXToken.sol";
import "./Interfaces/IRewardManager.sol";
import '../../Oracle/Interfaces/IPIDController.sol';
//manages rewards and crossovers for liquidity and collateral pools

contract RewardManager is IRewardManager,ReentrancyGuard,Initializable{
    address public smartcontract_owner;
    address public bankx_pool_address;
    address public xsd_pool_address;
    address public collat_pool_address;
    address public xsd_address;
    address public bankx_address;
    address public weth_address;
    IPIDController pid_controller;
    XSDStablecoin private XSD;
    BankXToken private BankX;
    IBankXWETHpool private bankxwethpool;
    IXSDWETHpool private xsdwethpool;
    uint public vesting1;
    uint public vesting2;
    uint public vesting3;
    struct Liquidity_Provider{
        uint vestingtimestamp;
        uint ethvalue;
        uint xsdrewards;
        uint bankxrewards;
    }
    mapping(address => mapping(address => mapping(uint => Liquidity_Provider))) public liquidity_provider;
    constructor(
        address _smartcontract_owner, 
        address _weth_address
    ){
        require((_smartcontract_owner != address(0))
        &&(_weth_address != address(0)),"Zero address detected");
        smartcontract_owner = _smartcontract_owner;
        weth_address = _weth_address;
    }
    // called once by the smart contract owner at time of deployment
    function initialize(address _bankx_address, address _xsd_address,address _xsd_pool_address,address _bankx_pool_address,address _collat_pool_address, address _pid_address,uint _vesting1,uint _vesting2,uint _vesting3) public initializer {
        require(msg.sender == smartcontract_owner, 'RewardManager: FORBIDDEN'); // sufficient check
        require((_bankx_address != address(0))
        &&(_xsd_address != address(0))
        &&(_xsd_pool_address != address(0))
        &&(_bankx_pool_address != address(0))
        &&(_pid_address != address(0)), "Zero address detected");
        bankx_address = _bankx_address;
        xsd_address = _xsd_address;
        bankx_pool_address = _bankx_pool_address;
        xsd_pool_address = _xsd_pool_address;
        collat_pool_address = _collat_pool_address;
        BankX = BankXToken(bankx_address);
        XSD = XSDStablecoin(_xsd_address);
        bankxwethpool = IBankXWETHpool(_bankx_pool_address);
        xsdwethpool = IXSDWETHpool(_xsd_pool_address);
        pid_controller = IPIDController(_pid_address);
        vesting1 = _vesting1;
        vesting2 = _vesting2;
        vesting3 = _vesting3;
    }

    function tier1(address pool,uint percent,address to,uint ethvalue,uint amountpaid,uint difference) private {
        uint actdiff = difference - amountpaid;
        if(ethvalue>actdiff){
           uint left_over = ethvalue - actdiff;
           liquidity_provider[pool][to][vesting1].ethvalue += actdiff;
           liquidity_provider[pool][to][vesting1].bankxrewards += actdiff + (actdiff*percent/100);
           liquidity_provider[pool][to][vesting1].xsdrewards += actdiff/20;
           liquidity_provider[bankx_pool_address][to][vesting2].vestingtimestamp = block.timestamp+vesting2;
           tier2(pool,percent,to,left_over,difference);
        }
        else{
            liquidity_provider[pool][to][vesting1].ethvalue += ethvalue;
            liquidity_provider[pool][to][vesting1].bankxrewards += ethvalue + (ethvalue*percent/100);
            liquidity_provider[pool][to][vesting1].xsdrewards += ethvalue/20;
        }
    }

    function tier2(address pool,uint percent,address to,uint ethvalue,uint difference) private {
        if(ethvalue>difference){
            uint left_over = ethvalue - difference;
            liquidity_provider[pool][to][vesting2].ethvalue += difference;
            liquidity_provider[pool][to][vesting2].bankxrewards += difference + (difference*percent/100);
            liquidity_provider[pool][to][vesting2].xsdrewards += difference/50;
            liquidity_provider[pool][to][vesting3].ethvalue += left_over;
            liquidity_provider[pool][to][vesting3].bankxrewards += left_over + (left_over*percent/100);
            liquidity_provider[bankx_pool_address][to][vesting3].vestingtimestamp = block.timestamp + vesting3;
            }
        else{
            liquidity_provider[pool][to][vesting2].ethvalue += ethvalue;
            liquidity_provider[pool][to][vesting2].bankxrewards += ethvalue + (ethvalue*percent/100);
            liquidity_provider[pool][to][vesting2].xsdrewards += ethvalue/50;
        }
    }
//When the creator adds liquidity during a deficit period it must be added to the amount paid variables
    function creatorProvideBankXLiquidity() external override nonReentrant{
        (uint112 _reserve0, uint112 _reserve1,) = bankxwethpool.getReserves(); // gas savings
        uint balance0 = IERC20(bankx_address).balanceOf(bankx_pool_address);
        uint balance1 = IERC20(weth_address).balanceOf(bankx_pool_address);
        uint amount0 = balance0-(_reserve0);
        uint amount1 = balance1-(_reserve1);
        if(pid_controller.bucket2()){
            uint ethvalue = ((amount0*XSD.bankx_price())+(amount1*XSD.eth_usd_price()))/(1e6);
            pid_controller.amountPaidBankXWETH(ethvalue);
        }
        bankxwethpool.sync();
        emit CreatorProvideBankXLiquidity(msg.sender, amount0, amount1);
    }

    function creatorProvideXSDLiquidity() external override nonReentrant{
        (uint112 _reserve0, uint112 _reserve1,) = xsdwethpool.getReserves();
        uint balance0 = IERC20(xsd_address).balanceOf(xsd_pool_address);
        uint balance1 = IERC20(weth_address).balanceOf(xsd_pool_address);
        uint amount0 = balance0-(_reserve0);
        uint amount1 = balance1-(_reserve1);
        if(pid_controller.bucket1()){
            uint ethvalue = ((amount0*XSD.xsd_price())+(amount1*XSD.eth_usd_price()))/(1e6);
            pid_controller.amountPaidXSDWETH(ethvalue);
        }
        xsdwethpool.sync();
        emit CreatorProvideXSDLiquidity(msg.sender, amount0, amount1);
    }
    //principal is split among tiers as well
    function userProvideBankXLiquidity(address to) external override nonReentrant{
        require(pid_controller.bucket2(), "RewardManager:NO DEFICIT");
        (, uint112 _reserve1,) = bankxwethpool.getReserves(); // gas savings
        uint balance1 = IERC20(weth_address).balanceOf(bankx_pool_address);
        uint amount = balance1-_reserve1;
        uint ethvalue = (amount*(XSD.eth_usd_price()))/(1e6);
        uint bankxamount = ethvalue/XSD.bankx_price();
        uint amountpaid = pid_controller.amountpaid2();
        uint difference = pid_controller.diff2()/3;
        require((ethvalue+amountpaid)<(difference*3),"BankXLiquidity:DEFICIT LIMIT");
        if(amountpaid<difference){
            tier1(bankx_pool_address,8,to,ethvalue,amountpaid,difference);
            liquidity_provider[bankx_pool_address][to][vesting1].vestingtimestamp = block.timestamp+vesting1;
        }
        else if(amountpaid<(difference*(2))){
            tier2(bankx_pool_address,8,to,ethvalue,(2*difference)-amountpaid);
            liquidity_provider[bankx_pool_address][to][vesting2].vestingtimestamp = block.timestamp+vesting2;
        }
        else{
            liquidity_provider[bankx_pool_address][to][vesting3].ethvalue += ethvalue;
            liquidity_provider[bankx_pool_address][to][vesting3].bankxrewards += ethvalue + (ethvalue*9/100);
            liquidity_provider[bankx_pool_address][to][vesting3].vestingtimestamp = block.timestamp + vesting3;
        }
        BankX.pool_mint(bankx_pool_address, bankxamount);
        pid_controller.amountPaidBankXWETH(ethvalue);
        bankxwethpool.sync();
        emit UserProvideBankXLiquidity(to, amount);
    }

    function userProvideXSDLiquidity(address to) external override nonReentrant{
        require(pid_controller.bucket1(),"RewardManager:NO DEFICIT");
        (, uint112 _reserve1,) = xsdwethpool.getReserves(); // gas savings
        uint balance1 = IERC20(weth_address).balanceOf(xsd_pool_address);
        uint amount = balance1-_reserve1;
        uint ethvalue = (amount*(XSD.eth_usd_price()))/(1e6);
        uint xsdamount = ethvalue/XSD.xsd_price();
        uint amountpaid = pid_controller.amountpaid1();
        uint difference = pid_controller.diff1()/3;
        require((ethvalue+amountpaid)<(difference*3),"XSDLiquidity:DEFICIT LIMIT");
        if(amountpaid<difference){
            tier1(xsd_pool_address,9,to,ethvalue,amountpaid,difference);
            liquidity_provider[xsd_pool_address][to][vesting1].vestingtimestamp = block.timestamp+vesting1;
        }
        else if(amountpaid<(difference*(2))){
            tier2(xsd_pool_address,9,to,ethvalue,(2*difference)-amountpaid);
            liquidity_provider[xsd_pool_address][to][vesting2].vestingtimestamp = block.timestamp+vesting2;
        }
        else{
            liquidity_provider[xsd_pool_address][to][vesting3].ethvalue += ethvalue;
            liquidity_provider[xsd_pool_address][to][vesting3].bankxrewards += ethvalue + (ethvalue*9/100);
            liquidity_provider[xsd_pool_address][to][vesting3].vestingtimestamp = block.timestamp + vesting3;
        }
        XSD.pool_mint(xsd_pool_address, xsdamount);
        pid_controller.amountPaidXSDWETH(ethvalue);
        xsdwethpool.sync();
        emit UserProvideXSDLiquidity(to, amount);
    }

    function userProvideCollatPoolLiquidity(address to, uint amount) external override nonReentrant{
        require(pid_controller.bucket3(),"RewardManager:NO DEFICIT");
        uint ethvalue = (amount*XSD.eth_usd_price())/(1e6);
        uint difference = pid_controller.diff3()/3;
        uint amountpaid = pid_controller.amountpaid3();
        require((ethvalue+amountpaid)<(difference*3),"CollatPoolLiquidity:DEFICIT LIMIT");
        if(amountpaid<difference){
            tier1(collat_pool_address,7,to,ethvalue,amountpaid,difference);
            liquidity_provider[collat_pool_address][to][vesting1].vestingtimestamp = block.timestamp+vesting1;
        }
        else if(amountpaid<(difference*(2))){
            tier2(collat_pool_address,7,to,ethvalue,(2*difference)-amountpaid);
            liquidity_provider[collat_pool_address][to][vesting2].vestingtimestamp = block.timestamp+vesting2;
        }
        else{
            liquidity_provider[collat_pool_address][to][vesting3].ethvalue += ethvalue;
            liquidity_provider[collat_pool_address][to][vesting3].bankxrewards += ethvalue + (ethvalue*9/100);
            liquidity_provider[collat_pool_address][to][vesting3].vestingtimestamp = block.timestamp + vesting3;
        }
        pid_controller.amountPaidCollateralPool(ethvalue);
        emit UserProvideCollatLiquidity(to, amount);

    }

    function tier1Redemption(address pool,address to) private returns(uint bankxamount,uint xsdamount){
        require(liquidity_provider[pool][to][vesting1].bankxrewards != 0 || liquidity_provider[pool][to][vesting1].xsdrewards != 0, "Nothing to claim");
        bankxamount = ((liquidity_provider[pool][to][vesting1].bankxrewards)*(1e6))/(XSD.bankx_price());
        xsdamount = ((liquidity_provider[pool][to][vesting1].xsdrewards)*(1e6))/(XSD.xsd_price());
        liquidity_provider[pool][to][vesting1].bankxrewards = 0;
        liquidity_provider[pool][to][vesting1].xsdrewards = 0;
        liquidity_provider[pool][to][vesting1].ethvalue = 0;
        liquidity_provider[pool][to][vesting1].vestingtimestamp = 0;
    }
    function tier2Redemption(address pool,address to) private returns(uint bankxamount,uint xsdamount){
        require(liquidity_provider[pool][to][vesting2].bankxrewards != 0 || liquidity_provider[pool][to][vesting2].xsdrewards != 0, "Nothing to claim");
        bankxamount = ((liquidity_provider[pool][to][vesting2].bankxrewards)*(1e6))/(XSD.bankx_price());
        xsdamount = ((liquidity_provider[pool][to][vesting2].xsdrewards)*(1e6))/(XSD.xsd_price());
        liquidity_provider[pool][to][vesting2].bankxrewards = 0;
        liquidity_provider[pool][to][vesting2].xsdrewards = 0;
        liquidity_provider[pool][to][vesting2].ethvalue = 0;
        liquidity_provider[pool][to][vesting2].vestingtimestamp = 0;
    }
    function tier3Redemption(address pool,address to) private returns(uint bankxamount){
        require(liquidity_provider[pool][to][vesting3].bankxrewards != 0, "RewardManager:NO CLAIM");
        bankxamount = ((liquidity_provider[pool][to][vesting3].bankxrewards)*(1e6))/(XSD.bankx_price());
        liquidity_provider[pool][to][vesting3].bankxrewards = 0;
        liquidity_provider[pool][to][vesting3].ethvalue = 0;
        liquidity_provider[pool][to][vesting3].vestingtimestamp = 0;
    }

    function LiquidityRedemption(address pool,address to) external override nonReentrant{
        //find a better way to check which tier
        uint bankxamount;
        uint xsdamount;
        if((liquidity_provider[pool][to][vesting1].ethvalue != 0) && (liquidity_provider[pool][to][vesting1].vestingtimestamp<=block.timestamp)){
            (bankxamount,xsdamount) = tier1Redemption(pool,to);
        }
        if((liquidity_provider[pool][to][vesting2].ethvalue != 0) && (liquidity_provider[pool][to][vesting2].vestingtimestamp<=block.timestamp)){
            uint bankxamount2;
            uint xsdamount2;
            (bankxamount2,xsdamount2) = tier2Redemption(pool,to);
            bankxamount += bankxamount2;
            xsdamount += xsdamount2; 
        }
        if((liquidity_provider[pool][to][vesting3].ethvalue != 0) && (liquidity_provider[pool][to][vesting3].vestingtimestamp<=block.timestamp)){
            bankxamount += tier3Redemption(pool,to);
        }
        BankX.pool_mint(to, bankxamount);
        XSD.pool_mint(to, xsdamount);
        emit liquidityRedemption(to, bankxamount, xsdamount);
    }
    function setSmartContractOwner(address _smartcontract_owner) external{
        require(msg.sender == smartcontract_owner, "Only the smart contract owner can access this function");
        require(msg.sender != address(0), "Zero address detected");
        smartcontract_owner = _smartcontract_owner;
    }

    function renounceOwnership() external{
        require(msg.sender == smartcontract_owner, "Only the smart contract owner can access this function");
        smartcontract_owner = address(0);
    }

    function resetAddresses(address _bankx_address, address _xsd_address,address _xsd_pool_address,address _bankx_pool_address,address _collat_pool_address, address _pid_address,uint _vesting1,uint _vesting2,uint _vesting3) external{
        require(msg.sender == smartcontract_owner, 'RewardManager: FORBIDDEN'); // sufficient check
        require((_bankx_address != address(0))
        &&(_xsd_address != address(0))
        &&(_xsd_pool_address != address(0))
        &&(_bankx_pool_address != address(0))
        &&(_pid_address != address(0)), "Zero address detected");
        bankx_address = _bankx_address;
        xsd_address = _xsd_address;
        bankx_pool_address = _bankx_pool_address;
        xsd_pool_address = _xsd_pool_address;
        collat_pool_address = _collat_pool_address;
        BankX = BankXToken(bankx_address);
        XSD = XSDStablecoin(_xsd_address);
        bankxwethpool = IBankXWETHpool(_bankx_pool_address);
        xsdwethpool = IXSDWETHpool(_xsd_pool_address);
        pid_controller = IPIDController(_pid_address);
        vesting1 = _vesting1;
        vesting2 = _vesting2;
        vesting3 = _vesting3;
    }
    // ========== EVENTS ========== 
    event CreatorProvideBankXLiquidity(address sender, uint amount0, uint amount1);
    event CreatorProvideXSDLiquidity(address sender, uint amount0, uint amount1);
    event UserProvideBankXLiquidity(address sender, uint amount);
    event UserProvideXSDLiquidity(address sender, uint amount);
    event UserProvideCollatLiquidity(address sender, uint amount);
    event liquidityRedemption(address sender, uint bankxamount, uint xsdamount);
    
}
pragma solidity ^0.8.0;


import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../BEP20/BEP20Custom.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./Pools/CollateralPool.sol";
import "./Pools/Interfaces/IBankXWETHpool.sol";
import "./Pools/Interfaces/IXSDWETHpool.sol";
import "../Oracle/ChainlinkETHUSDPriceConsumer.sol";
import "../Oracle/ChainlinkXAGUSDPriceConsumer.sol";

contract XSDStablecoin is BEP20Custom {

     /* ========== STATE VARIABLES ========== */
    enum PriceChoice { XSD, BankX }
    ChainlinkETHUSDPriceConsumer private eth_usd_pricer;
    ChainlinkXAGUSDPriceConsumer private xag_usd_pricer;
    uint8 private eth_usd_pricer_decimals;
    uint8 private xag_usd_pricer_decimals;
    string public symbol;
    string public name;
    uint8 public constant decimals = 18;
    address public pid_address; // pid controller address
    address public treasury; //stores the genesis supply
    address public collateral_pool_address;
    address public router;
    address public eth_usd_oracle_address;
    address public xag_usd_oracle_address;
    address public smartcontract_owner;
    // interest rate related variables
    uint256 public interest_rate;
    IBankXWETHpool private bankxEthPool;
    IXSDWETHpool private xsdEthPool;
    uint256 public cap_rate;
    uint256 public genesis_supply; 

    // The addresses in this array are added by the oracle and these contracts are able to mint xsd
    address[] public xsd_pools_array;

    // Mapping is also used for faster verification
    mapping(address => bool) public xsd_pools; 

    // Constants for various precisions
    uint256 private constant PRICE_PRECISION = 1e6;
    
    uint256 public global_collateral_ratio; // 6 decimals of precision, e.g. 924102 = 0.924102
    uint256 public xsd_step; // Amount to change the collateralization ratio by upon refreshCollateralRatio()
    uint256 public refresh_cooldown; // Seconds to wait before being able to run refreshCollateralRatio() again
    uint256 public price_target; // The price of XSD at which the collateral ratio will respond to; this value is only used for the collateral ratio mechanism and not for minting and redeeming which are hardcoded at $1
    uint256 public price_band; // The bound above and below the price target at which the refreshCollateralRatio() will not change the collateral ratio

    bool public collateral_ratio_paused = false;

    /* ========== MODIFIERS ========== */

    modifier onlyPools() {
       require(xsd_pools[msg.sender] == true, "Only xsd pools can call this function");
        _;//check happens before the function is executed
    } 

    modifier onlyByOwner(){
        require(msg.sender == smartcontract_owner, "You are not the owner");
        _;
    }
    
    modifier onlyByOwnerPID() {
        require(msg.sender == smartcontract_owner || msg.sender == pid_address, "You are not the owner or the pid controller");
        _;
    }

    modifier onlyByOwnerOrPool() {
        require(
            msg.sender == smartcontract_owner  
            || xsd_pools[msg.sender] == true, 
            "You are not the owner or a pool");
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _pool_amount,
        uint256 _genesis_supply,
        address _smartcontract_owner,
        address _treasury,
        uint256 _cap_rate
    ) {
        require((_smartcontract_owner != address(0))
                && (_treasury != address(0)), "Zero address detected"); 
        name = _name;
        symbol = _symbol;
        genesis_supply = _genesis_supply + _pool_amount;
        treasury = _treasury;
        _mint(_smartcontract_owner, _pool_amount);
        _mint(treasury, _genesis_supply);
        smartcontract_owner = _smartcontract_owner;
        xsd_step = 2500; // 6 decimals of precision, equal to 0.25%
        global_collateral_ratio = 1000000; // XSD system starts off fully collateralized (6 decimals of precision)
        interest_rate = 52800; //interest rate starts off at 5%
        refresh_cooldown = 3600; // Refresh cooldown period is set to 1 hour (3600 seconds) at genesis
        price_target = 800000; // Change price target to 1 gram of silver
        price_band = 5000; // Collateral ratio will not adjust if 0.005 off target at genesis
        cap_rate = _cap_rate;// Maximum mint amount
    }
    //change price target to reflect true value of silver
    /* ========== VIEWS ========== */

    // Choice = 'XSD' or 'BankX' for now
    function pool_price(PriceChoice choice) internal view returns (uint256) {
        // Get the ETH / USD price first, and cut it down to 1e6 precision
        uint256 _eth_usd_price = (uint256(eth_usd_pricer.getLatestPrice())*PRICE_PRECISION)/(uint256(10) ** eth_usd_pricer_decimals);
        uint256 price_vs_eth = 0;
        uint256 reserve0;
        uint256 reserve1;

        if (choice == PriceChoice.XSD) {
            (reserve0, reserve1, ) = xsdEthPool.getReserves();
            if(reserve0 == 0 || reserve1 == 0){
                return 1;
            }
            price_vs_eth = reserve0/(reserve1); // How much XSD if you put in 1 WETH
        }
        else if (choice == PriceChoice.BankX) {
            (reserve0, reserve1, ) = bankxEthPool.getReserves();
            if(reserve0 == 0 || reserve1 == 0){
                return 1;
            }
            price_vs_eth = reserve0/(reserve1);  // How much BankX if you put in 1 WETH
        }
        else revert("INVALID PRICE CHOICE. Needs to be either 0 (XSD) or 1 (BankX)");

        // Will be in 1e6 format
        return _eth_usd_price/price_vs_eth;
    }

    // Returns X XSD = 1 USD
    //XSD price
    function xsd_price() public view returns (uint256) {
        return pool_price(PriceChoice.XSD);
    }

    // Returns X BankX = 1 USD
    function bankx_price()  public view returns (uint256) {
        return pool_price(PriceChoice.BankX);
    }

    function eth_usd_price() public view returns (uint256) {
        return (uint256(eth_usd_pricer.getLatestPrice())*PRICE_PRECISION)/(uint256(10) ** eth_usd_pricer_decimals);
    }
    //silver price
    //hard coded value for testing on goerli
    function xag_usd_price() public view returns (uint256) {
        return (uint256(xag_usd_pricer.getLatestPrice())*PRICE_PRECISION)/(uint256(10) ** xag_usd_pricer_decimals);
    }

    
    // This is needed to avoid costly repeat calls to different getter functions
    // It is cheaper gas-wise to just dump everything and only use some of the info
    function xsd_info() public view returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        return (
            pool_price(PriceChoice.XSD), // xsd_price()
            pool_price(PriceChoice.BankX), // bankx_price()
            totalSupply(), // totalSupply()
            global_collateral_ratio, // global_collateral_ratio()
            globalCollateralValue(), // globalCollateralValue
            (uint256(eth_usd_pricer.getLatestPrice())*PRICE_PRECISION)/(uint256(10) ** eth_usd_pricer_decimals) //eth_usd_price
        );
    }

    // Iterate through all xsd pools and calculate all value of collateral in all pools globally 
    function globalCollateralValue() public view returns (uint256) {
        uint256 collateral_amount = 0;
        collateral_amount = CollateralPool(payable(collateral_pool_address)).collatDollarBalance();
        return collateral_amount;
    }

    /* ========== PUBLIC FUNCTIONS ========== */
    
    // There needs to be a time interval that this can be called. Otherwise it can be called multiple times per expansion.
    // To simulate global collateral ratio set xsd price higher than silver price and hit refresh collateral ratio.
    uint256 public last_call_time; // Last time the refreshCollateralRatio function was called
    function refreshCollateralRatio() public {
        require(collateral_ratio_paused == false, "Collateral Ratio has been paused");
        uint256 xsd_price_cur = xsd_price();
        require(block.timestamp - last_call_time >= refresh_cooldown, "Must wait for the refresh cooldown since last refresh");

        // Step increments are 0.25% (upon genesis, changable by setXSDStep()) 
        
        if (xsd_price_cur > (price_target+price_band)) { //decrease collateral ratio
            if(global_collateral_ratio <= xsd_step){ //if within a step of 0, go to 0
                global_collateral_ratio = 0;
            } else {
                global_collateral_ratio = global_collateral_ratio-xsd_step;
            }
        } else if (xsd_price_cur < price_target-price_band) { //increase collateral ratio
            if(global_collateral_ratio+xsd_step >= 1000000){
                global_collateral_ratio = 1000000; // cap collateral ratio at 1.000000
            } else {
                global_collateral_ratio = global_collateral_ratio+xsd_step;
            }
        }
        else
        last_call_time = block.timestamp; // Set the time of the last expansion
        uint256 _interest_rate = (1000000-global_collateral_ratio)/(2);
        //update interest rate
        if(_interest_rate>52800){
            interest_rate = _interest_rate;
        }
        else{
            interest_rate = 52800;
        }

        emit CollateralRatioRefreshed(global_collateral_ratio);
    }

    function creatorMint(uint256 amount) public onlyByOwner{
        require(genesis_supply+amount<cap_rate,"cap limit reached");
        super._mint(treasury,amount);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    // Used by pools when user redeems
    function pool_burn_from(address b_address, uint256 b_amount) public onlyPools {
        super._burnFrom(b_address, b_amount);
        emit XSDBurned(b_address, msg.sender, b_amount);
    }

    // This function is what other xsd pools will call to mint new XSD 
    function pool_mint(address m_address, uint256 m_amount) public onlyPools {
        super._mint(m_address, m_amount);
        emit XSDMinted(msg.sender, m_address, m_amount);
    }
    

    // Adds collateral addresses supported, such as tether and busd, must be ERC20 
    function addPool(address pool_address) public onlyByOwner {
        require(pool_address != address(0), "Zero address detected");

        require(xsd_pools[pool_address] == false, "Address already exists");
        xsd_pools[pool_address] = true; 
        xsd_pools_array.push(pool_address);

        emit PoolAdded(pool_address);
    }

    // Remove a pool 
    function removePool(address pool_address) public onlyByOwner {
        require(pool_address != address(0), "Zero address detected");

        require(xsd_pools[pool_address] == true, "Address nonexistant");
        
        // Delete from the mapping
        delete xsd_pools[pool_address];

        // 'Delete' from the array by setting the address to 0x0
        for (uint i = 0; i < xsd_pools_array.length; i++){ 
            if (xsd_pools_array[i] == pool_address) {
                xsd_pools_array[i] = address(0); // This will leave a null in the array and keep the indices the same
                break;
            }
        }

        emit PoolRemoved(pool_address);
    }
    function burnpoolXSD(uint _xsdamount) public {
        //uXSD = totalSupply - collat_XSD
        require(msg.sender == router, "Only the router can access this function");
        require(totalSupply()-CollateralPool(payable(collateral_pool_address)).collat_XSD()>_xsdamount, "uXSD has to be positive");
        super._burn(address(xsdEthPool),_xsdamount);
        xsdEthPool.sync();
        emit XSDBurned(msg.sender, address(this), _xsdamount);
    }
    
    function burnUserXSD(uint _xsdamount) public {
        require(totalSupply()-CollateralPool(payable(collateral_pool_address)).collat_XSD()>_xsdamount, "uXSD has to be positive");
        super._burn(msg.sender, _xsdamount);
        emit XSDBurned(msg.sender, address(this), _xsdamount);
    }
    function setXSDStep(uint256 _new_step) public onlyByOwnerPID {
        xsd_step = _new_step;

        emit XSDStepSet(_new_step);
    }  

    function setPriceTarget (uint256 _new_price_target) public onlyByOwnerPID {
        price_target = _new_price_target;

        emit PriceTargetSet(_new_price_target);
    }

    function setRefreshCooldown(uint256 _new_cooldown) public onlyByOwnerPID {
    	refresh_cooldown = _new_cooldown;

        emit RefreshCooldownSet(_new_cooldown);
    }

    function setTreasury(address _new_treasury) public onlyByOwner {
        require(_new_treasury != address(0), "Zero address detected");
        treasury = _new_treasury;
    }

    function setETHUSDOracle(address _eth_usd_oracle_address) public onlyByOwner {
        require(_eth_usd_oracle_address != address(0), "Zero address detected");

        eth_usd_oracle_address = _eth_usd_oracle_address;
        eth_usd_pricer = ChainlinkETHUSDPriceConsumer(eth_usd_oracle_address);
        eth_usd_pricer_decimals = eth_usd_pricer.getDecimals();

        emit ETHUSDOracleSet(_eth_usd_oracle_address);
    }
    
    function setXAGUSDOracle(address _xag_usd_oracle_address) public onlyByOwner {
        require(_xag_usd_oracle_address != address(0), "Zero address detected");

        xag_usd_oracle_address = _xag_usd_oracle_address;
        xag_usd_pricer = ChainlinkXAGUSDPriceConsumer(xag_usd_oracle_address);
        xag_usd_pricer_decimals = xag_usd_pricer.getDecimals();

        emit XAGUSDOracleSet(_xag_usd_oracle_address);
    }

    function setPIDController(address _pid_address) external onlyByOwner {
        require(_pid_address != address(0), "Zero address detected");

        pid_address = _pid_address;

        emit PIDControllerSet(_pid_address);
    }

    function setRouterAddress(address _router) external onlyByOwner {
        require(_router != address(0), "Zero address detected");
        router = _router;
    }

    function setPriceBand(uint256 _price_band) external onlyByOwner {
        price_band = _price_band;

        emit PriceBandSet(_price_band);
    }

    // Sets the XSD_ETH Uniswap oracle address 
    function setXSDEthPool(address _xsd_pool_addr) public onlyByOwner {
        require(_xsd_pool_addr != address(0), "Zero address detected");
        xsdEthPool = IXSDWETHpool(_xsd_pool_addr); 

        emit XSDETHPoolSet(_xsd_pool_addr);
    }

    // Sets the BankX_ETH Uniswap oracle address 
    function setBankXEthPool(address _bankx_pool_addr) public onlyByOwner {
        require(_bankx_pool_addr != address(0), "Zero address detected");
        bankxEthPool = IBankXWETHpool(_bankx_pool_addr);

        emit BankXEthPoolSet(_bankx_pool_addr);
    }

    //sets the collateral pool address
    function setCollateralEthPool(address _collateral_pool_address) public onlyByOwner {
        require(_collateral_pool_address != address(0), "Zero address detected");
        collateral_pool_address = payable(_collateral_pool_address);
    }

    function setSmartContractOwner(address _smartcontract_owner) external{
        require(msg.sender == smartcontract_owner, "Only the smart contract owner can access this function");
        require(msg.sender != address(0), "Zero address detected");
        smartcontract_owner = _smartcontract_owner;
    }

    function renounceOwnership() external{
        require(msg.sender == smartcontract_owner, "Only the smart contract owner can access this function");
        smartcontract_owner = address(0);
    }

    /* ========== EVENTS ========== */

    // Track XSD burned
    event XSDBurned(address indexed from, address indexed to, uint256 amount);

    // Track XSD minted
    event XSDMinted(address indexed from, address indexed to, uint256 amount);

    event CollateralRatioRefreshed(uint256 global_collateral_ratio);
    event PoolAdded(address pool_address);
    event PoolRemoved(address pool_address);
    event RedemptionFeeSet(uint256 red_fee);
    event MintingFeeSet(uint256 min_fee);
    event XSDStepSet(uint256 new_step);
    event PriceTargetSet(uint256 new_price_target);
    event RefreshCooldownSet(uint256 new_cooldown);
    event ETHUSDOracleSet(address eth_usd_oracle_address);
    event XAGUSDOracleSet(address xag_usd_oracle_address);
    event PIDControllerSet(address _pid_controller);
    event PriceBandSet(uint256 price_band);
    event XSDETHPoolSet(address xsd_pool_addr);
    event BankXEthPoolSet(address bankx_pool_addr);
    event CollateralRatioToggled(bool collateral_ratio_paused);
}
pragma solidity ^0.8.0;

import '../XSD/XSDStablecoin.sol';
import "../UniswapFork/BankXLibrary.sol";
import "../XSD/Pools/Interfaces/ICollateralpool.sol";
import "../XSD/Pools/Interfaces/IBankXWETHpool.sol";
import "../XSD/Pools/Interfaces/IXSDWETHpool.sol";
import "../Utils/Initializable.sol";
import "./Interfaces/BankXNFTInterface.sol";
import "./Interfaces/ICD.sol";


contract PIDController is Initializable {

    // Instances
    XSDStablecoin public XSD;
    BankXToken public BankX;
    ICollateralpool public collateralpool;


    // XSD and BankX addresses
    address public xsdwethpool_address;
    address public bankxwethpool_address;
    address public collateralpool_address;
    address public smartcontract_owner;
    address public BankXNFT_address;
    address public cd_address;
    uint public NFT_timestamp;
    // Misc addresses
    address public reward_manager_address;
    address public WETH;
    // 6 decimals of precision
    uint256 public growth_ratio;
    uint256 public xsd_step;
    uint256 public GR_top_band;
    uint256 public GR_bottom_band;

    // Time-related
    uint256 public internal_cooldown;
    uint256 public last_update;
    
    // Booleans
    bool public is_active;
    bool public use_growth_ratio;
    bool public collateral_ratio_paused;
    bool public FIP_6;
    bool public bucket1;
    bool public bucket2;
    bool public bucket3;
    
    //deficit related variables
    uint public diff1;
    uint public diff2;
    uint public diff3;

    uint public timestamp1;
    uint public timestamp2;
    uint public timestamp3;

    uint public amountpaid1;
    uint public amountpaid2;
    uint public amountpaid3;

    //arbitrage relate variables
    uint256 public xsd_percent;
    uint256 public xsd_burnable_limit;
    uint256 public maxArbBurnAbove;
    uint256 public minArbBurnBelow;

    uint256 public xsd_percentage_target;
    uint256 public bankx_percentage_target;
    uint256 public cd_allocated_supply;

    /* ========== MODIFIERS ========== */

    modifier onlyByOwner() {
        require(msg.sender == smartcontract_owner || msg.sender == reward_manager_address, "Not owner or reward_manager");
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    function initialize(address _xsd_contract_address,address _bankx_contract_address,address _xsd_weth_pool_address, address _bankx_weth_pool_address,address payable _collateralpool_contract_address,address _WETHaddress,address _smartcontract_owner,address _reward_manager_address, uint _xsd_percentage_target, uint _bankx_percentage_target) public initializer{
        require(
            (_xsd_contract_address != address(0))
            && (_bankx_contract_address != address(0))
            && (_xsd_weth_pool_address != address(0))
            && (_bankx_weth_pool_address != address(0))
            && (_collateralpool_contract_address != address(0))
            && (_WETHaddress != address(0))
            && (_reward_manager_address != address(0))
        , "Zero address detected"); 
        xsdwethpool_address = _xsd_weth_pool_address;
        bankxwethpool_address = _bankx_weth_pool_address;
        smartcontract_owner = _smartcontract_owner;
        reward_manager_address = _reward_manager_address;
        xsd_step = 2500;
        collateralpool_address = _collateralpool_contract_address;
        collateralpool = ICollateralpool(_collateralpool_contract_address);
        XSD = XSDStablecoin(_xsd_contract_address);
        BankX = BankXToken(_bankx_contract_address);
        WETH = _WETHaddress;
        xsd_percentage_target = _xsd_percentage_target;
        bankx_percentage_target = _bankx_percentage_target;

        // Upon genesis, if GR changes by more than 1% percent, enable change of collateral ratio
        GR_top_band = 1000;
        GR_bottom_band = 1000; 
        is_active = false;
    }

    

    //interest rate variable
    /* ========== PUBLIC MUTATIVE FUNCTIONS ========== */
    
    function systemCalculations() public {
    	require(collateral_ratio_paused == false, "Collateral Ratio has been paused");
        uint256 time_elapsed = block.timestamp - last_update;
        require(time_elapsed >= internal_cooldown, "internal cooldown not passed");
        uint256 bankx_reserves = BankX.balanceOf(bankxwethpool_address);
        uint256 bankx_price = XSD.bankx_price();
        
        uint256 bankx_liquidity = bankx_reserves*bankx_price; // Has 6 decimals of precision

        uint256 xsd_supply = XSD.totalSupply();
        
        // Get the XSD price
        uint256 xsd_price = XSD.xsd_price();

        uint256 new_growth_ratio = (bankx_liquidity/(xsd_supply-collateralpool.collat_XSD())); // (E18 + E6) / E18

        uint256 last_collateral_ratio = XSD.global_collateral_ratio();
        uint256 new_collateral_ratio = last_collateral_ratio;
        uint256 silver_price = (XSD.xag_usd_price()*(1e4))/(311035); //31.1034768
        uint256 XSD_top_band = silver_price + (xsd_percent*silver_price)/100;
        uint256 XSD_bottom_band = silver_price - (xsd_percent*silver_price)/100;
        xsd_burnable_limit = approximateXSD();
        // make the top band and bottom band a percentage of silver price.

        if(FIP_6){
            require(xsd_price > XSD_top_band || xsd_price < XSD_bottom_band, "Use PIDController when XSD is outside of peg");
        }

        if((NFT_timestamp == 0) || ((block.timestamp - NFT_timestamp)>43200)){
            BankXInterface(BankXNFT_address).updateTVLReached();
            NFT_timestamp = block.timestamp;
        }

        // First, check if the price is out of the band
        if(xsd_price > XSD_top_band){
            new_collateral_ratio = last_collateral_ratio - xsd_step;
            maxArbBurnAbove = aboveThePeg();
        } else if (xsd_price < XSD_bottom_band){
            new_collateral_ratio = last_collateral_ratio + xsd_step;
            minArbBurnBelow = belowThePeg();

        // Else, check if the growth ratio has increased or decreased since last update
        } else if(use_growth_ratio){
            if(new_growth_ratio > ((growth_ratio*(1e6 + GR_top_band))/1e6)){
                new_collateral_ratio = last_collateral_ratio - xsd_step;
            } else if (new_growth_ratio < (growth_ratio*(1e6 - GR_bottom_band)/1e6)){
                new_collateral_ratio = last_collateral_ratio + xsd_step;
            }
        }

        growth_ratio = new_growth_ratio;
        last_update = block.timestamp;

        // No need for checking CR under 0 as the last_collateral_ratio.sub(xsd_step) will throw 
        // an error above in that case
        if(new_collateral_ratio > 1e6){
            new_collateral_ratio = 1e6;
        }
        incentiveChecker1();
        incentiveChecker2();
        incentiveChecker3();
//check what this part does
        if(is_active){
            uint256 delta_collateral_ratio;
            if(new_collateral_ratio > last_collateral_ratio){
                delta_collateral_ratio = new_collateral_ratio - last_collateral_ratio;
                XSD.setPriceTarget(1000e6); // Set to high value to decrease CR
                emit XSDdecollateralize(new_collateral_ratio);
            } else if (new_collateral_ratio < last_collateral_ratio){
                delta_collateral_ratio = last_collateral_ratio - new_collateral_ratio;
                XSD.setPriceTarget(0); // Set to zero to increase CR
                emit XSDrecollateralize(new_collateral_ratio);
            }

            XSD.setXSDStep(delta_collateral_ratio); // Change by the delta
            uint256 cooldown_before = XSD.refresh_cooldown(); // Note the existing cooldown period
            XSD.setRefreshCooldown(0); // Unlock the CR cooldown
            //refresh interest rate.
            XSD.refreshCollateralRatio(); // Refresh CR

            // Reset params
            XSD.setXSDStep(0);
            XSD.setRefreshCooldown(cooldown_before); // Set the cooldown period to what it was before, or until next controller refresh
            //change price target to that of one ounce/gram of silver.
            XSD.setPriceTarget((XSD.xag_usd_price()*(1e4))/(311035));           
        }
    }

    //checks the XSD liquidity pool for a deficit.
    //bucket and difference variables should return values only if changed.
    // difference is calculated only every week.
    function incentiveChecker1() internal{
        uint silver_price = (XSD.xag_usd_price()*(1e4))/(311035);
        uint XSDvalue = (XSD.totalSupply()*(silver_price))/(1e6);
        uint _reserve1;
        (,_reserve1,) = IXSDWETHpool(xsdwethpool_address).getReserves();
        uint reserve = (_reserve1*(XSD.eth_usd_price())*2)/(1e6);
        if(((block.timestamp - timestamp1)>=604800)||(amountpaid1 >= diff1)){
            timestamp1 = 0;
            bucket1 = false;
            diff1 = 0;
            amountpaid1 = 0;
        }
        if(timestamp1 == 0){
        if(reserve<(XSDvalue*xsd_percentage_target/100)){
            bucket1 = true;
            diff1 = ((XSDvalue*xsd_percentage_target/100)-reserve)/2;
            timestamp1 = block.timestamp;
        }
        }
    }

    //checks the BankX liquidity pool for a deficit.
    //bucket and difference variables should return values only if changed.
    function incentiveChecker2() internal{
        cd_allocated_supply = ICD(cd_address).allocatedSupply()*1e10;
        uint BankXvalue = (cd_allocated_supply*(XSD.bankx_price()))/(1e6);
        uint _reserve1;
        (, _reserve1,) = IBankXWETHpool(bankxwethpool_address).getReserves();
        uint reserve = (_reserve1*(XSD.eth_usd_price())*2)/(1e6);
        if(((block.timestamp - timestamp2)>=604800)|| (amountpaid2 >= diff2)){
            timestamp2 = 0;
            bucket2 = false;
            diff2 = 0;
            amountpaid2 = 0;
        }
        if(timestamp2 == 0){
        if(reserve<(BankXvalue*bankx_percentage_target/100)){
            bucket2 = true;
            diff2 = ((BankXvalue*bankx_percentage_target/100) - reserve)/2;
            timestamp2 = block.timestamp;
        }
        }
    }

    //checks the Collateral pool for a deficit
    // return system collateral as a public global variable
    function incentiveChecker3() internal{
        uint silver_price = (XSD.xag_usd_price()*(1e4))/(311035);
        uint XSDvalue = (collateralpool.collat_XSD()*(silver_price))/(1e6);//use gram of silver price
        uint collatValue = collateralpool.collatDollarBalance();// eth value in the collateral pool
        XSDvalue = (XSDvalue * XSD.global_collateral_ratio())/(1e6);
        if(((block.timestamp-timestamp3)>=604800) || (amountpaid3 >= diff3)){
            timestamp3 = 0;
            bucket3 = false;
            diff3 = 0;
            amountpaid3 = 0;
        }
        if(timestamp3 == 0 && collatValue != 0){
        if((collatValue*400)<=(3*XSDvalue)){ //posted collateral - actual collateral <= 0.25% posted collateral
            bucket3 = true;
            diff3 = (3*XSDvalue) - (collatValue*400); 
            timestamp3 = block.timestamp;
        }
        }
    }

    //Essentially the value of both halves of the pool have to be the same:
    // XSD number * XSD USD price = ETH reserves * ETH USD Price
    // target XSD number = ETH reserves * ETH USD Price/ silver price

    function approximateXSD() internal view returns(uint256 xsd_amount){
        (uint reserveA, uint reserveB,) = IXSDWETHpool(xsdwethpool_address).getReserves();
        uint silver_price = (XSD.xag_usd_price()*(1e4))/(311035);
        uint x = reserveB * XSD.eth_usd_price(); // precision of 1e6
        uint target = x/silver_price; //number of xsd we need
        if(target>reserveA)
            xsd_amount = target - reserveA;
        else
            xsd_amount = reserveA - target;
}
//burning BankX for XSD
//sol gives the maxXSD that can be minted
function aboveThePeg() internal view returns(uint256 sol){
    uint silver_price = (XSD.xag_usd_price()*(1e4))/(311035);
    (uint reserveA, uint reserveB,) = IXSDWETHpool(xsdwethpool_address).getReserves();
    sol = ((XSD.xsd_price()*XSD.eth_usd_price()*reserveB) - (reserveA*XSD.xsd_price()*silver_price))/((silver_price+XSD.xsd_price())*silver_price);
    if( sol > xsd_burnable_limit){
        sol = xsd_burnable_limit;
    }
}

//burning XSD for BankX
// sol gives the maxXSD that can be burnt
function belowThePeg() internal view returns(uint256 sol){
    uint silver_price = (XSD.xag_usd_price()*(1e4))/(311035);
    (uint reserveA, uint reserveB,) = IXSDWETHpool(xsdwethpool_address).getReserves();
    sol = ((reserveA*XSD.xsd_price()*silver_price)-(XSD.xsd_price()*XSD.eth_usd_price()*reserveB))/((silver_price+XSD.xsd_price())*silver_price);
    if( sol > xsd_burnable_limit){
        sol = xsd_burnable_limit;
    }
}

    //functions to change amountpaid variables
    function amountPaidXSDWETH(uint ethvalue) external {
        require(msg.sender == reward_manager_address, "Only RewardManager can access this address");
        amountpaid1 += ethvalue;
    }

    function amountPaidBankXWETH(uint ethvalue) external {
        require(msg.sender == reward_manager_address, "Only RewardManager can access this address");
        amountpaid2 += ethvalue;
    }
    
    function amountPaidCollateralPool(uint ethvalue) external {
        require(msg.sender == reward_manager_address,"Only RewardManager can access this address");
        amountpaid3 += ethvalue;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function activate(bool _state) external onlyByOwner {
        is_active = _state;
    }

    function useGrowthRatio(bool _use_growth_ratio) external onlyByOwner {
        use_growth_ratio = _use_growth_ratio;
    }

    // As a percentage added/subtracted from the previous; e.g. top_band = 4000 = 0.4% -> will decollat if GR increases by 0.4% or more
    function setGrowthRatioBands(uint256 _GR_top_band, uint256 _GR_bottom_band) external onlyByOwner {
        GR_top_band = _GR_top_band;
        GR_bottom_band = _GR_bottom_band;
    }

    function setInternalCooldown(uint256 _internal_cooldown) external onlyByOwner {
        internal_cooldown = _internal_cooldown;
    }

    function setXSDStep(uint256 _new_step) external onlyByOwner {
        xsd_step = _new_step;
    }

    function setPriceBandPercentage(uint256 percent) external onlyByOwner {
        require(percent!=0,"PID:Zero value detected");
        xsd_percent = percent;
    }

    function toggleCollateralRatio(bool _is_paused) external onlyByOwner {
    	collateral_ratio_paused = _is_paused;
    }

    function activateFIP6(bool _activate) external onlyByOwner {
        FIP_6 = _activate;
    }

    function setSmartContractOwner(address _smartcontract_owner) external{
        require(msg.sender == smartcontract_owner, "Only the smart contract owner can access this function");
        require(msg.sender != address(0), "Zero address detected");
        smartcontract_owner = _smartcontract_owner;
    }

    function renounceOwnership() external{
        require(msg.sender == smartcontract_owner, "Only the smart contract owner can access this function");
        smartcontract_owner = address(0);
    }
    
    function setXSDPoolAddress(address _xsd_weth_pool_address) external onlyByOwner{
        xsdwethpool_address = _xsd_weth_pool_address;
    }

    function setBankXPoolAddress(address _bankx_weth_pool_address) external onlyByOwner{
        bankxwethpool_address = _bankx_weth_pool_address;
    }
    
    function setRewardManagerAddress(address _reward_manager_address) external onlyByOwner{
        reward_manager_address = _reward_manager_address;
    }

    function setCollateralPoolAddress(address payable _collateralpool_contract_address) external onlyByOwner{
        collateralpool_address = _collateralpool_contract_address;
        collateralpool = ICollateralpool(_collateralpool_contract_address);
    }

    function setXSDAddress(address _xsd_contract_address) external onlyByOwner{
        XSD = XSDStablecoin(_xsd_contract_address);
    }

    function setBankXAddress(address _bankx_contract_address) external onlyByOwner{
        BankX = BankXToken(_bankx_contract_address);
    }

    function setWETHAddress(address _WETHaddress) external onlyByOwner{
        WETH = _WETHaddress;
    }

    function setBankXNFTAddress(address _BankXNFT_address) external onlyByOwner{
        BankXNFT_address = _BankXNFT_address;
    }

    function setCDAddress(address _cd_address) external onlyByOwner{
        cd_address = _cd_address;
    }

    function setPercentageTarget(uint256 _xsd_percentage_target, uint256 _bankx_percentage_target) external onlyByOwner{
        xsd_percentage_target = _xsd_percentage_target;
        bankx_percentage_target = _bankx_percentage_target;
    }

    /* ========== EVENTS ========== */  
    event XSDdecollateralize(uint256 new_collateral_ratio);
    event XSDrecollateralize(uint256 new_collateral_ratio);
}
pragma solidity ^0.8.0;


interface IRouter{
    function creatorAddLiquidityTokens(
        address tokenB,
        uint amountB
    ) external;

    function creatorAddLiquidityETH(
        address pool
    ) external payable;

    function userAddLiquidityETH(
        address pool
    ) external payable;

    function userRedeemLiquidity(
        address pool
    ) external;

    function swapETHForXSD(uint amountOut) external payable;

    function swapXSDForETH(uint amountOut, uint amountInMax) external;

    function swapETHForBankX(uint amountOut) external payable;
    
    function swapBankXForETH(uint amountOut, uint amountInMax) external;

    function swapBankXForXSD(uint bankx_amount,address sender,uint256 slippage) external;

    function swapXSDForBankX(uint XSD_amount,address sender,uint256 slippage) external;

}
pragma solidity >=0.6.0;

// helper methods for interacting with ERC20 tokens and sending ETH that do not consistently return true/false
library TransferHelper {
    function safeApprove(
        address token,
        address to,
        uint256 value
    ) internal {
        // bytes4(keccak256(bytes('approve(address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, to, value));
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            'TransferHelper::safeApprove: approve failed'
        );
    }

    function safeTransfer(
        address token,
        address to,
        uint256 value
    ) internal {
        // bytes4(keccak256(bytes('transfer(address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            'TransferHelper::safeTransfer: transfer failed'
        );
    }

    function safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 value
    ) internal {
        // bytes4(keccak256(bytes('transferFrom(address,address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            'TransferHelper::transferFrom: transferFrom failed'
        );
    }

    function safeTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success, 'TransferHelper::safeTransferETH: ETH transfer failed');
    }
}
pragma solidity ^0.8.0;

import "./AggregatorV3Interface.sol";

contract ChainlinkXAGUSDPriceConsumer {

    AggregatorV3Interface internal priceFeed;


    constructor() {
        priceFeed = AggregatorV3Interface(0x817326922c909b16944817c207562B25C4dF16aD);
    }

    /**
     * Returns the latest price
     */
    function getLatestPrice() public view returns (int) {
        (
            , 
            int price,
            ,
            ,
            
        ) = priceFeed.latestRoundData();
        return price;
    }

    function getDecimals() public view returns (uint8) {
        return priceFeed.decimals();
    }
}
pragma solidity ^0.8.0;

import "./AggregatorV3Interface.sol";

contract ChainlinkETHUSDPriceConsumer {

    AggregatorV3Interface internal priceFeed;

    constructor() {
        priceFeed = AggregatorV3Interface(0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE);
    }

    /**
     * Returns the latest price
     */
    function getLatestPrice() public view returns (int) {
        (
            , 
            int price,
            ,
            ,
            
        ) = priceFeed.latestRoundData();
        return price;
    }

    function getDecimals() public view returns (uint8) {
        return priceFeed.decimals();
    }
}
pragma solidity ^0.8.0;

interface IXSDWETHpool {
    function PERMIT_TYPEHASH() external pure returns (bytes32);
    function nonces(address owner) external view returns (uint);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint);
    function price1CumulativeLast() external view returns (uint);
    function kLast() external view returns (uint);
    function collatDollarBalance() external returns (uint);
    function swap(uint amount0Out, uint amount1Out, address to) external;
    function skim(address to) external;
    function sync() external;
}
pragma solidity ^0.8.0;

interface IBankXWETHpool {
    function PERMIT_TYPEHASH() external pure returns (bytes32);
    function nonces(address owner) external view returns (uint);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint);
    function price1CumulativeLast() external view returns (uint);
    function kLast() external view returns (uint);
    function collatDollarBalance() external returns(uint);
    function swap(uint amount0Out, uint amount1Out, address to) external;
    function skim(address to) external;
    function sync() external;
}
pragma solidity ^0.8.0;

import '@uniswap/lib/contracts/libraries/TransferHelper.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import "../../BankX/BankXToken.sol";
import "../XSDStablecoin.sol";
import "./Interfaces/IBankXWETHpool.sol";
import "./Interfaces/IXSDWETHpool.sol";
import '../../Oracle/Interfaces/IPIDController.sol';
import "../../BEP20/IWBNB.sol";
import "./CollateralPoolLibrary.sol";

contract CollateralPool is ReentrancyGuard {
    
// accumulated interest rate:  0.000002739726639247
    /* ========== STATE VARIABLES ========== */

    address public WETH;
    address public smartcontract_owner;
    address public xsd_contract_address;
    address public bankx_contract_address;
    address public xsdweth_pool;
    address public bankxweth_pool;
    address public pid_address;
    BankXToken private BankX;
    XSDStablecoin private XSD;
    IPIDController private pid_controller;
    uint256 public collat_XSD;
    uint256 public bankx_price;
    uint256 public xsd_price;
    bool public mint_paused;
    bool public redeem_paused;
    bool public buyback_paused;

    struct MintInfo {
        uint256 accum_interest; //accumulated interest from previous mints
        uint256 interest_rate; //interest rate at that particular timestamp
        uint256 time; //last timestamp
        uint256 amount; //XSD amount minted
    }
    struct PriceCheck{
        uint256 lastpricecheck;
        bool pricecheck;
    }
    mapping(address=>MintInfo) public mintMapping; 
    mapping (address => uint256) public redeemBankXBalances;
    mapping (address => uint256) public redeemCollateralBalances;
    mapping (address => uint256) public vestingtimestamp;
    uint256 public unclaimedPoolCollateral;
    uint256 public unclaimedPoolBankX;
    uint256 public collateral_equivalent_d18;
    uint256 public bankx_minted_count;
    mapping (address => uint256) public lastRedeemed;
    mapping (address => PriceCheck) public lastPriceCheck;

    // Number of blocks to wait before being able to collectRedemption()
    uint256 public block_delay = 2;
    /* ========== MODIFIERS ========== */

    modifier onlyByOwner() {
        require(msg.sender == smartcontract_owner, "Not owner");
        _;
    }
 
    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _xsd_contract_address,
        address _bankx_contract_address,
        address _bankxweth_pool,
        address _xsdweth_pool,
        address _WETH,
        address _smartcontract_owner
    ) {
        require(
            (_xsd_contract_address != address(0))
            && (_bankx_contract_address != address(0))
            && (_WETH != address(0))
            && (_bankxweth_pool != address(0))
            && (_xsdweth_pool != address(0))
        , "Zero address detected"); 
        XSD = XSDStablecoin(_xsd_contract_address);
        BankX = BankXToken(_bankx_contract_address);
        xsd_contract_address = _xsd_contract_address;
        bankx_contract_address = _bankx_contract_address;
        xsdweth_pool = _xsdweth_pool;
        bankxweth_pool = _bankxweth_pool;
        WETH = _WETH;
        smartcontract_owner = _smartcontract_owner;
    }

    /* ========== VIEWS ========== */

    //only accept ETH via fallback function from the WETH contract
    receive() external payable {
        assert(msg.sender == WETH);
    }

    // Returns dollar value of collateral held in this XSD pool
    function collatDollarBalance() external view returns (uint256) {
            return ((IWBNB(WETH).balanceOf(address(this))*XSD.eth_usd_price())/(1e6));        
    }

    // Returns the value of excess collateral held in this XSD pool, compared to what is needed to maintain the global collateral ratio
    function availableExcessCollatDV() public view returns (uint256) {
        uint256 global_collateral_ratio = XSD.global_collateral_ratio();
        uint256 global_collat_value = XSD.globalCollateralValue();

        if (global_collateral_ratio > (1e6)) global_collateral_ratio = (1e6); // Handles an overcollateralized contract with CR > 1
        uint256 required_collat_dollar_value_d18 = ((collat_XSD)*global_collateral_ratio*(XSD.xag_usd_price()*(1e4))/(311035))/(1e12); // Calculates collateral needed to back each 1 XSD with $1 of collateral at current collat ratio
        if ((global_collat_value-unclaimedPoolCollateral)>required_collat_dollar_value_d18) return (global_collat_value-unclaimedPoolCollateral-required_collat_dollar_value_d18);
        else return 0;
    }
    /* ========== INTERNAL FUNCTIONS ======== */
    function priceCheck() external{
        bankx_price = XSD.bankx_price();
        xsd_price = XSD.xsd_price();
        lastPriceCheck[msg.sender].lastpricecheck = block.number;
        lastPriceCheck[msg.sender].pricecheck = true;
    }

    function mintInterestCalc(uint xsd_amount,address sender) internal {
        (mintMapping[sender].accum_interest, mintMapping[sender].interest_rate, mintMapping[sender].time, mintMapping[sender].amount) = CollateralPoolLibrary.calcMintInterest(xsd_amount,XSD.xag_usd_price(), XSD.interest_rate(), mintMapping[sender].accum_interest, mintMapping[sender].interest_rate, mintMapping[sender].time, mintMapping[sender].amount);
    }
    function redeemInterestCalc(uint xsd_amount,address sender) internal {
        (mintMapping[sender].accum_interest, mintMapping[sender].interest_rate, mintMapping[sender].time, mintMapping[sender].amount)=CollateralPoolLibrary.calcRedemptionInterest(xsd_amount,XSD.xag_usd_price(), mintMapping[sender].accum_interest, mintMapping[sender].interest_rate, mintMapping[sender].time, mintMapping[sender].amount);
    }

    /* ========== PUBLIC FUNCTIONS ========== */
    
    // We separate out the 1t1, fractional and algorithmic minting functions for gas efficiency 
    function mint1t1XSD(uint256 XSD_out_min) external payable nonReentrant {
        require(!mint_paused, "Mint Paused");
        require(msg.value>0, "Invalid collateral amount");
        require(XSD.global_collateral_ratio() >= (1e6), "Collateral ratio must be >= 1");
        (uint256 xsd_amount_d18) = CollateralPoolLibrary.calcMint1t1XSD(
            XSD.eth_usd_price(),
            XSD.xag_usd_price(),
            msg.value
        ); //1 XSD for each $1 worth of collateral
        require(XSD_out_min <= xsd_amount_d18, "Slippage limit reached");
        mintInterestCalc(xsd_amount_d18,msg.sender);
        IWBNB(WETH).deposit{value: msg.value}();
        assert(IWBNB(WETH).transfer(address(this), msg.value));
        collat_XSD = collat_XSD + xsd_amount_d18;
        XSD.pool_mint(msg.sender, xsd_amount_d18);
    }

    // 0% collateral-backed
    function mintAlgorithmicXSD(uint256 bankx_amount_d18, uint256 XSD_out_min) external nonReentrant {
        require(!mint_paused, "Mint Paused");
        require(((lastPriceCheck[msg.sender].lastpricecheck+(block_delay)) <= block.number) && (lastPriceCheck[msg.sender].pricecheck), "Must wait for block_delay blocks before collecting redemption");
        uint256 xag_usd_price = XSD.xag_usd_price();
        require(XSD.global_collateral_ratio() == 0, "Collateral ratio must be 0");
        (uint256 xsd_amount_d18) = CollateralPoolLibrary.calcMintAlgorithmicXSD(
            bankx_price, // X BankX / 1 USD
            xag_usd_price,
            bankx_amount_d18
        );
        require(XSD_out_min <= xsd_amount_d18, "Slippage limit reached");
        mintInterestCalc(xsd_amount_d18,msg.sender);
        collat_XSD = collat_XSD + xsd_amount_d18;
        bankx_minted_count = bankx_minted_count + bankx_amount_d18;
        lastPriceCheck[msg.sender].pricecheck = false;
        BankX.pool_burn_from(msg.sender, bankx_amount_d18);
        XSD.pool_mint(msg.sender, xsd_amount_d18);
    }

    // Will fail if fully collateralized or fully algorithmic
    // > 0% and < 100% collateral-backed
    function mintFractionalXSD(uint256 bankx_amount, uint256 XSD_out_min) external payable nonReentrant {
        require(!mint_paused, "Mint Paused");
        require(((lastPriceCheck[msg.sender].lastpricecheck+(block_delay)) <= block.number) && (lastPriceCheck[msg.sender].pricecheck), "Must wait for block_delay blocks before collecting redemption");
        uint256 xag_usd_price = XSD.xag_usd_price();
        uint256 global_collateral_ratio = XSD.global_collateral_ratio();

        require(global_collateral_ratio < (1e6) && global_collateral_ratio > 0, "Collateral ratio needs to be between .000001 and .999999");
        CollateralPoolLibrary.MintFF_Params memory input_params = CollateralPoolLibrary.MintFF_Params(
            bankx_price,
            XSD.eth_usd_price(),
            bankx_amount,
            msg.value,
            global_collateral_ratio
        );

        (uint256 mint_amount, uint256 bankx_needed) = CollateralPoolLibrary.calcMintFractionalXSD(input_params);
        mint_amount = (mint_amount*31103477)/((xag_usd_price)); //grams of silver in calculated mint amount
        require(XSD_out_min <= mint_amount, "Slippage limit reached");
        require(bankx_needed <= bankx_amount, "Not enough BankX inputted");
        mintInterestCalc(mint_amount,msg.sender);
        bankx_minted_count = bankx_minted_count + bankx_needed;
        BankX.pool_burn_from(msg.sender, bankx_needed);
        IWBNB(WETH).deposit{value: msg.value}();
        assert(IWBNB(WETH).transfer(address(this), msg.value));
        collat_XSD = collat_XSD + mint_amount;
        lastPriceCheck[msg.sender].pricecheck = false;
        XSD.pool_mint(msg.sender, mint_amount);
    }

    // Redeem collateral. 100% collateral-backed
    function redeem1t1XSD(uint256 XSD_amount, uint256 COLLATERAL_out_min) external nonReentrant {
        require(!pid_controller.bucket3(), "Cannot withdraw in times of deficit");
        require(!redeem_paused, "Redeem Paused");
        require(XSD.global_collateral_ratio() == (1e6), "Collateral ratio must be == 1");
        require(XSD_amount<=mintMapping[msg.sender].amount, "OVERREDEMPTION ERROR");
        require(((lastPriceCheck[msg.sender].lastpricecheck+(block_delay)) <= block.number) && (lastPriceCheck[msg.sender].pricecheck), "Must wait for block_delay blocks before collecting redemption");

        // convert xsd to $ and then to collateral value
        (uint256 XSD_dollar,uint256 collateral_needed) = CollateralPoolLibrary.calcRedeem1t1XSD(
            XSD.eth_usd_price(),
            XSD.xag_usd_price(),
            XSD_amount
        );
        uint total_xsd_amount = mintMapping[msg.sender].amount;
        require(collateral_needed <= (IWBNB(WETH).balanceOf(address(this))-unclaimedPoolCollateral), "Not enough collateral in pool");
        require(COLLATERAL_out_min <= collateral_needed, "Slippage limit reached");
        redeemInterestCalc(XSD_amount, msg.sender);
        uint current_accum_interest = (XSD_amount*mintMapping[msg.sender].accum_interest)/total_xsd_amount;
        redeemBankXBalances[msg.sender] = (redeemBankXBalances[msg.sender]+current_accum_interest);
        redeemCollateralBalances[msg.sender] = redeemCollateralBalances[msg.sender]+XSD_dollar;
        unclaimedPoolCollateral = unclaimedPoolCollateral+XSD_dollar;
        lastRedeemed[msg.sender] = block.number;
        unclaimedPoolBankX = (unclaimedPoolBankX+current_accum_interest);
        uint256 bankx_amount = (current_accum_interest*1e6)/bankx_price;
        // Move all external functions to the end
        collat_XSD -= XSD_amount;
        lastPriceCheck[msg.sender].pricecheck = false;
        mintMapping[msg.sender].accum_interest = (mintMapping[msg.sender].accum_interest - current_accum_interest);
        XSD.pool_burn_from(msg.sender, XSD_amount);
        BankX.pool_mint(address(this), bankx_amount);
    }

    // Will fail if fully collateralized or algorithmic
    // Redeem XSD for collateral and BankX. > 0% and < 100% collateral-backed
    function redeemFractionalXSD(uint256 XSD_amount, uint256 BankX_out_min, uint256 COLLATERAL_out_min) external nonReentrant {
        require(!pid_controller.bucket3(), "Cannot withdraw in times of deficit");
        require(!redeem_paused, "Redeem Paused");
        require(XSD_amount<=mintMapping[msg.sender].amount, "OVERREDEMPTION ERROR");
        require(((lastPriceCheck[msg.sender].lastpricecheck+(block_delay)) <= block.number) && (lastPriceCheck[msg.sender].pricecheck), "Must wait for block_delay blocks before collecting redemption");
        uint256 xag_usd_price = XSD.xag_usd_price();
        uint256 global_collateral_ratio = XSD.global_collateral_ratio();

        require(global_collateral_ratio < (1e6) && global_collateral_ratio > 0, "Collateral ratio needs to be between .000001 and .999999");
        

        uint256 bankx_dollar_value_d18 = XSD_amount - ((XSD_amount*global_collateral_ratio)/(1e6));
        bankx_dollar_value_d18 = (bankx_dollar_value_d18*xag_usd_price)/(31103477);
        uint256 bankx_amount = (bankx_dollar_value_d18*1e6)/bankx_price;

        // Get dollar value required and then convert to collateral value(WETH)
        uint256 collateral_dollar_value = (XSD_amount*global_collateral_ratio)/(1e6);
        collateral_dollar_value = (collateral_dollar_value*xag_usd_price)/31103477;
        uint256 collateral_amount = (collateral_dollar_value*1e6)/XSD.eth_usd_price();


        require(collateral_amount <= (IWBNB(WETH).balanceOf(address(this))-unclaimedPoolCollateral), "Not enough collateral in pool");
        require(COLLATERAL_out_min <= collateral_amount, "Slippage limit reached [collateral]");
        require(BankX_out_min <= bankx_amount, "Slippage limit reached [BankX]");

        redeemCollateralBalances[msg.sender] = redeemCollateralBalances[msg.sender]+collateral_dollar_value;
        unclaimedPoolCollateral = unclaimedPoolCollateral+collateral_dollar_value;
        lastRedeemed[msg.sender] = block.number;
        uint total_xsd_amount = mintMapping[msg.sender].amount;
        redeemInterestCalc(XSD_amount, msg.sender);
        uint current_accum_interest = (XSD_amount*mintMapping[msg.sender].accum_interest)/total_xsd_amount;
        redeemBankXBalances[msg.sender] = redeemBankXBalances[msg.sender]+current_accum_interest;
        bankx_amount = bankx_amount + ((current_accum_interest*1e6)/bankx_price);
        mintMapping[msg.sender].accum_interest = mintMapping[msg.sender].accum_interest - current_accum_interest;
        redeemBankXBalances[msg.sender] = redeemBankXBalances[msg.sender]+bankx_dollar_value_d18;
        unclaimedPoolBankX = unclaimedPoolBankX+bankx_dollar_value_d18+current_accum_interest;
        collat_XSD -= XSD_amount;
        lastPriceCheck[msg.sender].pricecheck = false;
        // Move all external functions to the end
        XSD.pool_burn_from(msg.sender, XSD_amount);
        BankX.pool_mint(address(this), bankx_amount);
    }

    // Redeem XSD for BankX. 0% collateral-backed
    function redeemAlgorithmicXSD(uint256 XSD_amount, uint256 BankX_out_min) external nonReentrant {
        require(!pid_controller.bucket3(), "Cannot withdraw in times of deficit");
        require(!redeem_paused, "Redeem Paused");
        require(XSD_amount<=mintMapping[msg.sender].amount, "OVERREDEMPTION ERROR");
        require(XSD.global_collateral_ratio() == 0, "Collateral ratio must be 0"); 
        require(((lastPriceCheck[msg.sender].lastpricecheck+(block_delay)) <= block.number) && (lastPriceCheck[msg.sender].pricecheck), "Must wait for block_delay blocks before collecting redemption");
        uint256 bankx_dollar_value_d18 = (XSD_amount*XSD.xag_usd_price())/(31103477);

        uint256 bankx_amount = (bankx_dollar_value_d18*1e6)/bankx_price;
        
        lastRedeemed[msg.sender] = block.number;
        uint total_xsd_amount = mintMapping[msg.sender].amount;
        require(BankX_out_min <= bankx_amount, "Slippage limit reached");
        redeemInterestCalc(XSD_amount, msg.sender);
        uint current_accum_interest = XSD_amount*mintMapping[msg.sender].accum_interest/total_xsd_amount; //precision of 6
        redeemBankXBalances[msg.sender] = (redeemBankXBalances[msg.sender]+current_accum_interest);
        bankx_amount = bankx_amount + ((current_accum_interest*1e6)/bankx_price);
        mintMapping[msg.sender].accum_interest = (mintMapping[msg.sender].accum_interest - current_accum_interest);
        redeemBankXBalances[msg.sender] = redeemBankXBalances[msg.sender]+bankx_dollar_value_d18;
        unclaimedPoolBankX = unclaimedPoolBankX+bankx_dollar_value_d18+current_accum_interest;
        collat_XSD -= XSD_amount;
        lastPriceCheck[msg.sender].pricecheck = false;
        // Move all external functions to the end
        XSD.pool_burn_from(msg.sender, XSD_amount);
        BankX.pool_mint(address(this), bankx_amount);
    }

    // After a redemption happens, transfer the newly minted BankX and owed collateral from this pool
    // contract to the user. Redemption is split into two functions to prevent flash loans from being able
    // to take out XSD/collateral from the system, use an AMM to trade the new price, and then mint back into the system.
    function collectRedemption() external nonReentrant{
        require(!pid_controller.bucket3(), "Cannot withdraw in times of deficit");
        require(!redeem_paused, "Redeem Paused");
        require((lastRedeemed[msg.sender]+(block_delay)) <= block.number, "Must wait for block_delay blocks before collecting redemption");
        require(((lastRedeemed[msg.sender]+(block_delay)) <= block.number) && ((lastPriceCheck[msg.sender].lastpricecheck+(block_delay)) <= block.number) && (lastPriceCheck[msg.sender].pricecheck), "Must wait for block_delay blocks before collecting redemption");
        //check for bucket and revert if there is a deficit.
        // add address parameter
        uint BankXDollarAmount;
        uint CollateralDollarAmount;
        uint BankXAmount;
        uint CollateralAmount;

        // Use Checks-Effects-Interactions pattern
        if(redeemBankXBalances[msg.sender] > 0){
            BankXDollarAmount = redeemBankXBalances[msg.sender];
            BankXAmount = (BankXDollarAmount*1e6)/bankx_price;
            redeemBankXBalances[msg.sender] = 0;
            unclaimedPoolBankX = unclaimedPoolBankX-BankXDollarAmount;
            TransferHelper.safeTransfer(address(BankX), msg.sender, BankXAmount);
        }
        
        if(redeemCollateralBalances[msg.sender] > 0){
            CollateralDollarAmount = redeemCollateralBalances[msg.sender];
            CollateralAmount = (CollateralDollarAmount*1e6)/XSD.eth_usd_price();
            redeemCollateralBalances[msg.sender] = 0;
            unclaimedPoolCollateral = unclaimedPoolCollateral-CollateralDollarAmount;
            IWBNB(WETH).withdraw(CollateralAmount); //try to unwrap eth in the redeem
            TransferHelper.safeTransferETH(msg.sender, CollateralAmount);
        }
        lastPriceCheck[msg.sender].pricecheck = false;
    }

    // Function can be called by an BankX holder to have the protocol buy back BankX with excess collateral value from a desired collateral pool
    // This can also happen if the collateral ratio > 1
    // add XSD as a burn option while uXSD value is positive
    // need two seperate functions: one for bankx and one for XSD
    function buyBackBankX(uint256 BankX_amount,uint256 COLLATERAL_out_min) external{
        require(!buyback_paused, "Buyback Paused");
        require(((lastPriceCheck[msg.sender].lastpricecheck+(block_delay)) <= block.number) && (lastPriceCheck[msg.sender].pricecheck), "Must wait for block_delay blocks before collecting redemption");
        CollateralPoolLibrary.BuybackBankX_Params memory input_params = CollateralPoolLibrary.BuybackBankX_Params(
            availableExcessCollatDV(),
            bankx_price,
            XSD.eth_usd_price(),
            BankX_amount
        );

        (collateral_equivalent_d18) = (CollateralPoolLibrary.calcBuyBackBankX(input_params));

        require(COLLATERAL_out_min <= collateral_equivalent_d18, "Slippage limit reached");
        lastPriceCheck[msg.sender].pricecheck = false;
        // Give the sender their desired collateral and burn the BankX
        BankX.pool_burn_from(msg.sender, BankX_amount);
        TransferHelper.safeTransfer(address(WETH), address(this), collateral_equivalent_d18);
        IWBNB(WETH).withdraw(collateral_equivalent_d18);
        TransferHelper.safeTransferETH(msg.sender, collateral_equivalent_d18);
    }
    //buyback with XSD instead of bankx
    function buyBackXSD(uint256 XSD_amount, uint256 collateral_out_min) external {
        require(!buyback_paused, "Buyback Paused");
        require(((lastPriceCheck[msg.sender].lastpricecheck+(block_delay)) <= block.number) && (lastPriceCheck[msg.sender].pricecheck), "Must wait for block_delay blocks before collecting redemption");
        if(XSD_amount != 0) require((XSD.totalSupply()+XSD_amount)>collat_XSD, "uXSD MUST BE POSITIVE");

        CollateralPoolLibrary.BuybackXSD_Params memory input_params = CollateralPoolLibrary.BuybackXSD_Params(
            availableExcessCollatDV(),
            xsd_price,
            XSD.eth_usd_price(),
            XSD_amount
        );

        (collateral_equivalent_d18) = (CollateralPoolLibrary.calcBuyBackXSD(input_params));

        require(collateral_out_min <= collateral_equivalent_d18, "Slippage limit reached");
        lastPriceCheck[msg.sender].pricecheck = false;
        XSD.pool_burn_from(msg.sender, XSD_amount);
        TransferHelper.safeTransfer(address(WETH), address(this), collateral_equivalent_d18);
        IWBNB(WETH).withdraw(collateral_equivalent_d18);
        TransferHelper.safeTransferETH(msg.sender, collateral_equivalent_d18);
    }

    // Combined into one function due to 24KiB contract memory limit
    function setPoolParameters(uint256 new_block_delay, bool _mint_paused, bool _redeem_paused, bool _buyback_paused) external onlyByOwner {
        block_delay = new_block_delay;
        mint_paused = _mint_paused;
        redeem_paused = _redeem_paused;
        buyback_paused = _buyback_paused;
        emit PoolParametersSet(new_block_delay);
    }

    function setPIDController(address new_pid_address) external onlyByOwner {
        pid_controller = IPIDController(new_pid_address);
        pid_address = new_pid_address;
    }
    function setSmartContractOwner(address _smartcontract_owner) external{
        require(msg.sender == smartcontract_owner, "Only the smart contract owner can access this function");
        require(msg.sender != address(0), "Zero address detected");
        smartcontract_owner = _smartcontract_owner;
    }

    function renounceOwnership() external{
        require(msg.sender == smartcontract_owner, "Only the smart contract owner can access this function");
        smartcontract_owner = address(0);
    }

    function resetAddresses(address _xsd_contract_address,
        address _bankx_contract_address,
        address _bankxweth_pool,
        address _xsdweth_pool,
        address _WETH) external{
        require(msg.sender == smartcontract_owner, "Only the smart contract owner can access this function");
        require(
            (_xsd_contract_address != address(0))
            && (_bankx_contract_address != address(0))
            && (_WETH != address(0))
            && (_bankxweth_pool != address(0))
            && (_xsdweth_pool != address(0))
        , "Zero address detected"); 
        XSD = XSDStablecoin(_xsd_contract_address);
        BankX = BankXToken(_bankx_contract_address);
        xsd_contract_address = _xsd_contract_address;
        bankx_contract_address = _bankx_contract_address;
        xsdweth_pool = _xsdweth_pool;
        bankxweth_pool = _bankxweth_pool;
        WETH = _WETH;
    }

    /* ========== EVENTS ========== */

    event PoolParametersSet(uint256 new_block_delay);

}
pragma solidity ^0.8.0;

import "./IERC20.sol";
import "./extensions/IERC20Metadata.sol";
import "../../utils/Context.sol";

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
contract ERC20 is Context, IERC20, IERC20Metadata {
    mapping(address => uint256) private _balances;

    mapping(address => mapping(address => uint256)) private _allowances;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;

    /**
     * @dev Sets the values for {name} and {symbol}.
     *
     * The default value of {decimals} is 18. To select a different value for
     * {decimals} you should overload it.
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
        return 18;
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
        _approve(owner, spender, allowance(owner, spender) + addedValue);
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
        uint256 currentAllowance = allowance(owner, spender);
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        unchecked {
            _approve(owner, spender, currentAllowance - subtractedValue);
        }

        return true;
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

        _beforeTokenTransfer(from, to, amount);

        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _balances[from] = fromBalance - amount;
        }
        _balances[to] += amount;

        emit Transfer(from, to, amount);

        _afterTokenTransfer(from, to, amount);
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

        _beforeTokenTransfer(address(0), account, amount);

        _totalSupply += amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);

        _afterTokenTransfer(address(0), account, amount);
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
        }
        _totalSupply -= amount;

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
    ) internal virtual {}

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
    ) internal virtual {}
}
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/Context.sol";
import "./IBEP20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

// Due to compiling issues, _name, _symbol, and _decimals were removed


/**
 * @dev Implementation of the {IBEP20} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
 * For a generic mechanism see {BEP20Mintable}.
 *
 * TIP: For a detailed writeup see our guide
 * https://forum.zeppelin.solutions/t/how-to-implement-BEP20-supply-mechanisms/226[How
 * to implement supply mechanisms].
 *
 * We have followed general OpenZeppelin guidelines: functions revert instead
 * of returning `false` on failure. This behavior is nonetheless conventional
 * and does not conflict with the expectations of BEP20 applications.
 *
 * Additionally, an {Approval} event is emitted on calls to {transferFrom}.
 * This allows applications to reconstruct the allowance for all accounts just
 * by listening to said events. Other implementations of the EIP may not emit
 * these events, as it isn't required by the specification.
 *
 * Finally, the non-standard {decreaseAllowance} and {increaseAllowance}
 * functions have been added to mitigate the well-known issues around setting
 * allowances. See {IBEP20-approve}.
 */
contract BEP20Custom is Context, IBEP20 {
    using SafeMath for uint256;

    mapping (address => uint256) internal _balances;

    mapping (address => mapping (address => uint256)) internal _allowances;

    uint256 private _totalSupply;
    /**
     * @dev See {IBEP20-totalSupply}.
     */
    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IBEP20-balanceOf}.
     */
    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev See {IBEP20-transfer}.
     *
     * Requirements:
     *
     * - `recipient` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     */
    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, amount);
        return true;
    }

    /**
     * @dev See {IBEP20-allowance}.
     */
    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @dev See {IBEP20-approve}.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.approve(address spender, uint256 amount)
     */
    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, amount);
        return true;
    }

    /**
     * @dev See {IBEP20-transferFrom}.
     *
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP. See the note at the beginning of {BEP20}.
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
            require(currentAllowance >= amount, "BEP20: insufficient allowance");
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }

    /**
     * @dev Atomically increases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IBEP20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, allowance(owner, spender) + addedValue);
        return true;
    }

    /**
     * @dev Atomically decreases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IBEP20-approve}.
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
        uint256 currentAllowance = allowance(owner, spender);
        require(currentAllowance >= subtractedValue, "BEP20: decreased allowance below zero");
        unchecked {
            _approve(owner, spender, currentAllowance - subtractedValue);
        }

        return true;
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
    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(from != address(0), "BEP20: transfer from the zero address");
        require(to != address(0), "BEP20: transfer to the zero address");

        _beforeTokenTransfer(from, to, amount);

        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "BEP20: transfer amount exceeds balance");
        unchecked {
            _balances[from] = fromBalance - amount;
        }
        _balances[to] += amount;

        emit Transfer(from, to, amount);

        _afterTokenTransfer(from, to, amount);
    }

    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements
     *
     * - `to` cannot be the zero address.
     */
    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "BEP20: mint to the zero address");

        _beforeTokenTransfer(address(0), account, amount);

        _totalSupply += amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);

        _afterTokenTransfer(address(0), account, amount);
    }

    /**
     * @dev Destroys `amount` tokens from the caller.
     *
     * See {BEP20-_burn}.
     */
    function burn(uint256 amount) public virtual {
        _burn(_msgSender(), amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, deducting from the caller's
     * allowance.
     *
     * See {BEP20-_burn} and {BEP20-allowance}.
     *
     * Requirements:
     *
     * - the caller must have allowance for `accounts`'s tokens of at least
     * `amount`.
     */
    function burnFrom(address account, uint256 amount) public virtual {
        uint256 decreasedAllowance = allowance(account, _msgSender()).sub(amount, "BEP20: burn amount exceeds allowance");

        _approve(account, _msgSender(), decreasedAllowance);
        _burn(account, amount);
    }


    /**
     * @dev Transfers 'tokens' from 'account' to origin address, reducing the
     * total supply.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * Requirements
     *
     * - `account` cannot be the zero address.
     * - `account` must have at least `amount` tokens.
     */
    function _burn(address account, uint256 amount) internal virtual {
       require(account != address(0), "BEP20: burn from the zero address");

        _beforeTokenTransfer(account, address(0), amount);

        uint256 accountBalance = _balances[account];
        require(accountBalance >= amount, "BEP20: burn amount exceeds balance");
        unchecked {
            _balances[account] = accountBalance - amount;
        }
        _totalSupply -= amount;

        emit Transfer(account, address(0), amount);

        _afterTokenTransfer(account, address(0), amount);
        
    }

    /**
     * @dev Sets `amount` as the allowance of `spender` over the `owner`s tokens.
     *
     * This is internal function is equivalent to `approve`, and can be used to
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
        require(owner != address(0), "BEP20: approve from the zero address");
        require(spender != address(0), "BEP20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`.`amount` is then deducted
     * from the caller's allowance.
     *
     * See {_burn} and {_approve}.
     */
    function _burnFrom(address account, uint256 amount) internal virtual {
        _burn(account, amount);
        _approve(account, _msgSender(), _allowances[account][_msgSender()].sub(amount, "BEP20: burn amount exceeds allowance"));
    }

    /**
     * @dev Hook that is called before any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of `from`'s tokens
     * will be to transferred to `to`.
     * - when `from` is zero, `amount` tokens will be minted for `to`.
     * - when `to` is zero, `amount` of `from`'s tokens will be burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:using-hooks.adoc[Using Hooks].
     */
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual { }
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
    ) internal virtual {}
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


import "../BEP20/BEP20Custom.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "../BEP20/IBEP20.sol";
import "../XSD/XSDStablecoin.sol";

contract BankXToken is BEP20Custom {

    /* ========== STATE VARIABLES ========== */

    string public symbol;
    string public name;
    uint8 public constant decimals = 18;
    
    
    uint256 public genesis_supply; // 2B is printed upon genesis
    address public pool_address; //points to BankX pool address
    address public treasury; //stores the genesis supply
    address public router;
    XSDStablecoin private XSD; //XSD stablecoin instance
    address public smartcontract_owner;
    /* ========== MODIFIERS ========== */

    modifier onlyPools() {
       require(XSD.xsd_pools(msg.sender) == true, "Only xsd pools can mint new BankX");
        _;
    } 
    
    modifier onlyByOwner() {
        require(msg.sender == smartcontract_owner, "You are not an owner");
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _pool_amount, 
        uint256 _genesis_supply,
        address _treasury,
        address _smartcontract_owner
    ) {
        require((_treasury != address(0)), "Zero address detected"); 
        name = _name;
        symbol = _symbol;
        genesis_supply = _genesis_supply + _pool_amount;
        treasury = _treasury;
        _mint(_msgSender(), _pool_amount);
        _mint(treasury, _genesis_supply);
        smartcontract_owner = _smartcontract_owner;

    
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setPool(address new_pool) external onlyByOwner {
        require(new_pool != address(0), "Zero address detected");

        pool_address = new_pool;
    }

    function setTreasury(address new_treasury) external onlyByOwner {
        require(new_treasury != address(0), "Treasury address cannot be 0");
        treasury = new_treasury;
    }

    function setRouterAddress(address _router) external onlyByOwner {
        require(_router != address(0), "Zero address detected");
        router = _router;
    }
    
    function setXSDAddress(address xsd_contract_address) external onlyByOwner {
        require(xsd_contract_address != address(0), "Zero address detected");

        XSD = XSDStablecoin(xsd_contract_address);

        emit XSDAddressSet(xsd_contract_address);
    }
    
    function mint(address to, uint256 amount) public onlyPools {
        _mint(to, amount);
        emit BankXMinted(address(this), to, amount);
    }
    
    function genesisSupply() public view returns(uint256){
        return genesis_supply;
    }

    // This function is what other xsd pools will call to mint new BankX (similar to the XSD mint) 
    function pool_mint(address m_address, uint256 m_amount) external onlyPools  {        
        super._mint(m_address, m_amount);
        emit BankXMinted(address(this), m_address, m_amount);
    }

    // This function is what other xsd pools will call to burn BankX 
    function pool_burn_from(address b_address, uint256 b_amount) external onlyPools {

        super._burnFrom(b_address, b_amount);
        emit BankXBurned(b_address, address(this), b_amount);
    }
    //burn bankx from the pool when bankx is inflationary
    function burnpoolBankX(uint _bankx_amount) public {
        require(msg.sender == router, "Only Router can access this function");
        require(totalSupply()>genesis_supply,"BankX must be deflationary");
        super._burn(pool_address, _bankx_amount);
        IBankXWETHpool(pool_address).sync();
        emit BankXBurned(msg.sender, address(this), _bankx_amount);
    }

    function setSmartContractOwner(address _smartcontract_owner) external{
        require(msg.sender == smartcontract_owner, "Only the smart contract owner can access this function");
        require(msg.sender != address(0), "Zero address detected");
        smartcontract_owner = _smartcontract_owner;
    }

    function renounceOwnership() external{
        require(msg.sender == smartcontract_owner, "Only the smart contract owner can access this function");
        smartcontract_owner = address(0);
    }
    /* ========== EVENTS ========== */

    // Track BankX burned
    event BankXBurned(address indexed from, address indexed to, uint256 amount);

    // Track BankX minted
    event BankXMinted(address indexed from, address indexed to, uint256 amount);
    event XSDAddressSet(address addr);
}
pragma solidity ^0.8.0;

interface IPIDController{
    function bucket1() external view returns (bool);
    function bucket2() external view returns (bool);
    function bucket3() external view returns (bool);
    function diff1() external view returns (uint);
    function diff2() external view returns (uint);
    function diff3() external view returns (uint);
    function amountpaid1() external view returns (uint);
    function amountpaid2() external view returns (uint);
    function amountpaid3() external view returns (uint);
    function bankx_arbi_limit() external view returns (uint);
    function xsd_arbi_limit() external view returns (uint);
    function bankx_burnable_limit() external view returns (uint);
    function xsd_burnable_limit() external view returns (uint);
    function amountPaidBankXWETH(uint bnbvalue) external;
    function amountPaidXSDWETH(uint bnbvalue) external;
    function amountPaidCollateralPool(uint bnbvalue) external;
}
pragma solidity ^0.8.0;

// a library for handling binary fixed point numbers (https://en.wikipedia.org/wiki/Q_(number_format))

// range: [0, 2**112 - 1]
// resolution: 1 / 2**112

library UQ112x112 {
    uint224 constant Q112 = 2**112;

    // encode a uint112 as a UQ112x112
    function encode(uint112 y) internal pure returns (uint224 z) {
        z = uint224(y) * Q112; // never overflows
    }

    // divide a UQ112x112 by a uint112, returning a UQ112x112
    function uqdiv(uint224 x, uint112 y) internal pure returns (uint224 z) {
        z = x / uint224(y);
    }
}
pragma solidity ^0.8.0;

import "../IERC20.sol";
import "../../../utils/Address.sol";

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

    function safeTransfer(
        IERC20 token,
        address to,
        uint256 value
    ) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    function safeTransferFrom(
        IERC20 token,
        address from,
        address to,
        uint256 value
    ) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }

    /**
     * @dev Deprecated. This function has issues similar to the ones found in
     * {IERC20-approve}, and its usage is discouraged.
     *
     * Whenever possible, use {safeIncreaseAllowance} and
     * {safeDecreaseAllowance} instead.
     */
    function safeApprove(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        // safeApprove should only be called when setting an initial allowance,
        // or when resetting it to zero. To increase and decrease it, use
        // 'safeIncreaseAllowance' and 'safeDecreaseAllowance'
        require(
            (value == 0) || (token.allowance(address(this), spender) == 0),
            "SafeERC20: approve from non-zero to non-zero allowance"
        );
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, value));
    }

    function safeIncreaseAllowance(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        uint256 newAllowance = token.allowance(address(this), spender) + value;
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
    }

    function safeDecreaseAllowance(
        IERC20 token,
        address spender,
        uint256 value
    ) internal {
        unchecked {
            uint256 oldAllowance = token.allowance(address(this), spender);
            require(oldAllowance >= value, "SafeERC20: decreased allowance below zero");
            uint256 newAllowance = oldAllowance - value;
            _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
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
        // we're implementing it ourselves. We use {Address.functionCall} to perform this call, which verifies that
        // the target address contains contract code and also asserts for success in the low-level call.

        bytes memory returndata = address(token).functionCall(data, "SafeERC20: low-level call failed");
        if (returndata.length > 0) {
            // Return data is optional
            require(abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
        }
    }
}
pragma solidity ^0.8.0;

/**
 * @dev Standard math utilities missing in the Solidity language.
 */
library Math {
    /**
     * @dev Returns the largest of two numbers.
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }

    /**
     * @dev Returns the smallest of two numbers.
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @dev Returns the average of two numbers. The result is rounded towards
     * zero.
     */
    function average(uint256 a, uint256 b) internal pure returns (uint256) {
        // (a + b) / 2 can overflow.
        return (a & b) + (a ^ b) / 2;
    }

    /**
     * @dev Returns the ceiling of the division of two numbers.
     *
     * This differs from standard division with `/` in that it rounds up instead
     * of rounding down.
     */
    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        // (a + b - 1) / b can overflow on addition, so we distribute.
        return a / b + (a % b == 0 ? 0 : 1);
    }
}
pragma solidity ^0.8.0;

interface IRewardManager {
function creatorProvideBankXLiquidity() external;
function creatorProvideXSDLiquidity() external;
function userProvideBankXLiquidity(address to) external;
function userProvideXSDLiquidity(address to) external;
function userProvideCollatPoolLiquidity(address to, uint amount) external;
function LiquidityRedemption(address pool,address to) external;
}
pragma solidity ^0.8.0;

interface ICD{
    function allocatedSupply() external view returns (uint256);
}
pragma solidity ^0.8.0;

interface BankXInterface {

    function balanceOf(address account) external view returns (uint256);

    function pool_mint(address _entity, uint _amount) external;

    function pool_burn_from(address _entity, uint _amount) external;

    function genesis_supply() external returns (uint);

    function totalSupply() external view returns (uint);

    function updateTVLReached() external;

}
pragma solidity ^0.8.0;

interface ICollateralpool{
    function userProvideLiquidity(address to, uint amount1) external;
    function collat_XSD() external returns(uint);
    function collatDollarBalance() external view returns (uint256);
}
pragma solidity ^0.8.0;


library CollateralPoolLibrary {
    // ================ Structs ================
    // Needed to lower stack size
    struct MintFF_Params {
        uint256 bankx_price_usd; 
        uint256 col_price_usd;
        uint256 bankx_amount;
        uint256 collateral_amount;
        uint256 col_ratio;
    }

    struct BuybackBankX_Params {
        uint256 excess_collateral_dollar_value_d18;
        uint256 bankx_price_usd;
        uint256 col_price_usd;
        uint256 BankX_amount;
    }

    struct BuybackXSD_Params {
        uint256 excess_collateral_dollar_value_d18;
        uint256 xsd_price_usd;
        uint256 col_price_usd;
        uint256 XSD_amount;
    }



    // ================ Functions ================
// xsd is at the price of one gram of silver.
    function calcMint1t1XSD(uint256 col_price, uint256 silver_price, uint256 collateral_amount_d18) public pure returns (uint256) {
        uint256 gram_price = (silver_price*(1e4))/(311035);
        return (collateral_amount_d18*(col_price))/(gram_price); 
    }
// xsd is at the price of one gram of silver
    function calcMintAlgorithmicXSD(uint256 bankx_price_usd, uint256 silver_price, uint256 bankx_amount_d18) public pure returns (uint256) {
        uint256 gram_price = (silver_price*(1e4))/(311035);
        return (bankx_amount_d18*bankx_price_usd)/(gram_price);
    }
//new-code-start
    function calcMintInterest(uint256 XSD_amount,uint256 silver_price,uint256 rate, uint256 accum_interest, uint256 interest_rate, uint256 time, uint256 amount) internal view returns(uint256, uint256, uint256, uint256) {
        uint256 gram_price = (silver_price*(1e4))/(311035);
        if(time == 0){
        interest_rate = rate;
        amount = XSD_amount;
        time = block.timestamp;
        }
        else{
        uint delta_t = block.timestamp - time;
        delta_t = delta_t/(86400); //1 day = 86400
        accum_interest = accum_interest+((amount*gram_price*interest_rate*delta_t)/(365*(1e12)));
        interest_rate = (amount*interest_rate) + (XSD_amount*rate);//weighted average interest calculation is in two parts
        amount = amount+XSD_amount;
        interest_rate = interest_rate/amount;//second part
        time = block.timestamp;
        }
        return (
            accum_interest,
            interest_rate,
            time, 
            amount
        );
    }

    function calcRedemptionInterest(uint256 XSD_amount,uint256 silver_price, uint256 accum_interest, uint256 interest_rate, uint256 time, uint256 amount) internal view returns(uint256, uint256, uint256, uint256){
        uint256 gram_price = (silver_price*(1e4))/(311035);
        uint delta_t = block.timestamp - time;
        delta_t = delta_t/(86400);
        accum_interest = accum_interest+((amount*gram_price*interest_rate*delta_t)/(365*(1e12)));
        amount = amount - XSD_amount;
        time = block.timestamp;
        return (
            accum_interest,
            interest_rate,
            time, 
            amount
        );
    }
    //new-code-end
    // Must be internal because of the struct
    // xsd must be the dollar value of one price of silver
    function calcMintFractionalXSD(MintFF_Params memory params) internal pure returns (uint256, uint256) {
        // Since solidity truncates division, every division operation must be the last operation in the equation to ensure minimum error
        // The contract must check the proper ratio was sent to mint XSD. We do this by seeing the minimum mintable XSD based on each amount 
        uint256 bankx_dollar_value_d18;
        uint256 c_dollar_value_d18;
        
        // Scoping for stack concerns
        {    
            // USD amounts of the collateral and the BankX
            bankx_dollar_value_d18 = params.bankx_amount*(params.bankx_price_usd)/(1e6);
            c_dollar_value_d18 = params.collateral_amount*(params.col_price_usd)/(1e6);

        }
        uint calculated_bankx_dollar_value_d18 = 
                    (c_dollar_value_d18*(1e6)/(params.col_ratio))
                    -(c_dollar_value_d18);

        uint calculated_bankx_needed = calculated_bankx_dollar_value_d18*(1e6)/(params.bankx_price_usd);

        return (
            (c_dollar_value_d18+calculated_bankx_dollar_value_d18),
            calculated_bankx_needed
        );
    }

    function calcRedeem1t1XSD(uint256 col_price_usd,uint256 silver_price, uint256 XSD_amount) public pure returns (uint256,uint256) {
        uint256 gram_price = (silver_price*(1e4))/(311035);
        return ((XSD_amount*gram_price/1e6),((XSD_amount*gram_price)/col_price_usd));
    }

    // Must be internal because of the struct
    function calcBuyBackBankX(BuybackBankX_Params memory params) internal pure returns (uint256) {
        // If the total collateral value is higher than the amount required at the current collateral ratio then buy back up to the possible BankX with the desired collateral
        require(params.excess_collateral_dollar_value_d18 > 0, "No excess collateral to buy back!");

        // Make sure not to take more than is available
        uint256 bankx_dollar_value_d18 = (params.BankX_amount*params.bankx_price_usd);
        require((bankx_dollar_value_d18/1e6) <= params.excess_collateral_dollar_value_d18, "You are trying to buy back more than the excess!");

        // Get the equivalent amount of collateral based on the market value of BankX provided 
        uint256 collateral_equivalent_d18 = (bankx_dollar_value_d18)/(params.col_price_usd);

        return (
            collateral_equivalent_d18
        );

    }

    function calcBuyBackXSD(BuybackXSD_Params memory params) internal pure returns (uint256) {
        require(params.excess_collateral_dollar_value_d18 > 0, "No excess collateral to buy back!");

        uint256 xsd_dollar_value_d18 = params.XSD_amount*(params.xsd_price_usd);
        require((xsd_dollar_value_d18/1e6) <= params.excess_collateral_dollar_value_d18, "You are trying to buy more than the excess!");

        uint256 collateral_equivalent_d18 = (xsd_dollar_value_d18)/(params.col_price_usd);

        return (
            collateral_equivalent_d18
        );
    }

}
pragma solidity ^0.8.0;

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
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and making it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        // On the first call to nonReentrant, _notEntered will be true
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");

        // Any calls to nonReentrant after this point will fail
        _status = _ENTERED;

        _;

        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = _NOT_ENTERED;
    }
}
pragma solidity ^0.8.0;

interface AggregatorV3Interface {

  function decimals() external view returns (uint8);
  function description() external view returns (string memory);
  function version() external view returns (uint256);

  // getRoundData and latestRoundData should both raise "No data present"
  // if they do not have data to report, instead of returning unset values
  // which could be misinterpreted as actual reported values.
  function getRoundData(uint80 _roundId)
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );
  function latestRoundData()
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );

}
pragma solidity ^0.8.0;


interface IBEP20 {
  /**
   * @dev Returns the amount of tokens in existence.
   */
  function totalSupply() external view returns (uint256);

  /**
   * @dev Returns the amount of tokens owned by `account`.
   */
  function balanceOf(address account) external view returns (uint256);

  /**
   * @dev Moves `amount` tokens from the caller's account to `recipient`.
   *
   * Returns a boolean value indicating whether the operation succeeded.
   *
   * Emits a {Transfer} event.
   */
  function transfer(address recipient, uint256 amount) external returns (bool);

  /**
   * @dev Returns the remaining number of tokens that `spender` will be
   * allowed to spend on behalf of `owner` through {transferFrom}. This is
   * zero by default.
   *
   * This value changes when {approve} or {transferFrom} are called.
   */
  function allowance(address _owner, address spender) external view returns (uint256);

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
   * @dev Moves `amount` tokens from `sender` to `recipient` using the
   * allowance mechanism. `amount` is then deducted from the caller's
   * allowance.
   *
   * Returns a boolean value indicating whether the operation succeeded.
   *
   * Emits a {Transfer} event.
   */
  function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

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

// CAUTION
// This version of SafeMath should only be used with Solidity 0.8 or later,
// because it relies on the compiler's built in overflow checks.

/**
 * @dev Wrappers over Solidity's arithmetic operations.
 *
 * NOTE: `SafeMath` is generally not needed starting with Solidity 0.8, since the compiler
 * now has built in overflow checking.
 */
library SafeMath {
    /**
     * @dev Returns the addition of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function tryAdd(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            uint256 c = a + b;
            if (c < a) return (false, 0);
            return (true, c);
        }
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function trySub(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b > a) return (false, 0);
            return (true, a - b);
        }
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function tryMul(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
            // benefit is lost if 'b' is also tested.
            // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
            if (a == 0) return (true, 0);
            uint256 c = a * b;
            if (c / a != b) return (false, 0);
            return (true, c);
        }
    }

    /**
     * @dev Returns the division of two unsigned integers, with a division by zero flag.
     *
     * _Available since v3.4._
     */
    function tryDiv(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b == 0) return (false, 0);
            return (true, a / b);
        }
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers, with a division by zero flag.
     *
     * _Available since v3.4._
     */
    function tryMod(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b == 0) return (false, 0);
            return (true, a % b);
        }
    }

    /**
     * @dev Returns the addition of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `+` operator.
     *
     * Requirements:
     *
     * - Addition cannot overflow.
     */
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        return a + b;
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting on
     * overflow (when the result is negative).
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     *
     * - Subtraction cannot overflow.
     */
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a - b;
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `*` operator.
     *
     * Requirements:
     *
     * - Multiplication cannot overflow.
     */
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b;
    }

    /**
     * @dev Returns the integer division of two unsigned integers, reverting on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator.
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return a / b;
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * reverting when dividing by zero.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        return a % b;
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting with custom message on
     * overflow (when the result is negative).
     *
     * CAUTION: This function is deprecated because it requires allocating memory for the error
     * message unnecessarily. For custom revert reasons use {trySub}.
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     *
     * - Subtraction cannot overflow.
     */
    function sub(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        unchecked {
            require(b <= a, errorMessage);
            return a - b;
        }
    }

    /**
     * @dev Returns the integer division of two unsigned integers, reverting with custom message on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator. Note: this function uses a
     * `revert` opcode (which leaves remaining gas untouched) while Solidity
     * uses an invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function div(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        unchecked {
            require(b > 0, errorMessage);
            return a / b;
        }
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * reverting with custom message when dividing by zero.
     *
     * CAUTION: This function is deprecated because it requires allocating memory for the error
     * message unnecessarily. For custom revert reasons use {tryMod}.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function mod(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        unchecked {
            require(b > 0, errorMessage);
            return a % b;
        }
    }
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
pragma solidity ^0.8.0;

import "../IERC20.sol";

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
