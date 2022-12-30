// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "./Math.sol";

library SwapMath {
    function computeSwapStep(
        uint160 sqrtPriceCurrentX96, // 当前价格
        uint160 sqrtPriceTargetX96, // 找到的tick对应价格
        uint128 liquidity, // 当前的流动性
        uint256 amountRemaining, // 用户的输入
        uint24 fee
    )
        internal
        pure
        returns (
            uint160 sqrtPriceNextX96,
            uint256 amountIn,
            uint256 amountOut,
            uint256 feeAmount
        )
    {
        //zero => false pool输出为x(价格上涨)， one => true pool输出为y(价格下跌)
        bool zeroForOne = sqrtPriceCurrentX96 >= sqrtPriceTargetX96;
        // 计算费率之后的amountRemaining
        uint256 amountRemainingLessFee = PRBMath.mulDiv(
            amountRemaining,
            // 一个费率单位是0.0001%,也就是1e6最大
            1e6 - fee,
            1e6
        );
        // 计算当前的流动性支持在current => target之间能支持的amountIn
        amountIn = zeroForOne // 当价格下跌，说明pool接受的输入是x
            ? Math.calcAmount0Delta(
                sqrtPriceCurrentX96,
                sqrtPriceTargetX96,
                liquidity,
                true
            ) // 价格上涨，说明pool接受的输入是y
            : Math.calcAmount1Delta(
                sqrtPriceCurrentX96,
                sqrtPriceTargetX96,
                liquidity,
                true
            );
        // 当用户输入的token数量大于pool能接受的数量，说明需求已经超过当前price区间,next=target
        if (amountRemainingLessFee >= amountIn)
            sqrtPriceNextX96 = sqrtPriceTargetX96;
        else
            // 如果在区间内，则需要重新计算一个next price
            sqrtPriceNextX96 = Math.getNextSqrtPriceFromInput(
                sqrtPriceCurrentX96,
                liquidity,
                amountRemainingLessFee,
                zeroForOne
            );
        bool max = sqrtPriceNextX96 == sqrtPriceTargetX96;
         if (zeroForOne) {
            amountIn = max
                ? amountIn
                : Math.calcAmount0Delta(
                    sqrtPriceCurrentX96,
                    sqrtPriceNextX96,
                    liquidity,
                    true
                );
            amountOut = Math.calcAmount1Delta(
                sqrtPriceCurrentX96,
                sqrtPriceNextX96,
                liquidity,
                false
            );
        } else {
            amountIn = max
                ? amountIn
                : Math.calcAmount1Delta(
                    sqrtPriceCurrentX96,
                    sqrtPriceNextX96,
                    liquidity,
                    true
                );
            amountOut = Math.calcAmount0Delta(
                sqrtPriceCurrentX96,
                sqrtPriceNextX96,
                liquidity,
                false
            );
        }
         if (!max) {
            // 如果在区间内说明可用满足需求，此时的fee就是用户投入与实际需要之差
            feeAmount = amountRemaining - amountIn;
        } else {
            // 如果区间无法满足需要，只考虑这个价格区间实际满足的交易数量的fee
            feeAmount = Math.mulDivRoundingUp(amountIn, fee, 1e6 - fee);
        }
    }
}
