// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BLS} from "bls-solidity/libraries/BLS.sol";
import {IRandomSource, IRandomConsumer, IBoardRegistry} from "../interfaces/IRandomSource.sol";

interface IOperatorRegistry is IBoardRegistry {
    function operator() external view returns (address);
}

/// @notice 请求方主板：某地址持有本局几份持仓（v2 月局 holderCount；持仓转让后由新持有人兜底）
interface IBoardParticipants {
    function holderCount(address account) external view returns (uint256);
}

/// @title drand evmnet 随机数适配器（M2，替代 Chainlink VRF）
/// @notice 不可升级，没有管理员。drand evmnet（chain hash 04f1e906…6ec8c3，League of Entropy）每 3 秒产生一轮
///         BLS 签名，方案 `bls-bn254-unchained-on-g1`：签名在 BN254 G1，公钥在 G2，被签的消息是 keccak256(round)。
///         1. 主板请求随机数时，适配器锁定一个**未来**的轮次 R（当前时间 + minDelay 之后第一轮），这时还没人知道它的签名；
///         2. 运营地址提交第 R 轮的签名（运营地址为 0 时任何参与者都可以）；第 R 轮产生满 operatorGrace（3 天）后，
///            请求方主板的参与者也可以代交；
///         3. 用 BN254 预编译验签，通过后随机数 = sha256(签名)（和 drand 公布的 randomness 相同，可以在 api.drand.sh 核对）。
///         每一轮的签名是确定的，谁提交都一样，提交的人只能决定"什么时候交"，决定不了结果。
///         **重发沿用同一轮次**：同一块主板在它最新的请求被交付之前再次请求（主板的 retryDraw），新请求仍然锁定
///         原来那一轮。否则运营地址可以在第 R 轮公开后扣着不交、等 24 小时重发换一轮，等于可以重抽。
///         验签库：randa-mu/bls-solidity @ 9e10df9（zkSecurity 2025-09 审计范围内），见 lib/bls-solidity/VENDORED.md。
/// @dev 主板回调失败时整笔提交 revert（不会把随机数白白用掉），提交者可以带更多 gas 重交；
///      过期请求由主板自己忽略（不 revert）。
contract DrandEvmnetAdapter is IRandomSource {
    /// @notice evmnet 的创世时间和周期（https://api.drand.sh/v2/beacons/evmnet/info，2026-10-21 读取）
    uint256 public constant GENESIS_TIME = 1727521075;
    uint256 public constant PERIOD = 3;
    string public constant DST = "BLS_SIG_BN254G1_XMD:KECCAK-256_SVDW_RO_NUL_";

    IOperatorRegistry public immutable registry;
    uint256 public immutable minDelay;
    uint256 public immutable operatorGrace;

    struct Request {
        address consumer;
        uint64 round;
        bool fulfilled;
    }

    uint256 public lastRequestId;
    mapping(uint256 => Request) public requests;
    /// @notice 每块主板最新的请求编号
    mapping(address => uint256) public latestRequestOf;
    /// @notice 每块主板当前锁定的轮次：它最新的请求被交付之前，再次请求都沿用这一轮（0 = 没有锁定）
    mapping(address => uint64) public lockedRound;

    event RandomnessRequested(uint256 indexed requestId, address indexed consumer, uint64 round);
    event RandomnessDelivered(uint256 indexed requestId, address indexed consumer, uint64 round, uint256 randomness);

    error BadConfig();
    error NotBoard();
    error UnknownRequest();
    error AlreadyFulfilled();
    error NotAuthorized();
    error InvalidSignature();

    constructor(address registry_, uint256 minDelay_, uint256 operatorGrace_) {
        if (registry_ == address(0) || minDelay_ < PERIOD || operatorGrace_ > 3650 days) revert BadConfig();
        registry = IOperatorRegistry(registry_);
        minDelay = minDelay_;
        operatorGrace = operatorGrace_;
    }

    /// @notice evmnet 公钥（G2，和 bls-solidity 的 EvmnetRegistry 相同的坐标顺序）
    function publicKey() public pure returns (BLS.PointG2 memory) {
        return BLS.PointG2(
            [
                0x557ec32c2ad488e4d4f6008f89a346f18492092ccc0d594610de2732c8b808f,
                0x7e1d1d335df83fa98462005690372c643340060d205306a9aa8106b6bd0b382
            ],
            [
                0x297d3a4f9749b33eb2d904c9d9ebf17224150ddd7abd7567a9bec6c74480ee0b,
                0x95685ae3a85ba243747b1b2f426049010f6b73a0cf1d389351d5aaaa1047f6
            ]
        );
    }

    /// @notice 第 round 轮的产生时间
    function roundTime(uint64 round) public pure returns (uint256) {
        return GENESIS_TIME + (uint256(round) - 1) * PERIOD;
    }

    /// @notice 时间 t（含）之后产生的第一轮
    function roundAt(uint256 t) public pure returns (uint64) {
        if (t <= GENESIS_TIME) return 1;
        return uint64((t - GENESIS_TIME + PERIOD - 1) / PERIOD + 1);
    }

    function requestRandomness() external returns (uint256 requestId) {
        if (!registry.isBoard(msg.sender)) revert NotBoard();
        uint64 round = lockedRound[msg.sender];
        if (round == 0) {
            round = roundAt(block.timestamp + minDelay);
            lockedRound[msg.sender] = round;
        }
        requestId = ++lastRequestId;
        requests[requestId] = Request({consumer: msg.sender, round: round, fulfilled: false});
        latestRequestOf[msg.sender] = requestId;
        emit RandomnessRequested(requestId, msg.sender, round);
    }

    /// @notice 验证第 round 轮的签名（64 字节：x ‖ y，各 32 字节大端），返回随机数 sha256(签名)
    function verify(uint64 round, bytes calldata signature) public view returns (uint256 randomness) {
        BLS.PointG1 memory sig = BLS.g1Unmarshal(signature);
        if (!BLS.isValidPointG1(sig)) revert InvalidSignature();
        BLS.PointG1 memory message = BLS.hashToPoint(bytes(DST), abi.encodePacked(keccak256(abi.encodePacked(round))));
        (bool pairingOk, bool callOk) = BLS.verifySingle(sig, publicKey(), message);
        if (!pairingOk || !callOk) revert InvalidSignature();
        return uint256(sha256(signature));
    }

    /// @notice 提交请求锁定的那一轮的签名，验签通过后回调主板。
    function fulfill(uint256 requestId, bytes calldata signature) external {
        Request storage q = requests[requestId];
        address consumer = q.consumer;
        if (consumer == address(0)) revert UnknownRequest();
        if (q.fulfilled) revert AlreadyFulfilled();
        _auth(consumer, q.round);
        uint256 randomness = verify(q.round, signature);
        q.fulfilled = true;
        // 交付的是这块主板最新的请求：解除锁定，它下一次请求（例如标准局的下一轮抽签）锁定新的未来轮次
        if (latestRequestOf[consumer] == requestId) lockedRound[consumer] = 0;
        emit RandomnessDelivered(requestId, consumer, q.round, randomness);
        IRandomConsumer(consumer).onRandomness(requestId, randomness);
    }

    /// @dev 运营地址随时可以；运营地址为 0 时请求方主板的持仓持有人随时可以；否则持有人要等这一轮产生满 operatorGrace
    function _auth(address consumer, uint64 round) internal view {
        address op = registry.operator();
        if (op != address(0) && msg.sender == op) return;
        if (IBoardParticipants(consumer).holderCount(msg.sender) == 0) revert NotAuthorized();
        if (op != address(0) && block.timestamp < roundTime(round) + operatorGrace) revert NotAuthorized();
    }
}
