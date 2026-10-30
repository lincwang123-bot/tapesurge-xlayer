// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {UniswapV3TwapOracle} from "../src/oracle/UniswapV3TwapOracle.sol";
import {ISwapRouter02, IWrappedNative} from "../src/interfaces/ISwap.sol";
import {ITransistors} from "../src/interfaces/ITapeOut.sol";

interface IV3PoolFull {
    function slot0()
        external
        view
        returns (uint160, int24 tick, uint16 index, uint16 cardinality, uint16 cardinalityNext, uint8, bool);
    function increaseObservationCardinalityNext(uint16 next) external;
}

/// @notice M3 主网分叉测试（只在本地分叉上执行，不广播）：真实的 Oku SwapRouter02、WOKB、BEM/WOKB 1% 池、TapeOut 工厂。
///         1. 观测点覆盖不到 30 分钟时读不出 TWAP：回购暂停（整笔 revert，资金不动）。池子观测点数随时间变化
///            （10-20 测时只有 1 个，10-27 已被扩到 200），所以不假设具体数量：连续逐块成交，直到观测点被写满、
///            最早的一个也不到 30 分钟（只有 1 个观测点时成交一笔就够）；
///         2. 调用 increaseObservationCardinalityNext(1800) 扩容，之后隔几分钟成交一笔，30 分钟后 TWAP 可读；
///         3. 分账合约按 TWAP 的 98% 做最低成交量，把 1 OKB wrap 成 WOKB、单跳换成 BEM、转入 0x…dEaD。
///         运行：XLAYER_RPC_URL=https://rpc.xlayer.tech forge test --match-contract ForkXLayerBuybackTest -vv
contract ForkXLayerBuybackTest is Test {
    address internal constant TAPEOUT_FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    address internal constant BEM = 0x60e62Efa9405d6873C5deaBD4E6CC91c25363952;
    address internal constant WOKB = 0xe538905cf8410324e03A5A23C1c177a474D59b2b;
    address internal constant SWAP_ROUTER02 = 0x4f0C28f5926AFDA16bf2506D5D9e57Ea190f9bcA;
    address internal constant POOL = 0x2CcF8aa17F5DF9Fb5D51C9de12135a913fF29f7A;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint16 internal constant CARDINALITY = 1800; // 30 分钟 / 约 1 秒一块

    bool internal live;
    address internal trader = address(0x7ADE);

    function setUp() public {
        string memory rpc = vm.envOr("XLAYER_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        live = true;
        vm.deal(trader, 100 ether);
        console2.log("REPORT fork block", block.number);
    }

    function test_Fork_BuybackOnRealPoolAfterCardinalityIncrease() public {
        if (!live) vm.skip(true);
        (, int24 spotTick,, uint16 card, uint16 cardNext,,) = IV3PoolFull(POOL).slot0();
        console2.log("REPORT pool observation cardinality / next (before)", card, cardNext);
        UniswapV3TwapOracle oracle = new UniswapV3TwapOracle(POOL, WOKB, BEM, 30 minutes);
        GenesisSplitter s = _deploySplitter(address(oracle));
        _revenue(s, 1_000); // 1,000 颗 × 0.006 = 6 OKB 铸造收入 → 回购池 2.4 OKB
        s.distribute();
        assertEq(s.buybackPool(), 2.4 ether);

        // 1. 逐块密集成交（每块 1 秒），把观测点写满：最早的观测点也不到 30 分钟，TWAP 读不出来 → 回购暂停
        assertTrue(oracle.twapAvailable(), "precondition: TWAP readable before the burst");
        uint256 burst;
        for (; oracle.twapAvailable() && burst < uint256(cardNext) + 50; burst++) {
            vm.warp(block.timestamp + 1);
            vm.roll(block.number + 1);
            _tradeFlip();
        }
        console2.log("REPORT trades to overwrite all observations", burst);
        assertFalse(oracle.twapAvailable(), "observations cover less than 30 minutes");
        vm.expectRevert(bytes("OLD"));
        s.buyback();
        assertEq(s.buybackPool(), 2.4 ether, "nothing spent while paused");

        // 2. 扩容（任何人可调）：之后隔几分钟有人成交，30 分钟后 TWAP 又能读
        uint256 g;
        if (cardNext < CARDINALITY) {
            g = gasleft();
            IV3PoolFull(POOL).increaseObservationCardinalityNext(CARDINALITY);
            console2.log("REPORT gas increaseObservationCardinalityNext(1800)", g - gasleft());
        }
        (,,, card, cardNext,,) = IV3PoolFull(POOL).slot0();
        assertGe(cardNext, CARDINALITY);
        vm.warp(block.timestamp + 10 minutes);
        vm.roll(block.number + 600);
        _tradeFlip();
        for (uint256 i; i < 4; i++) {
            vm.warp(block.timestamp + 8 minutes);
            vm.roll(block.number + 480);
            _tradeFlip();
        }
        assertTrue(oracle.twapAvailable(), "30-minute TWAP readable again");

        // 3. 回购：最低成交量 = TWAP 报价 × 98%；成交的 BEM 转入 0x…dEaD
        int24 twap = oracle.twapTick();
        uint256 quote = oracle.quoteBemOut(1 ether);
        uint256 floor = s.minOutFor(1 ether);
        assertEq(floor, quote * 9_800 / 10_000);
        uint256 dead0 = IERC20(BEM).balanceOf(DEAD);
        g = gasleft();
        uint256 out = s.buyback();
        console2.log("REPORT gas buyback (distribute + wrap + swap)", g - gasleft());
        assertEq(IERC20(BEM).balanceOf(DEAD) - dead0, out, "BEM burned to 0x..dEaD");
        assertGe(out, floor);
        assertEq(s.buybackPool(), 1.4 ether, "1 OKB per call");
        assertEq(IERC20(WOKB).balanceOf(address(s)), 0);
        assertEq(IERC20(WOKB).allowance(address(s), SWAP_ROUTER02), 0);
        console2.log("REPORT spot tick / 30-min TWAP tick", uint256(int256(spotTick)), uint256(int256(twap)));
        console2.log("REPORT TWAP quote BEM per OKB / floor / actual out", quote, floor, out);
        // 间隔不到 1 小时不能再回购
        vm.expectRevert(GenesisSplitter.TooSoon.selector);
        s.buyback();
    }

    // ---------------- 辅助 ----------------

    function _deploySplitter(address oracle) internal returns (GenesisSplitter s) {
        GenesisSplitter.Params memory sp;
        sp.boardFactory = address(new HubStub()); // 这里只测回购：注册中心用桩合约（还没有主板开局）
        sp.tapeoutFactory = TAPEOUT_FACTORY;
        sp.cpuName = "TapeSurge Genesis (X Layer) buyback fork test";
        sp.cpuSymbol = "SURGE";
        sp.cpuStory = "fork integration";
        sp.transistorSupply = 66_666;
        sp.mintPrice = 0.006 ether;
        sp.foundation = address(0xF0F0);
        sp.project = address(0xFEE5);
        sp.buybackBps = 4_000;
        sp.projectBps = 1_000;
        sp.foundationBps = 2_000;
        sp.bucketBps = [uint256(1000), 800, 500, 400, 300];
        sp.bem = BEM;
        sp.wrappedNative = WOKB;
        sp.router = SWAP_ROUTER02;
        sp.poolFee = 10_000;
        sp.oracle = oracle;
        sp.maxSwapPerCall = 1 ether;
        sp.minSwapInterval = 1 hours;
        sp.maxSlippageBps = 200;
        uint256 fee = ITapeOutFactory(TAPEOUT_FACTORY).deployFee();
        vm.deal(address(this), 1 ether);
        s = new GenesisSplitter{value: fee}(sp);
    }

    /// @dev 真实铸造 n 颗带来的收入（每颗 0.006 OKB 归 creator，协议费另付给 TapeOut）
    function _revenue(GenesisSplitter s, uint256 n) internal {
        ITransistors t = s.transistors();
        uint256 value = n * (0.006 ether + t.protocolFee());
        address minter = address(0xA11CE);
        vm.deal(minter, 100 ether);
        vm.prank(minter);
        t.mint{value: value}(0, n);
    }

    /// @dev 买卖交替：手上没有 BEM 就用 0.5 OKB 买，有就全部卖回去
    function _tradeFlip() internal {
        bool buy = IERC20(BEM).balanceOf(trader) == 0;
        _trade(buy, buy ? 0.5 ether : 0);
    }

    /// @dev 别人在池子里成交一笔（买 BEM 或把手上的 BEM 卖回去）。Uniswap v3 只在 tick 变化时写观测点，
    ///      所以每笔都要足够大（0.5 OKB 约挪动 5 个 tick）；买卖交替，价格基本不变。
    function _trade(bool buyBem, uint256 amount) internal {
        vm.startPrank(trader);
        address tokenIn = buyBem ? WOKB : BEM;
        if (buyBem) IWrappedNative(WOKB).deposit{value: amount}();
        else amount = IERC20(BEM).balanceOf(trader);
        IERC20(tokenIn).approve(SWAP_ROUTER02, amount);
        ISwapRouter02(SWAP_ROUTER02)
            .exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: buyBem ? BEM : WOKB,
                    fee: 10_000,
                    recipient: trader,
                    amountIn: amount,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        vm.stopPrank();
    }
}

interface ITapeOutFactory {
    function deployFee() external view returns (uint256);
}

/// @dev 还没有主板开局的注册中心（分账时 rewardBoard 都返回 0）
contract HubStub {
    function rewardBoard(uint256) external pure returns (address) {
        return address(0);
    }
}
