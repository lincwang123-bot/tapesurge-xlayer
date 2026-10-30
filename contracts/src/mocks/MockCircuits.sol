// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

interface IMockTransistorsBurn {
    function burnFor(address from, uint256 id, uint256 amount) external;
}

/// @notice 仅用于测试 / 测试网：模拟 TapeOut 信标。任何人都能"升级"，用来测试升级哨兵。
contract MockBeacon {
    address public implementation;

    event Upgraded(address indexed implementation);

    constructor(address impl) {
        implementation = impl;
    }

    function upgradeTo(address impl) external {
        implementation = impl;
        emit Upgraded(impl);
    }
}

/// @notice 仅用于测试 / 测试网：模拟 TapeOut 电路合约（ERC-721 + 链上网表）。
/// @dev 网表格式（白皮书附录 B）：NAND 每个 7 字节 = 0x00 + 3 字节输入 a + 3 字节输入 b；
///      LATCH 每个 4 字节 = 0x01 + 3 字节输入。信号 0、1 是常量，接着是 nIn 个输入，
///      再接着依次是每个门的输出；输出 = 最后 nOut 个信号；按位打包、低位在前。
///      这里的 eval 只实现组合逻辑（NAND），足够验证通行证半加器。
contract MockCircuits is ERC721 {
    /// @notice 流片费（主网 0.0002 BNB；测试网快速模式可以调低）
    uint256 public immutable TAPEOUT_FEE;

    struct Info {
        uint32 nIn;
        uint32 nOut;
        uint32 nState;
        uint32 gateCount;
    }

    /// @notice 处理器的晶体管合约；为 0 时（模拟官方矿机电路）流片不烧晶体管。
    address public immutable transistors;
    uint256 public nextId = 1;
    mapping(uint256 => bytes) internal _netlist;
    mapping(uint256 => Info) internal _info;
    /// @notice 测试辅助：每个地址最近一次流片 / 铸出的电路编号（测试网场景脚本用它找到玩家的通行证）
    mapping(address => uint256) public lastMintedBy;

    error BadFee();
    error BadNetlist();

    constructor(string memory name_, string memory symbol_, address transistors_, uint256 tapeoutFee_)
        ERC721(name_, symbol_)
    {
        transistors = transistors_;
        TAPEOUT_FEE = tapeoutFee_;
    }

    function tapeout(bytes calldata nl, uint32 nIn, uint32 nOut) external payable returns (uint256 id) {
        if (msg.value != TAPEOUT_FEE) revert BadFee();
        (uint32 nands, uint32 latches) = _countGates(nl);
        if (transistors != address(0)) {
            if (nands > 0) IMockTransistorsBurn(transistors).burnFor(msg.sender, 0, nands);
            if (latches > 0) IMockTransistorsBurn(transistors).burnFor(msg.sender, 1, latches);
        }
        id = _store(msg.sender, nl, nIn, nOut, nands, latches);
    }

    /// @notice 测试辅助：不收费、不烧晶体管，直接铸一个电路（模拟已有的官方矿机）。
    function mintCircuit(address to, bytes calldata nl, uint32 nIn, uint32 nOut) external returns (uint256 id) {
        (uint32 nands, uint32 latches) = _countGates(nl);
        id = _store(to, nl, nIn, nOut, nands, latches);
    }

    function netlist(uint256 id) external view returns (bytes memory) {
        _requireOwned(id);
        return _netlist[id];
    }

    function circuitInfo(uint256 id) external view returns (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount) {
        _requireOwned(id);
        Info memory i = _info[id];
        return (i.nIn, i.nOut, i.nState, i.gateCount);
    }

    /// @notice 组合逻辑求值。input 按位打包、低位在前。
    function eval(uint256 id, bytes calldata input) external view returns (bytes memory out) {
        _requireOwned(id);
        bytes memory nl = _netlist[id];
        Info memory info = _info[id];
        uint256 nSignals = 2 + info.nIn + info.gateCount;
        uint8[] memory sig = new uint8[](nSignals);
        sig[1] = 1;
        for (uint256 b = 0; b < info.nIn; b++) {
            sig[2 + b] = (uint8(input[b / 8]) >> (b % 8)) & 1;
        }
        uint256 k = 2 + info.nIn;
        for (uint256 p = 0; p < nl.length;) {
            if (uint8(nl[p]) != 0) revert BadNetlist(); // 只支持 NAND
            uint256 a = _u24(nl, p + 1);
            uint256 c = _u24(nl, p + 4);
            sig[k++] = 1 - (sig[a] & sig[c]);
            p += 7;
        }
        out = new bytes((info.nOut + 7) / 8);
        for (uint256 b = 0; b < info.nOut; b++) {
            uint8 bit = sig[nSignals - info.nOut + b];
            out[b / 8] = bytes1(uint8(out[b / 8]) | (bit << uint8(b % 8)));
        }
    }

    function _store(address to, bytes calldata nl, uint32 nIn, uint32 nOut, uint32 nands, uint32 latches)
        internal
        returns (uint256 id)
    {
        id = nextId++;
        lastMintedBy[to] = id;
        _netlist[id] = nl;
        _info[id] = Info(nIn, nOut, latches, nands + latches);
        _mint(to, id);
    }

    function _countGates(bytes calldata nl) internal pure returns (uint32 nands, uint32 latches) {
        uint256 p;
        while (p < nl.length) {
            uint8 t = uint8(nl[p]);
            if (t == 0) {
                nands++;
                p += 7;
            } else if (t == 1) {
                latches++;
                p += 4;
            } else {
                revert BadNetlist();
            }
        }
        if (p != nl.length || nands + latches == 0) revert BadNetlist();
    }

    function _u24(bytes memory b, uint256 o) private pure returns (uint256) {
        return (uint256(uint8(b[o])) << 16) | (uint256(uint8(b[o + 1])) << 8) | uint256(uint8(b[o + 2]));
    }
}
