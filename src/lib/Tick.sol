// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "./LiquidityMath.sol";
import "./Math.sol";

library Tick {
    struct Info {
        bool initialized;
        // 总的流动性
        uint128 liquidityGross;
        // 当跨tick的时候需要添加或删除的流动性
        int128 liquidityNet;
    }

    function update(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        int128 liquidityDelta,
        bool upper
    ) internal returns (bool flipped) {
        Tick.Info storage tickInfo = self[tick];

        uint128 liquidityBefore = tickInfo.liquidityGross;
        uint128 liquidityAfter = LiquidityMath.addLiquidity(
            liquidityBefore,
            liquidityDelta
        );

        flipped = (liquidityAfter == 0) != (liquidityBefore == 0);

        if (liquidityBefore == 0) {
            tickInfo.initialized = true;
        }

        tickInfo.liquidityGross = liquidityAfter;
        tickInfo.liquidityNet = upper
            // 当移动出当前price区间的upper减少流动性
            ? int128(int256(tickInfo.liquidityNet) - liquidityDelta)
            // 当进入到当前的price区间的lower增加流动性
            : int128(int256(tickInfo.liquidityNet) + liquidityDelta);
    }
    // 当tick跨区时返回需要添加或减少的流动性
    function cross(mapping(int24 => Tick.Info) storage self, int24 tick)
        internal
        view
        returns (int128 liquidityDelta)
    {
        Tick.Info storage info = self[tick];
        liquidityDelta = info.liquidityNet;
    }
}
