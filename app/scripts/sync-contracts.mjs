// 从 ../contracts 同步 ABI 和部署地址到 src/。合约改动或重新部署之后运行一次：npm run sync
// 只同步 X Layer 版（不碰 BSC 的 ABI 和部署文件）：node scripts/sync-contracts.mjs --xlayer-only
// 只读 contracts/out（forge build 的产物）和 contracts/deployments、contracts/broadcast，不写 contracts/ 里的任何文件。
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
// CONTRACTS_DIR 可以指向别的合约目录（例如开发中的某个提交导出的副本）
const contracts = process.env.CONTRACTS_DIR ?? join(root, '..', 'contracts');
const abiDir = join(root, 'src', 'abi');
const depDir = join(root, 'src', 'deployments');
const xlayerOnly = process.argv.includes('--xlayer-only');
mkdirSync(abiDir, { recursive: true });
mkdirSync(depDir, { recursive: true });

// TapeOut 的真实合约没有公开源码，晶体管和电路合约的 ABI 手写在 src/abi/tapeout.js；这里只同步本协议自己的合约。
const names = ['TapeBoard', 'MonthBoard', 'BoardFactory', 'MonthFactory', 'GenesisSplitter', 'MockBEM'];
// v2 月局新增的单例合约：持仓凭证、卖矿（以后还有交易所、清算治理）。没有就跳过，说明还是 v1.5
const optional = ['MonthPositions', 'MonthMachineSales', 'PositionExchange', 'MonthExitGovernor', 'StdMachineSales', 'MarketPriceFeed'];
for (const name of xlayerOnly ? [] : [...names, ...optional]) {
  const file = join(contracts, 'out', `${name}.sol`, `${name}.json`);
  if (!existsSync(file)) {
    if (optional.includes(name)) continue;
    throw new Error(`缺少 ${file}，先在 contracts/ 里运行 forge build`);
  }
  const { abi } = JSON.parse(readFileSync(file, 'utf8'));
  writeFileSync(join(abiDir, `${name}.json`), JSON.stringify(abi, null, 1) + '\n');
  console.log(`abi  ${name}: ${abi.length} 项`);
}

// 部署地址：deployments/<链 ID>.json；起始区块从 broadcast 记录里取（扫描通行证转账事件时用）
for (const [chainId, script] of xlayerOnly ? [] : [
  ['97', 'DeployTestnet.s.sol'],
  ['56', 'DeployMainnet.s.sol'],
  ['31337', 'DeployTestnet.s.sol'], // 本地 anvil，只在开发模式（VITE_ENABLE_LOCAL=1）下显示
]) {
  // BSC 测试网：v2 的部署记录另存为 97-v2.json（97.json 是 v1.5 的旧部署），有就优先用
  const v2 = join(contracts, 'deployments', `${chainId}-v2.json`);
  const file = existsSync(v2) ? v2 : join(contracts, 'deployments', `${chainId}.json`);
  if (!existsSync(file)) {
    console.log(`dep  ${chainId}: 还没有部署`);
    continue;
  }
  const dep = JSON.parse(readFileSync(file, 'utf8'));
  const run = join(contracts, 'broadcast', script, chainId, 'run-latest.json');
  if (existsSync(run)) {
    const { receipts } = JSON.parse(readFileSync(run, 'utf8'));
    const blocks = receipts.map((r) => parseInt(r.blockNumber, 16)).filter(Number.isFinite);
    if (blocks.length) dep.fromBlock = Math.min(...blocks);
  }
  writeFileSync(join(depDir, `${chainId}.json`), JSON.stringify(dep, null, 2) + '\n');
  console.log(`dep  ${chainId}: factory ${dep.factory}, fromBlock ${dep.fromBlock ?? '未知'}`);
}

// X Layer 版（../xlayer/contracts）：月局和 BSC v2 同名同参，页面直接用上面的 BSC ABI 调用；这里只同步 X Layer 特有的合约
// （RIG 矿机市场、测试网的模拟 RIG）和合并错误表用的 ABI，放在 src/abi/xlayer/。部署地址：1952（测试网）、196（主网）。
const xlayer = process.env.XLAYER_CONTRACTS_DIR ?? join(root, '..', 'xlayer', 'contracts');
if (existsSync(join(xlayer, 'out'))) {
  const xAbiDir = join(abiDir, 'xlayer');
  mkdirSync(xAbiDir, { recursive: true });
  for (const name of ['XRigMarket', 'MockRig', 'XHub', 'XMonthFactory', 'XMonthBoard', 'XMonthMachineSales', 'XPositionExchange']) {
    const file = join(xlayer, 'out', `${name}.sol`, `${name}.json`);
    if (!existsSync(file)) throw new Error(`缺少 ${file}，先在 xlayer/contracts/ 里运行 forge build`);
    const { abi } = JSON.parse(readFileSync(file, 'utf8'));
    writeFileSync(join(xAbiDir, `${name}.json`), JSON.stringify(abi, null, 1) + '\n');
    console.log(`abi  xlayer/${name}: ${abi.length} 项`);
  }
  for (const chainId of ['1952', '196']) {
    const file = join(xlayer, 'deployments', `${chainId}.json`);
    if (!existsSync(file)) {
      console.log(`dep  ${chainId}: 还没有部署`);
      continue;
    }
    const dep = JSON.parse(readFileSync(file, 'utf8'));
    writeFileSync(join(depDir, `${chainId}.json`), JSON.stringify(dep, null, 2) + '\n');
    console.log(`dep  ${chainId}: hub ${dep.hub}, market ${dep.market ?? '无'}, fromBlock ${dep.fromBlock ?? '未知'}`);
  }
}
