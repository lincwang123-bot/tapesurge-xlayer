// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRandomSource, IRandomConsumer} from "../interfaces/IRandomSource.sol";

/// @notice 仅用于测试：异步随机数源。请求后由测试代码调用 fulfill 交付随机数。
contract MockRandomSource is IRandomSource {
    uint256 public lastRequestId;
    mapping(uint256 => address) public consumerOf;

    event Requested(uint256 indexed requestId, address indexed consumer);

    function requestRandomness() external returns (uint256 requestId) {
        requestId = ++lastRequestId;
        consumerOf[requestId] = msg.sender;
        emit Requested(requestId, msg.sender);
    }

    function fulfill(uint256 requestId, uint256 word) external {
        IRandomConsumer(consumerOf[requestId]).onRandomness(requestId, word);
    }
}
