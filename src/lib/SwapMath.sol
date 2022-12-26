// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "./Math.sol";

library SwapMath {
    function computeSwapStep(
        uint160 sqrtPriceCurrentX96, // 当前价格
        uint160 sqrtPriceTargetX96, // 找到的tick对应价格
        uint128 liquidity, // 当前的流动性
        uint256 amountRemaining // 用户的输入
    )
        internal
        pure
        returns (
            uint160 sqrtPriceNextX96,
            uint256 amountIn,
            uint256 amountOut
        )
    {    
        //zero => false pool输出为x(价格上涨)， one => true pool输出为y(价格下跌)
        bool zeroForOne = sqrtPriceCurrentX96 >= sqrtPriceTargetX96;
        amountIn = zeroForOne
        // 当价格下跌，说明pool接受的输入是x
            ? Math.calcAmount0Delta(
                sqrtPriceCurrentX96,
                sqrtPriceTargetX96,
                liquidity
            )
            // 价格上涨，说明pool接受的输入是y
            : Math.calcAmount1Delta(
                sqrtPriceCurrentX96,
                sqrtPriceTargetX96,
                liquidity
            );
        // 当用户输入的token数量大于pool能接受的数量，说明需求已经超过当前price区间,next=target
        if (amountRemaining >= amountIn) sqrtPriceNextX96 = sqrtPriceTargetX96;
        else
            // 如果在区间内，则需要重新计算一个next price
            sqrtPriceNextX96 = Math.getNextSqrtPriceFromInput(
                sqrtPriceCurrentX96,
                liquidity,
                amountRemaining,
                zeroForOne
            );
        // 默认用户输入的是x，兑换的是y
        amountIn = Math.calcAmount0Delta(
            sqrtPriceCurrentX96,
            sqrtPriceNextX96,
            liquidity
        );
        amountOut = Math.calcAmount1Delta(
            sqrtPriceCurrentX96,
            sqrtPriceNextX96,
            liquidity
        );
        // 否则反之
        if (!zeroForOne) {
            (amountIn, amountOut) = (amountOut, amountIn);
        }
    }
}
