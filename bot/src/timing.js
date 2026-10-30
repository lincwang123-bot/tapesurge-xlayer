// 测试网部署会把规则里的时长按比例缩短（部署文件的 timeDivisor；BSC 第一次快速部署只记了 fast，等于 720 倍），
// 机器人的检查间隔按同样比例缩短，最短 15 秒。主网（BSC 56、X Layer 196）永远按正常间隔。
const MAINNETS = new Set([56, 196]);

export function timeDivisor(deployment, chainId) {
  if (MAINNETS.has(chainId)) return 1;
  const raw = deployment.timeDivisor ?? (deployment.fast ? 720 : 1);
  const divisor = Number(raw);
  if (!Number.isSafeInteger(divisor) || divisor < 1) {
    throw new Error('部署文件的 timeDivisor 必须是正整数');
  }
  return divisor;
}

export function checkInterval(seconds, deployment, chainId) {
  const divisor = timeDivisor(deployment, chainId);
  if (divisor === 1) return seconds;
  return Math.max(15, Math.round(seconds / divisor));
}
