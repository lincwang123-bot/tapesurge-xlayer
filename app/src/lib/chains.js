// 支持的网络和部署地址。地址由 scripts/sync-contracts.mjs 从 contracts/deployments 同步过来。
import { createPublicClient, fallback, http } from 'viem';
import { bsc, bscTestnet, foundry, xLayer, xLayerTestnet } from 'viem/chains';
import { DEFAULT_RPCS, rpcList } from './rpcs.js';
import { XLAYER_SWAP } from './zap.js';

const found = import.meta.glob('../deployments/*.json', { eager: true, import: 'default' });
const deployments = {};
for (const [path, dep] of Object.entries(found)) {
  // X Layer 的部署文件（xlayer/contracts/deployments）里 v2 单例用的是短名字，换成和 BSC 相同的键名，页面代码共用
  const x = dep.hub && !dep.factory;
  deployments[Number(path.match(/(\d+)\.json$/)[1])] = x
    ? { ...dep, positionExchange: dep.exchange, monthSales: dep.sales, monthPositions: dep.positions, monthGovernor: dep.governor }
    : dep;
}

const env = import.meta.env ?? {};

/**
 * family：'bsc' 是 BSC 版（标准局 + 月局，矿机是 PoD）；'xlayer' 是 X Layer 版（只有月局，矿机是 RIG 凭证，
 * 自带 RIG 矿机市场，注册中心是 XHub，部署文件里有 hub 没有 factory）。
 */
export const NETWORKS = {
  56: {
    id: 56,
    family: 'bsc',
    native: 'BNB',
    chain: bsc,
    testnet: false,
    name: 'BNB Chain',
    rpcs: rpcList(env.VITE_RPC_56, DEFAULT_RPCS[56]),
    explorer: 'https://bscscan.com',
    logChunk: 40_000n,
  },
  97: {
    id: 97,
    family: 'bsc',
    native: 'BNB',
    chain: bscTestnet,
    testnet: true,
    name: 'BSC Testnet',
    rpcs: rpcList(env.VITE_RPC_97, DEFAULT_RPCS[97]),
    explorer: 'https://testnet.bscscan.com',
    logChunk: 40_000n,
  },
  196: {
    id: 196,
    family: 'xlayer',
    native: 'OKB',
    chain: { ...xLayer, name: 'X Layer' },
    testnet: false,
    name: 'X Layer',
    rpcs: rpcList(env.VITE_RPC_196, DEFAULT_RPCS[196]),
    explorer: 'https://web3.okx.com/explorer/x-layer',
    logChunk: 100n, // X Layer 节点一次 eth_getLogs 最多查 100 个区块（2026-10-29 测试网实测）
    swap: XLAYER_SWAP, // 一键兑换（lib/zap.js）
  },
  1952: {
    id: 1952,
    family: 'xlayer',
    native: 'OKB',
    chain: { ...xLayerTestnet, name: 'X Layer Testnet' },
    testnet: true,
    name: 'X Layer Testnet',
    rpcs: rpcList(env.VITE_RPC_1952, DEFAULT_RPCS[1952]),
    explorer: 'https://web3.okx.com/explorer/x-layer-testnet',
    logChunk: 100n, // 一次 eth_getLogs 最多 100 个区块，超出报 "block range greater than 100 max"
    // 测试网没有真实的 BEM 池：用部署记录里的模拟路由 zapRouter（接口同 SwapRouter02，汇率同测试网报价），只有 OKB，没有 USDT
    swap: { mock: true, bemFee: 10_000 },
  },
};

// 本地 anvil：只在开发时打开（VITE_ENABLE_LOCAL=1），正式构建不会出现
if (env.VITE_ENABLE_LOCAL === '1') {
  NETWORKS[31337] = {
    id: 31337,
    family: 'bsc',
    native: 'BNB',
    chain: { ...foundry, contracts: { multicall3: { address: '0xcA11bde05977b3631167028862bE2a173976CA11' } } },
    testnet: true,
    name: 'Local',
    rpcs: rpcList(env.VITE_RPC_31337, ['http://127.0.0.1:8547']),
    explorer: 'http://127.0.0.1',
    logChunk: 100_000n,
  };
}

/** BSC 主网部署之后，正式版只显示 BSC 主网（项目方 2026-10-26 决定：BSC 测试网不再维护）；VITE_ENABLE_TESTNET=1 时测试网照常显示 */
export const MAINNET_ONLY = !!deployments[56]?.factory && env.VITE_ENABLE_TESTNET !== '1';

/** X Layer 版（参赛用的测试网 1952，以后的主网 196）：有部署文件就显示；VITE_DISABLE_XLAYER=1 时不显示 */
const XLAYER_ON = env.VITE_DISABLE_XLAYER !== '1';

function shown(n) {
  const dep = deployments[n.id];
  if (n.family === 'xlayer') return XLAYER_ON && !!dep?.hub;
  return !!dep?.factory && !(MAINNET_ONLY && n.testnet);
}

/** 已经部署了协议的网络（有地址文件的才显示；BSC 主网上线后 BSC 只剩主网） */
export const AVAILABLE = Object.values(NETWORKS).filter(shown);

export function deploymentOf(chainId) {
  return deployments[chainId] ?? null;
}

/** 默认网络：构建时可以用 VITE_DEFAULT_CHAIN 指定；否则有主网用主网，没有就用测试网 */
export function defaultChainId() {
  const want = Number(env.VITE_DEFAULT_CHAIN);
  if (AVAILABLE.some((n) => n.id === want)) return want;
  if (AVAILABLE.some((n) => n.id === 56)) return 56;
  return AVAILABLE[0]?.id ?? 97;
}

const clients = {};
export function publicClientOf(chainId) {
  const net = NETWORKS[chainId];
  if (!clients[chainId]) {
    clients[chainId] = createPublicClient({
      chain: net.chain,
      transport: fallback(net.rpcs.map((url) => http(url, { batch: { wait: 16 }, retryCount: 2, timeout: 20_000 }))),
      batch: { multicall: { wait: 16 } },
    });
  }
  return clients[chainId];
}

 /**
 * 查日志专用的连接：不合并批量请求。X Layer 测试网节点处理不了一批里的多条 eth_getLogs（返回的格式不对，viem 解析时报
 * "Cannot read properties of undefined (reading 'error')"，2026-10-29 实测），并发查日志时要一条一条发。
 */
const logClients = {};
export function logClientOf(chainId) {
  const net = NETWORKS[chainId];
  if (!logClients[chainId]) {
    logClients[chainId] = createPublicClient({
      chain: net.chain,
      transport: fallback(net.rpcs.map((url) => http(url, { retryCount: 2, timeout: 20_000 }))),
    });
  }
  return logClients[chainId];
}

export const explorerTx = (chainId, hash) => `${NETWORKS[chainId].explorer}/tx/${hash}`;
export const explorerAddr = (chainId, addr) => `${NETWORKS[chainId].explorer}/address/${addr}`;
