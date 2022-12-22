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
        // tick 上边界
        int24 lowerTick,
        // tick 下边界
        int24 upperTick,
        // 投入多少流动性
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

    // src/UniswapV3Pool.sol

    function swap(
        address recipient,
        bool zeroForOne, //换出什么: zero => token0(x) one=>token1(y)
        uint256 amountSpecified,
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
            // 根据当前开始循环的tick，找下一个tick是什么
            (step.nextTick, ) = tickBitmap.nextInitializedTickWithinOneWord(
                state.tick,
                1,
                zeroForOne
            );
            // 获取到下一个tick，然后求出对应的price是什么
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.nextTick);
            // 根据当前的price和next price 算出交换后的price和需要换入换出多少
            (state.sqrtPriceX96, step.amountIn, step.amountOut) = SwapMath
                .computeSwapStep(
                    state.sqrtPriceX96,
                    step.sqrtPriceNextX96,
                    liquidity,
                    state.amountSpecifiedRemaining
                );
            state.amountSpecifiedRemaining -= step.amountIn;
            state.amountCalculated += step.amountOut;
            state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
        }
        // 更新tick,到下一个价格
        if (state.tick != slot0_.tick) {
            (slot0.sqrtPriceX96, slot0.tick) = (state.sqrtPriceX96, state.tick);
        }
        (amount0, amount1) = zeroForOne
            ? (
                int256(amountSpecified - state.amountSpecifiedRemaining),
                -int256(state.amountCalculated)
            )
            : (
                -int256(state.amountCalculated),
                int256(amountSpecified - state.amountSpecifiedRemaining)
            );
        // 根据方向来决定换入哪种token和换出哪种token
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
        // 这里先写死,后面再改
        // int24 nextTick = 85184;
        // uint160 nextPrice = 5604469350942327889444743441197;
        // amount0 = -0.008396714242162444 ether;
        // amount1 = 42 ether;
        // (slot0.tick, slot0.sqrtPriceX96) = (nextTick, nextPrice);
        // IERC20(token0).transfer(recipient, uint256(-amount0));
        // uint256 balance1Before = balance1();
        // IuniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(
        //     amount0,
        //     amount1,
        //     data
        // );
        // if (balance1Before + uint256(amount1) > balance1()) {
        //     revert InsufficientInputAmount();
        // }
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
