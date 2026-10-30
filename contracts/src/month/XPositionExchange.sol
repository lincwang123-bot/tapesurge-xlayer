// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MonthState, IXMonthFactory} from "../interfaces/IXMonthBoard.sol";
import {IMonthBoardV2, IMonthPositions} from "../interfaces/IXMonthV2.sol";

/// @title XPositionExchange（X Layer 月局持仓挂单簿，单例；从 BSC v2.0-audit.6 PositionExchange 移植，去掉标准局分支）
/// @notice 整份持仓的公开盘口，用 BEM 计价，市场费为 0（规则决定第 6.2 / 6.5 节）。
///         - 报价单位：每 1e8 本金单位（1 BEM 原始本金）对应的 BEM 数量 unitPrice；成交总价 = ⌈stake × unitPrice ÷ 1e8⌉。
///         - 卖单：非托管，挂在链上。持有人授权本合约后 listAsk；每份持仓同时只有一张卖单，重挂即改价。
///           卖单记下挂单时的持有人、持仓版本号和局交易版本号，任何一项变化后自动失效。买家 buyAsk 吃单。
///           buyBest 一笔按单价从低到高吃多张卖单。
///         - 买单：本局通用，全额托管预算（≥ 1 BEM）。本局任何一份大小在 [minStake, maxStake] 内的持仓都可以卖给它
///           （sellToBid），可以连续成交多份；剩余预算不够最小一份时自动关闭并退款。撤单或过期后退还剩余预算。
///           每个地址每局最多 20 张未关闭买单。买单和卖单一样记下挂单时的局交易版本号，版本号变化（矿机卖出 / 交接、
///           清算投票锁定 / 解锁、开始清算）后失效，买家撤单或任何人 refundBid 退款。
///         - 不做自动撮合，只有吃单成交。成交款和退款直接转给收款人，不经过领取。
///         - 盘口：每局维护有卖单记录的插槽集合和未关闭买单集合，dApp / 机器人用 book / asksOf / bidsOf / recentTrades
///           几次 view 调用读出完整盘口，不需要扫描事件。
///         成交时持仓经 MonthPositions.transferFrom 转移，主板在钩子里检查转让锁、把卖方已累计的款项结转给卖方、
///         退还通行证并更新版本号。本合约只托管买单预算，和主板的资金完全分开。没有管理员，不可升级。
contract XPositionExchange is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice 订单最长有效期（规则决定 6.5：B1）
    uint256 public constant MAX_VALIDITY = 30 days;
    /// @notice 每张买单至少托管 1 BEM（规则决定 6.5：A1）
    uint256 public constant MIN_BID_BUDGET = 1e8;
    /// @notice 每个地址在每块月局最多 20 张未关闭买单（规则决定 6.5：A1）
    uint256 public constant MAX_OPEN_BIDS = 20;
    /// @notice 每块月局保存最近 20 笔成交（规则决定 6.5：C2）
    uint256 public constant TRADE_HISTORY = 20;
    /// @notice 报价单位：1 BEM 原始本金 = 1e8 本金单位
    uint256 public constant STAKE_UNIT = 1e8;

    struct AskOrder {
        address maker; // 挂单时的持有人；0 = 没有卖单
        uint96 unitPrice;
        uint32 positionVersion; // 挂单时的持仓版本号
        uint64 tradeEpoch; // 挂单时的局交易版本号
        uint64 deadline;
    }

    struct BidOrder {
        address bidder; // 0 = 已关闭
        uint96 unitPrice;
        address board;
        uint64 deadline;
        uint96 remaining; // 剩余托管预算
        uint96 minStake;
        uint96 maxStake;
    }

    struct AskView {
        uint256 slot;
        address maker;
        uint256 unitPrice;
        uint256 stake;
        uint256 cost; // ⌈stake × unitPrice ÷ 1e8⌉
        uint64 deadline;
        bool valid;
    }

    struct BidView {
        uint256 bidId;
        address bidder;
        uint256 unitPrice;
        uint256 remaining;
        uint256 minStake;
        uint256 maxStake;
        uint64 deadline;
        bool valid;
    }

    /// @dev 一个存储槽：12 + 12 + 5 + 3 字节
    struct Trade {
        uint96 unitPrice;
        uint96 stake;
        uint40 time;
        uint24 slot;
    }

    IERC20 public immutable BEM;
    IERC721 public immutable POSITIONS;
    IXMonthFactory public immutable FACTORY;

    mapping(address => mapping(uint256 => AskOrder)) internal _asks;
    mapping(address => uint256[]) internal _askSlots; // 有卖单记录的插槽（含已失效、未清理的）
    mapping(address => mapping(uint256 => uint256)) internal _askPos; // 插槽在 _askSlots 里的位置 + 1

    mapping(uint256 => BidOrder) internal _bids;
    mapping(address => uint256[]) internal _bidIds; // 未关闭的买单
    mapping(uint256 => uint256) internal _bidPos; // 买单在 _bidIds 里的位置 + 1
    mapping(address => mapping(address => uint256)) public openBidsOf; // 月局 → 买家 → 未关闭买单数
    uint256 public lastBidId;
    uint256 public totalEscrow; // Σ 未关闭买单的 remaining；不变量：BEM.balanceOf(this) == totalEscrow
    /// @notice 买单挂单时的局交易版本号；之后版本号变化，买单失效
    mapping(uint256 => uint64) public bidEpoch;

    mapping(address => Trade[20]) internal _trades;
    mapping(address => uint256) public tradeCount; // 每局累计成交笔数

    event AskListed(address indexed board, uint256 indexed slot, address indexed maker, uint256 unitPrice, uint64 deadline);
    event AskCancelled(address indexed board, uint256 indexed slot, address indexed by);
    event BidPlaced(
        uint256 indexed bidId,
        address indexed board,
        address indexed bidder,
        uint256 unitPrice,
        uint256 budget,
        uint256 minStake,
        uint256 maxStake,
        uint64 deadline
    );
    /// @param reason 1 买家撤单 2 过期、局交易版本号变化或领取期限关闭后退款 3 剩余预算不够最小一份，自动关闭
    event BidClosed(uint256 indexed bidId, address indexed board, uint256 refund, uint8 reason);
    /// @param bidId 0 = 买家吃卖单；非 0 = 持有人卖给这张买单
    event PositionTraded(
        address indexed board,
        uint256 indexed slot,
        address indexed seller,
        address buyer,
        uint256 unitPrice,
        uint256 stake,
        uint256 cost,
        uint256 bidId
    );

    error BadConfig();
    error NotMonthBoard();
    error NotListable();
    error BadDeadline();
    error ZeroPrice();
    error NotOwner();
    error NotApproved();
    error NoAsk();
    error AskNotValid();
    error PriceAbove();
    error SelfTrade();
    error NotTransferable();
    error PaymentMismatch();
    error NothingFilled();
    error PriceBelow();
    error BudgetTooSmall();
    error BadStakeRange();
    error TooManyBids();
    error BidClosedAlready();
    error BidExpired();
    error NotBidder();
    error BidStillValid();
    error StakeOutOfRange();
    error BudgetExceeded();
    error BidStale();

    constructor(address bem, address positions, address monthFactory) {
        if (bem == address(0) || positions == address(0) || monthFactory == address(0)) revert BadConfig();
        BEM = IERC20(bem);
        POSITIONS = IERC721(positions);
        FACTORY = IXMonthFactory(monthFactory);
    }

    // ============ 卖单 ============

    /// @notice 挂卖单或改价：调用者必须是当前持有人，且已授权本合约转移这份持仓。只能在结算阶段、领取期限关闭前挂单
    ///         （治理锁期间可以挂，但不能成交）。有效期 0 < deadline − now ≤ 30 天。
    function listAsk(address board, uint256 slot, uint256 unitPrice, uint64 deadline) external {
        _checkListable(board);
        _checkDeadline(deadline);
        if (unitPrice == 0) revert ZeroPrice();
        (address owner, uint256 stake, uint32 version) = _pos(board, slot);
        if (owner != msg.sender || stake == 0) revert NotOwner();
        if (!_approved(msg.sender, board, slot)) revert NotApproved();
        _asks[board][slot] = AskOrder({
            maker: msg.sender,
            unitPrice: SafeCast.toUint96(unitPrice),
            positionVersion: version,
            tradeEpoch: IMonthBoardV2(board).tradeEpoch(),
            deadline: deadline
        });
        if (_askPos[board][slot] == 0) {
            _askSlots[board].push(slot);
            _askPos[board][slot] = _askSlots[board].length;
        }
        emit AskListed(board, slot, msg.sender, unitPrice, deadline);
    }

    /// @notice 撤卖单：挂单人或这份持仓的当前持有人可以撤。
    function cancelAsk(address board, uint256 slot) external {
        AskOrder storage a = _asks[board][slot];
        if (a.maker == address(0)) revert NoAsk();
        (address owner,,) = _pos(board, slot);
        if (msg.sender != a.maker && msg.sender != owner) revert NotOwner();
        _removeAsk(board, slot, msg.sender);
    }

    /// @notice 任何人：删掉已失效的卖单（只影响存储和读取成本，不涉及资金）。仍然有效的跳过。
    function pruneAsks(address board, uint256[] calldata slots) external {
        for (uint256 i = 0; i < slots.length; i++) {
            AskOrder memory a = _asks[board][slots[i]];
            if (a.maker != address(0) && !_askValid(board, slots[i], a)) _removeAsk(board, slots[i], msg.sender);
        }
    }

    /// @notice 吃一张卖单：调用者按卖单价付款并收到持仓；卖单价高于 maxUnitPrice 时回滚（防止被抢先改价）。
    ///         需要事先授权本合约 BEM。成交款直接转给卖方。
    function buyAsk(address board, uint256 slot, uint256 maxUnitPrice) external nonReentrant returns (uint256 cost) {
        AskOrder memory a = _asks[board][slot];
        if (a.maker == address(0)) revert NoAsk();
        if (!_askValid(board, slot, a)) revert AskNotValid();
        if (a.unitPrice > maxUnitPrice) revert PriceAbove();
        if (msg.sender == a.maker) revert SelfTrade();
        _checkTradable(board);
        (, uint256 stake,) = _pos(board, slot);
        cost = _fill(board, slot, a, stake);
    }

    /// @notice 按最优价批量吃单：把 slots 里的卖单按单价从低到高（同价按插槽）依次成交，每笔单价 ≤ maxUnitPrice，
    ///         总花费 ≤ maxTotalCost。**失效的卖单跳过、不回滚**：没有卖单、已失效（被别人先买走、改了价、持仓有变化、
    ///         过期、撤销授权）、单价高于 maxUnitPrice、是调用者自己的、或加上它会超过 maxTotalCost 的都跳过，
    ///         其余照常成交；一张都没成交时回滚（NothingFilled）。保护靠 maxUnitPrice 和 maxTotalCost 两个上限：
    ///         同一区块里别人先吃掉卖一，本笔仍能按次优价成交，但不会超出这两个上限。现在不能交易（非结算阶段、治理锁、
    ///         领取期限关闭）时整笔回滚。slots 通常直接取 book(board, n) 的前 n 档。
    function buyBest(address board, uint256[] calldata slots, uint256 maxUnitPrice, uint256 maxTotalCost)
        external
        nonReentrant
        returns (uint256 filled, uint256 spent)
    {
        _checkTradable(board);
        uint256 n = slots.length;
        uint256[] memory order = new uint256[](n);
        uint256[] memory price = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 p = _asks[board][slots[i]].unitPrice;
            uint256 j = i;
            while (j > 0 && (price[j - 1] > p || (price[j - 1] == p && order[j - 1] > slots[i]))) {
                order[j] = order[j - 1];
                price[j] = price[j - 1];
                j--;
            }
            order[j] = slots[i];
            price[j] = p;
        }
        for (uint256 i = 0; i < n; i++) {
            uint256 slot = order[i];
            AskOrder memory a = _asks[board][slot];
            if (a.maker == address(0) || a.maker == msg.sender || a.unitPrice > maxUnitPrice) continue;
            if (!_askValid(board, slot, a)) continue;
            (, uint256 stake,) = _pos(board, slot);
            uint256 cost = quote(stake, a.unitPrice);
            if (spent + cost > maxTotalCost) continue;
            spent += _fill(board, slot, a, stake);
            filled++;
        }
        if (filled == 0) revert NothingFilled();
    }

    // ============ 买单 ============

    /// @notice 挂本局通用买单，托管 budget 个 BEM（≥ 1 BEM，且至少够买一份 minStake 大小的持仓）。
    ///         只能在结算阶段、领取期限关闭前挂单；每个地址每局最多 20 张未关闭买单。
    ///         局交易版本号变化（矿机卖出 / 交接、清算投票锁定 / 解锁、开始清算）后买单失效，需要撤单重挂。
    function placeBid(
        address board,
        uint256 unitPrice,
        uint256 budget,
        uint256 minStake,
        uint256 maxStake,
        uint64 deadline
    ) external nonReentrant returns (uint256 bidId) {
        _checkListable(board);
        _checkDeadline(deadline);
        if (unitPrice == 0) revert ZeroPrice();
        if (minStake == 0) minStake = 1;
        if (maxStake < minStake) revert BadStakeRange();
        if (budget < MIN_BID_BUDGET || budget < quote(minStake, unitPrice)) revert BudgetTooSmall();
        if (openBidsOf[board][msg.sender] >= MAX_OPEN_BIDS) revert TooManyBids();
        uint256 before = BEM.balanceOf(address(this));
        BEM.safeTransferFrom(msg.sender, address(this), budget);
        if (BEM.balanceOf(address(this)) - before != budget) revert PaymentMismatch();
        bidId = ++lastBidId;
        bidEpoch[bidId] = IMonthBoardV2(board).tradeEpoch();
        _bids[bidId] = BidOrder({
            bidder: msg.sender,
            unitPrice: SafeCast.toUint96(unitPrice),
            board: board,
            deadline: deadline,
            remaining: SafeCast.toUint96(budget),
            minStake: SafeCast.toUint96(minStake),
            maxStake: SafeCast.toUint96(maxStake > type(uint96).max ? type(uint96).max : maxStake)
        });
        _bidIds[board].push(bidId);
        _bidPos[bidId] = _bidIds[board].length;
        openBidsOf[board][msg.sender] += 1;
        totalEscrow += budget;
        emit BidPlaced(bidId, board, msg.sender, unitPrice, budget, minStake, maxStake, deadline);
    }

    /// @notice 持有人把一份持仓卖给买单；买单价低于 minUnitPrice 时回滚（防止被抢先撤单重挂）。
    ///         持有人要事先授权本合约转移持仓。成交款从托管预算直接转给持有人；剩余预算不够最小一份时买单自动关闭并退款。
    function sellToBid(uint256 bidId, uint256 slot, uint256 minUnitPrice) external nonReentrant returns (uint256 cost) {
        BidOrder storage b = _bids[bidId];
        if (b.bidder == address(0)) revert BidClosedAlready();
        if (block.timestamp >= b.deadline) revert BidExpired();
        if (b.unitPrice < minUnitPrice) revert PriceBelow();
        if (msg.sender == b.bidder) revert SelfTrade();
        _checkTradable(b.board);
        if (_bidStale(bidId, b.board)) revert BidStale();
        (address owner, uint256 stake,) = _pos(b.board, slot);
        if (owner != msg.sender) revert NotOwner();
        if (stake < b.minStake || stake > b.maxStake) revert StakeOutOfRange();
        cost = quote(stake, b.unitPrice);
        if (cost > b.remaining) revert BudgetExceeded();
        b.remaining -= uint96(cost);
        totalEscrow -= cost;
        _settleBid(bidId, b.board, slot, stake, cost);
        if (b.remaining < quote(b.minStake, b.unitPrice)) _closeBid(bidId, 3);
    }

    /// @notice 买家撤单，剩余预算直接退回买家。
    function cancelBid(uint256 bidId) external nonReentrant {
        BidOrder storage b = _bids[bidId];
        if (b.bidder == address(0)) revert BidClosedAlready();
        if (msg.sender != b.bidder) revert NotBidder();
        _closeBid(bidId, 1);
    }

    /// @notice 过期、局交易版本号变化或领取期限关闭后，任何人都可以帮买家退款（钱只退给买家）。
    function refundBid(uint256 bidId) external nonReentrant {
        BidOrder storage b = _bids[bidId];
        if (b.bidder == address(0)) revert BidClosedAlready();
        if (block.timestamp < b.deadline && !IMonthBoardV2(b.board).claimsClosed() && !_bidStale(bidId, b.board)) {
            revert BidStillValid();
        }
        _closeBid(bidId, 2);
    }

    // ============ 读取 ============

    /// @notice 成交总价 = ⌈stake × unitPrice ÷ 1e8⌉（向上取整，stake 和 unitPrice 都 > 0 时至少为 1）
    function quote(uint256 stake, uint256 unitPrice) public pure returns (uint256) {
        return (stake * unitPrice + STAKE_UNIT - 1) / STAKE_UNIT;
    }

    /// @notice 现在能否成交：结算阶段、没有治理锁、领取期限没关闭
    function tradable(address board) public view returns (bool) {
        if (!FACTORY.isBoard(board)) return false;
        IMonthBoardV2 b = IMonthBoardV2(board);
        return b.state() == MonthState.Settling && !b.governanceLocked() && !b.claimsClosed();
    }

    function ask(address board, uint256 slot) external view returns (AskOrder memory) {
        return _asks[board][slot];
    }

    /// @notice 卖单是否仍然有效（未过期；持有人、持仓版本号、局交易版本号没变；仍授权本合约；领取期限没关闭）。
    ///         治理锁期间的局交易版本号会变，所以锁定时所有卖单都失效，解锁后需要重挂。
    function askValid(address board, uint256 slot) public view returns (bool) {
        AskOrder memory a = _asks[board][slot];
        return a.maker != address(0) && _askValid(board, slot, a);
    }

    function bid(uint256 bidId) external view returns (BidOrder memory) {
        return _bids[bidId];
    }

    /// @notice 买单是否还能成交（未关闭、未过期、局交易版本号没变、领取期限没关闭、剩余预算够最小一份）
    function bidValid(uint256 bidId) public view returns (bool) {
        BidOrder storage b = _bids[bidId];
        return b.bidder != address(0) && block.timestamp < b.deadline && !IMonthBoardV2(b.board).claimsClosed()
            && !_bidStale(bidId, b.board) && b.remaining >= quote(b.minStake, b.unitPrice);
    }

    function askCount(address board) external view returns (uint256) {
        return _askSlots[board].length;
    }

    function bidCount(address board) external view returns (uint256) {
        return _bidIds[board].length;
    }

    /// @notice 分页读取有卖单记录的插槽（含已失效的，valid 字段标明）。顺序不固定。
    function asksOf(address board, uint256 offset, uint256 limit) external view returns (AskView[] memory out) {
        uint256[] storage all = _askSlots[board];
        uint256 n = _pageSize(all.length, offset, limit);
        out = new AskView[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _askView(board, all[offset + i]);
        }
    }

    /// @notice 分页读取未关闭的买单（valid 字段标明现在能否成交）。顺序不固定。
    function bidsOf(address board, uint256 offset, uint256 limit) external view returns (BidView[] memory out) {
        uint256[] storage all = _bidIds[board];
        uint256 n = _pageSize(all.length, offset, limit);
        out = new BidView[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _bidView(all[offset + i]);
        }
    }

    /// @notice 盘口：只含有效订单；卖单按单价从低到高（同价按插槽），买单按单价从高到低（同价先挂的在前），各取前 depth 档
    ///         （depth = 0 表示全部）。一次 eth_call 读完；订单很多时改用 asksOf / bidsOf 分页。
    function book(address board, uint256 depth) external view returns (AskView[] memory asks, BidView[] memory bids) {
        asks = _sortedAsks(board, depth);
        bids = _sortedBids(board, depth);
    }

    /// @notice 最近 20 笔成交，从新到旧
    function recentTrades(address board) external view returns (Trade[] memory out) {
        uint256 total = tradeCount[board];
        uint256 n = total < TRADE_HISTORY ? total : TRADE_HISTORY;
        out = new Trade[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _trades[board][(total - 1 - i) % TRADE_HISTORY];
        }
    }

    // ============ 内部 ============

    /// @dev 能否挂单：结算阶段（治理锁期间也能挂，但不能成交）、领取期限没关闭
    function _checkListable(address board) internal view {
        if (!FACTORY.isBoard(board)) revert NotMonthBoard();
        IMonthBoardV2 b = IMonthBoardV2(board);
        if (b.state() != MonthState.Settling || b.claimsClosed()) revert NotListable();
    }

    /// @dev 一份持仓的（持有人、投入、版本号）
    function _pos(address board, uint256 slot) internal view returns (address owner, uint256 stake, uint32 version) {
        if (!FACTORY.isBoard(board)) revert NotMonthBoard();
        IMonthBoardV2.Position memory p = IMonthBoardV2(board).socket(slot);
        return (p.owner, p.stake, p.version);
    }

    function _checkTradable(address board) internal view {
        if (!tradable(board)) revert NotTransferable();
    }

    function _checkDeadline(uint64 deadline) internal view {
        if (deadline <= block.timestamp || deadline - block.timestamp > MAX_VALIDITY) revert BadDeadline();
    }

    function _approved(address owner, address board, uint256 slot) internal view returns (bool) {
        return POSITIONS.isApprovedForAll(owner, address(this))
            || POSITIONS.getApproved(IMonthPositions(address(POSITIONS)).idOf(board, slot)) == address(this);
    }

    function _askValid(address board, uint256 slot, AskOrder memory a) internal view returns (bool) {
        if (block.timestamp >= a.deadline) return false;
        IMonthBoardV2 b = IMonthBoardV2(board); // claimsClosed / tradeEpoch 两种主板同名同签名
        if (b.claimsClosed() || b.tradeEpoch() != a.tradeEpoch) return false;
        (address owner,, uint32 version) = _pos(board, slot);
        return owner == a.maker && version == a.positionVersion && _approved(a.maker, board, slot);
    }

    function _removeAsk(address board, uint256 slot, address by) internal {
        delete _asks[board][slot];
        uint256 pos = _askPos[board][slot];
        uint256[] storage all = _askSlots[board];
        uint256 last = all[all.length - 1];
        all[pos - 1] = last;
        _askPos[board][last] = pos;
        all.pop();
        delete _askPos[board][slot];
        if (by != address(0)) emit AskCancelled(board, slot, by);
    }

    /// @dev 成交一张卖单：先删卖单、记成交，再把 BEM 从买家直接转给卖方（按卖方余额差核对）、转移持仓
    function _fill(address board, uint256 slot, AskOrder memory a, uint256 stake) internal returns (uint256 cost) {
        cost = quote(stake, a.unitPrice);
        _removeAsk(board, slot, address(0));
        _record(board, slot, a.unitPrice, stake);
        uint256 before = BEM.balanceOf(a.maker);
        BEM.safeTransferFrom(msg.sender, a.maker, cost);
        if (BEM.balanceOf(a.maker) - before != cost) revert PaymentMismatch();
        POSITIONS.transferFrom(a.maker, msg.sender, IMonthPositions(address(POSITIONS)).idOf(board, slot));
        emit PositionTraded(board, slot, a.maker, msg.sender, a.unitPrice, stake, cost, 0);
    }

    /// @dev 买单挂出后局交易版本号变了
    function _bidStale(uint256 bidId, address board) internal view returns (bool) {
        return IMonthBoardV2(board).tradeEpoch() != bidEpoch[bidId];
    }

    function _closeBid(uint256 bidId, uint8 reason) internal {
        BidOrder memory b = _bids[bidId];
        delete _bids[bidId];
        delete bidEpoch[bidId];
        uint256 pos = _bidPos[bidId];
        uint256[] storage all = _bidIds[b.board];
        uint256 last = all[all.length - 1];
        all[pos - 1] = last;
        _bidPos[last] = pos;
        all.pop();
        delete _bidPos[bidId];
        openBidsOf[b.board][b.bidder] -= 1;
        totalEscrow -= b.remaining;
        if (b.remaining > 0) BEM.safeTransfer(b.bidder, b.remaining);
        emit BidClosed(bidId, b.board, b.remaining, reason);
    }

    /// @dev 卖给买单的交割：删掉这份持仓的旧卖单、记成交、托管款直接付给持有人、持仓转给买家
    function _settleBid(uint256 bidId, address board, uint256 slot, uint256 stake, uint256 cost) internal {
        address bidder = _bids[bidId].bidder;
        uint256 unitPrice = _bids[bidId].unitPrice;
        if (_asks[board][slot].maker != address(0)) _removeAsk(board, slot, address(0)); // 持仓换手后卖单本来就失效
        _record(board, slot, unitPrice, stake);
        BEM.safeTransfer(msg.sender, cost);
        POSITIONS.transferFrom(msg.sender, bidder, IMonthPositions(address(POSITIONS)).idOf(board, slot));
        emit PositionTraded(board, slot, msg.sender, bidder, unitPrice, stake, cost, bidId);
    }

    function _record(address board, uint256 slot, uint256 unitPrice, uint256 stake) internal {
        uint256 n = tradeCount[board]++;
        _trades[board][n % TRADE_HISTORY] = Trade({
            unitPrice: uint96(unitPrice),
            stake: uint96(stake),
            time: uint40(block.timestamp),
            slot: SafeCast.toUint24(slot)
        });
    }

    function _pageSize(uint256 len, uint256 offset, uint256 limit) internal pure returns (uint256) {
        if (offset >= len) return 0;
        uint256 rest = len - offset;
        return limit == 0 || limit > rest ? rest : limit;
    }

    function _askView(address board, uint256 slot) internal view returns (AskView memory v) {
        AskOrder memory a = _asks[board][slot];
        (, uint256 stake,) = _pos(board, slot);
        v = AskView({
            slot: slot,
            maker: a.maker,
            unitPrice: a.unitPrice,
            stake: stake,
            cost: quote(stake, a.unitPrice),
            deadline: a.deadline,
            valid: _askValid(board, slot, a)
        });
    }

    function _bidView(uint256 bidId) internal view returns (BidView memory v) {
        BidOrder storage b = _bids[bidId];
        v = BidView({
            bidId: bidId,
            bidder: b.bidder,
            unitPrice: b.unitPrice,
            remaining: b.remaining,
            minStake: b.minStake,
            maxStake: b.maxStake,
            deadline: b.deadline,
            valid: bidValid(bidId)
        });
    }

    function _sortedAsks(address board, uint256 depth) internal view returns (AskView[] memory out) {
        uint256[] storage all = _askSlots[board];
        AskView[] memory tmp = new AskView[](all.length);
        uint256 n;
        for (uint256 i = 0; i < all.length; i++) {
            AskView memory v = _askView(board, all[i]);
            if (!v.valid) continue;
            uint256 j = n++;
            while (j > 0 && (tmp[j - 1].unitPrice > v.unitPrice || (tmp[j - 1].unitPrice == v.unitPrice && tmp[j - 1].slot > v.slot))) {
                tmp[j] = tmp[j - 1];
                j--;
            }
            tmp[j] = v;
        }
        out = _truncateAsks(tmp, depth == 0 || depth > n ? n : depth);
    }

    function _sortedBids(address board, uint256 depth) internal view returns (BidView[] memory out) {
        uint256[] storage all = _bidIds[board];
        BidView[] memory tmp = new BidView[](all.length);
        uint256 n;
        for (uint256 i = 0; i < all.length; i++) {
            BidView memory v = _bidView(all[i]);
            if (!v.valid) continue;
            uint256 j = n++;
            while (j > 0 && (tmp[j - 1].unitPrice < v.unitPrice || (tmp[j - 1].unitPrice == v.unitPrice && tmp[j - 1].bidId > v.bidId))) {
                tmp[j] = tmp[j - 1];
                j--;
            }
            tmp[j] = v;
        }
        out = _truncateBids(tmp, depth == 0 || depth > n ? n : depth);
    }

    function _truncateAsks(AskView[] memory a, uint256 n) internal pure returns (AskView[] memory) {
        assembly ("memory-safe") {
            mstore(a, n)
        }
        return a;
    }

    function _truncateBids(BidView[] memory a, uint256 n) internal pure returns (BidView[] memory) {
        assembly ("memory-safe") {
            mstore(a, n)
        }
        return a;
    }
}
