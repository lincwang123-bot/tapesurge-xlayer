// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IXMonthFactory} from "../interfaces/IXMonthBoard.sol";
import {IMonthBoardV2} from "../interfaces/IXMonthV2.sol";

/// @title XMonthPositions（X Layer 月局持仓凭证；从 BSC v2.0-audit.6 MonthPositions 移植，去掉标准局）
/// @notice 每份持仓 = 某块月局的一个插槽，编号 = 主板地址 << 96 | slot。
///         加入时由主板铸造给加入者。所有转移（transferFrom / safeTransferFrom / 授权代理 / 盘口成交）都经过 _update，
///         在这里调用主板的 onPositionTransfer：不在可转让阶段时整笔回滚；可以转让时主板先把卖方已经累计的款项
///         结转给卖方、退还通行证，再更新持有人和版本号。没有管理员，不可升级，不能销毁。
contract XMonthPositions is ERC721 {
    IXMonthFactory public immutable factory;

    error NotMonthBoard();
    error BadConfig();

    constructor(address factory_) ERC721("TapeSurge Position", "TSP") {
        if (factory_ == address(0)) revert BadConfig();
        factory = IXMonthFactory(factory_);
    }

    function idOf(address board, uint256 slot) public pure returns (uint256) {
        return (uint256(uint160(board)) << 96) | slot;
    }

    function boardOf(uint256 id) public pure returns (address) {
        return address(uint160(id >> 96));
    }

    function slotOf(uint256 id) public pure returns (uint256) {
        return id & type(uint96).max;
    }

    /// @notice 只认 XMonthFactory 登记过的主板；编号里的主板地址就是调用者，所以一块主板只能铸造自己的持仓。
    function mint(address to, uint256 slot) external {
        if (!factory.isBoard(msg.sender)) revert NotMonthBoard();
        _mint(to, idOf(msg.sender, slot));
    }

    /// @dev 铸造（from = 0）不回调；其余所有转移都先完成 ERC-721 记账，再由主板检查和结转，主板 revert 时整笔回滚。
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        if (from != address(0)) IMonthBoardV2(boardOf(tokenId)).onPositionTransfer(slotOf(tokenId), from, to);
    }
}
