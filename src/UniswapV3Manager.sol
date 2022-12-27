// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "./interfaces/IERC20.sol";
import "./interfaces/IUniswapV3Pool.sol";
import "./interfaces/IUniswapV3Manager.sol";
import "./lib/LiquidityMath.sol";
import "./lib/Path.sol";
import "./lib/PoolAddress.sol";
import "./lib/TickMath.sol";

contract UniswapV3Manager is IUniswapV3Manager {
    using Path for bytes;

    error SlippageCheckFailed(uint256 amount0, uint256 amount1);
    error TooLittleReceived(uint256 amountOut);

    address public immutable factory;

    constructor(address factory_) {
        factory = factory_;
    }

    function mint(MintParams calldata params)
        public
        returns (uint256 amount0, uint256 amount1)
    {
        // 直接根据输入的token计算出合约地址是什么
        address poolAddress = PoolAddress.computeAddress(
            factory,
            params.tokenA,
            params.tokenB,
            params.tickSpacing
        );
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);
        // 获取current price，lower price，upper price
        (uint160 sqrtPriceX96, ) = pool.slot0();
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtRatioAtTick(
            params.lowerTick
        );
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtRatioAtTick(
            params.upperTick
        );
        // 根据用户投入，以及当前价格，与价格区间算出用户对应的liquidity是多少
        uint128 liquidity = LiquidityMath.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceLowerX96,
            sqrtPriceUpperX96,
            params.amount0Desired,
            params.amount1Desired
        );

        (amount0, amount1) = pool.mint(
            msg.sender,
            params.lowerTick,
            params.upperTick,
            liquidity,
            abi.encode(
                IUniswapV3Pool.CallbackData({
                    token0: pool.token0(),
                    token1: pool.token1(),
                    payer: msg.sender
                })
            )
        );
        // mint的滑点保护
        if (amount0 < params.amount0Min || amount1 < params.amount1Min)
            revert SlippageCheckFailed(amount0, amount1);
    }

    function swapSingle(SwapSingleParams calldata params)
        public
        returns (uint256 amountOut)
    {
        // 单池子交易，只调用一次_swap
        amountOut = _swap(
            params.amountIn,
            msg.sender,
            params.sqrtPriceLimitX96,
            SwapCallbackData({
                path: abi.encodePacked(
                    params.tokenIn,
                    params.tickSpacing,
                    params.tokenOut
                ),
                payer: msg.sender
            })
        );
    }

    function swap(SwapParams memory params) public returns (uint256 amountOut) {
        // 多池子交易
        address payer = msg.sender;
        bool hasMultiplePools;

        while (true) {
            // 检查路径是否为多池子交易
            hasMultiplePools = params.path.hasMultiplePools();

            params.amountIn = _swap(
                params.amountIn,
                hasMultiplePools ? address(this) : params.recipient,
                0,
                SwapCallbackData({
                    path: params.path.getFirstPool(),
                    payer: payer
                })
            );
            // 每次跳过上一个部分进
            if (hasMultiplePools) {
                payer = address(this);
                params.path = params.path.skipToken();
            } else {
                amountOut = params.amountIn;
                break;
            }
        }
        // 进行校验，滑点保护
        if (amountOut < params.minAmountOut)
            revert TooLittleReceived(amountOut);
    }

    function _swap(
        uint256 amountIn,
        address recipient,
        uint160 sqrtPriceLimitX96,
        SwapCallbackData memory data
    ) internal returns (uint256 amountOut) {
        // 交换token，支持多对token之间的交换
        // 先获取第一对token
        (address tokenIn, address tokenOut, uint24 tickSpacing) = data
            .path
            .decodeFirstPool();
        // 因为创建的时候按顺序决定的tokenX和tokenY，这里排序就知道兑换方向了
        bool zeroForOne = tokenIn < tokenOut;
        // 获取pool地址
        (int256 amount0, int256 amount1) = getPool(
            tokenIn,
            tokenOut,
            tickSpacing
        ).swap(
                recipient,
                zeroForOne,
                amountIn,
                // 滑点保护，始终不超过上下限，sqrtPriceLimitX96=0对时候没有滑点保护
                sqrtPriceLimitX96 == 0
                    ? (
                        zeroForOne
                            ? TickMath.MIN_SQRT_RATIO + 1
                            : TickMath.MAX_SQRT_RATIO - 1
                    )
                    : sqrtPriceLimitX96,
                abi.encode(data)
            );

        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
    }

    function getPool(
        address token0,
        address token1,
        uint24 tickSpacing
    ) internal view returns (IUniswapV3Pool pool) {
        // 根据token信息推算pool地址
        (token0, token1) = token0 < token1
            ? (token0, token1)
            : (token1, token0);
        pool = IUniswapV3Pool(
            PoolAddress.computeAddress(factory, token0, token1, tickSpacing)
        );
    }

    function uniswapV3MintCallback(
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) public {
        // mint回调，pool合约的mint方法会回调此方法
        // pool合约默认调用它的是合约，不是eoa账号，pool会假定调用它的合约会实现该方法
        IUniswapV3Pool.CallbackData memory extra = abi.decode(
            data,
            (IUniswapV3Pool.CallbackData)
        );
        // 按要求向pool合约中转账,需要用户提前进行授权
        IERC20(extra.token0).transferFrom(extra.payer, msg.sender, amount0);
        IERC20(extra.token1).transferFrom(extra.payer, msg.sender, amount1);
    }

    function uniswapV3SwapCallback(
        int256 amount0,
        int256 amount1,
        bytes calldata data_
    ) public {
        // 同mint方法，pool合约会假定调用它的合约实现了该方法
        SwapCallbackData memory data = abi.decode(data_, (SwapCallbackData));
        (address tokenIn, address tokenOut, ) = data.path.decodeFirstPool();

        bool zeroForOne = tokenIn < tokenOut;

        int256 amount = zeroForOne ? amount0 : amount1;
        // 如果是manager合约自己调用的pool，说明这是一个多池子交易中的一环，则manager转给pool
        if (data.payer == address(this)) {
            IERC20(tokenIn).transfer(msg.sender, uint256(amount));
        } else {
            // 如果不是，则是用户将token转给pool
            IERC20(tokenIn).transferFrom(
                data.payer,
                msg.sender,
                uint256(amount)
            );
        }
    }
}