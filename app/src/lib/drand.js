// X Layer 开奖用的 drand evmnet 签名（和 bot/src/drand.js 同一套中继）。签名是 drand 网络按轮次确定生成的，谁去取、谁去交都一样，
// 适配器会在链上验签，所以不用信任中继：取到错误的签名，交付会以 InvalidSignature 失败。
// 用途：运营地址超过宽限期没交签名时，本局持仓的持有人可以自己交（全局审计 2026-10-29 第 7 条），
// 否则只能等 7 天"不抽奖结算"。
import { parseAbi } from 'viem';

const CHAIN_HASH = '04f1e9062b8a81f848fded9c12306733282b2727ecced50032187751166ec8c3';
/** 中继的源站（vite.config.js 把它们加进内容安全策略的 connect-src） */
export const DRAND_ORIGINS = ['https://api.drand.sh', 'https://api2.drand.sh', 'https://api3.drand.sh'];
const RELAYS = [
  (r) => `${DRAND_ORIGINS[0]}/v2/beacons/evmnet/rounds/${r}`,
  (r) => `${DRAND_ORIGINS[1]}/v2/beacons/evmnet/rounds/${r}`,
  (r) => `${DRAND_ORIGINS[2]}/v2/beacons/evmnet/rounds/${r}`,
  (r) => `${DRAND_ORIGINS[0]}/${CHAIN_HASH}/public/${r}`, // v1 接口
];

export const DrandAbi = parseAbi([
  'function requests(uint256 requestId) view returns (address consumer, uint64 round, bool fulfilled)',
  'function roundTime(uint64 round) view returns (uint256)',
  'function fulfill(uint256 requestId, bytes signature)',
  'error UnknownRequest()',
  'error AlreadyFulfilled()',
  'error NotAuthorized()',
  'error InvalidSignature()',
]);

/** 解析中继的返回：签名是 64 字节的 BN254 G1 点（x ‖ y），128 个十六进制字符 */
function parseBeacon(json, round) {
  if (!json || Number(json.round) !== Number(round)) throw new Error(`drand round mismatch: ${json?.round}`);
  const sig = String(json.signature ?? '').replace(/^0x/, '');
  if (!/^[0-9a-fA-F]{128}$/.test(sig)) throw new Error('bad drand signature');
  return `0x${sig.toLowerCase()}`;
}

/** 依次尝试各个中继，返回 `0x…` 签名；都失败时抛出（这一轮还没产生时中继也会返回错误） */
export async function fetchDrandSignature(round) {
  const errors = [];
  for (const url of RELAYS) {
    try {
      const res = await fetch(url(round), { signal: AbortSignal.timeout(10_000) });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return parseBeacon(await res.json(), round);
    } catch (e) {
      errors.push(e.message);
    }
  }
  throw new Error(errors.join('; '));
}

/**
 * 这块月局等待中的 drand 请求：{ id, round, at, fulfilled, mine }。
 * mine = 请求确实属于这块主板（重发的请求沿用同一轮，所以只看 pendingRequestId）。
 */
export async function pendingDrand(client, adapter, board, requestId) {
  const [consumer, round, fulfilled] = await client.readContract({ address: adapter, abi: DrandAbi, functionName: 'requests', args: [requestId] });
  const at = await client.readContract({ address: adapter, abi: DrandAbi, functionName: 'roundTime', args: [round] });
  return { id: requestId, round, at, fulfilled, mine: consumer.toLowerCase() === board.toLowerCase() };
}
