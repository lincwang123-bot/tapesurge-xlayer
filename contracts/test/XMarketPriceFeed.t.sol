// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./utils/Fixture.sol";
import {XMarketPriceFeed} from "../src/oracle/XMarketPriceFeed.sol";
import {XLayerDefaults} from "../script/XLayerDefaults.sol";

/// @title BSC 矿机行情的 X Layer 转报（XMarketPriceFeed）：报价保护同 BSC 版 MarketPriceFeed（MarketPriceFeed.t.sol
///        的报价部分），另外记录 BSC 区块号
contract XMarketPriceFeedTest is Fixture {
    uint256 internal constant P = 76_377_649; // 2026-10-27 BSC 主网买一（每单位算力 ≈ 0.764 BEM）
    uint256 internal constant A = 141_997_481; // 同一时刻的卖一
    uint256 internal constant BSC_BLOCK = 130_114_826;

    function test_DeployedWithBscParameters() public view {
        assertEq(address(priceFeed.HUB()), address(factory));
        assertEq(priceFeed.maxChangeBps(), 500);
        assertEq(priceFeed.minInterval(), 50 minutes);
        assertEq(priceFeed.maxStaleness(), 3 hours);
        assertEq(priceFeed.abandonAfter(), 7 days);
        assertEq(priceFeed.sellStartBps(), 9_900, "same sell formula as BSC");
        assertEq(priceFeed.sellStepBps(), 50);
        assertEq(priceFeed.sellStepInterval(), 6 hours);
        assertEq(address(sales.PRICE_FEED()), address(priceFeed));
        assertEq(monthFactory.priceFeed(), address(priceFeed));
    }

    function test_OnlyOperatorPostsValidPrices() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(XMarketPriceFeed.NotOperator.selector);
        priceFeed.post(P, A, BSC_BLOCK);
        vm.expectRevert(XMarketPriceFeed.BadPrices.selector);
        priceFeed.post(0, A, BSC_BLOCK);
        vm.expectRevert(XMarketPriceFeed.BadPrices.selector);
        priceFeed.post(A + 1, A, BSC_BLOCK); // bid > ask
        vm.expectEmit(address(priceFeed));
        emit XMarketPriceFeed.PricesPosted(P, A, 0, 0, BSC_BLOCK, block.timestamp);
        priceFeed.post(P, A, BSC_BLOCK); // 测试合约是运营地址
        assertTrue(priceFeed.fresh());
        assertFalse(priceFeed.abandoned());
        assertEq(priceFeed.bid(), P);
        assertEq(priceFeed.ask(), A);
        assertEq(priceFeed.sourceBlock(), BSC_BLOCK, "BSC block recorded for verification");
    }

    function test_ChangeLimitAndMinIntervalForBothSides() public {
        uint256 b = P / 400 * 400;
        uint256 a = A / 400 * 400;
        priceFeed.post(b, a, 1);
        vm.expectRevert(XMarketPriceFeed.TooSoon.selector);
        priceFeed.post(b, a, 2);
        vm.warp(block.timestamp + 50 minutes);
        vm.expectRevert(XMarketPriceFeed.ChangeTooLarge.selector);
        priceFeed.post(b * 106 / 100, a, 2);
        vm.expectRevert(XMarketPriceFeed.ChangeTooLarge.selector);
        priceFeed.post(b, a * 94 / 100, 2);
        priceFeed.post(b * 105 / 100, a * 95 / 100, 2); // 恰好 ±5%
        // 停报再久也照样限幅（同 BSC）
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(XMarketPriceFeed.ChangeTooLarge.selector);
        priceFeed.post(b * 3, a * 3, 3);
        uint256 nb = priceFeed.bid() * 105 / 100;
        uint256 na = priceFeed.ask() * 105 / 100;
        priceFeed.post(nb, na, 3);
        assertEq(priceFeed.bid(), nb);
    }

    function test_StaleAndAbandoned() public {
        assertTrue(priceFeed.abandoned(), "never posted");
        assertFalse(priceFeed.fresh());
        priceFeed.post(P, A, 1);
        vm.warp(block.timestamp + 3 hours);
        assertFalse(priceFeed.fresh(), "stale after 3 hours");
        assertFalse(priceFeed.abandoned());
        vm.warp(priceFeed.updatedAt() + 7 days - 1);
        assertFalse(priceFeed.abandoned());
        vm.warp(priceFeed.updatedAt() + 7 days);
        assertTrue(priceFeed.abandoned(), "abandoned after 7 days");
        priceFeed.post(P, A, 2);
        vm.prank(FEE_SAFE);
        factory.setOperator(address(0));
        // 运营地址为 0 只是暂停（fresh 为假），7 天没报价才算停运
        assertFalse(priceFeed.abandoned(), "no operator is not abandonment");
        assertFalse(priceFeed.fresh());
        vm.warp(priceFeed.updatedAt() + 7 days);
        assertTrue(priceFeed.abandoned());
    }

    /// @dev 追价报价同样受限，不算有效报价，也不刷新停运计时
    function test_CatchUpIsNotLive() public {
        priceFeed.post(P, A, 1);
        uint256 live = priceFeed.liveAt();
        vm.prank(address(0xBAD));
        vm.expectRevert(XMarketPriceFeed.NotOperator.selector);
        priceFeed.postCatchUp(P, A, 2);
        vm.expectRevert(XMarketPriceFeed.TooSoon.selector);
        priceFeed.postCatchUp(P, A, 2);
        vm.warp(block.timestamp + 50 minutes);
        vm.expectRevert(XMarketPriceFeed.ChangeTooLarge.selector);
        priceFeed.postCatchUp(P * 2, A * 2, 2);
        uint256 nb = P * 95 / 100 + 1;
        uint256 na = A * 95 / 100 + 1;
        vm.expectEmit(address(priceFeed));
        emit XMarketPriceFeed.CatchUpPosted(nb, na, block.timestamp);
        priceFeed.postCatchUp(nb, na, 2);
        assertTrue(priceFeed.catchingUp());
        assertFalse(priceFeed.fresh(), "catching up is not live");
        assertEq(priceFeed.liveAt(), live, "catch-up does not refresh liveAt");
        vm.warp(priceFeed.updatedAt() + 50 minutes);
        priceFeed.post(nb, na, 3);
        assertFalse(priceFeed.catchingUp());
        assertTrue(priceFeed.fresh());
        assertEq(priceFeed.liveAt(), block.timestamp);
    }

    /// @dev 收购价上限同 BSC buyQuote：报价有效 → min(卖一, 上限)；从没报过价 → 默认曲线；报过价之后无效 → 0（暂停）
    function test_BuyQuoteSameAsBsc() public {
        // 夹具开局前没有报价时（本测试没开局）：从没报过价 → 默认曲线
        assertEq(priceFeed.updatedAt(), 0);
        assertEq(priceFeed.buyQuote(165_000_000, 123, 0), 123, "never posted: default curve");
        priceFeed.post(P, A, BSC_BLOCK);
        assertEq(priceFeed.buyQuote(165_000_000, 123, 0), A, "min(ask, cap)");
        assertEq(priceFeed.buyQuote(100_000_000, 123, 0), 100_000_000);
        vm.warp(block.timestamp + 3 hours);
        assertEq(priceFeed.buyQuote(165_000_000, 123, 0), 0, "stale: buying paused");
        priceFeed.postCatchUp(P, A, BSC_BLOCK + 1);
        assertEq(priceFeed.buyQuote(165_000_000, 123, 0), 0, "catching up: paused");
        vm.warp(priceFeed.updatedAt() + 50 minutes);
        priceFeed.post(P, A, BSC_BLOCK + 2);
        assertEq(priceFeed.buyQuote(165_000_000, 123, 0), A);
        vm.prank(FEE_SAFE);
        factory.setOperator(address(0));
        assertEq(priceFeed.buyQuote(165_000_000, 123, 0), 0, "operator 0: paused");
    }

    /// @dev 卖价同 BSC sellQuote：max(买一, 卖一 × (99% − 0.5% × 整 6 小时数))；报价无效 → 0
    function test_SellQuoteSameAsBsc() public {
        uint256 since = block.timestamp;
        assertEq(priceFeed.sellQuote(since), 0, "never posted");
        priceFeed.post(P, A, BSC_BLOCK);
        assertEq(priceFeed.sellQuote(since), A * 9_900 / 10_000);
        vm.warp(since + 6 hours - 1);
        assertEq(priceFeed.sellQuote(since), 0, "stale after 3 hours");
        priceFeed.post(P, A, BSC_BLOCK + 1);
        assertEq(priceFeed.sellQuote(since), A * 9_900 / 10_000, "still step 0");
        vm.warp(since + 6 hours);
        assertEq(priceFeed.sellQuote(since), A * 9_850 / 10_000, "one 6-hour step: -0.5%");
        // 降到买一以下之后按买一
        vm.warp(since + 6 hours * 100);
        priceFeed.post(P, A, BSC_BLOCK + 2);
        assertEq(priceFeed.sellQuote(since), P);
    }

    function test_ConstructorBounds() public {
        vm.expectRevert(XMarketPriceFeed.BadConfig.selector);
        new XMarketPriceFeed(address(0), 500, 50 minutes, 3 hours, 7 days, 9_900, 50, 6 hours);
        vm.expectRevert(XMarketPriceFeed.BadConfig.selector);
        new XMarketPriceFeed(address(factory), 0, 50 minutes, 3 hours, 7 days, 9_900, 50, 6 hours);
        vm.expectRevert(XMarketPriceFeed.BadConfig.selector);
        new XMarketPriceFeed(address(factory), 10_000, 50 minutes, 3 hours, 7 days, 9_900, 50, 6 hours);
        vm.expectRevert(XMarketPriceFeed.BadConfig.selector);
        new XMarketPriceFeed(address(factory), 500, 3 hours, 3 hours, 7 days, 9_900, 50, 6 hours); // 间隔不短于过期时间
        vm.expectRevert(XMarketPriceFeed.BadConfig.selector);
        new XMarketPriceFeed(address(factory), 500, 50 minutes, 3 hours, 1 hours, 9_900, 50, 6 hours); // 停运短于过期
        vm.expectRevert(XMarketPriceFeed.BadConfig.selector);
        new XMarketPriceFeed(address(factory), 500, 50 minutes, 3 hours, 7 days, 10_001, 50, 6 hours); // 起价超过卖一
        vm.expectRevert(XMarketPriceFeed.BadConfig.selector);
        new XMarketPriceFeed(address(factory), 500, 50 minutes, 3 hours, 7 days, 9_900, 50, 0); // 降价间隔为 0
        new XMarketPriceFeed(
            address(factory),
            XLayerDefaults.FEED_MAX_CHANGE_BPS,
            XLayerDefaults.FEED_MIN_INTERVAL,
            XLayerDefaults.FEED_MAX_STALENESS,
            XLayerDefaults.FEED_ABANDON_AFTER,
            XLayerDefaults.FEED_SELL_START_BPS,
            XLayerDefaults.FEED_SELL_STEP_BPS,
            XLayerDefaults.v2Timing().sellStepInterval
        );
    }
}
