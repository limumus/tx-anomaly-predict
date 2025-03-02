pragma solidity 0.6.12;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
   
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

contract Ownable {
    address public owner;

    constructor () public{
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(owner == msg.sender, "Ownable: caller is not the owner");
        _;
    }

    function transferOwnership(address newOwner) public onlyOwner {
        owner = newOwner;
    }
}

contract WILL is IERC20, Ownable {

    mapping (address => uint256) private _balances;
    mapping (address => mapping (address => uint256)) private _allowances;
    uint256 private _totalSupply;

    mapping (address => bool) public pairs;
    address public dappAddress = 0x719a516a38d8711477E6c47Bf70ab3bd52Cb52Ab;

    constructor() public {
        uint256 total = 18000000 * 10**18;
        _totalSupply = total;
        _balances[msg.sender] = total;
        emit Transfer(address(0), msg.sender, total);
    }

    function name() public pure returns (string memory) {
        return "WILL";
    }

    function symbol() public pure returns (string memory) {
        return "WILL";
    }

    function decimals() public pure returns (uint8) {
        return 18;
    }

    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _transfer(sender, recipient, amount);

        uint256 currentAllowance = _allowances[sender][msg.sender];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        _approve(sender, msg.sender, currentAllowance - amount);

        return true;
    }

    function _transfer(address sender, address recipient, uint256 amount) internal {

        uint256 senderBalance = _balances[sender];
        require(senderBalance >= amount, "ERC20: transfer amount exceeds balance");
        _balances[sender] = senderBalance - amount;
        
        uint256 receiveAmount = amount;
        if(pairs[sender] || pairs[recipient]) {
            uint256 dappAmount = amount * 2 / 100; // 2% DApp费用
            _transferNormal(sender, dappAddress, dappAmount); // 转账2% DApp费用到 dappAddress
            receiveAmount -= dappAmount; // 更新接收方应接收的金额
        }

        _transferNormal(sender, recipient, receiveAmount);
    }

    function _transferNormal(address sender, address recipient, uint256 amount) private {
        if(recipient == address(0)){
            _totalSupply -= amount;
        }else {
            _balances[recipient] += amount;
        }
        emit Transfer(sender, recipient, amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function setPair(address _pair, bool b) external onlyOwner {
        pairs[_pair] = b;
    }

    // 修改 dappAddress 的函数
    function setDappAddress(address newDappAddress) public onlyOwner {
        require(newDappAddress != address(0), "New dapp address cannot be the zero address");
        dappAddress = newDappAddress;
    }
}
