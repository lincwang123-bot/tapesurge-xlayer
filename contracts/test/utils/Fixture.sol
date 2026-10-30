// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {XHub} from "../../src/XHub.sol";
import {XMonthBoard} from "../../src/XMonthBoard.sol";
import {XMonthFactory} from "../../src/XMonthFactory.sol";
import {GenesisSplitter} from "../../src/GenesisSplitter.sol";
import {XMonthPositions} from "../../src/month/XMonthPositions.sol";
import {XMonthExitGovernor} from "../../src/month/XMonthExitGovernor.sol";
import {XMonthMachineSales} from "../../src/month/XMonthMachineSales.sol";
import {XPositionExchange} from "../../src/month/XPositionExchange.sol";
import {XRigMarket} from "../../src/market/XRigMarket.sol";
import {XMarketPriceFeed} from "../../src/oracle/XMarketPriceFeed.sol";
import {XLayerDefaults} from "../../script/XLayerDefaults.sol";
import {XLayerDeploy} from "../../script/XLayerDeploy.sol";
import {MonthState} from "../../src/interfaces/IXMonthBoard.sol";
import {MockBEM} from "../../src/mocks/MockBEM.sol";
import {MockRig} from "../../src/mocks/MockRig.sol";
import {RigMachineSource} from "../../src/machines/RigMachineSource.sol";
import {MockCircuits, MockBeacon} from "../../src/mocks/MockCircuits.sol";
import {MockTapeOutFactory, MockTransistors} from "../../src/mocks/MockTapeOut.sol";
import {MockRandomSource} from "../../src/mocks/MockRandom.sol";
import {
    MockWrappedNative,
    MockV3Pool,
    MockV3Factory,
    MockSwapRouter02,
    MockPriceOracle
} from "../../src/mocks/MockSwap.sol";

