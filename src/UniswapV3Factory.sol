// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;
import "./interfaces/IUniswapV3PoolDeployer.sol";
import "./UniswapV3Pool.sol";

contract UniswapV3Factory is IUniswapV3PoolDeployer {
    error PoolAlreadyExists();
    error ZeroAddressNotAllowed();
    error TokensMustBeDifferent();
    error UnsupportedFee();

    event PoolCreated(
        address indexed token0,
        address indexed token1,
        uint24 indexed fee,
        address pool
    );

    PoolParameters public parameters;

    // tick之间的间隔，简单起见，只有10和60
    // 费率和tickSpace之间绑定
    mapping(uint24 => uint24) public fees;
    mapping(address => mapping(address => mapping(uint24 => address)))
        public pools;

    constructor() {
        // 费率和tickSpacing绑定
        fees[500] = 10;
        fees[3000] = 60;
    }

    // 创建配对合约,也就是pool
    function createPool(
        address tokenX,
        address tokenY,
        uint24 fee 
    ) public returns (address pool) {
        if (tokenX == tokenY) revert TokensMustBeDifferent();
        if (fees[fee] == 0) revert UnsupportedFee();
        // 这里对两种token进行排序，让token0多地址始终小于token1，这样可以快速判断谁是x或y，计算价格流动方向
        (tokenX, tokenY) = tokenX < tokenY
            ? (tokenX, tokenY)
            : (tokenY, tokenX);

        if (tokenX == address(0)) revert ZeroAddressNotAllowed();
        if (pools[tokenX][tokenY][fee] != address(0))
            revert PoolAlreadyExists();

        parameters = PoolParameters({
            factory: address(this),
            token0: tokenX,
            token1: tokenY,
            tickSpacing: fees[fee],
            fee:fee
        });
        // 调用create2，计算salt值
        // 控制反转，pool合约通过接口IUniswapV3PoolDeployer获取参数
        pool = address(
            new UniswapV3Pool{
                salt: keccak256(abi.encodePacked(tokenX, tokenY, fee))
            }()
        );
        // 重置存储节省gas
        delete parameters;

        pools[tokenX][tokenY][fee] = pool;
        pools[tokenY][tokenX][fee] = pool;

        emit PoolCreated(tokenX, tokenY, fee, pool);
    }
}
