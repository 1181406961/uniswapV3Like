// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

library FixedPoint96 {
    // uniswap使用UN64x96二进制定点数
    uint8 internal constant RESOLUTION = 96;
    uint256 internal constant Q96 = 2**96;
}
