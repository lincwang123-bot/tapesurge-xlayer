// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Uniswap v3 SwapRouter02 的单跳兑换（X Layer：Oku 部署的 `0x4f0c…9bca`，factory = `0x4B2a…6804`）。
/// @dev SwapRouter02 的参数里没有 deadline（和 BSC 版用的 v3-periphery SwapRouter 不同）。
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    function factory() external view returns (address);
    function WETH9() external view returns (address);
}

/// @notice 原生币的包装代币（X Layer：WOKB，WETH9 同款）
interface IWrappedNative {
    function deposit() external payable;
}

interface IUniswapV3FactoryLike {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/// @notice 价格预言机：nativeIn 个原生币（wei）按参考价（30 分钟以上的 TWAP）应换得多少 BEM。
///         分账合约用它算"最低成交量"；TWAP 读不出来（观测点不够）时 revert，兑换随之暂停。
interface IBemPriceOracle {
    function quoteBemOut(uint256 nativeIn) external view returns (uint256 bemOut);
}

/// @notice 单池 TWAP 预言机额外公开的信息，分账合约部署时用它核对兑换池和预言机是同一个池子。
interface IPoolTwapOracle is IBemPriceOracle {
    function pool() external view returns (address);
    function baseToken() external view returns (address);
    function quoteToken() external view returns (address);
    function fee() external view returns (uint24);
}

/// @notice Uniswap v3 池子的 TWAP 接口
interface IV3PoolObserve {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
}
