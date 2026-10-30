// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {XHub} from "../src/XHub.sol";
import {XMonthBoard} from "../src/XMonthBoard.sol";
import {XMonthFactory} from "../src/XMonthFactory.sol";
import {MonthState} from "../src/interfaces/IXMonthBoard.sol";
import {IBeacon} from "../src/interfaces/ITapeOut.sol";

/// @notice XHub 的开局条件和升级哨兵登记。移植自 BSC 版 Sentinel.t.sol / Hardening.t.sol 里和注册中心、
///         月局有关的用例（X Layer 版只监控创世通行证所在的电路信标；RIG 的 UUPS 升级链上检测不到）。
contract XHubSentinelTest is Fixture {
    // ---------------- 开局条件 ----------------

    function test_GenesisNeedsThresholdOrDelayAndRunsOnce() public {
        vm.expectRevert(XHub.GenesisConditionNotMet.selector);
        factory.startGenesis();
        vm.warp(block.timestamp + 7 days - 1);
        vm.expectRevert(XHub.GenesisConditionNotMet.selector);
        factory.startGenesis();
        vm.warp(block.timestamp + 1);
        // 同 BSC：BSC 行情转报从没报过价时不能开局
        vm.expectRevert(XHub.FeedNotPosted.selector);
        factory.startGenesis();
        _feedDefault();
        XMonthBoard m = XMonthBoard(factory.startGenesis());
        assertEq(uint256(m.state()), uint256(MonthState.Recruiting));
        assertEq(m.number(), 1);
        assertTrue(factory.genesisStarted());
        vm.expectRevert(XHub.GenesisAlreadyStarted.selector);
        factory.startGenesis();
    }

    function test_GenesisOpensEarlyWhenMintThresholdReached() public {
        address minter = address(0xA11CE);
        vm.deal(minter, 100 ether);
        vm.prank(minter);
        transistors.mint{value: 10_000 * 0.0011 ether}(0, 10_000);
        _feedDefault();
        XMonthBoard m = XMonthBoard(factory.startGenesis()); // 不到 7 天
        assertEq(m.number(), 1);
    }

    function test_StartGenesisBlockedWhenTripped() public {
        machineBeacon.upgradeTo(address(0xBAD));
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(XHub.SentinelTripped.selector);
        factory.startGenesis();
    }

    /// @dev 冷静期内不能开局；登记满 30 天后可以开局
    function test_GenesisWaitsForCoolingPeriod() public {
        machineBeacon.upgradeTo(address(0xBAD));
        factory.noteSentinel();
        uint256 since = factory.sentinelSince();
        assertEq(since, block.timestamp);
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(XHub.SentinelTripped.selector);
        factory.startGenesis();
        vm.warp(since + 30 days);
        _feedDefault();
        assertTrue(factory.startGenesis() != address(0));
    }

    // ---------------- 登记与作废 ----------------

    /// @dev 没人登记时一直暂停；任何人都可以登记；信标恢复后立即恢复，再调用会清零
    function test_NoteSentinelRecordsAndResets() public {
        XMonthBoard m = _startGenesis();
        address original = machineBeacon.implementation();
        factory.noteSentinel();
        assertEq(factory.sentinelSince(), 0, "not tripped: nothing recorded");
        machineBeacon.upgradeTo(address(0xBAD));
        vm.warp(block.timestamp + 365 days);
        assertTrue(m.sentinelPaused(), "never noted: stays paused");
        vm.prank(address(0xCAFE));
        factory.noteSentinel();
        assertEq(factory.sentinelSince(), block.timestamp);
        machineBeacon.upgradeTo(original);
        assertFalse(m.sentinelPaused());
        factory.noteSentinel();
        assertEq(factory.sentinelSince(), 0, "recovered: reset");
    }

    /// @dev 升级 → 登记 → 恢复 → 30 天后再次升级（换了别的 implementation）：重新进入冷静期（BSC 内审 F1）
    function test_SecondUpgradeAfterRecoveryStartsNewCoolingPeriod() public {
        XMonthBoard m = _startGenesis();
        address original = machineBeacon.implementation();
        machineBeacon.upgradeTo(address(0xBAD1));
        factory.noteSentinel();
        uint256 first = factory.sentinelSince();
        assertTrue(m.sentinelPaused());
        vm.warp(block.timestamp + 5 days);
        machineBeacon.upgradeTo(original);
        assertFalse(m.sentinelTripped());
        assertEq(factory.sentinelSince(), 0, "record no longer matches the beacon");
        vm.warp(first + 60 days);
        machineBeacon.upgradeTo(address(0xBAD2));
        assertTrue(m.sentinelTripped());
        assertEq(factory.sentinelSince(), 0);
        assertTrue(m.sentinelPaused(), "second upgrade gets its own cooling period");
    }

    /// @dev 第二次升级后调用 noteSentinel：从调用时刻重新计 30 天；同一个 implementation 再调用不刷新
    function test_NoteAfterSecondUpgradeRestartsThirtyDays() public {
        XMonthBoard m = _startGenesis();
        machineBeacon.upgradeTo(address(0xBAD1));
        factory.noteSentinel();
        vm.warp(block.timestamp + 40 days);
        assertFalse(m.sentinelPaused(), "first cooling period is over");
        machineBeacon.upgradeTo(address(0xBAD2));
        assertTrue(m.sentinelPaused(), "record is void after the implementation changed");
        factory.noteSentinel();
        uint256 second = factory.sentinelSince();
        assertEq(second, block.timestamp);
        vm.warp(second + 30 days - 1);
        assertTrue(m.sentinelPaused());
        factory.noteSentinel();
        assertEq(factory.sentinelSince(), second);
        vm.warp(second + 30 days);
        assertFalse(m.sentinelPaused());
    }

    function test_UnreadableBeaconCountsAsTripped() public {
        XMonthBoard m = _startGenesis();
        vm.mockCallRevert(address(machineBeacon), abi.encodeWithSelector(IBeacon.implementation.selector), "");
        assertTrue(m.sentinelTripped());
        assertTrue(m.sentinelPaused());
        factory.noteSentinel();
        assertEq(factory.sentinelSince(), block.timestamp, "unreadable beacon can be noted");
    }

    function test_RevertWhen_EmergencySettleWithoutTrip() public {
        XMonthBoard m = _startGenesis();
        address[] memory users = _fillMonth(m);
        vm.prank(users[0]);
        vm.expectRevert(XMonthBoard.SentinelNotTripped.selector);
        m.emergencySettle();
    }

    /// @dev 冷静期内运营 / 参与者仍能开奖：到期的局照常开奖，不能提前结算
    function test_ExpiredBoardDrawsNormallyDuringCoolingPeriod() public {
        XMonthBoard m = _startGenesis();
        address[] memory users = _fillMonth(m);
        _sellMonth(m, _newUser(), 30);
        vm.warp(m.prepEnd());
        m.sync();
        _yieldMonth(m, 5 * BEM_1);
        vm.warp(m.miningEnd());
        machineBeacon.upgradeTo(address(0xBAD));
        vm.prank(users[0]);
        vm.expectRevert(XMonthBoard.WrongState.selector);
        m.emergencySettle();
        m.drawPrizes();
        assertEq(uint256(m.state()), uint256(MonthState.Drawing));
    }

    // ---------------- 构造参数 ----------------

    function test_RevertWhen_HubParamsInvalid() public {
        XHub.Params memory p = XHub.Params(address(splitter), address(monthFactory), address(this), 10_000, 7 days);
        p.splitter = address(0);
        vm.expectRevert(XHub.BadParams.selector);
        new XHub(p);
        p = XHub.Params(address(splitter), address(0), address(this), 10_000, 7 days);
        vm.expectRevert(XHub.BadParams.selector);
        new XHub(p);
        // 分账合约记录的注册中心不是新部署的这个
        p = XHub.Params(address(splitter), address(monthFactory), address(this), 10_000, 7 days);
        vm.expectRevert(XHub.BadParams.selector);
        new XHub(p);
    }

    function test_RevertWhen_MonthFactoryParamsMismatchHub() public {
        XMonthFactory.Params memory mp = defaultMonthParams();
        vm.expectRevert(XMonthFactory.BadHub.selector);
        new XMonthFactory(address(factory), mp); // hub 记录的是另一个月局工厂
    }

    /// @dev 移植 BSC 内审 F3：时长上下限
    function test_RevertWhen_MonthBoardDurationsOutOfRange() public {
        XMonthBoard.Config memory c = monthFactory.boardConfig();
        c.vrfRetryDelay = 1 hours - 1;
        vm.expectRevert(XMonthBoard.BadConfig.selector);
        new XMonthBoard(c);
        c = monthFactory.boardConfig();
        c.prepDuration = 0;
        vm.expectRevert(XMonthBoard.BadConfig.selector);
        new XMonthBoard(c);
        c = monthFactory.boardConfig();
        c.recruitDuration = 0;
        vm.expectRevert(XMonthBoard.BadConfig.selector);
        new XMonthBoard(c);
        c = monthFactory.boardConfig();
        c.claimWindow = 3650 days + 1;
        vm.expectRevert(XMonthBoard.BadConfig.selector);
        new XMonthBoard(c);
        c = monthFactory.boardConfig();
        c.sentinelResumeDelay = type(uint256).max;
        vm.expectRevert(XMonthBoard.BadConfig.selector);
        new XMonthBoard(c);
        c = monthFactory.boardConfig();
        c.minMachineWeight = 0;
        vm.expectRevert(XMonthBoard.BadConfig.selector);
        new XMonthBoard(c);
        c = monthFactory.boardConfig();
        c.machineSource = address(0);
        vm.expectRevert(XMonthBoard.BadConfig.selector);
        new XMonthBoard(c);
        c = monthFactory.boardConfig();
        c.vrfRetryDelay = 1 hours;
        c.claimWindow = 3650 days;
        assertGt(address(new XMonthBoard(c)).code.length, 20_000, "boundary values deploy");
    }
}
