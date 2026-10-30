// TapeOut 合约没有公开源码。下面的函数名和签名来自 BSC 主网链上读取（2026-10-20）和合约仓库里的 ITapeOut.sol。
// 注意：主网晶体管合约的协议费读 protocolFee()，测试网 mock 读 PROTOCOL_FEE()，两个都列出来，读的时候依次尝试。
import { parseAbi } from 'viem';

export const transistorsAbi = parseAbi([
  'function mint(uint256 id, uint256 amount) payable',
  'function mintPrice() view returns (uint256)',
  'function protocolFee() view returns (uint256)',
  'function PROTOCOL_FEE() view returns (uint256)',
  'function minted() view returns (uint256)',
  'function supplyCap() view returns (uint256)',
  'function balanceOf(address account, uint256 id) view returns (uint256)',
]);

export const circuitsAbi = parseAbi([
  'function tapeout(bytes nl, uint32 nIn, uint32 nOut) payable returns (uint256)',
  'function TAPEOUT_FEE() view returns (uint256)',
  'function netlist(uint256 id) view returns (bytes)',
  'function ownerOf(uint256 id) view returns (address)',
  'function balanceOf(address owner) view returns (uint256)',
  'function nextId() view returns (uint256)', // 下一个电路编号（已流片 nextId − 1 个，编号从 1 开始；2026-10-27 主网读取）
  'function approve(address to, uint256 id)',
  'function getApproved(uint256 id) view returns (address)',
  'function isApprovedForAll(address owner, address operator) view returns (bool)',
  'event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)',
]);

/// 通行证电路：半加器 HA1，5 个 NAND（白皮书附录 B）。网表哈希和合约里的 PASS_NETLIST_HASH 一致。
export const PASS_NETLIST = '0x0000000200000300000002000004000000030000040000000500000600000004000004';
export const PASS_NETLIST_HASH = '0xfffa29f1e30fa6438ba0e6ebd40ef157b53d0eff3f21cc4bc46942e27cb32ca0';
export const PASS_TRANSISTORS = 5n;
