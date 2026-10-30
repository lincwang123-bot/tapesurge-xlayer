// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {RigMachineSource} from "../src/machines/RigMachineSource.sol";
import {MockRig} from "../src/mocks/MockRig.sol";
import {MockBEM} from "../src/mocks/MockBEM.sol";

/// @notice 没有 onERC721Received 的合约（模拟主板）：RIG 用 transferFrom 转入，收益用普通 transfer 打进来
contract PlainHolder {}

/// @notice M1：RIG 矿机来源的收购资格，以及 RIG 收益"按收取时刻的持有人"异步到账的语义（MockRig 按 RigVoucher.sol 实现）
contract RigMachineSourceTest is Test {
    address internal constant CIRC = address(0xC1C1);
    uint256 internal constant MIN = 10;
    uint256 internal constant MAX = 300;
    uint256 internal constant SYNC_AGE = 3 days;

    MockBEM internal bem;
    MockRig internal rig;
    RigMachineSource internal src;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal vault = address(0x7A017); // 代表 LayerZero 送达方

    function setUp() public {
        vm.warp(1_800_000_000);
        bem = new MockBEM();
        rig = new MockRig(address(bem));
        src = new RigMachineSource(address(rig), CIRC, MIN, MAX, SYNC_AGE);
        bem.mint(vault, 1_000_000e8);
        vm.prank(vault);
        bem.approve(address(rig), type(uint256).max);
    }

    // ---------------- 构造参数 ----------------

    function test_RevertWhen_BadConfig() public {
        vm.expectRevert(RigMachineSource.BadConfig.selector);
        new RigMachineSource(address(0), CIRC, MIN, MAX, SYNC_AGE);
        vm.expectRevert(RigMachineSource.BadConfig.selector);
        new RigMachineSource(address(rig), CIRC, 0, MAX, SYNC_AGE);
        vm.expectRevert(RigMachineSource.BadConfig.selector);
        new RigMachineSource(address(rig), CIRC, MIN, MIN - 1, SYNC_AGE);
        vm.expectRevert(RigMachineSource.BadConfig.selector);
        new RigMachineSource(address(rig), CIRC, MIN, MAX, 0);
        assertEq(src.machineToken(), address(rig));
    }

    // ---------------- 收购资格 ----------------

    function test_PurchaseWeightIsPowerWithinRange() public {
        rig.mintRig(alice, 1, CIRC, 7, MIN);
        rig.mintRig(alice, 2, CIRC, 8, MAX);
        rig.mintRig(alice, 3, CIRC, 9, 42);
        assertEq(src.purchaseWeight(1), MIN);
        assertEq(src.purchaseWeight(2), MAX);
        assertEq(src.purchaseWeight(3), 42);
        assertEq(src.currentWeight(3), 42);
    }

    function test_PurchaseWeightZeroOutsideRange() public {
        rig.mintRig(alice, 1, CIRC, 7, MIN - 1);
        rig.mintRig(alice, 2, CIRC, 8, MAX + 1);
        rig.mintRig(alice, 3, CIRC, 9, 0);
        assertEq(src.purchaseWeight(1), 0);
        assertEq(src.purchaseWeight(2), 0);
        assertEq(src.purchaseWeight(3), 0, "stopped machine (power synced to 0)");
        assertEq(src.purchaseWeight(99), 0, "nonexistent rig");
        assertEq(src.currentWeight(1), MIN - 1);
    }

    function test_PurchaseWeightZeroForOtherCircuits() public {
        rig.mintRig(alice, 1, address(0xBAD), 7, 50);
        assertEq(src.purchaseWeight(1), 0);
        // expectedCircuits = 0 时不检查电路合约
        RigMachineSource any = new RigMachineSource(address(rig), address(0), MIN, MAX, SYNC_AGE);
        assertEq(any.purchaseWeight(1), 50);
    }

    function test_PurchaseWeightRequiresRecentSync() public {
        rig.mintRig(alice, 1, CIRC, 7, 50);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + SYNC_AGE);
        assertEq(src.purchaseWeight(1), 50, "exactly 3 days old is still fine");
        vm.warp(t0 + SYNC_AGE + 1);
        assertEq(src.purchaseWeight(1), 0, "stale: BSC side stopped syncing");
        // BSC 上有人收取一次（随消息同步算力），重新符合资格
        rig.sync(1, 60, uint64(block.timestamp));
        assertEq(src.purchaseWeight(1), 60);
        // 同步时间在未来（不应出现）：不收
        rig.sync(1, 60, uint64(block.timestamp + 1));
        assertEq(src.purchaseWeight(1), 0);
    }

    function test_PowerDropTracksRig() public {
        rig.mintRig(alice, 1, CIRC, 7, 100);
        rig.sync(1, 20, uint64(block.timestamp + 0));
        assertEq(src.purchaseWeight(1), 100, "older-or-equal sync time is ignored by the rig");
        vm.warp(block.timestamp + 1);
        rig.sync(1, 20, uint64(block.timestamp));
        assertEq(src.purchaseWeight(1), 20, "power downgraded on BSC");
        assertEq(rig.powerHeld(alice), 20);
        assertEq(rig.totalPower(), 20);
    }

    // ---------------- RIG 收益语义（主板按余额增量记账的前提）----------------

    /// @dev 收益归属按 BSC 上发起收取的时刻：收取后才转手、到账更晚，钱仍然给收取时的持有人
    function test_DelayedDeliveryPaysHolderAtClaimTime() public {
        PlainHolder board = new PlainHolder();
        rig.mintRig(alice, 1, CIRC, 7, 50);
        uint64 claimTime = uint64(block.timestamp + 1 hours);
        vm.warp(claimTime);
        // alice 在 BSC 上收取（消息在路上），随后把凭证卖给主板
        vm.warp(claimTime + 10 minutes);
        vm.prank(alice);
        rig.transferFrom(alice, address(board), 1);
        assertEq(rig.ownerOf(1), address(board), "contract holds RIG without onERC721Received");
        // 20 分钟后 LayerZero 才送达：仍然付给 alice
        vm.warp(claimTime + 30 minutes);
        _deliver(claimTime, 1, 5e8, 50);
        assertEq(bem.balanceOf(alice), 5e8);
        assertEq(bem.balanceOf(address(board)), 0);
        // 转手之后发起的收取归主板（普通 transfer，没有回调）
        uint64 t2 = uint64(block.timestamp + 1 days);
        vm.warp(t2 + 2 hours);
        _deliver(t2, 1, 7e8, 49);
        assertEq(bem.balanceOf(address(board)), 7e8);
        assertEq(rig.rigs(1).power, 49, "power synced with the yield message");
        assertEq(rig.rigs(1).syncedAt, t2);
    }

    /// @dev 两笔收取乱序到达：都按各自收取时刻的持有人付款；较早的那笔不会把算力同步回旧值
    function test_OutOfOrderDeliveries() public {
        PlainHolder board = new PlainHolder();
        rig.mintRig(alice, 1, CIRC, 7, 50);
        uint64 tA = uint64(block.timestamp + 1 hours);
        vm.warp(tA + 1);
        vm.prank(alice);
        rig.transferFrom(alice, bob, 1);
        uint64 tB = uint64(block.timestamp + 1 hours);
        vm.warp(tB + 1);
        vm.prank(bob);
        rig.transferFrom(bob, address(board), 1);
        uint64 tC = uint64(block.timestamp + 1 hours);
        vm.warp(tC + 1 hours);
        _deliver(tC, 1, 3e8, 40); // 最晚的先到
        _deliver(tA, 1, 1e8, 55);
        _deliver(tB, 1, 2e8, 60);
        assertEq(bem.balanceOf(alice), 1e8);
        assertEq(bem.balanceOf(bob), 2e8);
        assertEq(bem.balanceOf(address(board)), 3e8);
        assertEq(rig.rigs(1).power, 40, "stale messages do not overwrite newer power");
        assertEq(rig.holderAt(1, tA), alice);
        assertEq(rig.holderAt(1, tB), bob);
        assertEq(rig.payeeAt(1, tC), address(board));
    }

    function _deliver(uint64 time, uint256 id, uint256 amount, uint256 power) internal {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory shares = new uint256[](1);
        uint256[] memory powers = new uint256[](1);
        ids[0] = id;
        shares[0] = amount;
        powers[0] = power;
        vm.prank(vault);
        rig.deliverYield(time, ids, shares, powers);
    }
}
