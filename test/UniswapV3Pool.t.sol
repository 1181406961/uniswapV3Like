pragma solidity ^0.8.14;
import "forge-std/Test.sol";
import "./ERC20Mintable.sol";
import "../src/UniswapV3Pool.sol";

library Params {
    struct TestCaseParams {
        uint256 wethBalance;
        uint256 usdcBalance;
        int24 currentTick;
        int24 lowerTick;
        int24 upperTick;
        uint128 liquidity;
        uint160 currentSqrtP;
        bool shouldTransferInCallback;
        bool mintLiquidity;
    }

    function createPool(
        TestCaseParams memory self,
        ERC20Mintable token0,
        ERC20Mintable token1
    ) public returns (UniswapV3Pool pool) {
        pool = new UniswapV3Pool(
            address(token0),
            address(token1),
            self.currentSqrtP,
            self.currentTick
        );
    }

    function poolMint(
        TestCaseParams memory self,
        UniswapV3Pool pool,
        ERC20Mintable token0,
        ERC20Mintable token1,
        address approvees
    ) public returns (uint256 poolBalance0, uint256 poolBalance1) {
        token0.mint(address(this), self.wethBalance);
        token1.mint(address(this), self.usdcBalance);
        token0.approve(approvees, self.wethBalance);
        token1.approve(approvees, self.usdcBalance);
        UniswapV3Pool.CallbackData memory data = UniswapV3Pool.CallbackData({
            token0: address(token0),
            token1: address(token1),
            payer: address(this)
        });
        if (self.mintLiquidity) {
            (poolBalance0, poolBalance1) = pool.mint(
                address(this),
                self.lowerTick,
                self.upperTick,
                self.liquidity,
                abi.encode(data)
            );
        }
    }
}

