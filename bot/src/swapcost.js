// 经 Firsto 成交时 BEM ↔ BNB 的兑换成本（规则 6.22）。
// 主网按这一单的金额用 PancakeSwap V3 QuoterV2 eth_call 精确报出，和兑换适配器走同一条路径
// （WBNB ⇄ USDT 0.01% 池 ⇄ BEM 1% 池），成本相对合约用的 30 分钟 TWAP（oracle.quoteBemOut）计算：
//   - bnbOut（买矿机：用 BEM 换出 amount 个 BNB）：要付的 BEM ÷ TWAP 折算的 BEM − 1
//   - bemOut（卖矿机：用 BNB 换出 amount 个 BEM）：要付的 BNB ÷ TWAP 折算的 BNB − 1
// 报价（报给 MarketPriceFeed 的买一 / 卖一）用 forFeed：实际成本 + 0.25% 余量，限制在 1.2%–2%；
// 递单时直接用实际成本加一点余量（合约按实际欠款检查，挑错了只会模拟失败）。
// 测试网的兑换是 mock（固定 0.5%），也没有 QuoterV2，直接用 cfg.swapCostBps；主网读不到时也退回它并报警。
import { encodePacked, parseAbi } from 'viem';
import { ABI } from './abi.js';
import * as log from './log.js';

export const QUOTER_V2 = '0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997'; // PancakeSwap V3 QuoterV2（BSC 主网）
export const WBNB = '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c';
export const USDT = '0x55d398326f99059fF775485246999027B3197955';
const FEE_WBNB_USDT = 100;
const FEE_USDT_BEM = 10_000;
const E18 = 10n ** 18n;
const BPS = 10_000n;
const QUOTER_ABI = parseAbi(['function quoteExactOutput(bytes path, uint256 amountOut) view returns (uint256 amountIn, uint160[] sqrtPriceX96AfterList, uint32[] initializedTicksCrossedList, uint256 gasEstimate)']);

/** quoteExactOutput 的路径从输出币写到输入币 */
export function exactOutputPath(dir, bem) {
  return dir === 'bnbOut'
    ? encodePacked(['address', 'uint24', 'address', 'uint24', 'address'], [WBNB, FEE_WBNB_USDT, USDT, FEE_USDT_BEM, bem])
    : encodePacked(['address', 'uint24', 'address', 'uint24', 'address'], [bem, FEE_USDT_BEM, USDT, FEE_WBNB_USDT, WBNB]);
}

/** 实际付出相对 TWAP 折算值多出的比例（基点，向上取整；现价比 TWAP 有利时可以是负数） */
export function costBps(amountIn, twapIn) {
  if (twapIn <= 0n) throw new Error('TWAP 折算为 0');
  const d = (amountIn - twapIn) * BPS;
  return d >= 0n ? (d + twapIn - 1n) / twapIn : d / twapIn;
}

/** 报价用：实际成本 + 余量，限制在 [min, max] */
export function feedBps(raw, { marginBps = 25n, minBps = 120n, maxBps = 200n } = {}) {
  const s = raw + marginBps;
  return s < minBps ? minBps : s > maxBps ? maxBps : s;
}

/**
 * 一单的兑换成本。dir = 'bnbOut'（amount 是要换出的 BNB wei）或 'bemOut'（amount 是要换出的 BEM 最小单位）。
 * 返回 { rawBps, amountIn, quoted }；不能实时报价（测试网、读失败）时 rawBps = cfg.swapCostBps、quoted = false。
 */
export async function quoteSwapCost(ctx, dir, amount) {
  const { cfg, dep, pub } = ctx;
  const fixed = { rawBps: cfg.swapCostBps, amountIn: null, quoted: false };
  if (!cfg.mainnet || cfg.network !== 'bsc' || amount <= 0n) return fixed;
  try {
    const [amountIn] = await pub.readContract({ address: dep.swapQuoter ?? QUOTER_V2, abi: QUOTER_ABI, functionName: 'quoteExactOutput', args: [exactOutputPath(dir, dep.bem), amount] });
    let twapIn;
    if (dir === 'bnbOut') twapIn = await pub.readContract({ address: dep.oracle, abi: ABI.oracle, functionName: 'quoteBemOut', args: [amount] });
    else {
      const bemPerBnb = await pub.readContract({ address: dep.oracle, abi: ABI.oracle, functionName: 'quoteBemOut', args: [E18] });
      twapIn = (amount * E18) / bemPerBnb;
    }
    return { rawBps: costBps(amountIn, twapIn), amountIn, quoted: true };
  } catch (e) {
    log.warn('swap cost: quoter unavailable', { dir, amount: String(amount), reason: e.message });
    await ctx.alert?.send('swap:quoter', `⚠️ 读不到 PancakeSwap 兑换报价，兑换成本暂按固定 ${Number(cfg.swapCostBps) / 100}% 算：${e.message}`, { everySec: 6 * 3600 });
    return fixed;
  }
}

/** 报价用的兑换成本（基点）：实时报价时 = 实际成本 + 余量并限制范围；不能实时报价时 = cfg.swapCostBps */
export async function feedSwapBps(ctx, dir, amount) {
  const q = await quoteSwapCost(ctx, dir, amount);
  return { ...q, bps: q.quoted ? feedBps(q.rawBps, ctx.cfg.swapFeed) : q.rawBps };
}
