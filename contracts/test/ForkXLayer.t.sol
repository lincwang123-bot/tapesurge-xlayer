// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {XHub} from "../src/XHub.sol";
import {XMonthBoard} from "../src/XMonthBoard.sol";
import {XMonthFactory} from "../src/XMonthFactory.sol";
import {XLayerDeploy} from "../script/XLayerDeploy.sol";
import {XLayerDefaults} from "../script/XLayerDefaults.sol";
import {MonthState} from "../src/interfaces/IXMonthBoard.sol";
import {IRig} from "../src/interfaces/IRig.sol";
import {ITapeOutFactory, ITransistors, ICircuits} from "../src/interfaces/ITapeOut.sol";
import {RigMachineSource} from "../src/machines/RigMachineSource.sol";
import {MockRandomSource} from "../src/mocks/MockRandom.sol";
import {UniswapV3TwapOracle} from "../src/oracle/UniswapV3TwapOracle.sol";
import {XRigMarket} from "../src/market/XRigMarket.sol";

interface IRigEnumerable is IRig {
    function totalSupply() external view returns (uint256);
    function tokenByIndex(uint256 index) external view returns (uint256);
    function approve(address to, uint256 id) external;
}

interface IFeeTransistors is ITransistors {
    function balanceOf(address owner, uint256 id) external view returns (uint256);
}

/// @notice 没有 onERC721Received 的合约（RIG 用 transferFrom 转入）
contract PlainHolder {}

