# X Layer 月局移植 v2 规则（2026-10-27 起）

项目方 2026-10-27 决定：X Layer 参赛版以 BSC 主网 `v2.0-audit.6` 的月局规则为准。
X Layer 特有的三块保持不变：矿机来源用 RIG 凭证、随机数用 drand、收购和卖矿定价不用 Firsto 报价。

做法：以现有 `XMonthBoard`（RIG 余额增量记账、drand、工厂实测产出上限，已有 140 项测试）为底，逐项加入 v2 的规则；
三个单例模块（持仓凭证、持仓盘口、集体清算）从 BSC 搬过来，去掉标准局分支；卖矿定价单例 2026-10-28 起和 BSC 相同（卖价公式），只去掉寄售和目标价。

## 1. 规则对齐（以 BSC v2 为准）

| # | 规则 | 旧 X 版 | v2（移植后） |
|---|---|---|---|
| R1 | 奖金池 | 先扣 3% 基金会 + 2% 手续费，其余抽 5 个奖 | 不扣费；一半（向上取整）按投入比例记给所有持仓，一半抽 5 个奖（60/15/15/5/5） |
| R2 | 买满提前开挖 | 无 | 已有矿机，且 100 台已满或剩余预算按当前收购价连一台最小算力都买不下 → 立即开挖 |
| R3 | 卖矿溢价分成 | 无 | 成交额超过成本价的部分 × 10% 给手续费地址；≤ 成本价（含清算低价）不收 |
| R4 | 领取期限关闭 | 剩余转基金会；之后到账的产出也转基金会 | 剩余转 0x…dEaD 销毁；之后到账的产出也销毁 |
| R5 | 持仓 | 按地址记账，不能转让 | 每个插槽一份 ERC-721 持仓（编号 = 主板地址 << 96 \| slot），只在结算阶段可转让；转让时卖方已累计款项结转给卖方、通行证退给原持有人 |
| R6 | 持仓盘口 | 无 | `PositionExchange`：BEM 计价、零手续费、非托管卖单 + 托管买单 |
| R7 | 集体清算 | 无 | `MonthExitGovernor`：结算满 7 天、10% 支持开 24 小时投票、严格过半通过、24 小时等待、48 小时内执行；执行后按计划价（7 天从起价降到底价）可低于成本价卖出 |
| R8 | 随机数回调 | 只认最新请求 | 本局发出的任何请求都有效，先到先用 |
| R9 | 领取、退通行证、分批推送 | `withdraw(account)`；推送在主板 | `withdraw(slot)` / `claimAll(slot)` / `returnPass(slot)` / `withdrawCredit(account)`；分批推送移到卖矿单例 |
| R10 | 交接 | 出让方按成本价转给接手方（`acceptRelay`，成本 ≤ 接手方上限） | 出让方在接手方的收购拍卖里按接手方当前收购价卖出，不低于成本价（`relayOut` → `sellMachine`） |

## 2. X Layer 特有、保持不变

| # | 内容 | 说明 |
|---|---|---|
| X1 | 矿机来源 | `IMachineSource` / `RigMachineSource`：RIG 凭证 ERC-721，算力 10–300，3 天内同步过；主板直接持有，不赎回 |
| X2 | 产出记账 | 产出由 BSC 金库收取后经 LayerZero 普通转账到账，主板用 `accountedBalance` 按余额增量归类；卖出后迟到的产出仍归本局持仓 |
| X3 | 收购价上限 | 开局快照 = min(工厂记录的最近实测单位日产出 × 365 天, 部署上限)，没有样本时用部署上限，每局最多比上一局上调 max(25%, 部署上限 × 5%)；BSC 读 PoD 的产出速率。准备期内和 BSC 一样再和 BSC 卖一取较小值、报价无效时暂停（第 3 节） |
| X4 | 收购方式 | 收购拍卖：从上限 × 起始比例起逐步上涨；**任何 RIG 持有人**都可以卖给主板，另外接受同一工厂旧月局的交接；2026-10-29 起还有自带的 RIG 矿机市场 `XRigMarket`：单价不高于当前收购价的卖单，任何人可以触发卖给主板，主板按卖单实价付款（对应 BSC MarketTrader，见 README「RIG 矿机市场」） |
| X5 | 随机数 | drand evmnet 链上验签（`DrandEvmnetAdapter`），运营地址交付，3 天后持有人兜底 |
| X6 | 升级哨兵 | 只盯通行证电路的 beacon；RIG 由链下监控并披露 |

## 3. 结算阶段卖矿定价（`XMonthMachineSales`）和 BSC 行情转报（`XMarketPriceFeed`）

2026-10-28 起（项目方决定：除链上条件不同的部分外，尽可能和 BSC 对齐）收购价上限、结算卖价、清算下限都和 BSC 的
`MarketPriceFeed` / `MonthMachineSales` 相同，原来的"运营地址挂单、1 天没挂按成本价、7 天锁定成本价"规则去掉了：

