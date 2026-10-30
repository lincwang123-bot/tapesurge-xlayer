// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {XHub} from "../src/XHub.sol";
import {XMonthFactory} from "../src/XMonthFactory.sol";
import {UniswapV3TwapOracle} from "../src/oracle/UniswapV3TwapOracle.sol";
import {RigMachineSource} from "../src/machines/RigMachineSource.sol";
import {DrandEvmnetAdapter} from "../src/random/DrandEvmnetAdapter.sol";
import {MockBEM} from "../src/mocks/MockBEM.sol";
import {MockRig} from "../src/mocks/MockRig.sol";
import {MockTapeOutFactory} from "../src/mocks/MockTapeOut.sol";
import {MockWrappedNative, MockV3Pool, MockV3Factory, MockSwapRouter02} from "../src/mocks/MockSwap.sol";
import {XLayerDefaults} from "./XLayerDefaults.sol";
import {XLayerDeploy} from "./XLayerDeploy.sol";

/// @title X Layer 测试网部署脚本（链 ID 1952；本地演练 31337）
/// @notice X Layer 测试网上没有 TapeOut、RIG、BEM 和交易池，所以先部署一整套 mock，再部署 TapeSurge：
///         MockBEM、MockRig（RIG 凭证；`claim(ids)` 模拟在 BSC 金库上发起收取并立即到账）、MockTapeOutFactory
///         （费用 = X Layer 主网实测值 ÷ MOCK_FEE_DIVISOR）、MockWrappedNative（WOKB）、MockV3Pool（固定 tick = 主网
///         2026-10-21 的 216,768，1 OKB ≈ 3.86 BEM）、MockV3Factory、MockSwapRouter02（按略低于 TWAP 的固定汇率成交）。
///         **随机数用真实的 DrandEvmnetAdapter**（测试网有 BN254 预编译，2026-10-21 eth_call 验证过）；
///         预言机是真实的 UniswapV3TwapOracle（读 mock 池子）。
///
///         部署顺序：mock 环境 → 预言机 → RigMachineSource → DrandEvmnetAdapter（registry = 预测的 XHub）
///         → GenesisSplitter → XHub → XMonthFactory（后三个的地址按部署者 nonce 预先算好，互相核对）。
///
///         由 script/xlayer-testnet.sh 调用（运行时从 .env.xlayer-testnet 读部署私钥 XLAYER_TESTNET_DEPLOYER_PK，
///         脚本里用 vm.startBroadcast(私钥) 签名，命令行上不出现私钥，输出遮掉）。其他环境变量（都可省略）：
///         - TIME_DIVISOR（默认 720）：所有以天计的时长按同一比例缩短（48 = 1 天 → 30 分钟：月局招募 / 准备各 1.5 小时，
///           挖矿 15 小时）。随机数重发 / 停摆退出不低于 1 小时（主板构造要求）。drand 本身每 3 秒一轮，不缩短。
///         - MOCK_FEE_DIVISOR（默认 100）：mock 的 TapeOut 费用和 mintPrice 按主网缩小的比例（省测试 OKB）。
///         - GENESIS_DELAY（秒）：覆盖缩短后的开局等待时间；MINT_PRICE_WEI：直接指定 mintPrice。
///         - MOCK_YIELD_PER_POWER_DAY：MockRig 每单位算力每个真实日的产出（默认 = 主网约 1.65 BEM / 365 天 × TIME_DIVISOR，
///           缩短后的"一天"产出和主网一天相当）。
///         - FEE_SAFE / OPERATOR：默认是部署者；FOUNDATION 默认是由部署者派生的固定地址（v2 要求基金会和手续费地址不同）。
///         - WRITE_DEPLOYMENT=1：把地址写到 deployments/<链 ID>.json（场景脚本、运营机器人、dApp 读它）。
contract DeployXLayerTestnet is Script {
    uint256 internal constant DEFAULT_TIME_DIVISOR = 720;
    uint256 internal constant DEFAULT_FEE_DIVISOR = 100;
    /// @dev 主网 BEM/WOKB 池 2026-10-21 的 tick（token0 = BEM）。mock 池子里 BEM / WOKB 的地址大小关系可能相反，见 _tick()
    int24 internal constant MAINNET_TICK = 216_768;
    /// @dev 1 OKB ≈ 3.8585 BEM（TWAP 报价）；mock 路由按 99.3% 成交，在 2% 滑点以内
    uint256 internal constant ROUTER_BEM_PER_NATIVE = 383_150_000;
    /// @dev 主网单位产出约 1.65 BEM / 算力 / 365 天
    uint256 internal constant MAINNET_YIELD_PER_POWER_DAY = 165_000_000 / uint256(365);
    /// @dev mock RIG 记录里的"BSC 官方矿机电路"地址（RigMachineSource 只收这个电路合约的凭证）
    address internal constant MOCK_BSC_MACHINE_CIRCUITS = address(0xB5C0C1C1);

    MockBEM internal bem;
    MockRig internal rig;
    MockTapeOutFactory internal tapeout;
    MockWrappedNative internal wokb;
    MockV3Pool internal pool;
    MockV3Factory internal v3Factory;
    MockSwapRouter02 internal router;
    UniswapV3TwapOracle internal oracle;
    RigMachineSource internal source;
    DrandEvmnetAdapter internal adapter;
    GenesisSplitter internal splitter;
    XHub internal hub;
    XMonthFactory internal monthFactory;
    XLayerDeploy.MonthV2 internal v2;

    function run() public virtual {
        require(block.chainid == 1952 || block.chainid == 31337, "only X Layer testnet (1952) or local (31337)");
        // 部署私钥由 xlayer-testnet.sh 在运行时从 .env.xlayer-testnet 载入到环境变量；这里只用来签名，不打印
        uint256 key = vm.envUint("XLAYER_TESTNET_DEPLOYER_PK");
        address deployer = vm.addr(key);
        address expected = vm.envOr("EXPECT_DEPLOYER", address(0));
        require(expected == address(0) || deployer == expected, "deployer key does not match EXPECT_DEPLOYER");
        vm.startBroadcast(key);
        _deployMocks();
        _deploySystem(deployer);
        vm.stopBroadcast();
        _log(deployer);
        if (vm.envOr("WRITE_DEPLOYMENT", false)) _writeDeployment();
    }

    function _timeDivisor() internal view returns (uint256 d) {
        d = vm.envOr("TIME_DIVISOR", DEFAULT_TIME_DIVISOR);
        require(d >= 1, "TIME_DIVISOR must be >= 1");
    }

    function _feeDivisor() internal view returns (uint256 d) {
        d = vm.envOr("MOCK_FEE_DIVISOR", DEFAULT_FEE_DIVISOR);
        require(d >= 1, "MOCK_FEE_DIVISOR must be >= 1");
    }

    function _s(uint256 t) internal view returns (uint256) {
        uint256 r = t / _timeDivisor();
        return r == 0 ? 1 : r;
    }

    function _atLeastHour(uint256 t) internal pure returns (uint256) {
        return t < 1 hours ? 1 hours : t;
    }

    function _deployMocks() internal {
        bem = new MockBEM();
        rig = new MockRig(address(bem));
        rig.setYieldRate(vm.envOr("MOCK_YIELD_PER_POWER_DAY", MAINNET_YIELD_PER_POWER_DAY * _timeDivisor()));
        uint256 f = _feeDivisor();
        tapeout = new MockTapeOutFactory(0.0066 ether / f, 0.00066 ether / f, 0.0013 ether / f);
        wokb = new MockWrappedNative();
        pool = new MockV3Pool(address(wokb), address(bem), XLayerDefaults.POOL_FEE, 0);
        pool.setTick(_tick());
        v3Factory = new MockV3Factory();
        v3Factory.setPool(address(wokb), address(bem), XLayerDefaults.POOL_FEE, address(pool));
        router = new MockSwapRouter02(address(wokb), address(v3Factory), address(bem), ROUTER_BEM_PER_NATIVE);
    }

    /// @dev 让 mock 池子的价格和主网一致：主网 token0 = BEM；如果 mock 里 WOKB 地址更小（token0 = WOKB），tick 取反
    function _tick() internal view returns (int24) {
        return pool.token0() == address(bem) ? MAINNET_TICK : -MAINNET_TICK;
    }

    function _deploySystem(address deployer) internal {
        oracle = new UniswapV3TwapOracle(address(pool), address(wokb), address(bem), XLayerDefaults.TWAP_WINDOW);
        source = new RigMachineSource(
            address(rig),
            MOCK_BSC_MACHINE_CIRCUITS,
            XLayerDefaults.RIG_MIN_POWER,
            XLayerDefaults.RIG_MAX_POWER,
            _s(XLayerDefaults.RIG_MAX_SYNC_AGE)
        );
        uint256 n = vm.getNonce(deployer);
        address predictedHub = vm.computeCreateAddress(deployer, n + 2);
        address predictedMonth = vm.computeCreateAddress(deployer, n + 3);
        adapter = new DrandEvmnetAdapter(
            predictedHub, XLayerDefaults.DRAND_MIN_DELAY, _s(XLayerDefaults.DRAND_OPERATOR_GRACE)
        );

        XLayerDefaults.Addresses memory a = XLayerDefaults.Addresses({
            tapeoutFactory: address(tapeout),
            passBeacon: address(tapeout.circuitsBeacon()),
            bem: address(bem),
            machineSource: address(source),
            randomSource: address(adapter),
            wrappedNative: address(wokb),
            router: address(router),
            oracle: address(oracle),
            // v2：基金会和手续费地址必须不同（主板构造时检查）；测试网默认用由部署者派生的一个固定地址当基金会
            foundation: vm.envOr("FOUNDATION", address(uint160(uint256(keccak256(abi.encode("tapesurge-xlayer-testnet-foundation", deployer)))))),
            feeSafe: vm.envOr("FEE_SAFE", deployer),
            positions: address(0),
            sales: address(0),
            governor: address(0),
            market: address(0)
        });
        GenesisSplitter.Params memory sp = XLayerDefaults.splitterParams(
            a, vm.envOr("MINT_PRICE_WEI", XLayerDefaults.DEFAULT_MINT_PRICE / _feeDivisor())
        );
        sp.cpuName = "TapeSurge Genesis (X Layer testnet)";
        sp.minSwapInterval = _s(sp.minSwapInterval);
        sp.boardFactory = predictedHub;
        splitter = new GenesisSplitter{value: tapeout.deployFee()}(sp);

        hub = new XHub(
            XHub.Params({
                splitter: address(splitter),
                monthFactory: predictedMonth,
                initialOperator: vm.envOr("OPERATOR", deployer),
                genesisMintThreshold: XLayerDefaults.GENESIS_MINT_THRESHOLD,
                genesisDelay: vm.envOr("GENESIS_DELAY", _s(XLayerDefaults.GENESIS_DELAY))
            })
        );
        XMonthFactory.Params memory mp = XLayerDefaults.monthParams(a);
        _applyFast(mp);
        (mp.board.positions, mp.board.governor, mp.board.sales, mp.board.market) =
            XLayerDeploy.predictMonthV2(deployer, vm.getNonce(deployer));
        monthFactory = new XMonthFactory(address(hub), mp);
        require(address(hub) == predictedHub && address(monthFactory) == predictedMonth, "address prediction");
        v2 = XLayerDeploy.deployMonthV2(deployer, monthFactory, _fastTiming());
        require(address(adapter.registry()) == address(hub), "adapter.registry");
    }

    function _applyFast(XMonthFactory.Params memory mp) internal view {
        mp.board.recruitDuration = _s(mp.board.recruitDuration);
        mp.board.buyStepInterval = _s(mp.board.buyStepInterval);
        mp.board.prepDuration = _s(mp.board.prepDuration);
        mp.board.miningDuration = _s(mp.board.miningDuration);
        mp.board.vrfRetryDelay = _atLeastHour(_s(mp.board.vrfRetryDelay));
        mp.board.vrfSafeExitDelay = _atLeastHour(_s(mp.board.vrfSafeExitDelay));
        mp.board.operatorGrace = _s(mp.board.operatorGrace);
        mp.board.claimWindow = _s(mp.board.claimWindow);
        mp.board.sentinelResumeDelay = _s(mp.board.sentinelResumeDelay);
        mp.targets.fastFillWindow = _s(mp.targets.fastFillWindow);
    }

    /// @dev v2 单例的时长同样按 TIME_DIVISOR 缩短（清算投票等至少 1 小时，方便在测试网上手动操作）
    function _fastTiming() internal view returns (XLayerDefaults.V2Timing memory t) {
        t = XLayerDefaults.v2Timing();
        t.operatorGrace = _s(t.operatorGrace);
        t.planDecay = _atLeastHour(_s(t.planDecay));
        t.sellStepInterval = _s(t.sellStepInterval);
        t.minSettleAge = _s(t.minSettleAge);
        t.votePeriod = _atLeastHour(_s(t.votePeriod));
        t.executionDelay = _s(t.executionDelay);
        t.executionWindow = _atLeastHour(_s(t.executionWindow));
        t.failCooldown = _s(t.failCooldown);
        t.repriceCooldown = _s(t.repriceCooldown);
        t.saleSyncAge = _atLeastHour(_s(t.saleSyncAge));
    }

    function _writeDeployment() internal {
        string memory o = "deployment";
        vm.serializeAddress(o, "bem", address(bem));
        vm.serializeAddress(o, "rig", address(rig));
        vm.serializeAddress(o, "machineSource", address(source));
        vm.serializeAddress(o, "mockMachineCircuits", MOCK_BSC_MACHINE_CIRCUITS);
        vm.serializeAddress(o, "tapeout", address(tapeout));
        vm.serializeAddress(o, "wrappedNative", address(wokb));
        vm.serializeAddress(o, "pool", address(pool));
        vm.serializeAddress(o, "router", address(router));
        vm.serializeAddress(o, "oracle", address(oracle));
        vm.serializeAddress(o, "randomSource", address(adapter));
        vm.serializeAddress(o, "drandAdapter", address(adapter));
        vm.serializeAddress(o, "hub", address(hub));
        vm.serializeAddress(o, "monthFactory", address(monthFactory));
        vm.serializeAddress(o, "splitter", address(splitter));
        vm.serializeAddress(o, "transistors", address(hub.transistors()));
        vm.serializeAddress(o, "passCircuits", hub.passCircuits());
        vm.serializeAddress(o, "operator", hub.operator());
        vm.serializeAddress(o, "positions", address(v2.positions));
        vm.serializeAddress(o, "governor", address(v2.governor));
        vm.serializeAddress(o, "priceFeed", address(v2.priceFeed));
        vm.serializeAddress(o, "bscPriceFeed", XLayerDefaults.BSC_PRICE_FEED);
        vm.serializeAddress(o, "sales", address(v2.sales));
        vm.serializeAddress(o, "exchange", address(v2.exchange));
        vm.serializeAddress(o, "market", address(v2.market));
        vm.serializeBool(o, "mockRandom", false);
        vm.serializeUint(o, "feeDivisor", _feeDivisor());
        vm.serializeUint(o, "timeDivisor", _timeDivisor());
        string memory json = vm.serializeUint(o, "fromBlock", block.number);
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console2.log("deployment written to", path);
    }

    function _log(address deployer) internal view {
        console2.log("deployer", deployer);
        console2.log("MockBEM", address(bem));
        console2.log("MockRig", address(rig));
        console2.log("MockTapeOutFactory", address(tapeout));
        console2.log("MockWrappedNative (WOKB)", address(wokb));
        console2.log("MockV3Pool (BEM/WOKB)", address(pool));
        console2.log("MockSwapRouter02", address(router));
        console2.log("UniswapV3TwapOracle", address(oracle));
        console2.log("RigMachineSource", address(source));
        console2.log("DrandEvmnetAdapter", address(adapter));
        console2.log("GenesisSplitter", address(splitter));
        console2.log("XHub", address(hub));
        console2.log("XMonthFactory", address(monthFactory));
        console2.log("XMonthBoard implementation", monthFactory.boardImplementation());
        console2.log("XMonthPositions", address(v2.positions));
        console2.log("XMonthExitGovernor", address(v2.governor));
        console2.log("XMarketPriceFeed (BSC bid/ask relay)", address(v2.priceFeed));
        console2.log("XMonthMachineSales", address(v2.sales));
        console2.log("XPositionExchange", address(v2.exchange));
        console2.log("XRigMarket", address(v2.market));
        console2.log("operator", hub.operator());
        console2.log("time divisor / fee divisor", _timeDivisor(), _feeDivisor());
    }
}
