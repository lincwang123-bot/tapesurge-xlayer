// 发交易：先用 eth_call 模拟，模拟失败就把合约的自定义错误翻成人话，不弹钱包；模拟通过才让钱包签名。
import { BaseError, ContractFunctionRevertedError, UserRejectedRequestError, decodeErrorResult } from 'viem';
import TapeBoard from '../abi/TapeBoard.json';
import MonthBoard from '../abi/MonthBoard.json';
import BoardFactory from '../abi/BoardFactory.json';
import MonthFactory from '../abi/MonthFactory.json';
import GenesisSplitter from '../abi/GenesisSplitter.json';
import MockBEM from '../abi/MockBEM.json';
import MonthMachineSales from '../abi/MonthMachineSales.json';
import PositionExchange from '../abi/PositionExchange.json';
import MonthExitGovernor from '../abi/MonthExitGovernor.json';
import XRigMarket from '../abi/xlayer/XRigMarket.json';
import XMonthBoard from '../abi/xlayer/XMonthBoard.json';
import XMonthMachineSales from '../abi/xlayer/XMonthMachineSales.json';
import XPositionExchange from '../abi/xlayer/XPositionExchange.json';
import XHub from '../abi/xlayer/XHub.json';
import { DrandAbi } from './drand.js';

// 所有合约的自定义错误合在一起，用来解码任何一处的 revert
const errorAbi = (() => {
  const seen = new Set();
  return [TapeBoard, MonthBoard, BoardFactory, MonthFactory, GenesisSplitter, MockBEM, MonthMachineSales, PositionExchange, MonthExitGovernor,
    XRigMarket, XMonthBoard, XMonthMachineSales, XPositionExchange, XHub, DrandAbi]
    .flat()
    .filter((x) => x.type === 'error' && !seen.has(x.name) && seen.add(x.name));
})();

