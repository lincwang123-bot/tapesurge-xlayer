// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {XMonthBoard} from "../src/XMonthBoard.sol";
import {XMonthFactory} from "../src/XMonthFactory.sol";
import {XHub} from "../src/XHub.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {XLayerDefaults} from "../script/XLayerDefaults.sol";

/// @notice 按主网规则检查合约大小：运行时 ≤ 24,576 字节（EIP-170），初始化代码 + 构造参数 ≤ 49,152 字节（EIP-3860）。
/// @dev v2 起不再继承 Fixture：夹具要用 new 部署全部合约，测试合约自己的创建代码会嵌入所有字节码，在 sizecheck 配置下
///      超出初始化代码上限（超的是测试合约，不是生产合约）。这里直接读编译产物：运行时长度和实际部署一致（immutable 占位
///      长度固定），构造参数用和主网相同的结构体编码（只有字符串长度会影响编码长度，取主网的默认文案）。
contract SizeLimitsTest is Test {
    address internal constant A = address(0xA11);

    function test_ProductionContractsFitMainnetSizeLimits() public {
        _runtime("XMonthBoard.sol:XMonthBoard");
        _runtime("XMonthFactory.sol:XMonthFactory");
        _runtime("XHub.sol:XHub");
        _runtime("GenesisSplitter.sol:GenesisSplitter");
        _runtime("RigMachineSource.sol:RigMachineSource");
        _runtime("DrandEvmnetAdapter.sol:DrandEvmnetAdapter");
        _runtime("UniswapV3TwapOracle.sol:UniswapV3TwapOracle");
        _runtime("XMonthPositions.sol:XMonthPositions");
        _runtime("XMonthExitGovernor.sol:XMonthExitGovernor");
        _runtime("XMonthMachineSales.sol:XMonthMachineSales");
        _runtime("XMarketPriceFeed.sol:XMarketPriceFeed");
        _runtime("XPositionExchange.sol:XPositionExchange");
        _runtime("XRigMarket.sol:XRigMarket");

        XLayerDefaults.Addresses memory a = XLayerDefaults.Addresses({
            tapeoutFactory: A,
            passBeacon: A,
            bem: A,
            machineSource: A,
            randomSource: A,
            wrappedNative: A,
            router: A,
            oracle: A,
            foundation: A,
            feeSafe: address(0xF2),
            positions: A,
            sales: A,
            governor: A,
            market: A
        });
        XMonthFactory.Params memory mp = XLayerDefaults.monthParams(a);
        GenesisSplitter.Params memory sp = XLayerDefaults.splitterParams(a, XLayerDefaults.DEFAULT_MINT_PRICE);
        sp.boardFactory = A;
        _initcode("GenesisSplitter.sol:GenesisSplitter", abi.encode(sp));
        _initcode("XHub.sol:XHub", abi.encode(XHub.Params(A, A, A, 10_000, 7 days)));
        _initcode("XMonthFactory.sol:XMonthFactory", abi.encode(A, mp));
        _initcode("XMonthBoard.sol:XMonthBoard", abi.encode(mp.board));
        _initcode("RigMachineSource.sol:RigMachineSource", abi.encode(A, A, 10, 300, 3 days));
        _initcode("DrandEvmnetAdapter.sol:DrandEvmnetAdapter", abi.encode(A, 30, 3 days));
        _initcode("UniswapV3TwapOracle.sol:UniswapV3TwapOracle", abi.encode(A, A, A, uint32(30 minutes)));
        _initcode("XMonthPositions.sol:XMonthPositions", abi.encode(A));
        _initcode(
            "XMonthExitGovernor.sol:XMonthExitGovernor", abi.encode(A, A, 7 days, 1 days, 1 days, 2 days, 14 days, 7 days)
        );
        _initcode(
            "XMonthMachineSales.sol:XMonthMachineSales", abi.encode(A, A, A, A, 3 days, 7 days, 1 days, 7 days, A)
        );
        _initcode("XPositionExchange.sol:XPositionExchange", abi.encode(A, A, A));
        _initcode("XRigMarket.sol:XRigMarket", abi.encode(A, 0));
        _initcode("XMarketPriceFeed.sol:XMarketPriceFeed", abi.encode(A, 500, 50 minutes, 3 hours, 7 days));
    }

    function _runtime(string memory artifact) internal view {
        uint256 size = vm.getDeployedCode(artifact).length;
        console2.log(artifact, size);
        assertLe(size, 24_576, "EIP-170 runtime size");
    }

    function _initcode(string memory artifact, bytes memory args) internal view {
        uint256 size = vm.getCode(artifact).length + args.length;
        console2.log(artifact, size);
        assertLe(size, 49_152, "EIP-3860 initcode plus args");
    }
}
