// X Layer：RIG 凭证合约的升级监控（全局审计 2026-10-29 第 4 条）。
// RIG 是 TapeOut 的 UUPS 代理、未封印，升级发生在代理内部，主板合约在链上检测不到（设计说明 X6：靠链下监控）。
// 这里读代理的 EIP-1967 实现槽和 isSealed()，和期望值 / 第一次看到的值比较；纯函数，链上读写在 tasks/system.js。

/** EIP-1967 实现槽：bytes32(uint256(keccak256('eip1967.proxy.implementation')) - 1) */
export const EIP1967_IMPL_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';

/** X Layer 主网 RIG 代理 0x9cfc…E520 的实现（Sourcify 源码完全匹配，2026-10-21 读取，见 xlayer/contracts/src/interfaces/IRig.sol） */
export const RIG_IMPL_196 = '0x66fb7d52c4931b48776d9019f88f7f58fb0d85e1';

/** 存储槽的 32 字节 → 地址（小写）；读不到时当作 0 地址 */
export function implFromSlot(word) {
  const hex = String(word ?? '0x').replace(/^0x/, '').padStart(64, '0');
  return `0x${hex.slice(-40).toLowerCase()}`;
}

/**
 * 比较这次读到的实现：有期望值（配置或主网默认）就和期望值比，否则和第一次看到的（baseline）比。
 * 返回 { ref, changed, newlySealed }：changed = 实现和参照不同；newlySealed = 上次没封印、这次封印了。
 */
export function rigStatus({ expected = null, baseline = null, current, sealed = null, wasSealed = null }) {
  const ref = (expected ?? baseline)?.toLowerCase() ?? null;
  return {
    ref,
    changed: ref !== null && current.toLowerCase() !== ref,
    newlySealed: sealed === true && wasSealed === false,
  };
}
