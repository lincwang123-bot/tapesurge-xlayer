# bls-solidity（原样复制，未做任何修改）

- 来源：https://github.com/randa-mu/bls-solidity
- 版本：commit `9e10df92d631fab9c46f0ce9cd5c445f857bedcb`（2025-09-07）
- 审计：zkSecurity《Audit of onlyswaps and dcipher (BLS signatures)》，2025-09-19，审计范围包含 bls-solidity 的这个 commit
  （https://reports.zksecurity.xyz/reports/randa-mu-onlyswaps.md）。报告里没有关于 BN254 验签的发现；
  BN254 / BLS12-381 签名和 BN254 SvdW hash-to-curve 的差分测试"在数百万个用例上全部通过"。
  注意：这是 onlyswaps / dcipher 整体审计的一部分，不是单独针对本库的审计；仓库 README 仍写着
  "Experimental, unaudited cryptographic code"。我们自己的审计范围也应包含它。
- 复制的文件：`src/libraries/BLS.sol`（BN254 BLS 验签，基于 Kevin Charm 的 bls-bn254）、`src/libraries/ModExp.sol`、
  `src/libraries/Precompiles.sol`，以及 `LICENSE`（MIT）、`testcases.json`（原仓库的测试数据）。校验和见 `SHA256SUMS`。
- 用法与原仓库 `src/demos/EvmnetRegistry.sol` 相同：DST = `BLS_SIG_BN254G1_XMD:KECCAK-256_SVDW_RO_NUL_`，
  消息 = `keccak256(abi.encodePacked(uint64 round))`，签名在 G1、公钥在 G2，随机数 = `sha256(签名)`。
