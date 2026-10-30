// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MonthState, IXMonthFactory} from "../interfaces/IXMonthBoard.sol";
import {IMonthBoardV2} from "../interfaces/IXMonthV2.sol";

interface IMonthMachineSalesPlan {
    function installPlan(address board, uint256[] calldata indexes, uint128[] calldata start, uint128[] calldata floor)
        external;
}

/// @title XMonthExitGovernor（X Layer 月局多数集体清算，单例；从 BSC v2.0-audit.6 MonthExitGovernor 移植，只换接口引用）
/// @notice 结算阶段，持仓持有人可以按原始本金加权、严格过半，批准一个明确的售矿价格计划，把矿机低于成本价卖掉
///         （规格第 7、8 节；项目方 2026-10-22 选项 4a、5a、6a、7a）：
///         1. publishPlan：给本局每一台没卖出的矿机写明 BEM 起价和底价（底价 > 0），得到 planHash；
///         2. support：持有人用自己的持仓支持某个计划（转让后自动作废：记录绑定持仓版本号）；
///         3. openVote：结算开始满 minSettleAge（7 天）、不在冷却期、没有进行中的提案，且支持权重 ≥ 全部原始本金的 10%
///            （向上取整）时，任何人可以开启 24 小时投票；开启后锁定本局所有持仓转让；
///         4. castVote：每份持仓按原始本金计票，截止前可以改票；分母 W = 本局全部原始本金（弃权也在分母里）；
///         5. finalizeVote：截止后任何人可以结算。赞成 > ⌊W ÷ 2⌋ 通过，进入 24 小时执行等待（仍锁定）；否则解锁并冷却；
///         6. execute：等待结束后 48 小时内任何人可以执行：计划写入 MonthMachineSales（7 天从起价线性降到底价，之后保持），
///            主板进入清算（允许低于成本价成交），解锁转让；超时没执行可以 expire（解锁并冷却）。
///         失败 / 过期的冷却：第一次清算 14 天；已经在清算中（改价）7 天。执行后还可以再提更低的计划（改价）。
///         没有管理员，不可升级，不托管任何资金和资产。
contract XMonthExitGovernor {
    uint8 internal constant NONE = 0;
    uint8 internal constant VOTING = 1;
    uint8 internal constant DELAY = 2;

    uint8 public constant YES = 1;
    uint8 public constant NO = 2;
    uint8 public constant ABSTAIN = 3;

    uint256 public constant MAX_PLAN_MACHINES = 100;

    IXMonthFactory public immutable FACTORY;
    IMonthMachineSalesPlan public immutable SALES;
    uint256 public immutable MIN_SETTLE_AGE; // 7 天
    uint256 public immutable VOTE_PERIOD; // 24 小时
    uint256 public immutable EXECUTION_DELAY; // 24 小时
    uint256 public immutable EXECUTION_WINDOW; // 48 小时
    uint256 public immutable FAIL_COOLDOWN; // 14 天
    uint256 public immutable REPRICE_COOLDOWN; // 7 天
    uint256 public constant SUPPORT_BPS = 1_000; // 10%

    struct Plan {
        address board;
        uint256[] indexes;
        uint128[] start;
        uint128[] floor;
    }

    struct Proposal {
        uint8 phase; // 0 无 / 1 投票中 / 2 执行等待
        bytes32 planHash;
        uint64 voteEnd;
        uint64 executeAfter;
        uint64 executeBy;
        uint256 yes;
        uint256 no;
        uint256 abstain;
        uint256 total; // W
    }

    struct Support {
        bytes32 planHash;
        uint64 intentEpoch;
        uint32 positionVersion;
    }

    mapping(bytes32 => Plan) internal _plans;
    mapping(address => Proposal) public proposals; // 每块月局同时最多一个提案
    mapping(address => uint256) public proposalCount;
    mapping(address => uint256) public cooldownUntil;
    mapping(address => uint64) public intentEpoch; // 每次提案结束（失败 / 过期 / 执行）+1，旧意向不自动支持下一次
    mapping(address => mapping(uint256 => Support)) public supportOf; // board → slot
    // board → 提案编号 → slot → 选择（0 没投）
    mapping(address => mapping(uint256 => mapping(uint256 => uint8))) public voteOf;

    event PlanPublished(bytes32 indexed planHash, address indexed board, uint256 machines);
    event SupportChanged(address indexed board, uint256 indexed slot, bytes32 indexed planHash);
    event VoteOpened(
        address indexed board, uint256 indexed proposalId, bytes32 planHash, uint256 support, uint256 total
    );
    event VoteCast(
        address indexed board, uint256 indexed proposalId, uint256 indexed slot, uint8 choice, uint256 weight
    );
    event VoteFinalized(address indexed board, uint256 indexed proposalId, bool passed, uint256 yes, uint256 no);
    event PlanExecuted(address indexed board, uint256 indexed proposalId, bytes32 planHash);
    event ProposalExpired(address indexed board, uint256 indexed proposalId);

    error BadConfig();
    error NotMonthBoard();
    error WrongState();
    error BadPlan();
    error UnknownPlan();
    error NotHolder();
    error TooEarly();
    error CoolingDown();
    error ProposalActive();
    error NotEnoughSupport();
    error NotVoting();
    error BadChoice();
    error SlotsNotSorted();
    error NotExecutable();

    constructor(
        address monthFactory,
        address sales,
        uint256 minSettleAge,
        uint256 votePeriod,
        uint256 executionDelay,
        uint256 executionWindow,
        uint256 failCooldown,
        uint256 repriceCooldown
    ) {
        if (monthFactory == address(0) || sales == address(0)) revert BadConfig();
        if (votePeriod == 0 || executionWindow == 0) revert BadConfig();
        if (
            minSettleAge > 3650 days || votePeriod > 3650 days || executionDelay > 3650 days
                || executionWindow > 3650 days || failCooldown > 3650 days || repriceCooldown > 3650 days
        ) revert BadConfig();
        FACTORY = IXMonthFactory(monthFactory);
        SALES = IMonthMachineSalesPlan(sales);
        MIN_SETTLE_AGE = minSettleAge;
        VOTE_PERIOD = votePeriod;
        EXECUTION_DELAY = executionDelay;
        EXECUTION_WINDOW = executionWindow;
        FAIL_COOLDOWN = failCooldown;
        REPRICE_COOLDOWN = repriceCooldown;
    }

    // ============ 计划与意向 ============

    /// @notice 发布计划：必须列出本局现在每一台没卖出的矿机（序号严格递增），每台写明起价和底价（start ≥ floor > 0，
    ///         start ≥ 这台的成本价）。成交价另由卖矿合约保证不低于当时 BSC 买一 × 算力 × 95%（经 XMarketPriceFeed 转报）。
    ///         任何人可以发布；同样内容的计划得到同一个 planHash。
    function publishPlan(address board, uint256[] calldata indexes, uint128[] calldata start, uint128[] calldata floor)
        external
        returns (bytes32 planHash)
    {
        IMonthBoardV2 b = _board(board);
        if (b.state() != MonthState.Settling || b.claimsClosed()) revert WrongState();
        uint256 n = indexes.length;
        if (n == 0 || n > MAX_PLAN_MACHINES || start.length != n || floor.length != n) revert BadPlan();
        if (n != b.unsoldMachines()) revert BadPlan(); // 完整库存
        uint256 count = b.machineCount();
        for (uint256 i = 0; i < n; i++) {
            if (i > 0 && indexes[i] <= indexes[i - 1]) revert BadPlan();
            if (indexes[i] >= count) revert BadPlan();
            IMonthBoardV2.MachineView memory m = b.machine(indexes[i]);
            // 规则决定 6.33：起价不低于这台的成本价，计划是从成本往下的降价拍卖；成交下限见 XMonthMachineSales
            if (m.sold || floor[i] == 0 || start[i] < floor[i] || start[i] < m.cost) revert BadPlan();
        }
        planHash = keccak256(abi.encode(board, indexes, start, floor));
        if (_plans[planHash].board == address(0)) {
            Plan storage p = _plans[planHash];
            p.board = board;
            p.indexes = indexes;
            p.start = start;
            p.floor = floor;
            emit PlanPublished(planHash, board, n);
        }
    }

    /// @notice 用自己持有的持仓支持某个计划（每份持仓同时只支持一个；转让后作废）。
    function support(address board, uint256[] calldata slots, bytes32 planHash) external {
        IMonthBoardV2 b = _board(board);
        if (_plans[planHash].board != board) revert UnknownPlan();
        uint64 epoch = intentEpoch[board];
        for (uint256 i = 0; i < slots.length; i++) {
            IMonthBoardV2.Position memory p = b.socket(slots[i]);
            if (p.owner != msg.sender) revert NotHolder();
            supportOf[board][slots[i]] = Support(planHash, epoch, p.version);
            emit SupportChanged(board, slots[i], planHash);
        }
    }

    function withdrawSupport(address board, uint256[] calldata slots) external {
        IMonthBoardV2 b = _board(board);
        for (uint256 i = 0; i < slots.length; i++) {
            if (b.socket(slots[i]).owner != msg.sender) revert NotHolder();
            delete supportOf[board][slots[i]];
            emit SupportChanged(board, slots[i], bytes32(0));
        }
    }

    /// @notice 某份持仓当前对 planHash 的支持是否有效（同一轮意向、转让后没有作废）
    function supportValid(address board, uint256 slot, bytes32 planHash) public view returns (bool) {
        Support memory s = supportOf[board][slot];
        return s.planHash == planHash && planHash != bytes32(0) && s.intentEpoch == intentEpoch[board]
            && s.positionVersion == IMonthBoardV2(board).socket(slot).version;
    }

    // ============ 正式投票 ============

    /// @notice 开启正式投票：传入支持这个计划的持仓（严格递增，不能重复）；有效支持权重 ≥ W 的 10% 才能开启。
    function openVote(address board, bytes32 planHash, uint256[] calldata supporterSlots) external {
        IMonthBoardV2 b = _board(board);
        if (_plans[planHash].board != board) revert UnknownPlan();
        if (b.state() != MonthState.Settling || b.claimsClosed() || b.unsoldMachines() == 0) revert WrongState();
        if (block.timestamp < b.settleStart() + MIN_SETTLE_AGE) revert TooEarly();
        if (block.timestamp < cooldownUntil[board]) revert CoolingDown();
        Proposal storage p = proposals[board];
        if (p.phase != NONE) revert ProposalActive();
        uint256 weight;
        for (uint256 i = 0; i < supporterSlots.length; i++) {
            if (i > 0 && supporterSlots[i] <= supporterSlots[i - 1]) revert SlotsNotSorted();
            if (supportValid(board, supporterSlots[i], planHash)) weight += b.socket(supporterSlots[i]).stake;
        }
        uint256 total = b.totalStake();
        if (weight * 10_000 < total * SUPPORT_BPS) revert NotEnoughSupport();
        uint256 id = ++proposalCount[board];
        proposals[board] = Proposal({
            phase: VOTING,
            planHash: planHash,
            voteEnd: uint64(block.timestamp + VOTE_PERIOD),
            executeAfter: 0,
            executeBy: 0,
            yes: 0,
            no: 0,
            abstain: 0,
            total: total
        });
        b.setGovernanceLock(true);
        emit VoteOpened(board, id, planHash, weight, total);
    }

    /// @notice 投票 / 改票：choice 1 赞成、2 反对、3 弃权；调用者必须是这些持仓的持有人（投票期间持仓不能转让）。
    function castVote(address board, uint256[] calldata slots, uint8 choice) external {
        if (choice < YES || choice > ABSTAIN) revert BadChoice();
        IMonthBoardV2 b = _board(board);
        Proposal storage p = proposals[board];
        if (p.phase != VOTING || block.timestamp >= p.voteEnd) revert NotVoting();
        uint256 id = proposalCount[board];
        for (uint256 i = 0; i < slots.length; i++) {
            IMonthBoardV2.Position memory pos = b.socket(slots[i]);
            if (pos.owner != msg.sender) revert NotHolder();
            uint256 w = pos.stake;
            uint8 old = voteOf[board][id][slots[i]];
            if (old == YES) p.yes -= w;
            else if (old == NO) p.no -= w;
            else if (old == ABSTAIN) p.abstain -= w;
            if (choice == YES) p.yes += w;
            else if (choice == NO) p.no += w;
            else p.abstain += w;
            voteOf[board][id][slots[i]] = choice;
            emit VoteCast(board, id, slots[i], choice, w);
        }
    }

    /// @notice 投票截止后任何人可以结算：赞成 > ⌊W ÷ 2⌋ 通过（进入执行等待，仍锁定）；否则解锁并冷却。
    function finalizeVote(address board) external {
        IMonthBoardV2 b = _board(board);
        Proposal storage p = proposals[board];
        if (p.phase != VOTING) revert NotVoting();
        if (block.timestamp < p.voteEnd) revert TooEarly();
        uint256 id = proposalCount[board];
        bool passed = p.yes > p.total / 2;
        emit VoteFinalized(board, id, passed, p.yes, p.no);
        if (passed) {
            p.phase = DELAY;
            p.executeAfter = uint64(block.timestamp + EXECUTION_DELAY);
            p.executeBy = uint64(block.timestamp + EXECUTION_DELAY + EXECUTION_WINDOW);
        } else {
            _end(board, b, true);
        }
    }

    /// @notice 执行等待结束后、执行有效期内任何人可以执行：计划写入卖矿合约（只针对仍未卖出的矿机），主板进入清算，解锁转让。
    function execute(address board) external {
        IMonthBoardV2 b = _board(board);
        Proposal storage p = proposals[board];
        if (p.phase != DELAY || block.timestamp < p.executeAfter || block.timestamp >= p.executeBy) {
            revert NotExecutable();
        }
        uint256 id = proposalCount[board];
        bytes32 planHash = p.planHash;
        Plan storage pl = _plans[planHash];
        // 只保留仍未卖出的矿机（投票期间按 ≥ 成本价卖掉的跳过）
        uint256 n = pl.indexes.length;
        uint256 k;
        uint256[] memory idx = new uint256[](n);
        uint128[] memory st = new uint128[](n);
        uint128[] memory fl = new uint128[](n);
        for (uint256 i = 0; i < n; i++) {
            if (b.machine(pl.indexes[i]).sold) continue;
            idx[k] = pl.indexes[i];
            st[k] = pl.start[i];
            fl[k] = pl.floor[i];
            k++;
        }
        assembly {
            mstore(idx, k)
            mstore(st, k)
            mstore(fl, k)
        }
        _end(board, b, false);
        if (k > 0 && b.state() == MonthState.Settling && !b.claimsClosed()) {
            SALES.installPlan(board, idx, st, fl);
            b.startLiquidation();
        }
        emit PlanExecuted(board, id, planHash);
    }

    /// @notice 执行有效期过了还没执行：任何人可以让提案失效，解锁并冷却。
    function expire(address board) external {
        IMonthBoardV2 b = _board(board);
        Proposal storage p = proposals[board];
        if (p.phase != DELAY || block.timestamp < p.executeBy) revert NotExecutable();
        emit ProposalExpired(board, proposalCount[board]);
        _end(board, b, true);
    }

    function plan(bytes32 planHash)
        external
        view
        returns (address board, uint256[] memory indexes, uint128[] memory start, uint128[] memory floor)
    {
        Plan storage p = _plans[planHash];
        return (p.board, p.indexes, p.start, p.floor);
    }

    // ============ 内部 ============

    function _board(address board) internal view returns (IMonthBoardV2) {
        if (!FACTORY.isBoard(board)) revert NotMonthBoard();
        return IMonthBoardV2(board);
    }

    /// @dev 结束当前提案：解锁转让、意向轮次 +1；失败 / 过期时进入冷却（已经在清算中的改价 7 天，否则 14 天）
    function _end(address board, IMonthBoardV2 b, bool failed) internal {
        delete proposals[board];
        intentEpoch[board] += 1;
        if (failed) cooldownUntil[board] = block.timestamp + (b.liquidating() ? REPRICE_COOLDOWN : FAIL_COOLDOWN);
        b.setGovernanceLock(false);
    }
}
