// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

import "./PRBMath.sol";
import "./FixedPoint96.sol";

library LiquidityMath {
    /// $L = \frac{\Delta x \sqrt{P_u} \sqrt{P_l}}{\Delta \sqrt{P}}$
    function getLiquidityForAmount0(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0
    ) internal pure returns (uint128 liquidity) {
        if (sqrtPriceAX96 > sqrtPriceBX96)
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);

        uint256 intermediate = PRBMath.mulDiv(
            sqrtPriceAX96,
            sqrtPriceBX96,
            FixedPoint96.Q96
        );
        liquidity = uint128(
            PRBMath.mulDiv(amount0, intermediate, sqrtPriceBX96 - sqrtPriceAX96)
        );
    }

    /// $L = \frac{\Delta y}{\Delta \sqrt{P}}$
    function getLiquidityForAmount1(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtPriceAX96 > sqrtPriceBX96)
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);

        liquidity = uint128(
            PRBMath.mulDiv(
                amount1,
                FixedPoint96.Q96,
                sqrtPriceBX96 - sqrtPriceAX96
            )
        );
    }

    function getLiquidityForAmounts(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,// 下界
        uint160 sqrtPriceBX96,// 上界
        uint256 amount0, // token 0
        uint256 amount1  // token 1
    ) internal pure returns (uint128 liquidity) {
        // 根据用户选择的price区间，price和两种token计算对应的liquidity
        if (sqrtPriceAX96 > sqrtPriceBX96)
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        //如果当前的price小于lower 说明price区间高于当前，则只需要token0,x
        if (sqrtPriceX96 <= sqrtPriceAX96) {
            liquidity = getLiquidityForAmount0(
                sqrtPriceAX96,
                sqrtPriceBX96,
                amount0
            );
        // 表面提供的price区间包含当前价格，则算入到当前流动性中
        } else if (sqrtPriceX96 <= sqrtPriceBX96) {
            uint128 liquidity0 = getLiquidityForAmount0(
                sqrtPriceX96,
                sqrtPriceBX96,
                amount0
            );
            uint128 liquidity1 = getLiquidityForAmount1(
                sqrtPriceAX96,
                sqrtPriceX96,
                amount1
            );
            // 取最小值
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            // 说明当前的price高于price区间，则只需要token1,y
            liquidity = getLiquidityForAmount1(
                sqrtPriceAX96,
                sqrtPriceBX96,
                amount1
            );
        }
    }

    function addLiquidity(uint128 x, int128 y)
        internal
        pure
        returns (uint128 z)
    {
        if (y < 0) {
            z = x - uint128(-y);
        } else {
            z = x + uint128(y);
        }
    }
}
