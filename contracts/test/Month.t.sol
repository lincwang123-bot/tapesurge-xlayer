// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {XMonthBoard as MonthBoard} from "../src/XMonthBoard.sol";
import {XMonthFactory as MonthFactory} from "../src/XMonthFactory.sol";
import {XHub as BoardFactory} from "../src/XHub.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {MonthState} from "../src/interfaces/IXMonthBoard.sol";
import {PrizeHarness} from "./MonthStats.t.sol";

/// @notice 月局：开局、招募四种结果、准备矿机、30 天挖矿、开奖、随机数停摆、升级哨兵、首批回馈
contract MonthTest is Fixture {
    MonthBoard internal m;
    address internal keeper = address(0xBEEF);

    function setUp() public override {
        super.setUp();
        _startGenesis();
        m = _monthBoard();
    }

    /// @dev 招满 100 BEM（25 人 × 4 BEM），收购两台矿机，进入挖矿
    function _toMining() internal returns (address[] memory users) {
        users = _fillMonth(m);
        _sellMonth(m, _newUser(), 30);
        _sellMonth(m, _newUser(), 20);
        vm.warp(m.prepEnd());
        m.sync();
        assertEq(uint256(m.state()), uint256(MonthState.Mining));
    }

    // ---------------- 开局与招募 ----------------

    function test_GenesisOpensFirstMonthBoard() public view {
        assertEq(monthFactory.boardCount(), 1);
        assertEq(m.number(), 1);
        assertEq(m.target(), 100 * BEM_1);
        assertEq(m.minStake(), 0.2e8);
        assertEq(m.maxStake(), 4 * BEM_1);
        assertEq(m.recruitDeadline(), block.timestamp + 3 days);
        assertEq(uint256(m.state()), uint256(MonthState.Recruiting));
        assertTrue(factory.isBoard(address(m)), "hub knows month boards");
        assertTrue(monthFactory.isBoard(address(m)));
        assertEq(factory.monthFactory(), address(monthFactory));
        assertEq(m.PASS_CIRCUITS(), address(passCircuits));
        assertEq(m.SPLITTER(), address(splitter));
    }

    function test_FastFillGrowsNextMonthTarget() public {
        _fillMonth(m); // 1 天内招满
        assertEq(uint256(m.state()), uint256(MonthState.Preparing));
        assertEq(_monthBoard().target(), 125 * BEM_1);
        assertEq(_monthBoard().number(), 2);
        assertEq(m.target(), 100 * BEM_1, "started board target remains fixed");
        // 入场费留在主板，开始挖矿时才转给手续费地址
        assertEq(bem.balanceOf(FEE_SAFE), 0);
        _sellMonth(m, _newUser(), 50);
        vm.warp(m.prepEnd());
        m.sync();
        assertEq(uint256(m.state()), uint256(MonthState.Mining));
        assertEq(bem.balanceOf(FEE_SAFE), 1 * BEM_1);
        assertEq(m.accountedBalance(), bem.balanceOf(address(m)));
    }

    function test_FillAfterOneDayKeepsTarget() public {
        vm.warp(block.timestamp + 1 days);
        _fillMonth(m);
        assertEq(_monthBoard().target(), 100 * BEM_1);
    }

    function test_PartialStartAtSixtyPercentShrinks() public {
        _fillMonth(m); // → 125
        _fillMonth(_monthBoard()); // → 156
        MonthBoard m3 = _monthBoard();
        assertEq(m3.target(), 156 * BEM_1);
        uint256 maxS = m3.maxStake(); // 6.24 BEM
        for (uint256 i = 0; i < 16; i++) {
            _joinMonth(m3, maxS); // 99.84 BEM = 64%
        }
        vm.warp(block.timestamp + 3 days);
        m3.closeRecruitment();
        assertEq(uint256(m3.state()), uint256(MonthState.Preparing));
        assertEq(m3.budget(), 16 * maxS);
        assertEq(_monthBoard().target(), 117 * BEM_1); // 156 × 0.75 = 117
    }

    function test_FailedRecruitmentRefundsAndHalvesToFloor() public {
        address u = _joinMonth(m, 4 * BEM_1);
        uint256 passId = m.socket(1).passId;
        vm.warp(block.timestamp + 3 days);
        m.closeRecruitment();
        assertEq(uint256(m.state()), uint256(MonthState.Failed));
        _mClaimAll(m, u);
        assertEq(bem.balanceOf(u), 8 * BEM_1, "stake + fee refunded");
        assertEq(passCircuits.ownerOf(passId), u);
        MonthBoard retry = _monthBoard();
        assertEq(retry.number(), 1, "same number reopened");
        assertEq(retry.target(), 100 * BEM_1, "x0.5 clamped to 100");
        assertEq(monthFactory.attemptsOf(1), 2);
    }

    function test_PassLockedInOneBoardAtATime() public {
        address u = _newUser();
        uint256 passId = _mintPass(u);
        _fillMonth(m);
        MonthBoard next = _monthBoard();
        bem.mint(u, 10 * BEM_1);
        vm.startPrank(u);
        passCircuits.approve(address(next), passId);
        bem.approve(address(next), type(uint256).max);
        next.join(passId, 1 * BEM_1);
        vm.stopPrank();
        _fillMonth(next);
        MonthBoard later = _monthBoard();
        // 同一张通行证已经锁在上一块月局，不能重复加入另一块月局。
        vm.startPrank(u);
        bem.approve(address(later), type(uint256).max);
        vm.expectRevert(MonthBoard.NotPassOwner.selector);
        later.join(passId, 1 * BEM_1);
        vm.stopPrank();
    }

    // ---------------- 首批回馈：月局按开局顺序 ----------------

    function test_RewardRankCountsMonthBoardStarts() public {
        _fillMonth(m);
        MonthBoard next = _monthBoard();
        _fillMonth(next);
        assertEq(factory.rewardBoard(1), address(m));
        assertEq(factory.rewardBoard(2), address(next));
        assertEq(factory.startCount(), 2);

        address minter = address(0xA11CE);
        vm.deal(minter, 2 ether);
        vm.prank(minter);
        transistors.mint{value: 1_000 * 0.0011 ether}(0, 1_000);
        uint256 out = splitter.claimReward(1); // 第 1 桶（10%）给月局
        assertGt(out, 0);
        assertEq(m.subsidyCapital(), out);
        assertEq(m.budget(), 100 * BEM_1 + out, "subsidy joins purchase budget");
    }

    function test_SubsidyAcceptedUntilSettlement() public {
        assertFalse(m.acceptsSubsidy());
        _toMining();
        assertTrue(m.acceptsSubsidy());
        assertFalse(m.rewardEnded());
        vm.prank(address(splitter));
        vm.expectRevert(); // 没有授权 BEM
        m.depositSubsidy(1);
        vm.expectRevert(MonthBoard.OnlySplitter.selector);
        m.depositSubsidy(1);
    }

    // ---------------- 准备矿机 ----------------

    function test_PreparationBuysMachinesWithinThreeDays() public {
        _fillMonth(m);
        assertTrue(m.isPurchasing());
        address seller = _newUser();
        (uint256 mid,) = _newMachine(seller, 50);
        uint256 cap = m.buyPriceCap();
        assertEq(cap, 1.65e8, "first board uses the configured fallback cap");
        assertEq(m.buyPrice(), cap / 2);
        vm.startPrank(seller);
        machines.approve(address(m), mid);
        uint256 paid = m.sellMachine(address(machines), mid, 0);
        vm.stopPrank();
        assertEq(paid, 50 * (cap / 2));
        assertEq(m.machine(0).cost, paid);
        vm.warp(m.prepEnd());
        assertFalse(m.isPurchasing());
        (uint256 id,) = _newMachine(address(this), 20);
        machines.approve(address(m), id);
        vm.expectRevert(MonthBoard.BuyRoundInactive.selector);
        m.sellMachine(address(machines), id, 0);
        m.sync();
        assertEq(m.miningStart(), m.prepEnd());
        assertEq(m.miningEnd(), m.prepEnd() + 30 days);
        assertEq(m.budget(), 100 * BEM_1 - paid, "unspent BEM stays in board");
    }

    /// @dev 一台矿机都没买到就结算时，本金和 1% 入场费都退还，手续费地址什么也没收到
    function test_NoMachinesRefundsPrincipalAndEntryFee() public {
        address[] memory users = _fillMonth(m);
        vm.warp(m.prepEnd());
        m.sync();
        assertEq(uint256(m.state()), uint256(MonthState.Settling));
        for (uint256 i = 0; i < users.length; i++) {
            assertEq(_mOwed(m, users[i]), 4 * BEM_1 + 4 * BEM_1 / 100);
        }
        assertEq(m.finishedAt(), block.timestamp);
        assertEq(bem.balanceOf(FEE_SAFE), 0);
        for (uint256 i = 0; i < users.length; i++) {
            _mWithdraw(m, users[i]);
        }
        assertLe(bem.balanceOf(address(m)), users.length, "dust only");
    }

    /// @dev 升级哨兵冷静期内在准备期提前结算（没挖矿），入场费同样退还
    function test_EmergencySettleDuringPreparationRefundsEntryFee() public {
        address[] memory users = _fillMonth(m);
        _sellMonth(m, _newUser(), 50);
        machineBeacon.upgradeTo(address(0xBAD));
        vm.prank(users[0]);
        m.emergencySettle();
        assertEq(uint256(m.state()), uint256(MonthState.Settling));
        assertEq(m.miningStart(), 0);
        assertEq(bem.balanceOf(FEE_SAFE), 0);
        uint256 owedAll;
        for (uint256 i = 0; i < users.length; i++) {
            owedAll += _mOwed(m, users[i]);
        }
        // 买矿后剩下的预算 + 入场费按投入比例退还（矿机卖出后再退其余本金）
        assertApproxEqAbs(owedAll, m.totalStake() - m.totalSpent() + m.totalEntryFees(), users.length);
    }

    // ---------------- 挖矿与开奖 ----------------

    function test_YieldDuringMiningGoesToPrizePool() public {
        _toMining();
        _yield2(5 * BEM_1);
        m.harvest();
        assertEq(m.prizePool(), 5 * BEM_1);
        vm.expectRevert(MonthBoard.NotYet.selector);
        m.drawPrizes();
    }

    /// @dev 用月局的投入独立算出 5 个奖的中奖插槽
    function _expectedWinners(uint256 word) internal returns (uint256[5] memory) {
        uint256 n = m.socketCount();
        uint256[] memory w = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            w[i] = m.socket(i + 1).stake;
        }
        return new PrizeHarness(w).winnersFor(word);
    }

    function test_DrawPushesFeesAndFivePrizes() public {
        _toMining();
        _yield2(10 * BEM_1);
        vm.warp(m.miningEnd());
        uint256 idle = m.budget(); // 进入结算时没花完的资本按"本金 → 回馈 → 溢价"退还，同样按比例记给持仓
        m.drawPrizes(); // 测试合约是运营地址
        assertEq(uint256(m.state()), uint256(MonthState.Drawing));
        uint256 pot = m.prizePool();
        assertEq(pot, 10 * BEM_1);
        uint256 word = uint256(keccak256("prizes"));
        uint256[5] memory slots = _expectedWinners(word);
        vm.expectRevert(MonthBoard.NotYet.selector);
        m.finalizePrizes(); // 随机数还没到
        rng.fulfill(m.pendingRequestId(), word);
        // 回调只记下随机数；之后不能再重发、也不能走停摆保底，只能用这个随机数开奖
        assertEq(uint256(m.state()), uint256(MonthState.Drawing));
        assertTrue(m.wordReceived());
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(MonthBoard.NoPendingDraw.selector);
        m.retryDraw();
        vm.expectRevert(MonthBoard.NoPendingDraw.selector);
        m.triggerSafeSettle();
        uint256[5] memory before;
        for (uint256 i = 0; i < 5; i++) {
            before[i] = bem.balanceOf(m.socket(slots[i]).owner);
        }
        uint256 f0 = bem.balanceOf(FOUNDATION);
        uint256 fee0 = bem.balanceOf(FEE_SAFE);
        m.finalizePrizes();

        assertEq(uint256(m.state()), uint256(MonthState.Settling));
        assertTrue(m.prizesDrawn());
        // v2（BSC 规则决定 6.15）：月局只收入场费，奖金池不扣 3% / 2%，全部开奖（没有调用者奖励）
        assertEq(bem.balanceOf(FOUNDATION), f0, "no 3%");
        assertEq(bem.balanceOf(FEE_SAFE), fee0, "no 2%");
        // v2（BSC 规则决定 6.20）：一半按投入比例记给所有持仓，另一半抽 5 个奖
        uint256 net = pot / 2;
        assertApproxEqAbs(_owedAll(), (pot - net) + idle, m.socketCount(), "half shared pro rata");
        uint256[5] memory bps = [uint256(6_000), 1_500, 1_500, 500, 500];
        uint256 sum;
        for (uint256 i = 0; i < 5; i++) {
            assertEq(m.winnerSlots(i), slots[i]);
            if (i > 0) assertEq(m.prizeAmounts(i), net * bps[i] / 10_000);
            sum += m.prizeAmounts(i);
        }
        assertEq(sum, net, "prizes use exactly the drawn half");
        // 奖金直接推送：中奖者余额增加 = 他中的所有奖之和（可以重复中奖）
        for (uint256 i = 0; i < 5; i++) {
            uint256 expected;
            for (uint256 j = 0; j < 5; j++) {
                if (slots[j] == slots[i]) expected += m.prizeAmounts(j);
            }
            assertEq(bem.balanceOf(m.socket(slots[i]).owner) - before[i], expected);
            assertEq(m.credit(m.socket(slots[i]).owner), 0);
        }
    }

    function _owedAll() internal view returns (uint256 t) {
        for (uint256 s = 1; s <= m.socketCount(); s++) {
            t += m.owed(s);
        }
    }

    function test_DrawAndFinalizeAreOperatorOnlyWithParticipantFallback() public {
        address[] memory users = _toMining();
        _yield2(10 * BEM_1);
        vm.warp(m.miningEnd());
        vm.prank(users[0]);
        vm.expectRevert(MonthBoard.NotAuthorized.selector);
        m.drawPrizes();
        vm.warp(m.miningEnd() + 3 days);
        vm.prank(keeper); // 外人 3 天后仍然不行
        vm.expectRevert(MonthBoard.NotAuthorized.selector);
        m.drawPrizes();
        vm.prank(users[0]); // 参与者兜底
        m.drawPrizes();
        rng.fulfill(m.pendingRequestId(), 77);
        vm.prank(users[1]);
        vm.expectRevert(MonthBoard.NotAuthorized.selector);
        m.finalizePrizes();
        vm.warp(block.timestamp + 3 days);
        vm.prank(users[1]);
        m.finalizePrizes();
        assertTrue(m.prizesDrawn());
    }

    function test_EmptyPrizePoolSkipsRandomness() public {
        _toMining();
        vm.warp(m.miningEnd());
        m.drawPrizes();
        assertEq(uint256(m.state()), uint256(MonthState.Settling));
        assertFalse(m.prizesDrawn());
        assertEq(rng.lastRequestId(), 0);
    }

    // ---------------- 随机数超时与停摆 ----------------

    function test_RandomnessRetryOnlyAfter24hAndEveryRequestCounts() public {
        _toMining();
        _yield2(10 * BEM_1);
        vm.warp(m.miningEnd());
        m.drawPrizes();
        uint256 oldId = m.pendingRequestId();
        vm.expectRevert(MonthBoard.TooEarly.selector);
        m.retryDraw();
        vm.warp(block.timestamp + 1 days);
        vm.prank(keeper);
        vm.expectRevert(MonthBoard.NotAuthorized.selector);
        m.retryDraw();
        m.retryDraw(); // 运营地址
        uint256 newId = m.pendingRequestId();
        assertTrue(newId != oldId);
        // 重发不作废旧请求，先到先用，之后的回调被忽略
        rng.fulfill(oldId, 1);
        assertTrue(m.wordReceived(), "the old request still counts");
        assertFalse(m.drawPending());
        rng.fulfill(newId, 2);
        assertEq(uint256(m.state()), uint256(MonthState.Drawing));
        m.finalizePrizes();
        assertEq(uint256(m.state()), uint256(MonthState.Settling));
    }

    function test_RandomnessStallSharesPrizePoolProRataWithoutFees() public {
        address[] memory users = _toMining();
        _yield2(10 * BEM_1);
        vm.warp(m.miningEnd());
        m.drawPrizes();
        vm.warp(block.timestamp + 7 days - 1);
        vm.expectRevert(MonthBoard.TooEarly.selector);
        m.triggerSafeSettle();
        vm.warp(block.timestamp + 1);
        m.triggerSafeSettle();
        assertEq(uint256(m.state()), uint256(MonthState.Settling));
        assertFalse(m.prizesDrawn());
        assertEq(m.credit(FOUNDATION), 0, "no 3%");
        assertEq(m.credit(FEE_SAFE), 0, "no 2%");
        assertEq(m.credit(address(this)), 0, "no caller reward");
        // 奖金池 10 BEM + 未花完的本金按投入比例分（每人 4 / 100）
        uint256 idle = 100 * BEM_1 - m.totalSpent();
        for (uint256 i = 0; i < users.length; i++) {
            assertApproxEqAbs(_mOwed(m, users[i]), (10 * BEM_1 + idle) * 4 / 100, 2);
        }
        rng.fulfill(m.pendingRequestId(), 5);
        assertFalse(m.prizesDrawn(), "late randomness ignored");
    }

    // ---------------- 升级哨兵 ----------------

    function test_SentinelBlocksJoinAndAllowsEarlySettlement() public {
        address[] memory users = _toMining();
        _monthBoard().closeRecruitment(); // 下一块的 3 天招募已过期：宣布失败，工厂重开一块
        MonthBoard next = _monthBoard();
        (address u, uint256 passId) = _prepareJoin(next);
        machineBeacon.upgradeTo(address(0xBAD));
        vm.prank(u);
        vm.expectRevert(MonthBoard.UpgradeSentinelTripped.selector);
        next.join(passId, 1 * BEM_1);
        _yield2(3 * BEM_1);
        vm.expectRevert(MonthBoard.NotParticipant.selector);
        m.emergencySettle();
        vm.prank(users[0]);
        m.emergencySettle();
        assertEq(uint256(m.state()), uint256(MonthState.Settling));
        assertFalse(m.prizesDrawn());
        assertEq(m.credit(FOUNDATION), 0);
        // 拍卖与接力暂停
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(MonthBoard.UpgradeSentinelTripped.selector);
        sales.buyMachine(address(m), 0, type(uint256).max);
    }

    /// @dev 项目方 2026-10-20 方案 A：冷静期内月局不能加入、招募失败不重开；登记满 30 天后可以重开、可以加入
    function test_MonthJoinAndReopenResumeAfterCoolingPeriod() public {
        machineBeacon.upgradeTo(address(0xBAD));
        factory.noteSentinel();
        uint256 since = factory.sentinelSince();
        (address u, uint256 passId) = _prepareJoin(m);
        vm.prank(u);
        vm.expectRevert(MonthBoard.UpgradeSentinelTripped.selector);
        m.join(passId, 1 * BEM_1);
        m.closeRecruitment(); // 冷静期内可以立即结束招募
        assertEq(uint256(m.state()), uint256(MonthState.Failed));
        assertEq(monthFactory.recruitingBoard(), address(0));
        vm.expectRevert(MonthFactory.SentinelPaused.selector);
        monthFactory.reopen();
        vm.warp(since + 30 days);
        MonthBoard nm = MonthBoard(monthFactory.reopen());
        assertEq(monthFactory.recruitingBoard(), address(nm));
        vm.expectRevert(MonthFactory.NothingToReopen.selector);
        monthFactory.reopen();
        (address v, uint256 pass2) = _prepareJoin(nm);
        uint256 amt = nm.minStake();
        vm.prank(v);
        nm.join(pass2, amt);
        assertEq(nm.socketCount(), 1);
    }

    function test_ExpiredBoardMustDrawNormallyUnderSentinel() public {
        address[] memory users = _toMining();
        vm.warp(m.miningEnd());
        machineBeacon.upgradeTo(address(0xBAD));
        vm.prank(users[0]);
        vm.expectRevert(MonthBoard.WrongState.selector);
        m.emergencySettle();
    }

    // ---------------- 领取期限 ----------------

    /// @dev v2（BSC 规则决定 6.13）：过期未领的 BEM 转到 0x…dEaD 销毁，不再给基金会
    function test_ClaimWindowBurnsLeftovers() public {
        address[] memory users = _fillMonth(m);
        vm.warp(m.prepEnd());
        m.sync(); // 没买到矿机，直接结算
        _mWithdraw(m, users[0]);
        vm.warp(block.timestamp + 365 days);
        uint256 f0 = bem.balanceOf(FOUNDATION);
        uint256 d0 = bem.balanceOf(DEAD);
        m.closeClaims();
        assertEq(bem.balanceOf(DEAD) - d0, 96 * BEM_1 * 101 / 100); // 没挖矿：入场费随本金退还，过期一起销毁
        assertEq(bem.balanceOf(FOUNDATION), f0);
        uint256 sl_ = _slot(m, users[1]);
        vm.expectRevert(MonthBoard.ClaimsAreClosed.selector);
        m.withdraw(sl_);
        _mReturnPass(m, users[1]);
    }

    // ---------------- 辅助 ----------------

    /// @dev 模拟跨链 BEM 到账；不调用 BSC PoD 的领取接口。
    function _yield2(uint256 amount) internal {
        _yieldMonth(m, amount);
    }

    function _prepareJoin(MonthBoard mb) internal returns (address u, uint256 passId) {
        u = _newUser();
        passId = _mintPass(u);
        bem.mint(u, 10 * BEM_1);
        vm.startPrank(u);
        passCircuits.approve(address(mb), passId);
        bem.approve(address(mb), type(uint256).max);
        vm.stopPrank();
    }

    // ---------------- 注册中心 ----------------

    function test_OnlyMonthFactoryCanRegisterStarts() public {
        vm.expectRevert(BoardFactory.OnlyMonthFactory.selector);
        factory.registerStart(address(this));
        vm.expectRevert(MonthFactory.OnlyHub.selector);
        monthFactory.openFirst();
        vm.expectRevert(MonthFactory.OnlyRecruitingBoard.selector);
        monthFactory.onBoardStarted(true, 0);
    }

    function test_MonthFactoryRejectsWrongHub() public {
        MonthFactory.Params memory mp = defaultMonthParams();
        vm.expectRevert(MonthFactory.BadHub.selector);
        new MonthFactory(address(factory), mp); // hub 记录的是另一个月局工厂
    }

    function test_MonthBoardsCannotBeReinitialized() public {
        vm.expectRevert(MonthBoard.OnlyFactory.selector);
        m.initialize(9, 100 * BEM_1, 0.2e8, 4 * BEM_1);
        vm.prank(address(monthFactory));
        vm.expectRevert(MonthBoard.AlreadyInitialized.selector);
        m.initialize(9, 100 * BEM_1, 0.2e8, 4 * BEM_1);
        assertEq(monthFactory.boardConfig().miningDuration, 30 days);
        assertEq(monthFactory.boardConfig().passCircuits, address(passCircuits));
    }

    // ---------------- 自动发放 ----------------

    function test_FailedRefundsDistributedInBatchesWithoutDoublePay() public {
        address[] memory users = new address[](6);
        for (uint256 i = 0; i < 6; i++) {
            users[i] = _joinMonth(m, 2 * BEM_1);
        }
        vm.warp(block.timestamp + 3 days);
        m.closeRecruitment();
        // 1 号先自领
        _mClaimAll(m, users[0]);
        vm.prank(users[2]); // 参与者在 3 天内不能代替运营地址分发
        vm.expectRevert(MonthBoard.NotAuthorized.selector);
        sales.distribute(address(m), 1, 6);
        sales.distribute(address(m), 1, 3); // 第一批：1–3 号
        sales.distribute(address(m), 4, 100); // 第二批：4–6 号（超出范围的部分忽略）
        sales.distribute(address(m), 1, 6); // 重复调用不会重复支付
        for (uint256 i = 0; i < 6; i++) {
            assertEq(bem.balanceOf(users[i]), 4 * BEM_1, "stake + fee refunded exactly once");
            assertEq(passCircuits.ownerOf(m.socket(i + 1).passId), users[i]);
        }
        assertEq(bem.balanceOf(address(m)), 0);
        uint256 sl_ = _slot(m, users[3]);
        vm.expectRevert(MonthBoard.NothingToWithdraw.selector);
        m.withdraw(sl_);
    }
}