const MESSAGES = {
  AlreadyJoined: ['这个地址已经加入过本局，一个地址一局只能参加一次', 'This address has already joined this board'],
  BadAmount: ['投入金额不在本局允许的范围内', 'Amount is outside the allowed range for this board'],
  RecruitmentClosed: ['本局招募已经结束', 'Recruitment for this board has ended'],
  WrongState: ['本局当前阶段不能做这个操作', 'This action is not available in the current phase'],
  NotPassOwner: ['这张通行证不在你的钱包里', 'This pass is not in your wallet'],
  NotStandardPass: ['这不是标准的 HA1 通行证', 'This circuit is not a standard HA1 pass'],
  UpgradeSentinelTripped: [
    '检测到 TapeOut 合约升级，冷静期内暂停加入和矿机交易',
    'A TapeOut upgrade was detected; joining and machine trades are paused during the cooling period',
  ],
  SentinelPaused: ['升级冷静期内暂停', 'Paused during the upgrade cooling period'],
  SentinelTripped: ['升级冷静期内暂停', 'Paused during the upgrade cooling period'],
  NotAuthorized: [
    '这一步由运营地址执行；运营地址超过 3 天没执行时，本局参与者才可以代为执行',
    'The operator runs this step; participants can step in only after the operator has been idle for 3 days',
  ],
  TooEarly: ['时间还没到', 'Too early'],
  TooSoon: ['时间还没到', 'Too early'],
  NotYet: ['时间还没到', 'Not yet'],
  BelowThreshold: ['脉冲池还不够一次开奖', 'The pulse pool is not large enough for a draw yet'],
  DrawAlreadyPending: ['上一次开奖还在等随机数', 'A draw is already waiting for randomness'],
  NoPendingDraw: ['没有等待中的开奖', 'There is no pending draw'],
  NothingToWithdraw: ['没有可以领取的金额', 'Nothing to claim'],
  ClaimsAreClosed: ['领取期限已过', 'The claim window has closed'],
  NotParticipant: ['你没有参加本局', 'You are not a participant of this board'],
  NotAliveParticipant: ['只有未出局的参与者可以执行', 'Only participants still in the game can do this'],
  PassAlreadyReturned: ['通行证已经退还', 'The pass has already been returned'],
  CannotClose: ['招募还没到期，不能结束', 'Recruitment has not ended yet'],
  GenesisConditionNotMet: [
    '还不能开局：需要铸满 10,000 颗晶体管，或从开放铸造起满 7 天',
    'Genesis needs 10,000 transistors minted or 7 days since minting opened',
  ],
  GenesisAlreadyStarted: ['已经开局', 'Genesis has already started'],
  FeedNotPosted: [
    '还不能开局：运营机器人还没报出第一次矿机价格，报价后才能开局',
    'Genesis waits for the operator bot to post the first machine price',
  ],
  PriceAboveMaximum: ['价格已经变化，高于你能接受的上限', 'The price moved above your limit'],
  PriceBelowMinimum: ['当前收购价低于你设的最低价', 'The current offer is below your minimum'],
  InvalidSignature: ['drand 签名验证没通过', 'The drand signature did not verify'],
  AlreadyFulfilled: ['这一轮随机数已经交付过了', 'This randomness has already been delivered'],
  UnknownRequest: ['找不到这个随机数请求', 'Unknown randomness request'],
  NotForSale: ['这台矿机现在不能购买', 'This machine is not for sale right now'],
  AlreadySold: ['这台矿机已经卖出', 'This machine has already been sold'],
  InsufficientBudget: ['主板的收购预算不够买这台矿机', 'The board budget cannot cover this machine'],
  BuyRoundInactive: ['现在不在收购期', 'The board is not buying machines right now'],
  MachineNotEligible: [
    '这台矿机不符合收购条件（BSC：已验证、在挖、运行满 7 天、算力 10–300；X Layer：RIG 算力 10–300、3 天内同步过）',
    'Machine not eligible (BSC: verified, mining, 7+ days, weight 10–300; X Layer: RIG power 10–300, synced within 3 days)',
  ],
  NotMachineOwner: ['这台矿机不在你的钱包里', 'This machine is not in your wallet'],
  TooManyMachines: ['本局矿机数量已达上限', 'This board holds the maximum number of machines'],
  PriceUnavailable: ['暂时读不到价格', 'Price unavailable right now'],
  NotExpired: ['还没到期限', 'Not expired yet'],
  SentinelNotTripped: ['升级哨兵没有触发', 'The upgrade sentinel has not been tripped'],
  ERC20InsufficientBalance: ['BEM 余额不足', 'Insufficient BEM balance'],
  ERC20InsufficientAllowance: ['BEM 授权额度不足', 'Insufficient BEM allowance'],
  InsufficientBalance: ['余额不足', 'Insufficient balance'],
  // v2 多数集体清算
  BadPlan: ['计划不完整或价格不对：要列出全部没卖出的矿机，起价 ≥ 底价 > 0', 'Invalid plan: list every unsold machine, start ≥ floor > 0'],
  UnknownPlan: ['这个计划还没有发布', 'This plan has not been published'],
  NotHolder: ['你不是这份持仓的持有人', 'You do not hold this position'],
  CoolingDown: ['上一次提案结束后的冷却期还没过', 'Still in the cooldown after the last proposal'],
  ProposalActive: ['本局已经有一个进行中的提案', 'A proposal is already in progress'],
  NotEnoughSupport: ['支持这个计划的持仓还不到全部本金的 10%', 'Support is below 10% of total stake'],
  NotVoting: ['现在不在投票期', 'Voting is not open'],
  BadChoice: ['投票选项无效', 'Invalid vote choice'],
  SlotsNotSorted: ['持仓编号必须从小到大且不重复', 'Slots must be strictly increasing'],
  NotExecutable: ['现在不能执行（还在等待期，或已经过了执行期限）', 'Not executable now (still waiting, or the window has passed)'],
  TransferLocked: ['现在持仓不能转让（不在结算阶段，或正在集体清算投票）', 'Positions cannot be transferred right now'],
  // v2 持仓挂单簿
  NotTransferable: ['现在不能成交（不在结算阶段、正在集体清算投票，或领取期限已过）', 'Trading is closed right now'],
  NotListable: ['现在不能挂单（不在结算阶段或领取期限已过）', 'Listing is not available right now'],
  BadDeadline: ['有效期不对：最长 30 天', 'Invalid expiry (30 days max)'],
  ZeroPrice: ['价格必须大于 0', 'Price must be above 0'],
  NotOwner: ['你不是这份持仓（或这张 RIG）的持有人', 'You do not hold this position (or RIG)'],
  NotApproved: ['还没授权合约转移你的持仓（或 RIG）', 'The contract is not approved to move your position (or RIG)'],
  NoAsk: ['没有这张卖单', 'No such ask'],
  AskNotValid: ['这张卖单已经失效（持仓变了、过期或撤单），请刷新', 'This ask is no longer valid; refresh'],
  PriceAbove: ['价格变了，高于你能接受的上限', 'The price moved above your limit'],
  PriceBelow: ['买单价格变了，低于你能接受的下限', 'The bid moved below your limit'],
  SelfTrade: ['不能和自己成交', 'You cannot trade with yourself'],
  NothingFilled: ['一份也没买到：卖单可能刚被别人买走或改价了，请刷新', 'Nothing filled; the asks changed, refresh'],
  BudgetTooSmall: ['预算太少：至少 1 BEM，且要够买最小的一份', 'Budget too small (at least 1 BEM)'],
  BadStakeRange: ['持仓大小范围不对', 'Invalid stake range'],
  TooManyBids: ['你已经有 20 张没关闭的买单', 'You already have 20 open bids'],
  BidClosedAlready: ['这个买单已经关闭', 'This bid is closed'],
  BidExpired: ['这个买单已经过期', 'This bid has expired'],
  NotBidder: ['这不是你的买单', 'Not your bid'],
  StakeOutOfRange: ['这份持仓的大小不在买单接受的范围内', 'This position size is outside the bid range'],
  BudgetExceeded: ['买单剩余预算不够买这份持仓', 'The bid budget cannot cover this position'],
  // X Layer：RIG 矿机市场、卖矿同步时间、盘口买单版本号
  NoPower: ['这张 RIG 的算力是 0，不能挂单', 'This RIG has zero power'],
  NotMonthBoard: ['这不是本协议的月局', 'Not a TapeSurge monthly board'],
  BadPowerRange: ['算力范围不对：最小值不能大于最大值', 'Invalid power range'],
  PowerOutOfRange: ['这张 RIG 的算力不在买单接受的范围内', "This RIG's power is outside the bid range"],
  SyncTooOld: [
    '这张 RIG 太久没同步：先在 BSC 金库为它发起一次收取（测试网可以在 RIG 市场页点「刷新同步」）',
    'This RIG has not synced recently: trigger a claim in the BSC vault first (on testnet, use "Refresh sync" on the RIG market page)',
  ],
  BidStillValid: ['买单还没过期，只有买家自己能撤', 'The bid has not expired; only the bidder can cancel it'],
  BidStale: ['这张持仓买单已失效（本局矿机卖出或治理状态变了），请撤单重挂', 'This bid is stale (the board changed); cancel and place it again'],
  PaymentMismatch: ['到账金额和预期不一致', 'Payment amount mismatch'],
  BelowCost: ['价格低于成本价；只有多数集体清算通过后才能低于成本价卖出', 'Below cost; only allowed after a majority liquidation vote'],
};

