// 配置：全部来自环境变量（或 bot/.env）。私钥只在内存里用，任何日志都不会打印它。
import { existsSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { privateKeyToAccount } from 'viem/accounts';

export const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));

/** 读 bot/.env（KEY=VALUE，# 开头是注释）。已经在环境里设置的变量优先 */
function loadDotEnv() {
  const file = join(ROOT, '.env');
  if (!existsSync(file)) return;
  for (const line of readFileSync(file, 'utf8').split('\n')) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
    if (m && process.env[m[1]] === undefined) process.env[m[1]] = m[2].replace(/^['"]|['"]$/g, '');
  }
}

/** 从 KEY=VALUE 格式的文件里读一个变量（用于测试网的 contracts/.env.testnet） */
function readVar(file, name) {
  for (const line of readFileSync(file, 'utf8').split('\n')) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
    if (m && m[1] === name) return m[2].replace(/^['"]|['"]$/g, '');
  }
  return null;
}

const SUPPORTED = { 56: 'BNB Chain', 97: 'BSC Testnet', 196: 'X Layer', 1952: 'X Layer Testnet', 31337: 'Local' };
const MAINNETS = new Set([56, 196]);
const DEFAULT_RPC = { 97: 'https://bsc-testnet-rpc.publicnode.com', 196: 'https://rpc.xlayer.tech', 1952: 'https://testrpc.xlayer.tech' };
// 测试网一次性钱包文件只能用在对应的测试链（和本地 31337）上
const TESTNET_KEY_FILES = [
  [/\.env\.testnet$/, [97, 31337]],
  [/\.env\.xlayer-testnet$/, [1952, 31337]],
];

export function loadConfig(argv = process.argv.slice(2)) {
  loadDotEnv();
  const env = process.env;
  const chainId = Number(env.CHAIN_ID ?? 97);
  if (!SUPPORTED[chainId]) throw new Error(`CHAIN_ID=${chainId} 不支持（只支持 ${Object.keys(SUPPORTED).join(' / ')}）`);
  // 31337 用部署文件判断是哪个版本：X Layer 版有 hub、没有标准局工厂
  const network = chainId === 196 || chainId === 1952 ? 'xlayer' : 'bsc';

  const depFile = resolve(ROOT, env.DEPLOYMENT_FILE ?? `deployments/${chainId}.json`);
  if (!existsSync(depFile)) throw new Error(`找不到部署文件 ${depFile}，先运行 npm run sync`);
  const dep = JSON.parse(readFileSync(depFile, 'utf8'));
  const net = network === 'bsc' && dep.hub && !dep.factory ? 'xlayer' : network;
  const required = net === 'xlayer' ? ['hub', 'monthFactory', 'splitter', 'drandAdapter', 'rig'] : ['factory', 'monthFactory', 'splitter', 'randomSource'];
  for (const k of required) {
    if (!/^0x[0-9a-fA-F]{40}$/.test(dep[k] ?? '')) throw new Error(`部署文件缺少 ${k}`);
  }
  if (net === 'bsc') dep.hub ??= dep.factory; // BSC 版的注册中心就是标准局工厂
  // X Layer v2 的部署文件把卖矿单例叫 sales、治理合约叫 governor，换成 BSC 版的名字，boards.js 两边共用
  if (net === 'xlayer') {
    dep.monthSales ??= dep.sales;
    dep.monthGovernor ??= dep.governor;
  }

  const rpcs = (env.RPC_URLS ?? (chainId === 56 ? '' : DEFAULT_RPC[chainId] ?? 'http://127.0.0.1:8545'))
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  if (!rpcs.length) throw new Error('主网必须设置 RPC_URLS（建议付费节点，可以逗号分隔多个）');
  // 防夹子发送：会经 PancakeSwap 兑换的交易先发给这些节点，不进公开交易池。BSC 主网默认 PancakeSwap MEV Guard，
  // 备用 48 Club；SEND_RPC_URLS=off 关闭（例如在本地分叉上演练时，免得把交易发到真实主网）
  const sendRpcs = (env.SEND_RPC_URLS ?? (chainId === 56 ? 'https://bscrpc.pancakeswap.finance,https://rpc-bsc.48.club' : ''))
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s && s !== 'off');

  // X Layer：转报 BSC 主网报价合约的买一 / 卖一（只读 BSC，不在 BSC 上发交易）。测试网和本地也读 BSC 主网的真实值
  const bscRpcs = (env.BSC_RPC_URLS ?? 'https://bsc-rpc.publicnode.com,https://bsc-dataseed.bnbchain.org')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);

  const dryRun = argv.includes('--dry-run') || env.DRY_RUN === '1';
  const loaded = dryRun && !env.OPERATOR_KEY_FILE && !env.OPERATOR_PRIVATE_KEY ? null : loadAccount(env, chainId);
  const account = loaded?.account ?? null;
  if (account && dep.operator && account.address.toLowerCase() !== dep.operator.toLowerCase()) {
    console.warn(`⚠️ 机器人钱包 ${account.address} 和部署记录里的运营地址 ${dep.operator} 不一致`);
  }

  const cfg = {
    chainId,
    chainName: SUPPORTED[chainId],
    network: net,
    mainnet: MAINNETS.has(chainId),
    native: net === 'xlayer' ? 'OKB' : 'BNB',
    dep,
    rpcs,
    sendRpcs,
    account,
    readAs: account?.address ?? env.READ_AS ?? null,
    dryRun,
    once: argv.includes('--once'),
    // 测试网时间缩短时，每轮间隔也缩短（主网 60 秒）
    intervalSec: Number(env.INTERVAL_SEC ?? (!MAINNETS.has(chainId) && (dep.fast || Number(dep.timeDivisor ?? 1) > 1) ? 15 : 60)),
    maxGasGwei: Number(env.MAX_GAS_GWEI ?? 3),
    distributeBatch: BigInt(env.DISTRIBUTE_BATCH ?? 100),
    // 只用于 BSC v1.5 月局（BSC v2 和 X Layer 的矿机由合约按报价公式卖，不挂单）：结算时交接不了的矿机按
    // 成本价 ×（1 + 这个比例）挂单；0 = 不挂，结算开始 1 天后合约自动按成本价卖
    listPremiumBps: BigInt(env.LIST_PREMIUM_BPS ?? 0),
    // X Layer：链上最新区块时间落后本机时间超过这么多秒时，不发 drawPrizes（drand 锁定的是"链上时间 + 10 分钟"之后的轮次，
    // 链停机追块时那一轮可能已经公开）。本地 anvil 演练的链上时间本来就和本机不同，默认不检查；0 = 不检查
    maxChainLagSec: Number(env.MAX_CHAIN_LAG_SEC ?? (chainId === 31337 ? 0 : 60)),
    bscRpcs,
    // X Layer：BSC 报价合约地址（部署文件的 bscPriceFeed，可用环境变量覆盖）和转报间隔（合约要求两次至少隔 50 分钟）
    bscPriceFeed: env.BSC_PRICE_FEED ?? dep.bscPriceFeed ?? null,
    xFeedEverySec: Number(env.XFEED_EVERY_SEC ?? 3600),
    // X Layer：RIG 代理期望的实现地址（升级监控 rigWatch 用；不设时主网用 rigwatch.js 里的默认值，测试网和第一次看到的比）
    rigImplementation: rigImpl(env.RIG_IMPLEMENTATION ?? dep.rigImplementation),
    // Firsto 上没有求购时，买一按卖一减这个比例估（默认 9%）
    feedNoBidSpreadBps: BigInt(env.FEED_NO_BID_SPREAD_BPS ?? 900),
    // 经 Firsto 成交时 BEM ↔ BNB 兑换的成本（池子手续费 + 冲击）。报给链上的卖一 = Firsto 含费卖价 ×（1 + 它），
    // 买一 = Firsto 买单扣 1% 手续费后的净价 ×（1 − 它）：也就是主板经 Firsto 实际要付 / 能拿到的价（规则 6.22）。
    // 主网按每单金额用 QuoterV2 实时算（src/swapcost.js），这个值只在读不到报价时兜底；测试网 mock 兑换固定 0.5%。
    swapCostBps: BigInt(env.SWAP_COST_BPS ?? (MAINNETS.has(chainId) ? 150 : 50)),
    // 主网报价用的兑换成本 = 实际成本 + 余量，限制在 [下限, 上限]（FIRSTO-PROBE 6.3：+0.25%，1.2%–2%）
    swapFeed: {
      marginBps: BigInt(env.SWAP_FEED_MARGIN_BPS ?? 25),
      minBps: BigInt(env.SWAP_FEED_MIN_BPS ?? 120),
      maxBps: BigInt(env.SWAP_FEED_MAX_BPS ?? 200),
    },
    // 主网递单时在实际兑换成本上再留的余量（防止出块之间价格变动）
    swapTradeMarginBps: BigInt(env.SWAP_TRADE_MARGIN_BPS ?? 10),
    // 自动买卖：每轮最多买 / 卖几台，扫描间隔（秒），Firsto 卖单文件（测试网用，主网读接口）
    // 规则决定 6.37：收购改成从最便宜的挂单往上扫，每轮多买几台（每台都先模拟、逐笔发送）
    firstoMaxPerTick: Number(env.FIRSTO_MAX_PER_TICK ?? 10),
    firstoEverySec: Number(env.FIRSTO_EVERY_SEC ?? (MAINNETS.has(chainId) ? 300 : 60)),
    firstoAsksFile: env.FIRSTO_ASKS_FILE ?? null,
    // 测试网的模拟 tapeout.market：挂单流（格式同 /api/v1/circuit-market/feed）和 Seaport 卖单详情（orderHash → /api/v1/listings 的返回）
    tapeFeedFile: env.TAPE_FEED_FILE ?? null,
    tapeListingsFile: env.TAPE_LISTINGS_FILE ?? null,
    seaportOffersFile: env.SEAPORT_OFFERS_FILE ?? null, // 测试网的模拟 Seaport WBNB 出价
    // 主网：主板挂到 Seaport 的单是否提交给 tapeout.market 展示（往第三方接口发数据，上线时再打开）
    tapemarketSubmit: env.TAPEMARKET_SUBMIT === '1',
    // 主网：挂单库在 Firsto 上的签名卖单是否提交给 Firsto 接口（规则 6.30；往第三方接口发数据，上线时再打开）
    firstoSubmit: env.FIRSTO_SUBMIT === '1',
    // 测试网报价：买一 = 卖一 ×（1 − 这个比例），默认 1%（见 tasks/pricefeed.js 的 mockTargets）
    feedTestnetSpreadBps: BigInt(env.FEED_TESTNET_SPREAD_BPS ?? 100),
    // 主网报价保护（规则 6.36）：Firsto 日产能价（BNB）24 小时内累计变动超过这个比例就暂停自动报价，
    // 等项目方在服务器上运行 node scripts/feed-confirm.mjs 确认（写下面这个文件）后继续；0 = 不检查
    feedMaxDayChangeBps: BigInt(env.FEED_MAX_DAY_CHANGE_BPS ?? 1500),
    // 卖一 24 小时变动过大暂停后，逐步变动、新价位稳定 2 小时就自动恢复（tasks/pricefeed.js 的 autoResume；FEED_AUTO_RESUME=0 关掉，全部等人确认）
    feedAutoResume: env.FEED_AUTO_RESUME !== '0',
    feedAuto: {
      stepBps: BigInt(env.FEED_AUTO_STEP_BPS ?? 600), // 按小时取样，相邻两点最多变 6%
      stableSec: Number(env.FEED_AUTO_STABLE_SEC ?? 7_200), // 新价位稳定 2 小时
      stableBps: BigInt(env.FEED_AUTO_STABLE_BPS ?? 100), // 稳定 = 这段时间的读数都在当前价 1% 以内（匀速每小时跌 1.5% 不算稳定）
      hardBps: BigInt(env.FEED_AUTO_MAX_BPS ?? 3_000), // 24 小时累计超过 30% 一律等人确认
    },
    // 机器人买卖矿机时在 PancakeSwap 上换 BEM 的每小时上限（BEM 最小单位，8 位小数）：主网默认 80 BEM，约全市场成交量的 10%
    // （项目方 2026-10-26 决定，避免集中砸盘 / 拉盘）；BEM_HOURLY_CAP=0 不限。回购和回馈另有合约限制（每次 ≤ 0.5 BNB、间隔 ≥ 1 小时）
    bemHourlyCap: BigInt(Math.round(Number(env.BEM_HOURLY_CAP ?? (MAINNETS.has(chainId) ? 80 : 0)) * 1e8)),
    feedConfirmFile: resolve(ROOT, env.FEED_CONFIRM_FILE ?? `state/${chainId}.feed-confirm.json`),
    minOperatorBnb: Number(env.MIN_OPERATOR_BNB ?? 0.02),
    minVrfBnb: Number(env.MIN_VRF_BNB ?? 0.02),
    drawAlertSec: Number(env.DRAW_ALERT_SEC ?? 6 * 3600),
    alert: {
      telegramToken: env.TELEGRAM_BOT_TOKEN || null,
      telegramChat: env.TELEGRAM_CHAT_ID || null,
      webhook: env.ALERT_WEBHOOK_URL || null,
    },
    stateFile: resolve(ROOT, env.STATE_FILE ?? `state/${chainId}.json`),
    logFile: resolve(ROOT, env.LOG_FILE ?? `logs/${chainId}.log`),
  };
  // 日志脱敏用：不可枚举，JSON.stringify(cfg) 也不会带出来
  Object.defineProperty(cfg, 'secrets', {
    value: [loaded?.key, loaded?.key?.slice(2), ...rpcs, ...(env.BSC_RPC_URLS ? bscRpcs : []), env.TELEGRAM_BOT_TOKEN, env.ALERT_WEBHOOK_URL].filter(Boolean),
    enumerable: false,
  });
  return cfg;
}

