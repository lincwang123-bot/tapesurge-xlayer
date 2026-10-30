// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MonthState} from "./IXMonthBoard.sol";

/// @notice v2 月局主板对单例合约（持仓凭证、卖矿、清算治理）开放的接口。
///         和 BSC 版 IMonthV2 相同，去掉了 X Layer 用不到的 PRICE_FEED / consign / TRADER
///         （BSC 的 TRADER 在 X Layer 上是 RIG 矿机市场 XRigMarket，主板的 MARKET；它只调用 sellMachine）。
interface IMonthBoardV2 {
    /// @dev 与 XMonthBoard.Socket 的字段顺序和类型完全相同（socket(slot) 的返回值）
    struct Position {
        address owner;
        uint96 stake;
        uint256 passId;
        uint128 claimed;
        bool refunded;
        bool passReturned;
        uint32 version;
    }

    /// @dev 与 XMonthBoard.Machine 的字段顺序和类型完全相同（machine(index) 的返回值）；X Layer 上 key 恒为 0，collection 是 RIG 合约
    struct MachineView {
        bytes32 key;
        uint256 circuitId;
        address collection;
        uint64 weight;
        bool active;
        bool sold;
        uint128 cost;
    }

    function state() external view returns (MonthState);
    function settleStart() external view returns (uint256);
    function totalStake() external view returns (uint256);
    function socketCount() external view returns (uint256);
    function holderCount(address account) external view returns (uint256);
    function liquidating() external view returns (bool);
    function governanceLocked() external view returns (bool);
    function tradeEpoch() external view returns (uint64);
    function claimsClosed() external view returns (bool);
    function finishedAt() external view returns (uint256);
    function socket(uint256 slot) external view returns (Position memory);
    function machine(uint256 index) external view returns (MachineView memory);
    function machineCount() external view returns (uint256);
    function withdraw(uint256 slot) external returns (uint256 amount);
    function returnPass(uint256 slot) external;
    function unsoldMachines() external view returns (uint256);
    function sentinelPaused() external view returns (bool);
    /// @dev 矿机来源（IMachineSource），卖矿合约用它检查卖出前的同步时间
    function MACHINE_SOURCE() external view returns (address);

    /// @dev 只认持仓凭证合约：所有转移路径都经过这里（锁、结转、退通行证、版本号）
    function onPositionTransfer(uint256 slot, address from, address to) external;
    /// @dev 只认卖矿合约：从卖矿合约收 price 个 BEM，把第 index 台矿机转给 to
    function releaseMachine(uint256 index, address to, uint256 price) external;
    /// @dev 只认卖矿合约：在新月局的收购拍卖里按不低于成本价卖出第 index 台矿机
    function relayOut(uint256 index, address newBoard) external returns (uint256 paid);
    /// @dev 只认清算治理合约
    function setGovernanceLock(bool locked) external;
    function startLiquidation() external;

    /// @dev 新月局的收购入口（collection 必须是本局的 RIG 合约）。旧月局交接、普通卖家：第三个参数是最低单价；
    ///      RIG 矿机市场：第三个参数是卖单实价（整张 BEM 总额），按实价付款
    function sellMachine(address collection, uint256 circuitId, uint256 minPricePerWeight) external returns (uint256 paid);
}

/// @notice 卖矿单例公开它用的 BSC 行情转报（XMarketPriceFeed）
interface IMonthSalesFeed {
    function PRICE_FEED() external view returns (address);
}

/// @notice XMarketPriceFeed 的收购定价部分（和 BSC IMarketPriceFeed 同名同参）
interface IXPriceQuote {
    function buyQuote(uint256 cap, uint256 curvePrice, uint256 since) external view returns (uint256);
    function updatedAt() external view returns (uint256);
}

/// @notice 持仓凭证（ERC-721）的铸造入口
interface IMonthPositions {
    function mint(address to, uint256 slot) external;
    function idOf(address board, uint256 slot) external pure returns (uint256);
}
