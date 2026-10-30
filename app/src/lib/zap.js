// 一键兑换（2026-10-29 项目方决定：让手里只有 OKB / USDT 的人也能加入，结算后能换回去）。
// 主网直接调用链上的 Uniswap 式路由（X Layer：Oku SwapRouter02，BEM/WOKB 1% 池；USDT 先换成 OKB 再换 BEM）；
// X Layer 测试网没有真实的 BEM 池，调用接口相同的模拟路由 MockZapRouter（xlayer/contracts/src/mocks/MockZapRouter.sol）。
// - 买：按"刚好换到所需的 BEM"兑换（exactOutput），最多付"估价 × (1 + 滑点上限)"；付原生币时多付的同一笔退回（refundETH）；
// - 卖：BEM 全部卖出（exactInput），最少收"估价 × (1 − 滑点上限)"；换原生币时先留在路由里再 unwrapWETH9 给自己。
// 估价用池子现价（测试网用模拟路由的固定汇率），不含价格冲击；真实成交价由路由按池子算，超出上下限就整笔回滚。
// 不用 JSON ABI，只用 parseAbi：这个文件在 Node 里也能直接引用（scripts/zap-fork-check.mjs 在主网分叉上实测）。
import { encodeFunctionData, encodePacked, erc20Abi, parseAbi } from 'viem';

/**
 * X Layer 主网：Oku SwapRouter02 + BEM/WOKB 1% 池（和分账合约回购用的同一个）；USDT 走 USD₮0/WOKB 0.05% 池。
 * 2026-10-29 只读核对：BEM 池约 2,553 BEM + 217 OKB；USD₮0/WOKB 0.05% 池约 1,629 WOKB（旧 USDT 0x1E4a… 的池子很浅，不用）。
 */
export const XLAYER_SWAP = {
  router: '0x4f0C28f5926AFDA16bf2506D5D9e57Ea190f9bcA',
  wrapped: '0xe538905cf8410324e03A5A23C1c177a474D59b2b',
  bemFee: 10_000,
  bemPool: '0x2CcF8aa17F5DF9Fb5D51C9de12135a913fF29f7A',
  stable: { address: '0x779Ded0c9e1022225f8E0630b35a9b54bE713736', symbol: 'USDT', decimals: 6, fee: 500, pool: '0xe3BE6A0137f1b0602Fc1a4841686f43B340a5082' },
};

/** SwapRouter02 的约定：收款人填 address(2) 表示先留在路由里 */
export const ADDRESS_THIS = '0x0000000000000000000000000000000000000002';
/** 滑点上限：2%（估价不含价格冲击；每人每局最多 4 BEM，相对池子很小） */
export const SLIPPAGE_BPS = 200n;
const FEE_UNIT = 1_000_000n;
const Q192 = 2n ** 192n;
const E18 = 10n ** 18n;

export const RouterAbi = parseAbi([
  'struct ExactInputSingleParams { address tokenIn; address tokenOut; uint24 fee; address recipient; uint256 amountIn; uint256 amountOutMinimum; uint160 sqrtPriceLimitX96; }',
  'struct ExactOutputSingleParams { address tokenIn; address tokenOut; uint24 fee; address recipient; uint256 amountOut; uint256 amountInMaximum; uint160 sqrtPriceLimitX96; }',
  'struct ExactInputParams { bytes path; address recipient; uint256 amountIn; uint256 amountOutMinimum; }',
  'struct ExactOutputParams { bytes path; address recipient; uint256 amountOut; uint256 amountInMaximum; }',
  'function exactInputSingle(ExactInputSingleParams params) payable returns (uint256 amountOut)',
  'function exactOutputSingle(ExactOutputSingleParams params) payable returns (uint256 amountIn)',
  'function exactInput(ExactInputParams params) payable returns (uint256 amountOut)',
  'function exactOutput(ExactOutputParams params) payable returns (uint256 amountIn)',
  'function multicall(uint256 deadline, bytes[] data) payable returns (bytes[] results)',
  'function refundETH() payable',
  'function unwrapWETH9(uint256 amountMinimum, address recipient) payable',
  'function WETH9() view returns (address)',
  'function bemPerNative() view returns (uint256)',
  'function reserve() view returns (uint256)',
  'error STF()',
]);
const PoolAbi = parseAbi([
  'function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool)',
  'function token0() view returns (address)',
]);