- **行情从哪来**：RIG 凭证背后就是锁在 BSC 金库里的 PoD 矿机（算力 = 原矿机的 PoD 权重，持有人可以烧凭证取回矿机），所以 BSC
  矿机行情就是 RIG 的参照价。X Layer 合约读不到 BSC，由运营地址把 BSC 主网报价合约
  `MarketPriceFeed`（`0x5479E1ca5EA5052d3EB699BF9C738Ac358FC3465`）链上的 `bid()` / `ask()` 原样转报到 `XMarketPriceFeed`
  （单位相同：每单位算力的 BEM 最小单位数，两条链的 BEM 都是 8 位小数），每次带上读取时的 BSC 区块号（`sourceBlock`），
  任何人可以在 BSC 上按这个区块核对。报价保护和 BSC 相同：每次 ±5%、间隔 ≥ 50 分钟、3 小时过期、7 天停运、
  BSC 在追价时这里用 `postCatchUp`。信任假设和 BSC 一样（运营地址报价 + 合约限幅），没有新增。
  （曾加过"有效买一每天最多下调 10%"，为和 BSC 一致已撤回。）
- **开局**：BSC 行情转报必须已经报过价，否则 `XHub.startGenesis` 报 `FeedNotPosted`。
- **收购价上限**（`XMarketPriceFeed.buyQuote`，同 BSC）：报价有效时 = min(BSC 卖一, 开局快照)，收购拍卖在这个上限下从 50% 往上涨；
  报价无效（过期、追价、运营地址为 0、停运）时为 0，暂停收购。
- **卖价**（`XMarketPriceFeed.sellQuote` + `XMonthMachineSales.askPrice`，同 BSC）：整台 = max(收购时算力 × max(买一, 卖一 × (99% − 0.5% × n)), 成本价)，
  n = 结算开始后整 6 小时数；报价无效时暂停卖出；停运（7 天没有有效报价）后任何人按成本价可买。
- 任何人按当前要价买走（`buyMachine`），主板 `releaseMachine` 交割并再查一次不低于成本价。
- 交接（`relay`）、分批推送（`distribute`）：运营地址专属，3 天后本局持仓持有人兜底。
- 清算计划生效后：要价 = min(正常要价, 计划价)，计划价可以低于成本价，但**不低于 BSC 买一 × 算力 × 95%**（规则决定 6.33）；
  报价无效时计划价暂停；停运后按成本价。
- 和 BSC 的差别（都是链上条件决定的）：
  - 没有寄售（`consign`）和"保持排序第一"的目标价（`postFloor` / `floorQuote`）：2026-10-29 起月局矿机直接显示在自带的 RIG 矿机市场盘口里（`XRigMarket.boardOffers`），按卖矿合约要价直接买或配统一买单，不需要寄售库；
  - 2026-10-28 起：购买和交接要求这台 RIG 在 1 天内同步过（RIG 产出付给 BSC 上发起收取那一刻的持有人，
    不先收取的话，主板持有期间累积的产出会被买家带走）；
  - 转报多带一个 BSC 区块号。
- 上线后运营机器人每小时转报一次（测试网同样转报 BSC 主网的真实值，`xlayer-testnet.sh feed`）。

## 4. 合约清单

| 合约 | 来源 | 改动 |
|---|---|---|
| `XMonthBoard` | 旧 X 版 | 按第 1 节 R1–R10 改；挂单、交接、推送移出；`Machine` 结构改成和 BSC `MachineView` 相同的字段顺序（`key` 恒为 0，`collection` = RIG 合约） |
| `month/XMonthPositions` | BSC `MonthPositions` | 去掉标准局注册中心 |
| `month/XPositionExchange` | BSC `PositionExchange` | 去掉标准局分支 |
| `month/XMonthExitGovernor` | BSC `MonthExitGovernor` | 只换接口引用 |
| `month/XMonthMachineSales` | 新写 | 第 3 节 |
| `oracle/XMarketPriceFeed` | BSC `MarketPriceFeed` | 只保留报价、`fresh` / `abandoned`（收购价、卖价公式和目标价在 X Layer 不用）；报价多带 BSC 区块号 |
| `XMonthFactory` | 旧 X 版 | 配置里加三个单例地址 |
| `interfaces/IXMonthV2.sol` | BSC `IMonthV2.sol` | 去掉 `PRICE_FEED` / `consign` / `TRADER` |

部署顺序：月局工厂之后依次是持仓凭证、清算治理、报价转报、卖矿、盘口、RIG 矿机市场（2026-10-29）；四个单例需要月局工厂地址，月局工厂的构造又需要单例地址 → 部署脚本用 `vm.computeCreateAddress` 预测地址（和 BSC 测试网脚本相同）。
