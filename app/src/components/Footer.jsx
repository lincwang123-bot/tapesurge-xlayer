import { useApp } from '../App.jsx';
import { explorerAddr } from '../lib/chains.js';
import { shortAddr } from '../lib/format.js';

export default function Footer() {
  const app = useApp();
  const zh = app.lang === 'zh';
  const dep = app.dep;
  const rows = !dep
    ? []
    : app.xlayer
      ? [
          [zh ? '注册中心 XHub' : 'XHub registry', dep.hub],
          [zh ? '月局工厂' : 'Month factory', dep.monthFactory],
          [zh ? 'RIG 矿机市场' : 'RIG market', dep.market],
          [zh ? '通行证电路' : 'Pass circuits', dep.passCircuits],
          ['BEM', dep.bem],
        ].filter(([, a]) => a)
      : [
          [zh ? '标准局工厂' : 'Board factory', dep.factory],
          [zh ? '月局工厂' : 'Month factory', dep.monthFactory],
          [zh ? '创世分账合约' : 'Genesis splitter', dep.splitter],
          [zh ? '通行证电路' : 'Pass circuits', dep.passCircuits],
          ['BEM', dep.bem],
        ];
  return (
    <footer className="footer">
      <div className="footer-risk">
        <strong>{zh ? '参与前请了解风险' : 'Know the risks'}</strong>
        <p>
          {zh
            ? '收益来自 PoD 挖矿产出，会随全网算力和减半下降，不作任何保证；标准局每次谁出局、月局谁中奖，都由链上随机数决定；矿机可能被撤销或降级；TapeOut 合约可能升级。新开的局可以升级规则（链上公示 7 天后生效），已经开始的局永远按开局时的规则运行，谁也改不了；规则以白皮书和链上代码为准。'
            : 'Yield comes from PoD mining and falls as network hashpower grows and at each halving; nothing is guaranteed. Who is ejected on a standard board and who wins on a monthly board are decided by on-chain randomness. Machines can be revoked or downgraded, and TapeOut contracts can be upgraded. New boards may use upgraded rules (after a 7-day on-chain notice); boards already running keep their opening rules forever. The whitepaper and on-chain code are the rules.'}
        </p>
        <p className="footer-links">
          <a href="https://tapesurge.com" target="_blank" rel="noreferrer">
            {zh ? '官网' : 'Website'}
          </a>
          <a href="https://tapesurge.com/whitepaper.html" target="_blank" rel="noreferrer">
            {zh ? '白皮书' : 'Whitepaper'}
          </a>
        </p>
      </div>
      <dl className="footer-contracts">
        {rows.map(([label, addr]) => (
          <div key={label}>
            <dt>{label}</dt>
            <dd>
              <a href={explorerAddr(app.chainId, addr)} target="_blank" rel="noreferrer">
                {shortAddr(addr)}
              </a>
            </dd>
          </div>
        ))}
      </dl>
    </footer>
  );
}
