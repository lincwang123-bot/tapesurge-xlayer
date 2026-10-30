// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IBoardHub} from "../interfaces/IHub.sol";

/// @title XMarketPriceFeed（BSC 矿机行情的 X Layer 转报 + 买卖定价，单例，所有月局共用；V2-PORT.md 第 3 节）
/// @notice RIG 凭证背后就是锁在 BSC 金库里的 PoD 矿机（算力 = 原矿机的 PoD 权重，持有人可以烧凭证在 BSC 取回矿机），
///         所以 BSC 上的矿机行情就是 RIG 的参照价。X Layer 合约读不到 BSC，由运营地址把 BSC 报价合约
///         （TapeSurge v2 MarketPriceFeed）链上的 bid() / ask() 原样转报到这里，单位相同：每单位算力的 BEM 最小单位数
///         （两条链上的 BEM 都是 8 位小数）。每次报价带上读取时的 BSC 区块号，任何人都能在 BSC 上按这个区块核对。
///         报价保护、收购价上限和卖价公式都和 BSC 的 MarketPriceFeed 相同（2026-10-28 项目方决定：除链上条件不同的部分外和 BSC 对齐）：
///         - 0 < bid ≤ ask；bid、ask 各自相对上一次变动 ≤ 5%（任何时候都限，停报再久也不能一步报到任意价）；
///         - 两次报价至少间隔 50 分钟；超过 3 小时没更新算过期；超过 7 天没有有效报价算停运（只按时间判断）；
///         - BSC 那边在追价（catchingUp）时，这里用 postCatchUp 同步，追价期间不算有效报价；
///         - 收购价上限（buyQuote）= min(卖一, 一年产出上限)；报价无效（过期、追价、运营地址为 0、停运）时为 0（暂停收购）；
///           从没报过价时用主板自己的默认曲线（XHub.startGenesis 要求开局前已经报过价，实际用不到）；
///         - 卖价（sellQuote）= max(bid, ask × (99% − 0.5% × n))，n = 卖出阶段开始后已过的整 6 小时数；报价无效时为 0。
///         和 BSC 的差别只有两处，都是链上条件决定的：多了 BSC 区块号（转报来源可核对）；没有"保持排序第一"的目标价
///         （postFloor / floorQuote）：BSC 用它让主板寄售到矿机市场的挂单排第一，X Layer 上没有 RIG 的矿机市场可以寄售。
///         没有管理员，参数不可改。
contract XMarketPriceFeed {
    uint256 public constant BPS = 10_000;

    IBoardHub public immutable HUB;
    uint256 public immutable maxChangeBps; // 500：每次报价 bid / ask 各自最多变动 5%
    uint256 public immutable minInterval; // 50 分钟：两次报价至少间隔
    uint256 public immutable maxStaleness; // 3 小时：超过算过期
    uint256 public immutable abandonAfter; // 7 天：超过算停运
    uint256 public immutable sellStartBps; // 9900：卖价从卖一 × 99% 起
    uint256 public immutable sellStepBps; // 50：卖价每个 sellStepInterval 降卖一的 0.5%
    uint256 public immutable sellStepInterval; // 6 小时

    /// @notice 最近一次报价（每单位算力的 BEM 最小单位数）和时间（0 = 从没报过价）
    uint256 public bid;
    uint256 public ask;
    uint256 public updatedAt;
    /// @notice 最近一次报价读取的 BSC 区块号（运营地址自报，只用于核对）
    uint256 public sourceBlock;
    /// @notice 追价中：最近一次报价是 postCatchUp 报的，不算有效报价
    bool public catchingUp;
    /// @notice 最近一次有效报价（post，或第一次报价）的时间。停运按它算：一直追价也会在 7 天后停运
    uint256 public liveAt;

    event PricesPosted(
        uint256 bid, uint256 ask, uint256 previousBid, uint256 previousAsk, uint256 sourceBlock, uint256 time
    );
    /// @notice 这次报价是追价中的一步（同时发 PricesPosted）
    event CatchUpPosted(uint256 bid, uint256 ask, uint256 time);

    error BadConfig();
    error NotOperator();
    error BadPrices();
    error TooSoon();
    error ChangeTooLarge();

    constructor(
        address hub,
        uint256 maxChangeBps_,
        uint256 minInterval_,
        uint256 maxStaleness_,
        uint256 abandonAfter_,
        uint256 sellStartBps_,
        uint256 sellStepBps_,
        uint256 sellStepInterval_
    ) {
        if (
            hub == address(0) || maxChangeBps_ == 0 || maxChangeBps_ >= BPS || maxStaleness_ == 0
                || minInterval_ >= maxStaleness_ || abandonAfter_ < maxStaleness_ || sellStartBps_ > BPS
                || sellStepInterval_ == 0
        ) revert BadConfig();
        HUB = IBoardHub(hub);
        maxChangeBps = maxChangeBps_;
        minInterval = minInterval_;
        maxStaleness = maxStaleness_;
        abandonAfter = abandonAfter_;
        sellStartBps = sellStartBps_;
        sellStepBps = sellStepBps_;
        sellStepInterval = sellStepInterval_;
    }

    // ============ 报价 ============

    /// @notice 运营地址转报 BSC 报价合约在 bscBlock 区块的买一和卖一（每单位算力的 BEM 价）。0 < bid ≤ ask，报价随即有效。
    function post(uint256 newBid, uint256 newAsk, uint256 bscBlock) external {
        _post(newBid, newAsk, bscBlock, false);
    }

    /// @notice 追价：BSC 那边在追价，或这里落后 BSC 超过 5% 时，按 ±5% 一步步追；这期间报价不算有效（fresh() 为假），
    ///         收购和卖出暂停、清算计划价暂停。追到的最后一步用 post。停运按最后一次有效报价的时间算。
    function postCatchUp(uint256 newBid, uint256 newAsk, uint256 bscBlock) external {
        _post(newBid, newAsk, bscBlock, true);
    }

    function _post(uint256 newBid, uint256 newAsk, uint256 bscBlock, bool catchUp) internal {
        address op = HUB.operator();
        if (op == address(0) || msg.sender != op) revert NotOperator();
        if (newBid == 0 || newBid > newAsk) revert BadPrices();
        uint256 lastBid = bid;
        uint256 lastAsk = ask;
        uint256 t = updatedAt;
        if (t != 0) {
            if (block.timestamp < t + minInterval) revert TooSoon();
            if (!_within(newBid, lastBid) || !_within(newAsk, lastAsk)) revert ChangeTooLarge();
        }
        bid = newBid;
        ask = newAsk;
        updatedAt = block.timestamp;
        sourceBlock = bscBlock;
        catchingUp = catchUp;
        if (!catchUp || t == 0) liveAt = block.timestamp;
        emit PricesPosted(newBid, newAsk, lastBid, lastAsk, bscBlock, block.timestamp);
        if (catchUp) emit CatchUpPosted(newBid, newAsk, block.timestamp);
    }

    // ============ 状态 ============

    /// @notice 报价有效：报过、没过期（< 3 小时）、运营地址非 0、不在追价中
    function fresh() public view returns (bool) {
        uint256 t = updatedAt;
        return !catchingUp && t != 0 && block.timestamp < t + maxStaleness && HUB.operator() != address(0);
    }

    /// @notice 停运：从没报过价，或超过 7 天没有有效报价（只按时间判断；运营地址为 0 时 fresh() 为假，即暂停）
    function abandoned() public view returns (bool) {
        return updatedAt == 0 || block.timestamp >= liveAt + abandonAfter;
    }

    // ============ 定价（同 BSC MarketPriceFeed）============

    /// @notice 主板的收购价上限（每单位算力）。cap = 主板快照的一年产出上限；curvePrice = 主板默认曲线的当前价。
    ///         报价有效 → min(ask, cap)；从没报过价 → curvePrice；报过价之后无效（过期、追价、运营地址为 0、停运）→ 0
    ///         （暂停）。第三个参数不用，保留是为了和 BSC 接口相同。
    function buyQuote(uint256 cap, uint256 curvePrice, uint256) external view returns (uint256 p) {
        if (updatedAt == 0) return curvePrice;
        if (!fresh()) return 0;
        p = ask < cap ? ask : cap;
    }

    /// @notice 卖价（每单位算力）= max(bid, ask × (99% − 0.5% × n))，n = 卖出阶段开始（since）后已过的整 6 小时数。
    ///         报价无效（过期 / 没报过 / 追价 / 运营地址为 0）时返回 0。
    function sellQuote(uint256 since) external view returns (uint256 p) {
        if (!fresh()) return 0;
        uint256 n = block.timestamp > since ? (block.timestamp - since) / sellStepInterval : 0;
        uint256 drop = sellStepBps * n;
        if (drop < sellStartBps) p = ask * (sellStartBps - drop) / BPS;
        if (p < bid) p = bid;
    }

    function _within(uint256 v, uint256 last) internal view returns (bool) {
        return v * BPS >= last * (BPS - maxChangeBps) && v * BPS <= last * (BPS + maxChangeBps);
    }
}
