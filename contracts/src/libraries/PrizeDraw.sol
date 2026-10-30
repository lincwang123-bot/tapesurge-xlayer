// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EjectionTree} from "./EjectionTree.sol";

/// @title 月局开奖：用一个 VRF 随机数派生 5 次独立抽取
/// @notice 第 k 个奖的随机数 rₖ = keccak256(word, k) mod S，按"个人投入 ÷ 总投入"抽取（同一人可以中多个奖）。
///         所以每个人的期望奖金 = 个人投入 ÷ 总投入 × 奖金，拆号没有好处。
library PrizeDraw {
    using EjectionTree for EjectionTree.Tree;

    uint256 internal constant PRIZES = 5;

    /// @notice 5 个奖的比例：头奖 60%，二奖 2 × 15%，幸运奖 2 × 5%
    function prizeBps(uint256 k) internal pure returns (uint256) {
        if (k == 0) return 6_000;
        if (k <= 2) return 1_500;
        return 500;
    }

    function winners(EjectionTree.Tree storage t, uint256 totalStake, uint256 word)
        internal
        view
        returns (uint256[5] memory slots)
    {
        for (uint256 k = 0; k < PRIZES; k++) {
            uint256 r = uint256(keccak256(abi.encode(word, k))) % totalStake;
            slots[k] = t.selectByStake(r);
        }
    }
}
