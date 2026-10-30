// drand evmnet 签名获取（X Layer 版开奖用）。签名是 drand 网络按轮次确定生成的，谁去取、谁去交都一样，
// 合约会在链上用 BN254 预编译验签，所以这里不用信任任何一个中继：取到错误的签名，交付会以 InvalidSignature 失败。
const CHAIN_HASH = '04f1e9062b8a81f848fded9c12306733282b2727ecced50032187751166ec8c3';
const RELAYS = [
  (r) => `https://api.drand.sh/v2/beacons/evmnet/rounds/${r}`,
  (r) => `https://api2.drand.sh/v2/beacons/evmnet/rounds/${r}`,
  (r) => `https://api3.drand.sh/v2/beacons/evmnet/rounds/${r}`,
  (r) => `https://api.drand.sh/${CHAIN_HASH}/public/${r}`, // v1 接口（drand.cloudflare.com 不提供 evmnet，2026-10-21 实测）
];

/** 解析中继的返回：{ round, signature }，签名是 64 字节的 BN254 G1 点（x ‖ y），128 个十六进制字符 */
export function parseBeacon(json, round) {
  if (!json || Number(json.round) !== Number(round)) throw new Error(`drand 返回的轮次不对：要 ${round}，得到 ${json?.round}`);
  const sig = String(json.signature ?? '').replace(/^0x/, '');
  if (!/^[0-9a-fA-F]{128}$/.test(sig)) throw new Error('drand 签名格式不对（应为 128 个十六进制字符）');
  return `0x${sig.toLowerCase()}`;
}

/** 依次尝试各个中继，返回 `0x…` 签名；这一轮还没产生时中继返回错误，调用方下一轮再试 */
export async function fetchSignature(round, { fetchImpl = fetch, timeoutMs = 10_000 } = {}) {
  const errors = [];
  for (const url of RELAYS) {
    try {
      const res = await fetchImpl(url(round), { signal: AbortSignal.timeout(timeoutMs) });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return parseBeacon(await res.json(), round);
    } catch (e) {
      errors.push(e.message);
    }
  }
  throw new Error(`取不到 drand 第 ${round} 轮签名：${errors.join('；')}`);
}
