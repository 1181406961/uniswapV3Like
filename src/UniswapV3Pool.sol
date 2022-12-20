pragma solidity ^0.8.14;
import "./lib/Position.sol";
import "./lib/Tick.sol";
import "./lib/IUniswapV3MintCallback.sol";
import "forge-std/interfaces/IERC20.sol";

contract UniswapV3Pool {
    using Tick for mapping(int24 => Tick.Info);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    // 结构体
    // packing 两个元素，因为总是同时读取它们
    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
    }
    struct CallbackData {
        address token0;
        address token1;
        address payer;
    }
    // 变量定义
    // tick 的最大最小范围 2**128
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = -MIN_TICK;
    // 两种token
    address public immutable token0;
    address public immutable token1;
    Slot0 public slot0;
    // L
    uint128 public liquidity;
    // Ticks信息
    mapping(int24 => Tick.Info) public ticks;
    // Position信息
    mapping(bytes32 => Position.Info) public positions;
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
    // 错误信息
    error InvalidTickRange();
    error ZeroLiquidity();
    error InsufficientInputAmount();

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
        ticks.update(lowerTick, amount);
        ticks.update(upperTick, amount);
        Position.Info storage position = positions.get(
            owner,
            lowerTick,
            upperTick
        );
        position.update(amount);
        // 这里先假定用户放了这么多，根据预先的公式计算，这里先写死用户只输入这么多
        amount0 = 0.998976618347425280 ether;
        amount1 = 5000 ether;
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

    function swap(address recipient,bytes calldata data)
        public
        returns (int256 amount0, int256 amount1)
    {
        // 这里先写死,后面再改
        int24 nextTick = 85184;
        uint160 nextPrice = 5604469350942327889444743441197;
        amount0 = -0.008396714242162444 ether;
        amount1 = 42 ether;
        (slot0.tick, slot0.sqrtPriceX96) = (nextTick, nextPrice);
        IERC20(token0).transfer(recipient, uint256(-amount0));
        uint256 balance1Before = balance1();
        IUniswapV3MintCallback(msg.sender).uniswapV3SwapCallback(
            amount0,
            amount1,
            data
        );
        if (balance1Before + uint256(amount1) > balance1()) {
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
