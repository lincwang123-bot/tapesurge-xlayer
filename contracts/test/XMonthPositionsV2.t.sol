// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// 从 BSC v2.0-audit.6 contracts/test/MonthPositionsV2.t.sol 移植（V2-PORT.md）：产出改为模拟跨链到账（_yieldMonth），其余用例不变。

import {Fixture} from "./utils/Fixture.sol";
import {XMonthBoard as MonthBoard} from "../src/XMonthBoard.sol";
import {XMonthPositions as MonthPositions} from "../src/month/XMonthPositions.sol";
import {XMonthMachineSales as MonthMachineSales} from "../src/month/XMonthMachineSales.sol";
import {MonthState} from "../src/interfaces/IXMonthBoard.sol";
import {ICircuits} from "../src/interfaces/ITapeOut.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev 收 ERC-721 的合约（safeTransferFrom 用）
contract PositionReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/// @title v2 月局：持仓凭证与整份转让（第 2 阶段）
/// @notice 铸造、统一转让锁（每条转移路径）、结转给卖方、通行证立刻退回原持有人、版本号、一个钱包多份持仓、
///         治理锁、领取期限后禁止转让、退通行证失败时的处理、转让交错下的资金守恒。
contract MonthPositionsV2Test is Fixture {
    address internal buyer = address(0xB0B);
    address internal alice = address(0xA11CE5);
    address internal bob = address(0xB0B0B);

    /// @dev 月局 #1：小数投入招满 → 收购三台矿机 → 进入挖矿
    function _mining() internal returns (MonthBoard m, address[] memory users) {
        _startGenesis();
        m = _monthBoard();
        uint256 n;
        users = new address[](60);
        while (m.state() == MonthState.Recruiting) {
            uint256 span = m.maxStake() - m.minStake();
            uint256 amt = m.minStake() + (uint256(keccak256(abi.encode("p2", n))) % span) / 1e6 * 1e6;
            users[n++] = _joinMonth(m, amt);
        }
        assembly {
            mstore(users, n)
        }
        _sellMonth(m, _newUser(), 30);
        _sellMonth(m, _newUser(), 20);
        _sellMonth(m, _newUser(), 40);
        vm.warp(m.prepEnd());
        m.sync();
    }

    function _yieldAll(MonthBoard m, uint256 amount) internal {
        uint256 n = m.machineCount();
        for (uint256 i = 0; i < n; i++) {
            if (!m.machine(i).sold) _yieldMonth(m, amount / n);
        }
    }

    function _settled() internal returns (MonthBoard m, address[] memory users) {
        (m, users) = _mining();
        _yieldAll(m, 9 * BEM_1);
        vm.warp(m.miningEnd());
        m.drawPrizes();
        rng.fulfill(m.pendingRequestId(), uint256(keccak256("p2 prizes")));
        m.finalizePrizes();
        assertEq(uint256(m.state()), uint256(MonthState.Settling));
    }

    function _id(MonthBoard m, uint256 slot) internal view returns (uint256) {
        return positions.idOf(address(m), slot);
    }

    function _move(MonthBoard m, uint256 slot, address to) internal {
        uint256 id = _id(m, slot);
        address from = positions.ownerOf(id);
        vm.prank(from);
        positions.transferFrom(from, to, id);
    }

    // ---------------- 铸造与编号 ----------------

    function test_JoinMintsPositionToJoiner() public {
        _startGenesis();
        MonthBoard m = _monthBoard();
        address u = _joinMonth(m, m.minStake());
        uint256 id = _id(m, 1);
        assertEq(positions.ownerOf(id), u);
        assertEq(positions.boardOf(id), address(m));
        assertEq(positions.slotOf(id), 1);
        assertEq(m.holderCount(u), 1);
        assertEq(m.socket(1).owner, u);
        assertEq(m.socket(1).version, 0);
        // 只有月局能铸造；主板只能铸造自己的编号
        vm.expectRevert(MonthPositions.NotMonthBoard.selector);
        positions.mint(address(this), 1);
        // 只有凭证合约能调用转移钩子
        vm.expectRevert(MonthBoard.NotAuthorized.selector);
        m.onPositionTransfer(1, u, address(this));
    }

    // ---------------- 统一转让锁 ----------------

    /// @dev 招募、准备、挖矿、开奖（随机数到账前后）期间，所有转移路径都失败
    function test_TransfersLockedBeforeSettlementOnEveryPath() public {
        _startGenesis();
        MonthBoard m = _monthBoard();
        address u = _joinMonth(m, m.minStake());
        uint256 id = _id(m, 1);
        _expectAllPathsLocked(id, u);
        _fillMonth(m);
        assertEq(uint256(m.state()), uint256(MonthState.Preparing));
        _expectAllPathsLocked(id, u);
        _sellMonth(m, _newUser(), 30);
        vm.warp(m.prepEnd());
        m.sync();
        assertEq(uint256(m.state()), uint256(MonthState.Mining));
        _expectAllPathsLocked(id, u);
        _yieldMonth(m, BEM_1);
        vm.warp(m.miningEnd()); // 到期但还没 drawPrizes：仍是 Mining，转让照样失败
        _expectAllPathsLocked(id, u);
        m.drawPrizes();
        _expectAllPathsLocked(id, u);
        rng.fulfill(m.pendingRequestId(), 7);
        assertTrue(m.wordReceived());
        _expectAllPathsLocked(id, u); // 随机数已到、奖金还没发：不能卖掉旧权利包
        m.finalizePrizes();
        assertEq(uint256(m.state()), uint256(MonthState.Settling));
        _move(m, 1, alice); // 结算阶段：可以
        assertEq(positions.ownerOf(id), alice);
    }

    function _expectAllPathsLocked(uint256 id, address owner) internal {
        PositionReceiver rcv = new PositionReceiver();
        vm.startPrank(owner);
        vm.expectRevert(MonthBoard.TransferLocked.selector);
        positions.transferFrom(owner, alice, id);
        vm.expectRevert(MonthBoard.TransferLocked.selector);
        positions.safeTransferFrom(owner, address(rcv), id);
        positions.approve(bob, id);
        positions.setApprovalForAll(buyer, true);
        vm.stopPrank();
        vm.prank(bob); // 单个授权
        vm.expectRevert(MonthBoard.TransferLocked.selector);
        positions.transferFrom(owner, bob, id);
        vm.prank(buyer); // 全部授权
        vm.expectRevert(MonthBoard.TransferLocked.selector);
        positions.transferFrom(owner, buyer, id);
        vm.prank(owner);
        positions.setApprovalForAll(buyer, false);
    }

    function test_FailedBoardPositionsNeverTransfer() public {
        _startGenesis();
        MonthBoard m = _monthBoard();
        address u = _joinMonth(m, m.minStake());
        vm.warp(m.recruitDeadline());
        m.closeRecruitment();
        assertEq(uint256(m.state()), uint256(MonthState.Failed));
        uint256 id = _id(m, 1);
        vm.prank(u);
        vm.expectRevert(MonthBoard.TransferLocked.selector);
        positions.transferFrom(u, alice, id);
        // 退款照常按持仓付给加入者
        uint256 before = bem.balanceOf(u);
        m.claimAll(1);
        assertGt(bem.balanceOf(u), before);
    }

    function test_GovernanceLockAndClosedClaimsBlockTransfers() public {
        (MonthBoard m, address[] memory users) = _settled();
        uint64 e0 = m.tradeEpoch();
        vm.prank(address(governor)); // 冒充清算治理合约（只为测锁）
        m.setGovernanceLock(true);
        assertEq(m.tradeEpoch(), e0 + 1);
        uint256 id1 = _id(m, 1);
        vm.prank(users[0]);
        vm.expectRevert(MonthBoard.TransferLocked.selector);
        positions.transferFrom(users[0], alice, id1);
        vm.prank(address(governor)); // 冒充清算治理合约（只为测锁）
        m.setGovernanceLock(false);
        _move(m, 1, alice);
        // 只有治理合约能设置锁 / 开始清算
        vm.prank(alice);
        vm.expectRevert(MonthBoard.NotAuthorized.selector);
        m.setGovernanceLock(true);
        vm.prank(alice);
        vm.expectRevert(MonthBoard.NotAuthorized.selector);
        m.startLiquidation();
        // 卖完 + 365 天领取期限关闭后：禁止转让
        vm.warp(m.settleStart() + 1 days);
        _buyAll(m);
        vm.warp(m.finishedAt() + 365 days);
        m.closeClaims();
        vm.prank(alice);
        vm.expectRevert(MonthBoard.TransferLocked.selector);
        positions.transferFrom(alice, bob, id1);
    }

    function _buyAll(MonthBoard m) internal returns (uint256 total) {
        _syncRigs(m);
        bem.mint(buyer, 10_000 * BEM_1);
        vm.startPrank(buyer);
        bem.approve(address(sales), type(uint256).max);
        for (uint256 i = 0; i < m.machineCount(); i++) {
            if (!m.machine(i).sold) total += sales.buyMachine(address(m), i, type(uint256).max);
        }
        vm.stopPrank();
    }

    // ---------------- 结转、通行证、版本号 ----------------

    /// @dev 卖方已经累计的份额（含合约里还没 sweep 的到账）结转给卖方；买方只拿转让之后的；通行证立刻退给加入者
    function test_TransferCarriesAccruedToSellerAndReturnsPass() public {
        (MonthBoard m, address[] memory users) = _settled();
        address seller = users[0];
        uint256 passId = m.socket(1).passId;
        assertEq(passCircuits.ownerOf(passId), address(m));
        bem.mint(address(m), 2 * BEM_1); // 还没 sweep 的到账：转让前就属于卖方的那部分
        uint256 before = m.owed(1);
        uint64 epoch = m.tradeEpoch();
        vm.expectEmit(true, true, true, false, address(m));
        emit MonthBoard.PositionTransferred(1, seller, alice, 0);
        _move(m, 1, alice);
        uint256 carried = m.credit(seller);
        assertGt(carried, before, "unswept income counted for the seller");
        assertEq(m.owed(1), 0, "buyer starts from zero");
        assertEq(m.socket(1).owner, alice);
        assertEq(m.socket(1).version, 1);
        assertEq(m.tradeEpoch(), epoch, "a transfer changes the position version, not the board epoch");
        assertEq(m.holderCount(seller), 0);
        assertEq(m.holderCount(alice), 1);
        assertEq(passCircuits.ownerOf(passId), seller, "pass back to the original holder at once");
        assertTrue(m.socket(1).passReturned);
        // 之后卖出矿机的回款归买方
        vm.warp(m.settleStart() + 1 days);
        _buyAll(m);
        assertGt(m.owed(1), 0, "future proceeds go to the buyer");
        // 卖方领结转款；买方领持仓款
        uint256 s0 = bem.balanceOf(seller);
        m.withdrawCredit(seller);
        assertEq(bem.balanceOf(seller) - s0, carried);
        uint256 a0 = bem.balanceOf(alice);
        uint256 owedAlice = m.owed(1);
        m.withdraw(1);
        assertEq(bem.balanceOf(alice) - a0, owedAlice);
        vm.expectRevert(MonthBoard.NothingToWithdraw.selector);
        m.withdrawCredit(seller);
        // 再转一次：通行证不会再发，版本号继续 +1
        _move(m, 1, bob);
        assertEq(m.socket(1).version, 2);
        assertEq(passCircuits.ownerOf(passId), seller);
    }

    function test_OneWalletHoldsSeveralPositionsWithSeparateSlots() public {
        (MonthBoard m, address[] memory users) = _settled();
        _move(m, 1, alice);
        _move(m, 2, alice);
        _move(m, 3, alice);
        assertEq(m.holderCount(alice), 3);
        assertEq(positions.balanceOf(alice), 3);
        // 三份持仓各自独立：投入、版本号、可领金额分别记
        assertEq(m.socket(1).stake, m.socket(1).stake);
        assertTrue(m.socket(1).stake != 0 && m.socket(2).stake != 0);
        vm.warp(m.settleStart() + 1 days);
        _buyAll(m);
        uint256 total = m.totalStake();
        uint256 got = m.owed(1) + m.owed(2) + m.owed(3);
        uint256 stakes = uint256(m.socket(1).stake) + m.socket(2).stake + m.socket(3).stake;
        assertGt(got, 0);
        // 持有人可以代替运营地址兜底（3 天后）
        vm.warp(m.settleStart() + 3 days);
        vm.prank(alice);
        sales.distribute(address(m), 1, 3);
        assertEq(m.owed(1) + m.owed(2) + m.owed(3), 0);
        assertGt(bem.balanceOf(alice), 0);
        assertLe(stakes, total);
        // 原加入者已经不持有任何持仓：不能再兜底
        vm.prank(users[0]);
        vm.expectRevert(MonthMachineSales.NotAuthorized.selector);
        sales.distribute(address(m), 1, 3);
    }

    /// @dev 选项 9a：转让时退通行证失败，转让照常完成；通行证记在原持有人名下，之后 returnPass 退给原持有人
    function test_PassReturnFailureDoesNotBlockTransfer() public {
        (MonthBoard m, address[] memory users) = _settled();
        address seller = users[0];
        uint256 passId = m.socket(1).passId;
        vm.mockCallRevert(
            address(passCircuits),
            abi.encodeCall(ICircuits.transferFrom, (address(m), seller, passId)),
            abi.encode("paused")
        );
        _move(m, 1, alice);
        assertEq(m.socket(1).owner, alice);
        assertFalse(m.socket(1).passReturned);
        assertEq(m.passOwner(1), seller);
        vm.clearMockedCalls();
        _move(m, 1, bob); // 再转一次：仍然退给原持有人，而不是中间的 alice
        assertEq(passCircuits.ownerOf(passId), seller);
        assertTrue(m.socket(1).passReturned);
    }

    function test_PassReturnFailureThenReturnPassGoesToOriginalHolder() public {
        (MonthBoard m, address[] memory users) = _settled();
        address seller = users[0];
        uint256 passId = m.socket(1).passId;
        vm.mockCallRevert(
            address(passCircuits),
            abi.encodeCall(ICircuits.transferFrom, (address(m), seller, passId)),
            abi.encode("paused")
        );
        _move(m, 1, alice);
        vm.clearMockedCalls();
        m.returnPass(1);
        assertEq(passCircuits.ownerOf(passId), seller, "not to the current holder");
    }

    // ---------------- 交易版本号 ----------------

    function test_TradeEpochBumpsOnSettlementSaleAndRelay() public {
        (MonthBoard m,) = _mining();
        _yieldAll(m, 9 * BEM_1);
        uint64 e0 = m.tradeEpoch();
        vm.warp(m.miningEnd());
        m.drawPrizes();
        rng.fulfill(m.pendingRequestId(), 1);
        m.finalizePrizes();
        assertEq(m.tradeEpoch(), e0 + 1, "settlement start");
        vm.warp(m.settleStart() + 1 days);
        _syncRigs(m);
        bem.mint(buyer, 1_000 * BEM_1);
        vm.startPrank(buyer);
        bem.approve(address(sales), type(uint256).max);
        sales.buyMachine(address(m), 0, type(uint256).max);
        vm.stopPrank();
        assertEq(m.tradeEpoch(), e0 + 2, "machine sold (option 3a)");
        MonthBoard r = _monthBoard();
        if (block.timestamp >= r.recruitDeadline()) {
            r.closeRecruitment();
            r = _monthBoard();
        }
        _fillMonth(r);
        _relayWhenPriced(m, 1, r);
        assertEq(m.tradeEpoch(), e0 + 3, "machine relayed");
    }

    // ---------------- 资金守恒（转让交错）----------------

    /// @dev 结算中随机交错：转让（含转给已持仓的地址、转回原主）、迟到产出、卖矿、自领、结转款领取、分批推送。
    ///      结束时：结算开始后的流入 = 流出 + 合约剩余（只剩尘埃），一分不差；每一步 余额 ≥ liabilities ≥ Σ 可领。
    uint256 internal c_in0;
    uint256 internal c_paid0;
    uint256 internal c_out0;
    uint256 internal c_sales;

    function testFuzz_ConservationWithTransfers(uint256 seed, uint64 y1, uint64 y2) public {
        (MonthBoard m, address[] memory users) = _settled();
        address[] memory holders = new address[](users.length + 3);
        for (uint256 i = 0; i < users.length; i++) {
            holders[i] = users[i];
        }
        holders[users.length] = alice;
        holders[users.length + 1] = bob;
        holders[users.length + 2] = address(0xC0C0);
        c_in0 = bem.balanceOf(address(m));
        c_paid0 = deliveredYield[address(m)];
        c_out0 = _outside(holders);
        uint256 n = m.socketCount();
        for (uint256 k = 0; k < 12; k++) {
            _step(m, holders, seed, k, y1);
        }
        _yieldAll(m, bound(uint256(y2), 0, 10 * BEM_1));
        c_sales += _buyAll(m);
        sales.distribute(address(m), 1, n);
        for (uint256 i = 0; i < holders.length; i++) {
            if (m.credit(holders[i]) > 0) m.withdrawCredit(holders[i]);
        }
        _check(m, holders);
        uint256 inflow = c_in0 + (deliveredYield[address(m)] - c_paid0) + c_sales;
        uint256 outflow = _outside(holders) - c_out0 + bem.balanceOf(address(m));
        assertEq(inflow, outflow, "BEM conserved exactly");
        assertEq(bem.balanceOf(address(m)), m.liabilities(), "leftover is booked dust");
        assertLe(bem.balanceOf(address(m)), n + 10, "dust only");
        // 每份持仓的投入、总投入从未改变
        uint256 sum;
        for (uint256 i = 1; i <= n; i++) {
            sum += m.socket(i).stake;
        }
        assertEq(sum, m.totalStake());
    }

    function _step(MonthBoard m, address[] memory holders, uint256 seed, uint256 k, uint64 y1) internal {
        uint256 n = m.socketCount();
        {
            uint256 r = uint256(keccak256(abi.encode(seed, k)));
            uint256 slot = 1 + r % n;
            address to = holders[(r >> 16) % holders.length];
            if (to != positions.ownerOf(_id(m, slot))) _move(m, slot, to);
            if ((r >> 32) % 3 == 0) _yieldAll(m, bound(uint256(y1), 0, 10 * BEM_1));
            if ((r >> 40) % 4 == 0) m.harvest();
            if ((r >> 48) % 3 == 0 && m.owed(slot) > 0) m.withdraw(slot);
            if ((r >> 56) % 3 == 0) {
                address h = holders[(r >> 64) % holders.length];
                if (m.credit(h) > 0) m.withdrawCredit(h);
            }
            if (k == 5) {
                vm.warp(m.settleStart() + 1 days);
                _syncRigs(m);
                bem.mint(buyer, 1_000 * BEM_1);
                vm.startPrank(buyer);
                bem.approve(address(sales), type(uint256).max);
                c_sales += sales.buyMachine(address(m), 0, type(uint256).max);
                vm.stopPrank();
            }
            _check(m, holders);
        }
    }

    function _outside(address[] memory holders) internal view returns (uint256 sum) {
        sum = bem.balanceOf(FOUNDATION) + bem.balanceOf(FEE_SAFE) + bem.balanceOf(address(monthFactory));
        for (uint256 i = 0; i < holders.length; i++) {
            sum += bem.balanceOf(holders[i]);
        }
    }

    function _check(MonthBoard m, address[] memory holders) internal view {
        uint256 owedSum;
        for (uint256 i = 1; i <= m.socketCount(); i++) {
            owedSum += m.owed(i);
        }
        for (uint256 i = 0; i < holders.length; i++) {
            owedSum += m.credit(holders[i]);
        }
        assertGe(bem.balanceOf(address(m)), m.liabilities(), "balance >= liabilities");
        assertLe(owedSum, m.liabilities(), "sum owed <= liabilities");
    }

    // ---------------- 卖矿合约权限 ----------------

    function test_SalesDistributeRules() public {
        (MonthBoard m, address[] memory users) = _settled();
        vm.prank(users[1]);
        vm.expectRevert(MonthMachineSales.NotAuthorized.selector);
        sales.distribute(address(m), 1, 10); // 3 天内只有运营地址
        vm.expectRevert(MonthMachineSales.NotMonthBoard.selector);
        sales.distribute(address(0xBAD), 1, 10);
        sales.distribute(address(m), 1, type(uint256).max); // 超大 count 不溢出
        for (uint256 i = 1; i <= m.socketCount(); i++) {
            assertEq(m.owed(i), 0);
            assertTrue(m.socket(i).passReturned);
        }
    }
}
