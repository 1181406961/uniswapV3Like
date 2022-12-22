pragma solidity ^0.8.14;
import "forge-std/interfaces/IERC20.sol";

import "./lib/IUniswapV3Callback.sol";
import "./lib/Position.sol";
import "./lib/Tick.sol";
import "./lib/Math.sol";
import "./lib/Position.sol";
import "./lib/Tick.sol";
import "./lib/TickBitmap.sol";
import "./lib/TickMath.sol";
import "./lib/SwapMath.sol";

contract UniswapV3Pool {
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    // 错误信息
    error InvalidTickRange();
    error ZeroLiquidity();
    error InsufficientInputAmount();
    // 相关事件
    // mint
    event Mint(
        address indexed sender,
        address indexed owner,
        int24 lowerTick,
        int24 upperTick,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );
    // 交换代币
    event Swap(
        address indexed sender,
        address indexed recipient,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        uint128 amount,
        int24 tick
    );
    // 结构体
    // packing 两个元素，因为总是同时读取它们
    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
    }
    // 对必要数据进行打包操作
    struct CallbackData {
        address token0;
        address token1;
        address payer;
    }
    struct SwapState {
        // 剩余需要交换的
        uint256 amountSpecifiedRemaining;
        // pool计算可以换出的
        uint256 amountCalculated;
        // 新price和tick
        uint160 sqrtPriceX96;
        int24 tick;
    }

    struct StepState {
        // 开始时的price
        uint160 sqrtPriceStartX96;
        // 下一个tick
        int24 nextTick;
        // 下一个price
        uint160 sqrtPriceNextX96;
        //  当前的in和out
        uint256 amountIn;
        uint256 amountOut;
    }
    // 变量定义
    // tick 的最大最小范围 2**128
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = -MIN_TICK;
    // 两种token
    address public immutable token0;
    address public immutable token1;
    // 同时记录当前price和tick
    Slot0 public slot0;
    // L
    uint128 public liquidity;
    // Ticks信息
    mapping(int24 => Tick.Info) public ticks;
    // Position信息
    mapping(bytes32 => Position.Info) public positions;
    // ticks索引
    mapping(int16 => uint256) public tickBitmap;

    // 初始化两种token，保存当前price和tick
    constructor(
        address token0_,
        address token1_,
        uint160 sqrtPriceX96,
        int24 tick
    ) {
        token0 = token0_;
        token1 = token1_;
        slot0 = Slot0({sqrtPriceX96: sqrtPriceX96, tick: tick});
    }

    // v2中mint的Token，v3中mint的是NFT,延续了惯用方法
    function mint(
        // owner 是谁
        address owner,
        // tick 上边界(需要用户自定义)
        int24 lowerTick,
        // tick 下边界(需要用户自定义)
        int24 upperTick,
        // 投入多少流动性(需要用户自定义)
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1) {
        if (
            lowerTick >= upperTick ||
            lowerTick < MIN_TICK ||
            upperTick > MAX_TICK
        ) {
            revert InvalidTickRange();
        }
        if (amount == 0) {
            revert ZeroLiquidity();
        }
        bool flippedLower = ticks.update(lowerTick, amount);
        bool flippedUpper = ticks.update(upperTick, amount);
        // 记录流动性创建index
        if (flippedLower) {
            tickBitmap.flipTick(lowerTick, 1);
        }
        if (flippedUpper) {
            tickBitmap.flipTick(upperTick, 1);
        }
        Position.Info storage position = positions.get(
            owner,
            lowerTick,
            upperTick
        );
        position.update(amount);
        Slot0 memory slot0_ = slot0;
        // 根据用户输入的流动性和price，计算出用户需要投入多少x和y。
        // amount0 => x
        amount0 = Math.calcAmount0Delta(
            slot0_.sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(upperTick),
            amount
        );
        // amount1 => y
        amount1 = Math.calcAmount1Delta(
            slot0_.sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(lowerTick),
            amount
        );
        // 更新流动性
        liquidity += uint128(amount);
        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0 > 0) {
            balance0Before = balance0();
        }
        if (amount1 > 0) {
            balance1Before = balance1();
        }
        // sender必须是一个合约
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(
            amount0,
            amount1,
            data
        );
        // 这里检查一下sender是否按要求转账
        if (amount0 > 0 && balance0Before + amount0 > balance0()) {
            revert InsufficientInputAmount();
        }
        if (amount1 > 0 && balance1Before + amount1 > balance1()) {
            revert InsufficientInputAmount();
        }
        // 触发一下事件
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

    // TODO 重构提取获取价格算法,提取为一个view或pure方法,方便前端使用
    function swap(
        address recipient, // 接受地址
        bool zeroForOne, //换出什么: zero => token0(x) one=>token1(y)
        uint256 amountSpecified, // 对应换出，需要投入多少相应另一种token。比如换x，需要投入y。
        bytes calldata data
    ) public returns (int256 amount0, int256 amount1) {
        Slot0 memory slot0_ = slot0;
        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0_.sqrtPriceX96,
            tick: slot0_.tick
        });
        while (state.amountSpecifiedRemaining > 0) {
            StepState memory step;
            step.sqrtPriceStartX96 = state.sqrtPriceX96;
            // 根据当前系统的tick，找下一个tick是什么
            (step.nextTick, ) = tickBitmap.nextInitializedTickWithinOneWord(
                state.tick,
                1,
                zeroForOne
            );
            // 获取到下一个tick，然后求出对应的price是什么
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.nextTick);
            // 根据当前的price和找到的next price 算出交换后的price和两种token分别需要多少。
            // 这里需要重新计算一下next price。因为上一步通过bitmap找到的可能是一个边界price，
            // 然而交换需要token数量引起的price改变可能不会到达边界price。
            (state.sqrtPriceX96, step.amountIn, step.amountOut) = SwapMath
                .computeSwapStep(
                    state.sqrtPriceX96,
                    step.sqrtPriceNextX96,
                    liquidity,
                    state.amountSpecifiedRemaining
                );
            // 更新state
            state.amountSpecifiedRemaining -= step.amountIn;
            state.amountCalculated += step.amountOut;
            state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
        }
        // 检查一下state，更新系统当前的tick和price。
        if (state.tick != slot0_.tick) {
            (slot0.sqrtPriceX96, slot0.tick) = (state.sqrtPriceX96, state.tick);
        }
        // 根据 false=x true=y 来决定pool应该出和入哪种token
        (amount0, amount1) = zeroForOne
            ? (
                int256(amountSpecified - state.amountSpecifiedRemaining),
                -int256(state.amountCalculated)
            )
            : (
                -int256(state.amountCalculated),
                int256(amountSpecified - state.amountSpecifiedRemaining)
            );
        if (zeroForOne) {
            IERC20(token1).transfer(recipient, uint256(-amount1));

            uint256 balance0Before = balance0();
            IuniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(
                amount0,
                amount1,
                data
            );
            if (balance0Before + uint256(amount0) > balance0())
                revert InsufficientInputAmount();
        } else {
            IERC20(token0).transfer(recipient, uint256(-amount0));

            uint256 balance1Before = balance1();
            IuniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(
                amount0,
                amount1,
                data
            );
            if (balance1Before + uint256(amount1) > balance1())
                revert InsufficientInputAmount();
        }
        emit Swap(
            msg.sender,
            recipient,
            amount0,
            amount1,
            slot0.sqrtPriceX96,
            liquidity,
            slot0.tick
        );
    }

    function balance0() internal view returns (uint256 balance) {
        balance = IERC20(token0).balanceOf(address(this));
    }

    function balance1() internal view returns (uint256 balance) {
        balance = IERC20(token1).balanceOf(address(this));
    }
}
