// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBoardHub} from "../interfaces/IHub.sol";
import {IMachineSource} from "../interfaces/IMachineSource.sol";
import {MonthState, IXMonthFactory} from "../interfaces/IXMonthBoard.sol";
import {IMonthBoardV2} from "../interfaces/IXMonthV2.sol";
import {XMarketPriceFeed} from "../oracle/XMarketPriceFeed.sol";

/// @title XMonthMachineSales（X Layer 月局结算阶段的卖矿定价，所有月局共用一个）
/// @notice 接口、职责和要价规则同 BSC v2 的 MonthMachineSales（2026-10-28 项目方决定：除链上条件不同的部分外和 BSC 对齐）：
///         - 要价：整台 = max(收购时算力 × 卖价公式, 成本价)，卖价公式在 XMarketPriceFeed.sellQuote：
///           max(买一, 卖一 × (99% − 0.5% × 结算开始后整 6 小时数))，买一 / 卖一由运营地址从 BSC 报价合约转报；
///         - 报价无效（过期 / 追价中 / 运营地址为 0）：暂停卖出；停运（从没报过价，或 7 天没有有效报价）：任何人按成本价可买；
///         - 购买：任何人按当前要价付 BEM，主板 releaseMachine 交割（主板再检查一次不低于成本价）；
///         - 交接：运营地址（结算开始 3 天后本局持仓的持有人兜底）让旧月局在新月局的收购拍卖里按不低于成本价卖出；
///         - 清算计划（多数集体清算执行后）：要价 = min(上面的要价, 计划价)，计划价按计划曲线（7 天从起价线性降到底价，之后保持），
///           可以低于成本价，但不低于 BSC 买一 × 收购时算力 × 95%（规则决定 6.33），报价无效时计划价暂停；
///         - 分批推送：运营地址（3 天后持有人兜底）把一段插槽的可领款项推送给持有人并退还通行证。
///         和 BSC 的差别都是链上条件决定的：
///         - 没有寄售（consign）和"保持排序第一"的目标价：X Layer 上没有 RIG 的矿机市场；
///         - 同步时间：RIG 的产出付给 BSC 上**发起收取那一刻**的持有人，主板持有期间累积、还没收取的产出
///           会跟着凭证走。所以购买和交接都要求这台 RIG 在 SALE_SYNC_AGE（1 天）内同步过：任何人都可以先在 BSC 金库上
///           发起收取，之前累积的产出付给主板（按投入比例分给本局持仓），买家只拿到之后的。
///         没有管理员，不可升级，不托管任何人的资金（收到的 BEM 在同一笔交易里交给主板）。
contract XMonthMachineSales is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable BEM;
    IXMonthFactory public immutable FACTORY;
    IBoardHub public immutable HUB;
    address public immutable GOVERNOR;
    uint256 public immutable OPERATOR_GRACE;
    uint256 public immutable PLAN_DECAY; // 清算计划：从起价线性降到底价的时长（7 天）
    uint256 public immutable SALE_SYNC_AGE; // 购买 / 交接时 RIG 最近一次同步不能早于这么久以前（1 天）
    /// @notice BSC 矿机行情的转报（卖价公式、收购价上限、清算计划价下限都用它）
    XMarketPriceFeed public immutable PRICE_FEED;
    uint256 internal constant BPS = 10_000;
    /// @notice 清算计划价不低于 买一 × 算力 × 95%（同 BSC 版）
    uint256 internal constant MIN_BPS = 9_500;

    struct PlanPrice {
        uint128 start;
        uint128 floor;
    }

    /// @notice 清算计划开始的时间（0 = 没有生效的计划）；每次执行新计划时重置
    mapping(address => uint256) public planStart;
    /// @notice 清算计划价格：board → 矿机序号 → 起价 / 底价（整台，BEM 最小单位）
    mapping(address => mapping(uint256 => PlanPrice)) public planPrice;

    event MachineBought(address indexed board, uint256 indexed index, address indexed buyer, uint256 price);
    event MachineRelayed(address indexed board, uint256 indexed index, address indexed newBoard, uint256 price);
    event PlanInstalled(address indexed board, uint256 machines, uint256 start);

    error BadConfig();
    error NotMonthBoard();
    error NotAuthorized();
    error WrongState();
    error PriceAboveMaximum();
    error NotForSale();
    error PaymentMismatch();
    error UpgradeSentinelTripped();
    error SyncTooOld();

    constructor(
        address bem,
        address monthFactory,
        address hub,
        address governor,
        uint256 operatorGrace,
        uint256 planDecay,
        address priceFeed,
        uint256 saleSyncAge
    ) {
        if (
            bem == address(0) || monthFactory == address(0) || hub == address(0) || governor == address(0)
                || priceFeed == address(0)
        ) revert BadConfig();
        if (
            operatorGrace > 3650 days || planDecay == 0 || planDecay > 3650 days || saleSyncAge == 0
                || saleSyncAge > 3650 days
        ) revert BadConfig();
        BEM = IERC20(bem);
        FACTORY = IXMonthFactory(monthFactory);
        HUB = IBoardHub(hub);
        GOVERNOR = governor;
        OPERATOR_GRACE = operatorGrace;
        PLAN_DECAY = planDecay;
        PRICE_FEED = XMarketPriceFeed(priceFeed);
        SALE_SYNC_AGE = saleSyncAge;
    }

    modifier onlyBoard(address board) {
        if (!FACTORY.isBoard(board)) revert NotMonthBoard();
        _;
    }

    // ============ 要价 ============

    /// @notice 当前要价（整台）；0 = 现在不能买（同 BSC MonthMachineSales.askPrice，没有目标价）：
    ///         - 停运（从没报过价，或 7 天没有有效报价）→ 成本价；
    ///         - 报价有效 → max(收购时算力 × 卖价公式, 成本价)；
    ///         - 报价无效（过期 / 追价中 / 运营地址为 0，没停运）→ 0（暂停卖出）。
    ///         多数清算计划生效后，再和计划价比较，取较低的那个（计划价可以低于成本价；正常卖价暂停时按计划价）。计划价不低于
    ///         当时买一 × 收购时算力 × 95%，报价无效时计划价暂停（规则决定 6.33：多数票能止损，不能低于市价甩卖）。
    function askPrice(address board, uint256 index) public view returns (uint256 price) {
        IMonthBoardV2 b = IMonthBoardV2(board);
        if (b.state() != MonthState.Settling) return 0;
        IMonthBoardV2.MachineView memory m = b.machine(index);
        if (m.sold) return 0;
        if (PRICE_FEED.abandoned()) {
            price = m.cost;
        } else {
            uint256 q = PRICE_FEED.sellQuote(b.settleStart());
            if (q > 0) {
                price = q * m.weight;
                if (price < m.cost) price = m.cost;
            }
        }
        uint256 p = planAsk(board, index);
        if (p > 0 && PRICE_FEED.fresh()) {
            uint256 market = PRICE_FEED.bid() * m.weight * MIN_BPS / BPS;
            if (p < market) p = market;
            if (price == 0 || p < price) price = p;
        }
    }

    /// @notice 清算计划价的下限（整台）：BSC 买一 × 算力 × 95%；报价无效时为 0（这时计划价暂停）。
    function planMinPrice(uint256 weight) public view returns (uint256) {
        if (!PRICE_FEED.fresh()) return 0;
        return PRICE_FEED.bid() * weight * MIN_BPS / BPS;
    }

    /// @notice 清算计划价：start − (start − floor) × min(t, PLAN_DECAY) ÷ PLAN_DECAY，到底价后保持；没有计划时为 0。
    function planAsk(address board, uint256 index) public view returns (uint256) {
        uint256 t0 = planStart[board];
        PlanPrice memory p = planPrice[board][index];
        if (t0 == 0 || p.floor == 0) return 0;
        uint256 elapsed = block.timestamp - t0;
        if (elapsed > PLAN_DECAY) elapsed = PLAN_DECAY;
        return uint256(p.start) - (uint256(p.start) - p.floor) * elapsed / PLAN_DECAY;
    }

    /// @notice 写入多数批准的清算计划（只认清算治理合约）：只包含仍未卖出的矿机，降价从现在开始。
    function installPlan(address board, uint256[] calldata indexes, uint128[] calldata start, uint128[] calldata floor)
        external
    {
        if (msg.sender != GOVERNOR) revert NotAuthorized();
        planStart[board] = block.timestamp;
        for (uint256 i = 0; i < indexes.length; i++) {
            planPrice[board][indexes[i]] = PlanPrice(start[i], floor[i]);
        }
        emit PlanInstalled(board, indexes.length, block.timestamp);
    }

    /// @notice 现在买走第 index 台矿机要付的总价（= askPrice；0 = 现在不能买）。
    function quote(address board, uint256 index) external view returns (uint256) {
        return askPrice(board, index);
    }

    /// @notice 任何人按当前要价买走一台矿机（需要事先授权本合约 BEM）。价格超过 maxPrice 时拒绝；
    ///         这台 RIG 要在 SALE_SYNC_AGE 内同步过（syncFresh）。
    function buyMachine(address board, uint256 index, uint256 maxPrice)
        external
        nonReentrant
        onlyBoard(board)
        returns (uint256 price)
    {
        if (IMonthBoardV2(board).sentinelPaused()) revert UpgradeSentinelTripped(); // 主板交割时还会再查
        price = askPrice(board, index);
        if (price == 0) revert NotForSale();
        if (!syncFresh(board, index)) revert SyncTooOld();
        if (price > maxPrice) revert PriceAboveMaximum();
        uint256 before = BEM.balanceOf(address(this));
        BEM.safeTransferFrom(msg.sender, address(this), price);
        if (BEM.balanceOf(address(this)) - before != price) revert PaymentMismatch();
        BEM.forceApprove(board, price);
        IMonthBoardV2(board).releaseMachine(index, msg.sender, price);
        emit MachineBought(board, index, msg.sender, price);
    }

    /// @notice 第 index 台矿机最近一次同步在 SALE_SYNC_AGE 以内（可以购买 / 交接）。为假时先在 BSC 金库上发起一次收取。
    function syncFresh(address board, uint256 index) public view returns (bool) {
        IMonthBoardV2 b = IMonthBoardV2(board);
        uint256 t = IMachineSource(b.MACHINE_SOURCE()).syncedAt(b.machine(index).circuitId);
        return t + SALE_SYNC_AGE >= block.timestamp;
    }

    // ============ 分批推送 ============

    /// @notice 运营地址分批把月局插槽 [fromSlot, fromSlot + count) 的可领款项推送给各自的持有人，并退还通行证。
    ///         结算阶段从结算开始、招募失败从失败时起，运营地址 operatorGrace（3 天）内没执行，本局持有人也可以调用。
    ///         逐个插槽调用主板的 withdraw / returnPass（没有可领款项或通行证已退的跳过），与自领共用记账，不会重复支付。
    function distribute(address board, uint256 fromSlot, uint256 count) external nonReentrant onlyBoard(board) {
        IMonthBoardV2 b = IMonthBoardV2(board);
        MonthState st = b.state();
        uint256 since;
        if (st == MonthState.Settling) since = b.settleStart();
        else if (st == MonthState.Failed) since = b.finishedAt();
        else revert WrongState();
        if (b.claimsClosed()) revert WrongState();
        _auth(b, since);
        uint256 n = b.socketCount();
        if (fromSlot == 0) fromSlot = 1;
        if (fromSlot > n) return;
        uint256 end = count > n ? n + 1 : fromSlot + count; // 不会溢出：fromSlot ≤ n，count ≤ n
        if (end > n + 1) end = n + 1;
        for (uint256 slot = fromSlot; slot < end; slot++) {
            try b.withdraw(slot) {} catch {}
            try b.returnPass(slot) {} catch {}
        }
    }

    /// @dev 运营地址专属；运营地址在 since 之后 operatorGrace 内没执行，本局持仓的持有人可以执行；
    ///      运营地址为 0 时持有人随时可以执行。
    function _auth(IMonthBoardV2 b, uint256 since) internal view {
        address op = HUB.operator();
        if (op != address(0) && msg.sender == op) return;
        if (b.holderCount(msg.sender) == 0) revert NotAuthorized();
        if (op != address(0) && block.timestamp < since + OPERATOR_GRACE) revert NotAuthorized();
    }

    // ============ 交接 ============

    /// @notice 交接：旧月局在新月局（同一个 XMonthFactory、正在准备矿机）的收购拍卖里按新局当前收购价卖出，
    ///         成交额必须不低于成本价，否则整笔回滚；这台 RIG 要在 SALE_SYNC_AGE 内同步过。运营地址专属；结算开始 operatorGrace（3 天）后旧局持仓的持有人也可以；
    ///         运营地址为 0 时持有人随时可以。
    function relay(address oldBoard, uint256 index, address newBoard)
        external
        nonReentrant
        onlyBoard(oldBoard)
        returns (uint256 paid)
    {
        _auth(IMonthBoardV2(oldBoard), IMonthBoardV2(oldBoard).settleStart());
        if (!syncFresh(oldBoard, index)) revert SyncTooOld();
        paid = IMonthBoardV2(oldBoard).relayOut(index, newBoard);
        emit MachineRelayed(oldBoard, index, newBoard, paid);
    }
}
