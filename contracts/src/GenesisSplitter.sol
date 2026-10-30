// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ITapeOutFactory, ITransistors} from "./interfaces/ITapeOut.sol";
import {ISwapRouter02, IWrappedNative, IUniswapV3FactoryLike, IPoolTwapOracle} from "./interfaces/ISwap.sol";
import {IRewardTarget, IBoardHub} from "./interfaces/IHub.sol";

/// @title GenesisSplitter（X Layer 版：铸造收入分账合约，也是创世处理器的 creator）
/// @notice 不可升级，没有管理员（没有任何特权角色）。规则和 BSC 版相同（白皮书第 7 节），只换了链相关的部分：
///         铸造收入是 OKB；回购 / 回馈兑换走 Uniswap v3（Oku）的 BEM/WOKB 1% 单池，命名改成链无关的 native / wrappedNative。
///         - 构造时调用 TapeOut 工厂 createCPU 创建创世处理器，从此 creator = 本合约；
///         - distribute()：任何人可调，withdraw 铸造收入（原生币）后分账（比例为构造参数，默认）：
///             40% 回购池 / 10% 项目方（手续费 Safe）/ 20% 基金会 / 30% 五个回馈桶（10 : 8 : 5 : 4 : 3）；
///             某块主板已结束，它那一桶的新增部分（以及桶里剩下的余额）转入回购池；
///         - buyback()：分批（每次限额、最短间隔、最低成交量）买 BEM，直接转入 0x…dEaD（BEM 没有 burn）；
///         - claimReward(i)：把第 i 桶的原生币换成 BEM，转入第 i 块主板作为采购补贴本金（XHub.rewardBoard 的开局顺序）。
///         兑换（M3）：原生币先 wrap 成 wrappedNative（WOKB），再经 SwapRouter02 单跳换成 BEM；
///         最低成交量 = 同一个池子 30 分钟 TWAP 的报价 × (1 − maxSlippageBps)。TWAP 读不出来（观测点不够）时
///         预言机 revert，兑换暂停，而不是按没有防护的价格成交。
///         给基金会 / 项目方的原生币直接转账；对方拒收时改为记账（owedNative），之后由任何人调用 withdrawOwed 转给对方。
/// @dev 本合约在注册中心（XHub）之前单独部署；boardFactory 是预先算好的 XHub 地址（字段名沿用 BSC 版，XHub 部署时核对）。
///      部署时核对：路由的 WETH9 = wrappedNative；预言机的池子 = 路由所在工厂里 (wrappedNative, BEM, poolFee) 的池子。
contract GenesisSplitter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant REWARD_BUCKETS = 5;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct Params {
        address boardFactory; // 预先算好的 BoardFactory（注册中心）地址
        address tapeoutFactory;
        string cpuName;
        string cpuSymbol;
        string cpuStory;
        uint256 transistorSupply; // 66,666（每张通行证 5 颗，最多 13,333 张；和 BSC 版一致，2026-10-21）
        uint256 mintPrice; // X Layer：OKB 计价，部署当天按约 4 U 一张重算（README 默认 0.006 OKB）
        address foundation; // 基金会 Safe
        address project; // 项目方（手续费 Safe）
        uint256 buybackBps; // 4000
        uint256 projectBps; // 1000
        uint256 foundationBps; // 2000
        uint256[5] bucketBps; // 1000 / 800 / 500 / 400 / 300（合计即回馈 30%）
        address bem;
        address wrappedNative; // WOKB
        address router; // Uniswap v3 SwapRouter02
        uint24 poolFee; // BEM/WOKB 池的费率档（10000 = 1%）
        address oracle; // 同一个池子的 TWAP 预言机（UniswapV3TwapOracle），用来算最低成交量
        uint256 maxSwapPerCall; // 每次兑换最多多少原生币（X Layer：1 OKB）
        uint256 minSwapInterval; // 同一用途两次兑换的最短间隔
        uint256 maxSlippageBps; // 相对参考价最多少拿多少（含池子手续费）
    }

    address public immutable boardFactory;
    ITransistors public immutable transistors;
    address public immutable circuits;
    uint256 public immutable mintStart;
    address public immutable foundation;
    address public immutable project;
    uint256 public immutable buybackBps;
    uint256 public immutable projectBps;
    uint256 public immutable foundationBps;
    IERC20 public immutable bem;
    address public immutable wrappedNative;
    ISwapRouter02 public immutable router;
    uint24 public immutable poolFee;
    IPoolTwapOracle public immutable oracle;
    uint256 public immutable maxSwapPerCall;
    uint256 public immutable minSwapInterval;
    uint256 public immutable maxSlippageBps;

    /// @notice 回馈桶比例，下标 1–5（下标 0 不用）
    uint256[6] public bucketBps;

    /// @notice 回购池（原生币）
    uint256 public buybackPool;
    /// @notice 回馈桶（原生币），下标 1–5 对应第 1–5 块主板
    uint256[6] public rewardBucket;
    /// @notice 每种用途上次兑换的时间：下标 0 = 回购，1–5 = 回馈桶
    uint256[6] public lastSwapAt;

    uint256 public totalDistributed;
    uint256 public totalToFoundation;
    uint256 public totalToProject;
    uint256 public totalBemBurned;
    uint256[6] public totalRewardBem;
    /// @notice 拒收后记账、待转出的原生币（不参与分账）
    mapping(address => uint256) public owedNative;
    uint256 public totalOwedNative;

    event Distributed(uint256 fresh, uint256 toFoundation, uint256 toProject, uint256 toBuyback, uint256[6] toBuckets);
    event WithdrawFailed(bytes reason);
    event BucketSwept(uint256 indexed bucket, uint256 amount);
    event Buyback(uint256 nativeIn, uint256 bemOut);
    event RewardClaimed(uint256 indexed bucket, address indexed board, uint256 nativeIn, uint256 bemOut);
    event NativeDeferred(address indexed to, uint256 amount);

    error NotCreator();
    error BadParams();
    error BadBucket();
    error BoardNotActive();
    error TooSoon();
    error NothingToSwap();
    error TransferFailed();

    constructor(Params memory p) payable {
        if (
            p.boardFactory == address(0) || p.foundation == address(0) || p.project == address(0) || p.bem == address(0)
                || p.wrappedNative == address(0) || p.router == address(0) || p.oracle == address(0)
                || p.maxSwapPerCall == 0 || p.maxSlippageBps >= BPS
        ) revert BadParams();
        uint256 sum = p.buybackBps + p.projectBps + p.foundationBps;
        for (uint256 i = 0; i < REWARD_BUCKETS; i++) {
            sum += p.bucketBps[i];
            bucketBps[i + 1] = p.bucketBps[i];
        }
        if (sum != BPS) revert BadParams();
        // 兑换池和预言机必须是同一个池子：路由包装的就是 wrappedNative，预言机报的是 wrappedNative → BEM，
        // 池子 = 路由所在工厂里 (wrappedNative, BEM, poolFee) 的那个池
        IPoolTwapOracle o = IPoolTwapOracle(p.oracle);
        if (ISwapRouter02(p.router).WETH9() != p.wrappedNative) revert BadParams();
        if (o.baseToken() != p.wrappedNative || o.quoteToken() != p.bem || o.fee() != p.poolFee) revert BadParams();
        address pool =
            IUniswapV3FactoryLike(ISwapRouter02(p.router).factory()).getPool(p.wrappedNative, p.bem, p.poolFee);
        if (pool == address(0) || pool != o.pool()) revert BadParams();

        boardFactory = p.boardFactory;
        foundation = p.foundation;
        project = p.project;
        buybackBps = p.buybackBps;
        projectBps = p.projectBps;
        foundationBps = p.foundationBps;
        bem = IERC20(p.bem);
        wrappedNative = p.wrappedNative;
        router = ISwapRouter02(p.router);
        poolFee = p.poolFee;
        oracle = o;
        maxSwapPerCall = p.maxSwapPerCall;
        minSwapInterval = p.minSwapInterval;
        maxSlippageBps = p.maxSlippageBps;

        (address t, address c) = ITapeOutFactory(p.tapeoutFactory).createCPU{value: msg.value}(
            p.cpuName, p.cpuSymbol, p.cpuStory, p.transistorSupply, p.mintPrice
        );
        if (ITransistors(t).creator() != address(this)) revert NotCreator();
        transistors = ITransistors(t);
        circuits = c;
        mintStart = block.timestamp;
    }

    receive() external payable {}

    /// @notice 第 i 块主板（两种局合计、按真正开局的先后排序）是否已结束。
    function boardEnded(uint256 i) public view returns (bool) {
        address b = IBoardHub(boardFactory).rewardBoard(i);
        if (b == address(0)) return false;
        return IRewardTarget(b).rewardEnded();
    }

    /// @notice 提取铸造收入并分账。任何人可调。
    function distribute() external nonReentrant returns (uint256 fresh) {
        return _distribute();
    }

    /// @notice 分批回购：每次最多 maxSwapPerCall，两次之间至少隔 minSwapInterval，
    ///         成交量不低于参考价 × (1 − maxSlippageBps)，买到的 BEM 直接转入 0x…dEaD。任何人可调。
    /// @param minBemOut 调用者自己要求的最低成交量（取它和参考价下限中较大的一个）
    function buyback(uint256 minBemOut) public nonReentrant returns (uint256 bemOut) {
        _distribute();
        if (block.timestamp < lastSwapAt[0] + minSwapInterval) revert TooSoon();
        uint256 amount = buybackPool < maxSwapPerCall ? buybackPool : maxSwapPerCall;
        if (amount == 0) revert NothingToSwap();
        buybackPool -= amount;
        lastSwapAt[0] = block.timestamp;
        bemOut = _swap(amount, DEAD, minBemOut);
        totalBemBurned += bemOut;
        emit Buyback(amount, bemOut);
    }

    function buyback() external returns (uint256) {
        return buyback(0);
    }

    /// @notice 把第 i 桶的原生币换成 BEM，转入第 i 块主板作为采购补贴本金。任何人可调。
    ///         限额与间隔同回购；只认 BoardFactory 创建、处于 Active（采购 / 运行）状态的第 i 块主板。
    function claimReward(uint256 i, uint256 minBemOut) public nonReentrant returns (uint256 bemOut) {
        if (i == 0 || i > REWARD_BUCKETS) revert BadBucket();
        address board = IBoardHub(boardFactory).rewardBoard(i);
        if (board == address(0) || !IRewardTarget(board).acceptsSubsidy()) revert BoardNotActive();
        _distribute();
        if (block.timestamp < lastSwapAt[i] + minSwapInterval) revert TooSoon();
        uint256 amount = rewardBucket[i] < maxSwapPerCall ? rewardBucket[i] : maxSwapPerCall;
        if (amount == 0) revert NothingToSwap();
        rewardBucket[i] -= amount;
        lastSwapAt[i] = block.timestamp;
        bemOut = _swap(amount, address(this), minBemOut);
        bem.forceApprove(board, bemOut);
        IRewardTarget(board).depositSubsidy(bemOut);
        totalRewardBem[i] += bemOut;
        emit RewardClaimed(i, board, amount, bemOut);
    }

    function claimReward(uint256 i) external returns (uint256) {
        return claimReward(i, 0);
    }

    /// @notice 把拒收时记账的原生币再转给对方（基金会或项目方）。任何人可调；对方仍然拒收时 revert，记账不变。
    function withdrawOwed(address to) external nonReentrant returns (uint256 amount) {
        amount = owedNative[to];
        if (amount == 0) revert NothingToSwap();
        owedNative[to] = 0;
        totalOwedNative -= amount;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice 当前回购 / 回馈兑换的最低成交量（参考价下限）。TWAP 读不出来时 revert。
    function minOutFor(uint256 nativeIn) public view returns (uint256) {
        return oracle.quoteBemOut(nativeIn) * (BPS - maxSlippageBps) / BPS;
    }

    function _distribute() internal returns (uint256 fresh) {
        // withdraw 打给 creator（即本合约）；失败时不阻塞分账（原生币留在晶体管合约，下次再取）
        try transistors.withdraw() {}
        catch (bytes memory reason) {
            emit WithdrawFailed(reason);
        }

        uint256 accounted = buybackPool + totalOwedNative;
        bool[6] memory ended;
        for (uint256 i = 1; i <= REWARD_BUCKETS; i++) {
            accounted += rewardBucket[i];
            ended[i] = boardEnded(i);
            // 已结束主板的桶里剩下的余额，也转入回购池（否则会永远无法领取）
            if (ended[i] && rewardBucket[i] > 0) {
                emit BucketSwept(i, rewardBucket[i]);
                buybackPool += rewardBucket[i];
                rewardBucket[i] = 0;
            }
        }
        fresh = address(this).balance - accounted;
        if (fresh == 0) return 0;

        uint256 toFoundation = fresh * foundationBps / BPS;
        uint256 toProject = fresh * projectBps / BPS;
        uint256 toBuyback = fresh - toFoundation - toProject;
        uint256[6] memory toBuckets;
        for (uint256 i = 1; i <= REWARD_BUCKETS; i++) {
            if (ended[i]) continue;
            uint256 share = fresh * bucketBps[i] / BPS;
            toBuckets[i] = share;
            rewardBucket[i] += share;
            toBuyback -= share;
        }
        buybackPool += toBuyback;
        totalDistributed += fresh;
        totalToFoundation += toFoundation;
        totalToProject += toProject;
        emit Distributed(fresh, toFoundation, toProject, toBuyback, toBuckets);

        // 两个固定的 Safe 地址，各一次转账
        _sendNative(foundation, toFoundation);
        _sendNative(project, toProject);
    }

    /// @dev 对方拒收时记账，不回滚整笔分账
    function _sendNative(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) {
            owedNative[to] += amount;
            totalOwedNative += amount;
            emit NativeDeferred(to, amount);
        }
    }

    /// @dev 原生币 → wrap 成 wrappedNative → SwapRouter02 单跳换成 BEM。最低成交量取 TWAP 下限和调用者要求的较大者；
    ///      路由本身会检查 amountOutMinimum。每次只授权这一笔的数额，用完清零。
    function _swap(uint256 amountIn, address recipient, uint256 callerMin) internal returns (uint256 out) {
        uint256 floor = minOutFor(amountIn);
        uint256 minOut = callerMin > floor ? callerMin : floor;
        if (minOut == 0) revert NothingToSwap();
        IWrappedNative(wrappedNative).deposit{value: amountIn}();
        IERC20(wrappedNative).forceApprove(address(router), amountIn);
        out = router.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: wrappedNative,
                tokenOut: address(bem),
                fee: poolFee,
                recipient: recipient,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        IERC20(wrappedNative).forceApprove(address(router), 0);
    }
}
