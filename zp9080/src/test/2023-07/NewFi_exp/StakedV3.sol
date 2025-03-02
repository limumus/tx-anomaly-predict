pragma solidity ^0.8.10;

import "./Ownable.sol";
import "./TransferHelper.sol";
import "./SafeMath.sol";
import "./SafeCast.sol";
import "./ECDSA.sol";
import "./IERC20.sol";
import "./ReentrancyGuard.sol";
import "./Address.sol";


import "./ISwapRouter.sol";
import "./IQuoterV2.sol";


import "./IUniswapV3Pool.sol";
import "./IPancakeV3LmPool.sol";
import "./IUniswapV3Factory.sol";

import "./IMasterChefV3.sol";

import "./ICompute.sol";
import "./INonfungiblePositionManager.sol";
import "./IWETH9.sol";
import "./IAssets.sol";


contract StakedV3 is Ownable,ReentrancyGuard {
	using SafeMath for uint256;
	using SafeCast for uint256;
	
	
	address public route;
	address public quotev2;
	address public compute;
	address public assets;

	address public factory;
	address public weth;
	address public manage;

	uint public fee;
	

	struct pool {
		address token0; 		//质押币种合约地址
		address token1;		//另一种币种合约地址
		address pool;		//pool 合约地址
		address farm;		//farm 地址
		uint24 fee;			//pool手续费
		uint point;			//滑点
		bool inStatus;		//是否开启质押
		bool outStatus;		//是否可以提取
		uint tokenId;		//质押的nft tokenId
		uint wight0;
		uint wight1;
		uint lp0;
		uint lp1;
	}

	// 是否自动进行Farm
	mapping(uint => bool) public isFarm;
	// 滑点最大比率 * 2
	uint private pointMax = 10 ** 8;
	// 项目库
	mapping(uint => pool) public pools;

	event VerifyUpdate(address signer);
	event Setting(address route,address quotev2,address compute,address factory,address weth,address manage);
	event InvestToken(uint pid,address user,uint amount,uint investType,uint cycle,uint time);
	event ExtractToken(uint pid,address user,address token,uint amount,uint fee,uint tradeType,uint time);

	constructor (
		address _route,
		address _quotev2,
		address _compute,
		address _assets,
		uint _fee
	) {
		_setting(_route,_quotev2,_compute,_assets,_fee);
	}

	// 接收ETH NFT
    receive() external payable {}
    fallback() external payable {}
	function onERC1155Received(address, address, uint256, uint256, bytes memory) public virtual returns (bytes4) {
        return this.onERC1155Received.selector;
    }
    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory) public virtual returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
    function onERC721Received(address, address, uint256, bytes memory) public virtual returns (bytes4) {
        return this.onERC721Received.selector;
    }

	function _tokenSend(
        address _token,
        uint _amount
    ) private returns (bool result) {
        if(_token == address(0)){
            Address.sendValue(payable(msg.sender),_amount);
            result = true;
        }else{
            IERC20 token = IERC20(_token);
            result = token.transfer(msg.sender,_amount);
        }
    }

	function balanceOf(
		address _token
	) public view returns (uint balance) {
		if(_token == weth) {
			balance = address(this).balance;
		}else {
			IERC20 token = IERC20(_token);
            balance = token.balanceOf(address(this));
		}
	}

	function unWrapped() private {
		IERC20 token = IERC20(weth);
        uint balance = token.balanceOf(address(this));
		if(balance > 0) {
			IWETH9(weth).withdraw(balance);
		}
	}

	function pointHandle(
		uint point,
		uint amount,
		bool isplus
	) private view returns (uint result) {
		uint rate = 1;
		if(isplus) {
			rate = pointMax.add(point);
		}else {
			rate = pointMax.sub(point);
		}
		result = amount.mul(rate).div(pointMax);
	}

	function abs(
		int x
	) private pure returns (int) {
		return x >= 0 ? x : -x;
	}

	// Balance check attempted to distribute and returned whether the distribution was successful
	function extractAmount(
		address token,
		uint amount
	) private returns (bool) {
		uint balance = balanceOf(token);
		// Is the platform's storage sufficient for direct distribution
		if(balance >= amount) {
			if(token != weth) {
				require(_tokenSend(token,amount),"Staked::extract fail");
			}else {
				require(_tokenSend(address(0),amount),"Staked::extract fail");
			}
			return true;
		}else {
			return false;
		}
	}

	// Activate failed projects
	function Reboot(
		uint id,
		uint deadline
	) public onlyOwner {
		
		(bool pass,PoolToken memory tokens) = Challenge(id);
		if(!pass) {
			// Harvest income
			_harvest(id);
			// Remove all liquidity from the current project Farm
			_remove(id,tokens,deadline);

			// Exchange into pledged currency
			_reSwap(id,tokens);
			// Withdrawal of NFT
			_withdraw(id);

			// Update the latest currency price ratio
			wightReset(id);

			// Convert a single currency to two currencies for Farm
			uint amount0 = lpRate(id);
			(uint amountOut,) = _amountOut(id,pools[id].token0,pools[id].token1,amount0,false);

			Swap(id,pools[id].token0,pools[id].token1,amount0,amountOut,0);
			Mint(id,deadline);
		}
	}
	
	// Handling When Extracting Token Liquidity Fails
	function invalid(
		uint id,
		address token,
		uint amount,
		uint deadline,
		PoolToken memory tokens
	) private {
		// Harvest income
		_harvest(id);
		// Remove all liquidity from the current project Farm
		_remove(id,tokens,deadline);
		// bytes memory path;
		uint amountOut;
		uint balance;

		// Convert all to extraction currency
		if(tokens.token0 == token) {
			if(tokens.amount0 == 0) {
				(amountOut,balance) = _amountOut(id,tokens.token1,tokens.token0,0,true);
				Swap(id,tokens.token1,tokens.token0,balance,amountOut,0);
			}
		}else {
			if(tokens.amount1 == 0) {
				(amountOut,balance) = _amountOut(id,tokens.token0,tokens.token1,0,true);
				Swap(id,tokens.token0,tokens.token1,balance,amountOut,0);
			}
		}
		// Second attempt to distribute
		bool result = extractAmount(token,amount);
		require(result,"Staked::extraction failed (invalid:Insufficient reserves1)");
		// Withdrawal of NFT and Reset of Farm Pledge
		_withdraw(id);
		// Convert all to pledge currency
		if(pools[id].token0 != token) {
			(amountOut,balance) = _amountOut(id,pools[id].token1,pools[id].token0,0,true);
			Swap(id,pools[id].token1,pools[id].token0,balance,amountOut,0);
		}
		
		// Update the latest currency price ratio
		wightReset(id);

		// Convert a single currency to two currencies for Farm
		uint amount0 = lpRate(id);
		(amountOut,) = _amountOut(id,pools[id].token0,pools[id].token1,amount0,false);
		Swap(id,pools[id].token0,pools[id].token1,amount0,amountOut,0);
		Mint(id,deadline);
	}
	
	function wightReset(
		uint id
	) private {
		(uint amountOut,) = _amountOut(id,pools[id].token0,pools[id].token1,10 ** 18,false);
		pools[id].wight0 = 10 ** 18;
		pools[id].wight1 = amountOut;
	}

	function tryRun(
		uint id,
		address token,
		uint amount,
		uint deadline,
		PoolToken memory tokens,
		uint liquidity
	) private returns (bool) {
		
		if(tokens.liquidity > liquidity) {
			tokens.liquidity = uint128(liquidity);
		}else {
			tokens.liquidity = uint128(tokens.liquidity * 9999 / 10000);
		}
		require(tokens.liquidity > 0,"Staked::insufficient liquidity (valid)");
		(tokens.amount0,tokens.amount1) = ICompute(compute).getAmountsForLiquidity(tokens.sqrtPriceX96,tokens.sqrtRatioAX96,tokens.sqrtRatioBX96,tokens.liquidity);
		_remove(id,tokens,deadline);
		// Attempt to distribute
		bool result = extractAmount(token,amount);
		uint balance;
		if(!result) {
			if(token == tokens.token0) {
				balance = balanceOf(tokens.token1);
				tokens.amount1 = tokens.amount1 > balance ? balance : tokens.amount1;
				Swap(id,tokens.token1,tokens.token0,tokens.amount1,6,0);
			}else {
				balance = balanceOf(tokens.token0);
				tokens.amount0 = tokens.amount0 > balance ? balance : tokens.amount0;
				Swap(id,tokens.token0,tokens.token1,tokens.amount0,6,0);
			}
			// Attempt to distribute
			result = extractAmount(token,amount);
		}
		return result;
	}

	function valid(
		uint id,
		address token,
		uint amount,
		uint deadline,
		PoolToken memory tokens
	) private {
		uint liquidity;
		uint balance = balanceOf(token);
		uint temp = amount.sub(balance).div(2);
		temp = temp >= 1 ? temp : 1;

		if(token == tokens.token0 && tokens.amount0 > 0) {
			liquidity = tokens.liquidity * temp / tokens.amount0;
		}else if(tokens.amount1 > 0) {
			liquidity = tokens.liquidity * temp / tokens.amount1;
		}
		// Remove floating 2%
		uint upAmount = liquidity * 102 / 100;
		if(upAmount > tokens.liquidity) {
			liquidity = liquidity * 101 / 100;
		}else {
			liquidity = upAmount;
		}
		// The second and third times
		bool result = tryRun(id,token,amount,deadline,tokens,liquidity);

		if(!result) {
			balance = balanceOf(token);
			uint outAmount = amount.sub(balance).mul(102).div(100);
			(,tokens) = Challenge(id);
			liquidity = uint128(liquidity * outAmount / temp);
			// The fourth and fifth time
			result = tryRun(id,token,amount,deadline,tokens,liquidity);
		}
		
		require(result,"Staked::final extraction failed");
	}

	function lpExtract(
		uint id,
		address token,
		uint amount,
		uint deadline
	) private {
		require(pools[id].token0 == token || pools[id].token1 == token,"Staked::does not support decompression");
		// First attempt to distribute
		bool result = extractAmount(token,amount);
		
		if(!result) {
			require(pools[id].tokenId != 0,"Staked::insufficient liquidity (lpExtract)");
			(bool pass,PoolToken memory tokens) = Challenge(id);
			// Is liquidity ineffective
			if(pass) {
				valid(id,token,amount,deadline,tokens);
			}else {
				invalid(id,token,amount,deadline,tokens);
			}
			
		}
	}

	function unlpExtract(
		uint amount,
		address token
	) private {
		uint balance = balanceOf(token);
		if(token != weth) {
			require(balance >= amount,"Staked::insufficient funds reserves");
			require(_tokenSend(token,amount),"Staked::profit extract fail");
		}else {
			require(balance >= amount,"Staked::insufficient funds reserves");
			require(_tokenSend(address(0),amount),"Staked::profit extract fail");
		}
	}

	function Extract(
		uint id,
		uint tradeType,
		address token,
		uint amount,
		uint deadline
	) public nonReentrant {
		require(pools[id].outStatus,"Staked::extract closed");
		require(deadline > block.timestamp,"Staked::transaction lapsed");
		
		
		uint reduceAmount = amount;
		// Asset inspection
		amount = pointMax.sub(fee).mul(amount).div(pointMax);
		uint total = IAssets(assets).asset(msg.sender,id,token);
		require(total >= amount,"Staked::Overdrawing");

		// Is the income in the currency that constitutes lp
		if(pools[id].token0 == token) {
			lpExtract(id,token,amount,deadline);
		} else if(pools[id].token1 == token) {
			lpExtract(id,token,amount,deadline);
		} else {
			unlpExtract(amount,token);
		}
		// Accounting
		IAssets(assets).reduceAlone(msg.sender,id,token,reduceAmount);
		emit ExtractToken(id,msg.sender,token,amount,reduceAmount.sub(amount),tradeType,block.timestamp);
	}

	function Convert(
		address tokenIn,
		uint inAmount,
		uint outAmount,
		bytes memory path,
		uint side
	) public onlyOwner {
		_swap(tokenIn,inAmount,outAmount,path,side);
	}


	function pendingReward(
		uint id
	) public view returns (uint256 reward) {
		reward = IMasterChefV3(pools[id].farm).pendingCake(pools[id].tokenId);
	}

	function harvestFarm(
		uint id
	) public onlyOwner {
		_harvest(id);
	}
	function _harvest(
		uint id
	) private {
		IMasterChefV3(pools[id].farm).harvest(pools[id].tokenId,address(this));
	}

	function withdrawNFT(
		uint tokenId
	) public onlyOwner {
		INonfungiblePositionManager(manage).safeTransferFrom(address(this),msg.sender,tokenId);
	}

	function withdrawFarm(
		uint id,
		uint deadline
	) public onlyOwner {
		_harvest(id);
		(,PoolToken memory tokens) = Challenge(id);
		_remove(id,tokens,deadline);
		_withdraw(id);
	}

	function _withdraw(
		uint id
	) private {
		IMasterChefV3(pools[id].farm).withdraw(pools[id].tokenId,address(this));
		// Reset tokenId to 0
		pools[id].tokenId = 0;
	}

	function Invest(
		uint id,
		uint amount,
		uint quoteAmount,
		uint investType,
		uint cycle,
		uint deadline
	) public payable nonReentrant {
		require(pools[id].inStatus,"Staked::invest project closed");
		require(deadline > block.timestamp,"Staked::transaction lapsed");
		// Pledged Tokens
		if(pools[id].token0 == weth) {
			require(msg.value == amount,"Staked::input eth is not accurate");
		}else {
			TransferHelper.safeTransferFrom(pools[id].token0,msg.sender,address(this),amount);
		}
		uint balance = balanceOf(pools[id].token0);
		uint amount0 = lpRate(id);

		if(isFarm[id]) {
			// Liquidity check
			(bool pass,PoolToken memory tokens) = Challenge(id);
			if(!pass) {
				// Harvest income
				_harvest(id);
				// Remove liquidity
				_remove(id,tokens,deadline);
				// Exchange into pledged currency
				_reSwap(id,tokens);
				// Withdrawal of NFT
				_withdraw(id);
				// Update the latest currency price ratio
				wightReset(id);
			}
			// Token exchange
			// Number of tokens participating in redemption
			balance = balanceOf(pools[id].token0);
			amount0 = lpRate(id);
			// QuoteAmount Recalculate Valuation
			if(!pass) {
				(quoteAmount,) = _amountOut(id,pools[id].token0,pools[id].token1,amount0,false);
			}
			// Exchange token 1 token 0: Spend a fixed number of tokens
			Swap(id,pools[id].token0,pools[id].token1,amount0,quoteAmount,0);

			// Add liquidity
			if(pools[id].tokenId == 0) {
				// Mint
				Mint(id,deadline);
			}else {
				// Append
				Append(id,tokens,deadline);
			}
		}
		if(amount > 0) {
			// Accounting
			if(investType == 1) {
				IAssets(assets).plusAlone(msg.sender,id,pools[id].token0,amount);
			}
			emit InvestToken(id,msg.sender,amount,investType,cycle,block.timestamp);
		}
	}

	struct PoolToken {
		address token0;
		address token1;
		uint amount0;
		uint amount1;
		int24 tickLower;
		int24 tickUpper;
		uint160 sqrtPriceX96;
		uint160 sqrtRatioAX96;
		uint160 sqrtRatioBX96;
		uint128 liquidity;
	}

	// Converting tokens from ineffective liquidity into pledged tokens
	function _reSwap(
		uint id,
		PoolToken memory tokens
	) private {
		uint balance;
		uint amountOut;
		if(tokens.amount0 != 0) {
			if(tokens.token0 != pools[id].token0) {
				(amountOut,balance) = _amountOut(id,tokens.token0,tokens.token1,0,true);
				Swap(id,tokens.token0,tokens.token1,balance,amountOut,0);
			}
		}else if(tokens.amount1 != 0) {
			if(tokens.token1 == pools[id].token1) {
				(amountOut,balance) = _amountOut(id,tokens.token1,tokens.token0,0,true);
				Swap(id,tokens.token1,tokens.token0,balance,amountOut,0);
			}
		}
	}

	function _amountOut(
		uint id,
		address tokenIn,
		address tokenOut,
		uint amountIn,
		bool all
	) private returns (uint outAmount,uint inAmount) {
		if(all) {
			amountIn = balanceOf(tokenIn);
		}
		bytes memory path = abi.encodePacked(tokenIn,pools[id].fee,tokenOut);
		(outAmount,,,) = IQuoterV2(quotev2).quoteExactInput(path,amountIn);
		inAmount = amountIn;
	}

	function _remove(
		uint id,
		PoolToken memory tokens,
		uint deadline
	) private {
		uint min0 = pointHandle(pools[id].point,tokens.amount0,false);
		uint min1 = pointHandle(pools[id].point,tokens.amount1,false);
		if(tokens.liquidity > 0) {
			IMasterChefV3(pools[id].farm).decreaseLiquidity(
				IMasterChefV3.DecreaseLiquidityParams({
					tokenId:pools[id].tokenId,
					liquidity:tokens.liquidity,
					amount0Min:min0,
					amount1Min:min1,
					deadline:deadline
				})
			);
		}
		IMasterChefV3(pools[id].farm).collect(
			IMasterChefV3.CollectParams({
				tokenId:pools[id].tokenId,
				recipient:address(this),
				amount0Max:uint128(0xffffffffffffffffffffffffffffffff),
				amount1Max:uint128(0xffffffffffffffffffffffffffffffff)
			})
		);
		unWrapped();
	}

	function MintTick(
		uint id
	) private view returns (uint160,uint160,uint160,int24,int24) {
		(uint160 sqrtPriceX96,int24 tick,,,,,) = IUniswapV3Pool(pools[id].pool).slot0();
		int24 tickSpacing = IUniswapV3Pool(pools[id].pool).tickSpacing();
		int256 grap = abs(tick * pools[id].point.toInt256() / pointMax.toInt256());
		int24 tickLower;
		int24 tickUpper;
		if(grap > tickSpacing) {
			tickLower = int24((tick - grap) / tickSpacing * tickSpacing);
			tickUpper = int24((tick + grap) / tickSpacing * tickSpacing);
		}else {
			int256 multiple = abs(tick / tickSpacing);
			if(multiple >= 1) {
				tickLower = int24(-tickSpacing * (multiple + 3));
				tickUpper = int24(tickSpacing * (multiple + 3));
			}else {
				tickLower = int24(-tickSpacing * 3);
				tickUpper = int24(tickSpacing * 3);
			}
			if(tickUpper > 887272) {
				tickLower = int24(-887272 / tickSpacing * tickSpacing);
				tickUpper = int24(887272 / tickSpacing * tickSpacing);
			}
		}
	
		uint160 sqrtRatioAX96 = ICompute(compute).sqrtRatioAtTick(tickLower);
		uint160 sqrtRatioBX96 = ICompute(compute).sqrtRatioAtTick(tickUpper);
		return (sqrtPriceX96,sqrtRatioAX96,sqrtRatioBX96,tickLower,tickUpper);
	}

	function Mint(
		uint id,
		uint deadline
	) private {
		(uint160 sqrtPriceX96,uint160 sqrtRatioAX96,uint160 sqrtRatioBX96,int24 tickLower,int24 tickUpper) = MintTick(id);
		// Corresponding correct currency and quantity
		bool correct = pools[id].token0 < pools[id].token1;
		PoolToken memory tokens;
		if(correct) {
			tokens = PoolToken({
				token0:pools[id].token0,
				token1:pools[id].token1,
				amount0:balanceOf(pools[id].token0),
				amount1:balanceOf(pools[id].token1),
				tickLower:tickLower,
				tickUpper:tickUpper,
				sqrtPriceX96:sqrtPriceX96,
				sqrtRatioAX96:sqrtRatioAX96,
				sqrtRatioBX96:sqrtRatioBX96,
				liquidity:0
			});
		}else {
			tokens = PoolToken({
				token0:pools[id].token1,
				token1:pools[id].token0,
				amount0:balanceOf(pools[id].token1),
				amount1:balanceOf(pools[id].token0),
				tickLower:tickLower,
				tickUpper:tickUpper,
				sqrtPriceX96:sqrtPriceX96,
				sqrtRatioAX96:sqrtRatioAX96,
				sqrtRatioBX96:sqrtRatioBX96,
				liquidity:0
			});
		}
		uint128 liquidity = ICompute(compute).getLiquidityForAmounts(sqrtPriceX96,sqrtRatioAX96,sqrtRatioBX96,tokens.amount0,tokens.amount1);
		(tokens.amount0,tokens.amount1) = ICompute(compute).getAmountsForLiquidity(sqrtPriceX96,sqrtRatioAX96,sqrtRatioBX96,liquidity);
		_mint(id,tokens,deadline);
	}

	function _mint(
		uint id,
		PoolToken memory tokens,
		uint deadline
	) private {
		require(tokens.amount0 > 0,"Staked::Abnormal liquidity");
		require(tokens.amount1 > 0,"Staked::Abnormal liquidity");
		uint ethAmount = 0;
		
		if(tokens.token0 != weth) {
			TransferHelper.safeApprove(tokens.token0,manage,tokens.amount0);
		} else {
			ethAmount = tokens.amount0;
		}
		if(tokens.token1 != weth) {
			TransferHelper.safeApprove(tokens.token1,manage,tokens.amount1);
		} else {
			ethAmount = tokens.amount1;
		}
		uint amount0;
		uint amount1;
		// Add liquidity location
		(pools[id].tokenId,,amount0,amount1) = INonfungiblePositionManager(manage).mint{ value:ethAmount }(
			INonfungiblePositionManager.MintParams({
				token0:tokens.token0,
				token1:tokens.token1,
				fee:pools[id].fee,
				tickLower:tokens.tickLower,
				tickUpper:tokens.tickUpper,
				amount0Desired:tokens.amount0,
				amount1Desired:tokens.amount1,
				amount0Min:1,
				amount1Min:1,
				recipient:address(this),
				deadline:deadline
			})
		);
		if(tokens.token0 == pools[id].token0) {
			pools[id].lp0 = amount0;
			pools[id].lp1 = amount1;
		}else {
			pools[id].lp0 = amount1;
			pools[id].lp1 = amount0;
		}
		// Farm Pledge
		INonfungiblePositionManager(manage).safeTransferFrom(address(this),pools[id].farm,pools[id].tokenId);
	}

	function Challenge(
		uint id
	) public view returns (bool result,PoolToken memory tokens) {
		uint amount0;
		uint amount1;
		int24 tickLower;
		int24 tickUpper;
		uint160 sqrtPriceX96;
		uint160 sqrtRatioAX96;
		uint160 sqrtRatioBX96;
		if(pools[id].tokenId == 0) {
			result = true;
		} else {
			IMasterChefV3.UserPositionInfo memory tokenPosition = IMasterChefV3(pools[id].farm).userPositionInfos(pools[id].tokenId);
			tickLower = tokenPosition.tickLower;
			tickUpper = tokenPosition.tickUpper;

			(sqrtPriceX96,,,,,,) = IUniswapV3Pool(pools[id].pool).slot0();
			sqrtRatioAX96 = ICompute(compute).sqrtRatioAtTick(tickLower);
			sqrtRatioBX96 = ICompute(compute).sqrtRatioAtTick(tickUpper);
			
			(amount0,amount1) = ICompute(compute).getAmountsForLiquidity(sqrtPriceX96,sqrtRatioAX96,sqrtRatioBX96,tokenPosition.liquidity);
			if(amount0 == 0 || amount1 == 0) {
				result = false;
			}else {
				result = true;
			}
			bool correct = pools[id].token0 < pools[id].token1;
			tokens = PoolToken({
				token0:correct ? pools[id].token0 : pools[id].token1,
				token1:correct ? pools[id].token1 : pools[id].token0,
				amount0:amount0,
				amount1:amount1,
				tickLower:tickLower,
				tickUpper:tickUpper,
				sqrtPriceX96:sqrtPriceX96,
				sqrtRatioAX96:sqrtRatioAX96,
				sqrtRatioBX96:sqrtRatioBX96,
				liquidity:tokenPosition.liquidity
			});
		}
	}

	function Append(
		uint id,
		PoolToken memory tokens,
		uint deadline
	) private {
		require(pools[id].tokenId != 0,"Staked::no liquidity position");

		uint amount0 = balanceOf(tokens.token0);
		uint amount1 = balanceOf(tokens.token1);

		uint128 liquidity = ICompute(compute).getLiquidityForAmounts(tokens.sqrtPriceX96,tokens.sqrtRatioAX96,tokens.sqrtRatioBX96,amount0,amount1);
		(tokens.amount0,tokens.amount1) = ICompute(compute).getAmountsForLiquidity(tokens.sqrtPriceX96,tokens.sqrtRatioAX96,tokens.sqrtRatioBX96,liquidity);
		_append(id,tokens,deadline);
	} 

	function _append(
		uint id,
		PoolToken memory tokens,
		uint deadline
	) private {
		require(tokens.amount0 > 0,"Staked::Abnormal liquidity");
		require(tokens.amount1 > 0,"Staked::Abnormal liquidity");
		uint ethAmount = 0;
		if(tokens.token0 != weth) {
			TransferHelper.safeApprove(tokens.token0,pools[id].farm,tokens.amount0);
		} else {
			ethAmount = tokens.amount0;
		}
		if(tokens.token1 != weth) {
			TransferHelper.safeApprove(tokens.token1,pools[id].farm,tokens.amount1);
		} else {
			ethAmount = tokens.amount1;
		}
		(,uint amount0,uint amount1) = IMasterChefV3(pools[id].farm).increaseLiquidity{ value:ethAmount }(
			IMasterChefV3.IncreaseLiquidityParams({
				tokenId:pools[id].tokenId,
				amount0Desired:tokens.amount0,
				amount1Desired:tokens.amount1,
				amount0Min:1,
				amount1Min:1,
				deadline:deadline
			})
		);
		if(tokens.token0 == pools[id].token0) {
			pools[id].lp0 = amount0;
			pools[id].lp1 = amount1;
		}else {
			pools[id].lp0 = amount1;
			pools[id].lp1 = amount0;
		}
	}
	

	// Side 0: Spending fixed quantity tokens 1: Booking fixed quantity tokens
	function Swap(
		uint id,
		address tokenIn,
		address tokenOut,
		uint inAmount,
		uint outAmount,
		uint side
	) private returns (uint,uint) {
		bytes memory path;
		if(side == 0) {
			path = abi.encodePacked(tokenIn,pools[id].fee,tokenOut);
			outAmount = pointHandle(pools[id].point,outAmount,false);
		}else if(side == 1) {
			path = abi.encodePacked(tokenOut,pools[id].fee,tokenIn);
			inAmount = pointHandle(pools[id].point,inAmount,true);
		}
		if(inAmount > 0 && outAmount > 0) {
			_swap(tokenIn,inAmount,outAmount,path,side);
		}
		return (inAmount,outAmount);
	}
	
	function _swap(
		address tokenIn,
		uint inAmount,
		uint outAmount,
		bytes memory path,
		uint side
	) private {
		uint ethAmount = 0;
		if(tokenIn != weth) {
			TransferHelper.safeApprove(tokenIn,route,inAmount);
		}else {
			ethAmount = inAmount;
		}
		
		if(side == 0) {
			// Perform a fixed input exchange, if the execution fails, retrieve the exchange rate and try to execute it again
			try ISwapRouter(route).exactInput{ value:ethAmount }(
				ISwapRouter.ExactInputParams({
					path:path,
					recipient:address(this),
					amountIn:inAmount,
					amountOutMinimum:outAmount
				})
			) {} catch {
				(outAmount,,,) = IQuoterV2(quotev2).quoteExactInput(path,inAmount);
				ISwapRouter(route).exactInput{ value:ethAmount }(
					ISwapRouter.ExactInputParams({
						path:path,
						recipient:address(this),
						amountIn:inAmount,
						amountOutMinimum:outAmount
					})
				);
			}
		}else if(side == 1) {
			// Perform a fixed output exchange, if the execution fails, retrieve the exchange rate and try to execute it again
			try ISwapRouter(route).exactOutput{ value:ethAmount }(
				ISwapRouter.ExactOutputParams({
					path:path,
					recipient:address(this),
					amountOut:outAmount,
					amountInMaximum:inAmount
				})
			) {} catch {
				(inAmount,,,) = IQuoterV2(quotev2).quoteExactOutput(path,outAmount);
				ISwapRouter(route).exactOutput{ value:ethAmount }(
					ISwapRouter.ExactOutputParams({
						path:path,
						recipient:address(this),
						amountOut:outAmount,
						amountInMaximum:inAmount
					})
				);
			}
		}
		unWrapped();
	}

	function poolCreat(
		uint _id,
		address _token0,
		address _token1,
		uint24 _fee,
		uint _point,
		uint[] memory _level0,
		uint[] memory _level1
	) public onlyOwner nonReentrant {
		require(pools[_id].pool == address(0),"Staked::project existent");
		require(_point < pointMax,"Staked::invalid slippage");
		require(_token0 != _token1,"Staked::invalid pair");

		address tokenIn = _token0 == address(0) ? weth : _token0;
		address tokenOut = _token1 == address(0) ? weth : _token1;

		address _pool = IUniswapV3Factory(factory).getPool(tokenIn,tokenOut,_fee);
		require(_pool != address(0),"Staked::liquidit pool non-existent");
		address _lmPool = IUniswapV3Pool(_pool).lmPool();
		require(_lmPool != address(0),"Staked::does not support farms");
		address _farm = IPancakeV3LmPool(_lmPool).masterChef();
		require(_farm != address(0),"Staked::not bound to farm");
		pools[_id] = pool({
			token0:tokenIn,
			token1:tokenOut,
			fee:_fee,
			pool:_pool,
			farm:_farm,
			point:_point,
			inStatus:true,
			outStatus:true,
			tokenId:uint(0),
			wight0:_level0[0],
			wight1:_level1[0],
			lp0:_level0[1],
			lp1:_level1[1]
		});
		_autoFarm(_id,true);
	}

	// Calculate the amount of participation in exchange through value and liquidity ratio before calculating the pledge
	function lpRate(
		uint id
	) public view returns (uint inAmount) {
		uint balance = balanceOf(pools[id].token0);
		uint rate0 = pools[id].lp0.mul(pools[id].wight1);
		rate0 = rate0.div(pools[id].wight0);
		uint rate1 = pools[id].lp1;
		uint total = rate0.add(rate1);
		if(total > 0) {
			inAmount = rate1.mul(balance).div(total);
			if(inAmount == 0) {
				inAmount = balance.div(2);
			}
		}else {
			inAmount = balance.div(2);
		}
	}

	function poolControl(
		uint _id,
		bool _in,
		bool _out,
		uint _point,
		uint[] memory _level0,
		uint[] memory _level1
	) public onlyOwner {
		require(_point < pointMax,"Staked::invalid slippage");
		pools[_id].inStatus = _in;
		pools[_id].outStatus = _out;
		pools[_id].point = _point;

		require(_level0[0] > 0,"Staked::level0[0] > 0");
		require(_level1[0] > 0,"Staked::level1[0] > 0");
		require(_level0[1] > 0,"Staked::level0[1] > 0");
		require(_level1[1] > 0,"Staked::level1[1] > 0");
		pools[_id].wight0 = _level0[0];
		pools[_id].wight1 = _level1[0];
		pools[_id].lp0 = _level0[1];
		pools[_id].lp1 = _level1[1];
	}


	function setting(
		address _route,
		address _quotev2,
		address _compute,
		address _assets,
		uint _fee
	) public onlyOwner {
		_setting(_route,_quotev2,_compute,_assets,_fee);
	}

	function _setting(
		address _route,
		address _quotev2,
		address _compute,
		address _assets,
		uint _fee
	) private {
		require(_route != address(0),"Staked::invalid route address");
		require(_quotev2 != address(0),"Staked::invalid quotev2 address");
		require(_compute != address(0),"Staked::invalid compute address");
		route = _route;
		quotev2 = _quotev2;
		compute = _compute;
		assets = _assets;
		fee = _fee;
		factory = ISwapRouter(_route).factory();
		weth = ISwapRouter(_route).WETH9();
		manage = ISwapRouter(_route).positionManager();
		emit Setting(route,quotev2,compute,factory,weth,manage);
	}

	function autoFarm(
		uint _id,
		bool _auto
	) public onlyOwner {
		_autoFarm(_id,_auto);
	}

	function _autoFarm(
		uint _id,
		bool _auto
	) private {
		isFarm[_id] = _auto;
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
}
pragma solidity ^0.8.0;

