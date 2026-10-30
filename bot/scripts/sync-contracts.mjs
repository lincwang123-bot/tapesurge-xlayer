// 从 ../contracts 同步 ABI 和部署地址。合约重新编译或重新部署之后运行：npm run sync
// 只读 contracts/，不写入。服务器上没有 contracts/ 时，把本机同步好的 abi/ 和 deployments/ 一起拷过去即可。
// 只同步 X Layer 版（不碰 BSC 的 abi/v1、abi/v2 和部署文件）：node scripts/sync-contracts.mjs --xlayer-only
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const xlayerOnly = process.argv.includes('--xlayer-only');
// CONTRACTS_DIR 可以指向别的合约目录（例如开发中某个提交导出的副本）
const contracts = process.env.CONTRACTS_DIR ?? join(root, '..', 'contracts');
mkdirSync(join(root, 'deployments'), { recursive: true });
// BSC 版有两代月局：v1.5（月局自己挂单、交接）和 v2（持仓凭证 + 单例卖矿合约）。按 out/ 里有没有
// MonthMachineSales 判断是哪一代，ABI 分别放在 abi/v1/ 和 abi/v2/，运行时按部署文件里有没有 monthSales 选择。
const version = existsSync(join(contracts, 'out', 'MonthMachineSales.sol', 'MonthMachineSales.json')) ? 'v2' : 'v1';
const abiOut = join(root, 'abi', version);
if (!xlayerOnly) mkdirSync(abiOut, { recursive: true });

const names = [
  ['TapeBoard', 'TapeBoard'],
  ['MonthBoard', 'MonthBoard'],
  ['BoardFactory', 'BoardFactory'],
  ['MonthFactory', 'MonthFactory'],
  ['GenesisSplitter', 'GenesisSplitter'],
  ['ChainlinkVRFAdapter', 'ChainlinkVRFAdapter'],
  ['MockRandom', 'MockRandomSource'],
  ...(version === 'v2'
    ? [
        ['MonthMachineSales', 'MonthMachineSales'],
        ['MonthPositions', 'MonthPositions'],
        ['MonthExitGovernor', 'MonthExitGovernor'],
        ['PositionExchange', 'PositionExchange'],
        ['MarketPriceFeed', 'MarketPriceFeed'],
        ['StdMachineSales', 'StdMachineSales'],
        ['PancakeV3TwapOracle', 'PancakeV3TwapOracle'],
        // v2.0-rc5：主板在 Firsto 上自动买卖矿机（规则 6.22）；测试网的统一买单是 mock，机器人从链上读买单
        ['FirstoTrader', 'FirstoTrader'],
        ['MockFirsto', 'MockFirstoBidExchange'],
        // v2.0-rc8 / rc9：多来源交易模块、挂单模块、矿机合集规则（规则 6.26 / 6.29）
        ['MarketTrader', 'MarketTrader'],
        ['MachineLister', 'MachineLister'],
        ['MachineRules', 'MachineRules'],
      ]
    : []),
];
const LEGACY = new Set(['FirstoTrader']);
for (const [file, contract] of xlayerOnly ? [] : names) {
  const p = join(contracts, 'out', `${file}.sol`, `${contract}.json`);
  if (!existsSync(p)) {
    // FirstoTrader 在 rc8 被 MarketTrader 取代、源码已删：保留 abi/ 里已有的旧文件（给 rc5–rc7 的旧部署用），不再更新
    if (LEGACY.has(contract)) {
      console.log(`abi ${version}/${contract}: 合约已删除，保留旧文件`);
      continue;
    }
    throw new Error(`缺少 ${p}，先在 contracts/ 里运行 forge build`);
  }
  const { abi } = JSON.parse(readFileSync(p, 'utf8'));
  writeFileSync(join(abiOut, `${contract}.json`), JSON.stringify(abi) + '\n');
  console.log(`abi ${version}/${contract}: ${abi.length} 项`);
}

// X Layer 版（../xlayer/contracts）：只有月局；随机数是 drand，矿机是 RIG 凭证
const xlayer = join(root, '..', 'xlayer', 'contracts');
if (existsSync(join(xlayer, 'out'))) {
  mkdirSync(join(root, 'abi', 'xlayer'), { recursive: true });
  for (const [file, contract] of [
    ['XHub', 'XHub'],
    ['XMonthFactory', 'XMonthFactory'],
    ['XMonthBoard', 'XMonthBoard'],
    ['GenesisSplitter', 'GenesisSplitter'],
    ['DrandEvmnetAdapter', 'DrandEvmnetAdapter'],
    ['MockRig', 'MockRig'],
    // v2（2026-10-27 起）：持仓凭证、盘口、集体清算、BSC 行情转报、卖矿单例
    ...(existsSync(join(xlayer, 'out', 'XMonthMachineSales.sol'))
      ? [
          ['XMonthPositions', 'XMonthPositions'],
          ['XPositionExchange', 'XPositionExchange'],
          ['XMonthExitGovernor', 'XMonthExitGovernor'],
          ['XMarketPriceFeed', 'XMarketPriceFeed'],
          ['XMonthMachineSales', 'XMonthMachineSales'],
        ]
      : []),
    // 2026-10-29 起：RIG 矿机市场
    ...(existsSync(join(xlayer, 'out', 'XRigMarket.sol')) ? [['XRigMarket', 'XRigMarket']] : []),
  ]) {
    const p = join(xlayer, 'out', `${file}.sol`, `${contract}.json`);
    if (!existsSync(p)) throw new Error(`缺少 ${p}，先在 xlayer/contracts/ 里运行 forge build`);
    const { abi } = JSON.parse(readFileSync(p, 'utf8'));
    writeFileSync(join(root, 'abi', 'xlayer', `${contract}.json`), JSON.stringify(abi) + '\n');
    console.log(`abi xlayer/${contract}: ${abi.length} 项`);
  }
  for (const chainId of ['1952', '196']) {
    const file = join(xlayer, 'deployments', `${chainId}.json`);
    if (!existsSync(file)) continue;
    writeFileSync(join(root, 'deployments', `${chainId}.json`), readFileSync(file, 'utf8'));
    console.log(`deployment ${chainId}: hub ${JSON.parse(readFileSync(file, 'utf8')).hub}`);
  }
}

for (const [chainId, script] of xlayerOnly
  ? []
  : [
      ['97', 'DeployTestnet.s.sol'],
      ['56', 'DeployMainnet.s.sol'],
      ['31337', 'DeployTestnet.s.sol'],
    ]) {
  const file = join(contracts, 'deployments', `${chainId}.json`);
  if (!existsSync(file)) continue;
  const dep = JSON.parse(readFileSync(file, 'utf8'));
  const run = join(contracts, 'broadcast', script, chainId, 'run-latest.json');
  if (dep.fromBlock == null && existsSync(run)) {
    const blocks = JSON.parse(readFileSync(run, 'utf8')).receipts.map((r) => parseInt(r.blockNumber, 16));
    if (blocks.length) dep.fromBlock = Math.min(...blocks);
  }
  writeFileSync(join(root, 'deployments', `${chainId}.json`), JSON.stringify(dep, null, 2) + '\n');
  console.log(`deployment ${chainId}: factory ${dep.factory}`);
}
