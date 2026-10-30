// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {UniswapV3TwapOracle} from "../src/oracle/UniswapV3TwapOracle.sol";
import {MockV3Pool} from "../src/mocks/MockSwap.sol";

contract TickMathHarness {
    function sqrtAt(int24 t) external pure returns (uint160) {
        return TickMath.getSqrtRatioAtTick(t);
    }
}

/// @notice M3 单池 TWAP 预言机：TickMath 已知值、BEM/WOKB 报价（含小数位差）、窗口下限、观测点不够时暂停
contract TwapOracleTest is Test {
    /// @dev 地址大小关系和主网一致：BEM < WOKB，所以 BEM 是 token0
    address internal constant BEM = address(0x60e6);
    address internal constant WOKB = address(0xe538);
    address internal constant OTHER = address(0x7777);
    TickMathHarness internal tm = new TickMathHarness();

    function setUp() public {
        vm.warp(1_790_000_000);
    }

    function test_TickMathKnownValues() public view {
        assertEq(tm.sqrtAt(0), 1 << 96);
        assertEq(tm.sqrtAt(-887272), 4295128739);
        assertEq(tm.sqrtAt(887272), 1461446703485210103287273052203988822378723970342);
        assertEq(tm.sqrtAt(1), 79232123823359799118286999568);
        assertEq(tm.sqrtAt(-1), 79224201403219477170569942574);
    }

    function test_RevertWhen_TickOutOfRange() public {
        vm.expectRevert(TickMath.TickOutOfRange.selector);
        tm.sqrtAt(887273);
    }

    function test_QuoteAtTickZeroIsOneToOne() public {
        MockV3Pool p = new MockV3Pool(WOKB, BEM, 10_000, 0);
        UniswapV3TwapOracle o = new UniswapV3TwapOracle(address(p), WOKB, BEM, 30 minutes);
        assertEq(o.quoteBemOut(1e18), 1e18);
        assertEq(o.quoteAtTick(0, 5, BEM, WOKB), 5);
        assertEq(o.fee(), 10_000);
        assertEq(o.pool(), address(p));
    }

    /// @dev 主网池子 2026-10-21 的 tick 是 216,768（token0 = BEM 8 位小数，token1 = WOKB 18 位）：1 WOKB ≈ 3.86 BEM
    function test_QuoteAtMainnetTick() public {
        int24 t = 216_768;
        MockV3Pool p = new MockV3Pool(WOKB, BEM, 10_000, t);
        UniswapV3TwapOracle o = new UniswapV3TwapOracle(address(p), WOKB, BEM, 30 minutes);
        assertEq(o.twapTick(), t);
        uint256 out = o.quoteBemOut(1e18);
        assertApproxEqRel(out, 3.8585e8, 0.001e18);
        // 反方向：1 BEM ≈ 0.2592 WOKB
        assertApproxEqRel(o.quoteAtTick(t, 1e8, BEM, WOKB), 0.25917e18, 0.001e18);
        // 线性
        assertApproxEqAbs(o.quoteBemOut(2e18), 2 * out, 1);
    }

    function test_RevertWhen_WindowShorterThan30Minutes() public {
        MockV3Pool p = new MockV3Pool(WOKB, BEM, 10_000, 0);
        vm.expectRevert(UniswapV3TwapOracle.BadWindow.selector);
        new UniswapV3TwapOracle(address(p), WOKB, BEM, 29 minutes);
    }

    function test_RevertWhen_PoolDoesNotMatchTokens() public {
        MockV3Pool p = new MockV3Pool(WOKB, OTHER, 10_000, 0);
        vm.expectRevert(UniswapV3TwapOracle.BadPool.selector);
        new UniswapV3TwapOracle(address(p), WOKB, BEM, 30 minutes);
        vm.expectRevert(UniswapV3TwapOracle.BadPool.selector);
        new UniswapV3TwapOracle(address(0), WOKB, BEM, 30 minutes);
    }

    /// @dev 观测点不够（真实池子 observe revert "OLD"）：报价 revert，twapAvailable() 返回 false
    function test_UnavailableTwapReverts() public {
        MockV3Pool p = new MockV3Pool(WOKB, BEM, 10_000, 216_768);
        UniswapV3TwapOracle o = new UniswapV3TwapOracle(address(p), WOKB, BEM, 30 minutes);
        assertTrue(o.twapAvailable());
        p.setObserveReverts(true);
        assertFalse(o.twapAvailable());
        vm.expectRevert(bytes("OLD"));
        o.quoteBemOut(1e18);
    }
}
