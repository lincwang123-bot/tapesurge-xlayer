// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {ITapeOutFactory, ITransistors, ICircuits} from "../src/interfaces/ITapeOut.sol";

interface IDemoTransistors is ITransistors {
    function mintPrice() external view returns (uint256);
    function balanceOf(address owner, uint256 id) external view returns (uint256);
}

/// @notice M5a: a small, explicitly non-Genesis processor for the competition.
/// @dev Reads no environment variables or signing material. forge script without
///      --broadcast only simulates these three calls. All written addresses are
///      labelled SIMULATED, including when Forge performs its pre-broadcast run.
contract XLayerDemoProcessor is Script {
    address public constant FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    address public constant OWNER = 0x9304e363D12Fd84a32E92fD274C8EDC82Dd7d965;
    uint256 public constant CHAIN_ID = 196;
    uint256 public constant SUPPLY = 100;
    string public constant NAME = "TapeSurge Demo (X Layer)";
    string public constant SYMBOL = "SURGE-DEMO";
    /// @dev 文字按 2026-10-21 此前给的建议参数（写明：不是创世通行证，主板不接受）
    string public constant STORY = "Demo processor for the X Layer TapeOut accelerator. "
        "Not a TapeSurge Genesis Pass; TapeSurge boards do not accept it.";
    bytes public constant HA1 = hex"0000000200000300000002000004000000030000040000000500000600000004000004";
    bytes32 public constant HA1_HASH = 0xfffa29f1e30fa6438ba0e6ebd40ef157b53d0eff3f21cc4bc46942e27cb32ca0;
    string public constant SIMULATION_FILE = "deployments/196-demo.simulation.json";
    /// @notice 本地 anvil 分叉演练（真实广播到本机分叉、拿 receipt）的记录；包装脚本会把 receipt 并进去
    string public constant REHEARSAL_FILE = "deployments/196-demo.rehearsal.json";

    struct Result {
        uint256 sourceBlock;
        address transistors;
        address circuits;
        uint256 circuitId;
        uint256 deployFee;
        uint256 protocolFee;
        uint256 tapeoutFee;
        uint256 valueSpent;
    }

    error WrongChain(uint256 actual);
    error MissingFactory();
    error FeeGetterUnavailable();
    error UnexpectedProcessor();
    error TapeoutFailed(bytes reason);
    error MissingCircuitMint();
    error CircuitVerificationFailed();

    function run() external returns (Result memory r) {
        r = _execute();
        _report(r, false, OWNER.balance + r.valueSpent, SIMULATION_FILE, "SIMULATED_NOT_DEPLOYED");
    }

    /// @notice 本地 anvil 分叉演练用：和 run() 执行完全相同的三笔调用，只是把预测结果写进 REHEARSAL_FILE，
    ///         不覆盖模拟记录。包装脚本只允许对本机 RPC 使用（`xlayer-demo.sh rehearse`）。
    function rehearse() external returns (Result memory r) {
        r = _execute();
        _report(r, false, OWNER.balance + r.valueSpent, REHEARSAL_FILE, "LOCAL_FORK_REHEARSAL_NOT_DEPLOYED");
    }

    /// @notice An unfunded owner can preview using local fork funds. This entry
    ///         point refuses broadcast/resume contexts, even if called directly.
    function simulate() external returns (Result memory r) {
        require(vm.isContext(VmSafe.ForgeContext.ScriptDryRun), "simulate is dry-run only");
        uint256 observedBalance = OWNER.balance;
        if (observedBalance < 1 ether) vm.deal(OWNER, 1 ether);
        r = _execute();
        _report(r, observedBalance < 1 ether, observedBalance, SIMULATION_FILE, "SIMULATED_NOT_DEPLOYED");
    }

    function _report(
        Result memory r,
        bool balanceOverridden,
        uint256 observedBalance,
        string memory file,
        string memory status
    ) internal {
        _writeSimulation(r, balanceOverridden, observedBalance, file, status);
        console2.log("SIMULATION-derived processor addresses; not proof of deployment");
        console2.log("source block", r.sourceBlock);
        console2.log("creator / circuit owner", OWNER);
        console2.log("transistors", r.transistors);
        console2.log("circuits", r.circuits);
        console2.log("HA1 circuit id", r.circuitId);
        console2.log("deploy fee wei", r.deployFee);
        console2.log("protocol fee per NAND wei", r.protocolFee);
        console2.log("tapeout fee wei", r.tapeoutFee);
        console2.log("total transaction value wei (excludes gas)", r.valueSpent);
        console2.log("owner balance observed on fork wei", observedBalance);
        console2.log("local simulation balance overridden", balanceOverridden);
    }

    function _execute() internal returns (Result memory r) {
        if (block.chainid != CHAIN_ID) revert WrongChain(block.chainid);
        if (FACTORY.code.length == 0) revert MissingFactory();
        r.sourceBlock = block.number;
        r.deployFee = ITapeOutFactory(FACTORY).deployFee();
        uint256 beforeBalance = OWNER.balance;
        vm.startBroadcast(OWNER);
        // Zero creator mint price is deliberate. If the protocol rejects it,
        // stop here; do not guess a replacement price or alter the approved plan.
        (r.transistors, r.circuits) =
            ITapeOutFactory(FACTORY).createCPU{value: r.deployFee}(NAME, SYMBOL, STORY, SUPPLY, 0);
        IDemoTransistors t = IDemoTransistors(r.transistors);
        if (t.creator() != OWNER || t.supplyCap() != SUPPLY || t.mintPrice() != 0 || t.NAND() != 0) {
            revert UnexpectedProcessor();
        }
        r.protocolFee = t.protocolFee();
        r.tapeoutFee = _tapeoutFee(r.circuits);
        t.mint{value: 5 * r.protocolFee}(0, 5);
        vm.recordLogs();
        // Deployed TapeOut versions may omit a return value; the ERC721 mint
        // event identifies the actual id without assuming it starts at 1.
        (bool ok, bytes memory reason) =
            r.circuits.call{value: r.tapeoutFee}(abi.encodeCall(ICircuits.tapeout, (HA1, 2, 2)));
        if (!ok) revert TapeoutFailed(reason);
        vm.stopBroadcast();
        r.circuitId = _mintedId(vm.getRecordedLogs(), r.circuits);
        ICircuits c = ICircuits(r.circuits);
        (uint32 nIn, uint32 nOut, uint32 nState, uint32 gates) = c.circuitInfo(r.circuitId);
        if (
            c.ownerOf(r.circuitId) != OWNER || keccak256(c.netlist(r.circuitId)) != HA1_HASH || nIn != 2 || nOut != 2
                || nState != 0 || gates != 5 || keccak256(c.eval(r.circuitId, hex"00")) != keccak256(hex"00")
                || keccak256(c.eval(r.circuitId, hex"01")) != keccak256(hex"01")
                || keccak256(c.eval(r.circuitId, hex"02")) != keccak256(hex"01")
                || keccak256(c.eval(r.circuitId, hex"03")) != keccak256(hex"02") || t.minted() != 5
                || t.balanceOf(OWNER, 0) != 0
        ) revert CircuitVerificationFailed();
        r.valueSpent = r.deployFee + 5 * r.protocolFee + r.tapeoutFee;
        // Forge's local execution does not debit transaction gas here.
        if (beforeBalance - OWNER.balance != r.valueSpent) revert UnexpectedProcessor();
    }

    function _tapeoutFee(address circuits) internal view returns (uint256 fee) {
        (bool ok, bytes memory data) = circuits.staticcall(abi.encodeWithSignature("TAPEOUT_FEE()"));
        if (!ok || data.length != 32) {
            (ok, data) = circuits.staticcall(abi.encodeWithSignature("tapeoutFee()"));
        }
        if (!ok || data.length != 32) revert FeeGetterUnavailable();
        fee = abi.decode(data, (uint256));
    }

    function _mintedId(Vm.Log[] memory logs, address circuits) internal pure returns (uint256) {
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == circuits && logs[i].topics.length == 4 && logs[i].topics[0] == transferTopic
                    && logs[i].topics[1] == bytes32(0) && logs[i].topics[2] == bytes32(uint256(uint160(OWNER)))
            ) return uint256(logs[i].topics[3]);
        }
        revert MissingCircuitMint();
    }

    function _writeSimulation(
        Result memory r,
        bool balanceOverridden,
        uint256 observedBalance,
        string memory file,
        string memory status
    ) internal {
        string memory key = "xlayer-demo-simulation";
        vm.serializeBool(key, "simulationOnly", true);
        vm.serializeString(key, "status", status);
        vm.serializeUint(key, "chainId", CHAIN_ID);
        vm.serializeUint(key, "sourceBlock", r.sourceBlock);
        vm.serializeBool(key, "localBalanceOverridden", balanceOverridden);
        vm.serializeUint(key, "observedOwnerBalanceWei", observedBalance);
        vm.serializeAddress(key, "factory", FACTORY);
        vm.serializeAddress(key, "creator", OWNER);
        vm.serializeAddress(key, "transistors", r.transistors);
        vm.serializeAddress(key, "circuits", r.circuits);
        vm.serializeUint(key, "circuitId", r.circuitId);
        vm.serializeString(key, "name", NAME);
        vm.serializeString(key, "symbol", SYMBOL);
        vm.serializeString(key, "story", STORY);
        vm.serializeUint(key, "supply", SUPPLY);
        vm.serializeUint(key, "mintPriceWei", 0);
        vm.serializeBytes32(key, "ha1NetlistHash", HA1_HASH);
        vm.serializeUint(key, "deployFeeWei", r.deployFee);
        vm.serializeUint(key, "protocolFeePerNandWei", r.protocolFee);
        vm.serializeUint(key, "tapeoutFeeWei", r.tapeoutFee);
        vm.serializeUint(key, "transactionValueWei", r.valueSpent);
        string memory json = vm.serializeString(key, "gasCost", "See Forge estimate; no actual transaction fees paid");
        vm.writeJson(json, file);
    }
}
