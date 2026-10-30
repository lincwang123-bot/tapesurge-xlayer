// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {Fixture} from "./utils/Fixture.sol";
import {XMonthBoard} from "../src/XMonthBoard.sol";
import {MonthState} from "../src/interfaces/IXMonthBoard.sol";
import {MockRandomSource} from "../src/mocks/MockRandom.sol";
import {DrandEvmnetAdapter} from "../src/random/DrandEvmnetAdapter.sol";

/// @notice 从实际月局招募、持有 RIG、30 天挖矿到真实 drand 签名验签和奖金发放的本地集成测试。
/// @dev 使用 DrandEvmnetAdapter.t.sol 已核验的 evmnet 历史向量；无 RPC、无交易广播。
contract XDrandIntegrationTest is Fixture {
    uint64 internal constant ROUND = 12_345_678;
    bytes internal constant SIGNATURE =
        hex"1f82751a21ca166dcc2c804ddd5846cb5f0f8f4ded7e93a8ec9b34cdc885d99a26353f2dbf384155cc898695316de8ce942f167a0faf3906ca066ebc7200aa86";
    bytes32 internal constant RANDOMNESS = 0x0cf0d7df717120037ba88c57fb0598118b94083501489a3caa209e794f844564;
    uint256 internal constant POT = 10e8;

    DrandEvmnetAdapter internal adapter;
    XMonthBoard internal board;
    address[] internal participants;

    function setUp() public override {
        super.setUp();
        // 创世等待 7 天 + 准备 3 天 + 挖矿 30 天后，请求时刻正好位于第 ROUND 轮之前 30 秒。
        uint256 roundTime = 1727521075 + (uint256(ROUND) - 1) * 3;
        vm.warp(roundTime - 30 - 40 days);
        // 本测试合约接下来依次 CREATE adapter、splitter、hub；适配器绑定最终的真实 XHub。
        address predictedHub = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        adapter = new DrandEvmnetAdapter(predictedHub, 30, 3 days);
        // 仅复用 Fixture 的地址字段；本测试所有随机数请求/交付均经过真实适配器。
        rng = MockRandomSource(address(adapter));
        _deploySystem(defaultMonthParams(), defaultSplitterParams());
        assertEq(address(factory), predictedHub, "adapter binds the deployed hub");
        assertEq(address(adapter.registry()), address(factory));
        board = _startGenesis();
        assertEq(board.RANDOM_SOURCE(), address(adapter));
    }

    function _requestRealRound() internal returns (uint256 requestId) {
        participants = _fillMonth(board);
        _sellMonth(board, _newUser(), 50);
        vm.warp(board.prepEnd());
        board.sync();
        assertEq(uint256(board.state()), uint256(MonthState.Mining));
        vm.warp(board.miningEnd());
        assertEq(block.timestamp + 30, adapter.roundTime(ROUND));
        _yieldMonth(board, POT);
        board.drawPrizes();
        requestId = board.pendingRequestId();
        (address consumer, uint64 lockedRound, bool done) = adapter.requests(requestId);
        assertEq(consumer, address(board));
        assertEq(lockedRound, ROUND);
        assertFalse(done);
        assertEq(adapter.lockedRound(address(board)), ROUND);
        assertTrue(board.drawPending());
        assertEq(board.prizePool(), POT);
    }

    function test_RealMonthDrawAndPayoutWithDrandSignature() public {
        uint256 requestId = _requestRealRound();
        vm.warp(adapter.roundTime(ROUND));
        _fulfillAndFinalize(requestId);
    }

    /// @dev v2：重发不作废旧请求，先到先用；重发锁定同一轮次，所以先到的旧请求给出的就是同一个随机数
    function test_RetryKeepsRealRoundAndEveryRequestCounts() public {
        uint256 oldRequest = _requestRealRound();
        vm.warp(block.timestamp + 1 days);
        board.retryDraw();
        uint256 latestRequest = board.pendingRequestId();
        assertGt(latestRequest, oldRequest);
        (, uint64 lockedRound,) = adapter.requests(latestRequest);
        assertEq(lockedRound, ROUND, "a known signature cannot be rerolled by retrying");
        assertEq(adapter.latestRequestOf(address(board)), latestRequest);

        adapter.fulfill(oldRequest, SIGNATURE);
        (,, bool oldDone) = adapter.requests(oldRequest);
        (,, bool latestDone) = adapter.requests(latestRequest);
        assertTrue(oldDone);
        assertFalse(latestDone);
        assertEq(uint256(board.state()), uint256(MonthState.Drawing));
        assertFalse(board.drawPending(), "the old request still counts");
        assertTrue(board.wordReceived());
        assertFalse(board.prizesDrawn());
        assertEq(board.prizePool(), POT);
        assertEq(adapter.lockedRound(address(board)), ROUND, "old fulfillment does not release the latest lock");

        // 最新请求之后交付：主板忽略（已经有随机数），适配器解除锁定；随后照常开奖
        _fulfillAndFinalize(latestRequest);
    }

    function _fulfillAndFinalize(uint256 requestId) internal {
        assertEq(sha256(SIGNATURE), RANDOMNESS, "published drand randomness");
        uint256 beforeGas = gasleft();
        adapter.fulfill(requestId, SIGNATURE);
        uint256 fulfillGas = beforeGas - gasleft();
        console2.log("REPORT real XMonthBoard drand fulfill gas including callback", fulfillGas);
        assertTrue(board.wordReceived());
        assertFalse(board.drawPending());
        assertEq(uint256(board.state()), uint256(MonthState.Drawing));
        (,, bool done) = adapter.requests(requestId);
        assertTrue(done);
        assertEq(adapter.lockedRound(address(board)), 0);

        uint256[] memory beforeBalances = new uint256[](participants.length);
        uint256[] memory expectedPayouts = new uint256[](participants.length);
        uint256 feeBefore = bem.balanceOf(FEE_SAFE);
        uint256 foundationBefore = bem.balanceOf(FOUNDATION);
        for (uint256 i; i < participants.length; ++i) {
            beforeBalances[i] = bem.balanceOf(participants[i]);
        }

        beforeGas = gasleft();
        board.finalizePrizes();
        uint256 finalizeGas = beforeGas - gasleft();
        console2.log("REPORT real XMonthBoard finalizePrizes gas including transfers", finalizeGas);
        assertEq(uint256(board.state()), uint256(MonthState.Settling));
        assertTrue(board.prizesDrawn());
        assertEq(board.prizePool(), 0);
        // v2：奖金池不扣费；一半按比例记给持仓，一半抽 5 个奖
        assertEq(bem.balanceOf(FOUNDATION), foundationBefore, "no 3%");
        assertEq(bem.balanceOf(FEE_SAFE), feeBefore, "no 2%");

        uint256 net = POT / 2;
        uint256 totalPrizes;
        // 所有参与者均投入 4 BEM；使用公开 randomness 和线性区间独立检查中奖槽位。
        for (uint256 k; k < 5; ++k) {
            uint256 threshold = uint256(keccak256(abi.encode(uint256(RANDOMNESS), k))) % board.totalStake();
            uint256 expectedSlot = threshold / board.maxStake() + 1;
            assertEq(board.winnerSlots(k), expectedSlot, "winner derived from authentic drand randomness");
            uint256 bps = k == 0 ? 6000 : (k <= 2 ? 1500 : 500);
            uint256 prize = k == 0 ? net - net * 1500 * 2 / 10_000 - net * 500 * 2 / 10_000 : net * bps / 10_000;
            assertEq(board.prizeAmounts(k), prize);
            expectedPayouts[expectedSlot - 1] += prize;
            totalPrizes += prize;
        }
        assertEq(totalPrizes, net);
        uint256 totalOwed;
        for (uint256 i; i < participants.length; ++i) {
            assertEq(bem.balanceOf(participants[i]) - beforeBalances[i], expectedPayouts[i]);
            totalOwed += _mOwed(board, participants[i]);
        }
        assertApproxEqAbs(
            totalOwed,
            board.totalStake() - board.totalSpent() + (POT - net),
            participants.length,
            "idle principal and the shared half are claimable"
        );
        assertEq(board.accountedBalance(), bem.balanceOf(address(board)));
        assertTrue(monthFactory.hasYieldReport());
        assertEq(monthFactory.lastYieldBoard(), address(board));
    }
}
