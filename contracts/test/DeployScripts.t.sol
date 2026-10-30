// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployXLayerMainnet} from "../script/DeployXLayerMainnet.s.sol";
import {XLayerDeploy} from "../script/XLayerDeploy.sol";
import {XLayerDefaults} from "../script/XLayerDefaults.sol";

/// @notice 部署脚本的参数检查（不连网络）：X Layer 的两个 Safe 没填时主网部署脚本拒绝运行；只接受链 ID 196
contract DeployScriptsTest is Test {
    DeployXLayerMainnet internal d = new DeployXLayerMainnet();

    function test_RefusesWithoutSafesOrOperator() public {
        // 外层环境（例如 xlayer-mainnet.sh 部署前跑测试时）可能已经导出了这几个变量：先显式置成"没填"
        vm.setEnv("FOUNDATION_SAFE", vm.toString(address(0)));
        vm.setEnv("FEE_SAFE", vm.toString(address(0)));
        vm.setEnv("OPERATOR", vm.toString(address(0)));
        vm.setEnv("MINT_PRICE_WEI", "6000000000000000");
        vm.expectRevert(bytes("set FOUNDATION_SAFE (X Layer foundation Safe; required)"));
        d.settings(address(this));
        vm.setEnv("FOUNDATION_SAFE", vm.toString(address(0xF00D)));
        vm.expectRevert(bytes("set FEE_SAFE (X Layer fee Safe; required)"));
        d.settings(address(this));
        vm.setEnv("FEE_SAFE", vm.toString(address(0xFEE5)));
        vm.expectRevert(bytes("set OPERATOR (operator hot wallet address, non-zero)"));
        d.settings(address(this));
        vm.setEnv("OPERATOR", vm.toString(address(0x0BE7)));
        XLayerDeploy.Settings memory s = d.settings(address(this));
        assertEq(s.foundation, address(0xF00D));
        assertEq(s.feeSafe, address(0xFEE5));
        assertEq(s.mintPrice, XLayerDefaults.DEFAULT_MINT_PRICE, "default 0.006 OKB");
        vm.setEnv("MINT_PRICE_WEI", "6044000000000000");
        assertEq(d.settings(address(this)).mintPrice, 0.006044 ether, "recomputed on deployment day");
        vm.setEnv("MINT_PRICE_WEI", "6000000000000000");
    }

    function test_RefusesOtherChains() public {
        vm.expectRevert(bytes("DeployXLayerMainnet: only X Layer mainnet (chain id 196)"));
        d.run();
    }
}
