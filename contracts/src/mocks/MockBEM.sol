// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice 仅用于测试 / 测试网：模拟 BEM（8 位小数）。任何人都能铸造。
/// @dev 主网 BEM 只有 PoD 能铸造，也没有 burn 函数，所以回购后转入 0x…dEaD。
contract MockBEM is ERC20 {
    constructor() ERC20("Mock BEM", "mBEM") {}

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
