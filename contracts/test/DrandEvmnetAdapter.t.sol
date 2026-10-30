// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {BLS} from "bls-solidity/libraries/BLS.sol";
import {DrandEvmnetAdapter} from "../src/random/DrandEvmnetAdapter.sol";
import {XLayerDefaults} from "../script/XLayerDefaults.sol";

contract DrandRegistryStub {
    address public operator;
    mapping(address => bool) public isBoard;

    function setOperator(address o) external {
        operator = o;
    }

    function setBoard(address b, bool ok) external {
        isBoard[b] = ok;
    }
}

contract DrandConsumerStub {
    DrandEvmnetAdapter public adapter;
    mapping(address => uint256) public holderCount;
    uint256 public calls;
    uint256 public lastRequestId;
    uint256 public lastWord;
    bool public shouldRevert;

    constructor(DrandEvmnetAdapter a) {
        adapter = a;
    }

    function setParticipant(address p) external {
        holderCount[p] = 1;
    }

    function setRevert(bool r) external {
        shouldRevert = r;
    }

    function request() external returns (uint256) {
        return adapter.requestRandomness();
    }

    function onRandomness(uint256 requestId, uint256 word) external {
        require(msg.sender == address(adapter), "only adapter");
        require(!shouldRevert, "consumer reverted");
        calls++;
        lastRequestId = requestId;
        lastWord = word;
    }
}

