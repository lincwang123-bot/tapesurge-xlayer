# TapeSurge app

React 19 + Vite + viem. Served at **https://app.tapesurge.com** (BNB Chain mainnet by default; add `?chain=1952` for X Layer testnet).

## Features

- **Boards** – browse recruiting, mining and settling boards; join with a Genesis Pass; claim payouts and passes.
- **Join with OKB / USDT** – if a wallet is short of BEM, the app swaps exactly the missing amount through the on-chain pool (any excess refunded, 2% slippage cap) before joining; after settlement, BEM can be swapped back. On testnet a mock router with the same interface stands in for the pool.
- **RIG market** (X Layer) – list asks, place collection bids, buy board miners, see the book and recent trades.
- **Positions** – trade positions on the on-chain order book; vote on collective liquidation.
- **Fallback actions** – if the operator is idle, holders can run each step themselves, including submitting the drand signature for a draw.
- **Telegram reminders** – optional wallet-signed binding to @TapeSurgeBot (Cloudflare Worker + D1, see `worker/`).
- Browser wallets via EIP-6963; a strict Content-Security-Policy limits connections to the listed RPCs and drand relays.

## Run

```bash
npm install
npm run dev          # http://127.0.0.1:5174
npm run build        # dist/
```

Contract addresses and ABIs come from `src/deployments/` and `src/abi/` (`scripts/sync-contracts.mjs`). Custom RPCs: `VITE_RPC_56`, `VITE_RPC_196`, `VITE_RPC_1952`.

`scripts/zap-fork-check.mjs` runs the swap flow against the real X Layer router on a local mainnet fork.

## License

MIT
