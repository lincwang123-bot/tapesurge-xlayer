// 前端默认连接的公共 RPC。chains.js 用它连链，vite.config.js 用它生成内容安全策略的 connect-src（两处必须一致）。
// 构建时可以用 VITE_RPC_56 / VITE_RPC_97 / VITE_RPC_196 / VITE_RPC_1952（逗号分隔）换掉。
export const DEFAULT_RPCS = {
  56: ['https://bsc-rpc.publicnode.com', 'https://bsc-dataseed.bnbchain.org'],
  97: ['https://bsc-testnet-rpc.publicnode.com', 'https://data-seed-prebsc-1-s1.bnbchain.org:8545'],
  // X Layer（OKX 官方节点；测试网节点的状态偶尔落后几个区块，页面读数以刷新后为准）
  196: ['https://rpc.xlayer.tech', 'https://xlayerrpc.okx.com'],
  1952: ['https://testrpc.xlayer.tech', 'https://xlayertestrpc.okx.com'],
};

export const rpcList = (custom, defaults) => (custom ? custom.split(',').map((s) => s.trim()).filter(Boolean) : defaults);
