// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {XMonthBoard} from "../src/XMonthBoard.sol";
import {MonthState} from "../src/interfaces/IXMonthBoard.sol";

interface IReportedYield {
    function reportedYieldReceived(address board) external view returns (uint256);
}

/// @notice 迟到收益可修正未来报价；已开局快照、首次报告次序和实际持有算力时间保持确定。
contract XLateYieldTest is Fixture {
    XMonthBoard internal board;
    address[] internal users;

    function setUp() public override {
        super.setUp();
        board = _startGenesis();
    }

    function _startFirst(uint256 weight) internal {
        users = _fillMonth(board);
        _sellMonth(board, _newUser(), weight);
    }

    function _finish(XMonthBoard mb, uint256 income) internal {
        if (block.timestamp < mb.prepEnd() + 30 days) vm.warp(mb.prepEnd() + 30 days);
        if (income != 0) _yieldMonth(mb, income);
        mb.drawPrizes();
        if (mb.state() == MonthState.Drawing) {
            rng.fulfill(mb.pendingRequestId(), 12345);
            mb.finalizePrizes();
        }
        assertEq(uint256(mb.state()), uint256(MonthState.Settling));
    }

    function _freshPreparing() internal returns (XMonthBoard next) {
        next = _monthBoard();
        if (block.timestamp >= next.recruitDeadline()) {
            next.closeRecruitment();
            next = _monthBoard();
        }
        _fillMonth(next);
        assertEq(uint256(next.state()), uint256(MonthState.Preparing));
    }

    function _reported(XMonthBoard mb) internal view returns (uint256) {
        return IReportedYield(address(monthFactory)).reportedYieldReceived(address(mb));
    }

    function _sumOwed(XMonthBoard mb, address[] memory participants) internal view returns (uint256 total) {
        for (uint256 i; i < participants.length; ++i) {
            total += _mOwed(mb, participants[i]);
        }
    }

    function _buy(XMonthBoard mb, uint256 index) internal {
        _syncRigs(mb);
        address buyer = _newUser();
        bem.mint(buyer, 1000e8);
        vm.startPrank(buyer);
        bem.approve(address(sales), type(uint256).max);
        sales.buyMachine(address(mb), index, type(uint256).max);
        vm.stopPrank();
    }

    function test_LateYieldRestoresFutureBoardsButNotExistingSnapshot() public {
        _startFirst(50);
        _finish(board, 0);
        assertEq(monthFactory.unitYieldPerDay(), 0);
        XMonthBoard frozen = _freshPreparing();
        assertEq(frozen.buyPriceCap(), 0);

        uint256 beforeOwed = _sumOwed(board, users);
        _yieldMonth(board, 1e8);
        board.harvest();
        uint256 perDay = uint256(1e8) * 1 days / (50 * 33 days);
        assertEq(monthFactory.unitYieldPerDay(), perDay);
        assertEq(board.yieldReceived(), 1e8);
        assertEq(_reported(board), 1e8);
        assertApproxEqAbs(_sumOwed(board, users) - beforeOwed, 1e8, users.length);
        assertEq(frozen.buyPriceCap(), 0, "already-started board keeps its zero snapshot");
        (uint256 id,) = _newMachine(address(this), 10);
        machines.approve(address(frozen), id);
        vm.expectRevert(XMonthBoard.PriceUnavailable.selector);
        frozen.sellMachine(address(machines), id, 0);

        // 每局上限相对上一块开局的月局最多上调 max(25%, 部署上限 × 5%)。上一局是 0，所以这一局只恢复到
        // 部署上限的 5%（实测样本对应的 perDay × 365 更高），之后逐局继续上调
        XMonthBoard restored = _freshPreparing();
        assertGt(perDay * 365, 8_250_000);
        assertEq(restored.buyPriceCap(), 8_250_000);
        _sellMonth(restored, _newUser(), 10);
        assertEq(restored.machineCount(), 1, "future board can purchase again");
    }

    /// @dev 往样本局捐 BEM 能抬高样本，但下一局的上限相对上一块开局的月局最多上调
    ///      max(25%, 部署上限 × 5%)，捐一笔不能把上限直接抬到部署上限
    function test_DonationCannotJumpNextBoardCap() public {
        _startFirst(50);
        _finish(board, 0); // 零收益样本
        XMonthBoard second = _freshPreparing();
        assertEq(second.buyPriceCap(), 0, "decreases apply immediately");
        _yieldMonth(board, 1e8);
        board.sweep();
        uint256 honest = monthFactory.unitYieldPerDay() * 365;
        address donor = _newUser();
        bem.mint(donor, 20e8);
        vm.prank(donor);
        bem.transfer(address(board), 20e8);
        board.sweep();
        assertGe(monthFactory.unitYieldPerDay() * 365, 165_000_000, "the sample itself is inflated");
        assertEq(monthFactory.roundCap(), 8_250_000, "but the next cap rises by at most 5% of the deploy cap");
        XMonthBoard third = _freshPreparing();
        assertEq(third.buyPriceCap(), 8_250_000);
        assertLt(third.buyPriceCap(), honest + 8_250_000);
        assertEq(monthFactory.lastRoundCap(), 8_250_000);
        // 之后每局最多再上调 max(25%, 部署上限 × 5%)
        assertEq(monthFactory.roundCap(), 16_500_000);
    }

    /// @dev 第一局用部署上限，之后第一份样本没有可比的上一局，捐赠能把样本（快照）抬到部署上限；
    ///      这时实际收购价上限还要和 BSC 卖一取较小值（同 BSC：收购价上限 = min(卖一, 一年产出)），报价无效时暂停收购
    function test_DonationAtFirstSampleBoundedByBscAsk() public {
        _startFirst(50);
        _finish(board, 0);
        address donor = _newUser();
        bem.mint(donor, 20e8);
        vm.prank(donor);
        bem.transfer(address(board), 20e8);
        board.sweep();
        assertGe(monthFactory.unitYieldPerDay() * 365, 165_000_000, "inflated sample");
        uint256 bscAsk = 141_997_481; // 2026-10-27 BSC 主网卖一（每单位算力 ≈ 1.42 BEM）
        XMonthBoard second = _freshPreparing();
        assertEq(second.buyPriceCap(), 165_000_000, "snapshot from the inflated sample");
        vm.warp(block.timestamp + 60 hours); // 拍卖涨到上限
        _forcePrices(76_377_649, bscAsk);
        assertEq(second.buyPrice(), bscAsk, "never above the BSC ask");
        vm.warp(block.timestamp + 3 hours);
        assertEq(second.buyPrice(), 0, "stale feed: buying paused");
    }

    function test_SweepAlsoReportsLateYield() public {
        _startFirst(50);
        _finish(board, 0);
        _yieldMonth(board, 12e8);
        board.sweep();
        assertEq(monthFactory.unitYieldPerDay(), uint256(12e8) * 1 days / (50 * 33 days));
        assertEq(_reported(board), 12e8);
        assertEq(board.accountedBalance(), bem.balanceOf(address(board)));
    }

    function test_SettlingAccruesExposureAndSaleStopsSoldMachine() public {
        users = _fillMonth(board);
        uint256 boughtAt = block.timestamp;
        _sellMonth(board, _newUser(), 30);
        _sellMonth(board, _newUser(), 20);
        _finish(board, 0);
        assertEq(board.weightSeconds(), 50 * 33 days);
        vm.warp(block.timestamp + 10 days);
        _yieldMonth(board, 1e8);
        board.harvest();
        uint256 exposure = 50 * (block.timestamp - boughtAt);
        assertEq(board.weightSeconds(), exposure);
        assertEq(monthFactory.unitYieldPerDay(), 1e8 * 1 days / exposure);
        assertLt(monthFactory.unitYieldPerDay(), uint256(1e8) * 1 days / (50 * 33 days));

        _buy(board, 0);
        assertEq(board.activeWeight(), 20);
        vm.warp(block.timestamp + 2 days);
        _yieldMonth(board, 3e8);
        board.harvest();
        exposure += 20 * 2 days;
        assertEq(board.weightSeconds(), exposure, "sold 30-weight rig contributes no later time");
        assertEq(monthFactory.unitYieldPerDay(), 4e8 * 1 days / exposure);
        assertEq(board.accountedBalance(), bem.balanceOf(address(board)));
    }

    function test_RelayStopsOldBoardsWeightAndStartsReceiverExposure() public {
        users = _fillMonth(board);
        uint256 boughtAt = block.timestamp;
        _sellMonth(board, _newUser(), 30);
        _sellMonth(board, _newUser(), 20);
        _finish(board, 0);
        vm.warp(block.timestamp + 2 days);
        _yieldMonth(board, 100e8); // 正样本允许后续局按原价接力。
        board.harvest();
        XMonthBoard receiver = _freshPreparing();
        _relayWhenPriced(board, 0, receiver); // v2：在接手方的收购拍卖里按不低于成本价成交（可能要等收购价涨上来）
        uint256 relayedAt = block.timestamp;
        assertEq(board.activeWeight(), 20);
        assertEq(receiver.activeWeight(), 30);
        vm.warp(block.timestamp + 1 days);
        _yieldMonth(board, 1e8);
        board.harvest();
        receiver.harvest();
        uint256 exposure = 50 * (relayedAt - boughtAt) + 20 * 1 days;
        assertEq(board.weightSeconds(), exposure);
        assertEq(receiver.weightSeconds(), 30 * 1 days);
        assertEq(monthFactory.unitYieldPerDay(), 101e8 * 1 days / exposure);
    }

    function test_AllSoldExposureStaysFixedWhileLateIncomeUpdatesQuote() public {
        _startFirst(50);
        uint256 boughtAt = block.timestamp;
        _finish(board, 0);
        vm.warp(block.timestamp + 1 days);
        _buy(board, 0);
        uint256 exposure = 50 * (block.timestamp - boughtAt);
        assertEq(board.weightSeconds(), exposure);
        assertEq(board.activeWeight(), 0);
        vm.warp(block.timestamp + 90 days);
        _yieldMonth(board, 10e8);
        board.harvest();
        assertEq(board.weightSeconds(), exposure);
        assertEq(monthFactory.unitYieldPerDay(), 10e8 * 1 days / exposure);
        assertEq(_reported(board), 10e8);
    }

    function test_FirstReportOrderWinsAndOlderLateReportCannotTakeOver() public {
        _startFirst(50);
        XMonthBoard second = _freshPreparing();
        address[] memory secondUsers = new address[](second.socketCount());
        for (uint256 i; i < secondUsers.length; ++i) {
            secondUsers[i] = second.socket(i + 1).owner;
        }
        _sellMonth(second, _newUser(), 50);

        _finish(second, 20e8); // 编号 2 先首次报告。
        assertEq(monthFactory.lastYieldBoard(), address(second));
        vm.warp(block.timestamp + 1);
        _finish(board, 10e8); // 编号 1 后首次报告，应成为最新有效样本。
        assertEq(monthFactory.lastYieldBoard(), address(board));
        uint256 currentQuote = monthFactory.unitYieldPerDay();
        uint256 beforeOwed = _sumOwed(second, secondUsers);
        vm.warp(block.timestamp + 1 days);
        _yieldMonth(second, 100e8);
        second.harvest();
        assertEq(monthFactory.lastYieldBoard(), address(board));
        assertEq(monthFactory.unitYieldPerDay(), currentQuote, "older sample cannot become latest by refreshing");
        assertApproxEqAbs(_sumOwed(second, secondUsers) - beforeOwed, 100e8, secondUsers.length);

        _yieldMonth(board, 10e8);
        board.harvest();
        assertEq(monthFactory.lastYieldBoard(), address(board));
        assertEq(monthFactory.unitYieldPerDay(), board.unitYieldPerDay());
        assertEq(_reported(board), 20e8);
    }

    function test_EmptyBoardDoesNotHideOlderSampleThatCanRecover() public {
        _startFirst(50);
        _finish(board, 0);
        XMonthBoard empty = _freshPreparing();
        assertEq(empty.buyPriceCap(), 0);
        vm.warp(empty.prepEnd());
        empty.sync();
        assertEq(uint256(empty.state()), uint256(MonthState.Settling));
        assertFalse(monthFactory.yieldReported(address(empty)));
        assertEq(monthFactory.lastYieldBoard(), address(board));
        _yieldMonth(board, 10e8);
        board.harvest();
        assertGt(monthFactory.unitYieldPerDay(), 0);
        XMonthBoard restored = _freshPreparing();
        assertGt(restored.buyPriceCap(), 0);
        _sellMonth(restored, _newUser(), 10);
    }

    function test_RepeatedOrZeroHarvestAndForgedReportsCannotChangeQuote() public {
        _startFirst(50);
        _finish(board, 10e8);
        uint256 quote = monthFactory.unitYieldPerDay();
        uint256 income = board.yieldReceived();
        uint256 reported = _reported(board);
        vm.warp(block.timestamp + 1 days);
        board.harvest();
        board.harvest();
        _yieldMonth(board, 0);
        board.sweep();
        assertEq(monthFactory.unitYieldPerDay(), quote, "elapsed time alone does not publish a new sample");
        assertEq(board.yieldReceived(), income);
        assertEq(_reported(board), reported);

        (bool outsiderAccepted,) = address(monthFactory).call(abi.encodeWithSignature("reportYield(uint256)", quote));
        assertFalse(outsiderAccepted);
        vm.prank(address(board));
        (bool forgedAccepted,) = address(monthFactory).call(abi.encodeWithSignature("reportYield(uint256)", quote + 1));
        assertFalse(forgedAccepted, "registered board cannot publish a made-up per-day value");
        uint256 currentPerDay = board.unitYieldPerDay();
        vm.prank(address(board));
        (bool replayAccepted,) =
            address(monthFactory).call(abi.encodeWithSignature("reportYield(uint256)", currentPerDay));
        assertTrue(
            !replayAccepted || monthFactory.unitYieldPerDay() == quote, "empty replay may only be rejected or ignored"
        );
        assertEq(monthFactory.unitYieldPerDay(), quote);
        assertEq(_reported(board), reported);
        assertEq(monthFactory.lastYieldBoard(), address(board));
    }

    function test_IncomeAfterClaimsCloseIsBurnedWithoutUpdatingQuote() public {
        _startFirst(50);
        _finish(board, 10e8);
        vm.warp(block.timestamp + 1 days);
        _buy(board, 0);
        sales.distribute(address(board), 1, users.length);
        vm.warp(board.finishedAt() + 365 days);
        board.closeClaims();
        uint256 quote = monthFactory.unitYieldPerDay();
        uint256 income = board.yieldReceived();
        uint256 reported = _reported(board);
        uint256 deadBefore = bem.balanceOf(DEAD);
        bem.mint(address(board), 7e8);
        board.harvest();
        assertEq(bem.balanceOf(DEAD) - deadBefore, 7e8, "v2: burned after the claim window");
        assertEq(board.yieldReceived(), income);
        assertEq(_reported(board), reported);
        assertEq(monthFactory.unitYieldPerDay(), quote);
        assertEq(monthFactory.lastYieldBoard(), address(board));
        assertEq(bem.balanceOf(address(board)), 0);
        assertEq(board.accountedBalance(), 0);
    }
}