/// @notice X Layer 月局完整本地夹具；没有网络、私钥或广播。
abstract contract Fixture is Test {
    address internal constant FOUNDATION = address(0xF001);
    address internal constant FEE_SAFE = address(0xF002);
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal constant CIRC = address(0xC1C1);
    bytes internal constant PASS_NETLIST = hex"0000000200000300000002000004000000030000040000000500000600000004000004";
    bytes32 internal constant PASS_HASH = 0xfffa29f1e30fa6438ba0e6ebd40ef157b53d0eff3f21cc4bc46942e27cb32ca0;
    uint256 internal constant BEM_1 = 1e8;
    uint256 internal constant START_TIME = 1_790_000_000;
    /// @dev 1 OKB ≈ 3.86 BEM（2026-10-21 BEM/WOKB 池的现价；mock 的固定汇率，不是行情）
    uint256 internal constant BEM_PER_NATIVE = 386_000_000;
    uint24 internal constant POOL_FEE = 10_000;
    /// @dev 测试默认的 BSC 行情：卖一 = 部署上限 1.65 BEM / 算力（收购价上限不受卖一影响，和对齐 BSC 之前的测试口径相同），
    ///      买一很低（清算下限几乎不起作用）。报价相关的规则在专门的测试里用其他价格覆盖。
    uint256 internal constant FEED_BID = 1_000_000;
    uint256 internal constant FEED_ASK = 165_000_000;
    MockBEM internal bem;
    MockRig internal machines;
    RigMachineSource internal machineSource;
    MockBeacon internal machineBeacon; // compatibility name, monitors PASS beacon on X Layer
    MockTapeOutFactory internal tapeout;
    MockRandomSource internal rng;
    MockWrappedNative internal wrapped;
    MockV3Pool internal pool;
    MockV3Factory internal v3Factory;
    MockSwapRouter02 internal router;
    MockPriceOracle internal oracle;
    XHub internal factory;
    XMonthFactory internal monthFactory;
    GenesisSplitter internal splitter;
    MockTransistors internal transistors;
    MockCircuits internal passCircuits;
    XMonthPositions internal positions;
    XMonthExitGovernor internal governor;
    XMonthMachineSales internal sales;
    XPositionExchange internal exchange;
    XRigMarket internal market;
    XMarketPriceFeed internal priceFeed;
    uint256 internal userNonce;
    uint256 internal machineNonce;
    mapping(address => uint256) internal deliveredYield;

    function setUp() public virtual {
        vm.warp(START_TIME);
        vm.deal(address(this), 100 ether);
        bem = new MockBEM();
        machines = new MockRig(address(bem));
        machineSource = new RigMachineSource(address(machines), CIRC, 10, 300, 3 days);
        tapeout = new MockTapeOutFactory(0.001 ether, 0.0001 ether, 0.0002 ether);
        machineBeacon = tapeout.circuitsBeacon();
        rng = new MockRandomSource();
        wrapped = new MockWrappedNative();
        pool = new MockV3Pool(address(wrapped), address(bem), POOL_FEE, 0);
        v3Factory = new MockV3Factory();
        v3Factory.setPool(address(wrapped), address(bem), POOL_FEE, address(pool));
        router = new MockSwapRouter02(address(wrapped), address(v3Factory), address(bem), BEM_PER_NATIVE);
        oracle = new MockPriceOracle(address(pool), address(wrapped), address(bem), POOL_FEE, BEM_PER_NATIVE);
        _deploySystem(defaultMonthParams(), defaultSplitterParams());
    }

    function defaultSplitterParams() internal view returns (GenesisSplitter.Params memory sp) {
        sp.tapeoutFactory = address(tapeout);
        sp.cpuName = "TapeSurge Genesis (X Layer)";
        sp.cpuSymbol = "SURGE";
        sp.cpuStory = "5 transistors, one half adder: your pass to the board.";
        sp.transistorSupply = 66_666;
        sp.mintPrice = 0.001 ether; // mock fixture price; mainnet price is separate
        sp.foundation = FOUNDATION;
        sp.project = FEE_SAFE;
        sp.buybackBps = 4_000;
        sp.projectBps = 1_000;
        sp.foundationBps = 2_000;
        sp.bucketBps = [uint256(1000), 800, 500, 400, 300];
        sp.bem = address(bem);
        sp.wrappedNative = address(wrapped);
        sp.router = address(router);
        sp.oracle = address(oracle);
        sp.poolFee = POOL_FEE;
        sp.maxSwapPerCall = 1 ether;
        sp.minSwapInterval = 1 hours;
        sp.maxSlippageBps = 200;
    }

    function defaultMonthParams() internal view returns (XMonthFactory.Params memory p) {
        XMonthBoard.Config memory c;
        c.bem = address(bem);
        c.machineSource = address(machineSource);
        c.passBeacon = address(machineBeacon);
        c.passNetlistHash = PASS_HASH;
        c.foundation = FOUNDATION;
        c.feeRecipient = FEE_SAFE;
        c.randomSource = address(rng);
        c.entryFeeBps = 100;
        c.premiumFeeBps = 1000;
        c.recruitDuration = 3 days;
        c.minStartBps = 6000;
        c.buyStartBps = 5000;
        c.buyStepBps = 500;
        c.buyStepInterval = 6 hours;
        c.buyCapDays = 365;
        c.buyMaxPrice = 165_000_000;
        c.prepDuration = 3 days;
        c.minMachineWeight = 10;
        c.maxMachineWeight = 300;
        c.maxMachines = 100;
        c.miningDuration = 30 days;
        c.vrfRetryDelay = 1 days;
        c.vrfSafeExitDelay = 7 days;
        c.operatorGrace = 3 days;
        c.claimWindow = 365 days;
        c.sentinelResumeDelay = 30 days;
        p.board = c;
        p.targets = XMonthFactory.TargetRules(100e8, 100e8, 1000e8, 1e8, 20, 400, 1 days, 12500, 7500, 5000);
    }

    function _deploySystem(XMonthFactory.Params memory mp, GenesisSplitter.Params memory sp) internal {
        sp.boardFactory = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        splitter = new GenesisSplitter{value: tapeout.deployFee()}(sp);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        factory = new XHub(XHub.Params(address(splitter), predicted, address(this), 10_000, 7 days));
        (mp.board.positions, mp.board.governor, mp.board.sales, mp.board.market) =
            XLayerDeploy.predictMonthV2(address(this), vm.getNonce(address(this)));
        monthFactory = new XMonthFactory(address(factory), mp);
        assertEq(address(monthFactory), predicted, "factory address prediction");
        XLayerDeploy.MonthV2 memory v2 = XLayerDeploy.deployMonthV2(address(this), monthFactory, XLayerDefaults.v2Timing());
        positions = v2.positions;
        governor = v2.governor;
        sales = v2.sales;
        exchange = v2.exchange;
        market = v2.market;
        priceFeed = v2.priceFeed;
        transistors = MockTransistors(address(factory.transistors()));
        passCircuits = MockCircuits(factory.passCircuits());
    }

    /// @dev 测试合约（运营地址）转报 BSC 买一 = bid、卖一 = ask（每单位算力）。距上次不足 50 分钟时先等够。
    ///      变动超过 5% 时（合约不接受），先等 3 小时，再直接写入报价合约的存储，相当于机器人已经分几次追到了这个价
    ///      （只用于搭场景；限幅本身由 XMarketPriceFeed.t.sol 测）。同 BSC 版 Fixture._postPrices。
    function _postPrices(uint256 bid, uint256 ask) internal {
        uint256 t = priceFeed.updatedAt();
        if (t != 0) {
            if (block.timestamp < t + 50 minutes) vm.warp(t + 50 minutes);
            uint256 lb = priceFeed.bid();
            uint256 la = priceFeed.ask();
            bool big = bid * 10_000 > lb * 10_500 || bid * 10_000 < lb * 9_500 || ask * 10_000 > la * 10_500
                || ask * 10_000 < la * 9_500;
            if (big) {
                if (block.timestamp < t + 3 hours) vm.warp(t + 3 hours);
                _forcePrices(bid, ask);
                return;
            }
        }
        priceFeed.post(bid, ask, block.number);
    }

    /// @dev 直接写报价合约的 bid / ask / updatedAt / catchingUp / liveAt（存储槽 0 / 1 / 2 / 4 / 5），当作一次有效报价
    function _forcePrices(uint256 bid, uint256 ask) internal {
        vm.store(address(priceFeed), bytes32(uint256(0)), bytes32(bid));
        vm.store(address(priceFeed), bytes32(uint256(1)), bytes32(ask));
        vm.store(address(priceFeed), bytes32(uint256(2)), bytes32(block.timestamp));
        vm.store(address(priceFeed), bytes32(uint256(4)), bytes32(0));
        vm.store(address(priceFeed), bytes32(uint256(5)), bytes32(block.timestamp));
    }

    /// @dev 同 BSC：开局前运营地址必须已经转报过 BSC 行情
    function _startGenesis() internal returns (XMonthBoard) {
        vm.warp(block.timestamp + 7 days);
        _feedDefault();
        return XMonthBoard(factory.startGenesis());
    }

    /// @dev 运营机器人转报默认行情（现在有效）：收购和卖出都按报价公式；收购前保持报价有效
    function _feedDefault() internal {
        _forcePrices(FEED_BID, FEED_ASK);
    }

    /// @dev BSC 市价低于成本价时的有效报价：卖价公式低于成本价，按成本价卖
    function _feedAtCost() internal {
        _forcePrices(1, 1);
    }

    function _monthBoard() internal view returns (XMonthBoard) {
        return XMonthBoard(monthFactory.recruitingBoard());
    }

    function _joinMonth(XMonthBoard mb, uint256 amount) internal returns (address user) {
        user = _newUser();
        uint256 passId = _mintPass(user);
        bem.mint(user, amount * 2);
        vm.startPrank(user);
        passCircuits.approve(address(mb), passId);
        bem.approve(address(mb), type(uint256).max);
        mb.join(passId, amount);
        vm.stopPrank();
    }

    /// @dev 用最大投入把月局招满
    function _fillMonth(XMonthBoard mb) internal returns (address[] memory users) {
        uint256 n;
        uint256 maxS = mb.maxStake();
        users = new address[](mb.target() / maxS + 1);
        while (mb.state() == MonthState.Recruiting) {
            users[n++] = _joinMonth(mb, maxS);
        }
        assembly {
            mstore(users, n)
        }
    }

    function _sellMonth(XMonthBoard mb, address seller, uint256 weight)
        internal
        returns (uint256 id, bytes32 key, uint256 paid)
    {
        (id, key) = _newMachine(seller, weight);
        _feedDefault(); // 收购要有效报价（同 BSC：报价无效时暂停收购）
        vm.startPrank(seller);
        machines.approve(address(mb), id);
        paid = mb.sellMachine(address(machines), id, 0);
        vm.stopPrank();
    }

    // ---------------- v2 持仓（按地址找插槽，口径同 BSC 版夹具）----------------

    function _slot(XMonthBoard mb, address u) internal view returns (uint256) {
        uint256 n = mb.socketCount();
        for (uint256 i = 1; i <= n; i++) {
            if (mb.socket(i).owner == u) return i;
        }
        return 0;
    }

    /// @dev 某地址在月局可领的全部 BEM = 它持有的持仓可领 + 转让结转款
    function _mOwed(XMonthBoard mb, address u) internal view returns (uint256 amount) {
        uint256 n = mb.socketCount();
        for (uint256 i = 1; i <= n; i++) {
            if (mb.socket(i).owner == u) amount += mb.owed(i);
        }
        amount += mb.credit(u);
    }

    function _mWithdraw(XMonthBoard mb, address u) internal returns (uint256 amount) {
        uint256 n = mb.socketCount();
        for (uint256 i = 1; i <= n; i++) {
            if (mb.socket(i).owner == u && mb.owed(i) > 0) amount += mb.withdraw(i);
        }
        if (mb.credit(u) > 0) amount += mb.withdrawCredit(u);
        if (amount == 0) revert XMonthBoard.NothingToWithdraw();
    }

    function _mClaimAll(XMonthBoard mb, address u) internal returns (uint256 amount) {
        uint256 n = mb.socketCount();
        for (uint256 i = 1; i <= n; i++) {
            if (mb.socket(i).owner == u) amount += mb.claimAll(i);
        }
        if (!mb.claimsClosed() && mb.credit(u) > 0) amount += mb.withdrawCredit(u);
    }

    function _mReturnPass(XMonthBoard mb, address u) internal {
        mb.returnPass(_slot(mb, u));
    }

    /// @dev v2 交接：等接手方的收购价涨到不低于出让方成本价（每 6 小时 +5%），再交接；返回实际成交额
    function _relayWhenPriced(XMonthBoard from, uint256 index, XMonthBoard to) internal returns (uint256 paid) {
        uint256 cost = from.machine(index).cost;
        uint256 w = from.machine(index).weight;
        _feedDefault();
        while (to.buyPrice() * w < cost && to.isPurchasing()) {
            vm.warp(block.timestamp + 6 hours);
            _feedDefault();
        }
        // X Layer：运营上交接前先在 BSC 金库上收取一次，刷新 RIG 的同步时间（接手方只收 3 天内同步过的凭证）
        _yieldMonth(from, 0);
        paid = sales.relay(address(from), index, address(to));
    }

    // ---------------- 参与者 ----------------

    function _newUser() internal returns (address u) {
        u = address(uint160(0x100000 + ++userNonce));
        vm.label(u, string.concat("user", vm.toString(userNonce)));
    }

    /// @dev 用户铸 5 颗创世 NAND，按标准网表流片，得到通行证
    function _mintPass(address user) internal returns (uint256 passId) {
        return _mintCircuit(user, PASS_NETLIST);
    }

    function _mintCircuit(address user, bytes memory nl) internal returns (uint256 id) {
        uint256 gates = nl.length / 7;
        vm.deal(user, user.balance + 1 ether);
        vm.startPrank(user);
        transistors.mint{value: (0.001 ether + 0.0001 ether) * gates}(0, gates);
        id = passCircuits.tapeout{value: 0.0002 ether}(nl, 2, 2);
        vm.stopPrank();
    }

    function _newMachine(address owner, uint256 weight) internal returns (uint256 id, bytes32 key) {
        id = ++machineNonce;
        machines.mintRig(owner, id, CIRC, id, weight);
        key = bytes32(id);
    }

    function _yieldMonth(XMonthBoard board, uint256 amount) internal {
        bem.mint(address(board), amount);
        deliveredYield[address(board)] += amount;
        // 同步到账的常规消息同时刷新所持 RIG 的算力时间；延迟/乱序专用测试直接调用 deliverYield。
        for (uint256 i; i < board.machineCount(); ++i) {
            XMonthBoard.Machine memory machine = board.machine(i);
            if (!machine.sold) {
                machines.sync(machine.circuitId, machines.rigs(machine.circuitId).power, uint64(block.timestamp));
            }
        }
    }

    /// @dev 模拟在 BSC 金库上为本局还没卖出的 RIG 发起一次收取（不带产出）：刷新同步时间。
    ///      卖矿合约要求购买 / 交接前 1 天内同步过。
    function _syncRigs(XMonthBoard board) internal {
        _yieldMonth(board, 0);
    }

    receive() external payable {}
}
