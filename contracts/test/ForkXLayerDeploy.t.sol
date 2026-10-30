// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {XLayerDefaults} from "../script/XLayerDefaults.sol";
import {XLayerDeploy, IV3PoolCardinality} from "../script/XLayerDeploy.sol";
import {DeployXLayerMainnet} from "../script/DeployXLayerMainnet.s.sol";
import {XMonthBoard} from "../src/XMonthBoard.sol";
import {ITransistors} from "../src/interfaces/ITapeOut.sol";

/// @dev 只读的 Safe 桩（2/3）：真实部署时用 X Layer 上新建的两个 Safe
contract SafeStub {
    function getThreshold() external pure returns (uint256) {
        return 2;
    }

    function getOwners() external pure returns (address[] memory o) {
        o = new address[](3);
        o[0] = address(0x0A1);
        o[1] = address(0x0A2);
        o[2] = address(0x0A3);
    }

    receive() external payable {}
}

/// @notice M5 主网部署逻辑在 X Layer 主网分叉上整套执行一遍（本地分叉，不广播）：部署前自检、六个合约、预测地址、
///         和 XLayerDefaults 一致的参数，并统计 gas。池子扩容（实测 40,037,997 gas）由 ForkXLayerBuyback 单独测；
///         这里把 slot0 的 cardinalityNext 读数 mock 成 1,800，部署逻辑就会跳过扩容（否则分叉上要逐个远程读 1,800 个存储槽，约 13 分钟）。
///         运行：XLAYER_RPC_URL=https://rpc.xlayer.tech forge test --match-contract ForkXLayerDeployTest -vv
contract ForkXLayerDeployTest is Test {
    bool internal live;

    function setUp() public {
        string memory rpc = vm.envOr("XLAYER_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        live = true;
    }

    function test_Fork_MainnetDeploymentWiringAndGas() public {
        if (!live) vm.skip(true);
        XLayerDefaults.Mainnet memory m = XLayerDefaults.mainnet();
        (uint160 sqrtP, int24 tick, uint16 index, uint16 card,,,) = IV3PoolCardinality(m.pool).slot0();
        vm.mockCall(
            m.pool,
            abi.encodeWithSelector(IV3PoolCardinality.slot0.selector),
            abi.encode(sqrtP, tick, index, card, XLayerDefaults.OBSERVATION_CARDINALITY, uint8(0), true)
        );
        XLayerDeploy.Settings memory s = XLayerDeploy.Settings({
            operator: address(0x0BE7),
            foundation: address(new SafeStub()),
            feeSafe: address(new SafeStub()),
            mintPrice: XLayerDefaults.DEFAULT_MINT_PRICE
        });
        vm.deal(address(this), 1 ether);
        new DeployXLayerMainnet().preflight(address(this), s);

        uint256 g = gasleft();
        XLayerDeploy.Deployment memory d = XLayerDeploy.deployMainnet(address(this), s);
        uint256 used = g - gasleft();
        console2.log("REPORT deployment gas (12 contracts incl. v2 singletons and the RIG market, without the cardinality increase)", used);
        console2.log("REPORT OKB at 0.02 gwei incl. 0.0066 deployFee (wei)", used * 0.02 gwei + 0.0066 ether);
        assertFalse(d.cardinalityRaised);

        ITransistors t = d.hub.transistors();
        assertEq(t.supplyCap(), 6_666, "X Layer: 1,333 passes");
        assertEq(d.splitter.projectBps(), 10_000, "X Layer: all mint revenue to the fee Safe");
        assertEq(d.splitter.project(), s.feeSafe);
        assertEq(t.creator(), address(d.splitter));
        (, bytes memory price) = address(t).staticcall(abi.encodeWithSignature("mintPrice()"));
        assertEq(abi.decode(price, (uint256)), 0.006 ether);
        assertEq(d.hub.operator(), s.operator);
        assertEq(d.hub.feeRecipient(), s.feeSafe);
        assertEq(d.splitter.foundation(), s.foundation);
        assertEq(d.oracle.pool(), m.pool);
        assertEq(address(d.machineSource.rig()), m.rig);
        assertEq(d.machineSource.expectedCircuits(), m.bscMachineCircuits);
        XMonthBoard impl = XMonthBoard(d.monthFactory.boardImplementation());
        assertEq(impl.MACHINE_TOKEN(), m.rig);
        assertEq(impl.RANDOM_SOURCE(), address(d.adapter));
        assertEq(impl.PASS_BEACON(), m.circuitsBeacon);
        assertFalse(impl.sentinelTripped());
        assertEq(d.monthFactory.boardConfig().buyMaxPrice, 165_000_000);
        assertEq(d.monthFactory.nextTarget(), 100e8);
        assertEq(d.adapter.minDelay(), 10 minutes);
        assertEq(d.adapter.operatorGrace(), 3 days);
        assertEq(address(d.v2.sales.PRICE_FEED()), address(d.v2.priceFeed));
        assertEq(address(d.v2.priceFeed.HUB()), address(d.hub));
        assertEq(d.v2.priceFeed.minInterval(), 50 minutes);
        assertEq(d.v2.priceFeed.maxStaleness(), 3 hours);
        assertEq(d.v2.priceFeed.abandonAfter(), 7 days);
        assertEq(d.v2.priceFeed.sellStartBps(), 9_900, "BSC sell formula");
        assertEq(d.v2.priceFeed.sellStepBps(), 50);
        assertEq(d.v2.priceFeed.sellStepInterval(), 6 hours);
        assertTrue(d.v2.priceFeed.abandoned(), "no relay yet: liquidation plans fall back to cost");
        assertEq(impl.MARKET(), address(d.v2.market), "board buys from the RIG market at the ask price");
        assertEq(address(d.v2.market.RIG()), m.rig);
        assertEq(address(d.v2.market.BEM()), m.bem);
        assertEq(address(d.v2.market.SALES()), address(d.v2.sales));
        assertEq(address(d.v2.market.FACTORY()), address(d.monthFactory));
        assertEq(d.v2.market.FEE_RECIPIENT(), s.feeSafe);
        assertEq(d.v2.market.FEE_BPS(), 0, "market fee 0 (user decision 2026-10-29)");
    }
}
