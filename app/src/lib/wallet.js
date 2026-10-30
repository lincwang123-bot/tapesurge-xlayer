// 浏览器钱包连接：按 EIP-6963 发现已安装的钱包（MetaMask、OKX Wallet、Binance Wallet、Rabby 等），
// 找不到时退回 window.ethereum。不保存任何私钥，只记住上次用的是哪个钱包（rdns），方便下次自动连接。
import { useCallback, useEffect, useMemo, useState } from 'react';
import { createWalletClient, custom, getAddress, numberToHex } from 'viem';
import { NETWORKS } from './chains.js';

const LAST_KEY = 'tapesurge:wallet';
const store = {
  get: () => {
    try {
      return localStorage.getItem(LAST_KEY);
    } catch {
      return null;
    }
  },
  set: (v) => {
    try {
      if (v) localStorage.setItem(LAST_KEY, v);
      else localStorage.removeItem(LAST_KEY);
    } catch {
      /* 隐私模式下没有 localStorage，忽略 */
    }
  },
};

function useInjectedProviders() {
  const [list, setList] = useState([]);
  useEffect(() => {
    const seen = new Map();
    const onAnnounce = (e) => {
      const d = e.detail;
      if (!d?.info?.uuid || seen.has(d.info.uuid)) return;
      seen.set(d.info.uuid, d);
      setList([...seen.values()]);
    };
    window.addEventListener('eip6963:announceProvider', onAnnounce);
    window.dispatchEvent(new Event('eip6963:requestProvider'));
    // 不支持 EIP-6963 的老钱包
    const t = setTimeout(() => {
      if (seen.size === 0 && window.ethereum) {
        const d = { info: { uuid: 'legacy', name: 'Browser Wallet', rdns: 'legacy', icon: '' }, provider: window.ethereum };
        seen.set('legacy', d);
        setList([d]);
      }
    }, 400);
    return () => {
      clearTimeout(t);
      window.removeEventListener('eip6963:announceProvider', onAnnounce);
    };
  }, []);
  return list;
}

export function useWallet() {
  const providers = useInjectedProviders();
  const [active, setActive] = useState(null); // { info, provider }
  const [account, setAccount] = useState(null);
  const [chainId, setChainId] = useState(null);
  const [error, setError] = useState(null);

  const attach = useCallback(async (detail, request) => {
    setError(null);
    const p = detail.provider;
    const accounts = await p.request({ method: request ? 'eth_requestAccounts' : 'eth_accounts' });
    if (!accounts?.length) return false;
    setActive(detail);
    setAccount(getAddress(accounts[0]));
    setChainId(Number(await p.request({ method: 'eth_chainId' })));
    store.set(detail.info.rdns);
    return true;
  }, []);

  // 上次连过的钱包：静默恢复（eth_accounts 不弹窗）
  useEffect(() => {
    if (active) return;
    const last = store.get();
    const d = providers.find((x) => x.info.rdns === last);
    if (d) attach(d, false).catch(() => {});
  }, [providers, active, attach]);

  useEffect(() => {
    const p = active?.provider;
    if (!p?.on) return;
    const onAccounts = (a) => {
      if (a?.length) setAccount(getAddress(a[0]));
      else {
        setAccount(null);
        setActive(null);
        store.set(null);
      }
    };
    const onChain = (id) => setChainId(Number(id));
    p.on('accountsChanged', onAccounts);
    p.on('chainChanged', onChain);
    return () => {
      p.removeListener?.('accountsChanged', onAccounts);
      p.removeListener?.('chainChanged', onChain);
    };
  }, [active]);

  const connect = useCallback(
    async (detail) => {
      try {
        await attach(detail, true);
      } catch (e) {
        setError(e?.code === 4001 ? 'rejected' : e?.message || String(e));
      }
    },
    [attach],
  );

  const disconnect = useCallback(() => {
    setActive(null);
    setAccount(null);
    store.set(null);
  }, []);

  const switchChain = useCallback(
    async (id) => {
      const p = active?.provider;
      if (!p) return;
      const net = NETWORKS[id];
      try {
        await p.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: numberToHex(id) }] });
      } catch (e) {
        if (e?.code !== 4902 && e?.data?.originalError?.code !== 4902) throw e;
        await p.request({
          method: 'wallet_addEthereumChain',
          params: [
            {
              chainId: numberToHex(id),
              chainName: net.chain.name,
              nativeCurrency: net.chain.nativeCurrency,
              rpcUrls: net.rpcs,
              blockExplorerUrls: [net.explorer],
            },
          ],
        });
      }
    },
    [active],
  );

  const walletClient = useMemo(() => {
    if (!active || !account || !chainId || !NETWORKS[chainId]) return null;
    return createWalletClient({ account, chain: NETWORKS[chainId].chain, transport: custom(active.provider) });
  }, [active, account, chainId]);

  return { providers, active, account, chainId, error, connect, disconnect, switchChain, walletClient };
}