import "./Strings.sol";

/**
 * @dev Elliptic Curve Digital Signature Algorithm (ECDSA) operations.
 *
 * These functions can be used to verify that a message was signed by the holder
 * of the private keys of a given address.
 */
library ECDSA {
    enum RecoverError {
        NoError,
        InvalidSignature,
        InvalidSignatureLength,
        InvalidSignatureS,
        InvalidSignatureV // Deprecated in v4.8
    }

    function _throwError(RecoverError error) private pure {
        if (error == RecoverError.NoError) {
            return; // no error: do nothing
        } else if (error == RecoverError.InvalidSignature) {
            revert("ECDSA: invalid signature");
        } else if (error == RecoverError.InvalidSignatureLength) {
            revert("ECDSA: invalid signature length");
        } else if (error == RecoverError.InvalidSignatureS) {
            revert("ECDSA: invalid signature 's' value");
        }
    }

    /**
     * @dev Returns the address that signed a hashed message (`hash`) with
     * `signature` or error string. This address can then be used for verification purposes.
     *
     * The `ecrecover` EVM opcode allows for malleable (non-unique) signatures:
     * this function rejects them by requiring the `s` value to be in the lower
     * half order, and the `v` value to be either 27 or 28.
     *
     * IMPORTANT: `hash` _must_ be the result of a hash operation for the
     * verification to be secure: it is possible to craft signatures that
     * recover to arbitrary addresses for non-hashed data. A safe way to ensure
     * this is by receiving a hash of the original message (which may otherwise
     * be too long), and then calling {toEthSignedMessageHash} on it.
     *
     * Documentation for signature generation:
     * - with https://web3js.readthedocs.io/en/v1.3.4/web3-eth-accounts.html#sign[Web3.js]
     * - with https://docs.ethers.io/v5/api/signer/#Signer-signMessage[ethers]
     *
     * _Available since v4.3._
     */
    function tryRecover(bytes32 hash, bytes memory signature) internal pure returns (address, RecoverError) {
        if (signature.length == 65) {
            bytes32 r;
            bytes32 s;
            uint8 v;
            // ecrecover takes the signature parameters, and the only way to get them
            // currently is to use assembly.
            /// @solidity memory-safe-assembly
            assembly {
                r := mload(add(signature, 0x20))
                s := mload(add(signature, 0x40))
                v := byte(0, mload(add(signature, 0x60)))
            }
            return tryRecover(hash, v, r, s);
        } else {
            return (address(0), RecoverError.InvalidSignatureLength);
        }
    }

    /**
     * @dev Returns the address that signed a hashed message (`hash`) with
     * `signature`. This address can then be used for verification purposes.
     *
     * The `ecrecover` EVM opcode allows for malleable (non-unique) signatures:
     * this function rejects them by requiring the `s` value to be in the lower
     * half order, and the `v` value to be either 27 or 28.
     *
     * IMPORTANT: `hash` _must_ be the result of a hash operation for the
     * verification to be secure: it is possible to craft signatures that
     * recover to arbitrary addresses for non-hashed data. A safe way to ensure
     * this is by receiving a hash of the original message (which may otherwise
     * be too long), and then calling {toEthSignedMessageHash} on it.
     */
    function recover(bytes32 hash, bytes memory signature) internal pure returns (address) {
        (address recovered, RecoverError error) = tryRecover(hash, signature);
        _throwError(error);
        return recovered;
    }

    /**
     * @dev Overload of {ECDSA-tryRecover} that receives the `r` and `vs` short-signature fields separately.
     *
     * See https://eips.ethereum.org/EIPS/eip-2098[EIP-2098 short signatures]
     *
     * _Available since v4.3._
     */
    function tryRecover(
        bytes32 hash,
        bytes32 r,
        bytes32 vs
    ) internal pure returns (address, RecoverError) {
        bytes32 s = vs & bytes32(0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
        uint8 v = uint8((uint256(vs) >> 255) + 27);
        return tryRecover(hash, v, r, s);
    }

    /**
     * @dev Overload of {ECDSA-recover} that receives the `r and `vs` short-signature fields separately.
     *
     * _Available since v4.2._
     */
    function recover(
        bytes32 hash,
        bytes32 r,
        bytes32 vs
    ) internal pure returns (address) {
        (address recovered, RecoverError error) = tryRecover(hash, r, vs);
        _throwError(error);
        return recovered;
    }

    /**
     * @dev Overload of {ECDSA-tryRecover} that receives the `v`,
     * `r` and `s` signature fields separately.
     *
     * _Available since v4.3._
     */
    function tryRecover(
        bytes32 hash,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal pure returns (address, RecoverError) {
        // EIP-2 still allows signature malleability for ecrecover(). Remove this possibility and make the signature
        // unique. Appendix F in the Ethereum Yellow paper (https://ethereum.github.io/yellowpaper/paper.pdf), defines
        // the valid range for s in (301): 0 < s < secp256k1n &#247; 2 + 1, and for v in (302): v ∈ {27, 28}. Most
        // signatures from current libraries generate a unique signature with an s-value in the lower half order.
        //
        // If your library generates malleable signatures, such as s-values in the upper range, calculate a new s-value
        // with 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - s1 and flip v from 27 to 28 or
        // vice versa. If your library also generates signatures with 0/1 for v instead 27/28, add 27 to v to accept
        // these malleable signatures as well.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            return (address(0), RecoverError.InvalidSignatureS);
        }

        // If the signature is valid (and not malleable), return the signer address
        address signer = ecrecover(hash, v, r, s);
        if (signer == address(0)) {
            return (address(0), RecoverError.InvalidSignature);
        }

        return (signer, RecoverError.NoError);
    }

    /**
     * @dev Overload of {ECDSA-recover} that receives the `v`,
     * `r` and `s` signature fields separately.
     */
    function recover(
        bytes32 hash,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal pure returns (address) {
        (address recovered, RecoverError error) = tryRecover(hash, v, r, s);
        _throwError(error);
        return recovered;
    }

    /**
     * @dev Returns an Ethereum Signed Message, created from a `hash`. This
     * produces hash corresponding to the one signed with the
     * https://eth.wiki/json-rpc/API#eth_sign[`eth_sign`]
     * JSON-RPC method as part of EIP-191.
     *
     * See {recover}.
     */
    function toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        // 32 is the length in bytes of hash,
        // enforced by the type signature above
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }

    /**
     * @dev Returns an Ethereum Signed Message, created from `s`. This
     * produces hash corresponding to the one signed with the
     * https://eth.wiki/json-rpc/API#eth_sign[`eth_sign`]
     * JSON-RPC method as part of EIP-191.
     *
     * See {recover}.
     */
    function toEthSignedMessageHash(bytes memory s) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n", Strings.toString(s.length), s));
    }

    /**
     * @dev Returns an Ethereum Signed Typed Data, created from a
     * `domainSeparator` and a `structHash`. This produces hash corresponding
     * to the one signed with the
     * https://eips.ethereum.org/EIPS/eip-712[`eth_signTypedData`]
     * JSON-RPC method as part of EIP-712.
     *
     * See {recover}.
     */
    function toTypedDataHash(bytes32 domainSeparator, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
}
pragma solidity >=0.4.22 <0.9.0;

interface IAssets {
    function asset(
        address user,
        uint pid,
        address token
    ) external view returns (uint256);

    function plusAlone(
        address user,
		uint pid,
		address token,
		uint amount
    ) external;

    function reduceAlone(
        address user,
		uint pid,
		address token,
		uint amount
    ) external;
}
pragma solidity >=0.4.22 <0.9.0;

interface ICompute {
    function sqrtRatioAtTick(int24 tick) external pure returns (uint160 sqrtPriceX96);
    function tickAtSqrtRatio(uint160 sqrtPriceX96) external pure returns (int24 tick);

    function getLiquidityForAmounts(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0,
        uint256 amount1
    ) external pure returns (uint128 liquidity);

    function getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) external pure returns (uint256 amount0, uint256 amount1);
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
}
pragma solidity >=0.4.22 <0.9.0;
pragma abicoder v2;

