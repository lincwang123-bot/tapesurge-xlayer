// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title 随机数适配器接口
/// @notice 主板只依赖这个接口。主网和测试网的实现是 `ChainlinkVRFAdapter`（Chainlink VRF v2.5），
///         单元测试用 `MockRandomSource`。以后换成 drand 验签，只要实现同一个接口。
interface IRandomSource {
    /// @notice 请求一个随机数，结果异步回调到 msg.sender 的 `onRandomness`。
    function requestRandomness() external returns (uint256 requestId);
}

interface IRandomConsumer {
    /// @notice 随机数回调，只接受来自随机数适配器的调用。
    function onRandomness(uint256 requestId, uint256 randomWord) external;
}

/// @notice 适配器用它判断请求方是不是官方 BoardFactory 创建的主板（防止别人消耗 VRF 订阅）。
interface IBoardRegistry {
    function isBoard(address account) external view returns (bool);
}
