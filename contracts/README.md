# TapeSurge X Layer contracts

Solidity 0.8.28 · Foundry. The X Layer version of TapeSurge: monthly boards that pool BEM, buy TapeOut RIG miner vouchers, mine for 30 days, draw prizes with drand verified on-chain, then sell the miners and pay principal back first. The rules follow the BNB Chain mainnet version ([tapesurge-contracts](https://github.com/lincwang123-bot/tapesurge-contracts), `v2.0-audit.6`); only the chain-specific parts differ (see [`V2-PORT.md`](V2-PORT.md)).

## Contracts

| Contract | Role |
|---|---|
| `XHub` | Registry: genesis conditions, operator address, upgrade-sentinel registration |
| `XMonthFactory` | Opens monthly boards (EIP-1167 clones), board config, per-round buy-price cap snapshot |
| `XMonthBoard` | One board: recruitment, buying RIG, 30-day mining, drand draw, settlement, claims |
| `XMonthPositions` | Position NFTs (one per seat), transferable during settlement |
| `XPositionExchange` | On-chain order book for positions: asks, bids, batch buys |
| `XMonthExitGovernor` | Majority vote for a collective liquidation plan, floored at 95% of the market bid |
| `XMonthMachineSales` | Settlement pricing: formula price from the BSC miner market, never below cost; hand-over to the next board |
| `XRigMarket` | Built-in RIG market: non-custodial asks, escrowed collection bids, buying boards take asks, settling boards sell into it |
| `XMarketPriceFeed` | BSC miner-market bid / ask relayed by the operator, ±5% per post, 50-minute spacing, stale after 3 hours |
| `DrandEvmnetAdapter` | Locks a future drand round per draw and verifies its BLS signature on-chain (BN254 precompiles) |
| `RigMachineSource` | RIG eligibility: power 10–300, synced within 3 days, official miner circuits |
| `GenesisSplitter` | Creator of the Genesis Pass processor; routes mint revenue |
| `UniswapV3TwapOracle` | 30-minute TWAP of the BEM/WOKB pool |
| `src/mocks/` | Testnet-only stand-ins (BEM, RIG, TapeOut, swap router) |

## Key rules

- A board that has started has no admin entry point; its parameters and funds cannot be changed.
- The operator only runs scheduled steps (draws, drand delivery, price relay, hand-over, batch payouts). If it is idle for 3 days, position holders can run them.
- Buy price rises from 50% of the cap toward the cap; the cap is min(BSC best ask, the round snapshot). Settlement price is max(formula price, cost).
- Bids and asks on the position exchange are tied to the board's trade epoch and lapse when it changes.
- RIG sold or handed over must have synced within 1 day, so yield accrued while a board held it stays with the board.

## Build and test

```bash
forge build
forge test --no-match-contract Fork                     # 234 offline tests
XLAYER_RPC_URL=https://rpc.xlayer.tech forge test --match-contract Fork   # mainnet-fork tests
```

## Deployments

- X Layer testnet (chain 1952): [`deployments/1952.json`](deployments/1952.json); main addresses are listed in the [repository README](../README.md).
- Scripts: `script/DeployXLayerTestnet.s.sol`, `script/DeployXLayerMainnet.s.sol`, `script/CheckXLayerMainnet.s.sol`, `script/xlayer-testnet.sh`, `script/xlayer-mainnet.sh`. Parameters live in `script/XLayerDefaults.sol`.

## 中文简介

TapeSurge 的 X Layer 版合约：月局主板汇集 BEM，收购 TapeOut 的 RIG 矿机凭证挖 30 天，用链上验签的 drand 随机数开奖，到期卖掉矿机、先退本金。规则和 BNB Chain 主网版一致，只有链相关的部分不同，详见 [`V2-PORT.md`](V2-PORT.md)。

## License

MIT
