// ABI 由 scripts/sync-contracts.mjs 同步：BSC 版在 abi/，X Layer 版在 abi/xlayer/。
// 启动时按网络调用一次 initAbi()，之后各模块直接用 ABI.xxx。
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { parseAbi } from 'viem';
import { ROOT } from './config.js';

const load = (name) => JSON.parse(readFileSync(join(ROOT, 'abi', `${name}.json`), 'utf8'));

export const ABI = {};

/**
 * network：'bsc' 或 'xlayer'；bscVersion：'v1'（v1.5 部署）或 'v2'（部署文件里有 monthSales）。
 * BSC 两代共用标准局、工厂、分账合约的 ABI（v2 只改月局），月局和卖矿合约按代加载。
 */
export function initAbi(network, bscVersion = 'v1') {
  for (const k of Object.keys(ABI)) delete ABI[k];
  if (network === 'xlayer') {
    Object.assign(ABI, {
      hub: load('xlayer/XHub'), // 注册中心：创世、哨兵、运营地址（BSC 版这些在标准局工厂里）
      monthFactory: load('xlayer/XMonthFactory'),
      month: load('xlayer/XMonthBoard'),
      splitter: load('xlayer/GenesisSplitter'),
      drand: load('xlayer/DrandEvmnetAdapter'),
      rig: load('xlayer/MockRig'), // 只在测试网用：claim(ids) 模拟 BSC 金库收取 + LayerZero 送达
      // v2：交接、分批推送、挂单在卖矿单例；集体清算在治理合约（和 BSC v2 同名同参，boards.js 共用）
      ...(existsSync(join(ROOT, 'abi', 'xlayer', 'XMonthMachineSales.json'))
        ? {
            monthSales: load('xlayer/XMonthMachineSales'),
            monthPositions: load('xlayer/XMonthPositions'),
            monthGovernor: load('xlayer/XMonthExitGovernor'),
            exchange: load('xlayer/XPositionExchange'),
            // X Layer 上的行情转报合约；不叫 priceFeed，免得 BSC 的报价任务把它当成自己的
            xFeed: load('xlayer/XMarketPriceFeed'),
            // BSC 主网的报价合约（只读 bid / ask / catchingUp / fresh），转报来源
            bscFeed: load('v2/MarketPriceFeed'),
          }
        : {}),
      // 2026-10-29 起：X Layer 上的 RIG 矿机市场（卖单、统一买单，嵌进月局的买入和卖出）
      ...(existsSync(join(ROOT, 'abi', 'xlayer', 'XRigMarket.json')) ? { rigMarket: load('xlayer/XRigMarket') } : {}),
    });
  } else {
    const v = bscVersion;
    Object.assign(ABI, {
      std: load(`${v}/TapeBoard`),
      month: load(`${v}/MonthBoard`),
      factory: load(`${v}/BoardFactory`),
      hub: load(`${v}/BoardFactory`), // BSC 版的注册中心就是标准局工厂
      monthFactory: load(`${v}/MonthFactory`),
      splitter: load(`${v}/GenesisSplitter`),
      vrfAdapter: load(`${v}/ChainlinkVRFAdapter`),
      mockRandom: load(`${v}/MockRandomSource`),
      ...(v === 'v2'
        ? {
            monthSales: load('v2/MonthMachineSales'),
            monthPositions: load('v2/MonthPositions'),
            monthGovernor: load('v2/MonthExitGovernor'),
            exchange: load('v2/PositionExchange'),
            // v2.0-rc3：两种局共用的买一 / 卖一报价合约、标准局卖矿合约，和链上 TWAP 预言机（换算 BNB → BEM）
            priceFeed: load('v2/MarketPriceFeed'),
            stdSales: load('v2/StdMachineSales'),
            oracle: load('v2/PancakeV3TwapOracle'),
            // v2.0-rc5：FirstoTrader（吃 Firsto 卖单 / 卖给 Firsto 统一买单）；测试网的 mock 统一买单
            ...(existsSync(join(ROOT, 'abi', 'v2', 'FirstoTrader.json'))
              ? { firstoTrader: load('v2/FirstoTrader'), mockFirstoBids: load('v2/MockFirstoBidExchange') }
              : {}),
            // v2.0-rc8：多来源交易模块、挂单模块、矿机合集规则
            ...(existsSync(join(ROOT, 'abi', 'v2', 'MarketTrader.json'))
              ? { marketTrader: load('v2/MarketTrader'), machineLister: load('v2/MachineLister'), machineRules: load('v2/MachineRules') }
              : {}),
          }
        : {}),
    });
  }
  return ABI;
}

// Chainlink VRF v2.5 协调器：只用到查询订阅余额
export const COORDINATOR_ABI = parseAbi([
  'function getSubscription(uint256 subId) view returns (uint96 balance, uint96 nativeBalance, uint64 reqCount, address subOwner, address[] consumers)',
]);