contract UniswapV3PoolTest is Test {
    using Params for Params.TestCaseParams;
    ERC20Mintable token0;
    ERC20Mintable token1;
    UniswapV3Pool pool;
    bool transferInCallback;

    function setUp() public {
        token0 = new ERC20Mintable("Ether", "ETH", 18);
        token1 = new ERC20Mintable("USDC", "USDC", 18);
    }

    function testMintSuccess() public {
        Params.TestCaseParams memory params = Params.TestCaseParams({
            wethBalance: 1 ether,
            usdcBalance: 5000209190920489524100,
            currentTick: 85176,
            lowerTick: 84222,
            upperTick: 86129,
            liquidity: 1517882343751509868544,
            currentSqrtP: 5602277097478614198912276234240,
            shouldTransferInCallback: true,
            mintLiquidity: true
        });
        (uint256 poolBalance0, uint256 poolBalance1) = setupTestCase(params);
        uint256 expectedAmount0 = 998628802115141959;
        uint256 expectedAmount1 = 5000209190920489524100;
        // 验证合同金额
        assertEq(
            poolBalance0,
            expectedAmount0,
            "incorrect token0 deposited amount"
        );
        assertEq(
            poolBalance1,
            expectedAmount1,
            "incorrect token1 deposited amount"
        );
        // 验证转账
        assertEq(token0.balanceOf(address(pool)), expectedAmount0);
        assertEq(token1.balanceOf(address(pool)), expectedAmount1);
        bytes32 positionKey = keccak256(
            abi.encodePacked(address(this), params.lowerTick, params.upperTick)
        );
        uint128 posLiquidity = pool.positions(positionKey);
        // 验证position
        assertEq(posLiquidity, params.liquidity);
        (bool tickInitialized, uint128 tickLiquidity) = pool.ticks(
            params.lowerTick
        );
        // 验证tick
        assertTrue(tickInitialized);
        assertEq(tickLiquidity, params.liquidity);
        (tickInitialized, tickLiquidity) = pool.ticks(params.upperTick);
        assertTrue(tickInitialized);
        assertEq(tickLiquidity, params.liquidity);
        // 验证价格
        (uint160 sqrtPriceX96, int24 tick) = pool.slot0();
        assertEq(
            sqrtPriceX96,
            5602277097478614198912276234240,
            "invalid current sqrtP"
        );
        assertEq(tick, 85176, "invalid current tick");
        assertEq(
            pool.liquidity(),
            1517882343751509868544,
            "invalid current liquidity"
        );
    }

    function setupTestCase(Params.TestCaseParams memory params)
        internal
        returns (uint256 poolBalance0, uint256 poolBalance1)
    {
        pool = params.createPool(token0, token1);
        transferInCallback = params.shouldTransferInCallback;
        (poolBalance0, poolBalance1) = params.poolMint(
            pool,
            token0,
            token1,
            address(this)
        );
    }

    function testTickTooLow() public {
        Params.TestCaseParams memory params = Params.TestCaseParams({
            wethBalance: 1 ether,
            usdcBalance: 5000209190920489524100,
            currentTick: 85176,
            lowerTick: -887273,
            upperTick: 86129,
            liquidity: 1517882343751509868544,
            currentSqrtP: 5602277097478614198912276234240,
            shouldTransferInCallback: true,
            mintLiquidity: true
        });
        pool = params.createPool(token0, token1);
        vm.expectRevert(UniswapV3Pool.InvalidTickRange.selector);
        params.poolMint(pool, token0, token1, address(this));
    }

    // TODO 测试太高的情况
    function testTickTooHigh() public {}

    // TODO 测试liquidity为0的情况
    function testLiquidityIsZero() public {}

    // TODO 测试provider余额不足的时候
    function testProviderNotEngouhToken() public {}

    // 测试交换token
    function testSwapBuyEth() public {
        Params.TestCaseParams memory params = Params.TestCaseParams({
            wethBalance: 1 ether,
            usdcBalance: 5000209190920489524100,
            currentTick: 85176,
            lowerTick: 84222,
            upperTick: 86129,
            liquidity: 1517882343751509868544,
            currentSqrtP: 5602277097478614198912276234240,
            shouldTransferInCallback: true,
            mintLiquidity: true
        });
        (uint256 poolBalance0, uint256 poolBalance1) = setupTestCase(params);
        token1.mint(address(this), 42 ether);
        token1.approve(address(this), 42 ether);
        int256 userBalance0Before = int256(token0.balanceOf(address(this)));
        UniswapV3Pool.CallbackData memory data = UniswapV3Pool.CallbackData({
            token0: address(token0),
            token1: address(token1),
            payer: address(this)
        });
        (int256 amount0Delta, int256 amount1Delta) = pool.swap(
            address(this),
            false, // 换出x也就是ETC,zero = false one = true
            42 ether, // 输入y是什么
            abi.encode(data)
        );
        // 检查swap的数量是否正确
        assertEq(amount0Delta, -8396714242162445, "invalid ETH out");
        assertEq(amount1Delta, 42 ether, "invalid USDC in");
        // 检查sender是否正确的收到token0，减少token1
        assertEq(
            token0.balanceOf(address(this)),
            uint256(userBalance0Before - amount0Delta),
            "invalid user ETH balance"
        );
        assertEq(
            token1.balanceOf(address(this)),
            0,
            "invalid user USDC balance"
        );
        // 检查pool的余额是否正确
        assertEq(
            token0.balanceOf(address(pool)),
            uint256(int256(poolBalance0) + amount0Delta),
            "invalid pool ETH balance"
        );
        assertEq(
            token1.balanceOf(address(pool)),
            uint256(int256(poolBalance1) + amount1Delta),
            "invalid pool USDC balance"
        );
        // 检查sqrtPriceX96和tick是否更新
        (uint160 sqrtPriceX96, int24 tick) = pool.slot0();
        assertEq(
            sqrtPriceX96,
            5604469350942327889444743441197,
            "invalid current sqrtP"
        );
        assertEq(tick, 85184, "invalid current tick");
        // liquidity是否保持不变
        assertEq(
            pool.liquidity(),
            1517882343751509868544,
            "invalid current liquidity"
        );
    }

    function uniswapV3MintCallback(
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) public {
        if (transferInCallback) {
            UniswapV3Pool.CallbackData memory extra = abi.decode(
                data,
                (UniswapV3Pool.CallbackData)
            );

            IERC20(extra.token0).transferFrom(extra.payer, msg.sender, amount0);
            IERC20(extra.token1).transferFrom(extra.payer, msg.sender, amount1);
        }
    }

    function uniswapV3SwapCallback(
        int256 amount0,
        int256 amount1,
        bytes calldata data
    ) public {
        UniswapV3Pool.CallbackData memory extra = abi.decode(
            data,
            (UniswapV3Pool.CallbackData)
        );
        if (amount0 > 0) {
            IERC20(extra.token0).transferFrom(
                extra.payer,
                msg.sender,
                uint256(amount0)
            );
        }

        if (amount1 > 0) {
            IERC20(extra.token1).transferFrom(
                extra.payer,
                msg.sender,
                uint256(amount1)
            );
        }
    }
}

contract NotSwapHackerContract is Test {
    using Params for Params.TestCaseParams;
    ERC20Mintable token0;
    ERC20Mintable token1;
    UniswapV3Pool pool;

    function setUp() public {
        token0 = new ERC20Mintable("Ether", "ETH", 18);
        token1 = new ERC20Mintable("USDC", "USDC", 18);
    }

    // 测试交换token时余额不足
    function testSwapTokenBalanceNotEnough() public {
        Params.TestCaseParams memory params = Params.TestCaseParams({
            wethBalance: 1 ether,
            usdcBalance: 5000209190920489524100,
            currentTick: 85176,
            lowerTick: 84222,
            upperTick: 86129,
            liquidity: 1517882343751509868544,
            currentSqrtP: 5602277097478614198912276234240,
            shouldTransferInCallback: true,
            mintLiquidity: true
        });
        pool = params.createPool(token0, token1);
        params.poolMint(pool, token0, token1, address(this));
        vm.expectRevert(UniswapV3Pool.InsufficientInputAmount.selector);
        pool.swap(address(this), false, 42 ether, "");
    }

    function uniswapV3SwapCallback(
        int256 amount0,
        int256 amount1,
        bytes calldata data
    ) public {}

    function uniswapV3MintCallback(
        uint256 amount0,
        uint256 amount1,
        bytes calldata
    ) public {
        token0.transfer(msg.sender, amount0);
        token1.transfer(msg.sender, amount1);
    }
}
