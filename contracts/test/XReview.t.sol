// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {XMonthBoard} from "../src/XMonthBoard.sol";
import {MonthState} from "../src/interfaces/IXMonthBoard.sol";

/// @notice 独立复核到账与资本归类边界，以及跨链迟到收入后的采购恢复。
contract XReviewTest is Fixture {
    XMonthBoard internal board;
    address[] internal users;

    function setUp() public override {
        super.setUp();
        board = _startGenesis();
    }

    function _mining() internal {
        users = _fillMonth(board);
        _sellMonth(board, _newUser(), 50);
        vm.warp(board.prepEnd());
        board.sync();
    }

    function _owed() internal view returns (uint256 sum) {
        for (uint256 i; i < users.length; ++i) {
            sum += _mOwed(board, users[i]);
        }
    }

    function test_PendingYieldBeforeSubsidyIsNotCapital() public {
        _mining();
        _yieldMonth(board, 7e8);
        uint256 budgetBefore = board.budget();
        bem.mint(address(splitter), 3e8);
        vm.startPrank(address(splitter));
        bem.approve(address(board), 3e8);
        board.depositSubsidy(3e8);
        vm.stopPrank();
        assertEq(board.prizePool(), 7e8);
        assertEq(board.yieldReceived(), 7e8);
        assertEq(board.subsidyCapital(), 3e8);
        assertEq(board.budget(), budgetBefore + 3e8);
        assertEq(board.accountedBalance(), bem.balanceOf(address(board)));
    }

    function test_UnharvestedIncomeAfterRandomnessIsSharedExactlyOnce() public {
        _mining();
        vm.warp(board.miningEnd());
        _yieldMonth(board, 10e8);
        board.drawPrizes();
        rng.fulfill(board.pendingRequestId(), 12);
        _yieldMonth(board, 7e8);
        board.finalizePrizes();
        assertEq(bem.balanceOf(FOUNDATION), 0, "v2: no 3%");
        // v2：奖金池一半（5 BEM）按比例记给持仓，加上请求后到账的 7 BEM
        uint256 expected = board.totalStake() - board.totalSpent() + 5e8 + 7e8;
        assertApproxEqAbs(_owed(), expected, users.length);
        uint256 owedBefore = _owed();
        board.harvest();
        board.harvest();
        assertEq(_owed(), owedBefore);
        assertEq(board.accountedBalance(), bem.balanceOf(address(board)));
    }

    function test_SafeSettleCombinesFrozenAndLateIncomeWithoutFees() public {
        _mining();
        vm.warp(board.miningEnd());
        _yieldMonth(board, 10e8);
        board.drawPrizes();
        _yieldMonth(board, 7e8);
        vm.warp(block.timestamp + 7 days);
        board.triggerSafeSettle();
        assertEq(bem.balanceOf(FOUNDATION), 0);
        assertEq(bem.balanceOf(FEE_SAFE), board.totalEntryFees());
        assertApproxEqAbs(_owed(), board.totalStake() - board.totalSpent() + 17e8, users.length);
        assertEq(board.accountedBalance(), bem.balanceOf(address(board)));
    }

    function test_EmptySettledBoardSharesLateIncomeWithoutReportingSample() public {
        users = _fillMonth(board);
        vm.warp(board.prepEnd());
        board.sync();
        assertEq(uint256(board.state()), uint256(MonthState.Settling));
        assertEq(board.weightSeconds(), 0);

        _yieldMonth(board, 7e8);
        board.harvest();
        board.sweep();
        assertEq(board.yieldReceived(), 7e8);
        assertFalse(monthFactory.yieldReported(address(board)));
        assertFalse(monthFactory.hasYieldReport());
        assertEq(monthFactory.lastYieldBoard(), address(0));
        // 没挖矿就结算：入场费也退还
        assertApproxEqAbs(_owed(), board.totalStake() + board.totalEntryFees() + 7e8, users.length);

        uint256 paid;
        for (uint256 i; i < users.length; ++i) {
            uint256 beforeBalance = bem.balanceOf(users[i]);
            uint256 claimed = _mClaimAll(board, users[i]);
            assertEq(bem.balanceOf(users[i]) - beforeBalance, claimed);
            paid += claimed;
        }
        assertApproxEqAbs(paid, board.totalStake() + board.totalEntryFees() + 7e8, users.length);
        assertEq(_owed(), 0);
        assertLe(bem.balanceOf(address(board)), users.length);
        assertEq(board.accountedBalance(), bem.balanceOf(address(board)));
    }

    /// @dev 用户批准：零样本之后的迟到收入更新未来局，已经开局的零报价不能改写。
    function test_LateIncomeAfterZeroReportRestoresOnlyFutureAcquisitions() public {
        _mining();
        vm.warp(board.miningEnd());
        board.drawPrizes();
        assertEq(uint256(board.state()), uint256(MonthState.Settling));
        assertTrue(monthFactory.hasYieldReport());
        assertEq(monthFactory.unitYieldPerDay(), 0);

        _monthBoard().closeRecruitment();
        XMonthBoard next = _monthBoard();
        _fillMonth(next);
        assertEq(next.buyPriceCap(), 0);

        _yieldMonth(board, 30e8);
        board.harvest();
        assertGt(monthFactory.unitYieldPerDay(), 0, "late income restores the rate for future boards");
        assertEq(next.buyPriceCap(), 0, "a started board keeps its original cap snapshot");
        vm.warp(next.prepEnd());
        next.sync(); // 无持有样本的空局不能覆盖已经恢复的报价
        assertFalse(monthFactory.yieldReported(address(next)));
        _monthBoard().closeRecruitment();
        XMonthBoard later = _monthBoard();
        _fillMonth(later);
        assertGt(later.buyPriceCap(), 0);
        (uint256 id,) = _newMachine(address(this), 50);
        machines.approve(address(later), id);
        _feedDefault();
        later.sellMachine(address(machines), id, 0);
        assertEq(machines.ownerOf(id), address(later), "a future board can acquire RIG again");
    }
}
