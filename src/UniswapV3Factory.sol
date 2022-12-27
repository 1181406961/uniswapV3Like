// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;
import "./interfaces/IUniswapV3PoolDeployer.sol";
import "./UniswapV3Pool.sol";

contract UniswapV3Factory is IUniswapV3PoolDeployer {
    error PoolAlreadyExists();
    error ZeroAddressNotAllowed();
    error TokensMustBeDifferent();
    error UnsupportedTickSpacing();

    event PoolCreated(
        address indexed token0,
        address indexed token1,
        uint24 indexed tickSpacing,
        address pool
    );

    PoolParameters public parameters;
    
    // tick之间的间隔，简单起见，只有10和60
    mapping(uint24 => bool) public tickSpacings;
    mapping(address => mapping(address => mapping(uint24 => address)))
        public pools;

    constructor() {
        // 初始化两种space
        tickSpacings[10] = true;
        tickSpacings[60] = true;
    }
    // 创建配对合约,也就是pool
    function createPool(
        address tokenX,
        address tokenY,
        uint24 tickSpacing
    ) public returns (address pool) {
        if (tokenX == tokenY) revert TokensMustBeDifferent();
        if (!tickSpacings[tickSpacing]) revert UnsupportedTickSpacing();
        // 这里对两种token进行排序，让token0多地址始终小于token1，这样可以快速判断谁是x或y，计算价格流动方向
        (tokenX, tokenY) = tokenX < tokenY
            ? (tokenX, tokenY)
            : (tokenY, tokenX);

        if (tokenX == address(0)) revert ZeroAddressNotAllowed();
        if (pools[tokenX][tokenY][tickSpacing] != address(0))
            revert PoolAlreadyExists();

        parameters = PoolParameters({
            factory: address(this),
            token0: tokenX,
            token1: tokenY,
            tickSpacing: tickSpacing
        });
        // 控制反转，pool合约通过接口IUniswapV3PoolDeployer获取参数
        pool = address(
            new UniswapV3Pool{
                salt: keccak256(abi.encodePacked(tokenX, tokenY, tickSpacing))
            }()
        );
        // 重置存储节省gas
        delete parameters;

        pools[tokenX][tokenY][tickSpacing] = pool;
        pools[tokenY][tokenX][tickSpacing] = pool;

        emit PoolCreated(tokenX, tokenY, tickSpacing, pool);
    }
}
