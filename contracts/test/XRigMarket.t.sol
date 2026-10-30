// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {XMonthBoard} from "../src/XMonthBoard.sol";
import {XRigMarket} from "../src/market/XRigMarket.sol";
import {XMonthMachineSales} from "../src/month/XMonthMachineSales.sol";
import {MonthState} from "../src/interfaces/IXMonthBoard.sol";

/// @notice RIG 矿机市场（XRigMarket）：卖单、统一买单、月局从市场收购（按卖单实价，不超过收购价）、
///         月局矿机在市场成交（按卖矿合约要价）、手续费、托管守恒
contract XRigMarketTest is Fixture {
    address internal seller = address(0x5E11);
    address internal buyer = address(0xB0B);
    address internal bidder = address(0xB1D);
    address internal keeper = address(0xCAFE);

    function setUp() public override {
        super.setUp();
        address[2] memory payers = [buyer, bidder];
        for (uint256 i = 0; i < 2; i++) {
            bem.mint(payers[i], 100_000 * BEM_1);
            vm.prank(payers[i]);
            bem.approve(address(market), type(uint256).max);
        }
    }

    // ---------------- 辅助 ----------------

    function _rig(address owner, uint256 power) internal returns (uint256 id) {
        (id,) = _newMachine(owner, power);
        vm.prank(owner);
        machines.setApprovalForAll(address(market), true);
    }

    function _list(address owner, uint256 power, uint256 price) internal returns (uint256 id) {
        id = _rig(owner, power);
        vm.prank(owner);
        market.listAsk(id, price, uint64(block.timestamp + 7 days));
    }

    function _bid(uint256 price, uint256 budget, uint256 minPower, uint256 maxPower, uint256 maxSyncAge)
        internal
        returns (uint256 bidId)
    {
        vm.prank(bidder);
        bidId = market.placeBid(price, budget, minPower, maxPower, maxSyncAge, uint64(block.timestamp + 7 days));
    }

    /// @dev 一块正在收购的月局（第 1 块，招满）
    function _preparing() internal returns (XMonthBoard m) {
        _startGenesis();
        m = _monthBoard();
        _fillMonth(m);
        assertTrue(m.isPurchasing());
    }

    /// @dev 一块进入结算的月局：按给定算力各收购一台，挖满 30 天（没有产出，直接结算），刷新报价和 RIG 同步时间
    function _settling(uint256[] memory powers) internal returns (XMonthBoard m) {
        m = _preparing();
        address s = _newUser();
        for (uint256 i = 0; i < powers.length; i++) {
            _sellMonth(m, s, powers[i]);
        }
        vm.warp(m.prepEnd());
        m.sync();
        vm.warp(m.miningEnd());
        m.drawPrizes(); // 奖金池为 0：直接进入结算
        assertEq(uint256(m.state()), uint256(MonthState.Settling));
        _feedDefault();
        _syncRigs(m);
    }

    function _escrowBalanced() internal view {
        assertEq(bem.balanceOf(address(market)), market.totalEscrow(), "market holds exactly the bid escrow");
    }

    // ---------------- 部署 ----------------

    function test_ConstructorReadsBoardConfig() public view {
        assertEq(address(market.BEM()), address(bem));
        assertEq(address(market.RIG()), address(machines));
        assertEq(address(market.MACHINE_SOURCE()), address(machineSource));
        assertEq(address(market.FACTORY()), address(monthFactory));
        assertEq(address(market.SALES()), address(sales));
        assertEq(market.FEE_RECIPIENT(), FEE_SAFE);
        assertEq(market.FEE_BPS(), 0);
        assertEq(XMonthBoard(monthFactory.boardImplementation()).MARKET(), address(market));
    }

    function test_RevertWhen_MarketNotInBoardConfigOrFeeTooHigh() public {
        vm.expectRevert(XRigMarket.BadConfig.selector);
        new XRigMarket(address(monthFactory), 0); // 配置里的 market 是另一个地址
        vm.expectRevert(XRigMarket.BadConfig.selector);
        new XRigMarket(address(monthFactory), 101); // 手续费超过 1%
    }

    // ---------------- 卖单 ----------------

    function test_ListAndBuyAsk() public {
        uint256 id = _list(seller, 30, 1e8);
        assertTrue(market.askValid(id));
        uint256 before = bem.balanceOf(seller);
        vm.prank(buyer);
        uint256 total = market.buyAsk(id, 30e8);
        assertEq(total, 30e8);
        assertEq(bem.balanceOf(seller) - before, 30e8);
        assertEq(machines.ownerOf(id), buyer);
        assertEq(market.askCount(), 0);
        XRigMarket.Trade[] memory t = market.recentTrades();
        assertEq(t.length, 1);
        assertEq(t[0].rigId, id);
        assertEq(t[0].price, 1e8);
        assertEq(t[0].power, 30);
        assertEq(t[0].kind, market.KIND_BUY_ASK());
        _escrowBalanced();
    }

    function test_RevertWhen_BuyAskAboveMaxOrSelf() public {
        uint256 id = _list(seller, 30, 1e8);
        vm.prank(buyer);
        vm.expectRevert(XRigMarket.PriceAbove.selector);
        market.buyAsk(id, 30e8 - 1);
        vm.prank(seller);
        vm.expectRevert(XRigMarket.SelfTrade.selector);
        market.buyAsk(id, 30e8);
    }

    function test_ListAskChecks() public {
        uint256 id = _rig(seller, 30);
        vm.startPrank(seller);
        vm.expectRevert(XRigMarket.BadDeadline.selector);
        market.listAsk(id, 1e8, uint64(block.timestamp));
        vm.expectRevert(XRigMarket.BadDeadline.selector);
        market.listAsk(id, 1e8, uint64(block.timestamp + 30 days + 1));
        vm.expectRevert(XRigMarket.ZeroPrice.selector);
        market.listAsk(id, 0, uint64(block.timestamp + 1 days));
        machines.setApprovalForAll(address(market), false);
        vm.expectRevert(XRigMarket.NotApproved.selector);
        market.listAsk(id, 1e8, uint64(block.timestamp + 1 days));
        machines.approve(address(market), id); // 单张授权也可以
        market.listAsk(id, 1e8, uint64(block.timestamp + 1 days));
        market.listAsk(id, 2e8, uint64(block.timestamp + 1 days)); // 重挂即改价
        vm.stopPrank();
        assertEq(market.askCount(), 1);
        assertEq(market.ask(id).price, 2e8);
        vm.prank(buyer);
        vm.expectRevert(XRigMarket.NotOwner.selector);
        market.listAsk(id, 1e8, uint64(block.timestamp + 1 days));
        vm.prank(buyer);
        vm.expectRevert(XRigMarket.NotOwner.selector);
        market.cancelAsk(id);
        vm.prank(seller);
        market.cancelAsk(id);
        assertEq(market.askCount(), 0);
    }

    function test_AskInvalidAfterTransferRevokeOrExpiry() public {
        uint256 a = _list(seller, 30, 1e8);
        uint256 b = _list(seller, 20, 1e8);
        uint256 c = _list(seller, 10, 1e8);
        vm.startPrank(seller);
        machines.transferFrom(seller, keeper, a); // 持有人变了
        machines.setApprovalForAll(address(market), false); // 撤销授权
        vm.stopPrank();
        assertFalse(market.askValid(a));
        assertFalse(market.askValid(b));
        assertFalse(market.askValid(c));
        vm.prank(buyer);
        vm.expectRevert(XRigMarket.AskNotValid.selector);
        market.buyAsk(a, type(uint256).max);
        (XRigMarket.AskView[] memory asks,) = market.book(0);
        assertEq(asks.length, 0, "book only shows valid asks");
        vm.prank(seller);
        machines.setApprovalForAll(address(market), true);
        assertTrue(market.askValid(c));
        vm.warp(block.timestamp + 7 days); // 过期
        assertFalse(market.askValid(c));
        uint256[] memory ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (a, b, c);
        market.pruneAsks(ids);
        assertEq(market.askCount(), 0);
    }

    function test_BuyBestSortsAndSkips() public {
        uint256 hi = _list(seller, 10, 3e7);
        uint256 lo = _list(seller, 10, 1e7);
        uint256 mid = _list(seller, 10, 2e7);
        uint256 gone = _list(seller, 10, 5e6);
        vm.prank(seller);
        machines.transferFrom(seller, keeper, gone);
        (XRigMarket.AskView[] memory asks,) = market.book(0);
        assertEq(asks.length, 3);
        assertEq(asks[0].rigId, lo);
        assertEq(asks[1].rigId, mid);
        assertEq(asks[2].rigId, hi);
        assertEq(asks[0].total, 1e8);
        uint256[] memory ids = new uint256[](4);
        (ids[0], ids[1], ids[2], ids[3]) = (hi, gone, mid, lo);
        vm.prank(buyer);
        (uint256 filled, uint256 spent) = market.buyBest(ids, 2e7, type(uint256).max);
        assertEq(filled, 2);
        assertEq(spent, 3e8);
        assertEq(machines.ownerOf(lo), buyer);
        assertEq(machines.ownerOf(mid), buyer);
        assertEq(machines.ownerOf(hi), seller);
        vm.prank(buyer);
        vm.expectRevert(XRigMarket.NothingFilled.selector);
        market.buyBest(ids, 2e7, type(uint256).max);
        vm.prank(buyer);
        vm.expectRevert(XRigMarket.NothingFilled.selector);
        market.buyBest(ids, 3e7, 3e8 - 1); // 超过总花费上限的跳过
    }

    // ---------------- 统一买单 ----------------

    function test_SellToBidThenAutoCloseRefund() public {
        uint256 bidId = _bid(1e8, 55e8, 10, 40, 1 days);
        assertEq(market.totalEscrow(), 55e8);
        uint256 r1 = _rig(seller, 30);
        uint256 r2 = _rig(seller, 20);
        uint256 before = bem.balanceOf(seller);
        vm.prank(seller);
        assertEq(market.sellToBid(bidId, r1), 30e8);
        assertEq(machines.ownerOf(r1), bidder);
        assertEq(market.bid(bidId).remaining, 25e8);
        assertTrue(market.bidValid(bidId));
        uint256 bidderBefore = bem.balanceOf(bidder);
        vm.prank(seller);
        market.sellToBid(bidId, r2);
        // 剩 5 BEM，不够最小一张（10 算力 × 1 BEM）：自动关闭并退款
        assertEq(bem.balanceOf(seller) - before, 50e8);
        assertEq(bem.balanceOf(bidder) - bidderBefore, 5e8);
        assertEq(market.bid(bidId).bidder, address(0));
        assertEq(market.bidCount(), 0);
        assertEq(market.openBidsOf(bidder), 0);
        assertEq(market.recentTrades()[0].kind, market.KIND_SELL_TO_BID());
        _escrowBalanced();
    }

    function test_BidChecks() public {
        vm.startPrank(bidder);
        vm.expectRevert(XRigMarket.BudgetTooSmall.selector);
        market.placeBid(1e8, 1e8 - 1, 1, 40, 0, uint64(block.timestamp + 1 days));
        vm.expectRevert(XRigMarket.BudgetTooSmall.selector);
        market.placeBid(1e8, 9e8, 10, 40, 0, uint64(block.timestamp + 1 days)); // 不够一张 10 算力
        vm.expectRevert(XRigMarket.BadPowerRange.selector);
        market.placeBid(1e8, 10e8, 10, 9, 0, uint64(block.timestamp + 1 days));
        vm.stopPrank();

        uint256 bidId = _bid(1e8, 40e8, 10, 40, 1 days);
        uint256 big = _rig(seller, 50);
        vm.prank(seller);
        vm.expectRevert(XRigMarket.PowerOutOfRange.selector);
        market.sellToBid(bidId, big);
        uint256 ok = _rig(seller, 30);
        vm.prank(keeper);
        vm.expectRevert(XRigMarket.NotOwner.selector);
        market.sellToBid(bidId, ok);
        uint256 own = _rig(bidder, 30);
        vm.prank(bidder);
        vm.expectRevert(XRigMarket.SelfTrade.selector);
        market.sellToBid(bidId, own);
        vm.warp(block.timestamp + 1 days + 1); // RIG 超过 1 天没同步
        vm.prank(seller);
        vm.expectRevert(XRigMarket.SyncTooOld.selector);
        market.sellToBid(bidId, ok);
        machines.sync(ok, 30, uint64(block.timestamp));
        uint256 r40 = _rig(seller, 40);
        vm.prank(seller);
        market.sellToBid(bidId, ok); // 剩 10 BEM
        vm.prank(seller);
        vm.expectRevert(XRigMarket.BudgetExceeded.selector);
        market.sellToBid(bidId, r40);

        vm.prank(keeper);
        vm.expectRevert(XRigMarket.NotBidder.selector);
        market.cancelBid(bidId);
        vm.expectRevert(XRigMarket.BidStillValid.selector);
        market.refundBid(bidId);
        vm.warp(block.timestamp + 7 days);
        vm.prank(seller);
        vm.expectRevert(XRigMarket.BidExpired.selector);
        market.sellToBid(bidId, r40);
        uint256 before = bem.balanceOf(bidder);
        vm.prank(keeper);
        market.refundBid(bidId); // 过期后任何人可以帮买家退款
        assertEq(bem.balanceOf(bidder) - before, 10e8);
        vm.expectRevert(XRigMarket.BidClosedAlready.selector);
        market.refundBid(bidId);
        _escrowBalanced();
    }

    function test_RevertWhen_TooManyOpenBids() public {
        for (uint256 i = 0; i < 20; i++) {
            _bid(1e7, 1e8, 1, 300, 0);
        }
        vm.prank(bidder);
        vm.expectRevert(XRigMarket.TooManyBids.selector);
        market.placeBid(1e7, 1e8, 1, 300, 0, uint64(block.timestamp + 1 days));
        vm.prank(bidder);
        market.cancelBid(7);
        _bid(1e7, 1e8, 1, 300, 0);
        (, XRigMarket.BidView[] memory bids) = market.book(5);
        assertEq(bids.length, 5);
        _escrowBalanced();
    }

    function test_BookSortsBidsHighFirst() public {
        _bid(1e8, 10e8, 1, 300, 0);
        uint256 top = _bid(3e8, 10e8, 1, 300, 0);
        uint256 second = _bid(2e8, 10e8, 1, 300, 0);
        uint256 tie = _bid(3e8, 10e8, 1, 300, 0);
        (, XRigMarket.BidView[] memory bids) = market.book(3);
        assertEq(bids.length, 3);
        assertEq(bids[0].bidId, top);
        assertEq(bids[1].bidId, tie); // 同价先挂的在前
        assertEq(bids[2].bidId, second);
    }

    // ---------------- 月局从市场收购（对应 BSC MarketTrader）----------------

    function test_SellAskToBoardPaysAskPrice() public {
        XMonthBoard m = _preparing();
        uint256 buyPrice = m.buyPrice();
        assertEq(buyPrice, FEED_ASK / 2, "auction starts at 50% of the cap");
        uint256 id = _list(seller, 30, buyPrice * 6 / 10); // 卖单价低于当前收购价
        uint256 total = 30 * (buyPrice * 6 / 10);
        uint256 budget = m.budget();
        uint256 before = bem.balanceOf(seller);
        vm.prank(keeper); // 任何人都可以触发
        assertEq(market.sellAskToBoard(id, address(m)), total);
        assertEq(machines.ownerOf(id), address(m));
        assertEq(m.machine(0).cost, total, "board books the real ask price, not the auction price");
        assertEq(m.machine(0).weight, 30);
        assertEq(budget - m.budget(), total);
        assertEq(bem.balanceOf(seller) - before, total);
        assertEq(market.askCount(), 0);
        assertEq(market.recentTrades()[0].kind, market.KIND_ASK_TO_BOARD());
        _escrowBalanced();
    }

    function test_SellAskToBoardWaitsForAuctionToRise() public {
        XMonthBoard m = _preparing();
        uint256 price = m.buyPrice() * 12 / 10; // 比现在的收购价高 20%
        uint256 id = _list(seller, 30, price);
        vm.expectRevert(XMonthBoard.PriceBelowMinimum.selector);
        market.sellAskToBoard(id, address(m));
        vm.warp(block.timestamp + 12 hours); // 收购价每 6 小时 + 5%（上限的），到 60%
        _feedDefault();
        assertGe(m.buyPrice(), price);
        market.sellAskToBoard(id, address(m));
        assertEq(m.machine(0).cost, 30 * price);
    }

    function test_RevertWhen_SellAskToBoardIneligibleOrWrongBoard() public {
        uint256 stale = _rig(seller, 30); // 开局前铸的：到开局时已经超过 3 天没同步
        XMonthBoard m = _preparing();
        uint256 p = m.buyPrice() / 2;
        vm.prank(seller);
        market.listAsk(stale, p, uint64(block.timestamp + 1 days));
        vm.expectRevert(XMonthBoard.MachineNotEligible.selector);
        market.sellAskToBoard(stale, address(m));
        uint256 small = _list(seller, 5, p); // 算力低于月局下限 10
        vm.expectRevert(XMonthBoard.MachineNotEligible.selector);
        market.sellAskToBoard(small, address(m));
        uint256 id = _list(seller, 30, p);
        vm.expectRevert(XRigMarket.NotMonthBoard.selector);
        market.sellAskToBoard(id, keeper);
        XMonthBoard next = _monthBoard(); // 下一块还在招募
        vm.expectRevert(XMonthBoard.BuyRoundInactive.selector);
        market.sellAskToBoard(id, address(next));
        assertEq(machines.ownerOf(id), seller, "reverted: the RIG stays with the seller");
        // 卖单的 RIG 被卖家直接卖给月局后，卖单失效
        vm.startPrank(seller);
        machines.approve(address(m), id);
        m.sellMachine(address(machines), id, 0);
        vm.stopPrank();
        vm.expectRevert(XRigMarket.AskNotValid.selector);
        market.sellAskToBoard(id, address(m));
    }

    function test_OnlyMarketGetsExactPricePath() public {
        XMonthBoard m = _preparing();
        uint256 price = m.buyPrice();
        (uint256 id,) = _newMachine(seller, 30);
        vm.startPrank(seller);
        machines.approve(address(m), id);
        // 普通卖家：第三个参数是最低单价，高于收购价时拒绝
        vm.expectRevert(XMonthBoard.PriceBelowMinimum.selector);
        m.sellMachine(address(machines), id, price + 1);
        // 传一个很小的数也照样按收购价付款（只有市场合约走"按实价"）
        uint256 paid = m.sellMachine(address(machines), id, 1);
        vm.stopPrank();
        assertEq(paid, 30 * price);
    }

    // ---------------- 月局在市场卖矿 ----------------

    function test_BoardOffersAndBuyBoardMachine() public {
        uint256[] memory powers = new uint256[](2);
        (powers[0], powers[1]) = (30, 20);
        XMonthBoard m = _settling(powers);
        XRigMarket.OfferView[] memory offers = market.boardOffers(address(m));
        assertEq(offers.length, 2);
        assertEq(offers[0].index, 0);
        assertEq(offers[0].power, 30);
        assertEq(offers[0].total, sales.askPrice(address(m), 0));
        assertTrue(offers[0].syncFresh);
        assertGe(offers[0].total, m.machine(0).cost);
        uint256 total = offers[1].total;
        uint256 rigId = offers[1].rigId;
        uint256 before = bem.balanceOf(buyer);
        vm.prank(buyer);
        vm.expectRevert(XRigMarket.PriceAbove.selector);
        market.buyBoardMachine(address(m), 1, total - 1);
        vm.prank(buyer);
        assertEq(market.buyBoardMachine(address(m), 1, total), total);
        assertEq(before - bem.balanceOf(buyer), total);
        assertEq(machines.ownerOf(rigId), buyer);
        assertTrue(m.machine(1).sold);
        assertEq(market.boardOffers(address(m)).length, 1);
        assertEq(market.recentTrades()[0].kind, market.KIND_BUY_BOARD());
        vm.prank(buyer);
        vm.expectRevert(XRigMarket.NotForSale.selector);
        market.buyBoardMachine(address(m), 1, type(uint256).max);
        _escrowBalanced();
    }

    function test_FillBidFromBoardChargesAskPriceOnly() public {
        uint256[] memory powers = new uint256[](1);
        powers[0] = 30;
        XMonthBoard m = _settling(powers);
        uint256 ask = sales.askPrice(address(m), 0);
        uint256 rigId = m.machine(0).circuitId;
        uint256 low = _bid(ask / 30 - 1, 100e8, 10, 40, 1 days); // 出价低于要价
        vm.expectRevert(XRigMarket.PriceAbove.selector);
        market.fillBidFromBoard(low, address(m), 0);
        uint256 bidId = _bid(ask / 30 + 1e7, 200e8, 10, 40, 1 days);
        uint256 feeBefore = bem.balanceOf(FEE_SAFE);
        vm.prank(keeper);
        assertEq(market.fillBidFromBoard(bidId, address(m), 0), ask);
        assertEq(machines.ownerOf(rigId), bidder);
        assertEq(market.bid(bidId).remaining, 200e8 - ask, "bidder only pays the board's ask");
        assertTrue(m.machine(0).sold);
        // 手续费 Safe 只收到主板的溢价分成（市场不收月局卖矿的手续费）
        assertEq(bem.balanceOf(FEE_SAFE) - feeBefore, (ask - m.machine(0).cost) * m.PREMIUM_FEE_BPS() / 10_000);
        assertEq(market.recentTrades()[0].kind, market.KIND_BOARD_TO_BID());
        vm.expectRevert(XRigMarket.NotForSale.selector);
        market.fillBidFromBoard(bidId, address(m), 0);
        _escrowBalanced();
    }

    function test_FillBidFromBoardNeedsFreshSync() public {
        uint256[] memory powers = new uint256[](1);
        powers[0] = 30;
        XMonthBoard m = _settling(powers);
        uint256 ask = sales.askPrice(address(m), 0);
        uint256 bidId = _bid(ask / 30 + 1e7, 200e8, 10, 40, 0); // 买单不限同步时间
        vm.warp(block.timestamp + 1 days + 1);
        _feedDefault();
        vm.expectRevert(XMonthMachineSales.SyncTooOld.selector); // 卖矿合约要求 1 天内同步过
        market.fillBidFromBoard(bidId, address(m), 0);
        _syncRigs(m);
        market.fillBidFromBoard(bidId, address(m), 0);
        _escrowBalanced();
    }

    // ---------------- 手续费 ----------------

    function test_FeeFromPlayerSellersOnly() public {
        // 同一地址重新部署一个 1% 手续费的市场（月局配置里的 market 地址不变）
        deployCodeTo("XRigMarket.sol:XRigMarket", abi.encode(address(monthFactory), uint256(100)), address(market));
        assertEq(market.FEE_BPS(), 100);
        uint256 id = _list(seller, 30, 1e8);
        uint256 s0 = bem.balanceOf(seller);
        uint256 f0 = bem.balanceOf(FEE_SAFE);
        vm.prank(buyer);
        market.buyAsk(id, 30e8);
        assertEq(bem.balanceOf(seller) - s0, 30e8 * 99 / 100);
        assertEq(bem.balanceOf(FEE_SAFE) - f0, 30e8 / 100);

        uint256 bidId = _bid(1e8, 100e8, 10, 40, 0);
        uint256 r = _rig(seller, 20);
        s0 = bem.balanceOf(seller);
        f0 = bem.balanceOf(FEE_SAFE);
        vm.prank(seller);
        market.sellToBid(bidId, r);
        assertEq(bem.balanceOf(seller) - s0, 20e8 * 99 / 100);
        assertEq(bem.balanceOf(FEE_SAFE) - f0, 20e8 / 100);
        assertEq(
            market.bid(bidId).remaining, 80e8, "the bidder pays the full price; the fee comes out of the seller's side"
        );
        _escrowBalanced();
    }

    function test_FeeOnAskSoldToBoard() public {
        deployCodeTo("XRigMarket.sol:XRigMarket", abi.encode(address(monthFactory), uint256(100)), address(market));
        XMonthBoard m = _preparing();
        uint256 price = m.buyPrice() / 2;
        uint256 id = _list(seller, 30, price);
        uint256 s0 = bem.balanceOf(seller);
        uint256 f0 = bem.balanceOf(FEE_SAFE);
        market.sellAskToBoard(id, address(m));
        uint256 total = 30 * price;
        assertEq(m.machine(0).cost, total, "the board pays the ask price");
        assertEq(bem.balanceOf(FEE_SAFE) - f0, total / 100);
        assertEq(bem.balanceOf(seller) - s0, total - total / 100);
        _escrowBalanced();
    }
}
