// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {XHub} from "../src/XHub.sol";
import {XMonthFactory} from "../src/XMonthFactory.sol";
import {XMonthBoard} from "../src/XMonthBoard.sol";
import {MonthState} from "../src/interfaces/IXMonthBoard.sol";
import {DrandEvmnetAdapter} from "../src/random/DrandEvmnetAdapter.sol";
import {MockBEM} from "../src/mocks/MockBEM.sol";
import {MockRig} from "../src/mocks/MockRig.sol";
import {MockCircuits} from "../src/mocks/MockCircuits.sol";
import {MockTransistors} from "../src/mocks/MockTapeOut.sol";
import {XMonthMachineSales} from "../src/month/XMonthMachineSales.sol";
import {XMarketPriceFeed} from "../src/oracle/XMarketPriceFeed.sol";
import {XPositionExchange} from "../src/month/XPositionExchange.sol";
import {XRigMarket} from "../src/market/XRigMarket.sol";
import {XMonthPositions} from "../src/month/XMonthPositions.sol";

/// @title X Layer 测试网分阶段场景脚本（配合 DeployXLayerTestnet.s.sol；由 script/xlayer-testnet.sh 调用）
/// @notice 每个阶段单独执行，阶段之间等链上时间推进。只能在 X Layer 测试网（1952）或本地 anvil（31337）上运行。
///
///   签名：部署者（= 运营地址、RIG 卖家、买家）的私钥从环境变量 XLAYER_TESTNET_DEPLOYER_PK 读取（xlayer-testnet.sh 在运行时
///   从 .env.xlayer-testnet 载入），在脚本里用 vm.startBroadcast(私钥) 签名，不出现在命令行上，也不打印。
///   玩家的测试私钥由 TEST_MNEMONIC 派生（助记词，或 32 字节十六进制种子；xlayer-testnet.sh 默认用部署私钥的哈希做种子），
///   只存在于本次执行的内存里。
///
///   阶段（STAGE）：
///     status      打印主板状态和时间点
///     fund        部署者给玩家 [PLAYER_FROM, PLAYER_FROM + PLAYER_COUNT) 每人转 FUND_WEI（默认 = 通行证费用 + 0.0005 OKB 手续费余量）
///     mint        玩家各铸 5 颗创世 NAND、流片 HA1 通行证，并领 100 MockBEM
///     feed        运营地址转报 BSC 矿机行情：FEED_BID、FEED_ASK、BSC_BLOCK（由 xlayer-testnet.sh 从 BSC 主网报价合约只读取来），
///                 FEED_CATCHUP=1 表示 BSC 那边在追价。离上次不足 50 分钟时跳过；变动超过 5% 时按 ±5% 追一步（追价报价）
///     genesis     开局（开出第 1 块月局）
///     close       关闭已过招募期的月局（未达 60% 时招募失败，工厂接着开下一块）
///     join        手上有通行证的玩家加入当前招募中的月局，招满为止（STAKE_MODE=max 时每人投最大额）
///     reward      领取首批回馈：REWARD_RANK=i（开局顺序 1–5），任何人可调（X Layer 默认没有回馈桶，跳过）
///     machines    部署者铸 mock RIG（算力 30 / 20 / 40 / 50）卖给 MONTH_NUMBER 号月局，直到预算不够
///     yield       模拟在 BSC 金库上发起收取：MockRig.claim(本局在挖的凭证)，产出到账后 harvest
///     draw        月局到期开奖：先收取一次产出，再 drawPrizes；打印 drand 请求编号、锁定的轮次和该轮的时间
///     deliver     交付 drand 签名：DRAND_REQUEST_ID、DRAND_SIGNATURE（64 字节 hex，由 xlayer-testnet.sh 从 drand HTTP API 取），
///                 然后 finalizePrizes
///     settle      月局结算：交接第 0 张凭证给 RELAY_TO 号月局（它须在准备期）、第 1 张挂 120% 并买走、买走所有可买的
///                 （v2：挂单、买卖、交接都经卖矿单例 XMonthMachineSales）
///     trade       持仓转让演示（v2）：PLAYER_FROM 号玩家把自己的持仓按 UNIT_PRICE（每 1 BEM 本金，默认 1.05 BEM）挂到持仓盘口，
///                 PLAYER_FROM + 1 号玩家买走；卖方已累计的款项结转给卖方（withdrawCredit）
///     distribute  运营地址分批打款并退还通行证（BATCH，默认 100；经卖矿单例）
///     fallback    运营地址超过 operatorGrace 没打款时，由本局一位参与者代为分批打款
///     buyback     回购一次（分账合约 → mock 池子，BEM 转入 0x…dEaD；X Layer 默认不回购，跳过）
///     sweep       玩家把剩下的 OKB 退回部署者
contract XLayerTestnetScenario is Script {
    bytes internal constant PASS_NETLIST = hex"0000000200000300000002000004000000030000040000000500000600000004000004";
    uint256 internal constant BEM_1 = 1e8;
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    XHub internal hub;
    XMonthFactory internal mf;
    GenesisSplitter internal sp;
    DrandEvmnetAdapter internal adapter;
    MockBEM internal mbem;
    MockRig internal rig;
    address internal mockCircuits;
    MockTransistors internal tr;
    MockCircuits internal pass;
    XMonthMachineSales internal sales;
    XMarketPriceFeed internal feed;
    XPositionExchange internal exchange;
    XMonthPositions internal positions;
    XRigMarket internal market; // 2026-10-29 之前的部署没有 RIG 矿机市场时为 0

    uint256 internal deployerKey;
    address internal deployer;
    string internal mnemonic;

    function run() public {
        require(block.chainid == 1952 || block.chainid == 31337, "only X Layer testnet (1952) or local (31337)");
        string memory stage = vm.envOr("STAGE", string("status"));
        _load();
        if (_eq(stage, "status")) return _status();
        deployerKey = vm.envUint("XLAYER_TESTNET_DEPLOYER_PK");
        deployer = vm.addr(deployerKey);
        mnemonic = vm.envOr("TEST_MNEMONIC", string(""));
        if (_eq(stage, "fund")) return _fund(_from(), _count(), _fundAmount());
        if (_eq(stage, "mint")) return _mintPasses(_from(), _count());
        if (_eq(stage, "feed")) return _feed();
        if (_eq(stage, "genesis")) return _genesis();
        if (_eq(stage, "close")) return _close();
        if (_eq(stage, "join")) return _join(_from(), _count());
        if (_eq(stage, "reward")) return _reward(vm.envOr("REWARD_RANK", uint256(1)));
        if (_eq(stage, "machines")) return _machines(_month());
        if (_eq(stage, "yield")) return _yield(_month());
        if (_eq(stage, "draw")) return _draw(_month());
        if (_eq(stage, "deliver")) return _deliver(_month());
        if (_eq(stage, "settle")) return _settle(_month());
        if (_eq(stage, "trade")) return _trade(_month(), _from());
        if (_eq(stage, "distribute")) return _distribute(_month(), deployerKey);
        if (_eq(stage, "fallback")) return _fallback(_month(), _from(), _count());
        if (_eq(stage, "buyback")) return _buyback();
        if (_eq(stage, "sweep")) return _sweepPlayers(_from(), _count());
        revert(string.concat("unknown STAGE: ", stage));
    }

    function _load() internal {
        string memory path =
            vm.envOr("DEPLOYMENT_FILE", string.concat("deployments/", vm.toString(block.chainid), ".json"));
        string memory json = vm.readFile(path);
        hub = XHub(vm.parseJsonAddress(json, ".hub"));
        mf = XMonthFactory(vm.parseJsonAddress(json, ".monthFactory"));
        sp = GenesisSplitter(payable(vm.parseJsonAddress(json, ".splitter")));
        adapter = DrandEvmnetAdapter(vm.parseJsonAddress(json, ".drandAdapter"));
        mbem = MockBEM(vm.parseJsonAddress(json, ".bem"));
        rig = MockRig(vm.parseJsonAddress(json, ".rig"));
        mockCircuits = vm.parseJsonAddress(json, ".mockMachineCircuits");
        tr = MockTransistors(vm.parseJsonAddress(json, ".transistors"));
        pass = MockCircuits(vm.parseJsonAddress(json, ".passCircuits"));
        sales = XMonthMachineSales(vm.parseJsonAddress(json, ".sales"));
        feed = XMarketPriceFeed(vm.parseJsonAddress(json, ".priceFeed"));
        exchange = XPositionExchange(vm.parseJsonAddress(json, ".exchange"));
        positions = XMonthPositions(vm.parseJsonAddress(json, ".positions"));
        if (vm.keyExistsJson(json, ".market")) market = XRigMarket(vm.parseJsonAddress(json, ".market"));
    }

    // =====================================================================
    // 玩家
    // =====================================================================

    /// @dev 第 i 个玩家（派生编号 i + 1）。种子是 32 字节十六进制时：私钥 = keccak256(种子, 编号) mod n；否则按助记词派生。
    function _player(uint256 i) internal view returns (address who, uint256 pk) {
        bytes memory m = bytes(mnemonic);
        require(m.length > 0, "set TEST_MNEMONIC (test seed for player keys)");
        if (m.length == 66 && m[0] == "0" && (m[1] == "x" || m[1] == "X")) {
            pk = uint256(keccak256(abi.encode(vm.parseBytes32(mnemonic), i + 1))) % SECP256K1_N;
        } else {
            pk = vm.deriveKey(mnemonic, uint32(i + 1));
        }
        require(pk != 0, "bad player key");
        who = vm.addr(pk);
    }

    /// @dev 每个玩家需要的 OKB：5 颗 NAND 的铸造价和协议费 + 流片费 + 0.0005 OKB 手续费余量（0.02 gwei 下约 2,500 万 gas；
    ///      forge 按预估 gas × 1.3 检查余额）。用剩的最后由 sweep 退回。
    function _fundAmount() internal view returns (uint256) {
        return vm.envOr("FUND_WEI", (tr.mintPrice() + tr.protocolFee()) * 5 + pass.TAPEOUT_FEE() + 0.0005 ether);
    }

    function _fund(uint256 from, uint256 count, uint256 amount) internal {
        uint256 sent;
        vm.startBroadcast(deployerKey);
        for (uint256 i = from; i < from + count; i++) {
            (address who,) = _player(i);
            if (who.balance >= amount / 2) continue;
            (bool ok,) = who.call{value: amount}("");
            require(ok, "fund");
            sent++;
        }
        vm.stopBroadcast();
        console2.log("funded players", sent, "each (wei)", amount);
    }

    function _mintPasses(uint256 from, uint256 count) internal {
        uint256 price = (tr.mintPrice() + tr.protocolFee()) * 5;
        uint256 minted;
        for (uint256 i = from; i < from + count; i++) {
            (address who, uint256 pk) = _player(i);
            if (pass.lastMintedBy(who) != 0) continue;
            vm.startBroadcast(pk);
            tr.mint{value: price}(0, 5);
            pass.tapeout{value: pass.TAPEOUT_FEE()}(PASS_NETLIST, 2, 2);
            mbem.mint(who, 100 * BEM_1);
            vm.stopBroadcast();
            minted++;
        }
        console2.log("passes minted now", minted, "transistors minted so far", tr.minted());
    }

    // =====================================================================
    // 月局
    // =====================================================================

    function _genesis() internal {
        // 同 BSC：开局前 BSC 行情转报必须已经报过价，先跑 feed 阶段（或让运营机器人先转报一次）
        require(feed.updatedAt() != 0, "price feed never posted: run STAGE=feed (or start the operator bot) before genesis");
        vm.startBroadcast(deployerKey);
        hub.startGenesis();
        vm.stopBroadcast();
        console2.log("genesis started: month board", mf.recruitingBoard());
    }

    function _close() internal {
        XMonthBoard m = XMonthBoard(mf.recruitingBoard());
        require(block.timestamp >= m.recruitDeadline(), "month board still recruiting");
        vm.startBroadcast(deployerKey);
        m.closeRecruitment();
        vm.stopBroadcast();
        console2.log("closed month board", address(m), "state", uint256(m.state()));
        console2.log("now recruiting", mf.recruitingBoard());
    }

    function _join(uint256 from, uint256 count) internal {
        XMonthBoard m = XMonthBoard(mf.recruitingBoard());
        require(block.timestamp < m.recruitDeadline(), "recruitment is over: run STAGE=close first");
        if (block.chainid != 31337) {
            require(
                block.timestamp + vm.envOr("JOIN_MARGIN", uint256(300)) <= m.recruitDeadline(),
                "too close to the recruit deadline: wait for it to pass, then STAGE=close"
            );
        }
        uint256 joined;
        for (uint256 i = from; i < from + count; i++) {
            if (m.state() != MonthState.Recruiting) break;
            (address who, uint256 pk) = _player(i);
            uint256 passId = pass.lastMintedBy(who);
            if (passId == 0 || pass.ownerOf(passId) != who || m.holderCount(who) != 0) continue;
            uint256 lo = m.minStake();
            uint256 hi = m.maxStake();
            uint256 amt = _eq(vm.envOr("STAKE_MODE", string("max")), "max")
                ? hi
                : lo + (uint256(keccak256(abi.encode(address(m), i))) % (hi - lo)) / 1e6 * 1e6;
            vm.startBroadcast(pk);
            if (mbem.balanceOf(who) < amt * 2) mbem.mint(who, 100 * BEM_1);
            pass.approve(address(m), passId);
            mbem.approve(address(m), type(uint256).max);
            m.join(passId, amt);
            vm.stopBroadcast();
            joined++;
        }
        console2.log("month board", address(m), "number", m.number());
        console2.log("  joined now", joined, "state", uint256(m.state()));
    }

    function _reward(uint256 rank) internal {
        if (sp.bucketBps(rank) == 0) {
            console2.log("reward bucket", rank, "is 0% (X Layer default: all mint revenue to the fee Safe), skipped");
            return;
        }
        vm.startBroadcast(deployerKey);
        uint256 out = sp.claimReward(rank);
        vm.stopBroadcast();
        console2.log("reward bucket", rank, "BEM to board", out);
    }

    /// @dev 部署者铸 mock RIG（记录里的原矿机电路 = mock 的"BSC 官方矿机电路"），按当前收购价卖给月局，直到预算不够
    function _machines(XMonthBoard m) internal {
        require(m.isPurchasing(), "month board is not in its purchase window");
        // 同 BSC：收购价上限 = min(BSC 卖一, 开局快照)，报价无效时暂停收购
        require(m.buyPrice() > 0, "buy price is 0: price feed stale or catching up, run STAGE=feed first (or keep the operator bot running)");
        uint256[4] memory powers = [uint256(30), 20, 40, 50];
        uint256 sold;
        for (uint256 k = 0; k < powers.length; k++) {
            uint256 id = m.number() * 1_000 + m.machineCount() + 1;
            if (powers[k] * m.buyPrice() > m.budget()) continue;
            // 有 RIG 矿机市场时，第 2、4 台走市场：按当前收购价的 90% 挂卖单，再卖给月局（月局按卖单实价付款）
            bool viaMarket = address(market) != address(0) && k % 2 == 1;
            vm.startBroadcast(deployerKey);
            rig.mintRig(deployer, id, mockCircuits, id, powers[k]);
            uint256 paid;
            if (viaMarket) {
                rig.approve(address(market), id);
                market.listAsk(id, m.buyPrice() * 9 / 10, uint64(block.timestamp + 1 days));
                paid = market.sellAskToBoard(id, address(m));
            } else {
                rig.approve(address(m), id);
                paid = m.sellMachine(address(rig), id, 0);
            }
            vm.stopBroadcast();
            console2.log(viaMarket ? "sold RIG via the market" : "sold RIG", id, "power", powers[k]);
            console2.log("  paid (BEM)", paid);
            sold++;
        }
        console2.log("machines sold now", sold, "budget left", m.budget());
    }

    /// @dev 本局还没卖出的凭证
    function _activeIds(XMonthBoard m) internal view returns (uint256[] memory ids) {
        uint256 n = m.machineCount();
        ids = new uint256[](n);
        uint256 k;
        for (uint256 i = 0; i < n; i++) {
            XMonthBoard.Machine memory x = m.machine(i);
            if (!x.sold) ids[k++] = x.circuitId;
        }
        assembly {
            mstore(ids, k)
        }
    }

    function _yield(XMonthBoard m) internal {
        vm.startBroadcast(deployerKey);
        m.sync();
        uint256 paid = rig.claim(_activeIds(m));
        m.harvest();
        vm.stopBroadcast();
        console2.log("RIG yield claimed (BEM)", paid);
        console2.log("  state", uint256(m.state()), "prize pool", m.prizePool());
    }

    function _draw(XMonthBoard m) internal {
        vm.startBroadcast(deployerKey);
        m.sync();
        rig.claim(_activeIds(m)); // 运营上：开奖前先在 BSC 上收取一次
        m.drawPrizes();
        vm.stopBroadcast();
        uint256 id = m.pendingRequestId();
        console2.log("prize pool", m.prizePool(), "state", uint256(m.state()));
        if (m.state() != MonthState.Drawing) return;
        (, uint64 round,) = adapter.requests(id);
        console2.log("DRAND_REQUEST", id);
        console2.log("DRAND_ROUND", uint256(round));
        console2.log("DRAND_ROUND_TIME", adapter.roundTime(round));
    }

    function _deliver(XMonthBoard m) internal {
        uint256 id = vm.envUint("DRAND_REQUEST_ID");
        bytes memory sig = vm.envBytes("DRAND_SIGNATURE");
        vm.startBroadcast(deployerKey);
        (,, bool done) = adapter.requests(id);
        if (!done) adapter.fulfill(id, sig);
        if (m.state() == MonthState.Drawing && m.wordReceived()) m.finalizePrizes();
        vm.stopBroadcast();
        console2.log("prizes drawn", m.prizesDrawn(), "state", uint256(m.state()));
        for (uint256 k = 0; k < 5; k++) {
            console2.log("  prize", k, m.winnerSlots(k), m.prizeAmounts(k));
        }
    }

    function _settle(XMonthBoard m) internal {
        require(m.state() == MonthState.Settling, "month board is not settling");
        uint256 relayTo = vm.envOr("RELAY_TO", uint256(0));
        vm.startBroadcast(deployerKey);
        rig.claim(_activeIds(m)); // 交接 / 卖出前先收取一次（也刷新同步时间，接手方要求 3 天内同步过）
        if (relayTo != 0 && !m.machine(0).sold) {
            address to = mf.boardByNumber(relayTo);
            XMonthBoard.Machine memory x = m.machine(0);
            // v2：在接手方的收购拍卖里按它当前的收购价成交，必须不低于成本价（收购价每 6 小时 ÷ 比例 +5%，不够就跳过）
            if (XMonthBoard(to).isPurchasing() && XMonthBoard(to).buyPrice() * x.weight >= x.cost) {
                uint256 paid = sales.relay(address(m), 0, to);
                console2.log("relayed machine 0 to month board", relayTo, to);
                console2.log("  paid (BEM) / cost", paid, x.cost);
            } else {
                console2.log("relay skipped: receiver not purchasing or its buy price is still below cost");
            }
        }
        // 卖价同 BSC：max(收购时算力 × max(买一, 卖一 × (99% − 0.5% × n)), 成本价)；报价无效时暂停卖出（askPrice = 0），
        // 停运后按成本价。报价过期时先跑 feed 阶段。
        if (!feed.fresh() && !feed.abandoned()) console2.log("price feed is stale: sales paused, run STAGE=feed first");
        uint256 bought;
        for (uint256 i = 0; i < m.machineCount(); i++) {
            uint256 price = sales.askPrice(address(m), i);
            if (price == 0) continue;
            mbem.mint(deployer, price);
            mbem.approve(address(sales), price);
            sales.buyMachine(address(m), i, price);
            bought++;
        }
        vm.stopBroadcast();
        console2.log("machines bought now", bought, "unsold", m.unsoldMachines());
        console2.log("  principalRemaining", m.principalRemaining(), "rolledOver", m.rolledOver());
    }

    /// @dev 持仓转让演示：卖方挂卖单，买方吃单；卖方已累计的款项结转给卖方
    function _trade(XMonthBoard m, uint256 from) internal {
        require(m.state() == MonthState.Settling, "month board is not settling");
        (address seller, uint256 sellerPk) = _player(from);
        (address buyer, uint256 buyerPk) = _player(from + 1);
        uint256 slot;
        for (uint256 s = 1; s <= m.socketCount(); s++) {
            if (m.socket(s).owner == seller) {
                slot = s;
                break;
            }
        }
        require(slot != 0, "seller holds no position on this board");
        uint256 unitPrice = vm.envOr("UNIT_PRICE", uint256(105_000_000)); // 每 1 BEM 本金 1.05 BEM
        vm.startBroadcast(sellerPk);
        positions.approve(address(exchange), positions.idOf(address(m), slot));
        exchange.listAsk(address(m), slot, unitPrice, uint64(block.timestamp + 1 days));
        vm.stopBroadcast();
        uint256 cost = exchange.quote(m.socket(slot).stake, unitPrice);
        vm.startBroadcast(buyerPk);
        if (mbem.balanceOf(buyer) < cost) mbem.mint(buyer, cost);
        mbem.approve(address(exchange), cost);
        exchange.buyAsk(address(m), slot, unitPrice);
        vm.stopBroadcast();
        console2.log("position slot", slot, "traded for (BEM)", cost);
        console2.log("  new holder", m.socket(slot).owner, "seller credit", m.credit(seller));
    }

    function _distribute(XMonthBoard m, uint256 key) internal {
        uint256 batch = vm.envOr("BATCH", uint256(100));
        vm.startBroadcast(key);
        for (uint256 s = 1; s <= m.socketCount(); s += batch) {
            sales.distribute(address(m), s, batch);
        }
        vm.stopBroadcast();
        console2.log("distributed month board", address(m), "balance left", mbem.balanceOf(address(m)));
    }

    function _fallback(XMonthBoard m, uint256 from, uint256 count) internal {
        require(m.state() == MonthState.Settling, "month board is not settling");
        require(block.timestamp >= m.settleStart() + mf.boardConfig().operatorGrace, "operator grace is not over yet");
        for (uint256 i = from; i < from + count; i++) {
            (address who, uint256 pk) = _player(i);
            if (m.holderCount(who) == 0) continue;
            console2.log("participant distributes", who);
            return _distribute(m, pk);
        }
        revert("no participant of this board in the player range");
    }

    /// @dev 转报一次 BSC 买一 / 卖一。目标离上次报价超过 5% 时按 ±5% 追一步（追价报价，不算有效），追到后才用 post。
    function _feed() internal {
        uint256 bid = vm.envUint("FEED_BID");
        uint256 ask = vm.envUint("FEED_ASK");
        uint256 bscBlock = vm.envUint("BSC_BLOCK");
        bool catchUp = vm.envOr("FEED_CATCHUP", false);
        uint256 t = feed.updatedAt();
        if (t != 0 && block.timestamp < t + feed.minInterval()) {
            console2.log("feed: last post too recent, skipped; next post possible at", t + feed.minInterval());
            return;
        }
        if (t != 0) {
            uint256 b = _step(bid, feed.bid());
            uint256 a = _step(ask, feed.ask());
            if (a < b) a = b;
            if (b != bid || a != ask) (bid, ask, catchUp) = (b, a, true);
        }
        vm.startBroadcast(deployerKey);
        if (catchUp) feed.postCatchUp(bid, ask, bscBlock);
        else feed.post(bid, ask, bscBlock);
        vm.stopBroadcast();
        console2.log("feed posted bid / ask (BEM per unit power, 8 decimals)", bid, ask);
        console2.log("  BSC block", bscBlock, "catching up", catchUp);
        console2.log("  fresh", feed.fresh());
    }

    /// @dev 把目标价限制在上次报价的 ±5% 之内
    function _step(uint256 target, uint256 last) internal view returns (uint256) {
        uint256 bps = feed.maxChangeBps();
        uint256 hi = last * (10_000 + bps) / 10_000;
        uint256 lo = (last * (10_000 - bps) + 9_999) / 10_000;
        return target > hi ? hi : target < lo ? lo : target;
    }

    function _buyback() internal {
        if (sp.buybackBps() == 0) {
            console2.log("buyback is 0% (X Layer default: all mint revenue to the fee Safe), skipped");
            return;
        }
        vm.startBroadcast(deployerKey);
        uint256 out = sp.buyback();
        vm.stopBroadcast();
        console2.log("buyback: BEM burned", out, "pool left (wei)", sp.buybackPool());
    }

    function _sweepPlayers(uint256 from, uint256 count) internal {
        uint256 keep = 50_000 * vm.envOr("GAS_PRICE_WEI", uint256(0.02 gwei));
        uint256 total;
        uint256 n;
        for (uint256 i = from; i < from + count; i++) {
            (address who, uint256 pk) = _player(i);
            uint256 bal = who.balance;
            if (bal <= keep * 2) continue;
            vm.startBroadcast(pk);
            (bool ok,) = payable(deployer).call{value: bal - keep}("");
            vm.stopBroadcast();
            require(ok, "sweep");
            total += bal - keep;
            n++;
        }
        console2.log("players swept", n, "OKB returned (wei)", total);
    }

    function _status() internal view {
        console2.log("now", block.timestamp, "operator", hub.operator());
        console2.log("genesis started", hub.genesisStarted(), "transistors minted", tr.minted());
        if (!hub.genesisStarted()) console2.log("  genesis possible at", sp.mintStart() + hub.genesisDelay());
        console2.log("buyback pool (wei)", sp.buybackPool(), "BEM burned", sp.totalBemBurned());
        console2.log("price feed bid / ask", feed.bid(), feed.ask());
        console2.log("  BSC block", feed.sourceBlock(), "fresh", feed.fresh());
        uint256 n = mf.currentNumber();
        for (uint256 i = 1; i <= n; i++) {
            XMonthBoard m = XMonthBoard(mf.boardByNumber(i));
            console2.log("month board", i, address(m));
            console2.log("  state", uint256(m.state()), "participants", m.socketCount());
            console2.log("  recruitDeadline", m.recruitDeadline(), "prepEnd", m.prepEnd());
            console2.log("  miningEnd", m.miningEnd(), "prizePool", m.prizePool());
            console2.log("  machines", m.machineCount(), "unsold", m.unsoldMachines());
            console2.log("  settleStart", m.settleStart(), "subsidyCapital", m.subsidyCapital());
            if (m.state() == MonthState.Drawing && m.drawPending()) {
                (, uint64 round,) = adapter.requests(m.pendingRequestId());
                console2.log("  drand request", m.pendingRequestId(), "round", uint256(round));
            }
        }
    }

    // ---------------- 小工具 ----------------

    function _month() internal view returns (XMonthBoard) {
        uint256 n = vm.envOr("MONTH_NUMBER", uint256(1));
        address b = mf.boardByNumber(n);
        require(b != address(0), "no such month board");
        return XMonthBoard(b);
    }

    function _from() internal view returns (uint256) {
        return vm.envOr("PLAYER_FROM", uint256(0));
    }

    function _count() internal view returns (uint256) {
        return vm.envOr("PLAYER_COUNT", uint256(50));
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