/// @notice M2：drand evmnet 验签适配器。测试向量是 drand evmnet 的真实轮次（chain hash 04f1e906…6ec8c3），
///         签名和 randomness 来自 https://api.drand.sh/04f1e906…6ec8c3/public/{round}（2026-10-21 读取）。
contract DrandEvmnetAdapterTest is Test {
    // drand evmnet /info 返回的公钥（G2，128 字节，x1 ‖ x0 ‖ y1 ‖ y0）
    bytes internal constant EVMNET_PK =
        hex"07e1d1d335df83fa98462005690372c643340060d205306a9aa8106b6bd0b3820557ec32c2ad488e4d4f6008f89a346f18492092ccc0d594610de2732c8b808f0095685ae3a85ba243747b1b2f426049010f6b73a0cf1d389351d5aaaa1047f6297d3a4f9749b33eb2d904c9d9ebf17224150ddd7abd7567a9bec6c74480ee0b";

    uint64 internal constant R1 = 1_000_000;
    bytes internal constant SIG1 =
        hex"139a803860ff6d842b822b8b37eaeccc4e278dd44440535a976530a1a503e85e11d84b824f18e608a85e627e6b1b08322060cbcf7eca1ea78489252907e8473a";
    bytes32 internal constant RAND1 = 0x4da14d73e62d0c909d143e61a2adce866f6be3e7a9d58b1e32a95c87e780569c;

    uint64 internal constant R2 = 9_000_000;
    bytes internal constant SIG2 =
        hex"2a9c36dc75316c05f3a2f1eefdfac68df477e384d8c6b4265904755f716b6ac917ea24ba8e03d7f7da351a42cf9500dbf298cc9012f194b808d66d74eee12628";
    bytes32 internal constant RAND2 = 0x608f07628e1d7441077cfafd18ed1496295c6c46fc4fe117145bc635d4010c22;

    uint64 internal constant R3 = 12_345_678;
    bytes internal constant SIG3 =
        hex"1f82751a21ca166dcc2c804ddd5846cb5f0f8f4ded7e93a8ec9b34cdc885d99a26353f2dbf384155cc898695316de8ce942f167a0faf3906ca066ebc7200aa86";
    bytes32 internal constant RAND3 = 0x0cf0d7df717120037ba88c57fb0598118b94083501489a3caa209e794f844564;

    uint256 internal constant P = 21888242871839275222246405745257275088696311157297823662689037894645226208583;

    DrandRegistryStub internal reg;
    DrandEvmnetAdapter internal adapter;
    DrandConsumerStub internal board;
    address internal op = address(0x0FE7);
    address internal player = address(0xA11CE);
    address internal stranger = address(0x5757);

    function setUp() public {
        reg = new DrandRegistryStub();
        reg.setOperator(op);
        adapter = new DrandEvmnetAdapter(address(reg), 30, 3 days);
        board = new DrandConsumerStub(adapter);
        reg.setBoard(address(board), true);
        board.setParticipant(player);
    }

    /// @dev 主网默认锁定至少 10 分钟之后的轮次（防链上时间落后真实时间时锁到已经公开的一轮）
    function test_MainnetDefaultLocksTenMinutesAhead() public {
        assertGe(XLayerDefaults.DRAND_MIN_DELAY, 10 minutes);
        DrandEvmnetAdapter a = new DrandEvmnetAdapter(address(reg), XLayerDefaults.DRAND_MIN_DELAY, 3 days);
        DrandConsumerStub b = new DrandConsumerStub(a);
        reg.setBoard(address(b), true);
        vm.warp(1_790_000_000);
        uint256 id = b.request();
        (, uint64 round,) = a.requests(id);
        assertGe(a.roundTime(round), block.timestamp + 10 minutes);
        assertLt(a.roundTime(round), block.timestamp + 10 minutes + a.PERIOD());
    }

    // ---------------- 公钥、轮次时间 ----------------

    function test_PublicKeyMatchesDrandInfo() public view {
        BLS.PointG2 memory a = adapter.publicKey();
        BLS.PointG2 memory b = BLS.g2Unmarshal(EVMNET_PK);
        assertEq(a.x[0], b.x[0]);
        assertEq(a.x[1], b.x[1]);
        assertEq(a.y[0], b.y[0]);
        assertEq(a.y[1], b.y[1]);
        assertTrue(BLS.isValidPointG2(a), "public key on curve");
        assertEq(adapter.GENESIS_TIME(), 1727521075);
        assertEq(adapter.PERIOD(), 3);
    }

    function test_RoundTimeMath() public view {
        assertEq(adapter.roundTime(1), 1727521075);
        assertEq(adapter.roundAt(1727521075), 1);
        assertEq(adapter.roundAt(0), 1);
        uint256 t = adapter.roundTime(R3);
        assertEq(t, 1727521075 + (uint256(R3) - 1) * 3);
        assertEq(adapter.roundAt(t), R3, "exactly at round time");
        assertEq(adapter.roundAt(t - 1), R3);
        assertEq(adapter.roundAt(t - 2), R3);
        assertEq(adapter.roundAt(t - 3), R3 - 1);
        assertEq(adapter.roundAt(t + 1), R3 + 1, "first round at or after t");
    }

    // ---------------- 验签（真实向量）----------------

    function test_VerifyRealRounds() public view {
        assertEq(bytes32(adapter.verify(R1, SIG1)), RAND1, "randomness = sha256(sig) = drand's published value");
        assertEq(bytes32(adapter.verify(R2, SIG2)), RAND2);
        assertEq(bytes32(adapter.verify(R3, SIG3)), RAND3);
    }

    function test_VerifyGas() public view {
        uint256 g = gasleft();
        adapter.verify(R3, SIG3);
        uint256 used = g - gasleft();
        console2.log("REPORT drand verify gas (external call, round 12345678)", used);
        assertLt(used, 250_000);
    }

    function test_RevertWhen_WrongRound() public {
        vm.expectRevert(DrandEvmnetAdapter.InvalidSignature.selector);
        adapter.verify(R1 + 1, SIG1);
        vm.expectRevert(DrandEvmnetAdapter.InvalidSignature.selector);
        adapter.verify(R2, SIG1);
    }

    function test_RevertWhen_TamperedSignature() public {
        bytes memory s = SIG1;
        s[63] = bytes1(uint8(s[63]) ^ 0x01); // y 改一位：不在曲线上
        vm.expectRevert(DrandEvmnetAdapter.InvalidSignature.selector);
        adapter.verify(R1, s);
        s = SIG1;
        s[5] = bytes1(uint8(s[5]) ^ 0x10); // x 改一位
        vm.expectRevert(DrandEvmnetAdapter.InvalidSignature.selector);
        adapter.verify(R1, s);
    }

    /// @dev 同一个点只有一种编码能通过，提交者不能换编码改变 sha256(签名)
    function test_RevertWhen_NonCanonicalOrNegatedSignature() public {
        (uint256 x, uint256 y) = abi.decode(SIG1, (uint256, uint256));
        vm.expectRevert(DrandEvmnetAdapter.InvalidSignature.selector);
        adapter.verify(R1, abi.encodePacked(x + P, y)); // x ≥ p
        vm.expectRevert(DrandEvmnetAdapter.InvalidSignature.selector);
        adapter.verify(R1, abi.encodePacked(x, y + P)); // y ≥ p
        vm.expectRevert(DrandEvmnetAdapter.InvalidSignature.selector);
        adapter.verify(R1, abi.encodePacked(x, P - y)); // −σ：在曲线上但配对不通过
        vm.expectRevert(DrandEvmnetAdapter.InvalidSignature.selector);
        adapter.verify(R1, new bytes(64)); // 无穷远点 / 全 0
        vm.expectRevert(bytes("Invalid G1 bytes length"));
        adapter.verify(R1, abi.encodePacked(SIG1, uint8(0)));
    }

    // ---------------- 请求 ----------------

    function test_RevertWhen_RequestFromNonBoard() public {
        vm.expectRevert(DrandEvmnetAdapter.NotBoard.selector);
        adapter.requestRandomness();
        reg.setBoard(address(board), false);
        vm.expectRevert(DrandEvmnetAdapter.NotBoard.selector);
        board.request();
    }

    function test_RequestLocksFutureRound() public {
        vm.warp(1_790_000_000);
        uint256 id = board.request();
        (address consumer, uint64 round, bool done) = adapter.requests(id);
        assertEq(consumer, address(board));
        assertFalse(done);
        assertGe(adapter.roundTime(round), block.timestamp + 30, "at least 30 s in the future");
        assertLt(adapter.roundTime(round), block.timestamp + 30 + 3);
        assertEq(adapter.lockedRound(address(board)), round);
        assertEq(adapter.latestRequestOf(address(board)), id);
    }

    function test_RevertWhen_BadConfig() public {
        vm.expectRevert(DrandEvmnetAdapter.BadConfig.selector);
        new DrandEvmnetAdapter(address(0), 30, 3 days);
        vm.expectRevert(DrandEvmnetAdapter.BadConfig.selector);
        new DrandEvmnetAdapter(address(reg), 2, 3 days);
        vm.expectRevert(DrandEvmnetAdapter.BadConfig.selector);
        new DrandEvmnetAdapter(address(reg), 30, 3650 days + 1);
    }

    // ---------------- 交付 ----------------

    /// @dev 运营地址提交真实签名：验签通过，主板收到 sha256(签名)
    function test_OperatorFulfillsRealRound() public {
        uint256 id = _requestFor(R3);
        vm.warp(adapter.roundTime(R3) + 5);
        uint256 g = gasleft();
        vm.prank(op);
        adapter.fulfill(id, SIG3);
        console2.log("REPORT drand fulfill gas incl. consumer callback", g - gasleft());
        assertEq(board.calls(), 1);
        assertEq(board.lastRequestId(), id);
        assertEq(bytes32(board.lastWord()), RAND3);
        (,, bool done) = adapter.requests(id);
        assertTrue(done);
        assertEq(adapter.lockedRound(address(board)), 0, "lock released after the latest request is delivered");
        vm.prank(op);
        vm.expectRevert(DrandEvmnetAdapter.AlreadyFulfilled.selector);
        adapter.fulfill(id, SIG3);
    }

    function test_RevertWhen_FulfillWrongSignatureOrUnknown() public {
        uint256 id = _requestFor(R3);
        vm.warp(adapter.roundTime(R3) + 5);
        vm.startPrank(op);
        vm.expectRevert(DrandEvmnetAdapter.InvalidSignature.selector);
        adapter.fulfill(id, SIG1); // 别的轮次的真实签名
        vm.expectRevert(DrandEvmnetAdapter.UnknownRequest.selector);
        adapter.fulfill(id + 1, SIG3);
        vm.stopPrank();
    }

    /// @dev 参与者兜底：这一轮产生满 3 天后才可以代交；非参与者始终不行
    function test_ParticipantFallbackAfterThreeDays() public {
        uint256 id = _requestFor(R3);
        uint256 rt = adapter.roundTime(R3);
        vm.warp(rt + 3 days - 1);
        vm.prank(player);
        vm.expectRevert(DrandEvmnetAdapter.NotAuthorized.selector);
        adapter.fulfill(id, SIG3);
        vm.warp(rt + 3 days);
        vm.prank(stranger);
        vm.expectRevert(DrandEvmnetAdapter.NotAuthorized.selector);
        adapter.fulfill(id, SIG3);
        vm.prank(player);
        adapter.fulfill(id, SIG3);
        assertEq(bytes32(board.lastWord()), RAND3);
    }

    function test_NoOperatorMeansParticipantsAnytime() public {
        reg.setOperator(address(0));
        uint256 id = _requestFor(R3);
        vm.warp(adapter.roundTime(R3));
        vm.prank(stranger);
        vm.expectRevert(DrandEvmnetAdapter.NotAuthorized.selector);
        adapter.fulfill(id, SIG3);
        vm.prank(player);
        adapter.fulfill(id, SIG3);
        assertEq(board.calls(), 1);
    }

    /// @dev 主板回调失败时整笔回滚，请求保持未交付，可以重交
    function test_ConsumerRevertKeepsRequestOpen() public {
        uint256 id = _requestFor(R3);
        vm.warp(adapter.roundTime(R3) + 5);
        board.setRevert(true);
        vm.prank(op);
        vm.expectRevert(bytes("consumer reverted"));
        adapter.fulfill(id, SIG3);
        (,, bool done) = adapter.requests(id);
        assertFalse(done);
        board.setRevert(false);
        vm.prank(op);
        adapter.fulfill(id, SIG3);
        assertEq(board.calls(), 1);
    }

    /// @dev 防重抽：第 R 轮公开后运营地址扣着不交、等 24 小时让主板重发，新请求仍锁定第 R 轮，结果不变
    function test_RetryReusesLockedRound() public {
        uint256 id1 = _requestFor(R3);
        vm.warp(adapter.roundTime(R3) + 1 days); // 第 R 轮早已公开
        uint256 id2 = board.request();
        (, uint64 round2,) = adapter.requests(id2);
        assertEq(round2, R3, "retry keeps the locked round");
        // 旧请求先被交付：不解除锁定（它不是最新请求）
        vm.prank(op);
        adapter.fulfill(id1, SIG3);
        assertEq(adapter.lockedRound(address(board)), R3);
        uint256 id3 = board.request();
        (, uint64 round3,) = adapter.requests(id3);
        assertEq(round3, R3);
        // 最新请求交付：同样的随机数；锁定解除，下一次请求锁定新的未来轮次
        vm.prank(op);
        adapter.fulfill(id3, SIG3);
        assertEq(board.lastRequestId(), id3);
        assertEq(bytes32(board.lastWord()), RAND3);
        assertEq(adapter.lockedRound(address(board)), 0);
        uint256 id4 = board.request();
        (, uint64 round4,) = adapter.requests(id4);
        assertEq(adapter.roundAt(block.timestamp + 30), round4);
        assertGt(round4, R3);
        // id2 仍可交付（主板自己会当作过期请求忽略），不影响新的锁定
        vm.prank(op);
        adapter.fulfill(id2, SIG3);
        assertEq(adapter.lockedRound(address(board)), round4);
    }

    /// @dev 两块主板各自锁定，互不影响
    function test_LocksArePerBoard() public {
        DrandConsumerStub other = new DrandConsumerStub(adapter);
        reg.setBoard(address(other), true);
        uint256 a = _requestFor(R2);
        vm.warp(adapter.roundTime(R3) - 30);
        uint256 b = other.request();
        (, uint64 ra,) = adapter.requests(a);
        (, uint64 rb,) = adapter.requests(b);
        assertEq(ra, R2);
        assertEq(rb, R3);
        vm.startPrank(op);
        adapter.fulfill(b, SIG3);
        adapter.fulfill(a, SIG2);
        vm.stopPrank();
        assertEq(bytes32(other.lastWord()), RAND3);
        assertEq(bytes32(board.lastWord()), RAND2);
    }

    /// @dev 把时间拨到"请求时锁定的正好是第 round 轮"
    function _requestFor(uint64 round) internal returns (uint256 id) {
        vm.warp(adapter.roundTime(round) - 30);
        id = board.request();
        (, uint64 r,) = adapter.requests(id);
        assertEq(r, round);
    }
}