/**
 * 这个网络的兑换配置；没有时返回 null（界面不显示兑换）。
 * net.swap 是写死的主网地址；测试网（net.swap.mock）从部署记录读模拟路由地址，WOKB 从路由读。
 */
export async function zapConfig(client, net, dep) {
  const s = net?.swap;
  if (!s || !dep?.bem) return null;
  if (s.mock) {
    if (!dep.zapRouter) return null;
    const wrapped = await client.readContract({ address: dep.zapRouter, abi: RouterAbi, functionName: 'WETH9' });
    return { router: dep.zapRouter, wrapped, bem: dep.bem, bemFee: s.bemFee, bemPool: null, stable: null, mock: true, native: net.native };
  }
  return { ...s, bem: dep.bem, native: net.native };
}

/** 池子现价：每 1e18 个 tokenB 最小单位能换多少 tokenA 最小单位（不含手续费） */
async function spotPerE18(client, pool, tokenA) {
  const [[sqrtP], token0] = await Promise.all([
    client.readContract({ address: pool, abi: PoolAbi, functionName: 'slot0' }),
    client.readContract({ address: pool, abi: PoolAbi, functionName: 'token0' }),
  ]);
  const p2 = sqrtP * sqrtP; // token1 / token0 = p2 / Q192
  return token0.toLowerCase() === tokenA.toLowerCase() ? (E18 * Q192) / p2 : (E18 * p2) / Q192;
}

/** 现价：{ bemPerNative, stablePerNative }（每 1 个原生币能换的 BEM / 稳定币最小单位） */
export async function spotPrices(client, cfg) {
  const bemPerNative = cfg.bemPool
    ? await spotPerE18(client, cfg.bemPool, cfg.bem)
    : await client.readContract({ address: cfg.router, abi: RouterAbi, functionName: 'bemPerNative' });
  const stablePerNative = cfg.stable ? await spotPerE18(client, cfg.stable.pool, cfg.stable.address) : null;
  return { bemPerNative, stablePerNative };
}

const ceilDiv = (a, b) => (a === 0n ? 0n : (a - 1n) / b + 1n);
const grossUp = (x, fee) => ceilDiv(x * FEE_UNIT, FEE_UNIT - BigInt(fee)); // 付款里扣掉池费后还剩 x
const net = (x, fee) => (x * (FEE_UNIT - BigInt(fee))) / FEE_UNIT;

/**
 * 买 need 个 BEM 要付多少：{ est, max }（payWith = 'native' | 'stable'，单位是付款币的最小单位）。
 * 原生币：need ÷ 现价，加 BEM 池费；稳定币：再换算成稳定币，加稳定币池费。max = est × (1 + 滑点上限)。
 */
export function quoteBuy(prices, cfg, need, payWith) {
  let est = grossUp(ceilDiv(need * E18, prices.bemPerNative), cfg.bemFee);
  if (payWith === 'stable') est = grossUp(ceilDiv(est * prices.stablePerNative, E18), cfg.stable.fee);
  return { est, max: (est * (10_000n + SLIPPAGE_BPS)) / 10_000n };
}

/** 卖 amount 个 BEM 能收多少：{ est, min }（receive = 'native' | 'stable'） */
export function quoteSell(prices, cfg, amount, receive) {
  let est = net((amount * E18) / prices.bemPerNative, cfg.bemFee);
  if (receive === 'stable') est = net((est * prices.stablePerNative) / E18, cfg.stable.fee);
  return { est, min: (est * (10_000n - SLIPPAGE_BPS)) / 10_000n };
}

