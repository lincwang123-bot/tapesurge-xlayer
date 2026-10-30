// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// 从 BSC v2.0-audit.6 contracts/test/MonthPrizeSplit.t.sol 移植（V2-PORT.md）：产出改为模拟跨链到账（_yieldMonth），其余用例不变。

import {Fixture} from "./utils/Fixture.sol";
import {XMonthBoard as MonthBoard} from "../src/XMonthBoard.sol";
import {MonthState} from "../src/interfaces/IXMonthBoard.sol";

/// @title 月局奖金池一半按投入比例、一半抽奖（规则决定 6.20，v2.0-rc4）
contract MonthPrizeSplitTest is Fixture {
    MonthBoard internal m;
    address[] internal users;

    function setUp() public override {
        super.setUp();
        _startGenesis();
        m = _monthBoard();
        users = _fillMonth(m);
        _sellMonth(m, _newUser(), 30);
        _sellMonth(m, _newUser(), 20);
        vm.warp(m.prepEnd());
        m.sync();
        assertEq(uint256(m.state()), uint256(MonthState.Mining));
    }

    /// @dev 注入 amount 的产出（两台各一半），挖完 30 天并请求开奖、交付随机数
    function _toDrawn(uint256 amount, uint256 word) internal returns (uint256 pot) {
        _yieldMonth(m, amount / 2);
        _yieldMonth(m, amount - amount / 2);
        vm.warp(m.miningEnd());
        m.drawPrizes();
        pot = m.prizePool();
        rng.fulfill(m.pendingRequestId(), word);
    }

    function _owedAll() internal view returns (uint256 t) {
        for (uint256 s = 1; s <= m.socketCount(); s++) {
            t += m.owed(s);
        }
    }

    function _prizesOf(uint256 slot) internal view returns (uint256 t) {
        for (uint256 k = 0; k < 5; k++) {
            if (m.winnerSlots(k) == slot) t += m.prizeAmounts(k);
        }
    }

    /// @dev 守恒（一分不差）：推送出去的正好是抽奖的一半 pot / 2；按比例的一半 pot − pot / 2（奇数时多 1 个最小单位）
    ///      和没花完的资本一起记入负债；各持仓可领合计只差取整尘埃（≤ 持仓数）
    function testFuzz_HalfDrawnHalfSharedExactly(uint256 amount, uint256 word) public {
        amount = bound(amount, 1, 1_000 * BEM_1);
        uint256 pot = _toDrawn(amount, word);
        uint256 idle = m.budget();
        uint256 bal0 = bem.balanceOf(address(m));
        uint256 liab0 = m.liabilities();
        m.finalizePrizes();
        uint256 drawn;
        for (uint256 k = 0; k < 5; k++) {
            drawn += m.prizeAmounts(k);
        }
        assertEq(drawn, pot / 2, "drawn half = floor(pot / 2)");
        assertEq(bal0 - bem.balanceOf(address(m)), drawn, "only the drawn half leaves the board");
        assertEq(m.liabilities() - liab0, (pot - pot / 2) + idle, "shared half (rounded up) + idle capital owed");
        uint256 owed = _owedAll();
        assertLe(owed, m.liabilities());
        assertGe(owed + m.socketCount(), m.liabilities(), "only rounding dust unallocated");
        assertEq(m.prizePool(), 0);
    }

    /// @dev 奇数奖金池：按比例的一半多 1 个最小单位，抽奖的一半向下取整
    function test_OddPotRounding() public {
        uint256 pot = _toDrawn(10 * BEM_1 + 1, 7);
        assertEq(pot % 2, 1, "odd pot");
        uint256 liab0 = m.liabilities();
        uint256 idle = m.budget();
        m.finalizePrizes();
        uint256 drawn;
        for (uint256 k = 0; k < 5; k++) {
            drawn += m.prizeAmounts(k);
        }
        assertEq(drawn, (pot - 1) / 2);
        assertEq(m.liabilities() - liab0 - idle, (pot + 1) / 2);
    }

    /// @dev 中奖的持仓：奖金直接推送，同时照样按投入比例拿到另一半里自己的那一份
    function test_WinnersAlsoGetTheirProRataShare() public {
        uint256 pot = _toDrawn(20 * BEM_1, 99);
        m.finalizePrizes();
        uint256 slot = m.winnerSlots(0);
        address owner = m.socket(slot).owner;
        assertGt(_prizesOf(slot), 0);
        // 按比例的一半：stake / totalStake × (pot − pot / 2)；另外还有没花完的资本按比例退还
        uint256 shared = (pot - pot / 2) * m.socket(slot).stake / m.totalStake();
        assertGe(m.owed(slot), shared, "winner still owed its pro-rata share");
        // 一个没中奖的持仓：可领 = 同样的比例份额
        for (uint256 s = 1; s <= m.socketCount(); s++) {
            if (_prizesOf(s) == 0 && m.socket(s).stake == m.socket(slot).stake) {
                assertEq(m.owed(s), m.owed(slot), "same stake, same pro-rata amount, prizes are extra");
                break;
            }
        }
        assertTrue(owner != address(0));
    }

    /// @dev 奖金池为 0（没有产出）：没有可分的，不请求随机数，直接进入结算
    function test_EmptyPot() public {
        vm.warp(m.miningEnd());
        assertEq(m.prizePool(), 0);
        m.drawPrizes();
        assertEq(uint256(m.state()), uint256(MonthState.Settling), "nothing to draw: settles directly");
        assertFalse(m.prizesDrawn());
    }

    /// @dev VRF 停摆（7 天）：不抽奖，奖金池全部按投入比例分（和以前一样）
    function test_VrfStallSharesWholePotProRata() public {
        _yieldMonth(m, 5 * BEM_1);
        _yieldMonth(m, 5 * BEM_1);
        vm.warp(m.miningEnd());
        m.drawPrizes();
        uint256 pot = m.prizePool();
        uint256 idle = m.budget();
        uint256 liab0 = m.liabilities();
        uint256 bal0 = bem.balanceOf(address(m));
        vm.warp(block.timestamp + 7 days);
        m.triggerSafeSettle();
        assertEq(uint256(m.state()), uint256(MonthState.Settling));
        assertFalse(m.prizesDrawn());
        assertEq(bem.balanceOf(address(m)), bal0, "nothing pushed");
        assertEq(m.liabilities() - liab0, pot + idle, "whole pot shared pro rata");
    }
}
