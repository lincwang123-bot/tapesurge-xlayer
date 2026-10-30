// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBemPriceOracle} from "../interfaces/ISwap.sol";

interface IMockBem is IERC20 {
    function mint(address to, uint256 amount) external;
}

interface IWokb is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title MockZapRouter（只在 X Layer 测试网用）
/// @notice dApp 的"用 OKB 加入 / 结算后换回 OKB"（2026-10-29 项目方决定）在主网直接调用 Uniswap SwapRouter02；测试网没有真实的
///         BEM 池，用这个合约模拟 SwapRouter02 里 dApp 用到的那几个函数，参数和行为保持一致，dApp 两边用同一套代码：
///         - exactOutputSingle / exactInputSingle：只支持 WOKB ⇄ BEM 这一对；付 OKB 时随交易附上（msg.value），按 WOKB 处理；
///         - multicall(deadline, data) / multicall(data)：逐个 delegatecall 自己；
///         - refundETH：把这笔交易里没用完的 OKB 退给调用者；
///         - unwrapWETH9(amountMinimum, recipient)：把兑换时收款人填 ADDRESS_THIS（address(2)）的 WOKB 换成 OKB 付给 recipient。
///         汇率读测试网报价合约（quoteBemOut），手续费按 fee（百万分之一）照扣，和真实池子一样。
///         BEM 端直接铸造（MockBEM 谁都能铸）；OKB 端用自己持有的 WOKB 储备付：用户用 OKB 买 BEM 时付进来的 OKB 留作储备，
///         储备不够时卖 BEM 换 OKB 会失败（"reserve"）。没有管理员；只是测试工具，不托管任何人的资金（储备是用户付的测试 OKB）。
contract MockZapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    /// @dev SwapRouter02 的约定：收款人填 address(2) 表示先留在路由里（之后 unwrapWETH9）
    address internal constant ADDRESS_THIS = address(2);
    uint256 internal constant FEE_UNIT = 1_000_000;

    IWokb public immutable WETH9;
    IMockBem public immutable BEM;
    IBemPriceOracle public immutable ORACLE;

    /// @notice 收款人是 ADDRESS_THIS、还没 unwrapWETH9 的 WOKB（和储备分开记，免得 unwrap 动到储备）
    uint256 public pendingWeth;

    constructor(address wokb, address bem, address oracle) {
        require(wokb != address(0) && bem != address(0) && oracle != address(0), "config");
        WETH9 = IWokb(wokb);
        BEM = IMockBem(bem);
        ORACLE = IBemPriceOracle(oracle);
    }

    receive() external payable {
        require(msg.sender == address(WETH9), "Not WETH9");
    }

    /// @notice 每 1 OKB（1e18）换多少 BEM 最小单位（不含手续费），和测试网报价合约一致
    function bemPerNative() public view returns (uint256) {
        return ORACLE.quoteBemOut(1e18);
    }

    /// @notice 可以付出的 OKB 储备（卖 BEM 换 OKB 的上限）
    function reserve() public view returns (uint256) {
        return WETH9.balanceOf(address(this)) - pendingWeth;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 amountOut) {
        if (p.tokenIn == address(WETH9) && p.tokenOut == address(BEM)) {
            _takeWeth(p.amountIn);
            amountOut = _afterFee(p.amountIn * bemPerNative() / 1e18, p.fee);
            require(amountOut >= p.amountOutMinimum, "Too little received");
            BEM.mint(_to(p.recipient), amountOut);
        } else if (p.tokenIn == address(BEM) && p.tokenOut == address(WETH9)) {
            require(BEM.transferFrom(msg.sender, address(this), p.amountIn), "STF");
            amountOut = _afterFee(p.amountIn * 1e18 / bemPerNative(), p.fee);
            require(amountOut >= p.amountOutMinimum, "Too little received");
            _giveWeth(p.recipient, amountOut);
        } else {
            revert("pair");
        }
    }

    function exactOutputSingle(ExactOutputSingleParams calldata p) external payable returns (uint256 amountIn) {
        require(p.tokenIn == address(WETH9) && p.tokenOut == address(BEM), "pair");
        // 手续费从付款里扣：amountIn × (1 − fee) × 汇率 ≥ amountOut，向上取整
        uint256 gross = _ceilDiv(p.amountOut * 1e18, bemPerNative());
        amountIn = _ceilDiv(gross * FEE_UNIT, FEE_UNIT - p.fee);
        require(amountIn <= p.amountInMaximum, "Too much requested");
        _takeWeth(amountIn);
        BEM.mint(_to(p.recipient), p.amountOut);
    }

    function multicall(uint256 deadline, bytes[] calldata data) external payable returns (bytes[] memory) {
        require(block.timestamp <= deadline, "Transaction too old");
        return _multicall(data);
    }

    function multicall(bytes[] calldata data) external payable returns (bytes[] memory) {
        return _multicall(data);
    }

    function refundETH() external payable {
        if (address(this).balance > 0) _sendNative(msg.sender, address(this).balance);
    }

    function unwrapWETH9(uint256 amountMinimum, address recipient) external payable {
        uint256 amount = pendingWeth;
        require(amount >= amountMinimum, "Insufficient WETH9");
        pendingWeth = 0;
        if (amount > 0) {
            WETH9.withdraw(amount);
            _sendNative(recipient, amount);
        }
    }

    // ============ 内部 ============

    function _multicall(bytes[] calldata data) internal returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            (bool ok, bytes memory ret) = address(this).delegatecall(data[i]);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 32), mload(ret))
                }
            }
            results[i] = ret;
        }
    }

    /// @dev 收 amount 个 WOKB：这笔交易附带的 OKB 够就包成 WOKB（同 SwapRouter02 的 pay），否则从调用者转
    function _takeWeth(uint256 amount) internal {
        if (address(this).balance >= amount) {
            WETH9.deposit{value: amount}();
        } else {
            require(WETH9.transferFrom(msg.sender, address(this), amount), "STF");
        }
    }

    function _giveWeth(address recipient, uint256 amount) internal {
        require(reserve() >= amount, "reserve");
        if (recipient == ADDRESS_THIS) pendingWeth += amount;
        else require(WETH9.transfer(recipient, amount), "ST");
    }

    function _to(address recipient) internal view returns (address) {
        return recipient == ADDRESS_THIS ? address(this) : recipient;
    }

    function _afterFee(uint256 amount, uint24 fee) internal pure returns (uint256) {
        return amount * (FEE_UNIT - fee) / FEE_UNIT;
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    function _sendNative(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        require(ok, "STE");
    }
}
