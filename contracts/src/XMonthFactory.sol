// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBoardHub} from "./interfaces/IHub.sol";
import {IXMonthFactory, MonthState} from "./interfaces/IXMonthBoard.sol";
import {XHub} from "./XHub.sol";
import {XMonthBoard} from "./XMonthBoard.sol";
import {IMonthSalesFeed} from "./interfaces/IXMonthV2.sol";

/// @title MonthFactory（月局工厂）
/// @notice 不可升级，没有管理员（运营地址存在 XHub）。和 XHub 分开部署（月局实现合约放不进 XHub 的初始化代码上限）：
///         - 部署前先预测本合约地址，作为 XHub 的构造参数；本合约构造时校验 hub.monthFactory() == 本合约；
///         - 构造时部署 XMonthBoard 实现合约（创世电路合约、分账合约地址从 XHub 读取）；
///         - XHub.startGenesis 调用 openFirst 开出第 1 块月局（100 BEM，3 天招募）；
///         - 同一时间只有一块月局在招募；上一块开局时开出下一块；招募失败时重开同一编号；
///         - 金额按招募速度自动调整：1 天内招满 × 1.25；1–3 天内不变；到期 ≥ 60% 按实际开局 × 0.75；
///           到期 < 60% 退款重开 × 0.5；范围 100–1,000 BEM，向下取整到 1 BEM；投入范围 = 目标 × 0.2%–4%；
///         - 月局开局时向 XHub 登记开局顺序（两种局合计，用于首批回馈）；
///         - 局终收回的回馈资本转到本合约，下一块月局开局时全部转给它，作为它的回馈资本；
///         - 开局时算出这块月局的收购价上限快照（roundCap）：实测单位日产出 × buyCapDays，不超过部署上限；
///           直接捐赠无法和跨链产出区分，为防止样本被抬高，相对上一块开局的月局最多上调
///           max(25%, 部署上限 × 5%)，下调不限。准备期内实际的收购价上限还要和 BSC 卖一取较小值、报价无效时暂停收购
///           （XMonthBoard.buyPrice → XMarketPriceFeed.buyQuote，同 BSC）。
contract XMonthFactory is IXMonthFactory {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    /// @notice 每块月局的收购价上限相对上一块开局的月局最多上调 25%
    uint256 public constant CAP_RISE_BPS = 2_500;
    /// @notice 上调幅度至少可以是部署上限的 5%（上一局上限很低或为 0 时也能逐局恢复）
    uint256 public constant CAP_MIN_RISE_BPS = 500;

    struct TargetRules {
        uint256 initialTarget;
        uint256 minTarget;
        uint256 maxTarget;
        uint256 rounding;
        uint256 minStakeBps;
        uint256 maxStakeBps;
        uint256 fastFillWindow;
        uint256 growBps;
        uint256 partialBps;
        uint256 failBps;
    }

    struct Params {
        XMonthBoard.Config board; // passCircuits / splitter 由本合约从 XHub 读取
        TargetRules targets;
    }

    address public immutable hub;
    IERC20 public immutable bem;
    address public immutable boardImplementation;
    uint256 public immutable initialTarget;
    uint256 public immutable minTarget;
    uint256 public immutable maxTarget;
    uint256 public immutable targetRounding;
    uint256 public immutable minStakeBps;
    uint256 public immutable maxStakeBps;
    uint256 public immutable fastFillWindow;
    uint256 public immutable growBps;
    uint256 public immutable partialBps;
    uint256 public immutable failBps;

    XMonthBoard.Config internal _boardConfig;

    uint256 public nextTarget;
    uint256 public currentNumber;
    address public recruitingBoard;
    mapping(uint256 => address) public boardByNumber;
    mapping(address => uint256) public numberOf;
    mapping(uint256 => uint256) public attemptsOf;
    address[] public allBoards;
    uint256 public totalRolloverPaid;

    uint256 public unitYieldPerDay;
    bool public hasYieldReport;
    mapping(address => bool) public yieldReported;
    /// @notice 各局最近报告时的累计实收收益，用于拒绝没有新增收益的重复报告。
    mapping(address => uint256) public reportedYieldReceived;
    /// @notice 最新首次有效报告的月局；旧局的迟到更新不抢占它的报价。
    address public lastYieldBoard;
    /// @notice 最近一块开局的月局的收购价上限快照（hasRoundCap 为假时还没有月局开局）
    uint256 public lastRoundCap;
    bool public hasRoundCap;

    event YieldReported(address indexed board, uint256 perDay);
    event YieldSampleUpdated(address indexed board, uint256 perDay, uint256 received, bool applied);

    event BoardOpened(
        uint256 indexed number,
        address indexed board,
        uint256 attempt,
        uint256 target,
        uint256 minStake,
        uint256 maxStake
    );
    event TargetAdjusted(uint256 oldTarget, uint256 newTarget);
    event RolloverPaid(address indexed board, uint256 amount);

    error NothingToReopen();
    error SentinelPaused();
    error BadParams();
    error BadHub();
    error OnlyHub();
    error AlreadyOpened();
    error OnlyRecruitingBoard();
    error InvalidYieldReport();

    constructor(address hub_, Params memory p) {
        if (hub_ == address(0) || IBoardHub(hub_).monthFactory() != address(this)) revert BadHub();
        TargetRules memory t = p.targets;
        if (
            t.rounding == 0 || t.minTarget == 0 || t.minTarget > t.initialTarget || t.initialTarget > t.maxTarget
                || t.minStakeBps == 0 || t.maxStakeBps < t.minStakeBps || t.maxStakeBps * 2 > p.board.minStartBps
                || t.minTarget * t.minStakeBps < BPS
        ) revert BadParams();
        if (p.board.feeRecipient != XHub(hub_).feeRecipient() || p.board.bem != address(XHub(hub_).splitter().bem())) {
            revert BadParams();
        }
        hub = hub_;
        bem = IERC20(p.board.bem);
        initialTarget = t.initialTarget;
        minTarget = t.minTarget;
        maxTarget = t.maxTarget;
        targetRounding = t.rounding;
        minStakeBps = t.minStakeBps;
        maxStakeBps = t.maxStakeBps;
        fastFillWindow = t.fastFillWindow;
        growBps = t.growBps;
        partialBps = t.partialBps;
        failBps = t.failBps;
        nextTarget = t.initialTarget;

        XMonthBoard.Config memory c = p.board;
        c.passCircuits = IBoardHub(hub_).passCircuits();
        c.splitter = IBoardHub(hub_).splitter();
        c.hub = hub_;
        boardImplementation = address(new XMonthBoard(c));
        _boardConfig = c;
    }

    /// @notice 由 XHub.startGenesis 调用：开出第 1 块月局。
    function openFirst() external returns (address board) {
        if (msg.sender != hub) revert OnlyHub();
        if (currentNumber != 0) revert AlreadyOpened();
        board = _open(1);
    }

    /// @notice 由招募中的月局在开局时调用：登记开局顺序、调整金额、开出下一块，并把滚存的回馈资金转给它。
    function onBoardStarted(bool full, uint256 elapsed) external returns (uint256 rollover, uint256 cap) {
        address board = msg.sender;
        if (board != recruitingBoard) revert OnlyRecruitingBoard();
        cap = roundCap();
        lastRoundCap = cap;
        hasRoundCap = true;
        IBoardHub(hub).registerStart(board);
        if (!full) _adjust(partialBps);
        else if (elapsed < fastFillWindow) _adjust(growBps);
        _open(currentNumber + 1);
        rollover = bem.balanceOf(address(this));
        if (rollover > 0) {
            totalRolloverPaid += rollover;
            bem.safeTransfer(board, rollover);
            emit RolloverPaid(board, rollover);
        }
    }

    /// @notice 由招募中的月局在招募失败时调用：金额 × failBps，重开同一编号（升级哨兵冷静期内不重开，见 reopen）。
    function onBoardFailed() external {
        if (msg.sender != recruitingBoard) revert OnlyRecruitingBoard();
        recruitingBoard = address(0);
        _adjust(failBps);
        if (!XMonthBoard(boardImplementation).sentinelPaused()) _open(currentNumber);
    }

    /// @notice 冷静期内招募失败、没有重开的月局，在冷静期结束（登记满 30 天或信标恢复）后由任何人调用重开。
    function reopen() external returns (address board) {
        if (currentNumber == 0 || recruitingBoard != address(0)) revert NothingToReopen();
        if (XMonthBoard(boardImplementation).sentinelPaused()) revert SentinelPaused();
        board = _open(currentNumber);
    }

    /// @notice 已结算的官方月局首次报告或在新收益到账后更新。零收益也是有效初始样本。
    ///         首次有效报告顺序决定样本优先级；旧局更新不覆盖较新样本，不影响旧局参与者收款。
    function reportYield(uint256 perDay) external {
        XMonthBoard board = XMonthBoard(msg.sender);
        if (
            numberOf[msg.sender] == 0 || board.state() != MonthState.Settling || board.claimsClosed()
                || board.weightSeconds() == 0 || perDay != board.unitYieldPerDay()
        ) revert InvalidYieldReport();
        uint256 received = board.yieldReceived();
        if (!yieldReported[msg.sender]) {
            yieldReported[msg.sender] = true;
            hasYieldReport = true;
            lastYieldBoard = msg.sender;
        } else if (received <= reportedYieldReceived[msg.sender]) {
            revert InvalidYieldReport();
        }
        reportedYieldReceived[msg.sender] = received;
        bool applied = lastYieldBoard == msg.sender;
        if (applied) {
            unitYieldPerDay = perDay;
            emit YieldReported(msg.sender, perDay);
        }
        emit YieldSampleUpdated(msg.sender, perDay, received, applied);
    }

    /// @notice 现在开局的月局会得到的收购价上限快照（每单位算力）：没有样本时用部署上限；有样本时
    ///         min(实测单位日产出 × buyCapDays, 部署上限)，零收益样本得到 0；再限制相对上一块开局的月局
    ///         最多上调 max(上一局 × 25%, 部署上限 × 5%)。
    function roundCap() public view returns (uint256 cap) {
        uint256 maxPrice = _boardConfig.buyMaxPrice;
        cap = maxPrice;
        if (hasYieldReport) {
            uint256 perDay = unitYieldPerDay;
            uint256 capDays = _boardConfig.buyCapDays;
            // 先比较再乘，历史数据再大也不会溢出
            if (perDay <= maxPrice / capDays) cap = perDay * capDays;
        }
        if (hasRoundCap) {
            uint256 last = lastRoundCap;
            uint256 rise = last * CAP_RISE_BPS / BPS;
            uint256 minRise = maxPrice * CAP_MIN_RISE_BPS / BPS;
            if (rise < minRise) rise = minRise;
            if (cap > last + rise) cap = last + rise;
        }
    }

    /// @notice 月局共用的 BSC 行情转报（XMarketPriceFeed），从卖矿单例读
    function priceFeed() external view returns (address) {
        return IMonthSalesFeed(_boardConfig.sales).PRICE_FEED();
    }

    function isBoard(address account) external view returns (bool) {
        return numberOf[account] != 0;
    }

    function boardCount() external view returns (uint256) {
        return allBoards.length;
    }

    /// @notice 所有月局共用的参数。
    function boardConfig() external view returns (XMonthBoard.Config memory) {
        return _boardConfig;
    }

    function stakeRange(uint256 target) public view returns (uint256 minStake, uint256 maxStake) {
        minStake = target * minStakeBps / BPS;
        maxStake = target * maxStakeBps / BPS;
    }

    function _adjust(uint256 factorBps) internal {
        uint256 old = nextTarget;
        uint256 t = old * factorBps / BPS;
        t -= t % targetRounding;
        if (t < minTarget) t = minTarget;
        if (t > maxTarget) t = maxTarget;
        nextTarget = t;
        if (t != old) emit TargetAdjusted(old, t);
    }

    function _open(uint256 number) internal returns (address board) {
        uint256 target = nextTarget;
        (uint256 minStake, uint256 maxStake) = stakeRange(target);
        board = Clones.clone(boardImplementation);
        numberOf[board] = number;
        boardByNumber[number] = board;
        currentNumber = number;
        recruitingBoard = board;
        allBoards.push(board);
        uint256 attempt = ++attemptsOf[number];
        XMonthBoard(board).initialize(number, target, minStake, maxStake);
        emit BoardOpened(number, board, attempt, target, minStake, maxStake);
    }
}