interface IMasterChefV3 {
    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }
    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        returns (
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        );
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }
    function collect(CollectParams memory params) external returns (uint256 amount0, uint256 amount1);

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    function harvest(uint256 _tokenId, address _to) external returns (uint256 reward);
    function withdraw(uint256 _tokenId, address _to) external returns (uint256 reward);

    struct UserPositionInfo {
        uint128 liquidity;
        uint128 boostLiquidity;
        int24 tickLower;
        int24 tickUpper;
        uint256 rewardGrowthInside;
        uint256 reward;
        address user;
        uint256 pid;
        uint256 boostMultiplier;
    }
    function userPositionInfos(uint256 _tokenId) external view returns (UserPositionInfo memory userInfo);
    function pendingCake(uint256 _tokenId) external view returns (uint256 reward);
}
pragma solidity >=0.7.5;
pragma abicoder v2;

/// @title Non-fungible token for positions
/// @notice Wraps Uniswap V3 positions in a non-fungible token interface which allows for them to be transferred
/// and authorized.
interface INonfungiblePositionManager {
    /// @notice Emitted when liquidity is increased for a position NFT
    /// @dev Also emitted when a token is minted
    /// @param tokenId The ID of the token for which liquidity was increased
    /// @param liquidity The amount by which liquidity for the NFT position was increased
    /// @param amount0 The amount of token0 that was paid for the increase in liquidity
    /// @param amount1 The amount of token1 that was paid for the increase in liquidity
    event IncreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    /// @notice Emitted when liquidity is decreased for a position NFT
    /// @param tokenId The ID of the token for which liquidity was decreased
    /// @param liquidity The amount by which liquidity for the NFT position was decreased
    /// @param amount0 The amount of token0 that was accounted for the decrease in liquidity
    /// @param amount1 The amount of token1 that was accounted for the decrease in liquidity
    event DecreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    /// @notice Emitted when tokens are collected for a position NFT
    /// @dev The amounts reported may not be exactly equivalent to the amounts transferred, due to rounding behavior
    /// @param tokenId The ID of the token for which underlying tokens were collected
    /// @param recipient The address of the account that received the collected tokens
    /// @param amount0 The amount of token0 owed to the position that was collected
    /// @param amount1 The amount of token1 owed to the position that was collected
    event Collect(uint256 indexed tokenId, address recipient, uint256 amount0, uint256 amount1);

