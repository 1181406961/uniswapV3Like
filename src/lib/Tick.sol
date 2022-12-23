pragma solidity ^0.8.14;
import "./LiquidityMath.sol";

library Tick {
    struct Info {
        bool initialized;
        // total liquidity
        uint128 liquidityGross;
        // 当corss tick时，增加或减少了多少
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
        if (liquidityBefore == 0) {
            tickInfo.initialized = true;
        }
        tickInfo.liquidityGross = liquidityAfter;
        tickInfo.liquidityNet = upper
            ? int128(int256(tickInfo.liquidityNet) - liquidityDelta)
            : int128(int256(tickInfo.liquidityNet) + liquidityDelta);

        // 当首次添加流动性的时候和移除流动性的时候为true
        flipped = (liquidityAfter == 0) != (liquidityBefore == 0);
    }

    function cross(mapping(int24 => Tick.Info) storage self, int24 tick)
        internal
        view
        returns (int128 liquidityDelta)
    {
        Tick.Info storage info = self[tick];
        liquidityDelta = info.liquidityNet;
    }
}
