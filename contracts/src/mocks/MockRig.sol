// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRig} from "../interfaces/IRig.sol";

interface IMintableBem {
    function mint(address to, uint256 amount) external;
}

/// @notice 仅用于测试 / 测试网：模拟 TapeOut 矿机凭证 RIG（按 RigVoucher.sol 的规则）：
///         - 每次转移记一条 (时间, 持有人)，`holderAt` / `payeeAt` 按时间查；
///         - `deliverYield(time, ids, shares, powers)`：模拟 LayerZero 送达一笔"BSC 上 time 时刻发起的收取"——
///           先按 `time` 更新算力和同步时间（只接受比上次更新的），再把 BEM 按份额用普通 transfer 打给 time 时刻的持有人。
///           到账可以晚于 time（模拟跨链延迟），收益仍然归 time 时刻的持有人。
///         - `claim(ids)`（测试网用）：任何人可调，模拟"在 BSC 金库上发起收取"并立即到账：按 算力 × 速率 × 距上次收取的时间
///           铸造 MockBEM，付给当前持有人，同时把同步时间更新为现在。速率由部署者设一次（setYieldRate）。
contract MockRig is ERC721, IRig {
    struct Mark {
        uint64 time;
        address holder;
    }

    IERC20 public immutable bem;
    mapping(uint256 => Rig) internal _rigs;
    mapping(uint256 => Mark[]) internal _marks;
    mapping(address => uint256) public powerHeld;
    uint256 public totalPower;
    address public immutable deployer;
    /// @notice claim() 的产出速率：每单位算力每天多少 BEM 最小单位（0 = 不自动产出）
    uint256 public yieldPerPowerDay;
    mapping(uint256 => uint256) public lastClaimAt;

    event YieldClaimed(uint256 indexed id, address indexed payee, uint256 amount, uint256 power);

    constructor(address bem_) ERC721("TapeOut Rig (mock)", "RIG") {
        bem = IERC20(bem_);
        deployer = msg.sender;
    }

    function setYieldRate(uint256 perPowerDay) external {
        require(msg.sender == deployer, "only deployer");
        yieldPerPowerDay = perPowerDay;
    }

    /// @notice 测试网：模拟在 BSC 金库上发起收取并立即到账（任何人可调）
    function claim(uint256[] calldata ids) external returns (uint256 total) {
        for (uint256 i; i < ids.length; i++) {
            uint256 id = ids[i];
            Rig storage r = _rigs[id];
            uint256 since = lastClaimAt[id];
            lastClaimAt[id] = block.timestamp;
            if (block.timestamp > r.syncedAt) r.syncedAt = uint64(block.timestamp);
            uint256 amount = since == 0 ? 0 : r.power * yieldPerPowerDay * (block.timestamp - since) / 1 days;
            if (amount == 0) continue;
            address payee = _ownerOf(id);
            IMintableBem(address(bem)).mint(payee, amount);
            total += amount;
            emit YieldClaimed(id, payee, amount, r.power);
        }
    }

    function rigs(uint256 id) external view returns (Rig memory) {
        return _rigs[id];
    }

    function isSealed() external pure returns (bool) {
        return false;
    }

    function ownerOf(uint256 id) public view override(ERC721, IRig) returns (address) {
        return super.ownerOf(id);
    }

    function transferFrom(address from, address to, uint256 id) public override(ERC721, IRig) {
        super.transferFrom(from, to, id);
    }

    function holderAt(uint256 id, uint256 time) public view returns (address) {
        Mark[] storage m = _marks[id];
        uint256 n = m.length;
        if (n == 0) return address(0);
        if (time < m[0].time) return m[0].holder;
        uint256 lo;
        uint256 hi = n;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (m[mid].time <= time) lo = mid;
            else hi = mid;
        }
        return m[lo].holder;
    }

    function payeeAt(uint256 id, uint256 time) public view returns (address) {
        return holderAt(id, time);
    }

    // ---------------- 测试辅助 ----------------

    function mintRig(address to, uint256 id, address circuits, uint256 circuitId, uint256 power) external {
        _rigs[id] = Rig({circuits: circuits, syncedAt: uint64(block.timestamp), circuitId: circuitId, power: power});
        lastClaimAt[id] = block.timestamp;
        _mint(to, id);
    }

    /// @notice 模拟一次同步（BSC 上发起收取时随消息同步算力），不付产出
    function sync(uint256 id, uint256 power, uint64 time) external {
        _setPower(id, power, time);
    }

    /// @notice 模拟 LayerZero 送达一笔收益：BEM 先由调用者转给本合约，再按份额付给 time 时刻的持有人
    function deliverYield(uint64 time, uint256[] calldata ids, uint256[] calldata shares, uint256[] calldata powers)
        external
    {
        uint256 total;
        for (uint256 i; i < ids.length; i++) {
            total += shares[i];
        }
        bem.transferFrom(msg.sender, address(this), total);
        for (uint256 i; i < ids.length; i++) {
            _setPower(ids[i], powers[i], time);
            if (shares[i] > 0) bem.transfer(payeeAt(ids[i], time), shares[i]);
        }
    }

    function _setPower(uint256 id, uint256 power, uint64 time) internal {
        Rig storage r = _rigs[id];
        if (time <= r.syncedAt) return;
        r.syncedAt = time;
        uint256 old = r.power;
        r.power = power;
        address holder = _ownerOf(id);
        if (holder != address(0) && old != power) {
            powerHeld[holder] = powerHeld[holder] - old + power;
            totalPower = totalPower - old + power;
        }
    }

    function _update(address to, uint256 id, address auth) internal override returns (address from) {
        from = super._update(to, id, auth);
        _marks[id].push(Mark(uint64(block.timestamp), to));
        uint256 p = _rigs[id].power;
        if (p != 0) {
            if (from == address(0)) totalPower += p;
            else powerHeld[from] -= p;
            if (to == address(0)) totalPower -= p;
            else powerHeld[to] += p;
        }
    }
}