    /// @notice Returns the position information associated with a given token ID.
    /// @dev Throws if the token ID is not valid.
    /// @param tokenId The ID of the token that represents the position
    /// @return nonce The nonce for permits
    /// @return operator The address that is approved for spending
    /// @return token0 The address of the token0 for a specific pool
    /// @return token1 The address of the token1 for a specific pool
    /// @return fee The fee associated with the pool
    /// @return tickLower The lower end of the tick range for the position
    /// @return tickUpper The higher end of the tick range for the position
    /// @return liquidity The liquidity of the position
    /// @return feeGrowthInside0LastX128 The fee growth of token0 as of the last action on the individual position
    /// @return feeGrowthInside1LastX128 The fee growth of token1 as of the last action on the individual position
    /// @return tokensOwed0 The uncollected amount of token0 owed to the position as of the last computation
    /// @return tokensOwed1 The uncollected amount of token1 owed to the position as of the last computation
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    /// @notice Creates a new position wrapped in a NFT
    /// @dev Call this when the pool does exist and is initialized. Note that if the pool is created but not initialized
    /// a method does not exist, i.e. the pool is assumed to be initialized.
    /// @param params The params necessary to mint a position, encoded as `MintParams` in calldata
    /// @return tokenId The ID of the token that represents the minted position
    /// @return liquidity The amount of liquidity for this position
    /// @return amount0 The amount of token0
    /// @return amount1 The amount of token1
    function mint(MintParams calldata params)
        external
        payable
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        );

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /// @notice Increases the amount of liquidity in a position, with tokens paid by the `msg.sender`
    /// @param params tokenId The ID of the token for which liquidity is being increased,
    /// amount0Desired The desired amount of token0 to be spent,
    /// amount1Desired The desired amount of token1 to be spent,
    /// amount0Min The minimum amount of token0 to spend, which serves as a slippage check,
    /// amount1Min The minimum amount of token1 to spend, which serves as a slippage check,
    /// deadline The time by which the transaction must be included to effect the change
    /// @return liquidity The new liquidity amount as a result of the increase
    /// @return amount0 The amount of token0 to acheive resulting liquidity
    /// @return amount1 The amount of token1 to acheive resulting liquidity
    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        returns (
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        );

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /// @notice Decreases the amount of liquidity in a position and accounts it to the position
    /// @param params tokenId The ID of the token for which liquidity is being decreased,
    /// amount The amount by which liquidity will be decreased,
    /// amount0Min The minimum amount of token0 that should be accounted for the burned liquidity,
    /// amount1Min The minimum amount of token1 that should be accounted for the burned liquidity,
    /// deadline The time by which the transaction must be included to effect the change
    /// @return amount0 The amount of token0 accounted to the position's tokens owed
    /// @return amount1 The amount of token1 accounted to the position's tokens owed
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    /// @notice Collects up to a maximum amount of fees owed to a specific position to the recipient
    /// @param params tokenId The ID of the NFT for which tokens are being collected,
    /// recipient The account that should receive the tokens,
    /// amount0Max The maximum amount of token0 to collect,
    /// amount1Max The maximum amount of token1 to collect
    /// @return amount0 The amount of fees collected in token0
    /// @return amount1 The amount of fees collected in token1
    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

    /// @notice Burns a token ID, which deletes it from the NFT contract. The token must have 0 liquidity and all tokens
    /// must be collected first.
    /// @param tokenId The ID of the token that is being burned
    function burn(uint256 tokenId) external payable;

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    function ownerOf(uint256 tokenId) external view returns (address owner);
}
}
pragma solidity >=0.4.22 <0.9.0;

