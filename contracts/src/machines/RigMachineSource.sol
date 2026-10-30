// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IMachineSource} from "../interfaces/IMachineSource.sol";
import {IRig} from "../interfaces/IRig.sol";

/// @title RIG 矿机来源（M1）
/// @notice 不可升级，没有管理员。收购资格（设计说明 3.1）：
///         - `power > 0`，且在 [minPower, maxPower]（默认 10–300，和 BSC 版相同）；
///         - `syncedAt` 在 maxSyncAge（3 天）以内且不在未来：说明 BSC 那边仍在正常挖矿、同步；
///         - 原矿机的电路合约是 BSC 官方矿机电路（expectedCircuits，0 = 不检查）。
///         计价权重 = RIG 记录的 `power`（原矿机的 PoD 权重）。
/// @dev 收益归属按 BSC 上发起收取的时刻：卖家应在卖给主板前先在 BSC 金库上收取一次，否则这之前累积的产出
///      会在之后的收取里付给主板；主板交接 / 卖出凭证、月局开奖之前，运营机器人也应先收取一次。
contract RigMachineSource is IMachineSource {
    IRig public immutable rig;
    address public immutable expectedCircuits;
    uint256 public immutable minPower;
    uint256 public immutable maxPower;
    uint256 public immutable maxSyncAge;

    error BadConfig();

    constructor(address rig_, address expectedCircuits_, uint256 minPower_, uint256 maxPower_, uint256 maxSyncAge_) {
        if (rig_ == address(0) || minPower_ == 0 || maxPower_ < minPower_ || maxSyncAge_ == 0) revert BadConfig();
        rig = IRig(rig_);
        expectedCircuits = expectedCircuits_;
        minPower = minPower_;
        maxPower = maxPower_;
        maxSyncAge = maxSyncAge_;
    }

    function machineToken() external view returns (address) {
        return address(rig);
    }

    function purchaseWeight(uint256 id) external view returns (uint256) {
        IRig.Rig memory r = rig.rigs(id);
        if (r.power < minPower || r.power > maxPower) return 0;
        if (expectedCircuits != address(0) && r.circuits != expectedCircuits) return 0;
        if (r.syncedAt > block.timestamp || block.timestamp - r.syncedAt > maxSyncAge) return 0;
        return r.power;
    }

    function currentWeight(uint256 id) external view returns (uint256) {
        return rig.rigs(id).power;
    }

    /// @notice RIG 最近一次同步的时间：BSC 金库上最近一次发起收取的时间（之前累积的产出已付给当时的持有人）
    function syncedAt(uint256 id) external view returns (uint256) {
        return rig.rigs(id).syncedAt;
    }
}
