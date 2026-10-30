// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {XLayerDefaults} from "./XLayerDefaults.sol";
import {XLayerDeploy, IV3PoolCardinality} from "./XLayerDeploy.sol";
import {UniswapV3TwapOracle} from "../src/oracle/UniswapV3TwapOracle.sol";
import {ITapeOutFactory, IBeacon} from "../src/interfaces/ITapeOut.sol";
import {IRig} from "../src/interfaces/IRig.sol";

interface ISafeView {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
}

/// @title X Layer 主网部署脚本（只接受链 ID 196）
/// @notice 用 script/xlayer-mainnet.sh 执行：simulate（默认，只模拟）/ deploy（需要你自己的 --account 或 --ledger，
///         手动输入 DEPLOY 才广播）/ check（部署后的只读核对）。部署逻辑在 script/XLayerDeploy.sol。
///
///         环境变量：
///         - FOUNDATION_SAFE、FEE_SAFE（必填）：X Layer 上的基金会 Safe 和手续费 Safe。没填就拒绝运行。
///         - OPERATOR（必填，非零）：运营地址（运营机器人的热钱包）。
///         - MINT_PRICE_WEI（可选，默认 0.006 OKB）：部署当天按 OKB 价格重算的 mintPrice（每颗晶体管，wei）。
///         - MAX_GAS_PRICE_WEI（可选，默认 0.1 gwei，X Layer 当前约 0.02 gwei）：余额检查按这个 gas 价格算。
///         - PENDING_FILE（默认 deployments/196.pending.json）：模拟阶段写出的地址文件；xlayer-mainnet.sh 广播后确认
///           每个合约都已上链，才改名为 deployments/196.json。
///
///         部署前自检（不通过就 revert）：每个外部地址都有代码；读出 deployFee 和电路信标当前的 implementation
///         （升级哨兵的基准）；BEM/WOKB 池的观测点（不足 1,800 时，部署的第一笔交易就是扩容）；30 分钟 TWAP 现在能否读出
///         （读不出时只打印警告：合约会暂停回购和回馈兑换，直到扩容后的观测点覆盖满 30 分钟）；两个 Safe 读得出
///         getThreshold / getOwners；部署者余额够用；运营地址非零。部署后核对所有预测地址。
contract DeployXLayerMainnet is Script {
    /// @dev 主网分叉实测（2026-10-27，区块 74,337,482）：十个合约（含 v2 四个单例）24,063,943 gas；扩容到 1,800 个观测点 40,037,997 gas（留余量）
    uint256 internal constant DEPLOY_GAS_ESTIMATE = 40_000_000;
    uint256 internal constant CARDINALITY_GAS_ESTIMATE = 45_000_000;

    function run() public virtual {
        require(block.chainid == 196, "DeployXLayerMainnet: only X Layer mainnet (chain id 196)");
        (, address deployer,) = vm.readCallers();
        XLayerDeploy.Settings memory s = settings(deployer);
        preflight(deployer, s);

        vm.startBroadcast();
        XLayerDeploy.Deployment memory d = XLayerDeploy.deployMainnet(deployer, s);
        vm.stopBroadcast();

        _log(d);
        _writePending(d);
        console2.log("");
        console2.log("NEXT STEPS:");
        console2.log("  1. bash script/xlayer-mainnet.sh check");
        console2.log("  2. genesis countdown has started: startGenesis() after 7 days or 10,000 transistors");
        console2.log("  3. buybacks and reward swaps stay paused until the 30-minute TWAP is readable");
    }

    function settings(address deployer) public view returns (XLayerDeploy.Settings memory s) {
        s.foundation = vm.envOr("FOUNDATION_SAFE", address(0));
        s.feeSafe = vm.envOr("FEE_SAFE", address(0));
        require(s.foundation != address(0), "set FOUNDATION_SAFE (X Layer foundation Safe; required)");
        require(s.feeSafe != address(0), "set FEE_SAFE (X Layer fee Safe; required)");
        s.operator = vm.envOr("OPERATOR", address(0));
        require(s.operator != address(0), "set OPERATOR (operator hot wallet address, non-zero)");
        s.mintPrice = vm.envOr("MINT_PRICE_WEI", XLayerDefaults.DEFAULT_MINT_PRICE);
        require(s.mintPrice > 0, "MINT_PRICE_WEI must be > 0");
        if (s.operator == deployer) {
            console2.log("WARNING: OPERATOR == deployer. Use a separate operator hot wallet for the bot.");
        }
        if (s.foundation == s.feeSafe) console2.log("WARNING: FOUNDATION_SAFE == FEE_SAFE");
    }

    function preflight(address deployer, XLayerDeploy.Settings memory s) public {
        XLayerDefaults.Mainnet memory m = XLayerDefaults.mainnet();
        console2.log("== preflight (X Layer mainnet, block", block.number, ")");
        console2.log("deployer", deployer);
        console2.log("operator", s.operator);
        _hasCode("TapeOut factory", m.tapeoutFactory);
        _hasCode("circuits beacon", m.circuitsBeacon);
        _hasCode("RIG", m.rig);
        _hasCode("BEM", m.bem);
        _hasCode("WOKB", m.wokb);
        _hasCode("Uniswap v3 factory", m.v3Factory);
        _hasCode("SwapRouter02", m.router);
        _hasCode("pool BEM/WOKB", m.pool);
        _hasCode("foundation Safe", s.foundation);
        _hasCode("fee Safe", s.feeSafe);

        uint256 fee = ITapeOutFactory(m.tapeoutFactory).deployFee();
        console2.log("createCPU deployFee (wei)", fee);
        console2.log("circuits beacon implementation (sentinel baseline)", IBeacon(m.circuitsBeacon).implementation());
        console2.log("RIG sealed (expected false; disclosed + monitored off-chain)", IRig(m.rig).isSealed());
        console2.log("mintPrice per transistor (wei)", s.mintPrice);
        console2.log(
            "  one pass = 5 x (mintPrice + protocol fee) + tapeout fee; protocol / tapeout fee are set by TapeOut"
        );

        bool raise = _pool(m.pool);
        _safe("foundation Safe", s.foundation);
        _safe("fee Safe", s.feeSafe);

        uint256 maxGasPrice = vm.envOr("MAX_GAS_PRICE_WEI", uint256(0.1 gwei));
        uint256 gasNeeded = DEPLOY_GAS_ESTIMATE + (raise ? CARDINALITY_GAS_ESTIMATE : 0);
        uint256 need = fee + gasNeeded * maxGasPrice;
        console2.log("deployer balance (wei)", deployer.balance, "needed (wei)", need);
        require(deployer.balance >= need, "deployer balance too low (deployFee + gas at MAX_GAS_PRICE_WEI)");

        address[12] memory p = XLayerDeploy.predict(deployer, raise ? 1 : 0);
        console2.log("predicted UniswapV3TwapOracle", p[0]);
        console2.log("predicted RigMachineSource", p[1]);
        console2.log("predicted DrandEvmnetAdapter", p[2]);
        console2.log("predicted GenesisSplitter", p[3]);
        console2.log("predicted XHub (splitter.boardFactory / adapter.registry)", p[4]);
        console2.log("predicted XMonthFactory", p[5]);
        console2.log("predicted XMonthPositions", p[6]);
        console2.log("predicted XMonthExitGovernor", p[7]);
        console2.log("predicted XMarketPriceFeed", p[8]);
        console2.log("predicted XMonthMachineSales", p[9]);
        console2.log("predicted XPositionExchange", p[10]);
        console2.log("predicted XRigMarket", p[11]);
        console2.log("== preflight ok");
    }

    /// @return raise 是否需要先扩容观测点
    function _pool(address pool) internal returns (bool raise) {
        (,, uint16 index, uint16 card, uint16 next,,) = IV3PoolCardinality(pool).slot0();
        console2.log("pool BEM/WOKB observation index / cardinality / next", index, card, next);
        raise = next < XLayerDefaults.OBSERVATION_CARDINALITY;
        if (raise) {
            console2.log(
                "  first transaction: increaseObservationCardinalityNext", XLayerDefaults.OBSERVATION_CARDINALITY
            );
        }
        // 本地试部署一个预言机（不广播），看 30 分钟 TWAP 现在能否读出
        UniswapV3TwapOracle probe = new UniswapV3TwapOracle(
            pool, XLayerDefaults.mainnet().wokb, XLayerDefaults.mainnet().bem, XLayerDefaults.TWAP_WINDOW
        );
        if (probe.twapAvailable()) {
            console2.log("TWAP 30m: 1 OKB -> BEM (8 decimals)", probe.quoteBemOut(1 ether));
        } else {
            console2.log("WARNING: 30-minute TWAP not readable yet (too few observations).");
            console2.log("         Buybacks / reward swaps stay paused until the new observations cover 30 minutes.");
        }
    }

    function _hasCode(string memory name, address a) internal view {
        require(a.code.length > 0, string.concat("no code at ", name));
    }

    function _safe(string memory name, address safe) internal view {
        uint256 threshold = ISafeView(safe).getThreshold();
        address[] memory owners = ISafeView(safe).getOwners();
        require(threshold > 0 && owners.length >= threshold, string.concat("bad Safe ", name));
        console2.log(string.concat(name, " ", vm.toString(threshold), " of ", vm.toString(owners.length)), safe);
        for (uint256 i = 0; i < owners.length; i++) {
            console2.log("  owner", owners[i]);
        }
    }

    function _log(XLayerDeploy.Deployment memory d) internal view {
        console2.log("== deployed");
        if (d.cardinalityRaised) {
            console2.log("pool observation cardinality raised to", XLayerDefaults.OBSERVATION_CARDINALITY);
        }
        console2.log("UniswapV3TwapOracle", address(d.oracle));
        console2.log("RigMachineSource", address(d.machineSource));
        console2.log("DrandEvmnetAdapter", address(d.adapter));
        console2.log("GenesisSplitter", address(d.splitter));
        console2.log("XHub", address(d.hub));
        console2.log("XMonthFactory", address(d.monthFactory));
        console2.log("XMonthBoard implementation", d.monthFactory.boardImplementation());
        console2.log("XMonthPositions", address(d.v2.positions));
        console2.log("XMonthExitGovernor", address(d.v2.governor));
        console2.log("XMarketPriceFeed", address(d.v2.priceFeed));
        console2.log("XMonthMachineSales", address(d.v2.sales));
        console2.log("XPositionExchange", address(d.v2.exchange));
        console2.log("XRigMarket", address(d.v2.market));
        console2.log("Genesis transistors", address(d.hub.transistors()));
        console2.log("Genesis circuits (passes)", d.hub.passCircuits());
        console2.log("operator", d.hub.operator());
        console2.log("genesis possible at (unix)", d.splitter.mintStart() + d.hub.genesisDelay());
    }

    function _writePending(XLayerDeploy.Deployment memory d) internal {
        XLayerDefaults.Mainnet memory m = XLayerDefaults.mainnet();
        string memory o = "xlayer";
        vm.serializeAddress(o, "bem", m.bem);
        vm.serializeAddress(o, "hub", address(d.hub));
        vm.serializeAddress(o, "monthFactory", address(d.monthFactory));
        vm.serializeAddress(o, "splitter", address(d.splitter));
        vm.serializeAddress(o, "transistors", address(d.hub.transistors()));
        vm.serializeAddress(o, "passCircuits", d.hub.passCircuits());
        vm.serializeAddress(o, "rig", m.rig);
        vm.serializeAddress(o, "machineSource", address(d.machineSource));
        vm.serializeAddress(o, "randomSource", address(d.adapter));
        vm.serializeAddress(o, "drandAdapter", address(d.adapter));
        vm.serializeAddress(o, "router", m.router);
        vm.serializeAddress(o, "pool", m.pool);
        vm.serializeAddress(o, "oracle", address(d.oracle));
        vm.serializeAddress(o, "wrappedNative", m.wokb);
        vm.serializeAddress(o, "tapeout", m.tapeoutFactory);
        vm.serializeAddress(o, "operator", d.hub.operator());
        vm.serializeAddress(o, "positions", address(d.v2.positions));
        vm.serializeAddress(o, "governor", address(d.v2.governor));
        vm.serializeAddress(o, "priceFeed", address(d.v2.priceFeed));
        vm.serializeAddress(o, "bscPriceFeed", XLayerDefaults.BSC_PRICE_FEED);
        vm.serializeAddress(o, "sales", address(d.v2.sales));
        vm.serializeAddress(o, "exchange", address(d.v2.exchange));
        vm.serializeAddress(o, "market", address(d.v2.market));
        vm.serializeBool(o, "mockRandom", false);
        vm.serializeUint(o, "timeDivisor", 1);
        string memory json = vm.serializeUint(o, "fromBlock", block.number);
        string memory path = vm.envOr("PENDING_FILE", string("deployments/196.pending.json"));
        vm.writeJson(json, path);
        console2.log("addresses written to", path, "(renamed to 196.json after the on-chain check)");
    }
}
