// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {XLayerDefaults} from "./XLayerDefaults.sol";
import {IV3PoolCardinality} from "./XLayerDeploy.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {XHub} from "../src/XHub.sol";
import {XMonthFactory} from "../src/XMonthFactory.sol";
import {XMonthBoard} from "../src/XMonthBoard.sol";
import {XMonthPositions} from "../src/month/XMonthPositions.sol";
import {XMonthExitGovernor} from "../src/month/XMonthExitGovernor.sol";
import {XMarketPriceFeed} from "../src/oracle/XMarketPriceFeed.sol";
import {XMonthMachineSales} from "../src/month/XMonthMachineSales.sol";
import {XPositionExchange} from "../src/month/XPositionExchange.sol";
import {XRigMarket} from "../src/market/XRigMarket.sol";
import {UniswapV3TwapOracle} from "../src/oracle/UniswapV3TwapOracle.sol";
import {RigMachineSource} from "../src/machines/RigMachineSource.sol";
import {DrandEvmnetAdapter} from "../src/random/DrandEvmnetAdapter.sol";
import {ITransistors} from "../src/interfaces/ITapeOut.sol";

/// @title X Layer 主网部署后的只读核对（bash script/xlayer-mainnet.sh check）
/// @notice 读取 deployments/196.json（DEPLOYMENT_FILE 可改），和 XLayerDefaults 的预期值逐项比较，不一致的打印 "MISMATCH"。
///         EXPECT_OPERATOR / EXPECT_FOUNDATION_SAFE / EXPECT_FEE_SAFE / EXPECT_MINT_PRICE_WEI 设置时同时核对。不发送任何交易。
contract CheckXLayerMainnet is Script {
    uint256 internal mismatches;
    uint256 internal checks;

    XHub internal hub;
    XMonthFactory internal monthFactory;
    GenesisSplitter internal splitter;
    DrandEvmnetAdapter internal adapter;
    UniswapV3TwapOracle internal oracle;
    RigMachineSource internal source;
    XMonthPositions internal positions;
    XMonthExitGovernor internal governor;
    XMarketPriceFeed internal priceFeed;
    XMonthMachineSales internal sales;
    XPositionExchange internal exchange;
    XRigMarket internal market;

    function run() public {
        require(block.chainid == 196, "CheckXLayerMainnet: only X Layer mainnet (chain id 196)");
        string memory json = vm.readFile(vm.envOr("DEPLOYMENT_FILE", string("deployments/196.json")));
        hub = XHub(vm.parseJsonAddress(json, ".hub"));
        monthFactory = XMonthFactory(vm.parseJsonAddress(json, ".monthFactory"));
        splitter = GenesisSplitter(payable(vm.parseJsonAddress(json, ".splitter")));
        adapter = DrandEvmnetAdapter(vm.parseJsonAddress(json, ".drandAdapter"));
        oracle = UniswapV3TwapOracle(vm.parseJsonAddress(json, ".oracle"));
        source = RigMachineSource(vm.parseJsonAddress(json, ".machineSource"));
        positions = XMonthPositions(vm.parseJsonAddress(json, ".positions"));
        governor = XMonthExitGovernor(vm.parseJsonAddress(json, ".governor"));
        priceFeed = XMarketPriceFeed(vm.parseJsonAddress(json, ".priceFeed"));
        sales = XMonthMachineSales(vm.parseJsonAddress(json, ".sales"));
        exchange = XPositionExchange(vm.parseJsonAddress(json, ".exchange"));
        market = XRigMarket(vm.parseJsonAddress(json, ".market"));
        XLayerDefaults.Mainnet memory m = XLayerDefaults.mainnet();
        console2.log("== TapeSurge X Layer mainnet check, block", block.number, "time", block.timestamp);

        _wiring(m);
        _splitter(m);
        _board(m);
        _modules(m);
        _v2();
        _status(m);

        console2.log("");
        if (mismatches == 0) {
            console2.log(string.concat("ALL CHECKS PASSED: ", vm.toString(checks), " checks"));
        } else {
            console2.log(
                string.concat("MISMATCH: ", vm.toString(mismatches), " of ", vm.toString(checks), " checks failed")
            );
        }
    }

    function _wiring(XLayerDefaults.Mainnet memory m) internal {
        console2.log("-- wiring");
        _addr("splitter.boardFactory", splitter.boardFactory(), address(hub));
        _addr("hub.splitter", address(hub.splitter()), address(splitter));
        _addr("hub.monthFactory", hub.monthFactory(), address(monthFactory));
        _addr("monthFactory.hub", monthFactory.hub(), address(hub));
        _addr("adapter.registry", address(adapter.registry()), address(hub));
        _addr("hub.passCircuits", hub.passCircuits(), splitter.circuits());
        _addr("transistors.creator", ITransistors(address(hub.transistors())).creator(), address(splitter));
        _addr("hub.feeRecipient", hub.feeRecipient(), splitter.project());
        _addr("oracle.pool", oracle.pool(), m.pool);
        _addr("source.rig", address(source.rig()), m.rig);
        address op = vm.envOr("EXPECT_OPERATOR", address(0));
        if (op != address(0)) _addr("hub.operator", hub.operator(), op);
        else console2.log("  (EXPECT_OPERATOR not set) operator", hub.operator());
    }

    function _splitter(XLayerDefaults.Mainnet memory m) internal {
        console2.log("-- splitter / genesis processor");
        ITransistors t = ITransistors(address(hub.transistors()));
        _uint("transistors.supplyCap", t.supplyCap(), XLayerDefaults.TRANSISTOR_SUPPLY);
        uint256 want = vm.envOr("EXPECT_MINT_PRICE_WEI", uint256(0));
        if (want != 0) _uint("transistors.mintPrice", _mintPrice(address(t)), want);
        else console2.log("  (EXPECT_MINT_PRICE_WEI not set) mintPrice", _mintPrice(address(t)));
        // X Layer：铸造收入 100% 给手续费 Safe，不回购、没有回馈桶
        _uint("buybackBps", splitter.buybackBps(), 0);
        _uint("projectBps", splitter.projectBps(), 10_000);
        _uint("foundationBps", splitter.foundationBps(), 0);
        for (uint256 i = 0; i < 5; i++) {
            _uint(string.concat("bucketBps[", vm.toString(i + 1), "]"), splitter.bucketBps(i + 1), 0);
        }
        _addr("bem", address(splitter.bem()), m.bem);
        _addr("wrappedNative", splitter.wrappedNative(), m.wokb);
        _addr("router", address(splitter.router()), m.router);
        _uint("poolFee", splitter.poolFee(), XLayerDefaults.POOL_FEE);
        _addr("oracle", address(splitter.oracle()), address(oracle));
        _uint("maxSwapPerCall", splitter.maxSwapPerCall(), XLayerDefaults.MAX_SWAP_PER_CALL);
        _uint("minSwapInterval", splitter.minSwapInterval(), XLayerDefaults.MIN_SWAP_INTERVAL);
        _uint("maxSlippageBps", splitter.maxSlippageBps(), XLayerDefaults.MAX_SLIPPAGE_BPS);
        address f = vm.envOr("EXPECT_FOUNDATION_SAFE", address(0));
        address p = vm.envOr("EXPECT_FEE_SAFE", address(0));
        if (f != address(0)) _addr("foundation", splitter.foundation(), f);
        else console2.log("  (EXPECT_FOUNDATION_SAFE not set) foundation", splitter.foundation());
        if (p != address(0)) _addr("project (fee Safe)", splitter.project(), p);
        else console2.log("  (EXPECT_FEE_SAFE not set) project", splitter.project());
    }

    function _board(XLayerDefaults.Mainnet memory m) internal {
        console2.log("-- month board implementation");
        XMonthBoard impl = XMonthBoard(monthFactory.boardImplementation());
        XMonthBoard.Config memory c = monthFactory.boardConfig();
        XMonthBoard.Config memory want =
        XLayerDefaults.monthParams(
            XLayerDefaults.Addresses({
                tapeoutFactory: m.tapeoutFactory,
                passBeacon: m.circuitsBeacon,
                bem: m.bem,
                machineSource: address(source),
                randomSource: address(adapter),
                wrappedNative: m.wokb,
                router: m.router,
                oracle: address(oracle),
                foundation: splitter.foundation(),
                feeSafe: splitter.project(),
                positions: address(positions),
                sales: address(sales),
                governor: address(governor),
                market: address(market)
            })
        )
        .board;
        _addr("BEM", address(impl.BEM()), m.bem);
        _addr("MACHINE_SOURCE", address(impl.MACHINE_SOURCE()), address(source));
        _addr("MACHINE_TOKEN", impl.MACHINE_TOKEN(), m.rig);
        _addr("PASS_BEACON", impl.PASS_BEACON(), m.circuitsBeacon);
        _addr("RANDOM_SOURCE", impl.RANDOM_SOURCE(), address(adapter));
        _addr("HUB", impl.HUB(), address(hub));
        _addr("FOUNDATION", impl.FOUNDATION(), splitter.foundation());
        _addr("FEE_RECIPIENT", impl.FEE_RECIPIENT(), splitter.project());
        _addr("POSITIONS", impl.POSITIONS(), address(positions));
        _addr("SALES", impl.SALES(), address(sales));
        _addr("GOVERNOR", impl.GOVERNOR(), address(governor));
        _addr("MARKET", impl.MARKET(), address(market));
        _b32("PASS_NETLIST_HASH", impl.PASS_NETLIST_HASH(), XLayerDefaults.PASS_NETLIST_HASH);
        _bytes("boardConfig (all numeric rules)", _numbers(c), _numbers(want));
    }

    function _modules(XLayerDefaults.Mainnet memory m) internal {
        console2.log("-- modules");
        _uint("drand minDelay", adapter.minDelay(), XLayerDefaults.DRAND_MIN_DELAY);
        _uint("drand operatorGrace", adapter.operatorGrace(), XLayerDefaults.DRAND_OPERATOR_GRACE);
        _addr("source.expectedCircuits", source.expectedCircuits(), m.bscMachineCircuits);
        _uint("source.minPower", source.minPower(), XLayerDefaults.RIG_MIN_POWER);
        _uint("source.maxPower", source.maxPower(), XLayerDefaults.RIG_MAX_POWER);
        _uint("source.maxSyncAge", source.maxSyncAge(), XLayerDefaults.RIG_MAX_SYNC_AGE);
        _uint("oracle.window", oracle.window(), XLayerDefaults.TWAP_WINDOW);
        (,,, uint16 card, uint16 next,,) = IV3PoolCardinality(m.pool).slot0();
        _bool("pool cardinalityNext >= 1800", next >= XLayerDefaults.OBSERVATION_CARDINALITY, true);
        console2.log("  pool observation cardinality (grows on the next observations)", card);
    }

    function _v2() internal {
        console2.log("-- v2 singletons (positions / governor / price feed / sales / exchange / RIG market)");
        XLayerDefaults.V2Timing memory t = XLayerDefaults.v2Timing();
        _addr("positions.factory", address(positions.factory()), address(monthFactory));
        _addr("governor.FACTORY", address(governor.FACTORY()), address(monthFactory));
        _addr("governor.SALES", address(governor.SALES()), address(sales));
        _uint("governor.MIN_SETTLE_AGE", governor.MIN_SETTLE_AGE(), t.minSettleAge);
        _uint("governor.VOTE_PERIOD", governor.VOTE_PERIOD(), t.votePeriod);
        _uint("governor.EXECUTION_DELAY", governor.EXECUTION_DELAY(), t.executionDelay);
        _uint("governor.EXECUTION_WINDOW", governor.EXECUTION_WINDOW(), t.executionWindow);
        _uint("governor.FAIL_COOLDOWN", governor.FAIL_COOLDOWN(), t.failCooldown);
        _uint("governor.REPRICE_COOLDOWN", governor.REPRICE_COOLDOWN(), t.repriceCooldown);
        _addr("sales.FACTORY", address(sales.FACTORY()), address(monthFactory));
        _addr("sales.HUB", address(sales.HUB()), address(hub));
        _addr("sales.GOVERNOR", sales.GOVERNOR(), address(governor));
        _addr("sales.BEM", address(sales.BEM()), address(splitter.bem()));
        _uint("sales.OPERATOR_GRACE", sales.OPERATOR_GRACE(), t.operatorGrace);
        _uint("sales.PLAN_DECAY", sales.PLAN_DECAY(), t.planDecay);
        _uint("sales.SALE_SYNC_AGE", sales.SALE_SYNC_AGE(), t.saleSyncAge);
        _addr("sales.PRICE_FEED", address(sales.PRICE_FEED()), address(priceFeed));
        _addr("priceFeed.HUB", address(priceFeed.HUB()), address(hub));
        _uint("priceFeed.maxChangeBps", priceFeed.maxChangeBps(), XLayerDefaults.FEED_MAX_CHANGE_BPS);
        _uint("priceFeed.minInterval", priceFeed.minInterval(), XLayerDefaults.FEED_MIN_INTERVAL);
        _uint("priceFeed.maxStaleness", priceFeed.maxStaleness(), XLayerDefaults.FEED_MAX_STALENESS);
        _uint("priceFeed.abandonAfter", priceFeed.abandonAfter(), XLayerDefaults.FEED_ABANDON_AFTER);
        _uint("priceFeed.sellStartBps", priceFeed.sellStartBps(), XLayerDefaults.FEED_SELL_START_BPS);
        _uint("priceFeed.sellStepBps", priceFeed.sellStepBps(), XLayerDefaults.FEED_SELL_STEP_BPS);
        _uint("priceFeed.sellStepInterval", priceFeed.sellStepInterval(), t.sellStepInterval);
        _addr("monthFactory.priceFeed", monthFactory.priceFeed(), address(priceFeed));
        console2.log("  priceFeed bid / ask / BSC block", priceFeed.bid(), priceFeed.ask(), priceFeed.sourceBlock());
        console2.log("  priceFeed fresh", priceFeed.fresh());
        _addr("exchange.FACTORY", address(exchange.FACTORY()), address(monthFactory));
        _addr("exchange.POSITIONS", address(exchange.POSITIONS()), address(positions));
        _addr("exchange.BEM", address(exchange.BEM()), address(splitter.bem()));
        _addr("market.FACTORY", address(market.FACTORY()), address(monthFactory));
        _addr("market.SALES", address(market.SALES()), address(sales));
        _addr("market.MACHINE_SOURCE", address(market.MACHINE_SOURCE()), address(source));
        _addr("market.RIG", address(market.RIG()), XLayerDefaults.mainnet().rig);
        _addr("market.BEM", address(market.BEM()), address(splitter.bem()));
        _addr("market.FEE_RECIPIENT", market.FEE_RECIPIENT(), splitter.project());
        _uint("market.FEE_BPS", market.FEE_BPS(), XLayerDefaults.MARKET_FEE_BPS);
        console2.log("  market asks / open bids / trades", market.askCount(), market.bidCount(), market.tradeCount());
    }

    function _status(XLayerDefaults.Mainnet memory) internal {
        console2.log("-- status");
        _bool("sentinel tripped", XMonthBoard(monthFactory.boardImplementation()).sentinelTripped(), false);
        _uint("sentinelSince", hub.sentinelSince(), 0);
        ITransistors t = ITransistors(address(hub.transistors()));
        uint256 deadline = splitter.mintStart() + hub.genesisDelay();
        console2.log("genesis started", hub.genesisStarted());
        console2.log("transistors minted", t.minted(), "threshold", hub.genesisMintThreshold());
        console2.log("genesis possible at (unix) / by 7-day rule", deadline);
        console2.log("TWAP readable now (buybacks / reward swaps enabled)", oracle.twapAvailable());
        console2.log("splitter OKB balance (wei)", address(splitter).balance);
        console2.log("buybackPool / bucket1 (wei)", splitter.buybackPool(), splitter.rewardBucket(1));
        console2.log("recruiting month board", monthFactory.recruitingBoard());
    }

    // ---------------- 小工具 ----------------

    function _numbers(XMonthBoard.Config memory c) internal pure returns (bytes memory) {
        bytes memory a = abi.encode(c.entryFeeBps, c.recruitDuration, c.minStartBps, c.buyStartBps, c.buyStepBps);
        bytes memory b = abi.encode(c.buyStepInterval, c.buyCapDays, c.buyMaxPrice, c.prepDuration);
        bytes memory d = abi.encode(c.minMachineWeight, c.maxMachineWeight, c.maxMachines, c.miningDuration);
        bytes memory e = abi.encode(c.premiumFeeBps, c.vrfRetryDelay, c.vrfSafeExitDelay);
        bytes memory f = abi.encode(c.operatorGrace, c.claimWindow, c.sentinelResumeDelay);
        return bytes.concat(a, b, d, e, f);
    }

    function _mintPrice(address t) internal view returns (uint256 price) {
        (bool ok, bytes memory ret) = t.staticcall(abi.encodeWithSignature("mintPrice()"));
        if (ok && ret.length >= 32) price = abi.decode(ret, (uint256));
    }

    function _report(string memory name, bool ok, string memory got, string memory want) internal {
        checks++;
        if (ok) {
            console2.log(string.concat("  ok  ", name, " = ", got));
        } else {
            mismatches++;
            console2.log(string.concat("  MISMATCH ", name, ": got ", got, ", want ", want));
        }
    }

    function _uint(string memory name, uint256 got, uint256 want) internal {
        _report(name, got == want, vm.toString(got), vm.toString(want));
    }

    function _addr(string memory name, address got, address want) internal {
        _report(name, got == want, vm.toString(got), vm.toString(want));
    }

    function _bool(string memory name, bool got, bool want) internal {
        _report(name, got == want, got ? "true" : "false", want ? "true" : "false");
    }

    function _b32(string memory name, bytes32 got, bytes32 want) internal {
        _report(name, got == want, vm.toString(got), vm.toString(want));
    }

    function _bytes(string memory name, bytes memory got, bytes memory want) internal {
        _report(name, keccak256(got) == keccak256(want), "(encoded)", "(XLayerDefaults)");
    }
}
