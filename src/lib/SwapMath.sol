// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "./Math.sol";

library SwapMath {
    function computeSwapStep(
        uint160 sqrtPriceCurrentX96,
        uint160 sqrtPriceTargetX96,
        uint128 liquidity,
        uint256 amountRemaining
    )
        internal
        pure
        returns (
            uint160 sqrtPriceNextX96,
            uint256 amountIn,
            uint256 amountOut
        )
    {
        // 根据找到的next price决定时兑换x还是y
        bool zeroForOne = sqrtPriceCurrentX96 >= sqrtPriceTargetX96;
        amountIn = zeroForOne
            ? Math.calcAmount0Delta(
                sqrtPriceCurrentX96,
                sqrtPriceTargetX96,
                liquidity
            )
            : Math.calcAmount1Delta(
                sqrtPriceCurrentX96,
                sqrtPriceTargetX96,
                liquidity
            );
        // 判断一当前price range区间中的liquidity是不是足够兑换,如果不够则可能需要跨区搜索。
        if (amountRemaining >= amountIn)
            sqrtPriceNextX96 = sqrtPriceTargetX96;
        else
            // 根据用户需要兑换的token数量，从新计算next price为多少
            sqrtPriceNextX96 = Math.getNextSqrtPriceFromInput(
                sqrtPriceCurrentX96,
                liquidity,
                amountRemaining,
                zeroForOne
            );

        // 根据算出的next price和维持的liquidity，重新计算需要两种代币为多少
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
        // 根据方向决定换入还是换出
        if (!zeroForOne) {
            (amountIn, amountOut) = (amountOut, amountIn);
        }
    }
}
