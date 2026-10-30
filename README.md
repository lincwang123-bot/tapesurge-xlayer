# TapeSurge on X Layer

**TapeSurge (晶涌协议) lets anyone join TapeOut's PoD mining with a small stake.** Players pool BEM into a 30-day monthly board that buys RIG miner vouchers on X Layer. Half the output is shared by stake, and the other half is drawn as five prizes with drand randomness verified on-chain. When the board ends, the miners are sold and principal is paid back first. The project ships its own RIG market on X Layer, and players can join with OKB or USDT.

| | |
|---|---|
| Live app (X Layer testnet) | https://app.tapesurge.com/?chain=1952 |
| RIG market | https://app.tapesurge.com/?chain=1952#/market |
| BNB Chain version (mainnet since 2026-10-26) | https://github.com/lincwang123-bot/tapesurge-contracts |
| Hackathon | OKX Xccelerate · X Layer TapeOut developer program (2026-10-16 – 2026-12-07) |

> On X Layer testnet, BEM, RIG and TapeOut are mock contracts; drand randomness is real and verified on-chain. An external audit is planned before X Layer mainnet. Returns come from actual mining output; nothing here is investment advice.

## How a monthly board works

1. **Pool** – each player stakes 0.2%–4% of the board (plus a 1% entry fee) and locks a Genesis Pass: a half-adder circuit taped out on TapeOut from 5 transistors, reusable board after board.
2. **Buy miners** – the board buys RIG vouchers (each one stands for a PoD miner locked in a BSC vault) through a rising-price auction and from asks on the built-in RIG market, never above the price cap relayed from the BSC miner market.
3. **Mine 30 days** – yield arrives cross-chain and goes into the prize pool with no fee taken.
4. **Draw** – a future drand round is locked when the draw is requested; its BLS signature is verified on-chain (BN254 precompiles). Half the pool is shared by stake, half is drawn as 5 prizes (60/15/15/5/5).
5. **Return principal** – miners are sold at a formula price (not below cost unless a majority votes to liquidate), to buyers on the RIG market or to the next board. Proceeds repay principal first. During settlement, positions can be traded on an on-chain order book, and a majority can vote for a collective liquidation.

## Built on TapeOut, on X Layer

| TapeOut piece | How TapeSurge uses it |
|---|---|
| Processor factory and circuits | Genesis Pass = HA1 half-adder circuit taped out through a TapeSurge processor |
| RIG miner vouchers | The miners a board buys, holds and sells; the RIG market trades them |
| Cross-chain BEM (LayerZero OFT) | Stakes, prizes and RIG yield are all in BEM on X Layer |
| PoD mining | All yield comes from real PoD output of the miners behind the RIG vouchers |

## Repository layout

| Folder | What | Notes |
|---|---|---|
| [`contracts/`](contracts/) | X Layer contracts (Solidity 0.8.28, Foundry): monthly board, RIG market, drand adapter, BSC price relay, position exchange, collective liquidation, deploy scripts and tests | See [`contracts/README.md`](contracts/README.md) and [`contracts/V2-PORT.md`](contracts/V2-PORT.md) |
| [`app/`](app/) | React + viem dApp served at app.tapesurge.com: boards, RIG market, join with OKB / USDT, fallback actions (e.g. submit the drand signature) | Shared by the BNB Chain and X Layer versions |
| [`bot/`](bot/) | Operator bot (Node + viem): drand delivery, BSC price relay, RIG market matching, RIG upgrade watch | Shared by both chains; keys and server config are not in this repo |

## X Layer testnet deployment (chain 1952)

Full record: [`contracts/deployments/1952.json`](contracts/deployments/1952.json). Main addresses:

| Contract | Address |
|---|---|
| XHub (registry, operator, genesis) | `0xC772fe04E27805a09563AF288a035056E834Ef2c` |
| XMonthFactory | `0x31491566Caa3352a23b055b77eb2D1E187Bc112A` |
| XRigMarket (RIG market) | `0x90C76AEDE10213abE165b35A367695b47C9a0829` |
| XMonthMachineSales | `0xc2F11F774226B80a11d69DC9D382326867774Ca4` |
| XPositionExchange | `0xA4A39E2b6F328d26E2cB16b10464708df5034805` |
| DrandEvmnetAdapter | `0xd211717300AE781B48E36d6313209809caF2c3eA` |
| XMarketPriceFeed (BSC price relay) | `0xd2a42F766b448E495cC84c908e4a4940F8b72Fb5` |
| GenesisSplitter | `0x7370Ca55B3BF2741EBbf16337c988102B15f485b` |
| MockRig / MockBEM (testnet only) | `0x0AAbCDfcb4A75d7be49097681FbBf7a041c6eD22` / `0x3Cc169fbB649583b0aB898672A8C0f9b3ED2Aebc` |
| MockZapRouter (testnet stand-in for SwapRouter02) | `0x782945d8D6780663C508a3Cd0F04FAf0C224F1B9` |

## Run it

```bash
# contracts: 234 offline tests (fork tests need XLAYER_RPC_URL)
cd contracts && forge test --no-match-contract Fork

# dApp
cd app && npm install && npm run dev

# operator bot: 94 tests; a dry run needs no key
cd bot && npm install && npm test
CHAIN_ID=1952 node src/index.js --dry-run --once
```

## Development during the program

TapeSurge started on 2026-10-18; all X Layer work happened during the program. Highlights (dates in 2026):

- **10-20** On-chain survey of TapeOut on X Layer. There is no PoD and no Chainlink VRF on X Layer, so three modules were redesigned: RIG as the miner source, drand verified on-chain, Uniswap v3 for buyback.
- **10-21** First X Layer contracts: RIG machine source, drand evmnet adapter (BN254 on-chain verification), monthly board with cross-chain yield accounting, deploy and check scripts, mainnet-fork tests.
- **10-27** Ported the v2 rules from the BNB Chain version: position NFTs, on-chain position exchange, collective liquidation, formula-priced miner sales, BSC price relay with a ±5% step limit.
- **10-28** Parameters fixed, operator bot on X Layer, first testnet deployment, internal global review with the rules aligned to the BNB Chain version.
- **10-29** RIG market (asks, collection bids, batch buys, on-chain book; boards buy from and sell into it), testnet redeployed with the market, dApp on app.tapesurge.com, join with OKB / USDT (tested on an X Layer mainnet fork against the real router), demo video.

## 中文简介

TapeSurge（晶涌协议）让任何人用小额就能参与 TapeOut 的 PoD 挖矿：大家把 BEM 汇成一块 30 天的月局主板，主板在 X Layer 上买入 RIG 矿机凭证挖矿；产出一半按投入比例分，一半用链上验签的 drand 随机数抽 5 个奖；到期卖掉矿机，先退本金。项目自带 X Layer 上的 RIG 矿机市场，也可以直接用 OKB 或 USDT 加入。

- 本仓库是 X Layer 版：`contracts/` 是合约，`app/` 是 dApp，`bot/` 是运营机器人。
- BNB Chain 版合约（2026-10-26 主网上线）在 [tapesurge-contracts](https://github.com/lincwang123-bot/tapesurge-contracts)。
- X Layer 版目前在测试网运行，主网上线前会做外部审计。收益来自实际挖矿产出，不构成投资建议。

## License

MIT
