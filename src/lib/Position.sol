// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;
import "./PRBMath.sol";
import "./FixedPoint128.sol";
import "./LiquidityMath.sol";

library Position {
    struct Info {
        uint128 liquidity; // 该positon总的流动性
        // 区间内费用累计追踪器
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0; // token0累计应得的手续费
        uint128 tokensOwed1; // token1累计应得的手续费
    }

    function get(
        mapping(bytes32 => Info) storage self,
        address owner,
        int24 lowerTick,
        int24 upperTick
    ) internal view returns (Position.Info storage position) {
        position = self[
            keccak256(abi.encodePacked(owner, lowerTick, upperTick))
        ];
    }

    // 只有添加和删除流动性的时候会调用
    function update(
        Info storage self,
        int128 liquidityDelta, // 要添加或删除的流动性
        uint256 feeGrowthInside0X128,
        uint256 feeGrowthInside1X128
    ) internal {
        // 每单位流动性费用增量=本次-上次
        // 两种token应得的费用=每单位流动性费用 * position的流动性
        uint128 tokensOwed0 = uint128(
            PRBMath.mulDiv(
                feeGrowthInside0X128 - self.feeGrowthInside0LastX128,
                self.liquidity,
                FixedPoint128.Q128
            )
        );
        uint128 tokensOwed1 = uint128(
            PRBMath.mulDiv(
                feeGrowthInside1X128 - self.feeGrowthInside1LastX128,
                self.liquidity,
                FixedPoint128.Q128
            )
        );
        // 更新liquidity
        self.liquidity = LiquidityMath.addLiquidity(
            self.liquidity,
            liquidityDelta
        );
        // 记录最新累计,方便下次计算
        self.feeGrowthInside0LastX128 = feeGrowthInside0X128;
        self.feeGrowthInside1LastX128 = feeGrowthInside1X128;
        // 应得手续费在原来基础上加
        if (tokensOwed0 > 0 || tokensOwed1 > 0) {
            self.tokensOwed0 += tokensOwed0;
            self.tokensOwed1 += tokensOwed1;
        }
    }
}