interface IPancakeV3LmPool {
    function masterChef() external view returns (address);
}
pragma solidity >=0.7.5;
pragma abicoder v2;

/// @title QuoterV2 Interface
/// @notice Supports quoting the calculated amounts from exact input or exact output swaps.
/// @notice For each pool also tells you the number of initialized ticks crossed and the sqrt price of the pool after the swap.
/// @dev These functions are not marked view because they rely on calling non-view functions and reverting
/// to compute the result. They are also not gas efficient and should not be called on-chain.
interface IQuoterV2 {
    /// @notice Returns the amount out received for a given exact input swap without executing the swap
    /// @param path The path of the swap, i.e. each token pair and the pool fee
    /// @param amountIn The amount of the first token to swap
    /// @return amountOut The amount of the last token that would be received
    /// @return sqrtPriceX96AfterList List of the sqrt price after the swap for each pool in the path
    /// @return initializedTicksCrossedList List of the initialized ticks that the swap crossed for each pool in the path
    /// @return gasEstimate The estimate of the gas that the swap consumes
    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        );

    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Returns the amount out received for a given exact input but for a swap of a single pool
    /// @param params The params for the quote, encoded as `QuoteExactInputSingleParams`
    /// tokenIn The token being swapped in
    /// tokenOut The token being swapped out
    /// fee The fee of the token pool to consider for the pair
    /// amountIn The desired input amount
    /// sqrtPriceLimitX96 The price limit of the pool that cannot be exceeded by the swap
    /// @return amountOut The amount of `tokenOut` that would be received
    /// @return sqrtPriceX96After The sqrt price of the pool after the swap
    /// @return initializedTicksCrossed The number of initialized ticks that the swap crossed
    /// @return gasEstimate The estimate of the gas that the swap consumes
    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (
            uint256 amountOut,
            uint160 sqrtPriceX96After,
            uint32 initializedTicksCrossed,
            uint256 gasEstimate
        );

    /// @notice Returns the amount in required for a given exact output swap without executing the swap
    /// @param path The path of the swap, i.e. each token pair and the pool fee. Path must be provided in reverse order
    /// @param amountOut The amount of the last token to receive
    /// @return amountIn The amount of first token required to be paid
    /// @return sqrtPriceX96AfterList List of the sqrt price after the swap for each pool in the path
    /// @return initializedTicksCrossedList List of the initialized ticks that the swap crossed for each pool in the path
    /// @return gasEstimate The estimate of the gas that the swap consumes
    function quoteExactOutput(bytes memory path, uint256 amountOut)
        external
        returns (
            uint256 amountIn,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        );

    struct QuoteExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amount;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Returns the amount in required to receive the given exact output amount but for a swap of a single pool
    /// @param params The params for the quote, encoded as `QuoteExactOutputSingleParams`
    /// tokenIn The token being swapped in
    /// tokenOut The token being swapped out
    /// fee The fee of the token pool to consider for the pair
    /// amountOut The desired output amount
    /// sqrtPriceLimitX96 The price limit of the pool that cannot be exceeded by the swap
    /// @return amountIn The amount required as the input for the swap in order to receive `amountOut`
    /// @return sqrtPriceX96After The sqrt price of the pool after the swap
    /// @return initializedTicksCrossed The number of initialized ticks that the swap crossed
    /// @return gasEstimate The estimate of the gas that the swap consumes
    function quoteExactOutputSingle(QuoteExactOutputSingleParams memory params)
        external
        returns (
            uint256 amountIn,
            uint160 sqrtPriceX96After,
            uint32 initializedTicksCrossed,
            uint256 gasEstimate
        );
}
}
pragma solidity >=0.7.5;
pragma abicoder v2;
/// @title Router token swapping functionality
/// @notice Functions for swapping tokens via Uniswap V3
interface ISwapRouter {
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