export class TxError extends Error {
  constructor(code, detail) {
    super(code);
    this.code = code;
    this.detail = detail;
  }
}

function revertName(err) {
  if (!(err instanceof BaseError)) return null;
  const reverted = err.walk((e) => e instanceof ContractFunctionRevertedError);
  if (reverted?.data?.errorName) return reverted.data.errorName;
  // 有些节点返回的 revert 数据没被当前 ABI 解码，再用合并后的错误表试一次
  const raw = err.walk((e) => typeof e?.data === 'string' && e.data.startsWith('0x'))?.data;
  if (raw && raw.length >= 10) {
    try {
      return decodeErrorResult({ abi: errorAbi, data: raw }).errorName;
    } catch {
      return null;
    }
  }
  return reverted?.reason ? `reason:${reverted.reason}` : null;
}

/** 把任何错误翻成一句话 */
export function explain(err, lang = 'zh') {
  const i = lang === 'zh' ? 0 : 1;
  if (err instanceof TxError) {
    const m = MESSAGES[err.code];
    return m ? m[i] : err.detail || err.code;
  }
  if (err instanceof BaseError && err.walk((e) => e instanceof UserRejectedRequestError)) {
    return lang === 'zh' ? '你在钱包里取消了这笔交易' : 'You rejected the transaction in your wallet';
  }
  if (err?.code === 4001) return lang === 'zh' ? '你在钱包里取消了这笔交易' : 'You rejected the request';
  const name = revertName(err);
  if (name?.startsWith('reason:')) return name.slice(7);
  if (name) return MESSAGES[name]?.[i] ?? name;
  if (/insufficient funds/i.test(err?.message ?? '')) {
    return lang === 'zh' ? '钱包里的 gas 币（BNB / OKB）不够付这笔交易' : 'Not enough gas token (BNB / OKB) for this transaction';
  }
  return err?.shortMessage || err?.message || String(err);
}

const pause = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * 模拟 → 签名 → 等上链。返回交易回执。
 * onStage('simulating' | 'signing' | 'pending', hash?) 用来更新界面。
 * laggy（X Layer）：公共节点的状态会落后几个区块（2026-10-29 实测：铸完 NAND 马上模拟流片，节点还看不到刚铸的 NAND）。
 * 所以上链后等节点的区块高度追上这笔交易再返回；retries > 0 时模拟失败隔 1.5 秒重试（多步操作的后续步骤用）。
 */
export async function sendTx({ publicClient, walletClient, address, abi, functionName, args = [], value, onStage, laggy = false, retries = 0 }) {
  const account = walletClient.account;
  onStage?.('simulating');
  let request;
  for (let i = 0; ; i++) {
    try {
      ({ request } = await publicClient.simulateContract({ account, address, abi, functionName, args, value }));
      break;
    } catch (e) {
      if (i >= retries) throw e;
      await pause(1500);
    }
  }
  onStage?.('signing');
  const hash = await walletClient.writeContract(request);
  onStage?.('pending', hash);
  const receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: 180_000 });
  if (receipt.status !== 'success') throw new TxError('Reverted', hash);
  if (laggy) {
    for (let i = 0; i < 20; i++) {
      if ((await publicClient.getBlockNumber({ cacheTime: 0 }).catch(() => 0n)) > receipt.blockNumber) break;
      await pause(500);
    }
  }
  return receipt;
}

/** 只模拟，不发交易：用来判断一个按钮现在能不能点 */
export async function canCall({ publicClient, account, address, abi, functionName, args = [], value }) {
  try {
    await publicClient.simulateContract({ account, address, abi, functionName, args, value });
    return { ok: true };
  } catch (e) {
    return { ok: false, error: e };
  }
}
