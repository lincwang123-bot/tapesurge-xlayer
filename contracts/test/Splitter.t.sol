// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {XMonthBoard} from "../src/XMonthBoard.sol";
import {MonthState} from "../src/interfaces/IXMonthBoard.sol";
import {MockV3Pool, MockPriceOracle, MockSwapRouter02} from "../src/mocks/MockSwap.sol";
import {MockTransistors} from "../src/mocks/MockTapeOut.sol";
import {XLayerDefaults} from "../script/XLayerDefaults.sol";

/// @notice 铸造收入分账（移植自 BSC 版 Splitter.t.sol）：40 / 10 / 20 / 30 与回馈桶 10 : 8 : 5 : 4 : 3、回购、领取回馈；
///         另加 M3：wrap 成 WOKB 后单跳兑换、部署时核对兑换池 = 预言机的池、TWAP 读不出来时兑换暂停。
contract SplitterTest is Fixture {
    address internal minter = address(0xA11CE);

    /// @dev 有人铸造 n 颗创世晶体管：每颗 mintPrice（mock 0.001）归 creator（分账合约）
    function _mintTransistors(uint256 n) internal {
        vm.deal(minter, minter.balance + n * 0.0011 ether);
        vm.prank(minter);
        transistors.mint{value: n * 0.0011 ether}(0, n);
    }

    function test_SplitterIsCreatorOfGenesisProcessor() public view {
        assertEq(transistors.creator(), address(splitter));
        assertEq(splitter.circuits(), address(passCircuits));
        assertEq(splitter.boardFactory(), address(factory));
        assertEq(transistors.supplyCap(), 66_666);
        assertEq(splitter.wrappedNative(), address(wrapped));
        assertEq(address(splitter.router()), address(router));
        assertEq(splitter.poolFee(), POOL_FEE);
        assertEq(address(splitter.oracle()), address(oracle));
        assertEq(splitter.mintStart(), START_TIME);
    }

    function test_DistributeSplits40_10_20_30() public {
        _mintTransistors(1_000); // 1 OKB 铸造收入
        uint256 f0 = FOUNDATION.balance;
        uint256 p0 = FEE_SAFE.balance;
        assertEq(splitter.distribute(), 1 ether);
        assertEq(FOUNDATION.balance - f0, 0.2 ether);
        assertEq(FEE_SAFE.balance - p0, 0.1 ether);
        assertEq(splitter.buybackPool(), 0.4 ether);
        assertEq(splitter.rewardBucket(1), 0.1 ether);
        assertEq(splitter.rewardBucket(2), 0.08 ether);
        assertEq(splitter.rewardBucket(3), 0.05 ether);
        assertEq(splitter.rewardBucket(4), 0.04 ether);
        assertEq(splitter.rewardBucket(5), 0.03 ether);
        assertEq(address(splitter).balance, 0.7 ether);
        assertEq(splitter.distribute(), 0);
    }

    function test_DistributeAlternativeSplit50_0_20_30() public {
        GenesisSplitter.Params memory sp = defaultSplitterParams();
        sp.buybackBps = 5_000;
        sp.projectBps = 0;
        _deploySystem(defaultMonthParams(), sp);
        _mintTransistors(1_000);
        uint256 p0 = FEE_SAFE.balance;
        splitter.distribute();
        assertEq(splitter.buybackPool(), 0.5 ether);
        assertEq(FEE_SAFE.balance, p0);
        assertEq(splitter.rewardBucket(1), 0.1 ether);
    }

    /// @dev X Layer 部署默认（2026-10-28 项目方决定）：上限 6,666 颗；铸造收入 100% 给手续费 Safe，不回购、没有回馈桶，
    ///      分账合约不留钱。机制本身（40 / 10 / 20 / 30 等任意比例）由上面的测试覆盖。
    function test_XLayerDefaults_AllMintRevenueToFeeSafe() public {
        XLayerDefaults.Addresses memory a;
        a.tapeoutFactory = address(tapeout);
        a.bem = address(bem);
        a.wrappedNative = address(wrapped);
        a.router = address(router);
        a.oracle = address(oracle);
        a.foundation = FOUNDATION;
        a.feeSafe = FEE_SAFE;
        GenesisSplitter.Params memory sp = XLayerDefaults.splitterParams(a, 0.001 ether);
        _deploySystem(defaultMonthParams(), sp);
        assertEq(transistors.supplyCap(), 6_666, "1,333 passes + 1");
        assertEq(splitter.projectBps(), 10_000);
        assertEq(splitter.buybackBps() + splitter.foundationBps(), 0);
        for (uint256 i = 1; i <= 5; i++) {
            assertEq(splitter.bucketBps(i), 0);
        }

        _mintTransistors(1_000); // 1 OKB 铸造收入
        uint256 f0 = FOUNDATION.balance;
        uint256 p0 = FEE_SAFE.balance;
        assertEq(splitter.distribute(), 1 ether);
        assertEq(FEE_SAFE.balance - p0, 1 ether, "all of it to the fee Safe");
        assertEq(FOUNDATION.balance, f0);
        assertEq(splitter.buybackPool(), 0);
        assertEq(splitter.rewardBucket(1), 0);
        assertEq(address(splitter).balance, 0, "splitter keeps nothing");
        vm.expectRevert(GenesisSplitter.NothingToSwap.selector);
        splitter.buyback();

        // 铸满 6,666 颗为止
        _mintTransistors(5_666);
        vm.deal(minter, 1 ether);
        vm.prank(minter);
        vm.expectRevert(MockTransistors.CapExceeded.selector);
        transistors.mint{value: 0.0011 ether}(0, 1);
        splitter.distribute();
        assertEq(FEE_SAFE.balance - p0, 6.666 ether);
        assertEq(address(splitter).balance, 0);
    }

    function test_RevertWhen_SplitDoesNotSumTo100Percent() public {
        GenesisSplitter.Params memory sp = defaultSplitterParams();
        sp.boardFactory = address(0xFAC7);
        sp.buybackBps = 4_100;
        vm.expectRevert(GenesisSplitter.BadParams.selector);
        new GenesisSplitter{value: 0.001 ether}(sp);
    }

    function test_RevertWhen_SplitterWithoutBoardFactory() public {
        GenesisSplitter.Params memory sp = defaultSplitterParams();
        vm.expectRevert(GenesisSplitter.BadParams.selector);
        new GenesisSplitter{value: 0.001 ether}(sp);
    }

    // ---------------- M3：兑换池和预言机必须是同一个池子 ----------------

    function test_RevertWhen_RouterWrapsAnotherToken() public {
        GenesisSplitter.Params memory sp = defaultSplitterParams();
        sp.boardFactory = address(0xFAC7);
        sp.wrappedNative = address(0xBAD);
        vm.expectRevert(GenesisSplitter.BadParams.selector);
        new GenesisSplitter{value: 0.001 ether}(sp);
    }

    function test_RevertWhen_OracleWatchesAnotherPool() public {
        GenesisSplitter.Params memory sp = defaultSplitterParams();
        sp.boardFactory = address(0xFAC7);
        MockV3Pool other = new MockV3Pool(address(wrapped), address(bem), POOL_FEE, 0);
        sp.oracle = address(new MockPriceOracle(address(other), address(wrapped), address(bem), POOL_FEE, 1));
        vm.expectRevert(GenesisSplitter.BadParams.selector);
        new GenesisSplitter{value: 0.001 ether}(sp);
        // 预言机的费率档和兑换用的不一致
        sp.oracle = address(new MockPriceOracle(address(pool), address(wrapped), address(bem), 3_000, 1));
        vm.expectRevert(GenesisSplitter.BadParams.selector);
        new GenesisSplitter{value: 0.001 ether}(sp);
        // 预言机报的是反方向
        sp.oracle = address(new MockPriceOracle(address(pool), address(bem), address(wrapped), POOL_FEE, 1));
        vm.expectRevert(GenesisSplitter.BadParams.selector);
        new GenesisSplitter{value: 0.001 ether}(sp);
    }

    function test_RevertWhen_FactoryHasNoSuchPool() public {
        GenesisSplitter.Params memory sp = defaultSplitterParams();
        sp.boardFactory = address(0xFAC7);
        sp.poolFee = 3_000;
        sp.oracle = address(new MockPriceOracle(address(pool), address(wrapped), address(bem), 3_000, 1));
        vm.expectRevert(GenesisSplitter.BadParams.selector);
        new GenesisSplitter{value: 0.001 ether}(sp);
    }

    // ---------------- 拒收原生币时记账，不卡住分账 ----------------

    function test_RejectedNativeIsOwedAndDoesNotBlock() public {
        NativeRejector rejector = new NativeRejector();
        GenesisSplitter.Params memory sp = defaultSplitterParams();
        sp.foundation = address(rejector);
        _deploySystem(defaultMonthParams(), sp);
        _mintTransistors(1_000);
        uint256 project0 = FEE_SAFE.balance;
        splitter.distribute();
        assertEq(splitter.owedNative(address(rejector)), 0.2 ether);
        assertEq(splitter.totalOwedNative(), 0.2 ether);
        assertEq(FEE_SAFE.balance - project0, 0.1 ether, "project still paid");
        assertEq(splitter.buybackPool(), 0.4 ether);
        assertEq(splitter.distribute(), 0, "owed native is not counted as new revenue");
        vm.warp(block.timestamp + 1 hours);
        splitter.buyback();
        vm.expectRevert(GenesisSplitter.TransferFailed.selector);
        splitter.withdrawOwed(address(rejector));
        rejector.setAccept(true);
        assertEq(splitter.withdrawOwed(address(rejector)), 0.2 ether);
        assertEq(address(rejector).balance, 0.2 ether);
        assertEq(splitter.totalOwedNative(), 0);
        vm.expectRevert(GenesisSplitter.NothingToSwap.selector);
        splitter.withdrawOwed(address(rejector));
    }

    function test_DirectNativeCountsAsRevenue() public {
        (bool ok,) = address(splitter).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(splitter.distribute(), 1 ether);
    }

    // ---------------- 回购 ----------------

    function test_BuybackWrapsSwapsSingleHopAndBurns() public {
        _mintTransistors(10_000); // 10 OKB，回购池 4 OKB
        uint256 out = splitter.buyback();
        assertEq(splitter.buybackPool(), 3 ether, "at most 1 OKB per call");
        assertEq(out, BEM_PER_NATIVE);
        assertEq(bem.balanceOf(DEAD), out);
        assertEq(splitter.totalBemBurned(), out);
        assertEq(router.lastFee(), POOL_FEE, "single hop through the 1% pool");
        assertEq(wrapped.balanceOf(address(router)), 1 ether, "OKB wrapped to WOKB and paid to the router");
        assertEq(wrapped.balanceOf(address(splitter)), 0);
        assertEq(wrapped.allowance(address(splitter), address(router)), 0, "allowance reset");
        vm.expectRevert(GenesisSplitter.TooSoon.selector);
        splitter.buyback();
        vm.warp(block.timestamp + 1 hours);
        splitter.buyback();
        assertEq(bem.balanceOf(DEAD), 2 * out);
    }

    function test_BuybackMinOutIs98PercentOfTwap() public {
        _mintTransistors(1_000);
        assertEq(splitter.minOutFor(1 ether), BEM_PER_NATIVE * 9_800 / 10_000);
        router.setRate(BEM_PER_NATIVE * 9_750 / 10_000); // 比参考价差 2.5%：拒绝成交
        vm.expectRevert(bytes("Too little received"));
        splitter.buyback();
        router.setRate(BEM_PER_NATIVE * 9_850 / 10_000); // 差 1.5%：可以成交
        splitter.buyback();
        assertEq(splitter.buybackPool(), 0);
    }

    function test_BuybackCallerMinOutRespected() public {
        _mintTransistors(1_000);
        vm.expectRevert(bytes("Too little received"));
        splitter.buyback(BEM_PER_NATIVE);
    }

    function test_RevertWhen_NothingToBuyBack() public {
        vm.expectRevert(GenesisSplitter.NothingToSwap.selector);
        splitter.buyback();
    }

    /// @dev 观测点不够、TWAP 读不出来：回购和回馈兑换都暂停（整笔 revert，资金不动），分账照常
    function test_SwapsPauseWhileTwapUnavailable() public {
        _mintTransistors(1_000);
        splitter.distribute();
        oracle.setUnavailable(true);
        vm.expectRevert(bytes("OLD"));
        splitter.buyback();
        assertEq(splitter.buybackPool(), 0.4 ether, "nothing spent");
        XMonthBoard m = _startGenesis();
        _fillMonth(m);
        vm.expectRevert(bytes("OLD"));
        splitter.claimReward(1);
        _mintTransistors(1_000);
        assertGt(splitter.distribute(), 0, "distribution does not need the oracle");
        oracle.setUnavailable(false);
        splitter.buyback();
        splitter.claimReward(1);
    }

    // ---------------- 回馈 ----------------

    function test_ClaimRewardBecomesMonthBoardSubsidy() public {
        _mintTransistors(1_000);
        XMonthBoard m = _startGenesis(); // 开局时先分账一次：桶 1 = 0.1 OKB
        assertEq(splitter.rewardBucket(1), 0.1 ether);
        vm.expectRevert(GenesisSplitter.BoardNotActive.selector);
        splitter.claimReward(1); // 第 1 块还没开局
        _fillMonth(m);
        assertEq(factory.rewardBoard(1), address(m));
        splitter.distribute(); // 参与者铸通行证也带来了铸造收入
        uint256 bucket = splitter.rewardBucket(1);
        uint256 budget0 = m.budget();
        uint256 out = splitter.claimReward(1);
        assertEq(out, bucket * BEM_PER_NATIVE / 1e18);
        assertEq(m.subsidyCapital(), out);
        assertEq(m.budget(), budget0 + out);
        assertEq(splitter.rewardBucket(1), 0);
        assertEq(splitter.totalRewardBem(1), out);
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(GenesisSplitter.NothingToSwap.selector);
        splitter.claimReward(1);
        _mintTransistors(1_000);
        uint256 out2 = splitter.claimReward(1);
        assertEq(out2, 0.1 ether * BEM_PER_NATIVE / 1e18);
        _mintTransistors(1_000);
        vm.expectRevert(GenesisSplitter.TooSoon.selector);
        splitter.claimReward(1);
    }

    function test_RevertWhen_BadBucketOrNoBoard() public {
        vm.expectRevert(GenesisSplitter.BadBucket.selector);
        splitter.claimReward(0);
        vm.expectRevert(GenesisSplitter.BadBucket.selector);
        splitter.claimReward(6);
        vm.expectRevert(GenesisSplitter.BoardNotActive.selector);
        splitter.claimReward(2);
    }

    /// @dev 第 1 块月局没买到矿机、直接结算 = 已结束：它那一桶的余额和之后的份额转入回购池
    function test_EndedBoardShareGoesToBuyback() public {
        _mintTransistors(1_000);
        XMonthBoard m = _startGenesis();
        _fillMonth(m);
        splitter.distribute();
        uint256 oldBucket1 = splitter.rewardBucket(1);
        uint256 oldBucket2 = splitter.rewardBucket(2);
        vm.warp(m.prepEnd());
        m.sync();
        assertEq(uint256(m.state()), uint256(MonthState.Settling));
        assertTrue(splitter.boardEnded(1));
        _mintTransistors(1_000);
        uint256 poolBefore = splitter.buybackPool();
        splitter.distribute();
        assertEq(splitter.rewardBucket(1), 0);
        assertEq(splitter.buybackPool() - poolBefore, oldBucket1 + 0.4 ether + 0.1 ether);
        assertEq(splitter.rewardBucket(2), oldBucket2 + 0.08 ether);
    }

    function test_WithdrawFailureDoesNotBlockDistribution() public {
        vm.expectEmit(false, false, false, false, address(splitter));
        emit GenesisSplitter.WithdrawFailed("");
        assertEq(splitter.distribute(), 0);
    }
}

/// @dev 测试用：可以切换是否接收原生币的地址（模拟拒收的 Safe）
contract NativeRejector {
    bool public accept;

    function setAccept(bool v) external {
        accept = v;
    }

    receive() external payable {
        require(accept, "rejected");
    }
}
