// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolTwapOracle, IV3PoolObserve} from "../interfaces/ISwap.sol";
import {TickMath} from "../libraries/TickMath.sol";

/// @title Uniswap v3 单池 TWAP 预言机（原生币 → BEM 参考价，M3）
/// @notice 不可升级，没有管理员。X Layer：BEM/WOKB 1% 池 `0x2CcF…f7A`（Oku），用过去 `window` 秒（≥ 30 分钟）的
///         时间加权平均 tick 把 WOKB 换算成 BEM，给分账合约算"最低成交量"。数学和 BSC 版 PancakeV3TwapOracle 相同。
/// @dev 池子要有足够的观测点（observation cardinality），并且最早的观测点早于 window 秒之前；否则 observe
///      revert（"OLD"），回购和回馈兑换暂停，而不是按没有防护的价格成交。部署前先调用池子的
///      `increaseObservationCardinalityNext`（任何人可调），见部署脚本的自检。
contract UniswapV3TwapOracle is IPoolTwapOracle {
    uint32 public constant MIN_WINDOW = 30 minutes;

    address public immutable pool;
    address public immutable baseToken; // WOKB
    address public immutable quoteToken; // BEM
    uint24 public immutable fee;
    uint32 public immutable window;

    error BadPool();
    error BadWindow();

    constructor(address pool_, address baseToken_, address quoteToken_, uint32 window_) {
        if (window_ < MIN_WINDOW) revert BadWindow();
        if (pool_ == address(0) || baseToken_ == quoteToken_) revert BadPool();
        address t0 = IV3PoolObserve(pool_).token0();
        address t1 = IV3PoolObserve(pool_).token1();
        if (!((t0 == baseToken_ && t1 == quoteToken_) || (t0 == quoteToken_ && t1 == baseToken_))) revert BadPool();
        pool = pool_;
        baseToken = baseToken_;
        quoteToken = quoteToken_;
        fee = IV3PoolObserve(pool_).fee();
        window = window_;
    }

    /// @notice 过去 window 秒的平均 tick（向负无穷取整，同 Uniswap OracleLibrary.consult）
    function twapTick() public view returns (int24 tick) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = window;
        ago[1] = 0;
        (int56[] memory cum,) = IV3PoolObserve(pool).observe(ago);
        int56 delta = cum[1] - cum[0];
        int56 w = int56(uint56(window));
        tick = int24(delta / w);
        if (delta < 0 && (delta % w != 0)) tick--;
    }

    /// @notice 现在能不能读出完整窗口的 TWAP（部署脚本、前端和机器人用；兑换本身不依赖它）
    function twapAvailable() external view returns (bool) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = window;
        try IV3PoolObserve(pool).observe(ago) returns (int56[] memory, uint160[] memory) {
            return true;
        } catch {
            return false;
        }
    }

    /// @notice nativeIn 个原生币按 TWAP 换算能得到多少 BEM。
    function quoteBemOut(uint256 nativeIn) external view returns (uint256) {
        return quoteAtTick(twapTick(), nativeIn, baseToken, quoteToken);
    }

    /// @notice 与 Uniswap V3 OracleLibrary.getQuoteAtTick 相同：按 tick 价格把 baseAmount 个 base 换算成 quote。
    function quoteAtTick(int24 tick, uint256 baseAmount, address base, address quote)
        public
        pure
        returns (uint256 quoteAmount)
    {
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = base < quote
                ? Math.mulDiv(ratioX192, baseAmount, 1 << 192)
                : Math.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = Math.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = base < quote
                ? Math.mulDiv(ratioX128, baseAmount, 1 << 128)
                : Math.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }
}
