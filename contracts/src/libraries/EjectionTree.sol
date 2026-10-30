// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title 出局抽签用的树状数组（Fenwick tree）+ 最大值线段树
/// @notice 白皮书附录 A：设剩下 n 人、投入 w₁…wₙ、总和 S，第 j 人的出局权重为 S − wⱼ，
///         P(j 出局) = (S − wⱼ) / ((n − 1)·S)，这样最后留下 i 的概率正好是 wᵢ / S。
///
///         树状数组的每个插槽存一个打包值 `(1 << 128) | stake`：高 128 位是"在局人数"，低 128 位是"在局投入"。
///         任意前缀和同时给出前 m 个插槽里的在局人数 c 和在局投入 s，前缀出局权重 = c·S − s。
///         出局者的插槽被整体减掉，不再贡献人数和投入。查找"第一个权重前缀和 > r"的插槽用二进制下降，O(log n)。
///
///         另有一棵最大值线段树，O(1) 读出"在局参与者中的最大投入"（开奖门槛要用），O(log n) 更新。

library EjectionTree {
    uint256 internal constant COUNT_ONE = 1 << 128;
    uint256 internal constant LOW_MASK = COUNT_ONE - 1;

    struct Tree {
        uint256 capacity;
        uint256 leafBase; // 线段树叶子起点：不小于 capacity 的最小 2 的幂
        mapping(uint256 => uint256) node; // 树状数组
        mapping(uint256 => uint256) maxNode; // 最大值线段树（下标从 1 开始，根是 1）
    }

    error TreeAlreadyInitialized();
    error BadCapacity();
    error SlotOutOfRange();
    error StakeOutOfRange();

    function init(Tree storage t, uint256 capacity) internal {
        if (t.capacity != 0) revert TreeAlreadyInitialized();
        if (capacity == 0) revert BadCapacity();
        t.capacity = capacity;
        uint256 b = 1;
        while (b < capacity) b <<= 1;
        t.leafBase = b;
    }

    /// @notice 插槽 slot（从 1 开始）加入一个投入为 stake 的参与者。
    function insert(Tree storage t, uint256 slot, uint256 stake) internal {
        uint256 n = t.capacity;
        if (slot == 0 || slot > n) revert SlotOutOfRange();
        if (stake == 0 || stake > LOW_MASK) revert StakeOutOfRange();
        uint256 v = COUNT_ONE | stake;
        for (uint256 i = slot; i <= n; i += _lowbit(i)) {
            t.node[i] += v;
        }
        uint256 j = t.leafBase + slot - 1;
        t.maxNode[j] = stake;
        while (j > 1) {
            j >>= 1;
            if (t.maxNode[j] >= stake) break;
            t.maxNode[j] = stake;
        }
    }

    /// @notice 把插槽 slot 上投入为 stake 的参与者移出。
    function remove(Tree storage t, uint256 slot, uint256 stake) internal {
        uint256 n = t.capacity;
        if (slot == 0 || slot > n) revert SlotOutOfRange();
        uint256 v = COUNT_ONE | stake;
        for (uint256 i = slot; i <= n; i += _lowbit(i)) {
            t.node[i] -= v;
        }
        uint256 j = t.leafBase + slot - 1;
        t.maxNode[j] = 0;
        while (j > 1) {
            uint256 a = t.maxNode[j];
            uint256 b = t.maxNode[j ^ 1];
            uint256 m = a > b ? a : b;
            j >>= 1;
            if (t.maxNode[j] == m) break;
            t.maxNode[j] = m;
        }
    }

    /// @notice 在局参与者中的最大投入。
    function maxStake(Tree storage t) internal view returns (uint256) {
        return t.maxNode[1];
    }

    /// @notice 前 m 个插槽的（在局人数，在局投入）。
    function prefix(Tree storage t, uint256 m) internal view returns (uint256 count, uint256 sum) {
        uint256 acc;
        for (uint256 i = m; i > 0; i -= _lowbit(i)) {
            acc += t.node[i];
        }
        return (acc >> 128, acc & LOW_MASK);
    }

    /// @notice 按出局权重 S − wⱼ 抽取：返回第一个"权重前缀和 > r"的插槽。
    /// @param aliveSum 当前在局投入总和 S
    /// @param r 随机数，调用方保证 r < (n − 1)·S
    function selectEject(Tree storage t, uint256 aliveSum, uint256 r) internal view returns (uint256 slot) {
        uint256 n = t.capacity;
        uint256 pos;
        uint256 acc;
        for (uint256 step = _highestPowerOfTwo(n); step != 0; step >>= 1) {
            uint256 next = pos + step;
            if (next <= n) {
                uint256 cand = acc + t.node[next];
                // 前缀权重 = 人数·S − 投入；每个在局者的投入都 ≤ S，所以不会下溢
                if ((cand >> 128) * aliveSum - (cand & LOW_MASK) <= r) {
                    pos = next;
                    acc = cand;
                }
            }
        }
        return pos + 1;
    }

    /// @notice 按投入比例抽取（月局开奖用）：返回第一个"投入前缀和 > r"的插槽，P(j) = wⱼ / S。
    /// @param r 随机数，调用方保证 r < 在局投入总和 S
    function selectByStake(Tree storage t, uint256 r) internal view returns (uint256 slot) {
        uint256 n = t.capacity;
        uint256 pos;
        uint256 acc;
        for (uint256 step = _highestPowerOfTwo(n); step != 0; step >>= 1) {
            uint256 next = pos + step;
            if (next <= n) {
                uint256 cand = acc + (t.node[next] & LOW_MASK);
                if (cand <= r) {
                    pos = next;
                    acc = cand;
                }
            }
        }
        return pos + 1;
    }

    /// @notice 第 k 个（从 1 开始）在局插槽。只剩 1 人时用它找出硅王。
    function findByCount(Tree storage t, uint256 k) internal view returns (uint256 slot) {
        uint256 n = t.capacity;
        uint256 pos;
        uint256 accCount;
        for (uint256 step = _highestPowerOfTwo(n); step != 0; step >>= 1) {
            uint256 next = pos + step;
            if (next <= n) {
                uint256 c = accCount + (t.node[next] >> 128);
                if (c < k) {
                    pos = next;
                    accCount = c;
                }
            }
        }
        return pos + 1;
    }

    function _lowbit(uint256 i) private pure returns (uint256) {
        unchecked {
            return i & (~i + 1);
        }
    }

    function _highestPowerOfTwo(uint256 n) private pure returns (uint256 p) {
        if (n == 0) return 0;
        p = 1;
        while (p <= n >> 1) {
            p <<= 1;
        }
    }
}