/** RIG 期望实现地址：没设返回 null；格式不对直接报错（免得监控拿一个错地址比较、一直误报或漏报） */
function rigImpl(v) {
  if (!v) return null;
  if (!/^0x[0-9a-fA-F]{40}$/.test(v)) throw new Error(`RIG_IMPLEMENTATION 不是地址：${v}`);
  return v.toLowerCase();
}

function loadAccount(env, chainId) {
  let key = env.OPERATOR_PRIVATE_KEY || null;
  if (!key && env.OPERATOR_KEY_FILE) {
    const file = resolve(ROOT, env.OPERATOR_KEY_FILE);
    for (const [re, chains] of TESTNET_KEY_FILES) {
      if (re.test(file) && !chains.includes(chainId)) throw new Error(`${file} 是测试网一次性钱包，只能用在链 ${chains.join(' / ')} 上`);
    }
    const mode = statSync(file).mode & 0o077;
    if (MAINNETS.has(chainId) && mode !== 0) throw new Error(`${file} 的权限太宽，先运行 chmod 600`);
    const raw = env.OPERATOR_KEY_VAR ? readVar(file, env.OPERATOR_KEY_VAR) : readFileSync(file, 'utf8').trim();
    key = raw;
  }
  if (!key) throw new Error('没有运营钱包：设置 OPERATOR_KEY_FILE（推荐）或 OPERATOR_PRIVATE_KEY；只想看会做什么就加 --dry-run');
  if (!key.startsWith('0x')) key = `0x${key}`;
  if (!/^0x[0-9a-fA-F]{64}$/.test(key)) throw new Error('私钥格式不对（内容不会显示）');
  return { account: privateKeyToAccount(key), key };
}
