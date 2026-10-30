// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {XLayerDemoProcessor} from "../script/XLayerDemoProcessor.s.sol";
import {MockTapeOutFactory, MockTransistors} from "../src/mocks/MockTapeOut.sol";
import {ICircuits} from "../src/interfaces/ITapeOut.sol";

contract DemoProcessorHarness is XLayerDemoProcessor {
    function executeWithoutReport() external returns (Result memory) {
        return _execute();
    }
}

contract ZeroPriceRejectingFactory {
    function deployFee() external pure returns (uint256) {
        return 0;
    }

    function createCPU(string calldata, string calldata, string calldata, uint256, uint256 price)
        external
        payable
        returns (address, address)
    {
        require(price > 0, "zero creator mint price rejected");
        revert("should not choose a replacement price");
    }
}

contract XLayerDemoProcessorTest is Test {
    DemoProcessorHarness internal script;

    function setUp() public {
        script = new DemoProcessorHarness();
        vm.chainId(196);
        MockTapeOutFactory template = new MockTapeOutFactory(0.001 ether, 0.0001 ether, 0.0002 ether);
        vm.etch(script.FACTORY(), address(template).code);
        vm.deal(script.OWNER(), 1 ether);
    }

    function test_ThreeCallsCreateDemoAndOneVerifiedHA1() public {
        XLayerDemoProcessor.Result memory r = script.executeWithoutReport();
        assertEq(MockTransistors(r.transistors).creator(), script.OWNER());
        assertEq(MockTransistors(r.transistors).supplyCap(), 100);
        assertEq(MockTransistors(r.transistors).mintPrice(), 0);
        assertEq(MockTransistors(r.transistors).minted(), 5);
        assertEq(MockTransistors(r.transistors).balanceOf(script.OWNER(), 0), 0);
        assertEq(ICircuits(r.circuits).ownerOf(r.circuitId), script.OWNER());
        assertEq(keccak256(ICircuits(r.circuits).netlist(r.circuitId)), script.HA1_HASH());
        assertEq(r.valueSpent, 0.0017 ether);
        assertEq(script.OWNER().balance, 1 ether - r.valueSpent);
    }

    function test_RejectsWrongChainBeforeAnySpending() public {
        vm.chainId(56);
        vm.expectRevert(abi.encodeWithSelector(XLayerDemoProcessor.WrongChain.selector, 56));
        script.executeWithoutReport();
        assertEq(script.OWNER().balance, 1 ether);
    }

    function test_RejectsMissingFactory() public {
        vm.etch(script.FACTORY(), hex"");
        vm.expectRevert(XLayerDemoProcessor.MissingFactory.selector);
        script.executeWithoutReport();
    }

    function test_NoGuessedReplacementWhenZeroPriceRejected() public {
        ZeroPriceRejectingFactory rejecting = new ZeroPriceRejectingFactory();
        vm.etch(script.FACTORY(), address(rejecting).code);
        vm.expectRevert(bytes("zero creator mint price rejected"));
        script.executeWithoutReport();
        assertEq(script.OWNER().balance, 1 ether);
    }
}

/// @notice Explicitly opt in via Forge --fork-url; no RPC or key is read from env.
///         On the ordinary local suite this test is skipped, not reported as a fork pass.
contract XLayerDemoProcessorForkTest is Test {
    function test_Fork_OfficialFactoryZeroPriceDemoAndHA1() public {
        DemoProcessorHarness script = new DemoProcessorHarness();
        if (block.chainid != 196 || script.FACTORY().code.length == 0) {
            vm.skip(true);
            return;
        }
        // Only the local fork balance is funded. No remote state or wallet is changed.
        vm.deal(script.OWNER(), 1 ether);
        uint256 gasBefore = gasleft();
        XLayerDemoProcessor.Result memory r = script.executeWithoutReport();
        console2.log("REPORT mainnet fork block", r.sourceBlock);
        console2.log("REPORT createCPU deploy fee wei", r.deployFee);
        console2.log("REPORT protocol fee per NAND wei", r.protocolFee);
        console2.log("REPORT HA1 tapeout fee wei", r.tapeoutFee);
        console2.log("REPORT three-call value total wei", r.valueSpent);
        console2.log("REPORT execution and assertions gas (not receipt gas)", gasBefore - gasleft());
        console2.log("REPORT simulated transistors", r.transistors);
        console2.log("REPORT simulated circuits", r.circuits);
        console2.log("REPORT simulated circuit id", r.circuitId);
        assertEq(MockTransistors(r.transistors).creator(), script.OWNER());
        assertEq(MockTransistors(r.transistors).mintPrice(), 0);
        assertEq(MockTransistors(r.transistors).supplyCap(), 100);
        assertEq(keccak256(ICircuits(r.circuits).netlist(r.circuitId)), script.HA1_HASH());
    }
}