/// @notice X Layer 主网分叉集成测试（只读：只在本地分叉上执行，不广播）。
///         真实合约：TapeOut 工厂（createCPU / 铸造 / 流片）、RIG 凭证、跨链 BEM、电路信标。
///         分账合约用真实的 Oku SwapRouter02、WOKB 和 BEM/WOKB 池（回购本身见 ForkXLayerBuyback）。
///         仍是 mock 的部分：随机数（drand 真实签名另见 XDrandIntegration 和 script/probes/DrandProbe.sol）。
///         运行：XLAYER_RPC_URL=https://rpc.xlayer.tech forge test --match-contract ForkXLayerTest -vv
///         没有设置 XLAYER_RPC_URL 时全部跳过。
contract ForkXLayerTest is Test {
    address internal constant TAPEOUT_FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    address internal constant RIG = 0x9cfc959cd42B2e1d39a0d850c528210E818AE520;
    address internal constant RIG_IMPL = 0x66FB7d52C4931B48776D9019f88F7f58fB0d85E1;
    address internal constant BEM = 0x60e62Efa9405d6873C5deaBD4E6CC91c25363952;
    address internal constant WOKB = 0xe538905cf8410324e03A5A23C1c177a474D59b2b;
    address internal constant SWAP_ROUTER02 = 0x4f0C28f5926AFDA16bf2506D5D9e57Ea190f9bcA;
    address internal constant BEM_WOKB_POOL = 0x2CcF8aa17F5DF9Fb5D51C9de12135a913fF29f7A;
    address internal constant CIRCUITS_BEACON = 0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C;
    /// @dev RIG 记录里原矿机所在的 BSC 官方矿机电路合约
    address internal constant BSC_MACHINE_CIRCUITS = 0xb1024b89886B9a34Aa4ff5F31C411D708b20a14C;
    address internal constant FOUNDATION = address(0xF0F0);
    address internal constant FEE_SAFE = address(0xFEE5);
    bytes internal constant HA1 = hex"0000000200000300000002000004000000030000040000000500000600000004000004";
    bytes32 internal constant HA1_HASH = 0xfffa29f1e30fa6438ba0e6ebd40ef157b53d0eff3f21cc4bc46942e27cb32ca0;
    bytes32 internal constant ERC1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant ERC1967_BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;
    uint256 internal constant MINT_PRICE = 0.0061 ether; // README 里按约 4 U 一张算出的建议值
    uint256 internal constant BSC_BID = 77_201_309; // 2026-10-27 BSC 主网 MarketPriceFeed 买一（第 130,115,751 块）
    uint256 internal constant BSC_ASK = 142_769_954; // 同一块的卖一
    uint256 internal constant BEM_1 = 1e8;

    bool internal live;
    IRigEnumerable internal rig = IRigEnumerable(RIG);
    RigMachineSource internal source;

    function setUp() public {
        string memory rpc = vm.envOr("XLAYER_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        live = true;
        source = new RigMachineSource(RIG, BSC_MACHINE_CIRCUITS, 10, 300, 3 days);
        console2.log("REPORT fork block", block.number, "timestamp", block.timestamp);
    }

    // =====================================================================
    // 1. 真实 RIG：收购资格和链上记录一致；合约可以直接持有凭证
    // =====================================================================

    function test_Fork_RigEligibilityMatchesLiveRecords() public {
        if (!live) vm.skip(true);
        assertEq(address(uint160(uint256(vm.load(RIG, ERC1967_IMPL_SLOT)))), RIG_IMPL, "RIG implementation");
        assertFalse(rig.isSealed(), "RIG not sealed (UUPS upgradeable; disclosed + monitored off-chain)");
        uint256 n = rig.totalSupply();
        uint256 eligible;
        uint256 lowPower;
        uint256 stale;
        for (uint256 i; i < n; i++) {
            uint256 id = rig.tokenByIndex(i);
            IRig.Rig memory r = rig.rigs(id);
            bool inRange = r.power >= 10 && r.power <= 300;
            bool fresh = r.syncedAt <= block.timestamp && block.timestamp - r.syncedAt <= 3 days;
            bool ok = inRange && fresh && r.circuits == BSC_MACHINE_CIRCUITS;
            assertEq(source.purchaseWeight(id), ok ? r.power : 0, "purchaseWeight follows the live record");
            assertEq(source.currentWeight(id), r.power);
            if (ok) eligible++;
            if (!inRange) lowPower++;
            else if (!fresh) stale++;
            console2.log("REPORT rig", id, r.power, (block.timestamp - r.syncedAt) / 1 hours);
        }
        console2.log("REPORT rigs total / eligible", n, eligible);
        console2.log("REPORT rigs outside 10-300 power / in range but not synced within 3 days", lowPower, stale);
    }

    function test_Fork_ContractHoldsRealRigAndReceivesPlainBem() public {
        if (!live) vm.skip(true);
        uint256 id = rig.tokenByIndex(0);
        address owner = rig.ownerOf(id);
        PlainHolder holder = new PlainHolder();
        vm.prank(owner);
        rig.transferFrom(owner, address(holder), id);
        assertEq(rig.ownerOf(id), address(holder), "contract without onERC721Received holds RIG");
        assertEq(rig.holderAt(id, block.timestamp), address(holder));
        assertEq(rig.payeeAt(id, block.timestamp), address(holder), "yield claimed from now on goes to the holder");
        // 跨链 BEM：8 位小数，普通 transfer 即可到账（RIG 的 lzCompose 用的就是普通转账）
        assertEq(_decimals(BEM), 8);
        deal(BEM, address(this), 3 * BEM_1);
        IERC20(BEM).transfer(address(holder), 3 * BEM_1);
        assertEq(IERC20(BEM).balanceOf(address(holder)), 3 * BEM_1);
    }

    // =====================================================================
    // 2. 一整块月局：真实 TapeOut 通行证、真实 RIG、真实 BEM
    // =====================================================================

    struct Sys {
        GenesisSplitter splitter;
        XHub hub;
        XMonthFactory monthFactory;
        MockRandomSource rng;
        ITransistors transistors;
        ICircuits circuits;
        XLayerDeploy.MonthV2 v2;
    }

    Sys internal sys;
    XMonthBoard internal board;
    address[] internal players;
    uint256 internal soldRig;
    uint256 internal rigCost;
    address internal constant LZ = address(0x1A2E); // 代表 LayerZero 送达方（RIG 用普通转账付款）

    function test_Fork_FullMonthBoardWithRealRigBemAndTapeOut() public {
        if (!live) vm.skip(true);
        _deployAndCheckProcessor();
        _genesisAndJoin();
        _sellRealRig();
        _mineAndDraw();
        _settleAndPayOut();
    }

    function _deployAndCheckProcessor() internal {
        sys = _deploy();
        // 真实工厂创建的创世处理器：creator = 分账合约；电路合约是信标代理，信标就是升级哨兵监控的那个
        assertEq(sys.transistors.creator(), address(sys.splitter));
        assertEq(sys.transistors.supplyCap(), 66_666);
        assertEq(address(uint160(uint256(vm.load(address(sys.circuits), ERC1967_BEACON_SLOT)))), CIRCUITS_BEACON);
    }

    function _genesisAndJoin() internal {
        // 铸满开局门槛（10,000 颗）立刻开局，不用等 7 天（否则 RIG 的同步时间会过期）
        uint256 protocolFee = sys.transistors.protocolFee();
        address whale = address(0x7A1E);
        vm.deal(whale, 100 ether);
        vm.prank(whale);
        sys.transistors.mint{value: 10_000 * (MINT_PRICE + protocolFee)}(0, 10_000);
        // 同 BSC：开局前运营地址（本测试合约）先转报一次 BSC 行情（2026-10-27 BSC 主网的买一 / 卖一）
        sys.v2.priceFeed.post(BSC_BID, BSC_ASK, 130_115_751);
        board = XMonthBoard(sys.hub.startGenesis());
        assertEq(board.target(), 100 * BEM_1);
        assertFalse(board.sentinelTripped(), "real circuits beacon unchanged since deployment");
        // 25 个玩家：真实铸造 5 颗 NAND、真实流片 HA1、用真实 BEM 加入
        for (uint256 i; i < 25; i++) {
            address u = address(uint160(0xA000 + i));
            players.push(u);
            uint256 passId = _mintPass(sys, u, protocolFee);
            assertEq(keccak256(sys.circuits.netlist(passId)), HA1_HASH);
            deal(BEM, u, 10 * BEM_1);
            vm.startPrank(u);
            _approveCircuit(sys.circuits, address(board), passId);
            IERC20(BEM).approve(address(board), type(uint256).max);
            board.join(passId, 4 * BEM_1);
            vm.stopPrank();
        }
        assertEq(uint256(board.state()), uint256(MonthState.Preparing), "filled: started");
        assertEq(board.buyPriceCap(), 165_000_000, "first board uses the deploy cap");
    }

    function _sellRealRig() internal {
        (uint256 rigId, bool mocked) = _eligibleRig();
        if (mocked) console2.log("REPORT no RIG synced within 3 days at this block; mocked rigs() for", rigId);
        else console2.log("REPORT selling live-eligible RIG", rigId);
        address seller = rig.ownerOf(rigId);
        uint256 sellerBem = IERC20(BEM).balanceOf(seller);
        uint256 power = rig.rigs(rigId).power;
        vm.startPrank(seller);
        rig.approve(address(board), rigId);
        uint256 paid = board.sellMachine(address(rig), rigId, 0);
        vm.stopPrank();
        // 收购价上限 = min(BSC 卖一, 部署上限 1.65)，开局时按 50%
        assertEq(paid, power * (BSC_ASK * 5_000 / 10_000), "50% of min(BSC ask, cap) at the start of the round");
        assertEq(rig.ownerOf(rigId), address(board), "board holds the real RIG");
        assertEq(IERC20(BEM).balanceOf(seller) - sellerBem, paid);
        vm.clearMockedCalls();
        soldRig = rigId;
        rigCost = paid;
    }

    function _mineAndDraw() internal {
        // 30 天挖矿：产出由 RIG 普通转账打进来（这里直接转 BEM 模拟 LayerZero 送达），主板按余额增量记账
        vm.warp(board.prepEnd());
        board.sync();
        deal(BEM, LZ, 100 * BEM_1);
        vm.prank(LZ);
        IERC20(BEM).transfer(address(board), 2 * BEM_1);
        board.harvest();
        assertEq(board.prizePool(), 2 * BEM_1);
        vm.warp(board.miningEnd());
        vm.prank(LZ);
        IERC20(BEM).transfer(address(board), 1 * BEM_1);
        board.drawPrizes();
        assertEq(board.prizePool(), 3 * BEM_1);
        sys.rng.fulfill(board.pendingRequestId(), uint256(keccak256("fork prizes")));
        board.finalizePrizes();
        assertEq(uint256(board.state()), uint256(MonthState.Settling));
        assertEq(IERC20(BEM).balanceOf(FOUNDATION), 0, "v2: no 3%");
        assertGt(sys.monthFactory.unitYieldPerDay(), 0, "measured yield reported to the factory");
        console2.log("REPORT measured unit yield per day", sys.monthFactory.unitYieldPerDay());
    }

    function _settleAndPayOut() internal {
        // 1 天后自动按成本价挂单；买家买走凭证，真实 RIG 从主板转给买家
        vm.warp(board.settleStart() + 1 days);
        address buyer = address(0xB0B0);
        deal(BEM, buyer, rigCost);
        // 买之前先在 BSC 金库上发起一次收取（这里把真实 RIG 的同步时间 mock 成现在）
        IRig.Rig memory r = rig.rigs(soldRig);
        assertFalse(sys.v2.sales.syncFresh(address(board), 0), "real RIG has not synced for a day");
        r.syncedAt = uint64(block.timestamp);
        vm.mockCall(RIG, abi.encodeWithSelector(IRig.rigs.selector, soldRig), abi.encode(r));
        vm.startPrank(buyer);
        IERC20(BEM).approve(address(sys.v2.sales), rigCost);
        assertEq(sys.v2.sales.buyMachine(address(board), 0, rigCost), rigCost, "sold at cost");
        vm.stopPrank();
        vm.clearMockedCalls();
        assertEq(rig.ownerOf(soldRig), buyer);
        // 卖出之后才到账的产出（卖出前在 BSC 上发起的收取）仍归本局参与者
        vm.prank(LZ);
        IERC20(BEM).transfer(address(board), 1 * BEM_1);
        sys.v2.sales.distribute(address(board), 1, 25);
        uint256 got;
        for (uint256 i; i < 25; i++) {
            uint256 b = IERC20(BEM).balanceOf(players[i]);
            // 每人投 4 BEM + 0.04 入场费，起始 10 BEM：拿回本金后至少 9.96 BEM
            assertGe(b, 10 * BEM_1 - 4 * BEM_1 / 100, "principal back (only the entry fee is gone)");
            got += b;
            assertEq(sys.circuits.ownerOf(board.socket(i + 1).passId), players[i], "pass returned");
        }
        assertLe(IERC20(BEM).balanceOf(address(board)), 25, "dust only");
        console2.log("REPORT players total BEM after the board (started with 250)", got);
    }

    // =====================================================================
    // 3. RIG 矿机市场（XRigMarket）：真实 RIG、真实 BEM，嵌进月局的买入和卖出
    // =====================================================================

    XRigMarket internal market;
    address internal constant KEEPER = address(0xCAFE);
    address internal constant BIDDER = address(0xB1D0);
    uint256 internal marketRig; // 经市场卖给月局的那张 RIG
    uint256 internal marketBid;

    function test_Fork_RigMarketFeedsAndDrainsBoardWithRealRig() public {
        if (!live) vm.skip(true);
        _deployAndCheckProcessor();
        _genesisAndJoin();
        market = sys.v2.market;
        assertEq(board.MARKET(), address(market));
        _marketSellsToBoard();
        _marketPlayerTrades();
        _marketBoardSellsToBid();
    }

    /// @dev 月局从市场买：真实 RIG 持有人挂卖单（低于当前收购价），任何人触发，月局按卖单实价付款
    function _marketSellsToBoard() internal {
        (uint256 a, bool mocked) = _eligibleRig();
        if (mocked) console2.log("REPORT market: mocked rigs() sync time for", a);
        address seller = rig.ownerOf(a);
        uint256 power = rig.rigs(a).power;
        uint256 price = BSC_ASK * 4_000 / 10_000; // 卖一的 40%，低于开局收购价（卖一的 50%）
        vm.startPrank(seller);
        rig.approve(address(market), a);
        market.listAsk(a, price, uint64(block.timestamp + 7 days));
        vm.stopPrank();
        uint256 before = IERC20(BEM).balanceOf(seller);
        vm.prank(KEEPER);
        uint256 paid = market.sellAskToBoard(a, address(board));
        assertEq(paid, power * price, "board pays the real ask, not the auction price");
        assertLt(paid, power * board.buyPrice());
        assertEq(rig.ownerOf(a), address(board));
        assertEq(board.machine(0).cost, paid);
        assertEq(IERC20(BEM).balanceOf(seller) - before, paid);
        vm.clearMockedCalls();
        marketRig = a;
        console2.log("REPORT market: RIG sold to the board via an ask (id, power, BEM)", a, power, paid);
    }

    /// @dev 玩家之间：一张真实 RIG 挂单、买家吃单；统一买单收下另一张（只要算力 > 0，不要求同步时间）
    function _marketPlayerTrades() internal {
        (uint256 b, uint256 c) = _twoOtherRigs(marketRig);
        address sellerB = rig.ownerOf(b);
        vm.startPrank(sellerB);
        rig.approve(address(market), b);
        market.listAsk(b, 1e8, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        address buyer = address(0xB0B0);
        uint256 totalB = rig.rigs(b).power * 1e8;
        deal(BEM, buyer, totalB);
        vm.startPrank(buyer);
        IERC20(BEM).approve(address(market), totalB);
        market.buyAsk(b, totalB);
        vm.stopPrank();
        assertEq(rig.ownerOf(b), buyer);

        deal(BEM, BIDDER, 1_000 * BEM_1);
        vm.startPrank(BIDDER);
        IERC20(BEM).approve(address(market), type(uint256).max);
        marketBid = market.placeBid(BSC_ASK, 500 * BEM_1, 1, 300, 0, uint64(block.timestamp + 30 days));
        vm.stopPrank();
        address sellerC = rig.ownerOf(c);
        vm.startPrank(sellerC);
        rig.approve(address(market), c);
        uint256 costC = market.sellToBid(marketBid, c);
        vm.stopPrank();
        assertEq(costC, rig.rigs(c).power * BSC_ASK);
        assertEq(rig.ownerOf(c), BIDDER);
    }

    /// @dev 月局在市场卖：挖完、结算后，任何人让月局的那张 RIG 按卖矿合约要价卖给统一买单
    function _marketBoardSellsToBid() internal {
        vm.warp(board.prepEnd());
        board.sync();
        vm.warp(board.miningEnd());
        board.drawPrizes(); // 没有产出：奖金池为 0，直接结算
        assertEq(uint256(board.state()), uint256(MonthState.Settling));
        sys.v2.priceFeed.post(BSC_BID, BSC_ASK, 130_115_751); // 运营地址重新转报（30 天前的报价已过期）
        IRig.Rig memory r = rig.rigs(marketRig);
        r.syncedAt = uint64(block.timestamp); // 卖出前在 BSC 金库收取一次
        vm.mockCall(RIG, abi.encodeWithSelector(IRig.rigs.selector, marketRig), abi.encode(r));
        XRigMarket.OfferView[] memory offers = market.boardOffers(address(board));
        assertEq(offers.length, 1);
        assertEq(offers[0].rigId, marketRig);
        uint256 ask = sys.v2.sales.askPrice(address(board), 0);
        assertEq(offers[0].total, ask);
        // 第一张买单最长 30 天，挖矿期间已过期：任何人帮买家退款，买家重新挂单
        uint256 left = market.bid(marketBid).remaining;
        uint256 bidderBem = IERC20(BEM).balanceOf(BIDDER);
        vm.prank(KEEPER);
        market.refundBid(marketBid);
        assertEq(IERC20(BEM).balanceOf(BIDDER) - bidderBem, left);
        vm.prank(BIDDER);
        marketBid = market.placeBid(BSC_ASK, 500 * BEM_1, 1, 300, 1 days, uint64(block.timestamp + 7 days));
        uint256 remaining = market.bid(marketBid).remaining;
        vm.prank(KEEPER);
        assertEq(market.fillBidFromBoard(marketBid, address(board), 0), ask);
        vm.clearMockedCalls();
        assertEq(rig.ownerOf(marketRig), BIDDER, "the real RIG goes from the board to the bidder");
        assertEq(remaining - market.bid(marketBid).remaining, ask, "bidder pays the board's ask only");
        assertTrue(board.machine(0).sold);
        assertEq(IERC20(BEM).balanceOf(address(market)), market.totalEscrow(), "market holds only bid escrow");
        assertEq(market.tradeCount(), 4);
        console2.log("REPORT market: board RIG sold to a bid (ask BEM, cost BEM)", ask, board.machine(0).cost);
    }

    /// @dev 另外两张算力 > 0 的真实 RIG（不要求同步时间）
    function _twoOtherRigs(uint256 skip) internal view returns (uint256 b, uint256 c) {
        uint256 n = rig.totalSupply();
        for (uint256 i; i < n; i++) {
            uint256 t = rig.tokenByIndex(i);
            if (t == skip || rig.rigs(t).power == 0) continue;
            if (b == 0) b = t;
            else return (b, t);
        }
        revert("need two more RIGs");
    }

    // ---------------- 辅助 ----------------

    function _deploy() internal returns (Sys memory s) {
        s.rng = new MockRandomSource();
        // 真实的 Oku SwapRouter02 和 BEM/WOKB 1% 池；这里不兑换，所以不需要 TWAP 已经可读
        UniswapV3TwapOracle oracle = new UniswapV3TwapOracle(BEM_WOKB_POOL, WOKB, BEM, 30 minutes);
        GenesisSplitter.Params memory sp;
        sp.tapeoutFactory = TAPEOUT_FACTORY;
        sp.cpuName = "TapeSurge Genesis (X Layer) fork test";
        sp.cpuSymbol = "SURGE";
        sp.cpuStory = "fork integration";
        sp.transistorSupply = 66_666;
        sp.mintPrice = MINT_PRICE;
        sp.foundation = FOUNDATION;
        sp.project = FEE_SAFE;
        sp.buybackBps = 4_000;
        sp.projectBps = 1_000;
        sp.foundationBps = 2_000;
        sp.bucketBps = [uint256(1000), 800, 500, 400, 300];
        sp.bem = BEM;
        sp.wrappedNative = WOKB;
        sp.router = SWAP_ROUTER02;
        sp.oracle = address(oracle);
        sp.poolFee = 10_000;
        sp.maxSwapPerCall = 1 ether;
        sp.minSwapInterval = 1 hours;
        sp.maxSlippageBps = 200;
        sp.boardFactory = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        uint256 fee = ITapeOutFactory(TAPEOUT_FACTORY).deployFee();
        vm.deal(address(this), 10 ether);
        s.splitter = new GenesisSplitter{value: fee}(sp);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        s.hub = new XHub(XHub.Params(address(s.splitter), predicted, address(this), 10_000, 7 days));
        XMonthFactory.Params memory mp = _monthParams(address(s.rng));
        (mp.board.positions, mp.board.governor, mp.board.sales, mp.board.market) =
            XLayerDeploy.predictMonthV2(address(this), vm.getNonce(address(this)));
        s.monthFactory = new XMonthFactory(address(s.hub), mp);
        assertEq(address(s.monthFactory), predicted);
        s.v2 = XLayerDeploy.deployMonthV2(address(this), s.monthFactory, XLayerDefaults.v2Timing());
        s.transistors = s.hub.transistors();
        s.circuits = ICircuits(s.hub.passCircuits());
    }

    function _monthParams(address rng) internal view returns (XMonthFactory.Params memory p) {
        XMonthBoard.Config memory c;
        c.bem = BEM;
        c.machineSource = address(source);
        c.passBeacon = CIRCUITS_BEACON;
        c.passNetlistHash = HA1_HASH;
        c.foundation = FOUNDATION;
        c.feeRecipient = FEE_SAFE;
        c.randomSource = rng;
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

    /// @dev 真实 TapeOut：铸 5 颗 NAND（付 mintPrice + 协议费），再流片 HA1（付流片费）。电路编号从 Transfer 事件里取。
    function _mintPass(Sys memory s, address user, uint256 protocolFee) internal returns (uint256 id) {
        vm.deal(user, 1 ether);
        vm.startPrank(user);
        s.transistors.mint{value: 5 * (MINT_PRICE + protocolFee)}(0, 5);
        (, bytes memory feeData) = address(s.circuits).staticcall(abi.encodeWithSignature("TAPEOUT_FEE()"));
        vm.recordLogs();
        (bool ok,) = address(s.circuits).call{value: abi.decode(feeData, (uint256))}(
            abi.encodeCall(ICircuits.tapeout, (HA1, 2, 2))
        );
        require(ok, "tapeout failed");
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("Transfer(address,address,uint256)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(s.circuits) && logs[i].topics.length == 4 && logs[i].topics[0] == topic) {
                return uint256(logs[i].topics[3]);
            }
        }
        revert("no circuit minted");
    }

    function _approveCircuit(ICircuits c, address to, uint256 id) internal {
        (bool ok,) = address(c).call(abi.encodeWithSignature("approve(address,uint256)", to, id));
        require(ok, "approve failed");
    }

    /// @dev 选一张算力在 10–300 的真实 RIG；如果这一块高度上没有 3 天内同步过的，就只 mock 它的 rigs() 读数
    ///      （同步时间改成现在），凭证转移仍走真实 RIG 合约。
    function _eligibleRig() internal returns (uint256 id, bool mocked) {
        uint256 n = rig.totalSupply();
        uint256 fallbackId;
        for (uint256 i; i < n; i++) {
            uint256 t = rig.tokenByIndex(i);
            if (source.purchaseWeight(t) > 0) return (t, false);
            IRig.Rig memory r = rig.rigs(t);
            if (fallbackId == 0 && r.power >= 10 && r.power <= 300 && r.circuits == BSC_MACHINE_CIRCUITS) {
                fallbackId = t;
            }
        }
        require(fallbackId != 0, "no RIG in the 10-300 power range");
        IRig.Rig memory f = rig.rigs(fallbackId);
        f.syncedAt = uint64(block.timestamp);
        vm.mockCall(RIG, abi.encodeWithSelector(IRig.rigs.selector, fallbackId), abi.encode(f));
        return (fallbackId, true);
    }

    function _decimals(address token) internal view returns (uint8) {
        (, bytes memory d) = token.staticcall(abi.encodeWithSignature("decimals()"));
        return abi.decode(d, (uint8));
    }
}
