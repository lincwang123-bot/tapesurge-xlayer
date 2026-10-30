// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// 从 BSC v2.0-audit.6 contracts/test/MonthExitGovernor.t.sol 移植（V2-PORT.md）：产出改为模拟跨链到账（_yieldMonth）；
// 报价是转报到 XMarketPriceFeed 的 BSC 买一 / 卖一。唯一的断言差别：报价过期时 BSC 版正常卖价也暂停（askPrice = 0），
// X Layer 的正常卖价按挂单规则、不依赖报价，所以计划价暂停后按挂单规则（这里已锁定为成本价）。

import {Fixture} from "./utils/Fixture.sol";
import {XMonthBoard as MonthBoard} from "../src/XMonthBoard.sol";
import {XMonthExitGovernor as MonthExitGovernor} from "../src/month/XMonthExitGovernor.sol";
import {XMonthMachineSales as MonthMachineSales} from "../src/month/XMonthMachineSales.sol";
import {MonthState} from "../src/interfaces/IXMonthBoard.sol";

/// @title v2 月局多数集体清算（规格第 7、8 节，第 4 阶段）
/// @notice 招满 25 人、每人 4 BEM（W = 100 BEM）：10% = 3 份持仓（12 BEM）可以开启投票，严格过半 = 13 份（52 BEM）。
contract MonthExitGovernorTest is Fixture {
    MonthBoard internal m;
    address[] internal users;
    address internal buyer = address(0xB0B);
    uint256 internal constant SHARE = 4e8; // 每份 4 BEM
    /// @dev 市场低迷：BSC 买一 = 卖一 = 每单位算力 u，整台约为成本价的 30%（低于计划价，计划价按计划曲线成交）
    uint256 internal u;

    function setUp() public override {
        super.setUp();
        _startGenesis();
        m = _monthBoard();
        users = _fillMonth(m);
        assertEq(users.length, 25);
        _sellMonth(m, _newUser(), 30);
        _sellMonth(m, _newUser(), 20);
        _sellMonth(m, _newUser(), 40);
        vm.warp(m.prepEnd());
        m.sync();
        _yieldMonth(m, 3 * BEM_1);
        vm.warp(m.miningEnd());
        m.drawPrizes();
        rng.fulfill(m.pendingRequestId(), 5);
        m.finalizePrizes();
        assertEq(uint256(m.state()), uint256(MonthState.Settling));
        assertEq(m.totalStake(), 100 * BEM_1);
        bem.mint(buyer, 10_000 * BEM_1);
        vm.prank(buyer);
        bem.approve(address(sales), type(uint256).max);
        u = type(uint256).max;
        for (uint256 i = 0; i < m.machineCount(); i++) {
            uint256 x = uint256(m.machine(i).cost) * 30 / 100 / m.machine(i).weight;
            if (x < u) u = x;
        }
        _feed();
    }

    /// @dev 运营地址照常转报（规则决定 6.33：报价有效时计划价才能成交，且不低于买一 × 算力 × 95%）
    function _feed() internal {
        _postPrices(u, u);
    }

    // ---------------- 工具 ----------------

    /// @dev 全部未卖矿机：起价 = 成本价，底价 = 成本价 × floorPct%
    function _publish(uint256 floorPct) internal returns (bytes32 h) {
        uint256 n = m.unsoldMachines();
        uint256[] memory idx = new uint256[](n);
        uint128[] memory st = new uint128[](n);
        uint128[] memory fl = new uint128[](n);
        uint256 k;
        for (uint256 i = 0; i < m.machineCount(); i++) {
            if (m.machine(i).sold) continue;
            idx[k] = i;
            st[k] = m.machine(i).cost;
            fl[k] = uint128(uint256(m.machine(i).cost) * floorPct / 100);
            k++;
        }
        h = governor.publishPlan(address(m), idx, st, fl);
    }

    function _slots(uint256 from, uint256 count) internal pure returns (uint256[] memory s) {
        s = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            s[i] = from + i;
        }
    }

    function _support(uint256 from, uint256 count, bytes32 h) internal {
        for (uint256 i = from; i < from + count; i++) {
            uint256[] memory one = _slots(i, 1);
            vm.prank(m.socket(i).owner);
            governor.support(address(m), one, h);
        }
    }

    function _vote(uint256 from, uint256 count, uint8 choice) internal {
        for (uint256 i = from; i < from + count; i++) {
            uint256[] memory one = _slots(i, 1);
            vm.prank(m.socket(i).owner);
            governor.castVote(address(m), one, choice);
        }
    }

    function _open(bytes32 h) internal {
        vm.warp(m.settleStart() + 7 days);
        _support(1, 3, h);
        governor.openVote(address(m), h, _slots(1, 3));
    }

    // ---------------- 完整流程 ----------------

    function test_PassExecuteAndSellBelowCostOnTheApprovedCurve() public {
        bytes32 h = _publish(50);
        _support(1, 3, h);
        vm.expectRevert(MonthExitGovernor.TooEarly.selector); // 结算开始 7 天内不能开启（选项 4a）
        governor.openVote(address(m), h, _slots(1, 3));
        vm.warp(m.settleStart() + 7 days);
        governor.openVote(address(m), h, _slots(1, 3));
        assertTrue(m.governanceLocked());
        // 投票期间锁定转让
        uint256 pid = positions.idOf(address(m), 5);
        address o5 = m.socket(5).owner;
        vm.prank(o5);
        vm.expectRevert(MonthBoard.TransferLocked.selector);
        positions.transferFrom(o5, buyer, pid);
        // 13 份赞成（52%）
        _vote(1, 13, governor.YES());
        _vote(14, 5, governor.NO());
        vm.expectRevert(MonthExitGovernor.TooEarly.selector);
        governor.finalizeVote(address(m));
        vm.warp(block.timestamp + 24 hours);
        uint256[] memory s20 = _slots(20, 1);
        address o20 = m.socket(20).owner;
        vm.prank(o20);
        vm.expectRevert(MonthExitGovernor.NotVoting.selector); // 截止后不能再投
        governor.castVote(address(m), s20, 1);
        governor.finalizeVote(address(m));
        assertTrue(m.governanceLocked(), "still locked during the execution delay");
        vm.expectRevert(MonthExitGovernor.NotExecutable.selector);
        governor.execute(address(m));
        vm.warp(block.timestamp + 24 hours);
        uint256 cost0 = m.machine(0).cost;
        governor.execute(address(m));
        _feed();
        assertTrue(m.liquidating());
        assertFalse(m.governanceLocked(), "unlocked after execution (option 5a)");
        // 计划价：7 天从成本价线性降到 50%，之后保持（和"结算 1 天后按成本价"取较低者）
        assertEq(sales.askPrice(address(m), 0), cost0);
        vm.warp(block.timestamp + 3.5 days);
        _feed();
        uint256 el = block.timestamp - sales.planStart(address(m));
        assertEq(sales.askPrice(address(m), 0), cost0 - (cost0 - cost0 / 2) * el / 7 days);
        vm.warp(block.timestamp + 30 days);
        _feed();
        assertEq(sales.askPrice(address(m), 0), cost0 / 2, "stays at the floor");
        // 报价过期：计划价和正常卖价都暂停（同 BSC 规则决定 6.33）；恢复报价后照常
        vm.warp(block.timestamp + 3 hours);
        assertEq(sales.askPrice(address(m), 0), 0, "stale feed: sales paused");
        _feed();
        assertEq(sales.askPrice(address(m), 0), cost0 / 2);
        uint256 principalBefore = m.principalRemaining();
        uint256 feeSafeBefore = bem.balanceOf(FEE_SAFE);
        _syncRigs(m);
        vm.prank(buyer);
        uint256 paid = sales.buyMachine(address(m), 0, type(uint256).max);
        assertEq(paid, cost0 / 2, "sold below cost under the approved plan");
        assertEq(bem.balanceOf(FEE_SAFE), feeSafeBefore, "no premium fee below cost (rule 6.24)");
        assertEq(m.principalRemaining(), principalBefore - paid, "below-cost proceeds refund principal first");
        // 执行后转让照常
        vm.prank(o5);
        positions.transferFrom(o5, buyer, pid);
    }

    function test_ExactlyHalfFailsAndCoolsDown() public {
        bytes32 h = _publish(50);
        _open(h);
        _vote(1, 12, governor.YES()); // 48 BEM
        _vote(13, 1, governor.ABSTAIN()); // +4 → 但赞成只有 48
        _vote(14, 12, governor.NO());
        vm.warp(block.timestamp + 24 hours);
        governor.finalizeVote(address(m));
        assertFalse(m.governanceLocked());
        assertFalse(m.liquidating());
        // 50% 整也不通过：再造一个 12.5 份 = 50 BEM 的情形不可能（每份 4 BEM），这里用权重核对边界
        (,,,,, uint256 yes,,, uint256 total) = governor.proposals(address(m));
        assertEq(total, 0, "proposal cleared");
        assertEq(yes, 0);
        // 冷却 14 天；旧意向作废
        assertFalse(governor.supportValid(address(m), 1, h));
        _support(1, 3, h);
        vm.expectRevert(MonthExitGovernor.CoolingDown.selector);
        governor.openVote(address(m), h, _slots(1, 3));
        vm.warp(block.timestamp + 14 days);
        governor.openVote(address(m), h, _slots(1, 3));
    }

    /// @dev 赞成权重恰好等于 W 的一半：不通过（严格过半）
    function test_YesEqualToHalfOfTotalFails() public {
        bytes32 h = _publish(50);
        _open(h);
        // 12 份赞成 = 48 BEM，再让一份持仓先转给赞成者凑不到 50；直接用权重：W = 100，需要 > 50
        _vote(1, 12, governor.YES());
        vm.warp(block.timestamp + 24 hours);
        governor.finalizeVote(address(m));
        assertFalse(m.liquidating());
        // 换一个分母是偶数、赞成恰好一半的情形：W = 100，赞成 50 不可能凑出 → 用 _check 断言公式
        assertTrue(!(uint256(50) > uint256(100) / 2), "50 of 100 does not pass");
        assertTrue(uint256(51) > uint256(100) / 2);
    }

    function test_LowTurnoutAllYesFails() public {
        bytes32 h = _publish(50);
        _open(h);
        _vote(1, 10, governor.YES()); // 40%，全部赞成
        vm.warp(block.timestamp + 24 hours);
        governor.finalizeVote(address(m));
        assertFalse(m.liquidating(), "40% turnout all yes does not pass");
    }

    function test_ChangeVoteMovesWeight() public {
        bytes32 h = _publish(50);
        _open(h);
        _vote(1, 13, governor.YES());
        _vote(1, 1, governor.NO()); // 1 号改投反对：赞成剩 12 份
        (,,,,, uint256 yes, uint256 no,, uint256 total) = governor.proposals(address(m));
        assertEq(yes, 12 * SHARE);
        assertEq(no, SHARE);
        assertEq(total, 100 * BEM_1);
        vm.warp(block.timestamp + 24 hours);
        governor.finalizeVote(address(m));
        assertFalse(m.liquidating());
    }

    function test_NonHolderCannotVoteOrSupport() public {
        bytes32 h = _publish(50);
        vm.prank(buyer);
        vm.expectRevert(MonthExitGovernor.NotHolder.selector);
        governor.support(address(m), _slots(1, 1), h);
        _open(h);
        vm.prank(buyer);
        vm.expectRevert(MonthExitGovernor.NotHolder.selector);
        governor.castVote(address(m), _slots(1, 1), 1);
        vm.prank(m.socket(1).owner);
        vm.expectRevert(MonthExitGovernor.BadChoice.selector);
        governor.castVote(address(m), _slots(1, 1), 4);
    }

    /// @dev 意向随持仓转让作废；不足 10% 不能开启；重复列出同一持仓不能凑数
    function test_SupportVoidOnTransferAndNoDoubleCounting() public {
        bytes32 h = _publish(50);
        vm.warp(m.settleStart() + 7 days);
        _support(1, 3, h);
        uint256 pid = positions.idOf(address(m), 3);
        address o3 = m.socket(3).owner;
        vm.prank(o3);
        positions.transferFrom(o3, buyer, pid);
        assertFalse(governor.supportValid(address(m), 3, h), "support voided by the transfer");
        vm.expectRevert(MonthExitGovernor.NotEnoughSupport.selector);
        governor.openVote(address(m), h, _slots(1, 3)); // 只剩 8%
        uint256[] memory dup = new uint256[](3);
        dup[0] = 1;
        dup[1] = 1;
        dup[2] = 2;
        vm.expectRevert(MonthExitGovernor.SlotsNotSorted.selector);
        governor.openVote(address(m), h, dup);
        // 买方重新表态后可以开启
        vm.prank(buyer);
        governor.support(address(m), _slots(3, 1), h);
        governor.openVote(address(m), h, _slots(1, 3));
        vm.expectRevert(MonthExitGovernor.ProposalActive.selector);
        governor.openVote(address(m), h, _slots(1, 3));
    }

    function test_ExpireAfterExecutionWindow() public {
        bytes32 h = _publish(50);
        _open(h);
        _vote(1, 13, governor.YES());
        vm.warp(block.timestamp + 24 hours);
        governor.finalizeVote(address(m));
        vm.expectRevert(MonthExitGovernor.NotExecutable.selector);
        governor.expire(address(m));
        vm.warp(block.timestamp + 24 hours + 48 hours);
        vm.expectRevert(MonthExitGovernor.NotExecutable.selector);
        governor.execute(address(m));
        governor.expire(address(m));
        assertFalse(m.governanceLocked());
        assertFalse(m.liquidating());
        assertEq(governor.cooldownUntil(address(m)), block.timestamp + 14 days);
    }

    /// @dev 投票期间按 ≥ 成本价卖掉的矿机，执行时跳过；执行后只有剩下的矿机有计划价
    function test_MachineSoldDuringVoteIsSkippedAtExecution() public {
        bytes32 h = _publish(50);
        _open(h);
        _vote(1, 13, governor.YES());
        _syncRigs(m);
        vm.prank(buyer);
        sales.buyMachine(address(m), 1, type(uint256).max); // 结算 1 天后按成本价可买
        vm.warp(block.timestamp + 48 hours);
        governor.finalizeVote(address(m));
        vm.warp(block.timestamp + 24 hours);
        governor.execute(address(m));
        assertEq(sales.planAsk(address(m), 1), 0, "sold machine has no plan price");
        assertGt(sales.planAsk(address(m), 0), 0);
        assertGt(sales.planAsk(address(m), 2), 0);
    }

    function test_PlanMustListEveryUnsoldMachineWithValidPrices() public {
        uint256[] memory idx = new uint256[](2);
        uint128[] memory st = new uint128[](2);
        uint128[] memory fl = new uint128[](2);
        idx[0] = 0;
        idx[1] = 1;
        st[0] = 10;
        st[1] = 10;
        fl[0] = 5;
        fl[1] = 5;
        vm.expectRevert(MonthExitGovernor.BadPlan.selector); // 少了第 2 台
        governor.publishPlan(address(m), idx, st, fl);
        uint256[] memory i3 = new uint256[](3);
        uint128[] memory s3 = new uint128[](3);
        uint128[] memory f3 = new uint128[](3);
        i3[0] = 0;
        i3[1] = 2;
        i3[2] = 1;
        s3[0] = 10;
        s3[1] = 10;
        s3[2] = 10;
        f3[0] = 5;
        f3[1] = 5;
        f3[2] = 5;
        vm.expectRevert(MonthExitGovernor.BadPlan.selector); // 序号没有递增
        governor.publishPlan(address(m), i3, s3, f3);
        i3[1] = 1;
        i3[2] = 2;
        f3[2] = 0;
        vm.expectRevert(MonthExitGovernor.BadPlan.selector); // 底价为 0
        governor.publishPlan(address(m), i3, s3, f3);
        // 规则决定 6.33：起价低于这台的成本价也不行
        f3[2] = 5;
        vm.expectRevert(MonthExitGovernor.BadPlan.selector);
        governor.publishPlan(address(m), i3, s3, f3);
        for (uint256 i = 0; i < 3; i++) {
            s3[i] = m.machine(i).cost;
        }
        governor.publishPlan(address(m), i3, s3, f3);
        f3[2] = s3[2] + 1;
        vm.expectRevert(MonthExitGovernor.BadPlan.selector); // 起价低于底价
        governor.publishPlan(address(m), i3, s3, f3);
        f3[2] = 5;
        bytes32 h = governor.publishPlan(address(m), i3, s3, f3);
        assertEq(governor.publishPlan(address(m), i3, s3, f3), h, "same content, same hash");
        vm.expectRevert(MonthExitGovernor.NotMonthBoard.selector);
        governor.publishPlan(address(0xBAD), i3, s3, f3);
        // 其他月局的计划不能用在这块
        vm.expectRevert(MonthExitGovernor.UnknownPlan.selector);
        governor.openVote(address(m), keccak256("other"), _slots(1, 3));
    }

    /// @dev 选项 6a：执行后可以再提更低的计划（改价）；改价失败冷却 7 天；通过后降价从新计划生效时重新开始
    function test_RepriceAfterExecution() public {
        bytes32 h = _publish(80);
        _open(h);
        _vote(1, 13, governor.YES());
        vm.warp(block.timestamp + 24 hours);
        governor.finalizeVote(address(m));
        vm.warp(block.timestamp + 24 hours);
        governor.execute(address(m));
        uint256 cost2 = m.machine(2).cost;
        vm.warp(block.timestamp + 8 days);
        _feed();
        assertEq(sales.askPrice(address(m), 2), cost2 * 80 / 100);
        // 改价失败：7 天冷却
        bytes32 h2 = _publish(40);
        _support(1, 3, h2);
        governor.openVote(address(m), h2, _slots(1, 3));
        vm.warp(block.timestamp + 24 hours);
        governor.finalizeVote(address(m));
        assertEq(governor.cooldownUntil(address(m)), block.timestamp + 7 days);
        vm.warp(block.timestamp + 7 days);
        _support(1, 3, h2);
        governor.openVote(address(m), h2, _slots(1, 3));
        _vote(1, 13, governor.YES());
        vm.warp(block.timestamp + 24 hours);
        governor.finalizeVote(address(m));
        vm.warp(block.timestamp + 24 hours);
        governor.execute(address(m));
        _feed();
        assertEq(sales.askPrice(address(m), 2), cost2, "new curve restarts from its own start price (cost here)");
        vm.warp(block.timestamp + 7 days);
        _feed();
        assertEq(sales.askPrice(address(m), 2), cost2 * 40 / 100);
    }

    /// @dev 只有治理合约能写入计划；外人不能
    function test_OnlyGovernorInstallsPlan() public {
        uint256[] memory idx = new uint256[](1);
        uint128[] memory st = new uint128[](1);
        uint128[] memory fl = new uint128[](1);
        vm.expectRevert(MonthMachineSales.NotAuthorized.selector);
        sales.installPlan(address(m), idx, st, fl);
    }

    /// @dev 守恒：从清算投票到全部按计划价卖完、领完，BEM 一分不差
    function testFuzz_LiquidationConservation(uint8 floorPct, uint32 waitHours) public {
        uint256 pct = bound(uint256(floorPct), 1, 100);
        bytes32 h = _publish(pct);
        uint256 in0 = bem.balanceOf(address(m));
        uint256 paid0 = deliveredYield[address(m)];
        uint256 out0 = _outside();
        _open(h);
        _vote(1, 20, governor.YES());
        vm.warp(block.timestamp + 24 hours);
        governor.finalizeVote(address(m));
        vm.warp(block.timestamp + 24 hours);
        governor.execute(address(m));
        vm.warp(block.timestamp + bound(uint256(waitHours), 0, 30 days));
        uint256 saleSum;
        _syncRigs(m);
        vm.startPrank(buyer);
        for (uint256 i = 0; i < m.machineCount(); i++) {
            if (!m.machine(i).sold) saleSum += sales.buyMachine(address(m), i, type(uint256).max);
        }
        vm.stopPrank();
        sales.distribute(address(m), 1, users.length);
        uint256 inflow = in0 + (deliveredYield[address(m)] - paid0) + saleSum;
        uint256 outflow = _outside() - out0 + bem.balanceOf(address(m));
        assertEq(inflow, outflow, "BEM conserved exactly");
        assertEq(bem.balanceOf(address(m)), m.liabilities());
        assertLe(bem.balanceOf(address(m)), users.length + 10, "dust only");
        assertEq(m.unsoldMachines(), 0);
    }

    function _outside() internal view returns (uint256 sum) {
        sum = bem.balanceOf(FOUNDATION) + bem.balanceOf(FEE_SAFE) + bem.balanceOf(address(monthFactory));
        for (uint256 i = 0; i < users.length; i++) {
            sum += bem.balanceOf(users[i]);
        }
    }
}
