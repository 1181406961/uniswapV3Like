// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

import "./interfaces/IUniswapV3Pool.sol";

contract UniswapV3Quoter {
    struct QuoteParams {
        address pool;
        uint256 amountIn;
        bool zeroForOne;
    }
    // 使用ether.js的callStatic的方式来调用合约,把quote当成一个静态方法来调用。
    function quote(QuoteParams memory params)
        public
        returns (
            uint256 amountOut,
            uint160 sqrtPriceX96After,
            int24 tickAfter
        )
    {
        // 使用简单调用pool并且revert的方式来获取价格
        try
            IUniswapV3Pool(params.pool).swap(
                address(this),
                params.zeroForOne,
                params.amountIn,
                abi.encode(params.pool)
            )
        {} catch (bytes memory reason) {
            return abi.decode(reason, (uint256, uint160, int24));
        }
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes memory data
    ) external view {
        address pool = abi.decode(data, (address));

        uint256 amountOut = amount0Delta > 0
            ? uint256(-amount1Delta)
            : uint256(-amount0Delta);

        (uint160 sqrtPriceX96After, int24 tickAfter) = IUniswapV3Pool(pool)
            .slot0();

        assembly {
            // evm规定，下一个从0x40处读取下一个可用内存slot指针
            let ptr := mload(0x40)
            mstore(ptr, amountOut)
            mstore(add(ptr, 0x20), sqrtPriceX96After)
            mstore(add(ptr, 0x40), tickAfter)
            // 256 * 3 连续使用了3个32bytes的空间保存数据
            // 一共是96bytes。
            revert(ptr, 96)
        }
    }
}
