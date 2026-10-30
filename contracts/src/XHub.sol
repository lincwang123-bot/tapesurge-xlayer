// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ITransistors, IBeacon} from "./interfaces/ITapeOut.sol";
import {IXMonthFactory} from "./interfaces/IXMonthBoard.sol";
import {IXPriceQuote} from "./interfaces/IXMonthV2.sol";
import {GenesisSplitter} from "./GenesisSplitter.sol";

interface IXSentinel {
    function sentinelTripped() external view returns (bool);
    function sentinelPaused() external view returns (bool);
    function PASS_BEACON() external view returns (address);
}

/// @notice X Layer 月局注册中心。参数和资金去向不可修改；只有手续费收款人可更换运营地址。
///         部署顺序为 Splitter -> XHub -> XMonthFactory，后两者地址在部署前预测。
///         RIG 的 UUPS 升级由链下监控；此处只监控通行证信标。
contract XHub {
    struct Params {
        address splitter;
        address monthFactory;
        address initialOperator;
        uint256 genesisMintThreshold;
        uint256 genesisDelay;
    }

    GenesisSplitter public immutable splitter;
    ITransistors public immutable transistors;
    address public immutable passCircuits;
    address public immutable monthFactory;
    address public immutable feeRecipient;
    uint256 public immutable genesisMintThreshold;
    uint256 public immutable genesisDelay;
    address public operator;
    bool public genesisStarted;
    uint256 public startCount;
    mapping(uint256 => address) public rewardBoard;
    mapping(address => uint256) public rankOf;
    uint256 internal _sentinelSince;
    bytes32 internal _sentinelFingerprint;

    event GenesisStarted(uint256 minted, uint256 elapsed);
    event BoardStarted(uint256 indexed rank, address indexed board, bool monthBoard);
    event OperatorChanged(address indexed previous, address indexed current);
    event SentinelNoted(uint256 since);

    error BadParams();
    error GenesisAlreadyStarted();
    error GenesisConditionNotMet();
    error SentinelTripped();
    error OnlyMonthFactory();
    error OnlyFeeSafe();
    error BadBoard();
    error FeedNotPosted();

    constructor(Params memory p) {
        if (
            p.splitter == address(0) || p.monthFactory == address(0) || p.genesisMintThreshold == 0
                || p.genesisDelay == 0
        ) {
            revert BadParams();
        }
        GenesisSplitter s = GenesisSplitter(payable(p.splitter));
        if (s.boardFactory() != address(this)) revert BadParams();
        splitter = s;
        transistors = s.transistors();
        passCircuits = s.circuits();
        feeRecipient = s.project();
        monthFactory = p.monthFactory;
        genesisMintThreshold = p.genesisMintThreshold;
        genesisDelay = p.genesisDelay;
        operator = p.initialOperator;
        emit OperatorChanged(address(0), p.initialOperator);
    }

    /// @notice 开局：已铸晶体管 ≥ 门槛，或距开始铸造满 genesisDelay。先分账一次，再开出第 1 块月局。
    ///         BSC 行情转报必须已经报过价：否则第一块月局会按默认曲线收购，市价低时按几倍市价买矿机。
    function startGenesis() external returns (address board) {
        if (genesisStarted) revert GenesisAlreadyStarted();
        uint256 minted = transistors.minted();
        uint256 elapsed = block.timestamp - splitter.mintStart();
        if (minted < genesisMintThreshold && elapsed < genesisDelay) revert GenesisConditionNotMet();
        if (_sentinel().sentinelPaused()) revert SentinelTripped();
        if (IXPriceQuote(IXMonthFactory(monthFactory).priceFeed()).updatedAt() == 0) revert FeedNotPosted();
        genesisStarted = true;
        emit GenesisStarted(minted, elapsed);
        splitter.distribute();
        board = IXMonthFactory(monthFactory).openFirst();
    }

    function isBoard(address account) public view returns (bool) {
        return IXMonthFactory(monthFactory).isBoard(account);
    }

    function registerStart(address board) external returns (uint256 rank) {
        if (msg.sender != monthFactory) revert OnlyMonthFactory();
        if (!genesisStarted || !isBoard(board) || rankOf[board] != 0) revert BadBoard();
        rank = ++startCount;
        rewardBoard[rank] = board;
        rankOf[board] = rank;
        emit BoardStarted(rank, board, true);
    }

    function setOperator(address newOperator) external {
        if (msg.sender != feeRecipient) revert OnlyFeeSafe();
        emit OperatorChanged(operator, newOperator);
        operator = newOperator;
    }

    function noteSentinel() external {
        bool tripped = _sentinel().sentinelTripped();
        bytes32 fingerprint = _fingerprint();
        uint256 since = _sentinelSince;
        if (!tripped) {
            since = 0;
            fingerprint = bytes32(0);
        } else if (since == 0 || fingerprint != _sentinelFingerprint) {
            since = block.timestamp;
        }
        if (since != _sentinelSince || fingerprint != _sentinelFingerprint) {
            _sentinelSince = since;
            _sentinelFingerprint = fingerprint;
            emit SentinelNoted(since);
        }
    }

    function sentinelSince() external view returns (uint256) {
        return _sentinelSince != 0 && _fingerprint() == _sentinelFingerprint ? _sentinelSince : 0;
    }

    function _sentinel() internal view returns (IXSentinel) {
        return IXSentinel(IXMonthFactory(monthFactory).boardImplementation());
    }

    function _fingerprint() internal view returns (bytes32) {
        address beacon = _sentinel().PASS_BEACON();
        if (beacon == address(0)) return keccak256(abi.encode(address(0)));
        (bool ok, bytes memory ret) = beacon.staticcall(abi.encodeWithSelector(IBeacon.implementation.selector));
        return keccak256(abi.encode(ok && ret.length >= 32 ? abi.decode(ret, (address)) : address(1)));
    }
}
