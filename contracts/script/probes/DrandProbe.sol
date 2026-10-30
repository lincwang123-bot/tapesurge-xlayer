// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DrandEvmnetAdapter} from "../../src/random/DrandEvmnetAdapter.sol";

/// @notice 只读探针（不部署）：用 eth_call 在真实 X Layer 节点上执行创建代码。
///         构造函数里部署一个适配器并验签，然后直接返回 32 字节随机数（不留下运行时代码）。
///         doVerify = false 时只部署适配器，用来扣掉部署本身的 gas，得到纯验签的 gas。
contract DrandProbe {
    constructor(uint64 round, bytes memory signature, bool doVerify) {
        DrandEvmnetAdapter a = new DrandEvmnetAdapter(address(1), 30, 3 days);
        uint256 r;
        if (doVerify) r = a.verify(round, signature);
        assembly {
            mstore(0, r)
            return(0, 32)
        }
    }
}
