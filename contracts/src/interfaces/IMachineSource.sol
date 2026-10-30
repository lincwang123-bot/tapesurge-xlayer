// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title 矿机来源（X Layer 版的可替换模块 M1）
/// @notice 主板通过它判断一台矿机能不能收购、按多少权重计价。矿机本身是 `machineToken()` 上的 ERC-721，
///         由主板直接持有（转入 / 转出用 transferFrom）；来源合约只读不持有、不转账。
///         产出不需要主板去领：由外部（BSC 金库的收取 → LayerZero）直接打进主板，主板按余额增量记账。
interface IMachineSource {
    /// @notice 主板持有的矿机 NFT 合约（X Layer：RIG 凭证）
    function machineToken() external view returns (address);

    /// @notice 收购 / 接手时的计价权重；不符合收购资格时返回 0
    function purchaseWeight(uint256 id) external view returns (uint256);

    /// @notice 矿机当前的权重（停机、被撤销时为 0）
    function currentWeight(uint256 id) external view returns (uint256);

    /// @notice 最近一次同步（产出结算）的时间。XMonthMachineSales 卖出 / 交接前要求它足够新
    function syncedAt(uint256 id) external view returns (uint256);
}