const deadline = () => BigInt(Math.floor(Date.now() / 1000) + 20 * 60);
const call = (functionName, args) => encodeFunctionData({ abi: RouterAbi, functionName, args });

/**
 * 买 BEM 的交易步骤（交给 useTx().run）：稳定币要先授权给路由（按 max 精确授权），再兑换。
 * 原生币：multicall(exactOutputSingle, refundETH)，随交易附上 max，多付的退回。
 */
export function buySteps({ cfg, account, need, payWith, max, zh }) {
  if (payWith === 'stable') {
    const s = cfg.stable;
    // exactOutput 的路径从输出往回写：BEM ← WOKB ← 稳定币
    const path = encodePacked(['address', 'uint24', 'address', 'uint24', 'address'], [cfg.bem, cfg.bemFee, cfg.wrapped, s.fee, s.address]);
    return [
      {
        label: zh ? `授权 ${s.symbol}` : `Approve ${s.symbol}`,
        address: s.address,
        abi: erc20Abi,
        functionName: 'approve',
        args: [cfg.router, max],
      },
      {
        label: zh ? `用 ${s.symbol} 换 BEM` : `Swap ${s.symbol} for BEM`,
        address: cfg.router,
        abi: RouterAbi,
        functionName: 'multicall',
        args: [deadline(), [call('exactOutput', [{ path, recipient: account, amountOut: need, amountInMaximum: max }])]],
      },
    ];
  }
  const swap = call('exactOutputSingle', [
    { tokenIn: cfg.wrapped, tokenOut: cfg.bem, fee: cfg.bemFee, recipient: account, amountOut: need, amountInMaximum: max, sqrtPriceLimitX96: 0n },
  ]);
  return [
    {
      label: zh ? `用 ${cfg.native} 换 BEM` : `Swap ${cfg.native} for BEM`,
      address: cfg.router,
      abi: RouterAbi,
      functionName: 'multicall',
      args: [deadline(), [swap, call('refundETH', [])]],
      value: max,
    },
  ];
}

/** 卖 BEM 的交易步骤：先按数量精确授权 BEM 给路由，再兑换（原生币：先留在路由里，再 unwrapWETH9 给自己） */
export function sellSteps({ cfg, account, amount, receive, min, zh }) {
  const approve = {
    label: zh ? '授权 BEM' : 'Approve BEM',
    address: cfg.bem,
    abi: erc20Abi,
    functionName: 'approve',
    args: [cfg.router, amount],
  };
  if (receive === 'stable') {
    const s = cfg.stable;
    const path = encodePacked(['address', 'uint24', 'address', 'uint24', 'address'], [cfg.bem, cfg.bemFee, cfg.wrapped, s.fee, s.address]);
    return [
      approve,
      {
        label: zh ? `BEM 换 ${s.symbol}` : `Swap BEM for ${s.symbol}`,
        address: cfg.router,
        abi: RouterAbi,
        functionName: 'multicall',
        args: [deadline(), [call('exactInput', [{ path, recipient: account, amountIn: amount, amountOutMinimum: min }])]],
      },
    ];
  }
  const swap = call('exactInputSingle', [
    { tokenIn: cfg.bem, tokenOut: cfg.wrapped, fee: cfg.bemFee, recipient: ADDRESS_THIS, amountIn: amount, amountOutMinimum: 0n, sqrtPriceLimitX96: 0n },
  ]);
  return [
    approve,
    {
      label: zh ? `BEM 换 ${cfg.native}` : `Swap BEM for ${cfg.native}`,
      address: cfg.router,
      abi: RouterAbi,
      functionName: 'multicall',
      args: [deadline(), [swap, call('unwrapWETH9', [min, account])]],
    },
  ];
}
