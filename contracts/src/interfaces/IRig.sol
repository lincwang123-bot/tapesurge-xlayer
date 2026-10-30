// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title TapeOut 矿机凭证 RIG（X Layer）
/// @notice 代理 0x9cfc959cd42B2e1d39a0d850c528210E818AE520，实现 0x66fb7d52c4931b48776d9019f88f7f58fb0d85e1
///         （Sourcify exact match，2026-10-21 读取 `src/RigVoucher.sol`）。UUPS 可升级、未封印。
///         - 每张凭证对应 BSC 金库里锁着的一台 PoD 矿机；`power` = 原矿机的 PoD 权重，`syncedAt` = 最后一次同步时间。
///         - 有人在 BSC 金库上发起收取 → BEM 经 LayerZero 到 X Layer → `lzCompose` 把每台的份额用普通 transfer
///           打给 `payeeAt(id, time)`：**收取那一刻（time）**的凭证持有人，而不是到账时的持有人；没有回调。
///         - 凭证是 ERC-721（ERC721Enumerable），`transferFrom` 不要求接收方回调，合约可以直接持有。
///         - `redeem(id, to)` 烧掉凭证、在 BSC 上取回矿机。**TapeSurge 的主板永远不调用它。**
interface IRig {
    struct Rig {
        address circuits; // BSC 上原矿机的电路合约
        uint64 syncedAt;
        uint256 circuitId;
        uint256 power;
    }

    function rigs(uint256 id) external view returns (Rig memory);
    function powerHeld(address holder) external view returns (uint256);
    function totalPower() external view returns (uint256);
    function holderAt(uint256 id, uint256 time) external view returns (address);
    function payeeAt(uint256 id, uint256 time) external view returns (address);
    function isSealed() external view returns (bool);
    function ownerOf(uint256 id) external view returns (address);
    function transferFrom(address from, address to, uint256 id) external;
}
