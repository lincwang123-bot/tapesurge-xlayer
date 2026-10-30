// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title TapeOut 协议的外部接口（BSC 主网）
/// @notice 这些接口来自链上读取和 eth_call 模拟（见 `通行证设计-v2.md` 第 1 节、`设计文档-v4.md` 第 2 节）。
///         TapeOut 合约没有公开验证源码，函数名经 openchain 选择器数据库解析，返回值含义部分为推断。

/// @notice TapeOut 处理器工厂 `0x68224F668083c29e9800Be2a646d42d18cedF7e2`
interface ITapeOutFactory {
    /// @notice 创建处理器（晶体管 ERC-1155 + 电路 ERC-721）。
    /// @dev 已用 eth_call 模拟确认：由合约调用时，新处理器的 creator() = 调用合约。
    ///      需付 deployFee()（主网读到 0.001 BNB）。
    function createCPU(
        string calldata name,
        string calldata symbol,
        string calldata story,
        uint256 transistorSupply,
        uint256 mintPrice
    ) external payable returns (address transistors, address circuits);

    function deployFee() external view returns (uint256);
}

/// @notice 处理器的晶体管合约（ERC-1155）
interface ITransistors {
    /// @notice 铸造晶体管。需付 (mintPrice + 协议费 0.0001 BNB) × amount。
    function mint(uint256 id, uint256 amount) external payable;

    function NAND() external view returns (uint256); // = 0
    function LATCH() external view returns (uint256); // = 1

    /// @notice 已铸造的晶体管总数（推断为所有 id 合计）。
    function minted() external view returns (uint256);
    function supplyCap() external view returns (uint256);
    /// @notice 每颗晶体管的协议费。主网合约的 getter 是小写的 protocolFee()（2026-10-20 实测返回 1e14 = 0.0001 BNB），
    ///         大写的 PROTOCOL_FEE() 在主网会 revert；本仓库的合约和主网脚本都不调用它，测试网 mock 两个都提供。
    function protocolFee() external view returns (uint256);
    function creator() external view returns (address);

    /// @notice creator 名下待提取的铸造收入（BNB）。
    function owed(address account) external view returns (uint256);

    /// @notice 提取铸造收入。
    /// @dev 2026-10-19 主网分叉确认：打给 creator（creator 调用时）。分账合约就是 creator，
    ///      并且由它自己调用，所以 BNB 进入分账合约。
    function withdraw() external;
}

/// @notice 电路合约（ERC-721，Beacon 代理）。官方矿机电路 `0xb1024b89886b9a34aa4ff5f31c411d708b20a14c`；
///         每个处理器（包括创世处理器）都有自己的电路合约。
interface ICircuits {
    function ownerOf(uint256 id) external view returns (address);
    function transferFrom(address from, address to, uint256 id) external;

    /// @notice 电路的网表字节。通行证校验用 keccak256(netlist(id))。
    function netlist(uint256 id) external view returns (bytes memory);

    function circuitInfo(uint256 id) external view returns (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount);

    function eval(uint256 id, bytes calldata input) external view returns (bytes memory);

    /// @notice 流片：烧掉晶体管、铸出电路 NFT，另付 TAPEOUT_FEE（0.0002 BNB）。
    function tapeout(bytes calldata nl, uint32 nIn, uint32 nOut) external payable returns (uint256 id);
}

/// @notice ERC-1967 信标。官方电路的信标 `0xf8d6d8eb894d6971c8976ad8b4971cbefe028156`。
interface IBeacon {
    function implementation() external view returns (address);
}
