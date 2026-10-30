// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockBEM} from "../src/mocks/MockBEM.sol";
import {MockWrappedNative, MockPriceOracle} from "../src/mocks/MockSwap.sol";
import {MockZapRouter} from "../src/mocks/MockZapRouter.sol";

/// @notice 测试网模拟路由：dApp 用的几种调用（和主网 SwapRouter02 相同的参数）
contract MockZapRouterTest is Test {
    MockBEM bem;
    MockWrappedNative wokb;
    MockPriceOracle oracle;
    MockZapRouter router;
    address user = address(0xA11CE);
    uint24 constant FEE = 10_000; // 1%
    uint256 constant RATE = 383_150_000; // 1 OKB = 3.8315 BEM（测试网当时的报价）

    function setUp() public {
        bem = new MockBEM();
        wokb = new MockWrappedNative();
        oracle = new MockPriceOracle(address(1), address(wokb), address(bem), FEE, RATE);
        router = new MockZapRouter(address(wokb), address(bem), address(oracle));
        vm.deal(user, 10 ether);
    }

    function _buyCall(uint256 bemOut, uint256 maxIn) internal view returns (bytes[] memory data) {
        data = new bytes[](2);
        data[0] = abi.encodeCall(
            MockZapRouter.exactOutputSingle,
            (MockZapRouter.ExactOutputSingleParams(address(wokb), address(bem), FEE, user, bemOut, maxIn, 0))
        );
        data[1] = abi.encodeCall(MockZapRouter.refundETH, ());
    }

    /// dApp 加入前：用 OKB 刚好换到所需的 BEM，多付的 OKB 同一笔退回；付进来的 OKB 留作储备
    function test_BuyExactBemWithOkbRefundsTheRest() public {
        uint256 bemOut = 1.01e8; // 投 1 BEM + 1% 入场费
        uint256 before = user.balance;
        vm.prank(user);
        router.multicall{value: 1 ether}(block.timestamp + 60, _buyCall(bemOut, 1 ether));
        assertEq(bem.balanceOf(user), bemOut);
        uint256 paid = before - user.balance;
        // 1.01 / 3.8315 / 0.99 ≈ 0.26627 OKB
        assertApproxEqRel(paid, 0.26627 ether, 0.0005e18);
        assertEq(router.reserve(), paid, "payment kept as WOKB reserve");
        assertEq(address(router).balance, 0, "no OKB left in the router");
    }

    function test_BuyRevertsAboveMaximumOrAfterDeadline() public {
        vm.prank(user);
        vm.expectRevert(bytes("Too much requested"));
        router.multicall{value: 1 ether}(block.timestamp + 60, _buyCall(1.01e8, 0.2 ether));
        vm.prank(user);
        vm.expectRevert(bytes("Transaction too old"));
        router.multicall{value: 1 ether}(block.timestamp - 1, _buyCall(1.01e8, 1 ether));
    }

    /// 结算后：BEM 换回 OKB（收款人 ADDRESS_THIS → unwrapWETH9），不能超过储备，unwrap 动不到储备
    function test_SellBemForOkbUpToReserve() public {
        vm.prank(user);
        router.multicall{value: 1 ether}(block.timestamp + 60, _buyCall(2e8, 1 ether)); // 储备 ≈ 0.527 OKB
        uint256 res = router.reserve();

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeCall(
            MockZapRouter.exactInputSingle,
            (MockZapRouter.ExactInputSingleParams(address(bem), address(wokb), FEE, address(2), 1e8, 0, 0))
        );
        uint256 expected = uint256(1e8) * 1e18 / RATE * 99 / 100;
        data[1] = abi.encodeCall(MockZapRouter.unwrapWETH9, (expected, user));
        vm.startPrank(user);
        bem.approve(address(router), 1e8);
        uint256 before = user.balance;
        router.multicall(block.timestamp + 60, data);
        vm.stopPrank();
        assertEq(user.balance - before, expected);
        assertEq(router.reserve(), res - expected);
        assertEq(router.pendingWeth(), 0);

        // unwrap 只付自己这笔兑换的，不会把储备取走
        vm.prank(address(0xBAD));
        router.unwrapWETH9(0, address(0xBAD));
        assertEq(address(0xBAD).balance, 0);
        assertEq(router.reserve(), res - expected);

        // 储备不够：整笔回滚
        bem.mint(user, 100e8);
        vm.startPrank(user);
        bem.approve(address(router), 100e8);
        data[0] = abi.encodeCall(
            MockZapRouter.exactInputSingle,
            (MockZapRouter.ExactInputSingleParams(address(bem), address(wokb), FEE, address(2), 100e8, 0, 0))
        );
        data[1] = abi.encodeCall(MockZapRouter.unwrapWETH9, (0, user));
        vm.expectRevert(bytes("reserve"));
        router.multicall(block.timestamp + 60, data);
        vm.stopPrank();
    }

    function test_OnlyTheWokbBemPair() public {
        vm.prank(user);
        vm.expectRevert(bytes("pair"));
        router.exactInputSingle(MockZapRouter.ExactInputSingleParams(address(bem), address(bem), FEE, user, 1, 0, 0));
    }
}
