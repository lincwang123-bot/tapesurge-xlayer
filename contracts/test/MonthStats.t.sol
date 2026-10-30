// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {EjectionTree} from "../src/libraries/EjectionTree.sol";
import {PrizeDraw} from "../src/libraries/PrizeDraw.sol";

/// @notice 测试用：直接调用月局使用的 PrizeDraw.winners（同一个库函数）。
contract PrizeHarness {
    using EjectionTree for EjectionTree.Tree;

    EjectionTree.Tree internal t;
    uint256 public total;
    uint256 public n;

    constructor(uint256[] memory stakes) {
        n = stakes.length;
        t.init(n);
        for (uint256 i = 0; i < n; i++) {
            t.insert(i + 1, stakes[i]);
            total += stakes[i];
        }
    }

    /// @return wins wins[k * (n + 1) + slot] = 第 k 个奖被 slot 抽中的次数
    /// @return sameFirstTwo 头奖和第一个二奖被同一人抽中的次数
    function run(uint256 games, uint256 seed) external view returns (uint256[] memory wins, uint256 sameFirstTwo) {
        wins = new uint256[](5 * (n + 1));
        for (uint256 g = 0; g < games; g++) {
            uint256[5] memory s = PrizeDraw.winners(t, total, uint256(keccak256(abi.encode(seed, g))));
            for (uint256 k = 0; k < 5; k++) {
                wins[k * (n + 1) + s[k]]++;
            }
            if (s[0] == s[1]) sameFirstTwo++;
        }
    }

    function select(uint256 r) external view returns (uint256) {
        return t.selectByStake(r);
    }

    /// @notice 给定随机数，5 个奖分别抽中哪个插槽（与月局 finalizePrizes 用同一个库函数）
    function winnersFor(uint256 word) external view returns (uint256[5] memory) {
        return PrizeDraw.winners(t, total, word);
    }
}

/// @notice 月局开奖的公平性：5 个奖各自独立按"个人投入 ÷ 总投入"抽取，可重复中奖。
contract MonthStatsTest is Test {
    /// @dev 穷举：r ∈ [0, S) 时每个插槽被抽中的次数恰好等于它的投入
    function test_SelectByStakeIsExact() public {
        uint256[] memory w = new uint256[](5);
        w[0] = 1;
        w[1] = 20;
        w[2] = 5;
        w[3] = 10;
        w[4] = 64;
        PrizeHarness h = new PrizeHarness(w);
        uint256[] memory c = new uint256[](6);
        for (uint256 r = 0; r < 100; r++) {
            c[h.select(r)]++;
        }
        for (uint256 i = 0; i < 5; i++) {
            assertEq(c[i + 1], w[i]);
        }
    }

    function _check(uint256[] memory w, uint256 games, uint256 seed) internal {
        PrizeHarness h = new PrizeHarness(w);
        (uint256[] memory wins, uint256 same) = h.run(games, seed);
        uint256 s = h.total();
        for (uint256 k = 0; k < 5; k++) {
            _checkPrize(w, wins, k, games, s);
        }
        _checkIndependence(w, same, games, s);
    }

    /// @dev 第 k 个奖：每个人被抽中的频率 ≈ 投入占比（5σ 以内）
    function _checkPrize(uint256[] memory w, uint256[] memory wins, uint256 k, uint256 games, uint256 s) internal pure {
        uint256 n = w.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 expected = games * w[i] / s;
            uint256 tol = 5 * _sqrt(games * w[i] * (s - w[i]) / (s * s)) + 2;
            uint256 got = wins[k * (n + 1) + i + 1];
            uint256 diff = got > expected ? got - expected : expected - got;
            assertLe(diff, tol, "prize frequency off");
        }
    }

    /// @dev 独立性：头奖和第一个二奖落在同一人身上的频率 ≈ Σ pᵢ²
    function _checkIndependence(uint256[] memory w, uint256 same, uint256 games, uint256 s) internal pure {
        uint256 sumSq;
        for (uint256 i = 0; i < w.length; i++) {
            sumSq += w[i] * w[i];
        }
        uint256 expSame = games * sumSq / (s * s);
        uint256 tolSame = 5 * _sqrt(expSame) + 2;
        uint256 d = same > expSame ? same - expSame : expSame - same;
        console2.log("same winner for prizes 1 & 2:", same, "expected", expSame);
        assertLe(d, tolSame, "prizes not independent");
    }

    function test_PrizeStats_1_20_79() public {
        uint256[] memory w = new uint256[](3);
        w[0] = 1;
        w[1] = 20;
        w[2] = 79;
        _check(w, 20_000, 11);
    }

    function test_PrizeStats_EightPlayers() public {
        uint256[] memory w = new uint256[](8);
        uint256[8] memory v = [uint256(1), 1, 2, 5, 10, 20, 20, 41];
        for (uint256 i = 0; i < 8; i++) {
            w[i] = v[i];
        }
        _check(w, 20_000, 12);
    }

    /// @dev 实际规模：100 BEM 月局，投入 0.2–4 BEM（最小单位、小数）
    function test_PrizeStats_RealisticMonthBoard() public {
        uint256 n = 40;
        uint256[] memory w = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            w[i] = 0.2e8 + uint256(keccak256(abi.encode("m", i))) % 3.8e8;
        }
        _check(w, 5_000, 13);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
