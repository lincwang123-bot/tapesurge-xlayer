// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {XMonthBoard} from "../src/XMonthBoard.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {XHub} from "../src/XHub.sol";
import {XMonthFactory} from "../src/XMonthFactory.sol";
import {XMonthPositions} from "../src/month/XMonthPositions.sol";
import {XMonthExitGovernor} from "../src/month/XMonthExitGovernor.sol";
import {XMonthMachineSales} from "../src/month/XMonthMachineSales.sol";
import {XPositionExchange} from "../src/month/XPositionExchange.sol";
import {XRigMarket} from "../src/market/XRigMarket.sol";
import {UniswapV3TwapOracle} from "../src/oracle/UniswapV3TwapOracle.sol";
import {XMarketPriceFeed} from "../src/oracle/XMarketPriceFeed.sol";
import {RigMachineSource} from "../src/machines/RigMachineSource.sol";
import {DrandEvmnetAdapter} from "../src/random/DrandEvmnetAdapter.sol";
import {ITapeOutFactory} from "../src/interfaces/ITapeOut.sol";
import {XLayerDefaults} from "./XLayerDefaults.sol";

interface IV3PoolCardinality {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function increaseObservationCardinalityNext(uint16 next) external;
}

/// @title X Layer 主网部署逻辑（script/DeployXLayerMainnet.s.sol 和分叉测试共用，保证演练测的就是上线的那套参数）
/// @notice 部署顺序：
///           （如有需要）先调用 BEM/WOKB 池的 increaseObservationCardinalityNext(1800)（任何人可调；占用一个 nonce，
///           所以下面的预测地址从这笔交易之后算起）
///           n     UniswapV3TwapOracle（BEM/WOKB 1% 池，30 分钟）
///           n + 1 RigMachineSource（真实 RIG，算力 10–300，3 天内同步）
///           n + 2 DrandEvmnetAdapter（registry = 预测的 XHub，锁定 10 分钟后的轮次，参与者 3 天后可代交）
///           n + 3 GenesisSplitter（boardFactory = 预测的 XHub；构造时付 deployFee 调用 createCPU）
///           n + 4 XHub（monthFactory = 预测的 XMonthFactory）
///           n + 5 XMonthFactory（月局实现；配置里的四个单例地址是预测的 n + 6 / n + 7 / n + 9 / n + 11）
///           n + 6 XMonthPositions（持仓凭证）
///           n + 7 XMonthExitGovernor（集体清算；SALES = 预测的 n + 9）
///           n + 8 XMarketPriceFeed（BSC 矿机行情转报，hub = XHub）
///           n + 9 XMonthMachineSales（卖矿定价，PRICE_FEED = n + 8）
///           n + 10 XPositionExchange（持仓盘口）
///           n + 11 XRigMarket（RIG 矿机市场，手续费 XLayerDefaults.MARKET_FEE_BPS）
library XLayerDeploy {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Settings {
        address operator; // 运营地址（主网必须非零）
        address foundation; // X Layer 上的基金会 Safe（必填）
        address feeSafe; // X Layer 上的手续费 Safe（必填；也是唯一能更换运营地址的地址）
        uint256 mintPrice; // 部署当天按 OKB 价格重算（默认 XLayerDefaults.DEFAULT_MINT_PRICE）
    }

    struct Deployment {
        UniswapV3TwapOracle oracle;
        RigMachineSource machineSource;
        DrandEvmnetAdapter adapter;
        GenesisSplitter splitter;
        XHub hub;
        XMonthFactory monthFactory;
        MonthV2 v2;
        bool cardinalityRaised;
    }

    /// @notice v2 月局的六个单例
    struct MonthV2 {
        XMonthPositions positions;
        XMonthExitGovernor governor;
        XMarketPriceFeed priceFeed;
        XMonthMachineSales sales;
        XPositionExchange exchange;
        XRigMarket market;
    }

    /// @notice 月局工厂（deployer 的第 factoryNonce 笔创建）之后、写进月局配置的四个单例：持仓凭证（+1）、清算治理（+2）、
    ///         卖矿（+4）、RIG 矿机市场（+6）；+3 是报价转报合约，+5 是持仓盘口
    function predictMonthV2(address deployer, uint256 factoryNonce)
        internal
        pure
        returns (address positions, address governor, address sales, address market)
    {
        positions = vm.computeCreateAddress(deployer, factoryNonce + 1);
        governor = vm.computeCreateAddress(deployer, factoryNonce + 2);
        sales = vm.computeCreateAddress(deployer, factoryNonce + 4);
        market = vm.computeCreateAddress(deployer, factoryNonce + 6);
    }

    /// @notice 紧接着月局工厂部署六个单例（持仓凭证 → 清算治理 → 报价转报 → 卖矿 → 持仓盘口 → RIG 矿机市场），
    ///         并核对和月局配置里的预测地址一致
    function deployMonthV2(address deployer, XMonthFactory monthFactory, XLayerDefaults.V2Timing memory t)
        internal
        returns (MonthV2 memory v)
    {
        address mf = address(monthFactory);
        (address pPositions, address pGovernor, address pSales, address pMarket) =
            predictMonthV2(deployer, vm.getNonce(deployer) - 1);
        XMonthBoard.Config memory c = monthFactory.boardConfig();
        require(
            c.positions == pPositions && c.governor == pGovernor && c.sales == pSales && c.market == pMarket,
            "v2 singleton prediction"
        );
        v.positions = new XMonthPositions(mf);
        v.governor = new XMonthExitGovernor(
            mf, pSales, t.minSettleAge, t.votePeriod, t.executionDelay, t.executionWindow, t.failCooldown, t.repriceCooldown
        );
        v.priceFeed = new XMarketPriceFeed(
            c.hub,
            XLayerDefaults.FEED_MAX_CHANGE_BPS,
            XLayerDefaults.FEED_MIN_INTERVAL,
            XLayerDefaults.FEED_MAX_STALENESS,
            XLayerDefaults.FEED_ABANDON_AFTER,
            XLayerDefaults.FEED_SELL_START_BPS,
            XLayerDefaults.FEED_SELL_STEP_BPS,
            t.sellStepInterval
        );
        v.sales = new XMonthMachineSales(
            c.bem,
            mf,
            c.hub,
            address(v.governor),
            t.operatorGrace,
            t.planDecay,
            address(v.priceFeed),
            t.saleSyncAge
        );
        v.exchange = new XPositionExchange(c.bem, address(v.positions), mf);
        v.market = new XRigMarket(mf, XLayerDefaults.MARKET_FEE_BPS);
        require(
            address(v.positions) == pPositions && address(v.governor) == pGovernor && address(v.sales) == pSales
                && address(v.market) == pMarket,
            "v2 singleton addresses"
        );
    }

    /// @notice 扩容之后、前十二个合约的预测地址（deployer 的当前 nonce 起算，顺序见上）
    function predict(address deployer, uint256 skip) internal view returns (address[12] memory a) {
        uint256 n = vm.getNonce(deployer) + skip;
        for (uint256 i = 0; i < 12; i++) {
            a[i] = vm.computeCreateAddress(deployer, n + i);
        }
    }

    function needsCardinality() internal view returns (bool) {
        (,,,, uint16 next,,) = IV3PoolCardinality(XLayerDefaults.mainnet().pool).slot0();
        return next < XLayerDefaults.OBSERVATION_CARDINALITY;
    }

    function deployMainnet(address deployer, Settings memory s) internal returns (Deployment memory d) {
        XLayerDefaults.Mainnet memory m = XLayerDefaults.mainnet();
        if (needsCardinality()) {
            IV3PoolCardinality(m.pool).increaseObservationCardinalityNext(XLayerDefaults.OBSERVATION_CARDINALITY);
            d.cardinalityRaised = true;
        }
        address[12] memory p = predict(deployer, 0);

        d.oracle = new UniswapV3TwapOracle(m.pool, m.wokb, m.bem, XLayerDefaults.TWAP_WINDOW);
        d.machineSource = new RigMachineSource(
            m.rig,
            m.bscMachineCircuits,
            XLayerDefaults.RIG_MIN_POWER,
            XLayerDefaults.RIG_MAX_POWER,
            XLayerDefaults.RIG_MAX_SYNC_AGE
        );
        d.adapter = new DrandEvmnetAdapter(p[4], XLayerDefaults.DRAND_MIN_DELAY, XLayerDefaults.DRAND_OPERATOR_GRACE);

        XLayerDefaults.Addresses memory a = XLayerDefaults.Addresses({
            tapeoutFactory: m.tapeoutFactory,
            passBeacon: m.circuitsBeacon,
            bem: m.bem,
            machineSource: address(d.machineSource),
            randomSource: address(d.adapter),
            wrappedNative: m.wokb,
            router: m.router,
            oracle: address(d.oracle),
            foundation: s.foundation,
            feeSafe: s.feeSafe,
            positions: p[6],
            sales: p[9],
            governor: p[7],
            market: p[11]
        });
        GenesisSplitter.Params memory sp = XLayerDefaults.splitterParams(a, s.mintPrice);
        sp.boardFactory = p[4];
        d.splitter = new GenesisSplitter{value: ITapeOutFactory(m.tapeoutFactory).deployFee()}(sp);
        d.hub = new XHub(
            XHub.Params({
                splitter: address(d.splitter),
                monthFactory: p[5],
                initialOperator: s.operator,
                genesisMintThreshold: XLayerDefaults.GENESIS_MINT_THRESHOLD,
                genesisDelay: XLayerDefaults.GENESIS_DELAY
            })
        );
        d.monthFactory = new XMonthFactory(address(d.hub), XLayerDefaults.monthParams(a));
        d.v2 = deployMonthV2(deployer, d.monthFactory, XLayerDefaults.v2Timing());

        require(address(d.oracle) == p[0], "oracle address prediction");
        require(address(d.adapter) == p[2], "adapter address prediction");
        require(address(d.splitter) == p[3], "splitter address prediction");
        require(address(d.hub) == p[4], "XHub address prediction");
        require(address(d.monthFactory) == p[5], "XMonthFactory address prediction");
        require(d.splitter.boardFactory() == address(d.hub), "splitter.boardFactory");
        require(address(d.adapter.registry()) == address(d.hub), "adapter.registry");
        require(d.hub.monthFactory() == address(d.monthFactory), "hub.monthFactory");
        require(d.hub.feeRecipient() == s.feeSafe, "hub fee Safe");
    }
}