    /// @notice Swaps `amountIn` of one token for as much as possible of another token
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
    /// @param params The parameters necessary for the multi-hop swap, encoded as `ExactInputParams` in calldata
    /// @return amountOut The amount of the received token
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps as little as possible of one token for `amountOut` of another token
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
    /// @param params The parameters necessary for the multi-hop swap, encoded as `ExactOutputParams` in calldata
    /// @return amountIn The amount of the input token
    function exactOutput(ExactOutputParams calldata params) external payable returns (uint256 amountIn);


    /// @return Returns the address of the Uniswap V3 factory
    function factory() external view returns (address);

    /// @return Returns the address of WETH9
    function WETH9() external view returns (address);
    function positionManager() external view returns (address);
}
}
pragma solidity >=0.5.0;

/// @title The interface for the Uniswap V3 Factory
/// @notice The Uniswap V3 Factory facilitates creation of Uniswap V3 pools and control over the protocol fees
interface IUniswapV3Factory {
    /// @notice Emitted when the owner of the factory is changed
    /// @param oldOwner The owner before the owner was changed
    /// @param newOwner The owner after the owner was changed
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);

    /// @notice Emitted when a pool is created
    /// @param token0 The first token of the pool by address sort order
    /// @param token1 The second token of the pool by address sort order
    /// @param fee The fee collected upon every swap in the pool, denominated in hundredths of a bip
    /// @param tickSpacing The minimum number of ticks between initialized ticks
    /// @param pool The address of the created pool
    event PoolCreated(
        address indexed token0,
        address indexed token1,
        uint24 indexed fee,
        int24 tickSpacing,
        address pool
    );

    /// @notice Emitted when a new fee amount is enabled for pool creation via the factory
    /// @param fee The enabled fee, denominated in hundredths of a bip
    /// @param tickSpacing The minimum number of ticks between initialized ticks for pools created with the given fee
    event FeeAmountEnabled(uint24 indexed fee, int24 indexed tickSpacing);

    /// @notice Returns the current owner of the factory
    /// @dev Can be changed by the current owner via setOwner
    /// @return The address of the factory owner
    function owner() external view returns (address);

    /// @notice Returns the tick spacing for a given fee amount, if enabled, or 0 if not enabled
    /// @dev A fee amount can never be removed, so this value should be hard coded or cached in the calling context
    /// @param fee The enabled fee, denominated in hundredths of a bip. Returns 0 in case of unenabled fee
    /// @return The tick spacing
    function feeAmountTickSpacing(uint24 fee) external view returns (int24);

    /// @notice Returns the pool address for a given pair of tokens and a fee, or address 0 if it does not exist
    /// @dev tokenA and tokenB may be passed in either token0/token1 or token1/token0 order
    /// @param tokenA The contract address of either token0 or token1
    /// @param tokenB The contract address of the other token
    /// @param fee The fee collected upon every swap in the pool, denominated in hundredths of a bip
    /// @return pool The pool address
    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external view returns (address pool);

    /// @notice Creates a pool for the given two tokens and fee
    /// @param tokenA One of the two tokens in the desired pool
    /// @param tokenB The other of the two tokens in the desired pool
    /// @param fee The desired fee for the pool
    /// @dev tokenA and tokenB may be passed in either order: token0/token1 or token1/token0. tickSpacing is retrieved
    /// from the fee. The call will revert if the pool already exists, the fee is invalid, or the token arguments
    /// are invalid.
    /// @return pool The address of the newly created pool
    function createPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external returns (address pool);

    /// @notice Updates the owner of the factory
    /// @dev Must be called by the current owner
    /// @param _owner The new owner of the factory
    function setOwner(address _owner) external;

    /// @notice Enables a fee amount with the given tickSpacing
    /// @dev Fee amounts may never be removed once enabled
    /// @param fee The fee amount to enable, denominated in hundredths of a bip (i.e. 1e-6)
    /// @param tickSpacing The spacing between ticks to be enforced for all pools created with the given fee amount
    function enableFeeAmount(uint24 fee, int24 tickSpacing) external;
}
}
pragma solidity >=0.5.0;

