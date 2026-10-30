# TapeSurge operator bot

Node.js + viem. Runs the scheduled steps that the contracts allow the operator to trigger. **Every action is simulated first and only sent if the contract accepts it**; the contracts check prices, eligibility and timing, so a wrong choice by the bot is simply rejected.

## What it does

| Area | Task |
|---|---|
| Boards | Close recruitment, start mining, request draws, finalize prizes, push payouts and passes in batches |
| Randomness | BNB Chain: Chainlink VRF. X Layer: deliver the locked drand round's signature to the on-chain verifier |
| Prices | BNB Chain: relay the miner-market bid / ask (verified listings, ±5% per post, 24-hour move guard with automatic resume for gradual moves). X Layer: relay the BNB Chain quote |
| Miners | Buy for boards from the cheapest eligible listings; hand settling boards' miners to the next board; match the RIG market on X Layer |
| Monitoring | Upgrade sentinels, RIG implementation watch, operator balance, Telegram alerts |

## Run

```bash
npm install
npm test                                  # unit tests
CHAIN_ID=1952 node src/index.js --dry-run --once   # one round, simulate only, no key needed
```

Configuration is by environment variables (see `src/config.js` and `.env.example`); keys are read from a file outside the repository and are never logged. Deployment files are in `deployments/`; ABIs in `abi/` (`scripts/sync-contracts.mjs`).

## License

MIT
