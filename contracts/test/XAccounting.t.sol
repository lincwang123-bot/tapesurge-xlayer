// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {XMonthBoard} from "../src/XMonthBoard.sol";
import {XMonthFactory} from "../src/XMonthFactory.sol";
import {XHub} from "../src/XHub.sol";
import {MonthState} from "../src/interfaces/IXMonthBoard.sol";

/// @notice 覆盖 X Layer 独有风险：无回调入账、开奖后跨链迟到收益、零收益定价样本。
contract XAccountingTest is Fixture {
    XMonthBoard internal m;
    address[] internal users;

    function setUp() public override {
        super.setUp();
        m = _startGenesis();
    }

    function _mining() internal {
        users = _fillMonth(m);
        _sellMonth(m, _newUser(), 50);
        vm.warp(m.prepEnd());
        m.sync();
    }

    function _settle(uint256 amount) internal {
        _mining();
        vm.warp(m.miningEnd());
        if (amount != 0) _yieldMonth(m, amount);
        m.drawPrizes();
        if (m.state() == MonthState.Drawing) {
            rng.fulfill(m.pendingRequestId(), 12345);
            m.finalizePrizes();
        }
    }

    function test_EntryAndMachinePurchaseAreNotYield() public {
        _mining();
        assertEq(m.yieldReceived(), 0);
        assertEq(m.prizePool(), 0);
        assertEq(m.accountedBalance(), bem.balanceOf(address(m)));
        assertEq(m.budget() + m.totalSpent(), m.totalStake());
        assertEq(bem.balanceOf(FEE_SAFE), m.totalEntryFees());
    }

    function test_DrawingFreezesPrizeAndSharesDelayedIncome() public {
        _mining();
        vm.warp(m.miningEnd());
        _yieldMonth(m, 10e8);
        m.drawPrizes();
        assertEq(m.prizePool(), 10e8);
        _yieldMonth(m, 7e8);
        m.harvest();
        assertEq(m.prizePool(), 10e8, "signature can already be public; do not change prize stakes");
        rng.fulfill(m.pendingRequestId(), 12345);
        m.finalizePrizes();
        assertEq(uint256(m.state()), uint256(MonthState.Settling));
        assertEq(m.accountedBalance(), bem.balanceOf(address(m)));
        uint256 owed;
        for (uint256 i; i < users.length; ++i) {
            owed += _mOwed(m, users[i]);
        }
        // v2：奖金池不扣费，一半（5 BEM）按比例记给持仓；开奖请求后到账的 7 BEM 也按比例分
        assertApproxEqAbs(owed, m.totalStake() - m.totalSpent() + 5e8 + 7e8, users.length);
        assertEq(bem.balanceOf(FOUNDATION) + m.credit(FOUNDATION), 0, "no 3% in v2");
    }

    function test_ZeroYieldSampleNeverResetsToDeploymentCap() public {
        _settle(0);
        assertTrue(monthFactory.hasYieldReport());
        assertEq(monthFactory.unitYieldPerDay(), 0);
        _monthBoard().closeRecruitment();
        XMonthBoard next = _monthBoard();
        _fillMonth(next);
        assertEq(next.buyPriceCap(), 0);
        (uint256 id,) = _newMachine(address(this), 50);
        machines.approve(address(next), id);
        vm.expectRevert(XMonthBoard.PriceUnavailable.selector);
        next.sellMachine(address(machines), id, 0);
    }

    function test_NoMachinesIsNotAZeroYieldSample() public {
        _fillMonth(m);
        vm.warp(m.prepEnd());
        m.sync();
        assertFalse(monthFactory.hasYieldReport(), "no weight-time exposure means no yield sample");
    }

    function test_ReportsRequireSettledOfficialBoardAndCannotReplay() public {
        vm.expectRevert(XMonthFactory.InvalidYieldReport.selector);
        monthFactory.reportYield(1e8);
        vm.prank(address(m));
        vm.expectRevert(XMonthFactory.InvalidYieldReport.selector);
        monthFactory.reportYield(1e8);
        _settle(10e8);
        vm.prank(address(m));
        vm.expectRevert(XMonthFactory.InvalidYieldReport.selector);
        monthFactory.reportYield(100e8);
    }

    function test_OperatorCanOnlyBeRotatedByFeeRecipient() public {
        vm.expectRevert(XHub.OnlyFeeSafe.selector);
        factory.setOperator(address(0xBEEF));
        vm.prank(FEE_SAFE);
        factory.setOperator(address(0xBEEF));
        assertEq(factory.operator(), address(0xBEEF));
    }

    function test_SealedClaimWindowStillSweepsVeryLateDelivery() public {
        _settle(10e8);
        vm.warp(m.settleStart() + 1 days);
        address buyer = _newUser();
        bem.mint(buyer, 1000e8);
        vm.startPrank(buyer);
        bem.approve(address(sales), type(uint256).max);
        sales.buyMachine(address(m), 0, type(uint256).max);
        vm.stopPrank();
        sales.distribute(address(m), 1, users.length);
        vm.warp(m.finishedAt() + 365 days);
        m.closeClaims();
        uint256 before = bem.balanceOf(DEAD);
        bem.mint(address(m), 3e8); // a final delayed LayerZero payment after every RIG was sold
        m.harvest();
        assertEq(bem.balanceOf(DEAD) - before, 3e8, "v2: burned after the claim window");
        assertEq(bem.balanceOf(address(m)), 0);
        assertEq(m.accountedBalance(), 0);
    }

    function test_DelayedRigPaymentAfterSaleRemainsWithOldBoard() public {
        _settle(10e8);
        uint256 id = m.machine(0).circuitId;
        uint64 claimedAt = uint64(block.timestamp + 1);
        vm.warp(claimedAt + 12 hours); // 购买时 RIG 要在 1 天内同步过
        _feedAtCost(); // BSC 市价低于成本价：按成本价立即可买
        address buyer = _newUser();
        bem.mint(buyer, 1000e8);
        vm.startPrank(buyer);
        bem.approve(address(sales), type(uint256).max);
        sales.buyMachine(address(m), 0, type(uint256).max);
        vm.stopPrank();
        assertEq(machines.ownerOf(id), buyer);
        uint256 before = bem.balanceOf(address(m));
        uint256[] memory ids = new uint256[](1);
        uint256[] memory shares = new uint256[](1);
        uint256[] memory powers = new uint256[](1);
        ids[0] = id;
        shares[0] = 4e8;
        powers[0] = 50;
        bem.mint(address(this), 4e8);
        bem.approve(address(machines), 4e8);
        machines.deliverYield(claimedAt, ids, shares, powers);
        assertEq(bem.balanceOf(address(m)) - before, 4e8);
        m.harvest();
        sales.distribute(address(m), 1, users.length);
        assertLe(bem.balanceOf(address(m)), users.length, "only proportional rounding dust remains");
    }

    function testFuzz_RepeatedHarvestNeverDoubleCounts(uint64 first, uint64 second) public {
        first = uint64(bound(first, 0, 1000e8));
        second = uint64(bound(second, 0, 1000e8));
        _mining();
        _yieldMonth(m, first);
        m.harvest();
        m.harvest();
        _yieldMonth(m, second);
        m.harvest();
        m.harvest();
        assertEq(m.prizePool(), uint256(first) + second);
        assertEq(m.yieldReceived(), uint256(first) + second);
        assertEq(m.accountedBalance(), bem.balanceOf(address(m)));
    }
}
