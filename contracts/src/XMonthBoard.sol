// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ICircuits, IBeacon} from "./interfaces/ITapeOut.sol";
import {IMachineSource} from "./interfaces/IMachineSource.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IRandomSource, IRandomConsumer} from "./interfaces/IRandomSource.sol";
import {IRewardTarget, IBoardHub} from "./interfaces/IHub.sol";
import {MonthState, IXMonthFactory} from "./interfaces/IXMonthBoard.sol";
import {IMonthBoardV2, IMonthPositions, IMonthSalesFeed, IXPriceQuote} from "./interfaces/IXMonthV2.sol";
import {EjectionTree} from "./libraries/EjectionTree.sol";
import {PrizeDraw} from "./libraries/PrizeDraw.sol";

/// @title XMonthBoard（X Layer 月局 v2，每局一个）
/// @notice 不可升级，没有能改规则、参数或资金去向的管理员。唯一的特权角色是运营地址（只能开奖、提交 drand 签名、
///         通过 XMonthMachineSales 交接 / 分批推送、转报 BSC 行情，3 天不执行由本局持仓持有人兜底），由手续费 Safe 通过
///         XHub.setOperator 更换。
///
///         规则以 BSC 主网 v2.0-audit.6 的月局为准（V2-PORT.md，项目方 2026-10-27 决定），X Layer 特有的部分：
///         矿机是 RIG 凭证（IMachineSource），产出经 LayerZero 普通转账到账、按余额增量记账（accountedBalance）；
///         随机数是 drand 链上验签；收购价上限的快照用月局工厂记录的实测单位日产出（BSC 读 PoD 的产出速率）；收购价上限、结算卖价、集体清算的计划价下限用运营地址从 BSC 转报的买一 / 卖一（XMarketPriceFeed，公式同 BSC）。
///
///         每个插槽是一份持仓，凭证是 XMonthPositions 的 ERC-721（编号 = 主板地址 << 96 | slot）。
///         持仓只在结算阶段可以整份转让，所有转移路径都经过 onPositionTransfer（锁、结转、退通行证、版本号）。
///         结算阶段的卖矿定价（卖价公式、交接、清算计划）在单例 XMonthMachineSales；主板只负责交割和记账：
///         没有清算计划时成交价不得低于成本价（releaseMachine 里再查一次）。多数集体清算由 XMonthExitGovernor 发起。
///         由 XMonthFactory 用 EIP-1167 最小代理部署，参数在实现合约构造时写死；
///         每块月局的目标金额与投入范围由 XMonthFactory 在开出时传入（initialize）。
///
/// 一局的流程（白皮书第 6 节、规则文档 §8）：
///   1. 招募（3 天）：投入目标的 0.2%–4%，另付 1% 入场费（开始挖矿时转给手续费地址；招募失败、或一台矿机都没挖就
///      结算时按投入比例退还），通行证锁进主板。
///      招满即开局；到期 ≥ 60% 按实际金额开局；< 60% 全员退款并重招。
///   2. 准备矿机（Preparing，最多 3 天）：收购拍卖（sellMachine）——任何 RIG 持有人可以按当前收购价把合格的凭证卖给本局，
///      收购价从上限 × buyStartBps 起逐步上涨到上限（上限 = min(BSC 卖一, 开局快照)，报价无效时暂停收购，同 BSC）；正在结算的旧月局也可以把矿机交接进来（relayOut → sellMachine），
///      旧局要求不低于它的成本价；RIG 矿机市场（XRigMarket.sellAskToBoard）上单价不高于当前收购价的卖单也可以卖进来，
///      按卖单实价付款（对应 BSC MarketTrader）。买满（100 台，或剩余预算按当前收购价连一台最小算力的矿机都买不下）就提前开始挖矿。
///      买不满的 BEM 留在主板，局终原样退还。
///   3. 挖矿 30 天（Mining）：产出全部进入奖金池。
///   4. 开奖（drawPrizes → drand 回调 onRandomness 只记下随机数 → finalizePrizes）：奖金池不扣费（月局只收入场费）。
///      一半按投入比例分给所有持仓（记账领取），另一半用一个 drand 随机数派生 5 次独立抽取（60 / 15 / 15 / 5 / 5），
///      每次都按"个人投入 ÷ 总投入"抽，可重复中奖；奖金直接推送。
///   5. 收回本金（Settling）：矿机经 XMonthMachineSales 按 BSC 的卖价公式出售（整台不低于成本价）或交接给正在准备矿机的月局
///      （按对方的收购价，不低于成本价）。卖不出的矿机继续挖，产出按投入比例分给本局持仓。多数清算计划执行后，
///      才可以按计划价（可以低于成本价）卖出。成交额超过成本价的部分收 10% 溢价分成给手续费地址。
///      收回的资金按顺序：先退参与者的本金（按投入比例）→ 再收回回馈部分（转入月局工厂，滚给下一块开局的月局）
///      → 超出成本的部分按投入比例分给参与者。
///   异常：drand 24 小时可重发（本局的请求都有效，先到先用）；停摆超过 7 天不抽奖，奖金池按投入比例分给所有人，
///         本金照常收回；升级哨兵触发后进入 30 天冷静期（暂停加入、矿机收购 / 出售 / 交接，见 sentinelPaused），
///         参与者可以对还没到期的局发起提前结算（同停摆）。
///
/// 发放：开奖时奖金直接推送；其余款项按持仓记账，任何人都可以 withdraw / claimAll 某份持仓（付给它的持有人）；
///       运营地址经 XMonthMachineSales.distribute 分批推送并退还通行证（3 天后持有人兜底）。
/// 领取期限 365 天（从招募失败或卖完最后一台矿机起算），过期未领的 BEM 转到 0x…dEaD 销毁；之后迟到的跨链产出同样销毁。
contract XMonthBoard is IRewardTarget, IRandomConsumer, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EjectionTree for EjectionTree.Tree;

    uint256 public constant BPS = 10_000;
    uint256 internal constant ACC_SCALE = 1e18;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// @dev 构造参数里任何时长的上限（10 年）
    uint256 internal constant MAX_DURATION_PARAM = 3650 days;

    struct Config {
        // 外部合约
        address bem;
        address machineSource;
        address passCircuits; // 由 XMonthFactory 从 XHub 读取
        address passBeacon;
        bytes32 passNetlistHash;
        address foundation;
        address feeRecipient;
        address randomSource;
        address splitter; // 由 XMonthFactory 从 XHub 读取
        address hub; // XHub（注册中心，存放运营地址），由 XMonthFactory 填入
        address positions; // XMonthPositions（持仓凭证，单例）
        address sales; // XMonthMachineSales（结算阶段卖矿定价，单例）
        address governor; // XMonthExitGovernor（多数集体清算，单例）
        address market; // XRigMarket（RIG 矿机市场，单例）：收购时按它转来的卖单实价付款
        // 招募
        uint256 entryFeeBps; // 1%
        uint256 premiumFeeBps; // 卖矿溢价分成（1000 = 10%）：成交额超过成本价的部分按这个比例给手续费地址
        uint256 recruitDuration; // 3 天
        uint256 minStartBps; // 60%
        // 准备矿机（收购拍卖，以"每单位权重 365 天产出"为上限）
        uint256 buyStartBps;
        uint256 buyStepBps;
        uint256 buyStepInterval;
        uint256 buyCapDays; // 收购价上限 = 实测单位日产出 × buyCapDays（由 XMonthFactory.roundCap 计算）
        uint256 buyMaxPrice; // 部署上限（同上）
        uint256 prepDuration; // 收购期最多 3 天
        uint256 minMachineWeight;
        uint256 maxMachineWeight;
        uint256 maxMachines;
        // 挖矿
        uint256 miningDuration; // 30 天
        // 随机数与领取
        uint256 vrfRetryDelay; // 沿用原配置字段名；现在用于 drand 请求重试
        uint256 vrfSafeExitDelay; // 沿用原配置字段名；现在用于 drand 停摆结算
        uint256 operatorGrace; // 运营地址多久没执行，本局持有人可以兜底（3 天）
        uint256 claimWindow; // 365 天
        uint256 sentinelResumeDelay; // 升级哨兵冷静期：登记满这么久后恢复加入、开新主板、矿机收购和出售（30 天，外部审计 #2）
    }

    // 关键地址公开；数值参数为 internal，可通过 XMonthFactory.boardConfig() 读取
    IERC20 public immutable BEM;
    IMachineSource public immutable MACHINE_SOURCE;
    address public immutable MACHINE_TOKEN;
    address public immutable PASS_CIRCUITS;
    address public immutable PASS_BEACON;
    address internal immutable PASS_IMPL_AT_DEPLOY;
    bytes32 public immutable PASS_NETLIST_HASH;
    address public immutable FOUNDATION;
    address public immutable FEE_RECIPIENT;
    address public immutable RANDOM_SOURCE;
    address public immutable SPLITTER;
    address public immutable FACTORY;
    address public immutable HUB;
    address public immutable POSITIONS;
    address public immutable SALES;
    address public immutable GOVERNOR;
    /// @notice RIG 矿机市场（XRigMarket）：收购拍卖之外的第二个收购来源，按卖单实价付款（对应 BSC 的 TRADER）
    address public immutable MARKET;

    uint256 internal immutable ENTRY_FEE_BPS;
    /// @notice 卖矿溢价分成比例
    uint256 public immutable PREMIUM_FEE_BPS;
    uint256 internal immutable RECRUIT_DURATION;
    uint256 internal immutable MIN_START_BPS;
    uint256 internal immutable BUY_START_BPS;
    uint256 internal immutable BUY_STEP_BPS;
    uint256 internal immutable BUY_STEP_INTERVAL;
    uint256 internal immutable PREP_DURATION;
    uint256 internal immutable MIN_MACHINE_WEIGHT;
    uint256 internal immutable MAX_MACHINE_WEIGHT;
    uint256 internal immutable MAX_MACHINES;
    uint256 internal immutable MINING_DURATION;
    uint256 internal immutable VRF_RETRY_DELAY;
    uint256 internal immutable VRF_SAFE_EXIT_DELAY;
    uint256 internal immutable OPERATOR_GRACE;
    uint256 internal immutable CLAIM_WINDOW;
    uint256 internal immutable SENTINEL_RESUME_DELAY;

    // ============ 存储 ============

    struct Socket {
        address owner;
        uint96 stake;
        uint256 passId;
        uint128 claimed; // 已领取的按比例份额
        bool refunded;
        bool passReturned;
        uint32 version; // 持仓版本号：每次转让 +1，旧订单随之失效
    }

    /// @dev 字段顺序和类型与 IMonthBoardV2.MachineView 完全相同；X Layer 上 key 恒为 0，collection 是 RIG 合约
    struct Machine {
        bytes32 key;
        uint256 circuitId;
        address collection;
        uint64 weight; // 收购时的计价算力
        bool active;
        bool sold;
        uint128 cost; // 成本价：买入时付的 BEM
    }

    MonthState public state;
    uint256 public number;
    uint256 public target;
    uint256 public minStake;
    uint256 public maxStake;
    uint256 internal openedAt;
    uint256 public recruitDeadline;
    uint256 public startedAt;

    uint256 public socketCount;
    mapping(uint256 => Socket) internal _sockets;
    /// @notice 每个地址在本局持有几份持仓（招募时每个地址最多加入一次；结算阶段可以通过转让持有多份）
    mapping(address => uint256) public holderCount;
    /// @notice 转让时退通行证失败的插槽：通行证归这个地址（加入者），之后 returnPass 退给它
    mapping(uint256 => address) public passOwner;
    uint256 public totalStake;
    uint256 public totalEntryFees;
    EjectionTree.Tree internal _tree;

    // 资本：本金（totalStake）+ 回馈（splitter 补贴与上一批月局滚存过来的资金）
    uint256 public budget; // 还没花掉的资本
    uint256 internal _roundCap; // 收购开始时的收购价上限快照（外部审计 #3），见 buyPriceCap
    uint256 public subsidyCapital;

    uint256 public prepEnd;
    uint256 public miningStart;
    uint256 public miningEnd;
    Machine[] internal _machines;
    uint256 public unsoldMachines;
    uint256 public totalSpent;
    uint256 public activeWeight;

    // 开奖
    uint256 public prizePool;
    bool public drawPending;
    uint256 public pendingRequestId;
    /// @dev 本局发出的随机数请求（只开一次奖，重发的请求都有效，先到先用）
    mapping(uint256 => bool) internal _ourRequest;
    uint256 internal wordReceivedAt;
    uint256 internal lastRequestAt;
    uint256 internal firstRequestAt;
    bool public wordReceived; // drand 已交付随机数，等待 finalizePrizes
    uint256 internal drawWord;
    bool public prizesDrawn;
    uint256[5] public winnerSlots;
    uint256[5] public prizeAmounts;

    // 结算
    uint256 public settleStart;
    uint256 public principalRemaining; // 还没退还的参与者本金
    uint256 public subsidyRemaining; // 还没收回的回馈资本
    uint256 public rolledOver; // 已转入月局工厂（滚给下一块月局）的回馈资本
    uint256 internal accShare; // 每单位投入累计可领取的金额（× 1e18）：本金、超出成本的部分、局终后的产出

    mapping(address => uint256) public credit; // 持仓转让时结转给卖方的已累计款项（按地址领取）
    uint256 public liabilities;
    uint256 public finishedAt;
    bool public claimsClosed;

    // v2：持仓交易与清算
    uint64 public tradeEpoch; // 局交易版本号：进入结算、卖出 / 交接矿机、治理锁变化、开始清算时 +1
    bool public governanceLocked; // 清算正式投票与执行等待期间锁定转让
    bool public liquidating; // 多数清算计划已执行：允许按计划价低于成本价卖出

    // X Layer：跨链产出按余额增量记账
    /// @notice 已归类的 BEM 余额；本金、费用、补贴与买卖资金都显式增减，只有未归类净增量才算产出。
    uint256 public accountedBalance;
    /// @notice 领取关闭前累计归类的实收产出 BEM（包含无法与跨链产出区分的直接捐赠）。
    uint256 public yieldReceived;
    /// @notice 各台凭证从收购入局至售出或交接出局的收购权重 × 持有秒数，结算后继续累计。
    uint256 public weightSeconds;
    uint256 public weightUpdatedAt;
    /// @notice 请求随机数后才到账的产出不改变已冻结的奖金池，结算时按投入比例分配。
    uint256 public settlementIncome;

    // ============ 事件 ============

    event Initialized(uint256 indexed number, uint256 target, uint256 minStake, uint256 maxStake, uint256 deadline);
    event Joined(address indexed player, uint256 indexed slot, uint256 passId, uint256 stake, uint256 fee);
    event Started(uint256 totalStake, uint256 entryFees, bool full, uint256 elapsed, uint256 rolloverIn);
    event RecruitmentFailed(uint256 totalStake, uint256 participants);
    event MachineBought(
        uint256 indexed index,
        uint256 indexed circuitId,
        address indexed seller,
        uint256 weight,
        uint256 cost,
        address collection
    );
    event MachineRelayedOut(uint256 indexed index, uint256 indexed circuitId, address indexed toBoard, uint256 price);
    event MachineSold(uint256 indexed index, uint256 indexed circuitId, address indexed buyer, uint256 price);
    event SubsidyDeposited(uint256 amount);
    event MiningStarted(uint256 start, uint256 end, uint256 machines, uint256 weight);
    event Harvested(uint256 amount);
    event DrawRequested(uint256 indexed requestId, address indexed requester, uint256 prizePool);
    event StaleRandomness(uint256 indexed requestId);
    event RandomnessReceived(uint256 indexed requestId, uint256 randomWord);
    event PrizesDrawn(uint256 prizePool, uint256[5] slots, uint256[5] amounts, uint256 toFoundation, uint256 toFee);
    event NoDrawSettlement(uint256 prizePoolSharedProRata);
    event SettlementStarted(uint256 idleCapital);
    event CapitalReturned(uint256 principal, uint256 subsidyRolledOver, uint256 premium);
    event Withdrawn(address indexed account, uint256 amount);
    event PassReturned(address indexed player, uint256 passId);
    /// @param amountBurned 转到 0x…dEaD 的数额
    event ClaimsClosed(uint256 amountBurned);
    event PositionTransferred(uint256 indexed slot, address indexed from, address indexed to, uint256 carriedOver);
    event TradeEpochBumped(uint64 epoch);
    event GovernanceLockSet(bool locked);
    event LiquidationStarted();

    // ============ 错误 ============

    error BadConfig();
    error OnlyFactory();
    error OnlySplitter();
    error OnlyRandomSource();
    error AlreadyInitialized();
    error WrongState();
    error RecruitmentClosed();
    error UpgradeSentinelTripped();
    error AlreadyJoined();
    error BadAmount();
    error NotPassOwner();
    error NotStandardPass();
    error CannotClose();
    error BuyRoundInactive();
    error PriceUnavailable();
    error TooManyMachines();
    error NotMachineOwner();
    error MachineNotEligible();
    error PriceBelowMinimum();
    error InsufficientBudget();
    error NotMonthBoard();
    error RelayUnpaid();
    error NotYet();
    error NoPendingDraw();
    error TooEarly();
    error SentinelNotTripped();
    error NotParticipant();
    error AlreadySold();
    error NotAuthorized();
    error BelowCost();
    error NothingToWithdraw();
    error PassAlreadyReturned();
    error ClaimsAreClosed();
    error TransferLocked();
    error BalanceMismatch();

    // ============ 构造 / 初始化 ============

    constructor(Config memory c) {
        if (
            c.bem == address(0) || c.machineSource == address(0) || c.passCircuits == address(0)
                || c.foundation == address(0) || c.feeRecipient == address(0) || c.randomSource == address(0)
                || c.splitter == address(0)
        ) revert BadConfig();
        if (c.entryFeeBps > 1_000 || c.minStartBps == 0 || c.minStartBps > BPS) revert BadConfig();
        if (c.buyStepInterval == 0 || c.buyStartBps > BPS || c.buyCapDays == 0) revert BadConfig();
        // TapeCode 第三轮 #12：起始收购价不能为 0；基金会和手续费地址必须不同
        if (c.buyStartBps == 0 || c.foundation == c.feeRecipient || c.premiumFeeBps > 5_000) revert BadConfig();
        if (
            c.minMachineWeight == 0 || c.maxMachineWeight < c.minMachineWeight || c.maxMachineWeight > type(uint64).max
                || c.maxMachines == 0 || c.miningDuration == 0
        ) revert BadConfig();
        if (c.vrfSafeExitDelay < c.vrfRetryDelay || c.hub == address(0)) revert BadConfig();
        if (c.positions == address(0) || c.sales == address(0) || c.governor == address(0) || c.market == address(0)) {
            revert BadConfig();
        }
        // 时长类参数（内审 F3）：drand 重发至少隔 1 小时；招募期和准备期不能为 0；全部不超过 10 年
        if (c.vrfRetryDelay < 1 hours || c.recruitDuration == 0 || c.prepDuration == 0) revert BadConfig();
        if (
            c.recruitDuration > MAX_DURATION_PARAM || c.buyStepInterval > MAX_DURATION_PARAM
                || c.prepDuration > MAX_DURATION_PARAM || c.miningDuration > MAX_DURATION_PARAM
                || c.vrfSafeExitDelay > MAX_DURATION_PARAM || c.operatorGrace > MAX_DURATION_PARAM
                || c.claimWindow > MAX_DURATION_PARAM || c.sentinelResumeDelay > MAX_DURATION_PARAM
        ) revert BadConfig();

        BEM = IERC20(c.bem);
        MACHINE_SOURCE = IMachineSource(c.machineSource);
        MACHINE_TOKEN = IMachineSource(c.machineSource).machineToken();
        if (MACHINE_TOKEN == address(0)) revert BadConfig();
        PASS_CIRCUITS = c.passCircuits;
        PASS_BEACON = c.passBeacon;
        PASS_IMPL_AT_DEPLOY = c.passBeacon == address(0) ? address(0) : IBeacon(c.passBeacon).implementation();
        PASS_NETLIST_HASH = c.passNetlistHash;
        FOUNDATION = c.foundation;
        FEE_RECIPIENT = c.feeRecipient;
        RANDOM_SOURCE = c.randomSource;
        SPLITTER = c.splitter;
        FACTORY = msg.sender;
        HUB = c.hub;
        POSITIONS = c.positions;
        SALES = c.sales;
        GOVERNOR = c.governor;
        MARKET = c.market;

        ENTRY_FEE_BPS = c.entryFeeBps;
        PREMIUM_FEE_BPS = c.premiumFeeBps;
        RECRUIT_DURATION = c.recruitDuration;
        MIN_START_BPS = c.minStartBps;
        BUY_START_BPS = c.buyStartBps;
        BUY_STEP_BPS = c.buyStepBps;
        BUY_STEP_INTERVAL = c.buyStepInterval;
        PREP_DURATION = c.prepDuration;
        MIN_MACHINE_WEIGHT = c.minMachineWeight;
        MAX_MACHINE_WEIGHT = c.maxMachineWeight;
        MAX_MACHINES = c.maxMachines;
        MINING_DURATION = c.miningDuration;
        VRF_RETRY_DELAY = c.vrfRetryDelay;
        VRF_SAFE_EXIT_DELAY = c.vrfSafeExitDelay;
        OPERATOR_GRACE = c.operatorGrace;
        CLAIM_WINDOW = c.claimWindow;
        SENTINEL_RESUME_DELAY = c.sentinelResumeDelay;
    }

    /// @notice 由 XMonthFactory 在创建代理的同一笔交易里调用。
    function initialize(uint256 number_, uint256 target_, uint256 minStake_, uint256 maxStake_) external {
        if (msg.sender != FACTORY) revert OnlyFactory();
        if (state != MonthState.Uninitialized) revert AlreadyInitialized();
        if (minStake_ == 0 || maxStake_ < minStake_ || maxStake_ > type(uint96).max || target_ <= maxStake_) {
            revert BadConfig();
        }
        state = MonthState.Recruiting;
        number = number_;
        target = target_;
        minStake = minStake_;
        maxStake = maxStake_;
        openedAt = block.timestamp;
        recruitDeadline = block.timestamp + RECRUIT_DURATION;
        _tree.init(target_ / minStake_ + 1);
        emit Initialized(number_, target_, minStake_, maxStake_, recruitDeadline);
    }

    // ============ 1. 招募（规则同标准局，招募期 3 天）============

    /// @notice 加入本局。投入范围 [minStake, maxStake]，支持小数；超出剩余额度时只接受到恰好满额；
    ///         剩余额度小于 minStake 时也可以投恰好等于剩余额度的金额。入场费另收。
    function join(uint256 passId, uint256 amount) external nonReentrant {
        if (state != MonthState.Recruiting) revert WrongState();
        if (block.timestamp >= recruitDeadline) revert RecruitmentClosed();
        if (sentinelPaused()) revert UpgradeSentinelTripped();
        if (holderCount[msg.sender] != 0) revert AlreadyJoined();

        uint256 remaining = target - totalStake;
        if (amount > maxStake || (amount < minStake && amount != remaining) || amount == 0) revert BadAmount();
        uint256 stake = amount > remaining ? remaining : amount;

        if (ICircuits(PASS_CIRCUITS).ownerOf(passId) != msg.sender) revert NotPassOwner();
        if (keccak256(ICircuits(PASS_CIRCUITS).netlist(passId)) != PASS_NETLIST_HASH) revert NotStandardPass();

        uint256 fee = stake * ENTRY_FEE_BPS / BPS;
        uint256 slot = ++socketCount;
        _sockets[slot] = Socket({
            owner: msg.sender,
            stake: uint96(stake),
            passId: passId,
            claimed: 0,
            refunded: false,
            passReturned: false,
            version: 0
        });
        holderCount[msg.sender] = 1;
        totalStake += stake;
        totalEntryFees += fee;
        _tree.insert(slot, stake);
        IMonthPositions(POSITIONS).mint(msg.sender, slot); // 持仓凭证（_mint，不回调接收方）

        ICircuits(PASS_CIRCUITS).transferFrom(msg.sender, address(this), passId);
        _pull(msg.sender, stake + fee);
        emit Joined(msg.sender, slot, passId, stake, fee);

        if (totalStake == target) _start(true);
    }

    /// @notice 招募期满（或升级哨兵触发）后结束招募：≥ 60% 按实际金额开局；否则全员退款，工厂重开。
    function closeRecruitment() external nonReentrant {
        if (state != MonthState.Recruiting) revert WrongState();
        bool tripped = sentinelPaused(); // 冷静期内可以立即结束招募、全额退款
        if (block.timestamp < recruitDeadline && !tripped) revert CannotClose();
        if (!tripped && socketCount > 0 && totalStake * BPS >= target * MIN_START_BPS) {
            _start(false);
            return;
        }
        state = MonthState.Failed;
        finishedAt = block.timestamp;
        liabilities = totalStake + totalEntryFees;
        emit RecruitmentFailed(totalStake, socketCount);
        IXMonthFactory(FACTORY).onBoardFailed();
    }

    function _start(bool full) internal {
        _claimYield();
        state = MonthState.Preparing;
        startedAt = block.timestamp;
        weightUpdatedAt = block.timestamp;
        prepEnd = block.timestamp + PREP_DURATION;
        budget = totalStake;
        uint256 elapsed = block.timestamp - openedAt;
        // 工厂登记开局顺序、开出下一块、给出本局的收购价上限快照（限制每局涨幅），
        // 并把滚存的回馈资金转进来（作为本局的回馈资本）。入场费到开始挖矿时才转出。
        uint256 beforeRollover = _bemBalance();
        uint256 rollover;
        (rollover, _roundCap) = IXMonthFactory(FACTORY).onBoardStarted(full, elapsed);
        if (_bemBalance() != beforeRollover + rollover) revert BalanceMismatch();
        accountedBalance += rollover;
        if (rollover > 0) {
            budget += rollover;
            subsidyCapital += rollover;
        }
        emit Started(totalStake, totalEntryFees, full, elapsed, rollover);
    }

    // ============ 2. 准备矿机 ============

    function isPurchasing() public view returns (bool) {
        return state == MonthState.Preparing && block.timestamp < prepEnd;
    }

    /// @notice 开局时固定快照（XMonthFactory.roundCap）：min(最近已结束局实测单位日产出 × buyCapDays, 部署上限)，
    ///         相对上一块开局的月局最多上调 max(25%, 部署上限 × 5%)。
    ///         没有历史样本时使用部署上限；实测零收益为有效样本，整局维持零上限。
    function buyPriceCap() public view returns (uint256) {
        return _roundCap;
    }

    /// @notice 当前收购价（每单位权重）：从上限 × buyStartBps 起逐步上涨到上限。上限同 BSC（规则决定 6.37）：
    ///         报价有效时 = min(BSC 卖一, 开局快照)；报价无效（过期、追价、运营地址为 0、停运）时为 0，暂停收购；
    ///         从没报过价时用开局快照（XHub.startGenesis 要求开局前已经报过价，实际用不到）。
    function buyPrice() public view returns (uint256) {
        if (!isPurchasing()) return 0;
        uint256 bps = BUY_START_BPS + ((block.timestamp - startedAt) / BUY_STEP_INTERVAL) * BUY_STEP_BPS;
        if (bps > BPS) bps = BPS;
        uint256 cap = buyPriceCap();
        cap = IXPriceQuote(IMonthSalesFeed(SALES).PRICE_FEED()).buyQuote(cap, cap, startedAt);
        return cap * bps / BPS;
    }

    /// @notice 收购：把一台满足 MACHINE_SOURCE 资格的 RIG 凭证卖给本局（需要事先授权本合约转移凭证）。三种卖家：
    ///         - 任何持有人（收购拍卖）：按当前收购价成交，minPricePerWeight 是卖家要求的最低单价；
    ///         - 同一工厂的旧月局（交接）：同上，最低单价 = ⌈成本价 ÷ 算力⌉；
    ///         - RIG 矿机市场 XRigMarket（对应 BSC MarketTrader，规则决定 6.22 / 6.37）：第三个参数是市场卖单的实价
    ///           （整张的 BEM 总额），按实价付款，不得超过 算力 × 当前收购价。
    function sellMachine(address collection, uint256 circuitId, uint256 minPricePerWeight)
        external
        nonReentrant
        returns (uint256 paid)
    {
        if (collection != MACHINE_TOKEN) revert MachineNotEligible();
        if (!isPurchasing()) revert BuyRoundInactive();
        if (sentinelPaused()) revert UpgradeSentinelTripped();
        if (_machines.length >= MAX_MACHINES) revert TooManyMachines();
        if (IERC721(MACHINE_TOKEN).ownerOf(circuitId) != msg.sender) revert NotMachineOwner();
        _claimYield();
        uint256 weight = MACHINE_SOURCE.purchaseWeight(circuitId);
        if (weight == 0 || weight < MIN_MACHINE_WEIGHT || weight > MAX_MACHINE_WEIGHT) revert MachineNotEligible();
        uint256 price = buyPrice();
        if (price == 0) revert PriceUnavailable();
        paid = weight * price;
        if (msg.sender == MARKET) {
            if (minPricePerWeight > paid) revert PriceBelowMinimum();
            paid = minPricePerWeight;
        } else if (price < minPricePerWeight) {
            revert PriceBelowMinimum();
        }
        if (paid > budget) revert InsufficientBudget();
        _addMachine(circuitId, weight, paid);
        // RIG 按 BSC 收取时的持有人付款；此处只转凭证，不调用赎回或 BSC claim。
        IERC721(MACHINE_TOKEN).transferFrom(msg.sender, address(this), circuitId);
        _pay(msg.sender, paid);
        emit MachineBought(_machines.length - 1, circuitId, msg.sender, weight, paid, MACHINE_TOKEN);
        _sync(); // 买满就开始挖矿
    }

    /// @notice 首批回馈：开局后、局终结算前可以接收补贴。准备阶段可以继续买矿机；之后到账的留到局终，
    ///         和其他回馈资本一起转给下一块月局。
    function acceptsSubsidy() public view returns (bool) {
        return state == MonthState.Preparing || state == MonthState.Mining || state == MonthState.Drawing;
    }

    function rewardEnded() external view returns (bool) {
        return state == MonthState.Settling || state == MonthState.Failed;
    }

    function depositSubsidy(uint256 amount) external nonReentrant {
        if (msg.sender != SPLITTER) revert OnlySplitter();
        if (!acceptsSubsidy()) revert WrongState();
        _pull(msg.sender, amount);
        budget += amount;
        subsidyCapital += amount;
        emit SubsidyDeposited(amount);
    }

    function _addMachine(uint256 circuitId, uint256 weight, uint256 cost) internal {
        if (cost == 0 || cost > type(uint128).max) revert BadAmount();
        _accrueWeight();
        budget -= cost;
        totalSpent += cost;
        activeWeight += weight;
        unsoldMachines += 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        _machines.push(
            Machine({
                key: bytes32(0),
                circuitId: circuitId,
                collection: MACHINE_TOKEN,
                weight: uint64(weight),
                active: true,
                sold: false,
                cost: uint128(cost)
            })
        );
    }

    // ============ 3. 挖矿与开奖 ============

    /// @notice 推进阶段：准备期结束或买满后开始 30 天挖矿（一台矿机都没有时直接结算、原样退还）。任何人可调。
    function sync() external nonReentrant {
        _sync();
        _claimYield();
    }

    function _sync() internal {
        if (state == MonthState.Preparing && (block.timestamp >= prepEnd || _boughtOut())) {
            if (block.timestamp < prepEnd) prepEnd = block.timestamp; // 买满提前结束准备期
            if (_machines.length == 0) {
                _beginSettlement(); // 没挖矿：入场费随本金一起退还
            } else {
                state = MonthState.Mining;
                miningStart = prepEnd;
                miningEnd = prepEnd + MINING_DURATION;
                _pay(FEE_RECIPIENT, totalEntryFees); // 开始挖矿时才收入场费
                emit MiningStarted(miningStart, miningEnd, _machines.length, activeWeight);
            }
        }
    }

    /// @dev 买满：已经有矿机，并且 100 台上限已满，或者剩余预算按当前收购价连一台最小算力的矿机都买不下
    function _boughtOut() internal view returns (bool) {
        uint256 n = _machines.length;
        if (n == 0) return false;
        if (n >= MAX_MACHINES) return true;
        uint256 p = buyPrice();
        return p > 0 && budget < p * MIN_MACHINE_WEIGHT;
    }

    /// @notice 归类已经到账的跨链产出：请求开奖前进奖金池，之后按投入比例分配。任何人可调。
    function harvest() external nonReentrant returns (uint256 got) {
        _sync();
        if (state < MonthState.Preparing) revert WrongState();
        got = _claimYield();
    }

    /// @notice 30 天到期后开奖：先归类已到账产出并固定奖池，再请求随机数。奖金池为 0 时直接进入结算。
    ///         运营地址专属；到期 3 天后本局持有人也可以调用。
    function drawPrizes() external nonReentrant {
        _sync();
        if (state != MonthState.Mining) revert WrongState();
        if (block.timestamp < miningEnd) revert NotYet();
        _auth(miningEnd);
        _claimYield();
        if (prizePool == 0) {
            _beginSettlement();
            return;
        }
        state = MonthState.Drawing;
        firstRequestAt = block.timestamp;
        _requestDraw();
    }

    /// @notice drand 适配器验签后的回调：只记下随机数，实际开奖在 finalizePrizes 执行。
    ///         本局发出的任何一个请求都有效（重发不作废已在路上的结果），先到先用；重复的回调直接忽略。
    function onRandomness(uint256 requestId, uint256 randomWord) external nonReentrant {
        if (msg.sender != RANDOM_SOURCE) revert OnlyRandomSource();
        if (state != MonthState.Drawing || !drawPending || !_ourRequest[requestId]) {
            emit StaleRandomness(requestId);
            return;
        }
        drawPending = false;
        wordReceived = true;
        wordReceivedAt = block.timestamp;
        drawWord = randomWord;
        emit RandomnessReceived(requestId, randomWord);
    }

    /// @notice 用已交付的随机数完成开奖：一半按比例记账，一半 5 次独立抽取直接推送，然后进入收回本金阶段。
    ///         运营地址专属；随机数到账 3 天后本局持有人也可以调用。
    function finalizePrizes() external nonReentrant {
        if (state != MonthState.Drawing || !wordReceived) revert NotYet();
        _auth(wordReceivedAt);
        _payPrizes(drawWord);
        _beginSettlement();
    }

    /// @notice drand 超过 24 小时没响应时可重发请求（再过 3 天持有人可兜底）；旧请求仍然有效。
    function retryDraw() external nonReentrant {
        if (state != MonthState.Drawing || !drawPending) revert NoPendingDraw();
        if (block.timestamp < lastRequestAt + VRF_RETRY_DELAY) revert TooEarly();
        _auth(lastRequestAt + VRF_RETRY_DELAY);
        _requestDraw();
    }

    /// @notice drand 从首次请求起停摆超过 7 天：不抽奖，奖金池按投入比例分给所有人，本金照常收回。
    function triggerSafeSettle() external nonReentrant {
        if (state != MonthState.Drawing || !drawPending) revert NoPendingDraw();
        if (block.timestamp < firstRequestAt + VRF_SAFE_EXIT_DELAY) revert TooEarly();
        _noDrawSettle();
    }

    /// @notice 升级哨兵冷静期内，持有人可以对还没到期的局发起提前结算（规则同 drand 停摆）；已到期的局照常开奖。
    ///         冷静期过后不能再用。
    function emergencySettle() external nonReentrant {
        _sync();
        if (!sentinelPaused()) revert SentinelNotTripped();
        IBoardHub(HUB).noteSentinel(); // 顺带登记触发时间
        if (holderCount[msg.sender] == 0) revert NotParticipant();
        bool early = state == MonthState.Preparing || (state == MonthState.Mining && block.timestamp < miningEnd);
        if (!early) revert WrongState();
        _claimYield();
        _noDrawSettle();
    }

    function _requestDraw() internal {
        drawPending = true;
        lastRequestAt = block.timestamp;
        uint256 id = IRandomSource(RANDOM_SOURCE).requestRandomness();
        pendingRequestId = id;
        _ourRequest[id] = true;
        emit DrawRequested(id, msg.sender, prizePool);
    }

    /// @dev 奖金池不扣费。一半（向上取整）按原始投入比例记给所有持仓（和停摆、开奖后到账的产出同一套 accShare 记账），
    ///      另一半按 60 / 15 / 15 / 5 / 5 直接推送给 5 次独立抽出的中奖者（取整余数并入头奖）。
    ///      PrizesDrawn 的 prizePool 是整个奖金池，amounts 合计为抽奖的一半；toFoundation / toFee 字段保留，恒为 0。
    function _payPrizes(uint256 word) internal {
        uint256 pot = prizePool;
        prizePool = 0;
        uint256 net = pot / 2;
        _shareIncome(pot - net);
        uint256[5] memory slots = PrizeDraw.winners(_tree, totalStake, word);
        uint256[5] memory amounts;
        uint256 paid;
        for (uint256 k = 1; k < PrizeDraw.PRIZES; k++) {
            amounts[k] = net * PrizeDraw.prizeBps(k) / BPS;
            paid += amounts[k];
        }
        amounts[0] = net - paid;
        for (uint256 k = 0; k < PrizeDraw.PRIZES; k++) {
            _pay(_sockets[slots[k]].owner, amounts[k]);
        }
        winnerSlots = slots;
        prizeAmounts = amounts;
        prizesDrawn = true;
        emit PrizesDrawn(pot, slots, amounts, 0, 0);
    }

    function _noDrawSettle() internal {
        drawPending = false;
        _claimYield();
        uint256 pot = prizePool;
        prizePool = 0;
        emit NoDrawSettlement(pot);
        _shareIncome(pot);
        _beginSettlement();
    }

    /// @dev 余额快照不受已知资本收付干扰。随机数请求后的新增产出只记入按比例结算，
    ///      卖完所有凭证后仍可收到在途 LayerZero 款项；领取关闭后到账的转 0x…dEaD 销毁。
    function _claimYield() internal returns (uint256 got) {
        _accrueWeight();
        uint256 balance = _bemBalance();
        if (balance < accountedBalance) revert BalanceMismatch();
        got = balance - accountedBalance;
        if (got == 0) return 0;
        accountedBalance = balance;
        emit Harvested(got);
        if (claimsClosed) {
            _pay(DEAD, got);
        } else if (state == MonthState.Settling) {
            yieldReceived += got;
            _shareIncome(got);
            // 仅新增实收收益刷新报价；没有持有算力样本的空局仍分配款项，但不能报告报价。
            if (weightSeconds > 0) IXMonthFactory(FACTORY).reportYield(unitYieldPerDay());
        } else if (state == MonthState.Drawing) {
            yieldReceived += got;
            settlementIncome += got;
        } else if (state != MonthState.Failed) {
            yieldReceived += got;
            prizePool += got;
        }
    }

    function _accrueWeight() internal {
        if (state < MonthState.Preparing || claimsClosed) return;
        weightSeconds += activeWeight * (block.timestamp - weightUpdatedAt);
        weightUpdatedAt = block.timestamp;
    }

    /// @notice 持有期间的实收 BEM / 收购算力时间，折算为每单位算力日产出。
    /// @dev 由于 RIG 不提供完整历史算力，每台使用买入时的权重持续积分到售出或交接，
    ///      避免结算后继续收收益、分母却冻结在结算时造成报价虚高。新增到账可以刷新未来局的报价，
    ///      已开局快照不变；领取关闭后的到账直接销毁，不再计入收益样本。
    function unitYieldPerDay() public view returns (uint256) {
        uint256 elapsedWeight = weightSeconds;
        if (state >= MonthState.Preparing && !claimsClosed) {
            elapsedWeight += activeWeight * (block.timestamp - weightUpdatedAt);
        }
        return elapsedWeight == 0 ? 0 : Math.mulDiv(yieldReceived, 1 days, elapsedWeight);
    }

    function _pull(address from, uint256 amount) internal {
        _claimYield();
        uint256 beforeBalance = _bemBalance();
        BEM.safeTransferFrom(from, address(this), amount);
        if (_bemBalance() != beforeBalance + amount) revert BalanceMismatch();
        accountedBalance += amount;
    }

    function _pay(address to, uint256 amount) internal {
        if (amount == 0) return;
        accountedBalance -= amount;
        BEM.safeTransfer(to, amount);
    }

    // ============ 4. 收回本金 ============

    function _beginSettlement() internal {
        _claimYield();
        state = MonthState.Settling;
        if (weightSeconds > 0) IXMonthFactory(FACTORY).reportYield(unitYieldPerDay());
        // 没有随机抽奖的剩余收益，以及请求后到账的收益，都按参与比例分给所有持仓。
        // 没开始挖矿就结算（准备期一台都没买到，或升级哨兵冷静期内提前结算）时，入场费还在主板里，按投入比例退还。
        uint256 shared = prizePool + settlementIncome;
        if (miningStart == 0) shared += totalEntryFees;
        prizePool = 0;
        settlementIncome = 0;
        _shareIncome(shared);
        settleStart = block.timestamp;
        principalRemaining = totalStake;
        subsidyRemaining = subsidyCapital;
        uint256 idle = budget;
        budget = 0;
        emit SettlementStarted(idle);
        // 买不满的 BEM 原样退还（同样按"本金 → 回馈 → 超额"的顺序）
        if (idle > 0) _returnCapital(idle);
        _bumpEpoch();
        if (unsoldMachines == 0) finishedAt = block.timestamp;
    }

    /// @notice 交割（只认 XMonthMachineSales）：从卖矿合约收 price 个 BEM，把第 index 台矿机转给 to，按"本金 → 回馈 →
    ///         溢价"记账。定价在卖矿合约；这里再查一次：没有执行多数清算计划时，成交价不得低于成本价。升级哨兵冷静期内暂停。
    function releaseMachine(uint256 index, address to, uint256 price) external nonReentrant {
        if (msg.sender != SALES) revert NotAuthorized();
        if (state != MonthState.Settling) revert WrongState();
        if (sentinelPaused()) revert UpgradeSentinelTripped();
        Machine storage m = _sellOff(index);
        if (price < m.cost && !liquidating) revert BelowCost();
        _pull(msg.sender, price);
        IERC721(MACHINE_TOKEN).transferFrom(address(this), to, m.circuitId);
        _returnCapital(_takePremiumFee(price, m.cost));
        _bumpEpoch();
        emit MachineSold(index, m.circuitId, to, price);
    }

    /// @notice 交接（只认 XMonthMachineSales）：在另一块正在准备矿机的月局（同一个 XMonthFactory）的收购拍卖里当普通卖家，
    ///         按对方当前的收购价卖出；最低单价 = ⌈成本价 ÷ 算力⌉，所以成交额不低于成本价，否则整笔回滚。
    function relayOut(uint256 index, address newBoard) external nonReentrant returns (uint256 paid) {
        if (msg.sender != SALES) revert NotAuthorized();
        if (state != MonthState.Settling) revert WrongState();
        if (sentinelPaused()) revert UpgradeSentinelTripped();
        if (newBoard == address(this) || !IXMonthFactory(FACTORY).isBoard(newBoard)) revert NotMonthBoard();
        Machine storage m = _sellOff(index);
        uint256 cost = m.cost;
        uint256 before = _bemBalance();
        IERC721(MACHINE_TOKEN).approve(newBoard, m.circuitId);
        paid = IMonthBoardV2(newBoard).sellMachine(MACHINE_TOKEN, m.circuitId, (cost + m.weight - 1) / m.weight);
        if (paid < cost || _bemBalance() - before != paid) revert RelayUnpaid();
        accountedBalance += paid;
        _returnCapital(_takePremiumFee(paid, cost));
        _bumpEpoch();
        emit MachineRelayedOut(index, m.circuitId, newBoard, paid);
    }

    /// @notice 清算治理锁（只认 XMonthExitGovernor）：正式投票和执行等待期间锁定持仓转让。
    function setGovernanceLock(bool locked) external {
        if (msg.sender != GOVERNOR) revert NotAuthorized();
        governanceLocked = locked;
        _bumpEpoch();
        emit GovernanceLockSet(locked);
    }

    /// @notice 多数清算计划已执行（只认 XMonthExitGovernor）：之后允许按计划价（可以低于成本价）卖出。
    function startLiquidation() external {
        if (msg.sender != GOVERNOR || state != MonthState.Settling) revert NotAuthorized();
        liquidating = true;
        _bumpEpoch();
        emit LiquidationStarted();
    }

    function _bumpEpoch() internal {
        emit TradeEpochBumped(++tradeEpoch);
    }

    // ============ 持仓转让（只在结算阶段）============

    /// @notice 持仓转移钩子（只认 XMonthPositions：直接转账、授权转账、盘口成交都经过这里）。
    ///         1. 锁：只在结算阶段、领取期限内、没有清算投票 / 执行等待时可以转让；
    ///         2. 结转：先归类新到账，再把卖方已经累计的份额记入 credit[卖方]（卖方之后 withdrawCredit），买方只拿之后的；
    ///         3. 通行证：还没退的立刻退给原持有人（失败不影响转让，记在 passOwner，之后 returnPass）；
    ///         4. 更新持有人、持有计数和持仓版本号（旧订单失效）。
    function onPositionTransfer(uint256 slot, address from, address to) external nonReentrant {
        if (msg.sender != POSITIONS) revert NotAuthorized();
        if (state != MonthState.Settling || claimsClosed || governanceLocked) revert TransferLocked();
        Socket storage s = _sockets[slot];
        _claimYield();
        uint256 share = Math.mulDiv(s.stake, accShare, ACC_SCALE) - s.claimed;
        if (share > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            s.claimed += uint128(share);
            credit[from] += share;
        }
        if (!s.passReturned) {
            address back = passOwner[slot];
            if (back == address(0)) back = from;
            (bool ok,) = PASS_CIRCUITS.call(abi.encodeCall(ICircuits.transferFrom, (address(this), back, s.passId)));
            if (ok) {
                s.passReturned = true;
                emit PassReturned(back, s.passId);
            } else {
                passOwner[slot] = back;
            }
        }
        s.owner = to;
        holderCount[from] -= 1;
        holderCount[to] += 1;
        s.version += 1;
        emit PositionTransferred(slot, from, to, share);
    }

    /// @notice 归类合约里尚未分配的 BEM（卖不出的矿机继续挖的产出、迟到的跨链产出等），按投入比例记给持仓。任何人可调。
    function sweep() external nonReentrant {
        if (state != MonthState.Settling) revert WrongState();
        if (claimsClosed) revert ClaimsAreClosed();
        _claimYield();
    }

    /// @dev 标记售出前归类已到账收益；售出后迟到的跨链产出仍按投入比例归本局持仓。
    function _sellOff(uint256 index) internal returns (Machine storage m) {
        if (claimsClosed) revert ClaimsAreClosed();
        _claimYield();
        m = _machines[index];
        if (m.sold) revert AlreadySold();
        m.sold = true;
        unsoldMachines -= 1;
        if (unsoldMachines == 0) finishedAt = block.timestamp;
        if (m.active) {
            m.active = false;
            activeWeight -= m.weight;
        }
    }

    /// @dev 卖矿溢价分成：成交额超过成本价的部分 × PREMIUM_FEE_BPS 直接转给手续费地址，返回其余金额。
    ///      ≤ 成本价（含多数清算计划的低价卖出）不收。
    function _takePremiumFee(uint256 amount, uint256 cost) internal returns (uint256) {
        if (amount <= cost) return amount;
        uint256 fee = (amount - cost) * PREMIUM_FEE_BPS / BPS;
        _pay(FEE_RECIPIENT, fee);
        return amount - fee;
    }

    /// @dev 收回的资本按顺序：先退参与者本金（按投入比例）→ 再收回回馈资本（转入月局工厂，滚给下一块开局的月局）
    ///      → 超出成本的部分按投入比例分给参与者。
    function _returnCapital(uint256 amount) internal {
        uint256 principal = amount < principalRemaining ? amount : principalRemaining;
        principalRemaining -= principal;
        uint256 rest = amount - principal;
        uint256 toRollover = rest < subsidyRemaining ? rest : subsidyRemaining;
        subsidyRemaining -= toRollover;
        _shareIncome(amount - toRollover);
        if (toRollover > 0) {
            rolledOver += toRollover;
            _pay(FACTORY, toRollover);
        }
        emit CapitalReturned(principal, toRollover, rest - toRollover);
    }

    function _shareIncome(uint256 amount) internal {
        if (amount == 0) return;
        liabilities += amount;
        accShare += Math.mulDiv(amount, ACC_SCALE, totalStake);
    }

    // ============ 领取（按持仓）============

    /// @notice 第 slot 份持仓当前可以领取的 BEM（不含尚未归类的新到账；withdraw 会先归类，所以只会少报）。
    ///         转让时结转给卖方的款项不在这里，见 credit(address)。
    function owed(uint256 slot) public view returns (uint256 amount) {
        if (claimsClosed || slot == 0 || slot > socketCount) return 0;
        Socket storage s = _sockets[slot];
        if (state == MonthState.Failed) {
            if (!s.refunded) amount = uint256(s.stake) + uint256(s.stake) * ENTRY_FEE_BPS / BPS;
            return amount;
        }
        amount = Math.mulDiv(s.stake, accShare, ACC_SCALE) - s.claimed;
    }

    /// @notice 把第 slot 份持仓可领的 BEM 付给它当前的持有人。任何人可调。
    function withdraw(uint256 slot) external nonReentrant returns (uint256 amount) {
        amount = _withdraw(slot, true);
        if (amount == 0) revert NothingToWithdraw();
    }

    /// @notice 把转让时结转给 account 的款项付给它。任何人可调。
    function withdrawCredit(address account) external nonReentrant returns (uint256 amount) {
        if (claimsClosed) revert ClaimsAreClosed();
        amount = credit[account];
        if (amount == 0) revert NothingToWithdraw();
        credit[account] = 0;
        liabilities -= amount;
        _pay(account, amount);
        emit Withdrawn(account, amount);
    }

    function returnPass(uint256 slot) external nonReentrant {
        if (!_returnPass(slot)) revert PassAlreadyReturned();
    }

    /// @notice 领取第 slot 份持仓可领的 BEM，并在可以时退还通行证。任何人可调。
    function claimAll(uint256 slot) external nonReentrant returns (uint256 amount) {
        if (!claimsClosed) amount = _withdraw(slot, true);
        if (state == MonthState.Failed || state == MonthState.Settling) {
            if (!_sockets[slot].passReturned) _returnPass(slot);
        }
    }

    /// @notice 领取期限已过：剩下的 BEM（过期未领与取整尘埃）转到 0x…dEaD 销毁。通行证不过期。
    function closeClaims() external nonReentrant {
        if (finishedAt == 0 || block.timestamp < finishedAt + CLAIM_WINDOW) revert TooEarly();
        _claimYield();
        claimsClosed = true;
        liabilities = 0;
        prizePool = 0;
        settlementIncome = 0;
        uint256 bal = _bemBalance();
        if (bal > 0) _pay(DEAD, bal);
        emit ClaimsClosed(bal);
    }

    /// @dev 运营地址专属；运营地址在 since 之后 operatorGrace 内没执行，本局持仓的持有人可以执行；
    ///      运营地址为 0 时持有人随时可以执行。其他地址始终不行。
    function _auth(uint256 since) internal view {
        address op = IBoardHub(HUB).operator();
        if (op != address(0) && msg.sender == op) return;
        if (holderCount[msg.sender] == 0) revert NotAuthorized();
        if (op != address(0) && block.timestamp < since + OPERATOR_GRACE) revert NotAuthorized();
    }

    function _withdraw(uint256 slot, bool doSweep) internal returns (uint256 amount) {
        if (claimsClosed) revert ClaimsAreClosed();
        if (slot == 0 || slot > socketCount) revert NotParticipant();
        Socket storage s = _sockets[slot];
        if (state == MonthState.Failed) {
            if (s.refunded) return 0;
            s.refunded = true;
            amount = uint256(s.stake) + uint256(s.stake) * ENTRY_FEE_BPS / BPS;
        } else {
            if (doSweep && state == MonthState.Settling) _claimYield();
            amount = Math.mulDiv(s.stake, accShare, ACC_SCALE) - s.claimed;
            // forge-lint: disable-next-line(unsafe-typecast)
            s.claimed += uint128(amount);
        }
        if (amount == 0) return 0;
        liabilities -= amount;
        _pay(s.owner, amount);
        emit Withdrawn(s.owner, amount);
    }

    function _returnPass(uint256 slot) internal returns (bool) {
        if (state != MonthState.Failed && state != MonthState.Settling) revert WrongState();
        if (slot == 0 || slot > socketCount) revert NotParticipant();
        Socket storage s = _sockets[slot];
        if (s.passReturned) return false;
        s.passReturned = true;
        address back = passOwner[slot];
        if (back == address(0)) back = s.owner;
        ICircuits(PASS_CIRCUITS).transferFrom(address(this), back, s.passId);
        emit PassReturned(back, s.passId);
        return true;
    }

    // ============ 升级哨兵 ============

    /// @notice 升级哨兵的冷静期（外部审计 #2）：哨兵已触发，且注册中心的登记（`sentinelSince`）不满
    ///         sentinelResumeDelay（30 天）时为真。冷静期内暂停加入和矿机收购 / 出售，工厂也不开新主板；
    ///         持有人仍可提前结算，开奖照常。没人登记时一直处于冷静期。
    function sentinelPaused() public view returns (bool) {
        if (!sentinelTripped()) return false;
        uint256 since = IBoardHub(HUB).sentinelSince();
        return since == 0 || block.timestamp < since + SENTINEL_RESUME_DELAY;
    }

    function sentinelTripped() public view returns (bool) {
        return _beaconChanged(PASS_BEACON, PASS_IMPL_AT_DEPLOY);
    }

    function _beaconChanged(address beacon, address implAtDeploy) internal view returns (bool) {
        if (beacon == address(0)) return false;
        (bool ok, bytes memory ret) = beacon.staticcall(abi.encodeWithSelector(IBeacon.implementation.selector));
        if (!ok || ret.length < 32) return true;
        return abi.decode(ret, (address)) != implAtDeploy;
    }

    // ============ 只读 ============

    function socket(uint256 slot) external view returns (Socket memory) {
        return _sockets[slot];
    }

    function machine(uint256 index) external view returns (Machine memory) {
        return _machines[index];
    }

    function machineCount() external view returns (uint256) {
        return _machines.length;
    }

    /// @dev 本合约的 BEM 余额（多处使用，收成一个函数节省字节）
    function _bemBalance() internal view returns (uint256) {
        return BEM.balanceOf(address(this));
    }
}
