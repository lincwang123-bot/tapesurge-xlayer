// 测试网：用部署钱包成交 MachineLister 在 MockFirstoSignedAsk 上的签名卖单
// 用法：TESTNET_DEPLOYER_PK=… node fill-firsto.mjs <board> <index> [send]
import { createPublicClient, createWalletClient, http, parseAbi } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { bscTestnet } from 'viem/chains';

const RPC = process.env.RPC || 'https://bsc-testnet-rpc.publicnode.com';
const LISTER = '0x4650641D96F825ae70E692D1B08AE7FACC9D9a54';
const FIRSTO = '0x5C53B4E4b796719CC11E3508c5Fd6CDdEf3c957A';
const T = '(address maker,address collection,uint256 tokenId,uint256 nonce,uint128 price,uint64 expiry,address payoutRecipient,uint16 feeBps,uint256 feeEpoch,uint16 schemaVersion)';
const abi = parseAbi([
  `function firstoAsk(address board,uint256 index) view returns (${T} ask, bytes32 digest)`,
  `function fillSignedAsk(${T} ask, bytes signature, address nftRecipient) payable`,
  'function ownerOf(uint256) view returns (address)',
  'function getApproved(uint256) view returns (address)',
]);
const [board, index, send] = process.argv.slice(2);
const pub = createPublicClient({ chain: bscTestnet, transport: http(RPC) });
const [ask, digest] = await pub.readContract({ address: LISTER, abi, functionName: 'firstoAsk', args: [board, BigInt(index)] });
const value = ask.price + (ask.price * BigInt(ask.feeBps)) / 10000n;
const owner = await pub.readContract({ address: ask.collection, abi, functionName: 'ownerOf', args: [ask.tokenId] });
const approved = await pub.readContract({ address: ask.collection, abi, functionName: 'getApproved', args: [ask.tokenId] });
console.log(JSON.stringify({ ...ask, tokenId: String(ask.tokenId), nonce: String(ask.nonce), price: String(ask.price), expiry: String(ask.expiry), feeEpoch: String(ask.feeEpoch), digest, value: String(value), owner, approved }, null, 1));
if (send !== 'send') process.exit(0);
const account = privateKeyToAccount(process.env.TESTNET_DEPLOYER_PK);
const w = createWalletClient({ account, chain: bscTestnet, transport: http(RPC) });
const hash = await w.writeContract({ address: FIRSTO, abi, functionName: 'fillSignedAsk', args: [ask, '0x01', account.address], value });
const r = await pub.waitForTransactionReceipt({ hash });
console.log('tx', hash, r.status, 'gasUsed', String(r.gasUsed));
console.log('新主人', await pub.readContract({ address: ask.collection, abi, functionName: 'ownerOf', args: [ask.tokenId] }));
