// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// 从 BSC v2.0-audit.6 contracts/test/PositionExchange.t.sol 移植（V2-PORT.md）：产出改为模拟跨链到账（_yieldMonth），其余用例不变。

import {Fixture} from "./utils/Fixture.sol";
import {XMonthBoard as MonthBoard} from "../src/XMonthBoard.sol";
import {XPositionExchange as PositionExchange} from "../src/month/XPositionExchange.sol";
import {MonthState} from "../src/interfaces/IXMonthBoard.sol";

/// @title v2 持仓挂单簿（规则决定第 6.2 / 6.5 节，第 6 阶段）
contract PositionExchangeTest is Fixture {
    address internal seller = address(0x5E11E4);
    address internal small = address(0x5A11); // 小份持仓（minStake）
    address internal taker = address(0x7A4E4);
    address internal other = address(0x0711E4);
    address internal buyer = address(0xB0B);
    MonthBoard internal m;
    uint256 internal slot; // seller 的持仓（maxStake）
    uint256 internal smallSlot;
    uint256 internal constant U = 1e8; // 每 1 BEM 本金

    function setUp() public override {
        super.setUp();
        _startGenesis();
        m = _monthBoard();
        slot = _joinAs(seller, m.maxStake());
        smallSlot = _joinAs(small, m.minStake());
        _fillMonth(m);
        _sellMonth(m, _newUser(), 30);
        _sellMonth(m, _newUser(), 20);
        vm.warp(m.prepEnd());
        m.sync();
        _yieldMonth(m, 3 * BEM_1);
        vm.warp(m.miningEnd());
        m.drawPrizes();
        rng.fulfill(m.pendingRequestId(), 42);
        m.finalizePrizes();
        assertEq(uint256(m.state()), uint256(MonthState.Settling));
        address[5] memory all = [seller, small, taker, other, buyer];
        for (uint256 i = 0; i < all.length; i++) {
            bem.mint(all[i], 1_000 * BEM_1);
            vm.startPrank(all[i]);
            bem.approve(address(exchange), type(uint256).max);
            positions.setApprovalForAll(address(exchange), true);
            vm.stopPrank();
        }
    }

    function _joinAs(address user, uint256 amount) internal returns (uint256 s) {
        uint256 passId = _mintPass(user);
        bem.mint(user, amount * 2);
        vm.startPrank(user);
        passCircuits.approve(address(m), passId);
        bem.approve(address(m), type(uint256).max);
        m.join(passId, amount);
        vm.stopPrank();
        s = m.socketCount();
    }

    /// @dev 不发外部调用（放在 vm.prank 之后的参数里也不会吃掉 prank）
    function _id(uint256 s) internal view returns (uint256) {
        return (uint256(uint160(address(m))) << 96) | s;
    }

    function _list(address who, uint256 s, uint256 unitPrice) internal {
        vm.prank(who);
        exchange.listAsk(address(m), s, unitPrice, uint64(block.timestamp + 1 days));
    }

    function _bid(address who, uint256 unitPrice, uint256 budget, uint256 minS, uint256 maxS)
        internal
        returns (uint256 id)
    {
        vm.prank(who);
        id = exchange.placeBid(address(m), unitPrice, budget, minS, maxS, uint64(block.timestamp + 1 days));
    }

    function _stake(uint256 s) internal view returns (uint256) {
        return m.socket(s).stake;
    }

    // ---------------- 报价 ----------------

    function test_QuoteRoundsUpAndIsPositive() public view {
        assertEq(exchange.quote(1, 1), 1);
        assertEq(exchange.quote(20 * BEM_1, U), 20 * BEM_1, "par");
        assertEq(exchange.quote(20 * BEM_1, U / 2), 10 * BEM_1, "50%");
        assertEq(exchange.quote(3, U / 3), 1, "3 x 33333333 / 1e8 = 0.99999999 -> 1");
        assertEq(exchange.quote(1e8 + 1, 1), 2);
    }

    // ---------------- 卖单 ----------------

    function test_ListAndBuyAskPaysSellerDirectly() public {
        _list(seller, slot, 9 * U / 10); // 本金的 90%
        uint256 cost = exchange.quote(_stake(slot), 9 * U / 10);
        uint256 s0 = bem.balanceOf(seller);
        uint256 t0 = bem.balanceOf(taker);
        vm.prank(taker);
        assertEq(exchange.buyAsk(address(m), slot, 9 * U / 10), cost);
        assertEq(positions.ownerOf(_id(slot)), taker);
        assertEq(m.socket(slot).owner, taker);
        assertEq(bem.balanceOf(seller) - s0, cost, "seller paid directly");
        assertEq(t0 - bem.balanceOf(taker), cost);
        assertEq(bem.balanceOf(address(exchange)), 0);
        assertEq(exchange.askCount(address(m)), 0, "filled ask removed");
        assertGt(m.credit(seller), 0, "seller's accrued share stays with the seller on the board");
        PositionExchange.Trade[] memory t = exchange.recentTrades(address(m));
        assertEq(t.length, 1);
        assertEq(t[0].unitPrice, 9 * U / 10);
        assertEq(t[0].stake, _stake(slot));
        assertEq(t[0].slot, slot);
    }

    function test_RelistChangesPriceAndFrontRunGuard() public {
        _list(seller, slot, U);
        _list(seller, slot, 2 * U); // 改价：同一份持仓仍只有一张卖单
        assertEq(exchange.askCount(address(m)), 1);
        assertEq(exchange.ask(address(m), slot).unitPrice, 2 * U);
        vm.prank(taker);
        vm.expectRevert(PositionExchange.PriceAbove.selector);
        exchange.buyAsk(address(m), slot, U);
        vm.prank(seller);
        vm.expectRevert(PositionExchange.SelfTrade.selector);
        exchange.buyAsk(address(m), slot, 2 * U);
    }

    function test_CancelAsk() public {
        _list(seller, slot, U);
        vm.prank(other);
        vm.expectRevert(PositionExchange.NotOwner.selector);
        exchange.cancelAsk(address(m), slot);
        vm.prank(seller);
        exchange.cancelAsk(address(m), slot);
        assertEq(exchange.askCount(address(m)), 0);
        vm.prank(taker);
        vm.expectRevert(PositionExchange.NoAsk.selector);
        exchange.buyAsk(address(m), slot, U);
        vm.prank(seller);
        vm.expectRevert(PositionExchange.NoAsk.selector);
        exchange.cancelAsk(address(m), slot);
    }

    function test_ListRejections() public {
        vm.startPrank(other);
        vm.expectRevert(PositionExchange.NotOwner.selector);
        exchange.listAsk(address(m), slot, U, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        vm.startPrank(seller);
        vm.expectRevert(PositionExchange.ZeroPrice.selector);
        exchange.listAsk(address(m), slot, 0, uint64(block.timestamp + 1 days));
        vm.expectRevert(PositionExchange.BadDeadline.selector);
        exchange.listAsk(address(m), slot, U, uint64(block.timestamp));
        vm.expectRevert(PositionExchange.BadDeadline.selector);
        exchange.listAsk(address(m), slot, U, uint64(block.timestamp + 30 days + 1));
        exchange.listAsk(address(m), slot, U, uint64(block.timestamp + 30 days)); // 恰好 30 天可以
        vm.expectRevert(PositionExchange.NotMonthBoard.selector);
        exchange.listAsk(address(0xBAD), slot, U, uint64(block.timestamp + 1 days));
        positions.setApprovalForAll(address(exchange), false);
        vm.expectRevert(PositionExchange.NotApproved.selector);
        exchange.listAsk(address(m), slot, U, uint64(block.timestamp + 1 days));
        positions.approve(address(exchange), _id(slot)); // 单份授权也可以
        exchange.listAsk(address(m), slot, U, uint64(block.timestamp + 1 days));
        vm.stopPrank();
    }

    function test_AskExpiresAndApprovalRevokeInvalidates() public {
        _list(seller, slot, U);
        assertTrue(exchange.askValid(address(m), slot));
        vm.prank(seller);
        positions.setApprovalForAll(address(exchange), false);
        assertFalse(exchange.askValid(address(m), slot), "no approval -> not shown");
        vm.prank(seller);
        positions.setApprovalForAll(address(exchange), true);
        assertTrue(exchange.askValid(address(m), slot));
        vm.warp(block.timestamp + 1 days);
        assertFalse(exchange.askValid(address(m), slot), "expired");
        vm.prank(taker);
        vm.expectRevert(PositionExchange.AskNotValid.selector);
        exchange.buyAsk(address(m), slot, U);
    }

    /// @dev 持仓转走（再转回来）、卖出一台矿机、治理锁：卖单都自动失效；任何人可以清理；新持有人可以覆盖
    function test_AskInvalidAfterPositionChanges() public {
        _list(seller, slot, U);
        vm.prank(seller);
        positions.transferFrom(seller, other, _id(slot));
        vm.prank(other);
        positions.transferFrom(other, seller, _id(slot));
        assertFalse(exchange.askValid(address(m), slot), "version bumped by the round trip");
        vm.prank(taker);
        vm.expectRevert(PositionExchange.AskNotValid.selector);
        exchange.buyAsk(address(m), slot, U);
        uint256[] memory s = new uint256[](1);
        s[0] = slot;
        vm.prank(other);
        exchange.pruneAsks(address(m), s);
        assertEq(exchange.askCount(address(m)), 0, "anyone prunes a dead ask");

        _list(seller, slot, U);
        vm.warp(m.settleStart() + 1 days);
        _syncRigs(m);
        vm.startPrank(buyer);
        bem.approve(address(sales), type(uint256).max);
        sales.buyMachine(address(m), 0, type(uint256).max); // 卖出一台：局交易版本号 +1
        vm.stopPrank();
        assertFalse(exchange.askValid(address(m), slot), "machine sale bumps the trade epoch");
        exchange.pruneAsks(address(m), s);

        _list(seller, slot, U);
        vm.prank(seller);
        positions.transferFrom(seller, other, _id(slot));
        _list(other, slot, 2 * U); // 新持有人覆盖旧记录
        assertEq(exchange.askCount(address(m)), 1);
        assertEq(exchange.ask(address(m), slot).maker, other);
        assertTrue(exchange.askValid(address(m), slot));
    }

    // ---------------- 盘口 ----------------

    function test_BookSortedFilteredAndPaged() public {
        uint256 n = m.socketCount();
        uint256[] memory prices = new uint256[](5);
        prices[0] = 95;
        prices[1] = 80;
        prices[2] = 120;
        prices[3] = 80;
        prices[4] = 101;
        // 插槽 3..7 各挂一张卖单（不按价格顺序）
        for (uint256 i = 0; i < 5; i++) {
            uint256 s = 3 + i;
            address o = m.socket(s).owner;
            vm.prank(o);
            positions.setApprovalForAll(address(exchange), true);
            _list(o, s, prices[i] * U / 100);
        }
        // 插槽 8 挂单后转走：失效，不进盘口
        address o8 = m.socket(8).owner;
        vm.prank(o8);
        positions.setApprovalForAll(address(exchange), true);
        _list(o8, 8, U / 10);
        vm.prank(o8);
        positions.transferFrom(o8, other, _id(8));
        assertLe(8, n);
        assertEq(exchange.askCount(address(m)), 6);

        _bid(taker, 70 * U / 100, 50 * BEM_1, 0, type(uint256).max);
        _bid(other, 75 * U / 100, 50 * BEM_1, 0, type(uint256).max);
        uint256 b3 = _bid(buyer, 70 * U / 100, 50 * BEM_1, 0, type(uint256).max);
        _bid(taker, 60 * U / 100, 50 * BEM_1, 0, type(uint256).max);
        vm.prank(buyer);
        exchange.cancelBid(b3);

        (PositionExchange.AskView[] memory a, PositionExchange.BidView[] memory b) = exchange.book(address(m), 0);
        assertEq(a.length, 5, "dead ask filtered");
        uint256[5] memory wantSlots = [uint256(4), 6, 3, 7, 5]; // 80(4) 80(6) 95 101 120
        for (uint256 i = 0; i < 5; i++) {
            assertEq(a[i].slot, wantSlots[i]);
            assertTrue(a[i].valid);
            assertEq(a[i].cost, exchange.quote(a[i].stake, a[i].unitPrice));
        }
        assertEq(b.length, 3, "cancelled bid gone");
        assertEq(b[0].unitPrice, 75 * U / 100);
        assertEq(b[1].unitPrice, 70 * U / 100);
        assertEq(b[2].unitPrice, 60 * U / 100);
        (a, b) = exchange.book(address(m), 2);
        assertEq(a.length, 2);
        assertEq(b.length, 2);
        assertEq(a[1].slot, 6);

        PositionExchange.AskView[] memory p1 = exchange.asksOf(address(m), 0, 4);
        PositionExchange.AskView[] memory p2 = exchange.asksOf(address(m), 4, 4);
        assertEq(p1.length + p2.length, 6, "raw pages include the dead ask");
        assertEq(exchange.asksOf(address(m), 6, 4).length, 0);
        assertEq(exchange.bidsOf(address(m), 0, 0).length, 3);
    }

    // ---------------- 买单 ----------------

    function test_BidFillsSeveralUntilBudgetRunsOut() public {
        uint256 unit = 80 * U / 100;
        uint256 big = _stake(slot);
        uint256 cost = exchange.quote(big, unit);
        uint256 id = _bid(buyer, unit, cost * 2 + cost / 2, 0, type(uint256).max); // 够 2.5 份
        assertEq(bem.balanceOf(address(exchange)), cost * 2 + cost / 2);
        uint256 s0 = bem.balanceOf(seller);
        vm.prank(seller);
        exchange.sellToBid(id, slot, unit);
        assertEq(bem.balanceOf(seller) - s0, cost, "seller paid directly from escrow");
        assertEq(positions.ownerOf(_id(slot)), buyer);
        // 第二份
        address o3 = m.socket(3).owner;
        vm.startPrank(o3);
        positions.setApprovalForAll(address(exchange), true);
        exchange.sellToBid(id, 3, unit);
        vm.stopPrank();
        assertEq(exchange.bid(id).remaining, cost / 2);
        // 第三份大的买不起
        address o4 = m.socket(4).owner;
        vm.startPrank(o4);
        positions.setApprovalForAll(address(exchange), true);
        vm.expectRevert(PositionExchange.BudgetExceeded.selector);
        exchange.sellToBid(id, 4, unit);
        vm.stopPrank();
        // 小份（minStake）还买得起，买完剩余预算不够最小一份：自动关闭并退款
        uint256 smallCost = exchange.quote(_stake(smallSlot), unit);
        assertLe(smallCost, cost / 2);
        uint256 b0 = bem.balanceOf(buyer);
        vm.prank(small);
        exchange.sellToBid(id, smallSlot, unit);
        uint256 left = cost / 2 - smallCost;
        if (left < exchange.quote(1, unit)) {
            assertEq(exchange.bid(id).bidder, address(0), "auto-closed");
            assertEq(bem.balanceOf(buyer) - b0, left, "dust refunded directly");
        }
        assertEq(bem.balanceOf(address(exchange)), exchange.totalEscrow());
        assertEq(exchange.recentTrades(address(m)).length, 3);
    }

    function test_BidAutoClosesWhenBelowMinStakePrice() public {
        uint256 unit = U;
        uint256 c = exchange.quote(_stake(slot), unit);
        uint256 id = _bid(buyer, unit, c + c / 2, _stake(slot), _stake(slot)); // 只收 maxStake 大小，预算 1.5 份
        uint256 b0 = bem.balanceOf(buyer);
        vm.prank(seller);
        exchange.sellToBid(id, slot, unit);
        assertEq(exchange.bid(id).bidder, address(0), "remaining < one more position: closed");
        assertEq(bem.balanceOf(buyer) - b0, c / 2, "remainder refunded");
        assertEq(exchange.bidCount(address(m)), 0);
        assertEq(exchange.openBidsOf(address(m), buyer), 0);
        assertEq(bem.balanceOf(address(exchange)), 0);
    }

    function test_SellToBidRemovesSellersAsk() public {
        _list(seller, slot, 2 * U);
        uint256 id = _bid(buyer, U, 50 * BEM_1, 0, type(uint256).max);
        vm.prank(seller);
        exchange.sellToBid(id, slot, U);
        assertEq(exchange.askCount(address(m)), 0, "old ask of the sold position removed");
        assertEq(exchange.ask(address(m), slot).maker, address(0));
        PositionExchange.Trade[] memory t = exchange.recentTrades(address(m));
        assertEq(t[0].unitPrice, U);
    }

    function test_BidStakeRangeFilter() public {
        uint256 id = _bid(buyer, U, 100 * BEM_1, _stake(slot), type(uint256).max); // 只收大份
        vm.prank(small);
        vm.expectRevert(PositionExchange.StakeOutOfRange.selector);
        exchange.sellToBid(id, smallSlot, 0);
        uint256 id2 = _bid(buyer, U, 100 * BEM_1, 0, _stake(smallSlot)); // 只收小份
        vm.prank(seller);
        vm.expectRevert(PositionExchange.StakeOutOfRange.selector);
        exchange.sellToBid(id2, slot, 0);
        vm.prank(small);
        exchange.sellToBid(id2, smallSlot, 0);
        vm.prank(seller);
        exchange.sellToBid(id, slot, 0);
    }

    function test_BidRejectionsAndLimits() public {
        vm.startPrank(buyer);
        vm.expectRevert(PositionExchange.BudgetTooSmall.selector);
        exchange.placeBid(address(m), U, BEM_1 - 1, 0, type(uint256).max, uint64(block.timestamp + 1 days));
        vm.expectRevert(PositionExchange.BudgetTooSmall.selector); // 不够一份 minStake
        exchange.placeBid(address(m), U, 5 * BEM_1, 10 * BEM_1, 20 * BEM_1, uint64(block.timestamp + 1 days));
        vm.expectRevert(PositionExchange.BadStakeRange.selector);
        exchange.placeBid(address(m), U, 50 * BEM_1, 10 * BEM_1, 5 * BEM_1, uint64(block.timestamp + 1 days));
        vm.expectRevert(PositionExchange.ZeroPrice.selector);
        exchange.placeBid(address(m), 0, 50 * BEM_1, 0, type(uint256).max, uint64(block.timestamp + 1 days));
        vm.expectRevert(PositionExchange.BadDeadline.selector);
        exchange.placeBid(address(m), U, 50 * BEM_1, 0, type(uint256).max, uint64(block.timestamp + 31 days));
        uint256 first;
        for (uint256 i = 0; i < 20; i++) {
            uint256 id = exchange.placeBid(address(m), U, BEM_1, 0, type(uint256).max, uint64(block.timestamp + 1 days));
            if (i == 0) first = id;
        }
        vm.expectRevert(PositionExchange.TooManyBids.selector);
        exchange.placeBid(address(m), U, BEM_1, 0, type(uint256).max, uint64(block.timestamp + 1 days));
        exchange.cancelBid(first);
        exchange.placeBid(address(m), U, BEM_1, 0, type(uint256).max, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        assertEq(exchange.openBidsOf(address(m), buyer), 20);
        uint256 own = _bid(seller, U, 50 * BEM_1, 0, type(uint256).max);
        vm.prank(seller);
        vm.expectRevert(PositionExchange.SelfTrade.selector);
        exchange.sellToBid(own, slot, 0);
    }

    function test_CancelAndRefundBid() public {
        uint256 id = _bid(buyer, U, 30 * BEM_1, 0, type(uint256).max);
        vm.prank(other);
        vm.expectRevert(PositionExchange.NotBidder.selector);
        exchange.cancelBid(id);
        vm.prank(other);
        vm.expectRevert(PositionExchange.BidStillValid.selector);
        exchange.refundBid(id);
        vm.warp(block.timestamp + 1 days);
        assertFalse(exchange.bidValid(id));
        vm.prank(seller);
        vm.expectRevert(PositionExchange.BidExpired.selector);
        exchange.sellToBid(id, slot, 0);
        uint256 b0 = bem.balanceOf(buyer);
        vm.prank(other);
        exchange.refundBid(id); // 任何人帮忙退款，钱只退给买家
        assertEq(bem.balanceOf(buyer) - b0, 30 * BEM_1);
        vm.expectRevert(PositionExchange.BidClosedAlready.selector);
        exchange.refundBid(id);
        assertEq(bem.balanceOf(address(exchange)), 0);
    }

    // ---------------- 按最优价批量吃单 ----------------

    function _listSlots(uint256[] memory s, uint256[] memory pct) internal {
        for (uint256 i = 0; i < s.length; i++) {
            address o = m.socket(s[i]).owner;
            vm.prank(o);
            positions.setApprovalForAll(address(exchange), true);
            _list(o, s[i], pct[i] * U / 100);
        }
    }

    function test_BuyBestFillsCheapestFirstWithinCaps() public {
        uint256[] memory s = new uint256[](4);
        uint256[] memory pct = new uint256[](4);
        (s[0], s[1], s[2], s[3]) = (uint256(3), 4, 5, 6);
        (pct[0], pct[1], pct[2], pct[3]) = (uint256(95), 80, 120, 90);
        _listSlots(s, pct);
        // 价格上限 100%：只吃 80、90、95；传入顺序打乱也按价格从低到高
        uint256 c = exchange.quote(_stake(4), 80 * U / 100) + exchange.quote(_stake(6), 90 * U / 100);
        uint256 t0 = bem.balanceOf(taker);
        vm.prank(taker);
        (uint256 filled, uint256 spent) = exchange.buyBest(address(m), s, U, c); // 总额上限只够前两张
        assertEq(filled, 2);
        assertEq(spent, c);
        assertEq(t0 - bem.balanceOf(taker), c);
        assertEq(positions.ownerOf(_id(4)), taker);
        assertEq(positions.ownerOf(_id(6)), taker);
        assertTrue(exchange.askValid(address(m), 3), "95% left: over total cap");
        assertTrue(exchange.askValid(address(m), 5), "120% left: over unit cap");
        PositionExchange.Trade[] memory t = exchange.recentTrades(address(m));
        assertEq(t[0].unitPrice, 90 * U / 100, "newest = second fill");
        assertEq(t[1].unitPrice, 80 * U / 100);
    }

    function test_BuyBestSkipsDeadAsksAndRevertsWhenNothingFills() public {
        uint256[] memory s = new uint256[](3);
        uint256[] memory pct = new uint256[](3);
        (s[0], s[1], s[2]) = (uint256(3), 4, 5);
        (pct[0], pct[1], pct[2]) = (uint256(80), 85, 90);
        _listSlots(s, pct);
        vm.prank(other);
        exchange.buyAsk(address(m), 3, U); // 卖一被别人先买走
        address o5 = m.socket(5).owner;
        vm.prank(o5);
        positions.setApprovalForAll(address(exchange), false); // 卖三撤销授权
        vm.prank(taker);
        (uint256 filled,) = exchange.buyBest(address(m), s, U, type(uint256).max);
        assertEq(filled, 1, "only the 85% ask is still alive");
        assertEq(positions.ownerOf(_id(4)), taker);
        vm.prank(buyer);
        vm.expectRevert(PositionExchange.NothingFilled.selector);
        exchange.buyBest(address(m), s, U, type(uint256).max);
        // 自己的卖单跳过
        _list(taker, 4, U / 2);
        vm.prank(taker);
        vm.expectRevert(PositionExchange.NothingFilled.selector);
        exchange.buyBest(address(m), s, U, type(uint256).max);
    }

    // ---------------- 锁定与清算 ----------------

    function test_NoTradeWhileGovernanceLocked() public {
        uint256 id = _bid(buyer, U, 50 * BEM_1, 0, type(uint256).max);
        vm.prank(address(governor)); // 冒充清算治理合约（只为测锁）
        m.setGovernanceLock(true);
        assertFalse(exchange.tradable(address(m)));
        vm.prank(seller);
        vm.expectRevert(PositionExchange.NotTransferable.selector);
        exchange.sellToBid(id, slot, 0);
        assertFalse(exchange.bidValid(id), "the lock bumps the epoch, bids go stale like asks");
        _list(seller, slot, U); // 锁定期间可以挂单，但不能成交
        vm.prank(taker);
        vm.expectRevert(PositionExchange.NotTransferable.selector);
        exchange.buyAsk(address(m), slot, U);
        uint256[] memory s = new uint256[](1);
        s[0] = slot;
        vm.prank(taker);
        vm.expectRevert(PositionExchange.NotTransferable.selector);
        exchange.buyBest(address(m), s, U, type(uint256).max);
        vm.prank(address(governor));
        m.setGovernanceLock(false);
        assertFalse(exchange.askValid(address(m), slot), "unlock bumps the epoch: relist");
        _list(seller, slot, U);
        vm.prank(taker);
        exchange.buyAsk(address(m), slot, U);
        assertEq(positions.ownerOf(_id(slot)), taker);
        // 锁定前挂的买单已失效，不能成交；任何人可以帮买家退款，买家重挂后照常成交
        vm.prank(taker);
        vm.expectRevert(PositionExchange.BidStale.selector);
        exchange.sellToBid(id, slot, U);
        uint256 before = bem.balanceOf(buyer);
        exchange.refundBid(id);
        assertEq(bem.balanceOf(buyer) - before, 50 * BEM_1, "stale bid refunded to the bidder");
        uint256 id2 = _bid(buyer, U, 50 * BEM_1, 0, type(uint256).max);
        vm.prank(taker);
        exchange.sellToBid(id2, slot, U);
        assertEq(positions.ownerOf(_id(slot)), buyer);
    }

    /// @dev 矿机卖出后局交易版本号变了：旧买单不能再成交，任何人可以帮买家退款
    function test_BidStaleAfterMachineSale() public {
        vm.warp(m.settleStart() + 1 days); // 成本价锁定
        _syncRigs(m);
        uint256 id = _bid(buyer, U * 95 / 100, 50 * BEM_1, 0, type(uint256).max);
        assertTrue(exchange.bidValid(id));
        assertEq(exchange.bidEpoch(id), m.tradeEpoch());
        vm.startPrank(seller);
        bem.approve(address(sales), type(uint256).max);
        sales.buyMachine(address(m), 0, type(uint256).max); // 本金回到持仓，局交易版本号 +1
        vm.expectRevert(PositionExchange.BidStale.selector);
        exchange.sellToBid(id, slot, 0);
        vm.stopPrank();
        assertFalse(exchange.bidValid(id));
        (, PositionExchange.BidView[] memory bids) = exchange.book(address(m), 0);
        assertEq(bids.length, 0, "stale bids drop out of the book");
        // 买家撤单拿回全部托管
        uint256 before = bem.balanceOf(buyer);
        vm.prank(buyer);
        exchange.cancelBid(id);
        assertEq(bem.balanceOf(buyer) - before, 50 * BEM_1);
        assertEq(exchange.bidEpoch(id), 0);
        assertEq(exchange.totalEscrow(), bem.balanceOf(address(exchange)));
    }

    function test_TradeAfterLiquidationStarts() public {
        vm.startPrank(address(governor)); // 冒充清算治理合约：投票通过、执行
        m.setGovernanceLock(true);
        m.setGovernanceLock(false);
        m.startLiquidation();
        vm.stopPrank();
        assertTrue(m.liquidating());
        _list(seller, slot, U / 2);
        vm.prank(taker);
        exchange.buyAsk(address(m), slot, U / 2);
        assertEq(positions.ownerOf(_id(slot)), taker);
        uint256 id = _bid(buyer, U / 3, 50 * BEM_1, 0, type(uint256).max);
        vm.prank(taker);
        exchange.sellToBid(id, slot, U / 3); // 清算期间买单照常成交
        assertEq(positions.ownerOf(_id(slot)), buyer);
    }

    function test_ClaimsClosedStopsListingAndAllowsRefund() public {
        uint256 id = _bid(buyer, U, 50 * BEM_1, 0, type(uint256).max);
        _list(seller, slot, U);
        // 卖掉全部矿机，局终；领取期限过后关闭
        vm.warp(m.settleStart() + 1 days);
        _syncRigs(m);
        vm.startPrank(other);
        bem.approve(address(sales), type(uint256).max);
        for (uint256 i = 0; i < m.machineCount(); i++) {
            if (!m.machine(i).sold) sales.buyMachine(address(m), i, type(uint256).max);
        }
        vm.stopPrank();
        assertGt(m.finishedAt(), 0);
        vm.warp(m.finishedAt() + monthFactory.boardConfig().claimWindow);
        m.closeClaims();
        assertFalse(exchange.askValid(address(m), slot));
        vm.prank(seller);
        vm.expectRevert(PositionExchange.NotListable.selector);
        exchange.listAsk(address(m), slot, U, uint64(block.timestamp + 1 days));
        vm.prank(taker);
        vm.expectRevert(PositionExchange.AskNotValid.selector);
        exchange.buyAsk(address(m), slot, U);
        assertFalse(exchange.bidValid(id));
        vm.prank(buyer);
        vm.expectRevert(PositionExchange.NotListable.selector);
        exchange.placeBid(address(m), U, 50 * BEM_1, 0, type(uint256).max, uint64(block.timestamp + 1 days));
        uint256 b0 = bem.balanceOf(buyer);
        exchange.refundBid(id); // 没过期，但领取期限已关闭：任何人可以退款
        assertEq(bem.balanceOf(buyer) - b0, 50 * BEM_1);
    }

    function test_RecentTradesRingKeepsNewest20() public {
        _list(seller, slot, U);
        for (uint256 k = 0; k < 25; k++) {
            // 在 seller 和 taker 之间来回成交，单价每次 +1
            address from = k % 2 == 0 ? seller : taker;
            address to = k % 2 == 0 ? taker : seller;
            _list(from, slot, U + k);
            vm.prank(to);
            exchange.buyAsk(address(m), slot, U + k);
            vm.warp(block.timestamp + 1);
        }
        assertEq(exchange.tradeCount(address(m)), 25);
        PositionExchange.Trade[] memory t = exchange.recentTrades(address(m));
        assertEq(t.length, 20);
        for (uint256 i = 0; i < 20; i++) {
            assertEq(t[i].unitPrice, U + 24 - i, "newest first");
        }
    }

    // ---------------- 守恒 ----------------

    /// @dev 随机交错：挂单 / 改价 / 撤单 / 吃单 / 批量吃单、挂买单 / 卖给买单 / 撤买单 / 过期退款、持仓私下转让、时间推进。
    ///      每一步：交易所余额 == totalEscrow == Σ 未关闭买单 remaining；参与者 + 交易所的 BEM 总和不变（一分不差）；
    ///      每笔成交卖方收到 = quote(stake, 单价)。
    function testFuzz_BookCashConservation(uint256 seed) public {
        address[5] memory who = [seller, small, taker, other, buyer];
        uint256[3] memory slots = [slot, smallSlot, uint256(3)];
        address o3 = m.socket(3).owner;
        vm.prank(o3);
        positions.transferFrom(o3, other, _id(3));
        uint256 total = _sumBem(who);
        for (uint256 k = 0; k < 24; k++) {
            uint256 r = uint256(keccak256(abi.encode(seed, k)));
            address t = who[(r >> 8) % 5];
            uint256 s = slots[(r >> 16) % 3];
            address owner = m.socket(s).owner;
            uint256 unit = 1 + (r >> 24) % (2 * U);
            uint256 action = r % 10;
            if (action == 0 || action == 1) {
                _list(owner, s, unit);
            } else if (action == 2) {
                PositionExchange.AskOrder memory a = exchange.ask(address(m), s);
                if (exchange.askValid(address(m), s) && t != owner) {
                    uint256 cost = exchange.quote(_stake(s), a.unitPrice);
                    uint256 tb = bem.balanceOf(t);
                    uint256 ob = bem.balanceOf(owner);
                    vm.prank(t);
                    exchange.buyAsk(address(m), s, a.unitPrice);
                    assertEq(tb - bem.balanceOf(t), cost, "buyer paid quote");
                    assertEq(bem.balanceOf(owner) - ob, cost, "seller got quote");
                }
            } else if (action == 3) {
                uint256[] memory ss = new uint256[](3);
                ss[0] = slots[0];
                ss[1] = slots[1];
                ss[2] = slots[2];
                bool any;
                for (uint256 i = 0; i < 3; i++) {
                    if (exchange.askValid(address(m), ss[i]) && m.socket(ss[i]).owner != t) any = true;
                }
                if (any) {
                    vm.prank(t);
                    exchange.buyBest(address(m), ss, type(uint256).max, type(uint256).max);
                }
            } else if (action == 4) {
                if (exchange.ask(address(m), s).maker != address(0)) {
                    vm.prank(owner);
                    exchange.cancelAsk(address(m), s);
                }
            } else if (action == 7) {
                if (exchange.openBidsOf(address(m), t) < 20) {
                    uint256 budget = BEM_1 + (r >> 40) % (40 * BEM_1);
                    if (budget >= exchange.quote(1, unit)) _bid(t, unit, budget, 0, type(uint256).max);
                }
            } else if (action == 8 || action == 9) {
                uint256 n = exchange.bidCount(address(m));
                if (n > 0) {
                    PositionExchange.BidView memory b = exchange.bidsOf(address(m), (r >> 40) % n, 1)[0];
                    if (action == 8) {
                        if (b.valid && b.bidder != owner && exchange.quote(_stake(s), b.unitPrice) <= b.remaining) {
                            uint256 cost = exchange.quote(_stake(s), b.unitPrice);
                            uint256 ob = bem.balanceOf(owner);
                            vm.prank(owner);
                            exchange.sellToBid(b.bidId, s, 0);
                            assertEq(bem.balanceOf(owner) - ob, cost, "seller got quote from escrow");
                        }
                    } else if (b.valid) {
                        vm.prank(b.bidder);
                        exchange.cancelBid(b.bidId);
                    } else {
                        exchange.refundBid(b.bidId);
                    }
                }
            } else if (action == 5) {
                if (t != owner) {
                    vm.prank(owner);
                    positions.transferFrom(owner, t, _id(s)); // 私下转让：卖单自动失效
                }
            } else {
                vm.warp(block.timestamp + (r >> 40) % 2 days);
            }
            assertEq(bem.balanceOf(address(exchange)), exchange.totalEscrow(), "exchange BEM == escrow");
            uint256 esc;
            PositionExchange.BidView[] memory open = exchange.bidsOf(address(m), 0, 0);
            for (uint256 i = 0; i < open.length; i++) {
                esc += open[i].remaining;
            }
            assertEq(esc, exchange.totalEscrow(), "escrow == sum of open bids");
            assertEq(_sumBem(who), total, "no BEM created or lost");
        }
    }

    function _sumBem(address[5] memory who) internal view returns (uint256 s) {
        for (uint256 i = 0; i < who.length; i++) {
            s += bem.balanceOf(who[i]);
        }
        s += bem.balanceOf(address(exchange));
    }
}
