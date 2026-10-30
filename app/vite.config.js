import { existsSync } from 'node:fs';
import { defineConfig, loadEnv } from 'vite';
import react from '@vitejs/plugin-react';
import { DEFAULT_RPCS, rpcList } from './src/lib/rpcs.js';
import { DRAND_ORIGINS } from './src/lib/drand.js';

// 内容安全策略：页面只执行自己的脚本、只加载自己的样式 / 字体 / 图片，只连接自己的 /api 和下面这些 RPC，
// 也不能被别的网站嵌进框架里。即使页面被注入了恶意代码，它也不能从别的域名加载脚本，或者把数据发到别处。
// 两份一样的策略：dist/_headers 由 Cloudflare 加到每个响应上（含 frame-ancestors）；index.html 里的 meta 标签兜底。
function contentSecurityPolicy(mode) {
  const env = loadEnv(mode, process.cwd(), 'VITE_');
  // 主网部署之后正式版只显示主网（和 src/lib/chains.js 的 MAINNET_ONLY 一致），测试网节点也不放进 connect-src
  const mainnetOnly = existsSync(new URL('./src/deployments/56.json', import.meta.url)) && env.VITE_ENABLE_TESTNET !== '1';
  const rpcs = [...rpcList(env.VITE_RPC_56, DEFAULT_RPCS[56]), ...(mainnetOnly ? [] : rpcList(env.VITE_RPC_97, DEFAULT_RPCS[97]))];
  // X Layer 版（和 src/lib/chains.js 一致：有部署文件、没有 VITE_DISABLE_XLAYER=1 才连）
  for (const id of [196, 1952]) {
    if (env.VITE_DISABLE_XLAYER !== '1' && existsSync(new URL(`./src/deployments/${id}.json`, import.meta.url))) {
      rpcs.push(...rpcList(env[`VITE_RPC_${id}`], DEFAULT_RPCS[id]));
      rpcs.push(...DRAND_ORIGINS); // 持有人兜底交 drand 签名时从中继取签名（全局审计 2026-10-29 第 7 条）
    }
  }
  if (env.VITE_ENABLE_LOCAL === '1') rpcs.push(...rpcList(env.VITE_RPC_31337, ['http://127.0.0.1:8547']));
  if (env.VITE_API_BASE) rpcs.push(env.VITE_API_BASE);
  const connect = ["'self'", ...new Set(rpcs.map((u) => new URL(u).origin))].join(' ');
  const base = [
    "default-src 'self'",
    "script-src 'self'",
    "style-src 'self'",
    "img-src 'self' data:", // 钱包图标（EIP-6963）是 data: 地址
    "font-src 'self'",
    `connect-src ${connect}`,
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
  ];
  const header = [...base, "frame-ancestors 'none'"].join('; ');
  return {
    name: 'tapesurge-csp',
    apply: 'build',
    transformIndexHtml: () => [{ tag: 'meta', attrs: { 'http-equiv': 'Content-Security-Policy', content: base.join('; ') }, injectTo: 'head-prepend' }],
    generateBundle() {
      const lines = ['/*', `  Content-Security-Policy: ${header}`, '  X-Content-Type-Options: nosniff', '  Referrer-Policy: strict-origin-when-cross-origin', ''];
      this.emitFile({ type: 'asset', fileName: '_headers', source: lines.join('\n') });
    },
  };
}

export default defineConfig(({ mode }) => ({
  base: './',
  plugins: [react(), contentSecurityPolicy(mode)],
  server: { host: '127.0.0.1', port: 5174, strictPort: true },
  build: { target: 'es2022', assetsInlineLimit: 0 },
}));
