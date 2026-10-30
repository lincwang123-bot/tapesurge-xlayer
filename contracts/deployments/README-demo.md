# X Layer 参赛演示处理器（M5a）

这是供参赛展示的独立小处理器，**不是创世通行证，不提供主板准入或游戏参与权**。M4 主板只接受它部署配置中明确指定的创世电路地址，不能把这里的 Demo 电路地址当作通行证地址。

固定参数：chain `196`；官方工厂 `0x1f09DAeFA827f02CBb40967cc91b259763760761`；creator / HA1 所有人 `0x9304e363D12Fd84a32E92fD274C8EDC82Dd7d965`；名称 `TapeSurge Demo (X Layer)`；symbol `SURGE-DEMO`；晶体管上限 `100`；creator 的 `mintPrice = 0`。故事字段（2026-10-21 按此前的建议参数）：`Demo processor for the X Layer TapeOut accelerator. Not a TapeSurge Genesis Pass; TapeSurge boards do not accept it.`

脚本依次调用 `createCPU`、铸造 `5 NAND`、流片 `HA1`。费用全部从合约读取，零价创建被协议拒绝时直接停止，不猜测替代价格。它核对 creator、上限、零 mintPrice、晶体管烧毁、电路所有人、网表哈希、2 输入 / 2 输出 / 0 状态 / 5 NAND，以及半加器的全部 4 组输入输出。

## 默认只模拟

在 `xlayer/contracts` 内运行：

```bash
bash script/xlayer-demo.sh
# 重现本次验证使用的主网状态：
bash script/xlayer-demo.sh simulate --fork-block 73781796
```

不读取 `.env`、私钥或钱包。模拟记录是 `deployments/196-demo.simulation.json`，字段 `simulationOnly: true`、`status: SIMULATED_NOT_DEPLOYED`；里面的地址只是该分叉状态下的预测，不能提交为已部署的参赛地址。Forge 自己生成的 `broadcast/.../dry-run/` 记录同样只是模拟交易。不会创建名为 `196-demo.json` 的文件。

该 EOA 在上述 block 的真实余额为 `0 OKB`。为允许预览，`simulate()` 仅在本地分叉把余额补到 1 OKB，报告用 `localBalanceOverridden` 和 `observedOwnerBalanceWei` 明示；不会向钱包转账。该入口会拒绝 Forge 的 broadcast / resume 上下文。模拟在真实分叉合约上执行全部调用，跳过从原始零余额开始的第二遍交易回放；`deploy` 预检则严格使用真实余额并执行交易回放，余额不足会停止。真实部署前还需要给该地址准备 `0.0112 OKB + gas`（以上述 block 的费用为基准）。

## 本次主网分叉验证

2026-10-21，官方 RPC `https://rpc.xlayer.tech`，主网 block `73781796`，在本地分叉上验证通过，未向网络广播。验证命令：

```bash
forge test --match-contract XLayerDemoProcessorForkTest \
  --fork-url https://rpc.xlayer.tech --fork-block-number 73781796 -vv
```

| 项目 | 实际读取值 |
|---|---:|
| `deployFee()` | `0.0066 OKB` |
| `protocolFee()` / NAND | `0.00066 OKB` |
| 5 NAND | `0.0033 OKB` |
| `TAPEOUT_FEE()` | `0.0013 OKB` |
| 三笔交易附带金额合计 | `0.0112 OKB`，不含 gas |

`mintPrice = 0` 已在该主网分叉验证可行；creator 和 HA1 NFT 所有人都是指定 EOA，HA1 网表哈希 `0xfffa29f1e30fa6438ba0e6ebd40ef157b53d0eff3f21cc4bc46942e27cb32ca0` 与四组真值表全部通过。此处的费用会随协议配置变化；重新模拟会重读。Foundry 测试内执行和断言消耗不是链上 receipt gas，不能当作实际交易手续费。

普通本地测试 `forge test --match-path test/XLayerDemoProcessor.t.sol -vv` 包含 4 项单元测试；没有显式指定主网分叉时，真实合约测试显示 SKIP，不把 mock 测试冒充主网实测。

## 本地 anvil 分叉广播演练（真实 receipt，2026-10-21）

为了拿到每笔交易真实的 receipt gas，在**本机** anvil 分叉上把三笔交易真正广播了一遍（没有发到 X Layer 网络）：

```bash
anvil --fork-url https://rpc.xlayer.tech --port 8546        # 另开一个终端
bash script/xlayer-demo.sh rehearse --rpc-url http://127.0.0.1:8546
```

`rehearse` 只接受 127.0.0.1 / localhost，在本地节点上模拟该 EOA 签名（余额不足时只在本地补 0.1 OKB），Forge 的广播记录写在临时目录、用完删除，
结果写进 `deployments/196-demo.rehearsal.json`（`status: LOCAL_FORK_REHEARSAL_NOT_DEPLOYED`，地址同样只是预测）。

分叉区块 73,796,832；X Layer 现在是 OP Stack（op-reth），但 L1 数据费系数为 0，receipt 的 `l1Fee` = 0，手续费就是 gasUsed × gas 价格。

| # | 交易 | receipt gasUsed | 按 0.02 gwei 的手续费 | 附带金额（value） |
|---|---|---:|---:|---:|
| 1 | `createCPU`（建处理器） | 763,366 | 0.0000153 OKB | 0.0066 OKB（deployFee） |
| 2 | `mint` 5 颗 NAND | 157,965 | 0.0000032 OKB | 0.0033 OKB（协议费 5 × 0.00066） |
| 3 | `tapeout` HA1 | 250,373 | 0.0000050 OKB | 0.0013 OKB（流片费） |
| | **合计** | **1,171,704** | **0.0000234 OKB** | **0.0112 OKB** |

（本地分叉上实际的 effectiveGasPrice 是 0.013–0.018 gwei，手续费合计 0.0000192 OKB；上表统一按主网当前 0.02 gwei 算。）
链上核对：creator = `0x9304…d965`，`supplyCap` = 100，`mintPrice` = 0，HA1 电路 #1 归 `0x9304…d965`，网表哈希 = `PASS_NETLIST_HASH`。

**用户需要准备：约 0.0113 OKB；建议往 `0x9304…d965` 转 0.012 OKB**（约 1.4 美元，gas 价格涨 10 倍也够）。

## 以后由用户明确执行真实部署

以下命令会先完整模拟，再要求手动输入 `DEPLOY`。仅接受用户显式指定的加密 keystore 或 Ledger；不接受裸私钥、助记词、unlocked RPC 或额外 Forge 参数。

```bash
bash script/xlayer-demo.sh deploy --account YOUR_KEYSTORE_NAME
# 或
bash script/xlayer-demo.sh deploy --ledger
```

钱包必须对应上述固定 EOA。真实部署会创建公开可铸造的 Demo 处理器；100 颗上限并不等于只限本人铸造。签名和发送前需核对钱包展示的 chain、目标、calldata 和费用。

成功广播后，包装脚本只从 Forge 的 `broadcast/XLayerDemoProcessor.s.sol/196/run-latest.json` 读取真实交易哈希、receipt、gas 和 block，要求恰好 3 笔交易全部成功，并通过 RPC 核对合约代码、creator 与 HA1 所有人，才创建 `deployments/196-demo.broadcast.json`。不会覆盖已有真实记录；中途失败会保留 Forge 记录并停止，不自动重发或重新部署。该广播路径尚未用真实资金执行，当前没有真实部署地址或交易哈希。
