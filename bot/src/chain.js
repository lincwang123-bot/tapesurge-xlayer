// 链上读写。每笔交易都先模拟：模拟不过就不发，只记下合约给的原因（大多数是"时间还没到"这类正常情况）。
import { BaseError, ContractFunctionRevertedError, createPublicClient, createWalletClient, decodeErrorResult, defineChain, encodeFunctionData, fallback, formatGwei, http } from 'viem';
import { bsc, bscTestnet, foundry } from 'viem/chains';
import { ABI } from './abi.js';
import * as log from './log.js';

// X Layer：自己定义，不依赖 viem 内置表里的测试网编号（X Layer 测试网 2025 年从 195 换成了 1952）
const okb = { name: 'OKB', symbol: 'OKB', decimals: 18 };
const multicall3 = { multicall3: { address: '0xcA11bde05977b3631167028862bE2a173976CA11' } };
const xLayer = defineChain({ id: 196, name: 'X Layer', nativeCurrency: okb, rpcUrls: { default: { http: ['https://rpc.xlayer.tech'] } }, contracts: multicall3 });
const xLayerTestnet = defineChain({
  id: 1952,
  name: 'X Layer Testnet',
  nativeCurrency: okb,
  rpcUrls: { default: { http: ['https://testrpc.xlayer.tech'] } },
  contracts: multicall3,
  testnet: true,
});

// 本地链（anvil）：分叉时自带 Multicall3；全新的 anvil 需要先用 anvil_setCode 把 Multicall3 放到同一地址
const local = defineChain({ ...foundry, contracts: multicall3 });

export function makeClients(cfg) {
  const chain = { 56: bsc, 97: bscTestnet, 196: xLayer, 1952: xLayerTestnet, 31337: local }[cfg.chainId];
  const transport = fallback(cfg.rpcs.map((url) => http(url, { retryCount: 2, timeout: 30_000 })));
  const pub = createPublicClient({ chain, transport, batch: { multicall: { wait: 10 } } });
  const wallet = cfg.account ? createWalletClient({ account: cfg.account, chain, transport }) : null;
  // 防夹子节点只用来发已签名的交易
  const priv = cfg.sendRpcs?.length ? createPublicClient({ chain, transport: fallback(cfg.sendRpcs.map((url) => http(url, { retryCount: 1, timeout: 15_000 }))) }) : null;
  // X Layer：只读 BSC 主网（转报报价合约的买一 / 卖一），不在 BSC 上签名
  const bscReader = cfg.network === 'xlayer' && cfg.bscRpcs?.length
    ? createPublicClient({ chain: bsc, transport: fallback(cfg.bscRpcs.map((url) => http(url, { retryCount: 2, timeout: 30_000 }))), batch: { multicall: { wait: 10 } } })
    : null;
  return { chain, pub, wallet, priv, bsc: bscReader };
}

// 所有合约的自定义错误合在一起，用来解码任何一处的 revert（按网络加载 ABI 之后才能算，所以用到时再算）
let allErrors = null;
function errorAbi() {
  if (!allErrors) {
    const seen = new Set();
    allErrors = Object.values(ABI)
      .flat()
      .filter((x) => x.type === 'error' && !seen.has(x.name) && seen.add(x.name));
  }
  return allErrors;
}

export function errorName(err) {
  if (!(err instanceof BaseError)) return err?.message ?? String(err);
  const r = err.walk((e) => e instanceof ContractFunctionRevertedError);
  if (r?.data?.errorName) return r.data.errorName;
  const raw = err.walk((e) => typeof e?.data === 'string' && e.data.startsWith('0x') && e.data.length >= 10)?.data;
  if (raw) {
    try {
      return decodeErrorResult({ abi: errorAbi(), data: raw }).errorName;
    } catch {
      /* 解不出来就用原始信息 */
    }
  }
  return r?.reason ?? err.shortMessage ?? err.message;
}

/**
 * gas 上限：估算值 × 1.25，至少多留 3 万（见 Sender.send）。
 * X Layer：估算值 × 2，至少多留 10 万。测试网公共节点的状态会落后几个区块：2026-10-29 机器人刚收取完 RIG 产出就发 harvest，
 * gas 按收取之前的状态估成 87,321，上链后用光失败（重发的那笔实际用 100,273）。X Layer 只按实际用量收费，多留不花钱。
 */
export function gasWithBuffer(estimate, { pct = 125n, minExtra = 30_000n } = {}) {
  const buffered = (estimate * pct) / 100n;
  return buffered - estimate < minExtra ? estimate + minExtra : buffered;
}

export const XLAYER_GAS_BUFFER = { pct: 200n, minExtra: 100_000n };

/**
 * 下一笔交易的 nonce：取"待处理"和"已确认"两种查询里较大的那个。X Layer 测试网的公共节点有时把待处理 nonce 报成 0
 * （2026-10-29 实测：同一时刻已确认 195、待处理 0），viem 默认只用待处理的，结果每笔都报 nonce too low。
 * 机器人一笔一笔发、每笔等回执，所以已确认的 nonce 就是下一笔要用的。
 */
export function nextNonce(pending, latest) {
  return pending > latest ? pending : latest;
}

export class Sender {
  constructor(cfg, clients, alert) {
    this.cfg = cfg;
    this.pub = clients.pub;
    this.wallet = clients.wallet;
    this.priv = clients.priv ?? null;
    this.alert = alert;
    this.sent = 0;
    this.spentWei = 0n;
  }