import './IUniswapV3PoolImmutables.sol';
import './IUniswapV3PoolState.sol';

/// @title The interface for a Uniswap V3 Pool
/// @notice A Uniswap pool facilitates swapping and automated market making between any two assets that strictly conform
/// to the ERC20 specification
/// @dev The pool interface is broken up into many smaller pieces
interface IUniswapV3Pool is
    IUniswapV3PoolImmutables,
    IUniswapV3PoolState
{

}
}
pragma solidity >=0.5.0;

/// @title Pool state that never changes
/// @notice These parameters are fixed for a pool forever, i.e., the methods will always return the same values
interface IUniswapV3PoolImmutables {
    /// @notice The contract that deployed the pool, which must adhere to the IUniswapV3Factory interface
    /// @return The contract address
    function factory() external view returns (address);

    /// @notice The first of the two tokens of the pool, sorted by address
    /// @return The token contract address
    function token0() external view returns (address);

    /// @notice The second of the two tokens of the pool, sorted by address
    /// @return The token contract address
    function token1() external view returns (address);

    /// @notice The pool's fee in hundredths of a bip, i.e. 1e-6
    /// @return The fee
    function fee() external view returns (uint24);

    /// @notice The pool tick spacing
    /// @dev Ticks can only be used at multiples of this value, minimum of 1 and always positive
    /// e.g.: a tickSpacing of 3 means ticks can be initialized every 3rd tick, i.e., ..., -6, -3, 0, 3, 6, ...
    /// This value is an int24 to avoid casting even though it is always positive.
    /// @return The tick spacing
    function tickSpacing() external view returns (int24);

    /// @notice The maximum amount of position liquidity that can use any tick in the range
    /// @dev This parameter is enforced per tick to prevent liquidity from overflowing a uint128 at any point, and
    /// also prevents out-of-range liquidity from being used to prevent adding in-range liquidity to a pool
    /// @return The max amount of liquidity per tick
    function maxLiquidityPerTick() external view returns (uint128);

    function lmPool() external view returns (address);
}
}
pragma solidity >=0.5.0;

/// @title Pool state that can change
/// @notice These methods compose the pool's state, and can change with any frequency including multiple times
/// per transaction
interface IUniswapV3PoolState {
    /// @notice The 0th storage slot in the pool stores many values, and is exposed as a single method to save gas
    /// when accessed externally.
    /// @return sqrtPriceX96 The current price of the pool as a sqrt(token1/token0) Q64.96 value
    /// tick The current tick of the pool, i.e. according to the last tick transition that was run.
    /// This value may not always be equal to SqrtTickMath.getTickAtSqrtRatio(sqrtPriceX96) if the price is on a tick
    /// boundary.
    /// observationIndex The index of the last oracle observation that was written,
    /// observationCardinality The current maximum number of observations stored in the pool,
    /// observationCardinalityNext The next maximum number of observations, to be updated when the observation.
    /// feeProtocol The protocol fee for both tokens of the pool.
    /// Encoded as two 4 bit values, where the protocol fee of token1 is shifted 4 bits and the protocol fee of token0
    /// is the lower 4 bits. Used as the denominator of a fraction of the swap fee, e.g. 4 means 1/4th of the swap fee.
    /// unlocked Whether the pool is currently locked to reentrancy
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint32 feeProtocol,
            bool unlocked
        );

    /// @notice The fee growth as a Q128.128 fees of token0 collected per unit of liquidity for the entire life of the pool
    /// @dev This value can overflow the uint256
    function feeGrowthGlobal0X128() external view returns (uint256);

    /// @notice The fee growth as a Q128.128 fees of token1 collected per unit of liquidity for the entire life of the pool
    /// @dev This value can overflow the uint256
    function feeGrowthGlobal1X128() external view returns (uint256);

    /// @notice The amounts of token0 and token1 that are owed to the protocol
    /// @dev Protocol fees will never exceed uint128 max in either token
    function protocolFees() external view returns (uint128 token0, uint128 token1);

    /// @notice The currently in range liquidity available to the pool
    /// @dev This value has no relationship to the total liquidity across all ticks
    function liquidity() external view returns (uint128);

    /// @notice Look up information about a specific tick in the pool
    /// @param tick The tick to look up
    /// @return liquidityGross the total amount of position liquidity that uses the pool either as tick lower or
    /// tick upper,
    /// liquidityNet how much liquidity changes when the pool price crosses the tick,
    /// feeGrowthOutside0X128 the fee growth on the other side of the tick from the current tick in token0,
    /// feeGrowthOutside1X128 the fee growth on the other side of the tick from the current tick in token1,
    /// tickCumulativeOutside the cumulative tick value on the other side of the tick from the current tick
    /// secondsPerLiquidityOutsideX128 the seconds spent per liquidity on the other side of the tick from the current tick,
    /// secondsOutside the seconds spent on the other side of the tick from the current tick,
    /// initialized Set to true if the tick is initialized, i.e. liquidityGross is greater than 0, otherwise equal to false.
    /// Outside values can only be used if the tick is initialized, i.e. if liquidityGross is greater than 0.
    /// In addition, these values are only relative and must be used only in comparison to previous snapshots for
    /// a specific position.
    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );

    /// @notice Returns 256 packed tick initialized boolean values. See TickBitmap for more information
    function tickBitmap(int16 wordPosition) external view returns (uint256);

    /// @notice Returns the information about a position by the position's key
    /// @param key The position's key is a hash of a preimage composed by the owner, tickLower and tickUpper
    /// @return _liquidity The amount of liquidity in the position,
    /// Returns feeGrowthInside0LastX128 fee growth of token0 inside the tick range as of the last mint/burn/poke,
    /// Returns feeGrowthInside1LastX128 fee growth of token1 inside the tick range as of the last mint/burn/poke,
    /// Returns tokensOwed0 the computed amount of token0 owed to the position as of the last mint/burn/poke,
    /// Returns tokensOwed1 the computed amount of token1 owed to the position as of the last mint/burn/poke
    function positions(bytes32 key)
        external
        view
        returns (
            uint128 _liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    /// @notice Returns data about a specific observation index
    /// @param index The element of the observations array to fetch
    /// @dev You most likely want to use #observe() instead of this method to get an observation as of some amount of time
    /// ago, rather than at a specific index in the array.
    /// @return blockTimestamp The timestamp of the observation,
    /// Returns tickCumulative the tick multiplied by seconds elapsed for the life of the pool as of the observation timestamp,
    /// Returns secondsPerLiquidityCumulativeX128 the seconds per in range liquidity for the life of the pool as of the observation timestamp,
    /// Returns initialized whether the observation has been initialized and the values are safe to use
    function observations(uint256 index)
        external
        view
        returns (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
        );
}
}
pragma solidity >=0.4.22 <0.9.0;

/// @title Interface for WETH9
interface IWETH9 {
    /// @notice Deposit ether to get wrapped ether
    function deposit() external payable;

    /// @notice Withdraw wrapped ether to get ether
    function withdraw(uint256) external;
}
}
pragma solidity ^0.8.0;

/**
 * @dev Standard math utilities missing in the Solidity language.
 */
