// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

import "../UniswapV3Pool.sol";

library PoolAddress {
    // 模拟create2计算合约地址
    function computeAddress(
        address factory,
        address token0,
        address token1,
        uint24 tickSpacing
    ) internal pure returns (address pool) {
        require(token0 < token1);
        // create2底层实现原理
        pool = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            factory,
                            keccak256(
                                abi.encodePacked(token0, token1, tickSpacing)
                            ),
                            // 加入createCode防止hash碰撞
                            keccak256(type(UniswapV3Pool).creationCode)
                        )
                    )
                )
            )
        );
    }
}