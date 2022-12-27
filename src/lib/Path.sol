// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

import "./BytesLib.sol";

library BytesLibExt {
    // 扩展BytesLib,基于BytesLib的实现，新增一个toUint24
    function toUint24(bytes memory _bytes, uint256 _start)
        internal
        pure
        returns (uint24)
    {
        // 判断必须得有3个字节
        require(_bytes.length >= _start + 3, "toUint24_outOfBounds");
        uint24 tempUint;

        assembly {
            // 移动三个字节并读取
            tempUint := mload(add(add(_bytes, 0x3), _start))
        }

        return tempUint;
    }
}

library Path {
    using BytesLib for bytes;
    using BytesLibExt for bytes;

    // token地址大小
    uint256 private constant ADDR_SIZE = 20;
    // tickSpacing大小
    uint256 private constant TICKSPACING_SIZE = 3;

    // 下一个token位置偏移 token+tickSpacing
    uint256 private constant NEXT_OFFSET = ADDR_SIZE + TICKSPACING_SIZE;
    // 编码的池子偏移 token+tickSpacing+token
    uint256 private constant POP_OFFSET = NEXT_OFFSET + ADDR_SIZE;
    /// 包括两个或以上的池子路径偏移长度
    uint256 private constant MULTIPLE_POOLS_MIN_LENGTH =
        POP_OFFSET + NEXT_OFFSET;

    function hasMultiplePools(bytes memory path) internal pure returns (bool) {
        // 判断一个路径中有多个池子
        return path.length >= MULTIPLE_POOLS_MIN_LENGTH;
    }

    function numPools(bytes memory path) internal pure returns (uint256) {
        // 计算路径中池子数量
        return (path.length - ADDR_SIZE) / NEXT_OFFSET;
    }

    function getFirstPool(bytes memory path)
        internal
        pure
        returns (bytes memory)
    {
        return path.slice(0, POP_OFFSET);
    }

    function skipToken(bytes memory path) internal pure returns (bytes memory) {
        // 跳过token+tickSpacing一部分，进入到下一部分
        return path.slice(NEXT_OFFSET, path.length - NEXT_OFFSET);
    }

    function decodeFirstPool(bytes memory path)
        internal
        pure
        returns (
            address tokenIn,
            address tokenOut,
            uint24 tickSpacing
        )
    {
        // 解码第一个池子参数
        tokenIn = path.toAddress(0);
        tickSpacing = path.toUint24(ADDR_SIZE);
        tokenOut = path.toAddress(NEXT_OFFSET);
    }
}