  get from() {
    return this.cfg.account?.address ?? this.cfg.readAs ?? undefined;
  }

  async nonce() {
    const address = this.cfg.account.address;
    const [pending, latest] = await Promise.all([
      this.pub.getTransactionCount({ address, blockTag: 'pending' }),
      this.pub.getTransactionCount({ address, blockTag: 'latest' }),
    ]);
    return nextNonce(pending, latest);
  }

  /** 只模拟：返回 { ok, result, reason } */
  async check(address, abi, functionName, args = []) {
    try {
      const { result, request } = await this.pub.simulateContract({ account: this.from, address, abi, functionName, args });
      return { ok: true, result, request };
    } catch (e) {
      return { ok: false, reason: errorName(e) };
    }
  }

  /**
   * 防夹子发送：本地签名后把同一笔交易发给防夹子节点（不进公开交易池，夹子看不到）；那边发不出去就直接发到普通节点。
   * 返回 { hash, raw }，raw 留着：60 秒还没上链时由 send 把同一笔再发到普通节点（同一个哈希，不会执行两次）。
   */
  async sendPrivate(request, gasPrice, gas, nonce) {
    const { abi, functionName, args, address, value } = request;
    const tx = await this.wallet.prepareTransactionRequest({
      account: this.cfg.account,
      to: address,
      data: encodeFunctionData({ abi, functionName, args }),
      value,
      gasPrice,
      gas,
      nonce,
    });
    const raw = await this.wallet.signTransaction(tx);
    try {
      return { hash: await this.priv.sendRawTransaction({ serializedTransaction: raw }), raw };
    } catch (e) {
      log.warn('private RPC failed, sending publicly', { reason: errorName(e) });
      return { hash: await this.pub.sendRawTransaction({ serializedTransaction: raw }), raw: null };
    }
  }

  /**
   * 模拟 → 检查 gas 价格 → 签名发送 → 等回执。
   * 模拟失败返回 { sent: false, reason }，不算错误；上链后 revert 才报警。
   * private：会经 PancakeSwap 兑换的交易（买卖矿机、回购）走防夹子节点，没配置时照常发。
   */
  async send(label, address, abi, functionName, args = [], { quiet = false, private: viaPrivate = false } = {}) {
    const sim = await this.check(address, abi, functionName, args);
    if (!sim.ok) {
      if (!quiet) log.info(`skip ${label}`, { reason: sim.reason });
      return { sent: false, reason: sim.reason };
    }
    if (this.cfg.dryRun || !this.wallet) {
      log.action(`[dry-run] would send ${label}`, { to: address, fn: functionName, args });
      return { sent: false, dryRun: true };
    }
    const gasPrice = await this.pub.getGasPrice();
    if (Number(formatGwei(gasPrice)) > this.cfg.maxGasGwei) {
      log.warn(`gas too high, postpone ${label}`, { gwei: formatGwei(gasPrice), max: this.cfg.maxGasGwei });
      return { sent: false, reason: 'GasTooHigh' };
    }
    try {
      // 用本地账户签名（模拟时传的是地址，直接透传会变成让节点代签）
      // gas 上限 = 估算 × 1.25：节点估出来的是"刚好够"，多层调用（兑换、闪电兑换、PoD 领取）里状态稍有变化就会耗尽 gas 失败
      // （2026-10-26 主网分叉演练：splitter buyback 按估算值 798,837 上链后 ReentrancySentryOOG）。没用完的 gas 不收费
      const estimate = await this.pub.estimateGas({ account: this.cfg.account, to: address, data: encodeFunctionData({ abi, functionName, args }), value: sim.request.value });
      const gas = gasWithBuffer(estimate, this.cfg.network === 'xlayer' ? XLAYER_GAS_BUFFER : undefined);
      let hash;
      let raw = null;
      const nonce = await this.nonce();
      if (viaPrivate && this.priv) ({ hash, raw } = await this.sendPrivate(sim.request, gasPrice, gas, nonce));
      else hash = await this.wallet.writeContract({ ...sim.request, account: this.cfg.account, gasPrice, gas, nonce });
      let receipt = null;
      if (raw) {
        receipt = await this.pub.waitForTransactionReceipt({ hash, timeout: 60_000 }).catch(() => null);
        if (!receipt) {
          log.warn(`private tx not mined in 60 s, rebroadcasting publicly: ${label}`, { hash });
          await this.pub.sendRawTransaction({ serializedTransaction: raw }).catch((e) => log.warn('public rebroadcast', { reason: errorName(e) }));
        }
      }
      receipt ??= await this.pub.waitForTransactionReceipt({ hash, timeout: 180_000 });
      const fee = receipt.gasUsed * (receipt.effectiveGasPrice ?? gasPrice);
      this.sent += 1;
      this.spentWei += fee;
      if (receipt.status !== 'success') {
        log.error(`reverted ${label}`, { hash, gasUsed: receipt.gasUsed });
        await this.alert.send(`tx:${label}`, `❌ 交易上链后失败：${label}\n${hash}`);
        return { sent: true, ok: false, hash };
      }
      log.action(label, { hash, gasUsed: receipt.gasUsed, fee: `${Number(fee) / 1e18} ${this.cfg.native}` });
      return { sent: true, ok: true, hash, receipt };
    } catch (e) {
      log.error(`send failed ${label}`, { reason: errorName(e) });
      await this.alert.send(`send:${label}`, `❌ 发送失败：${label}\n${errorName(e)}`);
      return { sent: false, reason: errorName(e) };
    }
  }
}
