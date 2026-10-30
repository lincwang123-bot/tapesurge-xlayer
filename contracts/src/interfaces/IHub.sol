// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice 首批回馈的领取对象（月局实现；以后的标准局也实现）。GenesisSplitter 只通过这个接口和主板交互。
interface IRewardTarget {
    /// @notice 现在能否接收回馈补贴（月局：开局后、局终结算前）
    function acceptsSubsidy() external view returns (bool);
    /// @notice 是否已结束（之后它那一桶的新增收入转入回购）
    function rewardEnded() external view returns (bool);
    function depositSubsidy(uint256 amount) external;
}

/// @notice 主板注册中心（X Layer 版由 XHub 担任，ABI 和 BSC 版 BoardFactory 的同名函数一致）：
///         开局顺序、是否官方主板、运营地址、升级哨兵登记。
interface IBoardHub {
    /// @notice 第 rank 个真正开局的主板（rank 从 1 开始；GenesisSplitter 按它发前 5 块的回馈）
    function rewardBoard(uint256 rank) external view returns (address);
    /// @notice 由月局工厂在月局开局时调用，登记开局顺序
    function registerStart(address board) external returns (uint256 rank);
    function isBoard(address account) external view returns (bool);
    function monthFactory() external view returns (address);
    function passCircuits() external view returns (address);
    function splitter() external view returns (address);
    /// @notice 运营地址：开奖、提交 drand 签名、自动发放、月局矿机交接 / 挂单由它执行；
    ///         它 3 天没执行时由本局参与者兜底。可以为 0。
    function operator() external view returns (address);
    /// @notice 第一次登记到升级哨兵触发的时间（0 = 未登记或已恢复）
    function sentinelSince() external view returns (uint256);
    /// @notice 登记升级哨兵触发（任何人可调；信标恢复后再调用清零）
    function noteSentinel() external;
}
