// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {XMonthBoard as MonthBoard} from "../src/XMonthBoard.sol";
import {MonthState} from "../src/interfaces/IXMonthBoard.sol";

/// @notice X Layer 移植 v2 时的规则（V2-PORT.md）：清算计划价下限 = 转报的 BSC 买一 × 算力 × 95%（报价无效暂停、停运按成本价）、
///         买满提前开挖、任何 RIG 持有人都能卖。
contract XV2RulesTest is Fixture {
    MonthBoard internal m;
    address[] internal users;
    address internal buyer = address(0xB0B);

    function setUp() public override {
        super.setUp();
        _startGenesis();
        m = _monthBoard();
    }

    function _settled(uint256 yieldAmount) internal {
        users = _fillMonth(m);
        _sellMonth(m, _newUser(), 30);
        _sellMonth(m, _newUser(), 20);
        _sellMonth(m, _newUser(), 40);
        vm.warp(m.prepEnd());
        m.sync();
        if (yieldAmount != 0) _yieldMonth(m, yieldAmount);
        vm.warp(m.miningEnd());
        m.drawPrizes();
        if (m.state() == MonthState.Drawing) {
            rng.fulfill(m.pendingRequestId(), 5);
            m.finalizePrizes();
        }
        assertEq(uint256(m.state()), uint256(MonthState.Settling));
        bem.mint(buyer, 10_000 * BEM_1);
        vm.prank(buyer);
        bem.approve(address(sales), type(uint256).max);
    }

    function _slots(uint256 from, uint256 count) internal pure returns (uint256[] memory s) {
        s = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            s[i] = from + i;
        }
    }

    /// @dev 全部未卖矿机：起价 = 成本价，底价 = 1（最小单位），多数通过并执行
    function _executeDumpPlan() internal {
        uint256 n = m.unsoldMachines();
        uint256[] memory idx = new uint256[](n);
        uint128[] memory st = new uint128[](n);
        uint128[] memory fl = new uint128[](n);
        for (uint256 i = 0; i < n; i++) {
            idx[i] = i;
            st[i] = m.machine(i).cost;
            fl[i] = 1;
        }
        bytes32 h = governor.publishPlan(address(m), idx, st, fl);
        vm.warp(m.settleStart() + 7 days);
        for (uint256 i = 1; i <= 13; i++) {
            vm.prank(m.socket(i).owner);
            governor.support(address(m), _slots(i, 1), h);
        }
        governor.openVote(address(m), h, _slots(1, 3));
        uint8 yes = governor.YES(); // 先读出来：vm.prank 只作用于下一次外部调用
        for (uint256 i = 1; i <= 13; i++) {
            vm.prank(m.socket(i).owner);
            governor.castVote(address(m), _slots(i, 1), yes);
        }
        vm.warp(block.timestamp + 24 hours);
        governor.finalizeVote(address(m));
        vm.warp(block.timestamp + 24 hours);
        governor.execute(address(m));
        assertTrue(m.liquidating());
    }

    /// @dev 让第 index 台的 买一 × 算力 约等于成本价 × bps（每单位算力，向上取整）
    function _unitFor(uint256 index, uint256 bps) internal view returns (uint256) {
        uint256 w = m.machine(index).weight;
        return (uint256(m.machine(index).cost) * bps / 10_000 + w - 1) / w;
    }

    /// @dev 多数票能止损，不能低于市价甩卖给自己（同 BSC 版规则决定 6.33）：起价 = 成本、底价 = 1 的计划，
    ///      成交价仍不低于转报的 BSC 买一 × 算力 × 95%，可以低于成本价
    function test_PlanPriceNeverBelowBscBidTimes95() public {
        _settled(9 * BEM_1);
        uint256 unit = _unitFor(0, 4_000); // 行情低迷：买一 × 算力 ≈ 成本价的 40%
        _postPrices(unit, unit * 2);
        _executeDumpPlan();
        vm.warp(block.timestamp + 30 days); // 计划曲线早已降到底价 1
        _postPrices(unit, unit * 2);
        for (uint256 i = 0; i < m.machineCount(); i++) {
            uint256 lo = unit * m.machine(i).weight * 9_500 / 10_000;
            assertEq(sales.planMinPrice(m.machine(i).weight), lo);
            assertEq(sales.askPrice(address(m), i), lo < m.machine(i).cost ? lo : m.machine(i).cost, "clamped to bid x 95%");
        }
        uint256 lo0 = unit * m.machine(0).weight * 9_500 / 10_000;
        assertLt(lo0, m.machine(0).cost, "the floor still allows a below-cost exit");
        uint256 principal0 = m.principalRemaining();
        _syncRigs(m);
        vm.prank(buyer);
        uint256 paid = sales.buyMachine(address(m), 0, type(uint256).max);
        assertEq(paid, lo0);
        assertEq(m.principalRemaining(), principal0 - paid, "below-cost proceeds refund principal first");
        // 买一回升 5%：下限跟着买一走
        _postPrices(unit * 105 / 100, unit * 2);
        assertEq(sales.askPrice(address(m), 1), unit * 105 / 100 * m.machine(1).weight * 9_500 / 10_000);
    }

    /// @dev 报价过期 / 追价中 / 运营地址为 0：计划价和正常卖价都暂停（同 BSC）；恢复有效报价后照常
    function test_PlanPausedWhileFeedNotFresh() public {
        _settled(9 * BEM_1);
        uint256 unit = _unitFor(0, 4_000);
        _postPrices(unit, unit);
        _executeDumpPlan();
        vm.warp(block.timestamp + 30 days);
        _postPrices(unit, unit);
        uint256 cost0 = m.machine(0).cost;
        uint256 lo = unit * m.machine(0).weight * 9_500 / 10_000;
        assertEq(sales.askPrice(address(m), 0), lo);
        // 过期（3 小时没更新）
        vm.warp(priceFeed.updatedAt() + 3 hours);
        assertEq(sales.planMinPrice(m.machine(0).weight), 0);
        assertEq(sales.askPrice(address(m), 0), 0, "stale: sales paused");
        assertLt(lo, cost0, "the plan allows a below-cost exit once the feed is live");
        // 追价中（BSC 那边在追价，或这里落后超过 5%）
        priceFeed.postCatchUp(unit * 96 / 100, unit * 96 / 100, block.number);
        assertEq(sales.askPrice(address(m), 0), 0, "catching up: sales paused");
        vm.warp(priceFeed.updatedAt() + 50 minutes);
        priceFeed.post(unit, unit, block.number);
        assertEq(sales.askPrice(address(m), 0), lo, "live again");
        // 运营地址为 0：暂停（不算停运）
        vm.prank(FEE_SAFE);
        factory.setOperator(address(0));
        assertFalse(priceFeed.abandoned());
        assertEq(sales.askPrice(address(m), 0), 0, "no operator: sales paused");
    }

    /// @dev 报价停运（从没报过，或 7 天没有有效报价，一直追价也算）：计划价不再用，按成本价卖（同 BSC 版的兜底）
    function test_AbandonedFeedFallsBackToCost() public {
        _settled(9 * BEM_1);
        _executeDumpPlan();
        vm.warp(block.timestamp + 30 days);
        assertTrue(priceFeed.abandoned(), "no live post for 7 days");
        uint256 cost0 = m.machine(0).cost;
        assertEq(sales.askPrice(address(m), 0), cost0, "abandoned: cost price");
        // 有效报价一次后恢复计划价；之后一直追价，最后一次有效报价满 7 天又停运
        uint256 unit = _unitFor(0, 4_000);
        _postPrices(unit, unit);
        uint256 live = priceFeed.liveAt();
        assertLt(sales.askPrice(address(m), 0), cost0);
        bool down = true;
        while (block.timestamp < live + 7 days) {
            vm.warp(priceFeed.updatedAt() + 50 minutes);
            uint256 q = down ? unit * 9_800 / 10_000 : unit;
            priceFeed.postCatchUp(q, q, block.number);
            down = !down;
            if (block.timestamp < live + 7 days) assertEq(sales.askPrice(address(m), 0), 0, "catching up: paused");
        }
        assertTrue(priceFeed.abandoned(), "abandoned 7 days after the last live post");
        assertEq(sales.askPrice(address(m), 0), cost0, "cost-price fallback");
        _syncRigs(m);
        vm.prank(buyer);
        assertEq(sales.buyMachine(address(m), 0, type(uint256).max), cost0);
    }

    /// @dev 计划价不会把价格抬到正常卖价之上（同 BSC：取较低者）。买一 × 算力 ≈ 成本价的 2 倍时，
    ///      正常卖价 = 买一 × 算力，计划价下限 = 买一 × 算力 × 95%，成交价取后者
    function test_PlanNeverRaisesThePrice() public {
        _settled(9 * BEM_1);
        uint256 unit = _unitFor(0, 20_000);
        _postPrices(unit, unit);
        _executeDumpPlan();
        _postPrices(unit, unit);
        uint256 w = m.machine(0).weight;
        uint256 normal = unit * w; // max(买一, 卖一 × 99% …) = 买一（买一 = 卖一）
        assertEq(sales.askPrice(address(m), 0), unit * w * 9_500 / 10_000);
        assertLe(sales.askPrice(address(m), 0), normal);
    }

    /// @dev 买满提前开挖（BSC 规则决定 6.37）：剩余预算按当前收购价连一台最小算力（10）都买不下时，立即开始 30 天挖矿
    function test_BoughtOutStartsMiningImmediately() public {
        _fillMonth(m);
        uint256 price = m.buyPrice(); // 上限 × 50%
        _sellMonth(m, _newUser(), 100);
        assertEq(uint256(m.state()), uint256(MonthState.Preparing), "budget still covers a 10-weight rig");
        assertGe(m.budget(), price * 10);
        uint256 w = (m.budget() - price * 10) / price + 1; // 买下这台后剩余预算不够 10 算力
        _sellMonth(m, _newUser(), w);
        assertLt(m.budget(), price * 10);
        assertEq(uint256(m.state()), uint256(MonthState.Mining), "bought out: mining starts now");
        assertEq(m.prepEnd(), block.timestamp);
        assertEq(m.miningStart(), block.timestamp);
        assertEq(m.miningEnd(), block.timestamp + 30 days);
        (uint256 id,) = _newMachine(address(this), 10);
        machines.approve(address(m), id);
        vm.expectRevert(MonthBoard.BuyRoundInactive.selector);
        m.sellMachine(address(machines), id, 0);
    }

    /// @dev X Layer 没有 MarketTrader：任何 RIG 持有人都能按当前收购价卖给准备中的月局，但只收本局 RIG 合约的凭证
    function test_AnyRigHolderSellsAtAuctionPrice() public {
        _fillMonth(m);
        vm.warp(block.timestamp + 12 hours); // 收购价 50% → 60%
        _feedDefault(); // 收购要有效报价（同 BSC）
        address seller = _newUser();
        (uint256 id,) = _newMachine(seller, 25);
        uint256 price = m.buyPrice();
        assertEq(price, m.buyPriceCap() * 6_000 / 10_000);
        vm.startPrank(seller);
        machines.approve(address(m), id);
        vm.expectRevert(MonthBoard.PriceBelowMinimum.selector);
        m.sellMachine(address(machines), id, price + 1); // 卖家要求的最低单价高于现价
        uint256 paid = m.sellMachine(address(machines), id, price);
        vm.stopPrank();
        assertEq(paid, 25 * price);
        assertEq(bem.balanceOf(seller), paid);
        assertEq(m.machine(0).collection, address(machines));
        assertEq(m.machine(0).key, bytes32(0));
    }
}
