// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

library Oracle {
    // 一个观测者，是一个价格slot，一个pool最多存储65535个观测
    // 包括价格，时间戳和init标志
    struct Observation {
        uint32 timestamp; // 时间戳
        int56 tickCumulative; // 价格
        bool initialized; // 激活时设置为true
    }

    function initialize(Observation[65535] storage self, uint32 time)
        internal
        returns (uint16 cardinality, uint16 cardinalityNext)
    {   
        // 初始化观测点,写入到0位置
        self[0] = Observation({
            timestamp: time,
            tickCumulative: 0, //初始化
            initialized: true
        });
        // 默认最大为1，也就是说默认情况下一个pool只能存2个
        cardinality = 1;
        cardinalityNext = 1;
    }

    function write(
        Observation[65535] storage self,
        uint16 index,
        uint32 timestamp,
        int24 tick,
        uint16 cardinality,
        uint16 cardinalityNext
    ) internal returns (uint16 indexUpdated, uint16 cardinalityUpdated) {
        Observation memory last = self[index];
        // 当前的block时间戳记录了，则跳过，防止价格操纵机制
        if (last.timestamp == timestamp) return (index, cardinality);
        // 说明当前可扩展的数量大于激活的数量，并且index在[0,cardinality)区间的最右侧，说明要扩展一个新位置
        if (cardinalityNext > cardinality && index == (cardinality - 1)) {
            cardinalityUpdated = cardinalityNext;
        } else {
            cardinalityUpdated = cardinality;
        }
        // 让下标始终保持在[0,cardinality) 区间中，达到上界时重置为0，也就是说默认情况下只重复更新一个观测
        // 当cardinalityNext > cardinality，不会覆盖旧的，会始终使用新的位置知道到达cardinalityNext = cardinality
        // 这里的取模运算时为了到达上界的时候重置为0，保存的观测数组是允许溢出的
        indexUpdated = (index + 1) % cardinalityUpdated;
        self[indexUpdated] = transform(last, timestamp, tick);
    }
    // 向pool中添加新的观测值
    function grow(
        Observation[65535] storage self,
        uint16 current,
        uint16 next
    ) internal returns (uint16) {
        if (next <= current) return current;
        // 为新的观测的timestamp设置新的非零值，来初始化观测，真正更新的时候会填上对应的时间戳
        for (uint16 i = current; i < next; i++) {
            self[i].timestamp = 1;
        }

        return next;
    }
    // 更新累计值
    function transform(
        Observation memory last,
        uint32 timestamp,
        int24 tick
    ) internal pure returns (Observation memory) {
        uint56 delta = timestamp - last.timestamp;

        return
            Observation({
                timestamp: timestamp,
                // 计算累计价格
                tickCumulative: last.tickCumulative +
                    int56(tick) *
                    int56(delta),
                initialized: true
            });
    }

    function lte(
        uint32 time,
        uint32 a,
        uint32 b
    ) private pure returns (bool) {
        if (a <= time && b <= time) return a <= b;

        uint256 aAdjusted = a > time ? a : a + 2**32;
        uint256 bAdjusted = b > time ? b : b + 2**32;

        return aAdjusted <= bAdjusted;
    }

    function binarySearch(
        Observation[65535] storage self,
        uint32 time,// 现在的区块时间
        uint32 target, // 请求的价格时间点
        // 现在的索引和基数
        uint16 index,
        uint16 cardinality
    )
        private
        view
        // 返回两个观测区间，请求的时间点在这个区间中
        returns (Observation memory beforeOrAt, Observation memory atOrAfter)
    {
        uint256 l = (index + 1) % cardinality; // 数组是可以越界的,最新的可能在最老的前面
        uint256 r = l + cardinality - 1; // 最新的位置
        uint256 i;
        while (true) {
            i = (l + r) / 2;

            beforeOrAt = self[i % cardinality];

            // 检查中点，没有初始化就跳过
            if (!beforeOrAt.initialized) {
                l = i + 1;
                continue;
            }
            // 如果初始化，验证右边界
            atOrAfter = self[(i + 1) % cardinality];

            bool targetAtOrAfter = lte(time, beforeOrAt.timestamp, target);
            // target > before && target < after 说明找到目标了
            if (targetAtOrAfter && lte(time, target, atOrAfter.timestamp))
                break;
            // 说明太大了，向左搜索
            if (!targetAtOrAfter) r = i - 1;
            // 说明过小，向右搜索
            else l = i + 1;
        }
    }

    function getSurroundingObservations(
        Observation[65535] storage self,
        uint32 time,// 现在的区块时间
        uint32 target,// 请求的价格时间点
        // 现在的索引和基数
        int24 tick,
        uint16 index,
        uint16 cardinality
    )
        private
        view
        returns (Observation memory beforeOrAt, Observation memory atOrAfter)
    {
        // 先获取一下当前最新
        beforeOrAt = self[index];
        // 如果target在当前最新的之后
        if (lte(time, beforeOrAt.timestamp, target)) {

            if (beforeOrAt.timestamp == target) {
                return (beforeOrAt, atOrAfter);
            } else {
                // 计算一下当前最新与target之间累积的一小段
                return (beforeOrAt, transform(beforeOrAt, target, tick));
            }
        }

        beforeOrAt = self[(index + 1) % cardinality];
        if (!beforeOrAt.initialized) beforeOrAt = self[0];
        // target必须比最老的观测点要早
        require(lte(time, beforeOrAt.timestamp, target), "OLD");

        return binarySearch(self, time, target, index, cardinality);
    }

    function observeSingle(
        Observation[65535] storage self,
        uint32 time,
        uint32 secondsAgo,
        int24 tick,
        uint16 index,
        uint16 cardinality
    ) internal view returns (int56 tickCumulative) {
        // 如果请求的是最新的观测，直接返回最新的
        if (secondsAgo == 0) {
            Observation memory last = self[index];
            // 如果当前时间的比记录时间靠后，则计算一下这一小段时间累计的价格
            if (last.timestamp != time) last = transform(last, time, tick);
            return last.tickCumulative;
        }
        // 如果请求的时间点在最新的观测点之前，需要使用二分搜索
        uint32 target = time - secondsAgo;

        (
            Observation memory beforeOrAt,
            Observation memory atOrAfter
        ) = getSurroundingObservations(
                self,
                time,
                target,
                tick,
                index,
                cardinality
            );

        if (target == beforeOrAt.timestamp) {

            return beforeOrAt.tickCumulative;
        } else if (target == atOrAfter.timestamp) {

            return atOrAfter.tickCumulative;
        } else {
            
            uint56 observationTimeDelta = atOrAfter.timestamp -
                beforeOrAt.timestamp;
            uint56 targetDelta = target - beforeOrAt.timestamp;

            return
            // 如果target在两个观测值记录点之间，这时使用时间加权平均
            // 价格变化率 * 时间段
                beforeOrAt.tickCumulative +
                ((atOrAfter.tickCumulative - beforeOrAt.tickCumulative) /
                    int56(observationTimeDelta)) *
                int56(targetDelta);
        }
    }

    function observe(
        Observation[65535] storage self,
        uint32 time, // 当前区块时间戳
        uint32[] memory secondsAgos, // 希望获取价格的时间点列表
        // 当前tick, 观测下标index, cardinality
        int24 tick, 
        uint16 index,
        uint16 cardinality
    ) internal view returns (int56[] memory tickCumulatives) {
        tickCumulatives = new int56[](secondsAgos.length);

        for (uint256 i = 0; i < secondsAgos.length; i++) {
            tickCumulatives[i] = observeSingle(
                self,
                time,
                secondsAgos[i],
                tick,
                index,
                cardinality
            );
        }
    }
}