library Math {
    enum Rounding {
        Down, // Toward negative infinity
        Up, // Toward infinity
        Zero // Toward zero
    }

    /**
     * @dev Returns the largest of two numbers.
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
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
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /**
     * @notice Calculates floor(x * y / denominator) with full precision. Throws if result overflows a uint256 or denominator == 0
     * @dev Original credit to Remco Bloemen under MIT license (https://xn--2-umb.com/21/muldiv)
     * with further edits by Uniswap Labs also under MIT license.
     */
    function mulDiv(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = x * y. Compute the product mod 2^256 and mod 2^256 - 1, then use
            // use the Chinese Remainder Theorem to reconstruct the 512 bit result. The result is stored in two 256
            // variables such that product = prod1 * 2^256 + prod0.
            uint256 prod0; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly {
                let mm := mulmod(x, y, not(0))
                prod0 := mul(x, y)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow cases, 256 by 256 division.
            if (prod1 == 0) {
                return prod0 / denominator;
            }

            // Make sure the result is less than 2^256. Also prevents denominator == 0.
            require(denominator > prod1);

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [prod1 prod0].
            uint256 remainder;
            assembly {
                // Compute remainder using mulmod.
                remainder := mulmod(x, y, denominator)

                // Subtract 256 bit number from 512 bit number.
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator and compute largest power of two divisor of denominator. Always >= 1.
            // See https://cs.stackexchange.com/q/138556/92363.

            // Does not overflow because the denominator cannot be zero at this stage in the function.
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                // Divide denominator by twos.
                denominator := div(denominator, twos)

                // Divide [prod1 prod0] by twos.
                prod0 := div(prod0, twos)

                // Flip twos such that it is 2^256 / twos. If twos is zero, then it becomes one.
                twos := add(div(sub(0, twos), twos), 1)
            }

            // Shift in bits from prod1 into prod0.
            prod0 |= prod1 * twos;

            // Invert denominator mod 2^256. Now that denominator is an odd number, it has an inverse modulo 2^256 such
            // that denominator * inv = 1 mod 2^256. Compute the inverse by starting with a seed that is correct for
            // four bits. That is, denominator * inv = 1 mod 2^4.
            uint256 inverse = (3 * denominator) ^ 2;

            // Use the Newton-Raphson iteration to improve the precision. Thanks to Hensel's lifting lemma, this also works
            // in modular arithmetic, doubling the correct bits in each step.
            inverse *= 2 - denominator * inverse; // inverse mod 2^8
            inverse *= 2 - denominator * inverse; // inverse mod 2^16
            inverse *= 2 - denominator * inverse; // inverse mod 2^32
            inverse *= 2 - denominator * inverse; // inverse mod 2^64
            inverse *= 2 - denominator * inverse; // inverse mod 2^128
            inverse *= 2 - denominator * inverse; // inverse mod 2^256

            // Because the division is now exact we can divide by multiplying with the modular inverse of denominator.
            // This will give us the correct result modulo 2^256. Since the preconditions guarantee that the outcome is
            // less than 2^256, this is the final result. We don't need to compute the high bits of the result and prod1
            // is no longer required.
            result = prod0 * inverse;
            return result;
        }
    }

    /**
     * @notice Calculates x * y / denominator with full precision, following the selected rounding direction.
     */
    function mulDiv(
        uint256 x,
        uint256 y,
        uint256 denominator,
        Rounding rounding
    ) internal pure returns (uint256) {
        uint256 result = mulDiv(x, y, denominator);
        if (rounding == Rounding.Up && mulmod(x, y, denominator) > 0) {
            result += 1;
        }
        return result;
    }

    /**
     * @dev Returns the square root of a number. If the number is not a perfect square, the value is rounded down.
     *
     * Inspired by Henry S. Warren, Jr.'s "Hacker's Delight" (Chapter 11).
     */
    function sqrt(uint256 a) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }

        // For our first guess, we get the biggest power of 2 which is smaller than the square root of the target.
        //
        // We know that the "msb" (most significant bit) of our target number `a` is a power of 2 such that we have
        // `msb(a) <= a < 2*msb(a)`. This value can be written `msb(a)=2**k` with `k=log2(a)`.
        //
        // This can be rewritten `2**log2(a) <= a < 2**(log2(a) + 1)`
        // → `sqrt(2**k) <= sqrt(a) < sqrt(2**(k+1))`
        // → `2**(k/2) <= sqrt(a) < 2**((k+1)/2) <= 2**(k/2 + 1)`
        //
        // Consequently, `2**(log2(a) / 2)` is a good first approximation of `sqrt(a)` with at least 1 correct bit.
        uint256 result = 1 << (log2(a) >> 1);

        // At this point `result` is an estimation with one bit of precision. We know the true value is a uint128,
        // since it is the square root of a uint256. Newton's method converges quadratically (precision doubles at
        // every iteration). We thus need at most 7 iteration to turn our partial result with one bit of precision
        // into the expected uint128 result.
        unchecked {
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            return min(result, a / result);
        }
    }

    /**
     * @notice Calculates sqrt(a), following the selected rounding direction.
     */
    function sqrt(uint256 a, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = sqrt(a);
            return result + (rounding == Rounding.Up && result * result < a ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 2, rounded down, of a positive value.
     * Returns 0 if given 0.
     */
    function log2(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >> 128 > 0) {
                value >>= 128;
                result += 128;
            }
            if (value >> 64 > 0) {
                value >>= 64;
                result += 64;
            }
            if (value >> 32 > 0) {
                value >>= 32;
                result += 32;
            }
            if (value >> 16 > 0) {
                value >>= 16;
                result += 16;
            }
            if (value >> 8 > 0) {
                value >>= 8;
                result += 8;
            }
            if (value >> 4 > 0) {
                value >>= 4;
                result += 4;
            }
            if (value >> 2 > 0) {
                value >>= 2;
                result += 2;
            }
            if (value >> 1 > 0) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 2, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log2(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log2(value);
            return result + (rounding == Rounding.Up && 1 << result < value ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 10, rounded down, of a positive value.
     * Returns 0 if given 0.
     */
    function log10(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >= 10**64) {
                value /= 10**64;
                result += 64;
            }
            if (value >= 10**32) {
                value /= 10**32;
                result += 32;
            }
            if (value >= 10**16) {
                value /= 10**16;
                result += 16;
            }
            if (value >= 10**8) {
                value /= 10**8;
                result += 8;
            }
            if (value >= 10**4) {
                value /= 10**4;
                result += 4;
            }
            if (value >= 10**2) {
                value /= 10**2;
                result += 2;
            }
            if (value >= 10**1) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 10, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log10(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log10(value);
            return result + (rounding == Rounding.Up && 10**result < value ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 256, rounded down, of a positive value.
     * Returns 0 if given 0.
     *
     * Adding one to the result gives the number of pairs of hex symbols needed to represent `value` as a hex string.
     */
    function log256(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >> 128 > 0) {
                value >>= 128;
                result += 16;
            }
            if (value >> 64 > 0) {
                value >>= 64;
                result += 8;
            }
            if (value >> 32 > 0) {
                value >>= 32;
                result += 4;
            }
            if (value >> 16 > 0) {
                value >>= 16;
                result += 2;
            }
            if (value >> 8 > 0) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 10, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log256(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log256(value);
            return result + (rounding == Rounding.Up && 1 << (result * 8) < value ? 1 : 0);
        }
    }
}
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
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if the sender is not the owner.
     */
    function _checkOwner() internal view virtual {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
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
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        // On the first call to nonReentrant, _status will be _NOT_ENTERED
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");

        // Any calls to nonReentrant after this point will fail
        _status = _ENTERED;
    }

    function _nonReentrantAfter() private {
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = _NOT_ENTERED;
    }
}
}
pragma solidity >=0.5.0;

/// @title Safe casting methods
/// @notice Contains methods for safely casting between types
library SafeCast {
    /// @notice Cast a uint256 to a uint160, revert on overflow
    /// @param y The uint256 to be downcasted
    /// @return z The downcasted integer, now type uint160
    function toUint160(uint256 y) internal pure returns (uint160 z) {
        require((z = uint160(y)) == y);
    }

    /// @notice Cast a int256 to a int128, revert on overflow or underflow
    /// @param y The int256 to be downcasted
    /// @return z The downcasted integer, now type int128
    function toInt128(int256 y) internal pure returns (int128 z) {
        require((z = int128(y)) == y);
    }

    /// @notice Cast a uint256 to a int256, revert on overflow
    /// @param y The uint256 to be casted
    /// @return z The casted integer, now type int256
    function toInt256(uint256 y) internal pure returns (int256 z) {
        require(y < 2**255);
        z = int256(y);
    }
}
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
}
pragma solidity ^0.8.0;

import "./Math.sol";

/**
 * @dev String operations.
 */
library Strings {
    bytes16 private constant _SYMBOLS = "0123456789abcdef";
    uint8 private constant _ADDRESS_LENGTH = 20;

    /**
     * @dev Converts a `uint256` to its ASCII `string` decimal representation.
     */
    function toString(uint256 value) internal pure returns (string memory) {
        unchecked {
            uint256 length = Math.log10(value) + 1;
            string memory buffer = new string(length);
            uint256 ptr;
            /// @solidity memory-safe-assembly
            assembly {
                ptr := add(buffer, add(32, length))
            }
            while (true) {
                ptr--;
                /// @solidity memory-safe-assembly
                assembly {
                    mstore8(ptr, byte(mod(value, 10), _SYMBOLS))
                }
                value /= 10;
                if (value == 0) break;
            }
            return buffer;
        }
    }

    /**
     * @dev Converts a `uint256` to its ASCII `string` hexadecimal representation.
     */
    function toHexString(uint256 value) internal pure returns (string memory) {
        unchecked {
            return toHexString(value, Math.log256(value) + 1);
        }
    }

    /**
     * @dev Converts a `uint256` to its ASCII `string` hexadecimal representation with fixed length.
     */
    function toHexString(uint256 value, uint256 length) internal pure returns (string memory) {
        bytes memory buffer = new bytes(2 * length + 2);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 2 * length + 1; i > 1; --i) {
            buffer[i] = _SYMBOLS[value & 0xf];
            value >>= 4;
        }
        require(value == 0, "Strings: hex length insufficient");
        return string(buffer);
    }

    /**
     * @dev Converts an `address` with fixed length of 20 bytes to its not checksummed ASCII `string` hexadecimal representation.
     */
    function toHexString(address addr) internal pure returns (string memory) {
        return toHexString(uint256(uint160(addr)), _ADDRESS_LENGTH);
    }
}
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
}
