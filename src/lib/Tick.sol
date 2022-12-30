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
        // 区间外累计费用追踪器
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
    }

    // 添加或删除流动性的时候，只有mint和burn的时候会调用
    function update(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        int24 currentTick,
        int128 liquidityDelta,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
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
            // 只有当tick小于current的时候才初始化,也就是当现价在价格区间内
            // 如果现价不在价格区间内，费用追踪器被设计为0，并且会在下一次这个tick被穿过时进行更新，也就是cross的时候才更新
            if (tick <= currentTick) {
                tickInfo.feeGrowthOutside0X128 = feeGrowthGlobal0X128;
                tickInfo.feeGrowthOutside1X128 = feeGrowthGlobal1X128;
            }
        }

        tickInfo.liquidityGross = liquidityAfter;
        tickInfo.liquidityNet = upper // 当移动出当前price区间的upper减少流动性
            ? int128(int256(tickInfo.liquidityNet) - liquidityDelta) // 当进入到当前的price区间的lower增加流动性
            : int128(int256(tickInfo.liquidityNet) + liquidityDelta);
    }

    // 当tick跨区时返回需要添加或减少的流动性
    function cross(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) internal returns (int128 liquidityDelta) {
        Tick.Info storage info = self[tick];
        // 更新此tick关于两种token的outside累计值
        info.feeGrowthOutside0X128 =
            feeGrowthGlobal0X128 -
            info.feeGrowthOutside0X128;
        info.feeGrowthOutside1X128 =
            feeGrowthGlobal1X128 -
            info.feeGrowthOutside1X128;
        liquidityDelta = info.liquidityNet;
    }

    // 添加或删除流动性的时候，只有mint和burn的时候会调用。获取一个position内的费用
    // 通过扣减区间外的值来计算，这样是因为要节省gas
    function getFeeGrowthInside(
        mapping(int24 => Tick.Info) storage self,
        int24 lowerTick_,
        int24 upperTick_,
        int24 currentTick,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    )
        internal
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        Tick.Info storage lowerTick = self[lowerTick_];
        Tick.Info storage upperTick = self[upperTick_];

        uint256 feeGrowthBelow0X128;
        uint256 feeGrowthBelow1X128;
        // current price 在区间内，不用更新
        if (currentTick >= lowerTick_) {
            feeGrowthBelow0X128 = lowerTick.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = lowerTick.feeGrowthOutside1X128;
        } else {
            // 此时当前价格在区间左侧，需要获取最新的左侧outside累计更新了多少。
            feeGrowthBelow0X128 =
                feeGrowthGlobal0X128 -
                lowerTick.feeGrowthOutside0X128;
            feeGrowthBelow1X128 =
                feeGrowthGlobal1X128 -
                lowerTick.feeGrowthOutside1X128;
        }

        uint256 feeGrowthAbove0X128;
        uint256 feeGrowthAbove1X128;
        // 同上说明在区间内，不用更新
        if (currentTick < upperTick_) {
            feeGrowthAbove0X128 = upperTick.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = upperTick.feeGrowthOutside1X128;
        } else {
            // 此时当前价格在区间右侧，需要获取最新的右侧outside累计更新了多少。
            feeGrowthAbove0X128 =
                feeGrowthGlobal0X128 -
                upperTick.feeGrowthOutside0X128;
            feeGrowthAbove1X128 =
                feeGrowthGlobal1X128 -
                upperTick.feeGrowthOutside1X128;
        }
        // 区间内的值=总累计值-区间外总值
        feeGrowthInside0X128 =
            feeGrowthGlobal0X128 -
            feeGrowthBelow0X128 -
            feeGrowthAbove0X128;
        feeGrowthInside1X128 =
            feeGrowthGlobal1X128 -
            feeGrowthBelow1X128 -
            feeGrowthAbove1X128;
    }
}
