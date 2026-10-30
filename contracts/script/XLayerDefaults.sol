// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {XMonthBoard} from "../src/XMonthBoard.sol";
import {XMonthFactory} from "../src/XMonthFactory.sol";

/// @title TapeSurge X Layer 默认部署参数（主网部署脚本、测试网部署脚本、分叉测试共用这一份）
/// @notice 规则和 BSC 版 v2.0-audit.6 相同（TapeSurgeDefaults，V2-PORT.md）；只有链相关的参数不同：OKB 计价的 mintPrice、Uniswap v3（Oku）兑换、
///         drand 随机数、RIG 矿机来源。X Layer 的基金会 Safe 和手续费 Safe 还没有，部署脚本要求必须显式传入。
///         通行证和铸造收入按 X Layer 自己的规则（2026-10-28 项目方决定，白皮书第 7 节的分账只适用于 BSC 版）：
///         晶体管上限 6,666 颗（1,333 张通行证）；铸造收入 100% 给手续费 Safe（项目方运营钱包），不回购、不进回馈桶。
library XLayerDefaults {
    uint256 internal constant BEM_1 = 1e8; // BEM 8 位小数

    // ---------------- 创世通行证和分账（M5）----------------
    /// @notice 默认 mintPrice：0.006 OKB / 颗（按 OKB ≈ 114.87 美元，一张通行证约 3.97 U）。部署当天按 OKB 价格重算，
    ///         通过环境变量 MINT_PRICE_WEI 传入：mintPrice = (4 ÷ OKB 价格 − 0.0046) ÷ 5（见 README）。
    uint256 internal constant DEFAULT_MINT_PRICE = 0.006 ether;
    uint256 internal constant TRANSISTOR_SUPPLY = 6_666; // 最多 1,333 张通行证（余 1 颗）；BSC 版是 66,666
    bytes32 internal constant PASS_NETLIST_HASH = 0xfffa29f1e30fa6438ba0e6ebd40ef157b53d0eff3f21cc4bc46942e27cb32ca0;

    // ---------------- 回购 / 回馈兑换（M3）----------------
    // X Layer 默认分账不回购、没有回馈桶（splitterParams），这些参数只用于分账合约构造时的池子核对，实际不会兑换。
    uint24 internal constant POOL_FEE = 10_000; // BEM/WOKB 1% 池
    uint32 internal constant TWAP_WINDOW = 30 minutes;
    /// @notice 部署前把池子的观测点扩到 1,800 个（30 分钟 / 约 1 秒一块），保证 30 分钟内每块都有成交也能读出 TWAP
    uint16 internal constant OBSERVATION_CARDINALITY = 1_800;
    uint256 internal constant MAX_SWAP_PER_CALL = 1 ether; // 单次最多 1 OKB
    uint256 internal constant MIN_SWAP_INTERVAL = 1 hours;
    uint256 internal constant MAX_SLIPPAGE_BPS = 200; // 最低成交量 = TWAP 的 98%（含 1% 池费）

    // ---------------- 随机数（M2）和矿机来源（M1）----------------
    /// @notice 请求时锁定至少 10 分钟之后的 drand 轮次。锁定按链上时间算：X Layer（OP Stack）停机后追块时，
    ///         区块时间会落后于真实时间，延迟太短时锁定的那一轮可能已经公开，调用 drawPrizes 的人就能先算出结果、挑区块调用。
    ///         运营机器人在链上时间落后真实时间超过 1 分钟时不发 drawPrizes / retryDraw。
    uint256 internal constant DRAND_MIN_DELAY = 10 minutes;
    uint256 internal constant DRAND_OPERATOR_GRACE = 3 days; // 这一轮产生满 3 天后参与者可以代交
    uint256 internal constant RIG_MIN_POWER = 10;
    uint256 internal constant RIG_MAX_POWER = 300;
    uint256 internal constant RIG_MAX_SYNC_AGE = 3 days;

    // ---------------- v2 月局：卖矿、持仓、集体清算（参数同 BSC 版 TapeSurgeDefaults）----------------
    uint256 internal constant PREMIUM_FEE_BPS = 1_000; // 卖矿溢价分成 10%
    /// @notice BSC 矿机行情转报（XMarketPriceFeed）：参数和 BSC 主网 MarketPriceFeed 相同（2026-10-27 链上只读核对），
    ///         测试网也不缩短（机器人按 BSC 的真实节奏转报）。用途同 BSC：收购价上限 = min(卖一, 一年产出)、结算卖价公式、
    ///         清算计划价不低于买一 × 算力 × 95%；报价无效时暂停收购和卖出（V2-PORT.md 第 3 节）。
    address internal constant BSC_PRICE_FEED = 0x5479E1ca5EA5052d3EB699BF9C738Ac358FC3465; // 转报来源（BSC 主网）
    uint256 internal constant FEED_MAX_CHANGE_BPS = 500; // 每次最多变动 5%
    uint256 internal constant FEED_MIN_INTERVAL = 50 minutes;
    uint256 internal constant FEED_MAX_STALENESS = 3 hours;
    uint256 internal constant FEED_ABANDON_AFTER = 7 days;
    /// @notice 卖价 = max(买一, 卖一 × (99% − 0.5% × 结算开始后整 6 小时数))，同 BSC TapeSurgeDefaults（2026-10-28 对齐 BSC）
    uint256 internal constant FEED_SELL_START_BPS = 9_900;
    uint256 internal constant FEED_SELL_STEP_BPS = 50;

    /// @notice RIG 矿机市场（XRigMarket）的手续费：0（2026-10-29 项目方决定；合约允许部署时设到 1%，付给手续费 Safe）
    uint256 internal constant MARKET_FEE_BPS = 0;

    /// @notice v2 单例用到的时长（测试网按 TIME_DIVISOR 缩短）
    struct V2Timing {
        uint256 operatorGrace; // 3 天后持有人兜底（交接、分批推送）
        uint256 planDecay; // 清算计划 7 天从起价降到底价
        uint256 sellStepInterval; // 卖价每 6 小时降卖一的 0.5%（XMarketPriceFeed.sellStepInterval）
        uint256 minSettleAge; // 结算满 7 天才能开启清算投票
        uint256 votePeriod; // 24 小时
        uint256 executionDelay; // 24 小时
        uint256 executionWindow; // 48 小时
        uint256 failCooldown; // 14 天
        uint256 repriceCooldown; // 7 天
        uint256 saleSyncAge; // 购买 / 交接时 RIG 要在 1 天内同步过
    }

    function v2Timing() internal pure returns (V2Timing memory t) {
        t.operatorGrace = 3 days;
        t.planDecay = 7 days;
        t.sellStepInterval = 6 hours;
        t.minSettleAge = 7 days;
        t.votePeriod = 24 hours;
        t.executionDelay = 24 hours;
        t.executionWindow = 48 hours;
        t.failCooldown = 14 days;
        t.repriceCooldown = 7 days;
        t.saleSyncAge = 1 days;
    }

    // ---------------- 开局 ----------------
    uint256 internal constant GENESIS_MINT_THRESHOLD = 1_000; // 上限 6,666 的约 15%（BSC 是 66,666 里的 10,000）；不到也可以 7 天后开局
    uint256 internal constant GENESIS_DELAY = 7 days;

    /// @notice X Layer 主网地址（2026-10-21 链上只读核实）
    struct Mainnet {
        address tapeoutFactory; // TapeOut 处理器工厂（createCPU）
        address circuitsBeacon; // 电路合约信标（创世通行证所在，升级哨兵监控它）
        address rig; // RIG 矿机凭证（UUPS 代理）
        address bscMachineCircuits; // RIG 记录里原矿机所在的 BSC 官方矿机电路合约
        address bem; // 跨链 BEM（LayerZero OFT，8 位小数）
        address wokb;
        address v3Factory; // Uniswap v3（Oku）工厂
        address router; // SwapRouter02
        address pool; // BEM/WOKB 1% 池
    }

    function mainnet() internal pure returns (Mainnet memory m) {
        m.tapeoutFactory = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
        m.circuitsBeacon = 0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C;
        m.rig = 0x9cfc959cd42B2e1d39a0d850c528210E818AE520;
        m.bscMachineCircuits = 0xb1024b89886B9a34Aa4ff5F31C411D708b20a14C;
        m.bem = 0x60e62Efa9405d6873C5deaBD4E6CC91c25363952;
        m.wokb = 0xe538905cf8410324e03A5A23C1c177a474D59b2b;
        m.v3Factory = 0x4B2ab38DBF28D31D467aA8993f6c2585981D6804;
        m.router = 0x4f0C28f5926AFDA16bf2506D5D9e57Ea190f9bcA;
        m.pool = 0x2CcF8aa17F5DF9Fb5D51C9de12135a913fF29f7A;
    }

    /// @notice 一次部署用到的外部地址（主网用真实合约，测试网用 mock）
    struct Addresses {
        address tapeoutFactory;
        address passBeacon;
        address bem;
        address machineSource;
        address randomSource;
        address wrappedNative;
        address router;
        address oracle;
        address foundation;
        address feeSafe;
        // v2 单例（在月局工厂之后部署，地址由部署方预测填入）
        address positions;
        address sales;
        address governor;
        address market;
    }

    /// @notice 分账合约参数（boardFactory = 预测的 XHub 地址，由部署方填入）
    function splitterParams(Addresses memory a, uint256 mintPrice)
        internal
        pure
        returns (GenesisSplitter.Params memory sp)
    {
        sp.tapeoutFactory = a.tapeoutFactory;
        sp.cpuName = "TapeSurge Genesis (X Layer)";
        sp.cpuSymbol = "SURGE";
        sp.cpuStory = "5 transistors, one half adder: your pass to the board.";
        sp.transistorSupply = TRANSISTOR_SUPPLY;
        sp.mintPrice = mintPrice;
        sp.foundation = a.foundation;
        sp.project = a.feeSafe;
        // X Layer：铸造收入 100% 给手续费 Safe（项目方运营钱包）。distribute() 任何人可调，从晶体管合约取出后
        // 同一笔交易里全部转出，分账合约不留钱；手续费 Safe 拒收时记账，之后 withdrawOwed 再转。
        sp.buybackBps = 0;
        sp.projectBps = 10_000;
        sp.foundationBps = 0;
        sp.bucketBps = [uint256(0), 0, 0, 0, 0];
        sp.bem = a.bem;
        sp.wrappedNative = a.wrappedNative;
        sp.router = a.router;
        sp.poolFee = POOL_FEE;
        sp.oracle = a.oracle;
        sp.maxSwapPerCall = MAX_SWAP_PER_CALL;
        sp.minSwapInterval = MIN_SWAP_INTERVAL;
        sp.maxSlippageBps = MAX_SLIPPAGE_BPS;
    }

    /// @notice 月局参数（规则同 BSC 版 TapeSurgeDefaults.monthParams；矿机资格由 machineSource 判断）
    function monthParams(Addresses memory a) internal pure returns (XMonthFactory.Params memory p) {
        XMonthBoard.Config memory c;
        c.bem = a.bem;
        c.machineSource = a.machineSource;
        c.passBeacon = a.passBeacon;
        c.passNetlistHash = PASS_NETLIST_HASH;
        c.foundation = a.foundation;
        c.feeRecipient = a.feeSafe;
        c.randomSource = a.randomSource;
        c.positions = a.positions;
        c.sales = a.sales;
        c.governor = a.governor;
        c.market = a.market;
        c.entryFeeBps = 100; // 1%
        c.premiumFeeBps = PREMIUM_FEE_BPS;
        c.recruitDuration = 3 days;
        c.minStartBps = 6_000;
        c.buyStartBps = 5_000; // 收购价从上限的 50% 起，每 6 小时 + 5%
        c.buyStepBps = 500;
        c.buyStepInterval = 6 hours;
        c.buyCapDays = 365;
        c.buyMaxPrice = 165_000_000; // 部署上限 1.65 BEM / 算力（第一块月局只用它）
        c.prepDuration = 3 days;
        c.minMachineWeight = RIG_MIN_POWER;
        c.maxMachineWeight = RIG_MAX_POWER;
        c.maxMachines = 100;
        c.miningDuration = 30 days;
        c.vrfRetryDelay = 1 days; // 字段名沿用 BSC 版；X Layer 上是 drand 请求的重发间隔（重发锁定同一轮次）
        c.vrfSafeExitDelay = 7 days;
        c.operatorGrace = 3 days;
        c.claimWindow = 365 days;
        c.sentinelResumeDelay = 30 days;
        p.board = c;
        p.targets = XMonthFactory.TargetRules({
            initialTarget: 100 * BEM_1,
            minTarget: 100 * BEM_1,
            maxTarget: 1_000 * BEM_1,
            rounding: BEM_1,
            minStakeBps: 20,
            maxStakeBps: 400,
            fastFillWindow: 1 days,
            growBps: 12_500,
            partialBps: 7_500,
            failBps: 5_000
        });
    }
}
