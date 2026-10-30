import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react';
import { AVAILABLE, NETWORKS, defaultChainId, deploymentOf, publicClientOf } from './lib/chains.js';
import { useWallet } from './lib/wallet.js';
import { LangContext, initialLang, saveLang } from './lib/i18n.js';
import Header from './components/Header.jsx';
import ConnectModal from './components/ConnectModal.jsx';
import Overview from './components/Overview.jsx';
import BoardList from './components/BoardList.jsx';
import BoardDetail from './components/BoardDetail.jsx';
import BindPage from './components/BindPage.jsx';
import MyPositions from './components/MyPositions.jsx';
import Footer from './components/Footer.jsx';
import RigMarket from './components/RigMarket.jsx';

const AppContext = createContext(null);
export const useApp = () => useContext(AppContext);

/** 测试网快速模式：所有以天计的时长按比例缩短（例如 48 = 1 天 → 30 分钟） */
function timeScale(dep, lang) {
  const div = Number(dep?.timeDivisor ?? (dep?.fast ? 720 : 0));
  if (!div) return null;
  const min = 1440 / div;
  const day = min >= 60 ? `${+(min / 60).toFixed(1)} ${lang === 'zh' ? '小时' : 'h'}` : `${+min.toFixed(1)} ${lang === 'zh' ? '分钟' : 'min'}`;
  return lang === 'zh'
    ? ` 测试网的时间按比例缩短：规则里的 1 天 = ${day}（例如月局挖矿 30 天 = ${+((30 * min) / 60).toFixed(1)} 小时）。`
    : ` Testnet time is compressed: 1 day in the rules = ${day} (a 30-day monthly board mines for ${+((30 * min) / 60).toFixed(1)} h).`;
}

