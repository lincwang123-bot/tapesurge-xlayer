// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMachineSource} from "../interfaces/IMachineSource.sol";
import {MonthState} from "../interfaces/IXMonthBoard.sol";
import {IMonthBoardV2} from "../interfaces/IXMonthV2.sol";
import {XMonthBoard} from "../XMonthBoard.sol";
import {XMonthFactory} from "../XMonthFactory.sol";
import {XMonthMachineSales} from "../month/XMonthMachineSales.sol";

/// @title XRigMarket（X Layer 上的 RIG 矿机市场，单例；嵌在 TapeSurge 月局的买入和卖出流程里，2026-10-29 项目方决定）
/// @notice 用 BEM 计价，报价单位是"每单位算力多少 BEM 最小单位"（算力 = RIG 记录的 power，即原矿机的 PoD 权重），
///         整张成交价 = 单价 × 成交时的算力。没有管理员，不可升级；只托管买单预算，卖单不托管 RIG。
///         - 卖单（对应 Firsto 卖单）：持有人授权本合约转移 RIG 后 listAsk；每张 RIG 同时只有一张卖单，重挂即改价。
///           持有人变了、撤销授权、过期（最长 30 天）或算力为 0 后自动失效。买家 buyAsk 吃单，buyBest 一笔按单价从低到高吃多张。
///           卖单对任何买家有效，包括正在收购的月局（见下）。
///         - 统一买单（对应 Firsto 按日产能的统一买单）：全额托管预算（≥ 1 BEM），写明单价、算力范围和最长同步间隔；
///           任何符合条件的 RIG 都可以卖给它（sellToBid），可以连续成交多张，剩余预算不够最小一张时自动关闭并退款。
///           每个地址最多 20 张未关闭买单。
///         - 月局从市场买矿（对应 BSC MarketTrader，规则决定 6.22 / 6.37）：任何人调用 sellAskToBoard，本合约把卖单的 RIG
///           卖给正在收购的月局；月局按卖单实价付款，实价不得超过 算力 × 月局当前收购价，资格（算力范围、3 天内同步）由月局检查。
///           收购价上限仍按 BSC 转报的行情（XMarketPriceFeed），和收购拍卖相同；拍卖照常进行。
///         - 月局在市场卖矿（对应 BSC 寄售，但不需要寄售库）：结算中的月局矿机按卖矿合约的公式要价（askPrice）显示在盘口
///           （boardOffers）。买家 buyBoardMachine 成交；或者任何人 fillBidFromBoard，让月局矿机按要价卖给出价够高的统一买单
///           （买家只付要价，多托管的留在买单里）。两条路都经过 XMonthMachineSales.buyMachine，要价、成本价、同步时间照旧检查。
///         - 手续费：FEE_BPS（部署时定，最多 1%；默认 0）从玩家卖方的成交款里扣，付给手续费 Safe；月局卖矿不收
///           （月局已经收溢价分成）。
///         - 定价：本合约的成交价只用于展示（recentTrades），不参与月局的收购价和卖价——量小时容易被操纵，
///           前期月局仍按 BSC 转报的行情定价。
///         已知限制：卖单不记版本号。持有人把 RIG 转走后卖单失效，之后再转回同一个地址会重新生效（有效期内）；
///         所以转走前最好先撤单。RIG 的产出付给 BSC 上发起收取那一刻的持有人：卖出前先在 BSC 金库收取一次，
///         否则之前累积的产出会付给买家。
contract XRigMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice 订单最长有效期
    uint256 public constant MAX_VALIDITY = 30 days;
    /// @notice 每张买单至少托管 1 BEM
    uint256 public constant MIN_BID_BUDGET = 1e8;
    /// @notice 每个地址最多 20 张未关闭买单
    uint256 public constant MAX_OPEN_BIDS = 20;
    /// @notice 保存最近 20 笔成交
    uint256 public constant TRADE_HISTORY = 20;
    /// @notice 手续费上限 1%（Firsto 的费率）
    uint256 public constant MAX_FEE_BPS = 100;
    uint256 internal constant BPS = 10_000;

    /// @notice 成交类型（RigTraded.kind / Trade.kind）
    uint8 public constant KIND_BUY_ASK = 1; // 买家吃卖单
    uint8 public constant KIND_ASK_TO_BOARD = 2; // 卖单卖给正在收购的月局
    uint8 public constant KIND_SELL_TO_BID = 3; // 持有人卖给买单
    uint8 public constant KIND_BOARD_TO_BID = 4; // 月局矿机卖给买单
    uint8 public constant KIND_BUY_BOARD = 5; // 买家买月局矿机

    struct AskOrder {
        address seller; // 挂单时的持有人；0 = 没有卖单
        uint64 deadline;
        uint96 price; // 每单位算力
    }

    struct BidOrder {
        address bidder; // 0 = 已关闭
        uint64 deadline;
        uint32 maxSyncAge; // RIG 最近一次同步不早于这么多秒以前；0 = 不限
        uint96 price; // 每单位算力
        uint96 remaining; // 剩余托管预算
        uint32 minPower;
        uint32 maxPower;
    }

    struct AskView {
        uint256 rigId;
        address seller;
        uint256 price;
        uint256 power;
        uint256 total; // price × power
        uint256 syncedAt;
        uint64 deadline;
        bool valid;
        bool boardEligible; // 符合月局收购资格（RigMachineSource.purchaseWeight > 0）
    }

    struct BidView {
        uint256 bidId;
        address bidder;
        uint256 price;
        uint256 remaining;
        uint256 minPower;
        uint256 maxPower;
        uint256 maxSyncAge;
        uint64 deadline;
        bool valid;
    }

    /// @notice 结算中的月局正在卖的一台矿机
    struct OfferView {
        uint256 index; // 主板里的矿机序号
        uint256 rigId;
        uint256 power;
        uint256 total; // 卖矿合约现在的整台要价（askPrice）
        uint256 syncedAt;
        bool syncFresh; // 1 天内同步过（不是的话要先在 BSC 金库收取一次才能买）
    }

    struct Trade {
        uint256 rigId;
        uint96 price; // 每单位算力（月局卖矿的成交按 总价 ÷ 算力 向下取整）
        uint32 power;
        uint40 time;
        uint8 kind;
    }

    IERC20 public immutable BEM;
    IERC721 public immutable RIG;
    IMachineSource public immutable MACHINE_SOURCE;
    XMonthFactory public immutable FACTORY;
    XMonthMachineSales public immutable SALES;
    address public immutable FEE_RECIPIENT;
    uint256 public immutable FEE_BPS;

    mapping(uint256 => AskOrder) internal _asks;
    uint256[] internal _askIds; // 有卖单记录的 RIG（含已失效、未清理的）
    mapping(uint256 => uint256) internal _askPos; // RIG 在 _askIds 里的位置 + 1

    mapping(uint256 => BidOrder) internal _bids;
    uint256[] internal _bidIds; // 未关闭的买单
    mapping(uint256 => uint256) internal _bidPos; // 买单在 _bidIds 里的位置 + 1
    mapping(address => uint256) public openBidsOf;
    uint256 public lastBidId;
    uint256 public totalEscrow; // Σ 未关闭买单的 remaining；不变量：BEM.balanceOf(this) ≥ totalEscrow

    Trade[20] internal _trades;
    uint256 public tradeCount;

    event AskListed(uint256 indexed rigId, address indexed seller, uint256 price, uint64 deadline);
    event AskCancelled(uint256 indexed rigId, address indexed by);
    event BidPlaced(
        uint256 indexed bidId,
        address indexed bidder,
        uint256 price,
        uint256 budget,
        uint256 minPower,
        uint256 maxPower,
        uint256 maxSyncAge,
        uint64 deadline
    );
    /// @param reason 1 买家撤单 2 过期后退款 3 剩余预算不够最小一张，自动关闭
    event BidClosed(uint256 indexed bidId, uint256 refund, uint8 reason);
    /// @param seller 卖方（月局卖矿时是主板地址）
    /// @param buyer 买方（卖给月局时是主板地址）
    /// @param price 每单位算力
    /// @param fee 付给手续费 Safe 的部分（从卖方的成交款里扣）
    /// @param bidId 0 = 不是卖给买单
    event RigTraded(
        uint256 indexed rigId,
        address indexed seller,
        address indexed buyer,
        uint256 price,
        uint256 power,
        uint256 total,
        uint256 fee,
        uint256 bidId,
        uint8 kind
    );

    error BadConfig();
    error BadDeadline();
    error ZeroPrice();
    error NotOwner();
    error NotApproved();
    error NoPower();
    error NoAsk();
    error AskNotValid();
    error PriceAbove();
    error SelfTrade();
    error PaymentMismatch();
    error NothingFilled();
    error NotMonthBoard();
    error BudgetTooSmall();
    error BadPowerRange();
    error TooManyBids();
    error BidClosedAlready();
    error BidExpired();
    error NotBidder();
    error BidStillValid();
    error PowerOutOfRange();
    error SyncTooOld();
    error BudgetExceeded();
    error NotForSale();

    /// @param monthFactory 月局工厂；BEM、矿机来源、卖矿合约、手续费 Safe 都从它的月局配置读取，
    ///        配置里的 market 必须就是本合约（部署时预测地址）
    /// @param feeBps 手续费（≤ 1%）
    constructor(address monthFactory, uint256 feeBps) {
        if (monthFactory == address(0) || feeBps > MAX_FEE_BPS) revert BadConfig();
        XMonthBoard.Config memory c = XMonthFactory(monthFactory).boardConfig();
        if (c.market != address(this)) revert BadConfig();
        BEM = IERC20(c.bem);
        MACHINE_SOURCE = IMachineSource(c.machineSource);
        RIG = IERC721(MACHINE_SOURCE.machineToken());
        FACTORY = XMonthFactory(monthFactory);
        SALES = XMonthMachineSales(c.sales);
        FEE_RECIPIENT = c.feeRecipient;
        FEE_BPS = feeBps;
    }

    // ============ 卖单 ============

    /// @notice 挂卖单或改价：调用者必须是这张 RIG 的当前持有人，且已授权本合约转移它。0 < deadline − now ≤ 30 天。
    function listAsk(uint256 rigId, uint256 price, uint64 deadline) external {
        _checkDeadline(deadline);
        if (price == 0) revert ZeroPrice();
        if (_ownerOf(rigId) != msg.sender) revert NotOwner();
        if (!_approved(msg.sender, rigId)) revert NotApproved();
        if (_power(rigId) == 0) revert NoPower();
        _asks[rigId] = AskOrder({seller: msg.sender, deadline: deadline, price: SafeCast.toUint96(price)});
        if (_askPos[rigId] == 0) {
            _askIds.push(rigId);
            _askPos[rigId] = _askIds.length;
        }
        emit AskListed(rigId, msg.sender, price, deadline);
    }

    /// @notice 撤卖单：挂单人或这张 RIG 的当前持有人可以撤。
    function cancelAsk(uint256 rigId) external {
        AskOrder storage a = _asks[rigId];
        if (a.seller == address(0)) revert NoAsk();
        if (msg.sender != a.seller && msg.sender != _ownerOf(rigId)) revert NotOwner();
        _removeAsk(rigId, msg.sender);
    }

    /// @notice 任何人：删掉已失效的卖单（只影响存储和读取成本，不涉及资金）。仍然有效的跳过。
    function pruneAsks(uint256[] calldata rigIds) external {
        for (uint256 i = 0; i < rigIds.length; i++) {
            AskOrder memory a = _asks[rigIds[i]];
            if (a.seller != address(0) && !_askValid(rigIds[i], a)) _removeAsk(rigIds[i], msg.sender);
        }
    }

    /// @notice 吃一张卖单：调用者付 单价 × 算力 并收到 RIG；总价高于 maxTotal 时回滚（防止被抢先改价）。
    ///         需要事先授权本合约 BEM。成交款直接转给卖方（扣手续费）。
    function buyAsk(uint256 rigId, uint256 maxTotal) external nonReentrant returns (uint256 total) {
        AskOrder memory a = _asks[rigId];
        if (a.seller == address(0)) revert NoAsk();
        if (!_askValid(rigId, a)) revert AskNotValid();
        if (msg.sender == a.seller) revert SelfTrade();
        uint256 power = _power(rigId);
        total = a.price * power;
        if (total > maxTotal) revert PriceAbove();
        _fillAsk(rigId, a, power);
    }

    /// @notice 按最优价批量吃单：把 rigIds 里的卖单按单价从低到高（同价按编号）依次成交，每张单价 ≤ maxPrice，
    ///         总花费 ≤ maxTotal。失效的卖单跳过、不回滚：没有卖单、已失效、单价高于 maxPrice、是调用者自己的、
    ///         或加上它会超过 maxTotal 的都跳过；一张都没成交时回滚（NothingFilled）。rigIds 通常取 book(n) 的前 n 档。
    function buyBest(uint256[] calldata rigIds, uint256 maxPrice, uint256 maxTotal)
        external
        nonReentrant
        returns (uint256 filled, uint256 spent)
    {
        uint256 n = rigIds.length;
        uint256[] memory order = new uint256[](n);
        uint256[] memory price = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 p = _asks[rigIds[i]].price;
            uint256 j = i;
            while (j > 0 && (price[j - 1] > p || (price[j - 1] == p && order[j - 1] > rigIds[i]))) {
                order[j] = order[j - 1];
                price[j] = price[j - 1];
                j--;
            }
            order[j] = rigIds[i];
            price[j] = p;
        }
        for (uint256 i = 0; i < n; i++) {
            uint256 rigId = order[i];
            AskOrder memory a = _asks[rigId];
            if (a.seller == address(0) || a.seller == msg.sender || a.price > maxPrice) continue;
            if (!_askValid(rigId, a)) continue;
            uint256 power = _power(rigId);
            uint256 total = a.price * power;
            if (spent + total > maxTotal) continue;
            _fillAsk(rigId, a, power);
            spent += total;
            filled++;
        }
        if (filled == 0) revert NothingFilled();
    }

    /// @notice 把一张卖单卖给正在收购的月局（任何人可调，对应 BSC MarketTrader）：本合约按卖单价从卖方取走 RIG，
    ///         调用主板 sellMachine，主板按卖单实价（单价 × 算力）付款；实价超过 算力 × 主板当前收购价、主板不在收购期、
    ///         RIG 不符合收购资格、预算不够或买满时整笔回滚。成交款转给卖方（扣手续费）。
    function sellAskToBoard(uint256 rigId, address board) external nonReentrant returns (uint256 total) {
        AskOrder memory a = _asks[rigId];
        if (a.seller == address(0)) revert NoAsk();
        if (!_askValid(rigId, a)) revert AskNotValid();
        if (!FACTORY.isBoard(board)) revert NotMonthBoard();
        uint256 power = _power(rigId);
        total = a.price * power;
        _removeAsk(rigId, address(0));
        _record(rigId, a.price, power, KIND_ASK_TO_BOARD);
        RIG.transferFrom(a.seller, address(this), rigId);
        RIG.approve(board, rigId);
        uint256 before = BEM.balanceOf(address(this));
        uint256 paid = IMonthBoardV2(board).sellMachine(address(RIG), rigId, total);
        if (paid != total || BEM.balanceOf(address(this)) - before != total) revert PaymentMismatch();
        uint256 fee = _fee(total);
        BEM.safeTransfer(a.seller, total - fee);
        if (fee > 0) BEM.safeTransfer(FEE_RECIPIENT, fee);
        emit RigTraded(rigId, a.seller, board, a.price, power, total, fee, 0, KIND_ASK_TO_BOARD);
    }

    // ============ 买单 ============

    /// @notice 挂统一买单，托管 budget 个 BEM（≥ 1 BEM，且至少够买一张 minPower 算力的 RIG）。
    ///         算力在 [minPower, maxPower]、最近一次同步在 maxSyncAge 秒以内（0 = 不限）的 RIG 都可以按 单价 × 算力 卖给它。
    function placeBid(
        uint256 price,
        uint256 budget,
        uint256 minPower,
        uint256 maxPower,
        uint256 maxSyncAge,
        uint64 deadline
    ) external nonReentrant returns (uint256 bidId) {
        _checkDeadline(deadline);
        if (price == 0) revert ZeroPrice();
        if (minPower == 0) minPower = 1;
        if (maxPower < minPower) revert BadPowerRange();
        if (budget < MIN_BID_BUDGET || budget < price * minPower) revert BudgetTooSmall();
        if (openBidsOf[msg.sender] >= MAX_OPEN_BIDS) revert TooManyBids();
        uint256 before = BEM.balanceOf(address(this));
        BEM.safeTransferFrom(msg.sender, address(this), budget);
        if (BEM.balanceOf(address(this)) - before != budget) revert PaymentMismatch();
        bidId = ++lastBidId;
        _bids[bidId] = BidOrder({
            bidder: msg.sender,
            deadline: deadline,
            maxSyncAge: SafeCast.toUint32(maxSyncAge),
            price: SafeCast.toUint96(price),
            remaining: SafeCast.toUint96(budget),
            minPower: SafeCast.toUint32(minPower),
            maxPower: SafeCast.toUint32(maxPower > type(uint32).max ? type(uint32).max : maxPower)
        });
        _bidIds.push(bidId);
        _bidPos[bidId] = _bidIds.length;
        openBidsOf[msg.sender] += 1;
        totalEscrow += budget;
        emit BidPlaced(bidId, msg.sender, price, budget, minPower, maxPower, maxSyncAge, deadline);
    }

    /// @notice 持有人把一张 RIG 卖给买单（要事先授权本合约转移 RIG）：按 买单单价 × 算力 从托管预算付款（扣手续费），
    ///         RIG 转给买家。买单条款挂出后不能改，所以不需要最低价保护。剩余预算不够最小一张时买单自动关闭并退款。
    function sellToBid(uint256 bidId, uint256 rigId) external nonReentrant returns (uint256 cost) {
        BidOrder storage b = _bids[bidId];
        _checkBidOpen(b);
        if (msg.sender == b.bidder) revert SelfTrade();
        if (_ownerOf(rigId) != msg.sender) revert NotOwner();
        uint256 power = _matchPower(b, rigId);
        cost = b.price * power;
        if (cost > b.remaining) revert BudgetExceeded();
        b.remaining -= uint96(cost);
        totalEscrow -= cost;
        address bidder = b.bidder;
        uint256 price = b.price;
        if (_asks[rigId].seller != address(0)) _removeAsk(rigId, address(0)); // 换手后旧卖单本来就失效
        _record(rigId, price, power, KIND_SELL_TO_BID);
        uint256 fee = _fee(cost);
        BEM.safeTransfer(msg.sender, cost - fee);
        if (fee > 0) BEM.safeTransfer(FEE_RECIPIENT, fee);
        RIG.transferFrom(msg.sender, bidder, rigId);
        emit RigTraded(rigId, msg.sender, bidder, price, power, cost, fee, bidId, KIND_SELL_TO_BID);
        _closeIfSpent(bidId);
    }

    /// @notice 让结算中的月局把第 index 台矿机卖给买单（任何人可调）：按卖矿合约现在的整台要价（askPrice）成交，
    ///         要价不得超过 买单单价 × 算力，买家只付要价（多托管的留在买单里）；RIG 要符合买单的算力范围和同步要求，
    ///         卖矿合约另外要求 1 天内同步过、不低于成本价（清算计划除外）。月局卖矿不收市场手续费。
    function fillBidFromBoard(uint256 bidId, address board, uint256 index)
        external
        nonReentrant
        returns (uint256 cost)
    {
        BidOrder storage b = _bids[bidId];
        _checkBidOpen(b);
        uint256 rigId = _boardRig(board, index);
        uint256 power = _matchPower(b, rigId);
        cost = SALES.askPrice(board, index);
        if (cost == 0) revert NotForSale();
        if (cost > b.price * power) revert PriceAbove();
        if (cost > b.remaining) revert BudgetExceeded();
        b.remaining -= uint96(cost);
        totalEscrow -= cost;
        address bidder = b.bidder;
        _buyFromBoard(board, index, rigId, cost, power, bidder, KIND_BOARD_TO_BID);
        emit RigTraded(rigId, board, bidder, cost / power, power, cost, 0, bidId, KIND_BOARD_TO_BID);
        _closeIfSpent(bidId);
    }

    /// @notice 买结算中月局的第 index 台矿机（同 XMonthMachineSales.buyMachine，只是从市场下单）：按现在的整台要价付款，
    ///         要价高于 maxPrice 时回滚。需要事先授权本合约 BEM。
    function buyBoardMachine(address board, uint256 index, uint256 maxPrice)
        external
        nonReentrant
        returns (uint256 cost)
    {
        uint256 rigId = _boardRig(board, index);
        cost = SALES.askPrice(board, index);
        if (cost == 0) revert NotForSale();
        if (cost > maxPrice) revert PriceAbove();
        uint256 before = BEM.balanceOf(address(this));
        BEM.safeTransferFrom(msg.sender, address(this), cost);
        if (BEM.balanceOf(address(this)) - before != cost) revert PaymentMismatch();
        uint256 power = _power(rigId);
        _buyFromBoard(board, index, rigId, cost, power, msg.sender, KIND_BUY_BOARD);
        emit RigTraded(rigId, board, msg.sender, power == 0 ? 0 : cost / power, power, cost, 0, 0, KIND_BUY_BOARD);
    }

    /// @notice 买家撤单，剩余预算直接退回买家。
    function cancelBid(uint256 bidId) external nonReentrant {
        BidOrder storage b = _bids[bidId];
        if (b.bidder == address(0)) revert BidClosedAlready();
        if (msg.sender != b.bidder) revert NotBidder();
        _closeBid(bidId, 1);
    }

    /// @notice 过期后任何人都可以帮买家退款（钱只退给买家）。
    function refundBid(uint256 bidId) external nonReentrant {
        BidOrder storage b = _bids[bidId];
        if (b.bidder == address(0)) revert BidClosedAlready();
        if (block.timestamp < b.deadline) revert BidStillValid();
        _closeBid(bidId, 2);
    }

    // ============ 读取 ============

    function ask(uint256 rigId) external view returns (AskOrder memory) {
        return _asks[rigId];
    }

    /// @notice 卖单是否仍然有效（没过期；持有人没变、仍授权本合约；算力 > 0）
    function askValid(uint256 rigId) public view returns (bool) {
        AskOrder memory a = _asks[rigId];
        return a.seller != address(0) && _askValid(rigId, a);
    }

    function bid(uint256 bidId) external view returns (BidOrder memory) {
        return _bids[bidId];
    }

    /// @notice 买单是否还能成交（未关闭、未过期、剩余预算够最小一张）
    function bidValid(uint256 bidId) public view returns (bool) {
        BidOrder storage b = _bids[bidId];
        return
            b.bidder != address(0) && block.timestamp < b.deadline
                && uint256(b.remaining) >= uint256(b.price) * b.minPower;
    }

    function askCount() external view returns (uint256) {
        return _askIds.length;
    }

    function bidCount() external view returns (uint256) {
        return _bidIds.length;
    }

    /// @notice 分页读取有卖单记录的 RIG（含已失效的，valid 字段标明）。顺序不固定。
    function asksPage(uint256 offset, uint256 limit) external view returns (AskView[] memory out) {
        uint256 n = _pageSize(_askIds.length, offset, limit);
        out = new AskView[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _askView(_askIds[offset + i]);
        }
    }

    /// @notice 分页读取未关闭的买单（valid 字段标明现在能否成交）。顺序不固定。
    function bidsPage(uint256 offset, uint256 limit) external view returns (BidView[] memory out) {
        uint256 n = _pageSize(_bidIds.length, offset, limit);
        out = new BidView[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _bidView(_bidIds[offset + i]);
        }
    }

    /// @notice 盘口：只含有效订单；卖单按单价从低到高（同价按编号），买单按单价从高到低（同价先挂的在前），各取前 depth 档
    ///         （depth = 0 表示全部）。月局在卖的矿机见 boardOffers。订单很多时改用 asksPage / bidsPage 分页。
    function book(uint256 depth) external view returns (AskView[] memory asks, BidView[] memory bids) {
        asks = _sortedAsks(depth);
        bids = _sortedBids(depth);
    }

    /// @notice 结算中的月局现在可以买的矿机（卖矿合约要价 > 0；syncFresh 为假的要先在 BSC 金库收取一次才能成交）。
    ///         不是结算中的月局返回空数组。
    function boardOffers(address board) external view returns (OfferView[] memory out) {
        if (!FACTORY.isBoard(board) || IMonthBoardV2(board).state() != MonthState.Settling) return out;
        IMonthBoardV2 b = IMonthBoardV2(board);
        uint256 n = b.machineCount();
        out = new OfferView[](n);
        uint256 k;
        for (uint256 i = 0; i < n; i++) {
            IMonthBoardV2.MachineView memory m = b.machine(i);
            if (m.sold) continue;
            uint256 total = SALES.askPrice(board, i);
            if (total == 0) continue;
            out[k++] = OfferView({
                index: i,
                rigId: m.circuitId,
                power: _power(m.circuitId),
                total: total,
                syncedAt: MACHINE_SOURCE.syncedAt(m.circuitId),
                syncFresh: SALES.syncFresh(board, i)
            });
        }
        assembly ("memory-safe") {
            mstore(out, k)
        }
    }

    /// @notice 最近 20 笔成交，从新到旧
    function recentTrades() external view returns (Trade[] memory out) {
        uint256 total = tradeCount;
        uint256 n = total < TRADE_HISTORY ? total : TRADE_HISTORY;
        out = new Trade[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _trades[(total - 1 - i) % TRADE_HISTORY];
        }
    }

    // ============ 内部 ============

    function _checkDeadline(uint64 deadline) internal view {
        if (deadline <= block.timestamp || deadline - block.timestamp > MAX_VALIDITY) revert BadDeadline();
    }

    function _checkBidOpen(BidOrder storage b) internal view {
        if (b.bidder == address(0)) revert BidClosedAlready();
        if (block.timestamp >= b.deadline) revert BidExpired();
    }

    /// @dev 当前持有人；不存在（已赎回烧掉）时为 0
    function _ownerOf(uint256 rigId) internal view returns (address) {
        try RIG.ownerOf(rigId) returns (address o) {
            return o;
        } catch {
            return address(0);
        }
    }

    function _approved(address owner, uint256 rigId) internal view returns (bool) {
        return RIG.isApprovedForAll(owner, address(this)) || RIG.getApproved(rigId) == address(this);
    }

    function _power(uint256 rigId) internal view returns (uint256) {
        return MACHINE_SOURCE.currentWeight(rigId);
    }

    function _askValid(uint256 rigId, AskOrder memory a) internal view returns (bool) {
        if (block.timestamp >= a.deadline || _ownerOf(rigId) != a.seller) return false;
        return _approved(a.seller, rigId) && _power(rigId) > 0;
    }

    /// @dev RIG 符合买单条件时返回算力：算力在 [minPower, maxPower]，最近一次同步在 maxSyncAge 以内（0 = 不限）
    function _matchPower(BidOrder storage b, uint256 rigId) internal view returns (uint256 power) {
        power = _power(rigId);
        if (power < b.minPower || power > b.maxPower) revert PowerOutOfRange();
        uint256 age = b.maxSyncAge;
        if (age != 0) {
            uint256 t = MACHINE_SOURCE.syncedAt(rigId);
            if (t > block.timestamp || block.timestamp - t > age) revert SyncTooOld();
        }
    }

    function _fee(uint256 amount) internal view returns (uint256) {
        return amount * FEE_BPS / BPS;
    }

    function _boardRig(address board, uint256 index) internal view returns (uint256) {
        if (!FACTORY.isBoard(board)) revert NotMonthBoard();
        return IMonthBoardV2(board).machine(index).circuitId;
    }

    /// @dev 用本合约里的 cost 个 BEM 经卖矿合约买下月局矿机，再把 RIG 转给 to（按余额差和持有人核对）
    function _buyFromBoard(
        address board,
        uint256 index,
        uint256 rigId,
        uint256 cost,
        uint256 power,
        address to,
        uint8 kind
    ) internal {
        if (_asks[rigId].seller != address(0)) _removeAsk(rigId, address(0));
        _record(rigId, power == 0 ? 0 : cost / power, power, kind);
        uint256 before = BEM.balanceOf(address(this));
        BEM.forceApprove(address(SALES), cost);
        SALES.buyMachine(board, index, cost);
        if (before - BEM.balanceOf(address(this)) != cost || RIG.ownerOf(rigId) != address(this)) {
            revert PaymentMismatch();
        }
        RIG.transferFrom(address(this), to, rigId);
    }

    /// @dev 成交一张卖单：先删卖单、记成交，再把 BEM 从买家直接转给卖方（按卖方余额差核对）和手续费 Safe、转移 RIG
    function _fillAsk(uint256 rigId, AskOrder memory a, uint256 power) internal {
        uint256 total = a.price * power;
        _removeAsk(rigId, address(0));
        _record(rigId, a.price, power, KIND_BUY_ASK);
        uint256 fee = _fee(total);
        uint256 before = BEM.balanceOf(a.seller);
        BEM.safeTransferFrom(msg.sender, a.seller, total - fee);
        if (BEM.balanceOf(a.seller) - before != total - fee) revert PaymentMismatch();
        if (fee > 0) BEM.safeTransferFrom(msg.sender, FEE_RECIPIENT, fee);
        RIG.transferFrom(a.seller, msg.sender, rigId);
        emit RigTraded(rigId, a.seller, msg.sender, a.price, power, total, fee, 0, KIND_BUY_ASK);
    }

    function _removeAsk(uint256 rigId, address by) internal {
        delete _asks[rigId];
        uint256 pos = _askPos[rigId];
        uint256 last = _askIds[_askIds.length - 1];
        _askIds[pos - 1] = last;
        _askPos[last] = pos;
        _askIds.pop();
        delete _askPos[rigId];
        if (by != address(0)) emit AskCancelled(rigId, by);
    }

    function _closeIfSpent(uint256 bidId) internal {
        BidOrder storage b = _bids[bidId];
        if (uint256(b.remaining) < uint256(b.price) * b.minPower) _closeBid(bidId, 3);
    }

    function _closeBid(uint256 bidId, uint8 reason) internal {
        BidOrder memory b = _bids[bidId];
        delete _bids[bidId];
        uint256 pos = _bidPos[bidId];
        uint256 last = _bidIds[_bidIds.length - 1];
        _bidIds[pos - 1] = last;
        _bidPos[last] = pos;
        _bidIds.pop();
        delete _bidPos[bidId];
        openBidsOf[b.bidder] -= 1;
        totalEscrow -= b.remaining;
        if (b.remaining > 0) BEM.safeTransfer(b.bidder, b.remaining);
        emit BidClosed(bidId, b.remaining, reason);
    }

    function _record(uint256 rigId, uint256 price, uint256 power, uint8 kind) internal {
        uint256 n = tradeCount++;
        _trades[n % TRADE_HISTORY] = Trade({
            rigId: rigId,
            price: SafeCast.toUint96(price),
            power: SafeCast.toUint32(power),
            time: uint40(block.timestamp),
            kind: kind
        });
    }

    function _pageSize(uint256 len, uint256 offset, uint256 limit) internal pure returns (uint256) {
        if (offset >= len) return 0;
        uint256 rest = len - offset;
        return limit == 0 || limit > rest ? rest : limit;
    }

    function _askView(uint256 rigId) internal view returns (AskView memory v) {
        AskOrder memory a = _asks[rigId];
        uint256 power = _power(rigId);
        v = AskView({
            rigId: rigId,
            seller: a.seller,
            price: a.price,
            power: power,
            total: a.price * power,
            syncedAt: MACHINE_SOURCE.syncedAt(rigId),
            deadline: a.deadline,
            valid: a.seller != address(0) && _askValid(rigId, a),
            boardEligible: MACHINE_SOURCE.purchaseWeight(rigId) > 0
        });
    }

    function _bidView(uint256 bidId) internal view returns (BidView memory v) {
        BidOrder storage b = _bids[bidId];
        v = BidView({
            bidId: bidId,
            bidder: b.bidder,
            price: b.price,
            remaining: b.remaining,
            minPower: b.minPower,
            maxPower: b.maxPower,
            maxSyncAge: b.maxSyncAge,
            deadline: b.deadline,
            valid: bidValid(bidId)
        });
    }

    function _sortedAsks(uint256 depth) internal view returns (AskView[] memory out) {
        uint256 len = _askIds.length;
        out = new AskView[](len);
        uint256 n;
        for (uint256 i = 0; i < len; i++) {
            AskView memory v = _askView(_askIds[i]);
            if (!v.valid) continue;
            uint256 j = n++;
            while (
                j > 0 && (out[j - 1].price > v.price || (out[j - 1].price == v.price && out[j - 1].rigId > v.rigId))
            ) {
                out[j] = out[j - 1];
                j--;
            }
            out[j] = v;
        }
        if (depth != 0 && depth < n) n = depth;
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    function _sortedBids(uint256 depth) internal view returns (BidView[] memory out) {
        uint256 len = _bidIds.length;
        out = new BidView[](len);
        uint256 n;
        for (uint256 i = 0; i < len; i++) {
            BidView memory v = _bidView(_bidIds[i]);
            if (!v.valid) continue;
            uint256 j = n++;
            while (
                j > 0 && (out[j - 1].price < v.price || (out[j - 1].price == v.price && out[j - 1].bidId > v.bidId))
            ) {
                out[j] = out[j - 1];
                j--;
            }
            out[j] = v;
        }
        if (depth != 0 && depth < n) n = depth;
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }
}
