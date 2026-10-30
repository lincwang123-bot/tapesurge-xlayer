// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {XMonthBoard as MonthBoard} from "../src/XMonthBoard.sol";
import {MonthState} from "../src/interfaces/IXMonthBoard.sol";
import {XMonthMachineSales as MonthMachineSales} from "../src/month/XMonthMachineSales.sol";

/// @notice 月局收回本金（v2）：交接（经卖矿单例，运营地址专属，在接手方的收购拍卖里按它的收购价成交且不低于成本价，
///         预算不够只接一部分）、挂单（经卖矿单例，≥ 成本价，1 天未挂自动按成本价可买，7 天未卖出降到成本价且不能再调高）、
///         溢价分成 10%、卖不出继续挖、回馈资本滚入下一块月局、自动发放与自领不重复、资金守恒
contract MonthSettlementTest is Fixture {
    using stdStorage for StdStorage;

    MonthBoard internal m; // 第 1 块月局：会进入结算
    address[] internal players;
    address internal buyer = address(0xB0B);
    address internal minter = address(0xA11CE);
    uint256 internal saleProceeds;
    uint256 internal relayProceeds;
    mapping(address => uint256) internal startBal;
    uint256 internal constant W0 = 30;
    uint256 internal constant W1 = 20;
    uint256 internal constant W2 = 40;

    function setUp() public override {
        super.setUp();
        _startGenesis();
        m = _monthBoard();
        bem.mint(buyer, 10_000 * BEM_1);
        vm.prank(buyer);
        bem.approve(address(sales), type(uint256).max);
    }

    /// @dev 第 1 块月局：招满（小数投入）→ 领回馈 → 收购 3 台矿机 → 挖 30 天 → 开奖 → 进入结算
    function _settle(bool withSubsidy) internal {
        uint256 i;
        while (m.state() == MonthState.Recruiting) {
            uint256 span = m.maxStake() - m.minStake();
            uint256 amt = m.minStake() + (uint256(keccak256(abi.encode("ms", i++))) % span) / 1e6 * 1e6;
            address u = _joinMonth(m, amt);
            players.push(u);
            startBal[u] = bem.balanceOf(u);
        }
        if (withSubsidy) {
            vm.deal(minter, 5 ether);
            vm.prank(minter);
            transistors.mint{value: 2_000 * 0.0011 ether}(0, 2_000);
            splitter.claimReward(1); // 月局是第 1 块开局的主板
            assertGt(m.subsidyCapital(), 0);
        }
        address seller = _newUser();
        _sellMonth(m, seller, W0);
        vm.warp(block.timestamp + 1 days);
        _sellMonth(m, seller, W1);
        _sellMonth(m, seller, W2);
        vm.warp(m.prepEnd());
        m.sync();
        vm.warp(m.miningEnd());
        _yieldMonth(m, 451_000 * (W0 + W1 + W2) * 30); // 30 天的跨链实到账收益
        m.drawPrizes();
        rng.fulfill(m.pendingRequestId(), uint256(keccak256("month prizes")));
        m.finalizePrizes();
        assertEq(uint256(m.state()), uint256(MonthState.Settling));
    }

    /// @dev 一块正在准备矿机的新月局（之前那块招募已过期时先宣布失败、重开）
    function _freshPreparing() internal returns (MonthBoard r) {
        r = _monthBoard();
        if (block.timestamp >= r.recruitDeadline()) {
            r.closeRecruitment();
            r = _monthBoard();
        }
        _fillMonth(r);
        assertTrue(r.isPurchasing());
    }

    function _relay(uint256 index, MonthBoard to) internal {
        relayProceeds += _relayWhenPriced(m, index, to);
    }

    function _buy(uint256 index) internal {
        _syncRigs(m);
        vm.prank(buyer);
        saleProceeds += sales.buyMachine(address(m), index, type(uint256).max);
    }

    // ---------------- 接力 ----------------

    function test_RelayAtReceiverBuyPrice() public {
        _settle(false);
        MonthBoard r = _freshPreparing();
        uint256 cost = m.machine(0).cost;
        uint256 principalBefore = m.principalRemaining();
        uint256 budgetBefore = r.budget();
        uint256 feeSafeBefore = bem.balanceOf(FEE_SAFE);
        _feedDefault();
        // 收购价还低于成本价：成交失败，凭证不动
        if (r.buyPrice() * m.machine(0).weight < cost) {
            vm.expectRevert(MonthBoard.PriceBelowMinimum.selector);
            sales.relay(address(m), 0, address(r));
            assertFalse(m.machine(0).sold);
        }
        uint256 paid = _relayWhenPriced(m, 0, r);
        assertGe(paid, cost, "never below cost");
        assertEq(paid, r.buyPrice() * m.machine(0).weight, "at the receiver's current buy price");
        assertEq(machines.ownerOf(m.machine(0).circuitId), address(r));
        assertTrue(m.machine(0).sold);
        assertEq(r.machine(0).cost, paid, "receiver cost basis = price paid");
        assertEq(r.budget(), budgetBefore - paid);
        // 溢价分成：超过成本价的部分 10% 给手续费地址，其余照旧先退本金
        uint256 fee = (paid - cost) * m.PREMIUM_FEE_BPS() / 10_000;
        assertEq(m.PREMIUM_FEE_BPS(), 1_000);
        assertEq(bem.balanceOf(FEE_SAFE) - feeSafeBefore, fee, "10% of the premium to the fee safe");
        assertEq(m.principalRemaining(), principalBefore - (paid - fee), "relay proceeds refund principal");
    }

    function test_RelayIsOperatorOnlyWithParticipantFallback() public {
        _settle(false);
        MonthBoard r = _freshPreparing();
        vm.prank(players[0]);
        vm.expectRevert(MonthMachineSales.NotAuthorized.selector);
        sales.relay(address(m), 0, address(r));
        vm.warp(m.settleStart() + 3 days);
        r = _freshPreparing();
        _feedDefault();
        while (r.buyPrice() * m.machine(0).weight < m.machine(0).cost) {
            vm.warp(block.timestamp + 6 hours);
            _feedDefault();
        }
        _yieldMonth(m, 0); // 运营上交接前先在 BSC 上收取一次，刷新 RIG 的同步时间（接手方要求 3 天内同步过）
        vm.prank(buyer); // 外人 3 天后仍然不行
        vm.expectRevert(MonthMachineSales.NotAuthorized.selector);
        sales.relay(address(m), 0, address(r));
        vm.prank(players[0]); // 本局持仓的持有人兜底
        sales.relay(address(m), 0, address(r));
        assertTrue(m.machine(0).sold);
    }

    function test_RelayRejectedWhenReceiverPriceBelowCost() public {
        _settle(false);
        // 工厂公布更低的实测日产出：接手方开局时快照的上限（365 天产出）低于成本价，收购价涨到顶也不够
        stdstore.target(address(monthFactory)).sig("unitYieldPerDay()").checked_write(uint256(100_000));
        MonthBoard r = _freshPreparing();
        vm.warp(block.timestamp + 60 hours); // 收购价到上限
        _feedDefault();
        assertEq(r.buyPrice(), r.buyPriceCap());
        assertLt(m.machine(0).weight * r.buyPriceCap(), m.machine(0).cost);
        _syncRigs(m);
        vm.expectRevert(MonthBoard.PriceBelowMinimum.selector);
        sales.relay(address(m), 0, address(r));
        assertFalse(m.machine(0).sold);
    }

    /// @dev 上限是开局时的最近一次实测收益快照，整个准备期内不随新报告变化。
    function test_MonthCapIsSnapshotDuringPreparation() public {
        _settle(false);
        MonthBoard r = _freshPreparing();
        uint256 snap = r.buyPriceCap();
        assertGt(snap, 0);
        vm.mockCall(address(monthFactory), abi.encodeWithSignature("unitYieldPerDay()"), abi.encode(uint256(100_000)));
        assertEq(r.buyPriceCap(), snap);
        vm.mockCall(
            address(monthFactory), abi.encodeWithSignature("unitYieldPerDay()"), abi.encode(uint256(10_000_000))
        );
        assertEq(r.buyPriceCap(), snap);
        _relay(0, r); // 按快照定价，收购价涨到不低于成本价就能成交
        assertTrue(m.machine(0).sold);
    }

    /// @dev 外部审计 #2：结算中哨兵触发，出售暂停；记录触发满 30 天后自动恢复（信标仍是升级后的）
    function test_SalesResumeThirtyDaysAfterTrip() public {
        _settle(false);
        vm.warp(m.settleStart() + 1 days); // 自动按成本价挂单
        uint256 cost = m.machine(0).cost;
        machineBeacon.upgradeTo(address(0xBAD));
        vm.prank(buyer);
        vm.expectRevert(MonthBoard.UpgradeSentinelTripped.selector);
        sales.buyMachine(address(m), 0, type(uint256).max);
        factory.noteSentinel();
        uint256 since = factory.sentinelSince();
        assertEq(since, block.timestamp);
        vm.warp(since + 30 days - 1);
        assertTrue(m.sentinelPaused());
        vm.prank(buyer);
        vm.expectRevert(MonthBoard.UpgradeSentinelTripped.selector);
        sales.buyMachine(address(m), 0, type(uint256).max);
        vm.warp(since + 30 days);
        assertTrue(m.sentinelTripped());
        assertFalse(m.sentinelPaused());
        _buy(0);
        assertEq(saleProceeds, cost);
    }

    /// @dev RIG 的产出付给 BSC 上发起收取那一刻的持有人。购买 / 交接前要求这台 RIG 1 天内同步过，
    ///      否则主板持有期间累积、还没收取的产出会被买家带走；任何人先在 BSC 金库上发起收取即可
    function test_SaleAndRelayRequireRecentRigSync() public {
        _settle(false);
        vm.warp(m.settleStart() + 1 days + 1); // 成本价已锁定；上次同步在 1 天多以前
        assertEq(sales.askPrice(address(m), 1), m.machine(1).cost);
        assertFalse(sales.syncFresh(address(m), 1));
        vm.prank(buyer);
        vm.expectRevert(MonthMachineSales.SyncTooOld.selector);
        sales.buyMachine(address(m), 1, type(uint256).max);
        MonthBoard r = _freshPreparing();
        vm.expectRevert(MonthMachineSales.SyncTooOld.selector);
        sales.relay(address(m), 0, address(r));
        // 发起收取：之前累积的产出先到主板（按投入比例归本局持仓），同步时间刷新后才能买
        uint256 owedBefore = m.owed(1);
        _yieldMonth(m, 5 * BEM_1);
        assertTrue(sales.syncFresh(address(m), 1));
        vm.prank(buyer);
        sales.buyMachine(address(m), 1, type(uint256).max);
        assertEq(machines.ownerOf(m.machine(1).circuitId), buyer);
        assertGt(m.owed(1), owedBefore, "accrued yield stayed with the board's positions");
        assertEq(m.yieldReceived() >= 5 * BEM_1, true);
    }

    function test_RelayOnlyWhatReceiverBudgetCovers() public {
        _settle(false);
        MonthBoard r = _freshPreparing();
        vm.warp(block.timestamp + 60 hours); // 接手方收购价到上限（不低于两台的成本价）
        _feedDefault();
        // 先用拍卖买一台，让剩余预算介于两台待接力矿机的成交额之间
        uint256 c1 = r.buyPrice() * m.machine(1).weight;
        uint256 c2 = r.buyPrice() * m.machine(2).weight;
        assertGe(c1, m.machine(1).cost);
        assertGe(c2, m.machine(2).cost);
        assertLt(c1, c2);
        (uint256 id,) = _newMachine(address(this), 10);
        uint256 w = (r.budget() - (c1 + c2) / 2) / r.buyPriceCap();
        machines.sync(id, w, uint64(block.timestamp + 1));
        vm.warp(block.timestamp + 1);
        machines.approve(address(r), id);
        r.sellMachine(address(machines), id, 0);
        assertGe(r.budget(), c1);
        assertLt(r.budget(), c2);
        _syncRigs(m);
        vm.expectRevert(MonthBoard.InsufficientBudget.selector);
        sales.relay(address(m), 2, address(r)); // 40 权重的那台接不下
        _relay(1, r); // 20 权重的可以
        assertTrue(m.machine(1).sold);
        assertFalse(m.machine(2).sold);
    }

    function test_RelayOnlyBetweenMonthBoardsInPreparation() public {
        _settle(false);
        address outsider = address(0xBADB0A);
        vm.expectRevert(MonthBoard.NotMonthBoard.selector);
        sales.relay(address(m), 0, outsider); // 非本工厂创建的地址
        vm.expectRevert(MonthBoard.NotMonthBoard.selector);
        sales.relay(address(m), 0, address(m));
        MonthBoard r = _freshPreparing();
        vm.warp(r.prepEnd()); // 接手方准备期已过
        _syncRigs(m);
        vm.expectRevert(MonthBoard.BuyRoundInactive.selector);
        sales.relay(address(m), 0, address(r));
        // 外人不能绕过卖矿单例直接交接 / 交割
        vm.expectRevert(MonthBoard.NotAuthorized.selector);
        m.relayOut(0, address(r));
        vm.expectRevert(MonthBoard.NotAuthorized.selector);
        m.releaseMachine(0, address(this), 0);
        // 只收本局 RIG 合约的凭证
        vm.expectRevert(MonthBoard.MachineNotEligible.selector);
        r.sellMachine(address(passCircuits), 1, 0);
    }

    // ---------------- 卖价：同 BSC 的公式，不低于成本价；报价过期暂停，停运按成本价 ----------------

    /// @dev 卖价 = max(收购时算力 × max(买一, 卖一 × (99% − 0.5% × 结算开始后整 6 小时数)), 成本价)
    function test_SalePriceFollowsBscFormulaNeverBelowCost() public {
        _settle(false);
        uint256 w = m.machine(0).weight;
        uint256 cost = m.machine(0).cost;
        _feedDefault();
        assertEq(sales.askPrice(address(m), 0), w * (FEED_ASK * 9_900 / 10_000), "starts at ask x 99%");
        vm.warp(m.settleStart() + 60 hours); // 10 个 6 小时：99% − 5%
        _feedDefault();
        assertEq(sales.askPrice(address(m), 0), w * (FEED_ASK * 9_400 / 10_000));
        // 买一托底：公式降到买一以下时按买一
        _forcePrices(FEED_ASK * 95 / 100, FEED_ASK);
        assertEq(sales.askPrice(address(m), 0), w * (FEED_ASK * 95 / 100));
        // 市价低于成本价：按成本价
        _feedAtCost();
        assertEq(sales.askPrice(address(m), 0), cost, "never below cost");
        _syncRigs(m);
        vm.prank(buyer);
        vm.expectRevert(MonthMachineSales.PriceAboveMaximum.selector);
        sales.buyMachine(address(m), 0, cost - 1);
        _buy(0);
        assertEq(saleProceeds, cost);
    }

    /// @dev 报价过期 / 追价中 / 运营地址为 0：暂停卖出；7 天没有有效报价（停运）：任何人按成本价可买（同 BSC）
    function test_SalesPauseWhenFeedStaleAndCostWhenAbandoned() public {
        _settle(false);
        uint256 cost = m.machine(1).cost;
        _feedDefault();
        assertGt(sales.askPrice(address(m), 1), cost);
        vm.warp(block.timestamp + 3 hours);
        assertFalse(priceFeed.fresh());
        assertEq(sales.askPrice(address(m), 1), 0, "stale feed: sales paused");
        _syncRigs(m);
        vm.prank(buyer);
        vm.expectRevert(MonthMachineSales.NotForSale.selector);
        sales.buyMachine(address(m), 1, type(uint256).max);
        vm.warp(priceFeed.liveAt() + 7 days);
        assertTrue(priceFeed.abandoned());
        assertEq(sales.askPrice(address(m), 1), cost, "abandoned feed: cost price");
        _buy(1);
        assertEq(saleProceeds, cost);
    }

    function test_SaleAtFormulaPremiumRefundsPrincipalAndSharesPremium() public {
        _settle(false);
        uint256 cost = m.machine(0).cost;
        _feedDefault();
        uint256 price = sales.askPrice(address(m), 0);
        assertGt(price, cost);
        uint256 allBefore = _totalOwedToPlayers();
        uint256 fee0 = bem.balanceOf(FEE_SAFE);
        _buy(0);
        assertEq(saleProceeds, price);
        assertEq(machines.ownerOf(m.machine(0).circuitId), buyer);
        // 溢价分成：超出成本的部分收 10% 给手续费地址；其余（本金 + 90% 溢价）按投入比例归参与者
        uint256 fee = (price - cost) / 10;
        assertEq(bem.balanceOf(FEE_SAFE) - fee0, fee, "10% of the premium");
        assertApproxEqAbs(_totalOwedToPlayers() - allBefore, price - fee, players.length);
    }

    function test_UnsoldMachineKeepsMiningAndOperatorPushesYield() public {
        _settle(false);
        vm.warp(m.settleStart() + 1 days); // 都已按成本价挂单，但没人买
        uint256 foundationBefore = bem.balanceOf(FOUNDATION);
        uint256 feeBefore = bem.balanceOf(FEE_SAFE);
        sales.distribute(address(m), 1, players.length); // 先把未花完的本金发掉
        uint256 sum0 = _sumBalances();
        _yieldAll(6 * BEM_1);
        m.harvest();
        sales.distribute(address(m), 1, players.length);
        assertApproxEqAbs(_sumBalances() - sum0, 6 * BEM_1, players.length, "yield pushed pro rata");
        assertEq(bem.balanceOf(FOUNDATION), foundationBefore, "no 3% on post-draw yield");
        assertEq(bem.balanceOf(FEE_SAFE), feeBefore, "no 2% on post-draw yield");
        assertEq(m.finishedAt(), 0, "claim window not started while machines unsold");
    }

    function test_RevokedMachineIsNotSoldBelowCost() public {
        _settle(false);
        machines.sync(m.machine(0).circuitId, 0, uint64(block.timestamp + 1));
        vm.warp(block.timestamp + 1);
        vm.warp(m.settleStart() + 1 days);
        assertEq(sales.askPrice(address(m), 0), m.machine(0).cost, "still priced at cost");
        _buy(1);
        _buy(2);
        assertGt(m.principalRemaining(), 0, "principal of the revoked machine is delayed");
        assertEq(m.unsoldMachines(), 1);
    }

    // ---------------- 回馈资本滚入下一块月局 ----------------

    function test_SubsidyCapitalRollsIntoNextMonthBoard() public {
        _settle(true);
        uint256 subsidy = m.subsidyCapital();
        vm.warp(m.settleStart() + 1 days); // 自动按成本价挂单
        _buy(0);
        _buy(1);
        _buy(2);
        assertEq(m.principalRemaining(), 0);
        assertEq(m.subsidyRemaining(), 0);
        assertEq(m.rolledOver(), subsidy, "subsidy capital returned to the month factory");
        assertEq(bem.balanceOf(address(monthFactory)), subsidy);
        // 参与者拿回本金，外加奖金池按比例分的一半（抽奖的一半已经直接推送）
        uint256 drawn;
        for (uint256 i = 0; i < 5; i++) {
            drawn += m.prizeAmounts(i);
        }
        uint256 sharedHalf = drawn; // 奖金池为偶数时两半相等；为奇数时按比例的一半多 1 个最小单位
        assertApproxEqAbs(_totalOwedToPlayers(), m.totalStake() + sharedHalf, players.length + 1);

        MonthBoard r = _freshPreparing();
        assertEq(r.subsidyCapital(), subsidy, "rolled into the next month board");
        assertEq(r.budget(), r.totalStake() + subsidy);
        assertEq(bem.balanceOf(address(monthFactory)), 0);
    }

    // ---------------- 自动发放与自领 ----------------

    function test_DistributeAndSelfClaimNeverDoublePay() public {
        _settle(false);
        vm.warp(m.settleStart() + 1 days);
        _buy(0);
        _buy(1);
        _buy(2);
        uint256 n = players.length;
        uint256[] memory owedBefore = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            owedBefore[i] = _mOwed(m, players[i]);
        }
        _mClaimAll(m, players[0]); // 1 号先自领
        vm.prank(players[1]); // 参与者在 3 天内不能代替运营地址分发
        vm.expectRevert(MonthMachineSales.NotAuthorized.selector);
        sales.distribute(address(m), 1, n);
        vm.prank(buyer);
        vm.expectRevert(MonthMachineSales.NotAuthorized.selector);
        sales.distribute(address(m), 1, n);
        sales.distribute(address(m), 1, 10); // 分批
        sales.distribute(address(m), 11, n);
        sales.distribute(address(m), 1, n); // 重复调用不会重复支付
        for (uint256 i = 0; i < n; i++) {
            assertEq(_mOwed(m, players[i]), 0);
            assertEq(passCircuits.ownerOf(m.socket(i + 1).passId), players[i], "pass returned");
        }
        uint256 claimedAgain = _mClaimAll(m, players[2]);
        assertEq(claimedAgain, 0);
        assertLe(bem.balanceOf(address(m)), n + 2, "dust only");
        assertGe(owedBefore[0], m.socket(1).stake, "principal fully returned");
    }

    // ---------------- 资金守恒 ----------------

    function test_MonthBoardConservesFunds() public {
        uint256 f0 = bem.balanceOf(FOUNDATION);
        uint256 fee0 = bem.balanceOf(FEE_SAFE);
        _settle(true);
        MonthBoard r = _freshPreparing();
        _relay(0, r); // 交接 1 台
        _feedDefault(); // 按卖价公式（高于成本价）卖 1 台
        _buy(1);
        vm.warp(block.timestamp + 10 days); // 卖不出的那台继续挖 10 天，然后按成本价卖
        _yieldAll(3 * BEM_1);
        m.harvest();
        _feedAtCost();
        _buy(2);
        assertEq(m.unsoldMachines(), 0);
        sales.distribute(address(m), 1, 15);
        for (uint256 i = 0; i < players.length; i++) {
            _mClaimAll(m, players[i]); // 已经推送过的人这里拿到 0
            assertGe(
                bem.balanceOf(players[i]) - startBal[players[i]], m.socket(i + 1).stake, "principal fully returned"
            );
        }
        uint256 inflow = m.totalStake() + m.totalEntryFees() + deliveredYield[address(m)] + m.subsidyCapital()
            + saleProceeds + relayProceeds;
        uint256 paidOut = _sumGains() + (bem.balanceOf(FOUNDATION) - f0)
            + (bem.balanceOf(FEE_SAFE) - fee0 - (r.miningStart() > 0 ? r.totalEntryFees() : 0)) + m.totalSpent()
            + m.rolledOver(); // 接手方的入场费到它开始挖矿时才转出
        uint256 bal = bem.balanceOf(address(m));
        assertEq(inflow, paidOut + bal, "inflow == paid out + balance");
        assertEq(m.liabilities(), bal);
        assertLe(bal, players.length + 10, "dust only");
        assertEq(m.principalRemaining(), 0);
        assertEq(m.subsidyRemaining(), 0);
        assertEq(m.rolledOver(), m.subsidyCapital());
    }

    // ---------------- 辅助 ----------------

    function _sumBalances() internal view returns (uint256 t) {
        for (uint256 i = 0; i < players.length; i++) {
            t += bem.balanceOf(players[i]);
        }
    }

    /// @dev 参与者从本局拿到的全部 BEM（奖金推送 + 发放 + 自领）
    function _sumGains() internal view returns (uint256 t) {
        for (uint256 i = 0; i < players.length; i++) {
            t += bem.balanceOf(players[i]) - startBal[players[i]];
        }
    }

    function _totalOwedToPlayers() internal view returns (uint256 t) {
        for (uint256 i = 0; i < players.length; i++) {
            t += _mOwed(m, players[i]);
        }
    }

    function _yieldAll(uint256 amount) internal {
        _yieldMonth(m, amount);
    }
}