function parseRoute(hash) {
  const parts = hash.replace(/^#\/?/, '').split('/').filter(Boolean);
  if (parts[0] === 'board' && (parts[1] === 'std' || parts[1] === 'month') && /^0x[0-9a-fA-F]{40}$/.test(parts[2] ?? '')) {
    return { page: 'board', kind: parts[1], address: parts[2] };
  }
  if (parts[0] === 'boards') return { page: 'boards', kind: parts[1] === 'month' ? 'month' : 'std' };
  if (parts[0] === 'me') return { page: 'me' };
  if (parts[0] === 'market') return { page: 'market' };
  // Telegram 提醒绑定：#/bind?code=XXXXXXXX
  if (parts[0]?.startsWith('bind')) return { page: 'bind', code: new URLSearchParams(parts[0].split('?')[1] ?? '').get('code') ?? '' };
  return { page: 'home' };
}

/** 链接里直接指定网络：?chain=1952（参赛用的 X Layer 测试网链接）；不是已部署的网络就忽略 */
function chainFromUrl() {
  const id = Number(new URLSearchParams(location.search).get('chain'));
  return AVAILABLE.some((n) => n.id === id) ? id : null;
}

function readChain() {
  const fromUrl = chainFromUrl();
  if (fromUrl) return fromUrl;
  try {
    const saved = Number(localStorage.getItem('tapesurge:chain'));
    if (AVAILABLE.some((n) => n.id === saved)) return saved;
  } catch {
    /* 忽略 */
  }
  return defaultChainId();
}

export default function App() {
  const [lang, setLangState] = useState(initialLang);
  const [chainId, setChainState] = useState(readChain);
  const [route, setRoute] = useState(() => parseRoute(location.hash));
  const [connectOpen, setConnectOpen] = useState(false);
  const [version, setVersion] = useState(0);
  const wallet = useWallet();
  // 链接里指定了网络时，不跟着钱包当前的网络自动切换（例如钱包停在 BSC，打开 X Layer 的参赛链接）
  const pinned = useRef(chainFromUrl());

  useEffect(() => {
    const onHash = () => {
      setRoute(parseRoute(location.hash));
      window.scrollTo({ top: 0 });
    };
    window.addEventListener('hashchange', onHash);
    return () => window.removeEventListener('hashchange', onHash);
  }, []);

  useEffect(() => {
    document.documentElement.lang = lang === 'zh' ? 'zh-CN' : 'en';
    document.title = lang === 'zh' ? 'TapeSurge 应用 · 晶涌协议' : 'TapeSurge App';
  }, [lang]);

  // 钱包切到了另一个已部署的网络：页面跟着切过去
  useEffect(() => {
    if (pinned.current) return;
    if (wallet.chainId && wallet.chainId !== chainId && AVAILABLE.some((n) => n.id === wallet.chainId)) {
      setChainState(wallet.chainId);
    }
  }, [wallet.chainId]); // eslint-disable-line react-hooks/exhaustive-deps

  const setLang = useCallback((l) => {
    setLangState(l);
    saveLang(l);
  }, []);

  const setChainId = useCallback((id) => {
    pinned.current = null; // 手动选了网络，之后照常跟着钱包切换
    setChainState(id);
    try {
      localStorage.setItem('tapesurge:chain', String(id));
    } catch {
      /* 忽略 */
    }
  }, []);

  const app = useMemo(
    () => ({
      lang,
      setLang,
      chainId,
      setChainId,
      net: NETWORKS[chainId],
      // X Layer 版：只有月局，矿机是 RIG 凭证，自带 RIG 矿机市场
      xlayer: NETWORKS[chainId].family === 'xlayer',
      dep: deploymentOf(chainId),
      client: publicClientOf(chainId),
      wallet,
      account: wallet.chainId === chainId ? wallet.account : wallet.account, // 读数据时用当前账户，签名时 WalletGate 会要求切网络
      openConnect: () => setConnectOpen(true),
      version,
      bump: () => setVersion((v) => v + 1),
      route,
    }),
    [lang, setLang, chainId, setChainId, wallet, version, route],
  );

  let page;
  if (!app.dep) {
    page = (
      <section className="panel">
        <p>{lang === 'zh' ? '这个网络还没有部署。' : 'Not deployed on this network yet.'}</p>
      </section>
    );
  } else if (route.page === 'boards') page = <BoardList kind={app.xlayer ? 'month' : route.kind} />;
  else if (route.page === 'market') {
    page = app.xlayer ? (
      <RigMarket />
    ) : (
      <section className="panel">
        <p>{lang === 'zh' ? 'RIG 矿机市场只在 X Layer 上。' : 'The RIG market is on X Layer only.'}</p>
      </section>
    );
  }
  else if (route.page === 'board') page = <BoardDetail kind={route.kind} address={route.address} key={route.address} />;
  else if (route.page === 'me') page = <MyPositions />;
  else if (route.page === 'bind') page = <BindPage code={route.code} />;
  else page = <Overview />;

  return (
    <LangContext.Provider value={lang}>
      <AppContext.Provider value={app}>
        <div className="app">
          <Header />
          {app.net.testnet && (
            <div className="testnet-bar">
              {app.xlayer
                ? lang === 'zh'
                  ? '你在 X Layer 测试网上：BEM、RIG 矿机凭证和 TapeOut 都是模拟合约，代币没有价值；随机数用真实的 drand 签名在链上验证。主网上线前合约会经过第三方审计。'
                  : 'You are on X Layer Testnet: BEM, RIG miner vouchers and TapeOut are mock contracts and tokens have no value; randomness is real drand, verified on-chain. Contracts will be audited before mainnet.'
                : lang === 'zh'
                  ? '你在 BSC 测试网上：所有代币都是测试用的，没有价值。主网上线前合约会经过第三方审计。'
                  : 'You are on BSC Testnet: all tokens are test tokens with no value. Contracts will be audited before mainnet.'}
              {timeScale(app.dep, lang)}
            </div>
          )}
          <main className="main">{page}</main>
          <Footer />
        </div>
        {connectOpen && <ConnectModal onClose={() => setConnectOpen(false)} />}
      </AppContext.Provider>
    </LangContext.Provider>
  );
}
