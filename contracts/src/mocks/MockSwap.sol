// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapRouter02, IPoolTwapOracle} from "../interfaces/ISwap.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @notice 仅用于测试 / 测试网：WETH9 同款的原生币包装代币（X Layer 上对应 WOKB）。
contract MockWrappedNative is ERC20 {
    constructor() ERC20("Wrapped OKB (mock)", "WOKB") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "withdraw");
    }
}

/// @notice 仅用于测试 / 测试网：固定 tick 的 v3 池子（TWAP 数学测试；testnet 上作为预言机和兑换的"池子"地址）。
contract MockV3Pool {
    address public token0;
    address public token1;
    uint24 public fee;
    int24 public tick;
    uint16 public observationCardinalityNext = 1;
    bool public observeReverts;

    constructor(address a, address b, uint24 fee_, int24 tick_) {
        (token0, token1) = a < b ? (a, b) : (b, a);
        fee = fee_;
        tick = tick_;
    }

    function setTick(int24 t) external {
        tick = t;
    }

    /// @notice 模拟观测点不够、30 分钟 TWAP 读不出来（真实池子 revert "OLD"）
    function setObserveReverts(bool v) external {
        observeReverts = v;
    }

    function increaseObservationCardinalityNext(uint16 next) external {
        if (next > observationCardinalityNext) observationCardinalityNext = next;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        require(!observeReverts, "OLD");
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        for (uint256 i = 0; i < secondsAgos.length; i++) {
            tickCumulatives[i] = int56(tick) * int56(uint56(block.timestamp - secondsAgos[i]));
        }
    }
}

/// @notice 仅用于测试 / 测试网：Uniswap v3 工厂的 getPool。
contract MockV3Factory {
    mapping(bytes32 => address) internal _pools;

    function setPool(address a, address b, uint24 fee, address pool) external {
        _pools[_key(a, b, fee)] = pool;
    }

    function getPool(address a, address b, uint24 fee) external view returns (address) {
        return _pools[_key(a, b, fee)];
    }

    function _key(address a, address b, uint24 fee) internal pure returns (bytes32) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return keccak256(abi.encode(t0, t1, fee));
    }
}

/// @notice 仅用于测试 / 测试网：按固定汇率把 wrappedNative 换成 BEM（直接铸造 MockBEM），模拟 SwapRouter02.exactInputSingle。
contract MockSwapRouter02 is ISwapRouter02 {
    address public immutable WETH9;
    address public immutable factory;
    address public immutable bem;
    /// @notice 1 个原生币（1e18 wei）能换多少 BEM 最小单位
    uint256 public bemPerNative;
    uint256 public swapCount;
    uint24 public lastFee;

    constructor(address wrapped, address factory_, address bem_, uint256 bemPerNative_) {
        WETH9 = wrapped;
        factory = factory_;
        bem = bem_;
        bemPerNative = bemPerNative_;
    }

    function setRate(uint256 r) external {
        bemPerNative = r;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 amountOut) {
        require(msg.value == 0, "no native");
        require(p.tokenIn == WETH9 && p.tokenOut == bem, "pair");
        IERC20(WETH9).transferFrom(msg.sender, address(this), p.amountIn);
        amountOut = p.amountIn * bemPerNative / 1e18;
        require(amountOut >= p.amountOutMinimum, "Too little received");
        swapCount++;
        lastFee = p.fee;
        IMintable(bem).mint(p.recipient, amountOut);
    }
}

/// @notice 仅用于测试 / 测试网：固定参考价的预言机（带上分账合约部署时核对的池子信息）。
contract MockPriceOracle is IPoolTwapOracle {
    address public immutable pool;
    address public immutable baseToken;
    address public immutable quoteToken;
    uint24 public immutable fee;
    uint256 public bemPerNative;
    bool public unavailable;

    constructor(address pool_, address base, address quote, uint24 fee_, uint256 bemPerNative_) {
        pool = pool_;
        baseToken = base;
        quoteToken = quote;
        fee = fee_;
        bemPerNative = bemPerNative_;
    }

    function setRate(uint256 r) external {
        bemPerNative = r;
    }

    /// @notice 模拟 TWAP 读不出来（观测点不够）
    function setUnavailable(bool v) external {
        unavailable = v;
    }

    function quoteBemOut(uint256 nativeIn) external view returns (uint256) {
        require(!unavailable, "OLD");
        return nativeIn * bemPerNative / 1e18;
    }
}
