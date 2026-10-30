// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice 月局的状态（和 BSC 版 MonthBoard 相同）
/// - Recruiting：招募中（3 天）
/// - Failed：招募失败，全员退款、退还通行证
/// - Preparing：已开局，准备矿机（收购拍卖 + 旧月局交接，最多 3 天，买满提前开挖）
/// - Mining：挖矿 30 天，产出进奖金池
/// - Drawing：等待随机数开奖
/// - Settling：已开奖（或不抽奖结算），收回本金：交接 / 挂单出售（不低于成本价；多数清算后按计划价）/ 卖不出继续挖
enum MonthState {
    Uninitialized,
    Recruiting,
    Failed,
    Preparing,
    Mining,
    Drawing,
    Settling
}

interface IXMonthFactory {
    function openFirst() external returns (address board);
    /// @return rollover 转给刚开局主板的滚存资金（上一批月局收回的回馈部分）
    /// @return cap 刚开局主板的收购价上限快照（每单位算力，见 XMonthFactory.roundCap）
    function onBoardStarted(bool full, uint256 elapsed) external returns (uint256 rollover, uint256 cap);
    function onBoardFailed() external;
    function isBoard(address account) external view returns (bool);
    function boardImplementation() external view returns (address);
    /// @notice 月局共用的 BSC 行情转报（XMarketPriceFeed，从卖矿单例读）
    function priceFeed() external view returns (address);
    /// @notice 最新首次有效报告的月局，在最近一次新增到账时测得的每单位算力日产出；0 是有效样本。
    function unitYieldPerDay() external view returns (uint256);
    function hasYieldReport() external view returns (bool);
    /// @notice 月局结算时首次报告；之后新增收益到账可更新，只有当前最新样本局能改写未来局报价。
    function reportYield(uint256 perDay) external;
}
