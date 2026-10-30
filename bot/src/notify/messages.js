// @TapeSurgeBot 提醒文案（中文 / 英文）。金额是 BEM 最小单位（8 位小数）。
const bem = (v, d = 4) => {
  const s = (Number(BigInt(v)) / 1e8).toFixed(d).replace(/\.?0+$/, '');
  return s === '' ? '0' : s;
};
const short = (a) => `${a.slice(0, 6)}…${a.slice(-4)}`;
const pct = (unit) => (Number(unit) / 1e6).toFixed(1);

export const M = {
  zh: {
    prize: ({ board, amount, link }) => `🎉 月局 #${board} 开奖：你中了 ${bem(amount)} BEM！\n去领取：${link}`,
    eject: ({ board, payout, link }) => `⚡ 标准局 #${board}：你被抽中出局，${bem(payout)} BEM（投入的 105%）和通行证已经打到你的钱包。\n${link}`,
    claim: ({ total, items, link }) => `💰 你有 ${bem(total)} BEM 待领取：\n${items.map((i) => `· ${i}`).join('\n')}\n去领取：${link}`,
    claimItem: ({ kind, board, amount }) => `${kind === 'std' ? '标准局' : '月局'} #${board}：${bem(amount)} BEM`,
    tradeSell: ({ board, slot, unit, cost, link }) => `✅ 月局 #${board} 持仓 #${slot} 已卖出：本金的 ${pct(unit)}%，到手 ${bem(cost)} BEM（已直接到账）。\n${link}`,
    tradeBuy: ({ board, slot, unit, cost, link }) => `✅ 你买入了月局 #${board} 持仓 #${slot}：本金的 ${pct(unit)}%，花费 ${bem(cost)} BEM。\n${link}`,
    vote: ({ board, end, link }) => `🗳 月局 #${board} 开始集体清算投票，${end} 截止。按原始本金计票，不投票等于不赞成。投票期间持仓暂停转让。\n去投票：${link}`,
    voteRemind: ({ board, end, link }) => `⏰ 月局 #${board} 的集体清算投票 ${end} 截止，你还有持仓没投票。\n${link}`,
    resultPassed: ({ board, link }) => `📣 月局 #${board} 集体清算投票通过，等待期满后执行。\n${link}`,
    resultFailed: ({ board, link }) => `📣 月局 #${board} 集体清算投票没有通过，持仓恢复可以转让。\n${link}`,
    resultExecuted: ({ board, link }) => `📣 月局 #${board} 清算计划已执行：矿机开始按计划价出售，回款先退本金。\n${link}`,
    resultExpired: ({ board, link }) => `📣 月局 #${board} 的清算提案超过执行期限，已失效。\n${link}`,
    ask: ({ board, link }) => `ℹ️ 你在月局 #${board} 挂的卖单已失效（卖出了矿机，或集体清算投票开始 / 结束）。需要的话请重新挂单。\n${link}`,
    deadline: ({ kind, board, days, amount, link }) => `⏳ ${kind === 'std' ? '标准局' : '月局'} #${board} 的领取期限还剩约 ${days} 天，你还有 ${bem(amount)} BEM 没领。过期后会转给基金会。\n${link}`,
    refund: ({ kind, board, link }) => `↩️ ${kind === 'std' ? '标准局' : '月局'} #${board} 招募没达到目标的 60%，全员全额退款（含入场费），通行证也会退回。\n${link}`,
    overflow: (n) => `另外还有 ${n} 条提醒，请打开 dApp 查看。`,
  },
  en: {
    prize: ({ board, amount, link }) => `🎉 Monthly #${board} draw: you won ${bem(amount)} BEM!\nClaim: ${link}`,
    eject: ({ board, payout, link }) => `⚡ Standard #${board}: you were ejected; ${bem(payout)} BEM (105% of stake) and your pass were sent to your wallet.\n${link}`,
    claim: ({ total, items, link }) => `💰 You have ${bem(total)} BEM to claim:\n${items.map((i) => `· ${i}`).join('\n')}\nClaim: ${link}`,
    claimItem: ({ kind, board, amount }) => `${kind === 'std' ? 'Standard' : 'Monthly'} #${board}: ${bem(amount)} BEM`,
    tradeSell: ({ board, slot, unit, cost, link }) => `✅ Monthly #${board} position #${slot} sold at ${pct(unit)}% of stake; you received ${bem(cost)} BEM.\n${link}`,
    tradeBuy: ({ board, slot, unit, cost, link }) => `✅ You bought monthly #${board} position #${slot} at ${pct(unit)}% of stake for ${bem(cost)} BEM.\n${link}`,
    vote: ({ board, end, link }) => `🗳 Monthly #${board}: a liquidation vote is open until ${end}. Votes are weighted by stake; not voting counts as not in favour. Transfers are paused during the vote.\n${link}`,
    voteRemind: ({ board, end, link }) => `⏰ Monthly #${board}: the liquidation vote ends ${end} and some of your positions have not voted.\n${link}`,
    resultPassed: ({ board, link }) => `📣 Monthly #${board}: the liquidation vote passed; it can be executed after the waiting period.\n${link}`,
    resultFailed: ({ board, link }) => `📣 Monthly #${board}: the liquidation vote did not pass; positions can be transferred again.\n${link}`,
    resultExecuted: ({ board, link }) => `📣 Monthly #${board}: the liquidation plan is live; machines sell at plan prices and proceeds repay stake first.\n${link}`,
    resultExpired: ({ board, link }) => `📣 Monthly #${board}: the liquidation proposal expired without execution.\n${link}`,
    ask: ({ board, link }) => `ℹ️ Your ask on monthly #${board} lapsed (a machine was sold or a vote started/ended). Relist if you still want to sell.\n${link}`,
    deadline: ({ kind, board, days, amount, link }) => `⏳ ${kind === 'std' ? 'Standard' : 'Monthly'} #${board}: about ${days} days left to claim ${bem(amount)} BEM. Unclaimed funds go to the foundation.\n${link}`,
    refund: ({ kind, board, link }) => `↩️ ${kind === 'std' ? 'Standard' : 'Monthly'} #${board} did not reach 60% of its target; everyone is fully refunded (entry fee included) and passes are returned.\n${link}`,
    overflow: (n) => `${n} more reminders; open the dApp to see them.`,
  },
};

export { bem, short };
