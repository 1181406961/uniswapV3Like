// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "./interfaces/IERC20.sol";
import "./interfaces/IUniswapV3FlashCallback.sol";
import "./interfaces/IUniswapV3MintCallback.sol";
import "./interfaces/IUniswapV3Pool.sol";
import "./interfaces/IUniswapV3SwapCallback.sol";
import "./interfaces/IUniswapV3PoolDeployer.sol";

import "./lib/LiquidityMath.sol";
import "./lib/Math.sol";
import "./lib/Position.sol";
import "./lib/SwapMath.sol";
import "./lib/Tick.sol";
import "./lib/TickBitmap.sol";
import "./lib/TickMath.sol";

contract UniswapV3Pool is IUniswapV3Pool {
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;

    error InsufficientInputAmount();
    error InvalidPriceLimit();
    error InvalidTickRange();
    error NotEnoughLiquidity();
    error ZeroLiquidity();
    error AlreadyInitialized();
    // 闪电贷事件
    event Flash(address indexed recipient, uint256 amount0, uint256 amount1);
    // 添加流动性
    event Mint(
        address sender,
        address indexed owner,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );
    // 交换token
    event Swap(
        address indexed sender,
        address indexed recipient,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    );
    // 工厂地址，token0，token1，tickSpacing初始化参数
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable tickSpacing;

    struct Slot0 {
        // 当前价格
        uint160 sqrtPriceX96;
        // 当前价格对应的tick
        int24 tick;
    }

    struct SwapState {
        uint256 amountSpecifiedRemaining; // 用户剩余的输入
        uint256 amountCalculated; // pool计算的输出
        uint160 sqrtPriceX96; // 当前价格
        int24 tick; // 当前tick
        uint128 liquidity; // 当前liquidity
    }

    struct StepState {
        uint160 sqrtPriceStartX96; // 开始价格
        int24 nextTick; // 下一个价格
        bool initialized;
        uint160 sqrtPriceNextX96;
        uint256 amountIn;
        uint256 amountOut;
    }

    Slot0 public slot0;

    // 当前价格区间的总的liquidity
    uint128 public liquidity;

    mapping(int24 => Tick.Info) public ticks;
    mapping(int16 => uint256) public tickBitmap;
    mapping(bytes32 => Position.Info) public positions;

    // constructor(
    //     address token0_,
    //     address token1_,
    //     uint160 sqrtPriceX96,
    //     int24 tick
    // ) {
    //     token0 = token0_;
    //     token1 = token1_;

    //     slot0 = Slot0({sqrtPriceX96: sqrtPriceX96, tick: tick});
    // }
    constructor() {
        (factory, token0, token1, tickSpacing) = IUniswapV3PoolDeployer(
            msg.sender
        ).parameters();
    }

    function initialize(uint160 sqrtPriceX96) public {
        if (slot0.sqrtPriceX96 != 0) revert AlreadyInitialized();

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        slot0 = Slot0({sqrtPriceX96: sqrtPriceX96, tick: tick});
    }

    function mint(
        address owner,
        // 价格区间
        int24 lowerTick,
        int24 upperTick,
        // 用户投入到liquidity
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1) {
        if (
            lowerTick >= upperTick ||
            lowerTick < TickMath.MIN_TICK ||
            upperTick > TickMath.MAX_TICK
        ) revert InvalidTickRange();

        if (amount == 0) revert ZeroLiquidity();

        bool flippedLower = ticks.update(lowerTick, int128(amount), false);
        bool flippedUpper = ticks.update(upperTick, int128(amount), true);

        // 将lower和upper放入到bitMap中
        if (flippedLower) {
            tickBitmap.flipTick(lowerTick, int24(tickSpacing));
        }

        if (flippedUpper) {
            tickBitmap.flipTick(upperTick, int24(tickSpacing));
        }
        // 记录该用户的流动性
        Position.Info storage position = positions.get(
            owner,
            lowerTick,
            upperTick
        );
        position.update(amount);

        Slot0 memory slot0_ = slot0;
        // 只有价格区间包含当前价格的时候才把流动性添加到当前价格中
        if (slot0_.tick < lowerTick) {
            // 当价格区间高于当前价格时，只需要token0，x
            amount0 = Math.calcAmount0Delta(
                TickMath.getSqrtRatioAtTick(lowerTick),
                TickMath.getSqrtRatioAtTick(upperTick),
                amount
            );
        } else if (slot0_.tick < upperTick) {
            // 这里根据用户投入到liquidity，重新计算一下用户需要投入多少token0和token1
            amount0 = Math.calcAmount0Delta(
                slot0_.sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(upperTick),
                amount
            );

            amount1 = Math.calcAmount1Delta(
                slot0_.sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(lowerTick),
                amount
            );
            liquidity = LiquidityMath.addLiquidity(liquidity, int128(amount));
        } else {
            // 当价格区间低于当前价格时，只需要token1，y
            amount1 = Math.calcAmount1Delta(
                TickMath.getSqrtRatioAtTick(lowerTick),
                TickMath.getSqrtRatioAtTick(upperTick),
                amount
            );
        }

        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(
            amount0,
            amount1,
            data
        );
        // 检查用户是否如期转账token0和token1
        if (amount0 > 0 && balance0Before + amount0 > balance0())
            revert InsufficientInputAmount();
        if (amount1 > 0 && balance1Before + amount1 > balance1())
            revert InsufficientInputAmount();

        emit Mint(
            msg.sender,
            owner,
            lowerTick,
            upperTick,
            amount,
            amount0,
            amount1
        );
    }

    function swap(
        address recipient,
        bool zeroForOne, // zero=false输出token0，one=true输出token1，根据公式 p = y/x: 当输出x的时候价格上涨，输出y的时候价格下降
        uint256 amountSpecified, // 与输出token对应的，用户需要投入的多少token
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) public returns (int256 amount0, int256 amount1) {
        Slot0 memory slot0_ = slot0;
        uint128 liquidity_ = liquidity;
        // 滑点保护
        if (
            zeroForOne // 当输出token1时，价格下降，但是不能小于limit
                ? sqrtPriceLimitX96 > slot0_.sqrtPriceX96 ||
                    sqrtPriceLimitX96 < TickMath.MIN_SQRT_RATIO // 当输出token0时，价格上涨，但是不能超过limit
                : sqrtPriceLimitX96 < slot0_.sqrtPriceX96 ||
                    sqrtPriceLimitX96 > TickMath.MAX_SQRT_RATIO
        ) revert InvalidPriceLimit();

        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0_.sqrtPriceX96,
            tick: slot0_.tick,
            liquidity: liquidity_
        });
        // 找到新的next price 对应的tick。
        while (
            state.amountSpecifiedRemaining > 0 &&
            // 当没有next tick的时候，这时不能超过最大，只有部分进行来交易。
            state.sqrtPriceX96 != sqrtPriceLimitX96
        ) {
            StepState memory step;

            step.sqrtPriceStartX96 = state.sqrtPriceX96;
            // 根据当前价格，以及换出的方向，在bitmap中寻找下一个tick。
            (step.nextTick, ) = tickBitmap.nextInitializedTickWithinOneWord(
                state.tick,
                int24(tickSpacing),
                zeroForOne
            );

            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.nextTick);
            // 根据找到的tick获取计算下一个真正的tick和两种token数量
            // 因为找的都是边界tick， next price可能还在边界中，所以需要重新计算一下。
            (state.sqrtPriceX96, step.amountIn, step.amountOut) = SwapMath
                .computeSwapStep(
                    state.sqrtPriceX96,
                    // 滑点保护，防止价格下跌或上涨不超过limit
                    (
                        zeroForOne
                            ? step.sqrtPriceNextX96 < sqrtPriceLimitX96
                            : step.sqrtPriceNextX96 > sqrtPriceLimitX96
                    )
                        ? sqrtPriceLimitX96
                        : step.sqrtPriceNextX96,
                    state.liquidity,
                    state.amountSpecifiedRemaining
                );
            // 减去用户可以输入到pool中的对应token数量
            state.amountSpecifiedRemaining -= step.amountIn;
            // 加上pool给用户的输出token数量
            state.amountCalculated += step.amountOut;
            // 检查是否跨price区间了
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                int128 liquidityDelta = ticks.cross(step.nextTick);
                // 当价格按从lower => upper方向移动时，穿过lower时增加liquidity,穿过upper减少liquidity
                // 当价格按从upper => lower方向移动时，穿过upper增加liquidity，穿过lower减少liquidity
                if (zeroForOne) liquidityDelta = -liquidityDelta;

                state.liquidity = LiquidityMath.addLiquidity(
                    state.liquidity,
                    liquidityDelta
                );
                // 当到达极限边界时，没有流动性了。此时交易只能部分成交
                if (state.liquidity == 0) revert NotEnoughLiquidity();
                // 开闭区间问题 左闭右开，如果穿过下界到下一个区间需要减一
                state.tick = zeroForOne ? step.nextTick - 1 : step.nextTick;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }
        // 更新当前tick到next tick
        if (state.tick != slot0_.tick) {
            (slot0.sqrtPriceX96, slot0.tick) = (state.sqrtPriceX96, state.tick);
        }
        // 更新流动性
        if (liquidity_ != state.liquidity) liquidity = state.liquidity;

        (amount0, amount1) = zeroForOne
           // 转给用户token1，用户转给pool token0
            ? (
                int256(amountSpecified - state.amountSpecifiedRemaining),
                -int256(state.amountCalculated)
            )
            // 转给用户token0，用户转给pool token1
            : (
                -int256(state.amountCalculated),
                int256(amountSpecified - state.amountSpecifiedRemaining)
            );
        if (zeroForOne) {
            // 转给用户token1
            IERC20(token1).transfer(recipient, uint256(-amount1));
            uint256 balance0Before = balance0();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(
                amount0,
                amount1,
                data
            );
            // 用户转给pool token0
            if (balance0Before + uint256(amount0) > balance0())
                revert InsufficientInputAmount();
        } else {
            // 转给用户token0
            IERC20(token0).transfer(recipient, uint256(-amount0));

            uint256 balance1Before = balance1();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(
                amount0,
                amount1,
                data
            );
            // 用户转给pool token1
            if (balance1Before + uint256(amount1) > balance1())
                revert InsufficientInputAmount();
        }

        emit Swap(
            msg.sender,
            recipient,
            amount0,
            amount1,
            slot0.sqrtPriceX96,
            state.liquidity,
            slot0.tick
        );
    }
    // 闪电贷
    function flash(
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) public {
        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));

        if (amount0 > 0) IERC20(token0).transfer(msg.sender, amount0);
        if (amount1 > 0) IERC20(token1).transfer(msg.sender, amount1);

        IUniswapV3FlashCallback(msg.sender).uniswapV3FlashCallback(data);

        require(IERC20(token0).balanceOf(address(this)) >= balance0Before);
        require(IERC20(token1).balanceOf(address(this)) >= balance1Before);

        emit Flash(msg.sender, amount0, amount1);
    }

    ////////////////////////////////////////////////////////////////////////////
    //
    // INTERNAL
    //
    ////////////////////////////////////////////////////////////////////////////
    function balance0() internal returns (uint256 balance) {
        balance = IERC20(token0).balanceOf(address(this));
    }

    function balance1() internal returns (uint256 balance) {
        balance = IERC20(token1).balanceOf(address(this));
    }
}
