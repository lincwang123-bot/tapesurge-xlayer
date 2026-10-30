// 在 X Layer 主网分叉上实测一键兑换（src/lib/zap.js）：用 dApp 生成的同一批交易步骤调用真实的 Oku SwapRouter02。
// 只在本地分叉上发交易，不碰主网。用法：
//   anvil --fork-url https://rpc.xlayer.tech --port 8551
//   node scripts/zap-fork-check.mjs http://127.0.0.1:8551
// 检查：OKB 买到的 BEM 正好是要的数、多付的 OKB 退回、路由里不留钱；USDT 两跳买 BEM；BEM 卖回 OKB / USDT 不低于下限；
// 每一步把估价和实际成交对比打印出来（估价不含价格冲击，用来校准滑点上限）。
import { createPublicClient, createWalletClient, defineChain, erc20Abi, formatUnits, http, parseEther } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { RouterAbi, XLAYER_SWAP, buySteps, quoteBuy, quoteSell, sellSteps, spotPrices } from '../src/lib/zap.js';

const RPC = process.argv[2] ?? 'http://127.0.0.1:8551';
const BEM = '0x60e62Efa9405d6873C5deaBD4E6CC91c25363952';
// anvil 默认的第 0 个测试账户（公开的测试私钥，只在本地分叉上有余额）
const account = privateKeyToAccount('0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80');
const chain = defineChain({ id: 196, name: 'X Layer fork', nativeCurrency: { name: 'OKB', symbol: 'OKB', decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
const pub = createPublicClient({ chain, transport: http(RPC) });
const wallet = createWalletClient({ account, chain, transport: http(RPC) });
const cfg = { ...XLAYER_SWAP, bem: BEM, native: 'OKB' };
const bal = (token) => pub.readContract({ address: token, abi: erc20Abi, functionName: 'balanceOf', args: [account.address] });
const okb = () => pub.getBalance({ address: account.address });

async function run(steps) {
  let gasCost = 0n;
  for (const s of steps) {
    const { request } = await pub.simulateContract({ account, address: s.address, abi: s.abi, functionName: s.functionName, args: s.args, value: s.value });
    const hash = await wallet.writeContract(request);
    const r = await pub.waitForTransactionReceipt({ hash });
    if (r.status !== 'success') throw new Error(`${s.label} reverted`);
    gasCost += r.gasUsed * r.effectiveGasPrice;
  }
  return gasCost;
}

let failed = 0;
const check = (ok, msg) => {
  console.log(`${ok ? '✓' : '✗'} ${msg}`);
  if (!ok) failed++;
};
const pct = (a, b) => `${((Number(a) / Number(b) - 1) * 100).toFixed(3)}%`;

const prices = await spotPrices(pub, cfg);
console.log(`现价：1 OKB = ${formatUnits(prices.bemPerNative, 8)} BEM，1 OKB = ${formatUnits(prices.stablePerNative, 6)} USDT`);

// 1. OKB 刚好买到 4.04 BEM（最高投入 4 BEM + 1% 入场费）
{
  const need = 404_000_000n;
  const q = quoteBuy(prices, cfg, need, 'native');
  const [b0, o0] = [await bal(BEM), await okb()];
  const gas = await run(buySteps({ cfg, account: account.address, need, payWith: 'native', max: q.max, zh: true }));
  const got = (await bal(BEM)) - b0;
  const paid = o0 - (await okb()) - gas;
  check(got === need, `OKB → BEM：收到 ${formatUnits(got, 8)} BEM（要 ${formatUnits(need, 8)}）`);
  check(paid <= q.max, `付了 ${formatUnits(paid, 18)} OKB，估价 ${formatUnits(q.est, 18)}（实际比估价 ${pct(paid, q.est)}），上限 ${formatUnits(q.max, 18)}`);
  check((await pub.getBalance({ address: cfg.router })) === 0n, '多付的 OKB 已退回，路由里没留 OKB');
}

// 2. USDT 两跳买 1.01 BEM：先在分叉上用 OKB 换一些 USD₮0
{
  await run([
    {
      label: 'get USDT',
      address: cfg.router,
      abi: RouterAbi,
      functionName: 'exactInputSingle',
      args: [{ tokenIn: cfg.wrapped, tokenOut: cfg.stable.address, fee: cfg.stable.fee, recipient: account.address, amountIn: parseEther('2'), amountOutMinimum: 0n, sqrtPriceLimitX96: 0n }],
      value: parseEther('2'),
    },
  ]);
  const need = 101_000_000n;
  const q = quoteBuy(prices, cfg, need, 'stable');
  const [b0, u0] = [await bal(BEM), await bal(cfg.stable.address)];
  await run(buySteps({ cfg, account: account.address, need, payWith: 'stable', max: q.max, zh: true }));
  const got = (await bal(BEM)) - b0;
  const paid = u0 - (await bal(cfg.stable.address));
  check(got === need, `USDT → OKB → BEM：收到 ${formatUnits(got, 8)} BEM（要 ${formatUnits(need, 8)}）`);
  check(paid <= q.max, `付了 ${formatUnits(paid, 6)} USDT，估价 ${formatUnits(q.est, 6)}（实际比估价 ${pct(paid, q.est)}），上限 ${formatUnits(q.max, 6)}`);
}

// 3. 卖 2 BEM 换回 OKB
{
  const amount = 200_000_000n;
  const q = quoteSell(prices, cfg, amount, 'native');
  const o0 = await okb();
  const gas = await run(sellSteps({ cfg, account: account.address, amount, receive: 'native', min: q.min, zh: true }));
  const got = (await okb()) + gas - o0;
  check(got >= q.min, `BEM → OKB：收到 ${formatUnits(got, 18)} OKB，估价 ${formatUnits(q.est, 18)}（实际比估价 ${pct(got, q.est)}），下限 ${formatUnits(q.min, 18)}`);
  check((await pub.readContract({ address: cfg.wrapped, abi: erc20Abi, functionName: 'balanceOf', args: [cfg.router] })) === 0n, '路由里没留 WOKB');
}

// 4. 卖 1 BEM 换 USDT
{
  const amount = 100_000_000n;
  const q = quoteSell(prices, cfg, amount, 'stable');
  const u0 = await bal(cfg.stable.address);
  await run(sellSteps({ cfg, account: account.address, amount, receive: 'stable', min: q.min, zh: true }));
  const got = (await bal(cfg.stable.address)) - u0;
  check(got >= q.min, `BEM → OKB → USDT：收到 ${formatUnits(got, 6)} USDT，估价 ${formatUnits(q.est, 6)}（实际比估价 ${pct(got, q.est)}），下限 ${formatUnits(q.min, 6)}`);
}

console.log(failed ? `\n${failed} 项没通过` : '\n全部通过');
process.exit(failed ? 1 : 0);
