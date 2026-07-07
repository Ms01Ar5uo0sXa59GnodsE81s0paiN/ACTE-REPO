// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IBotGasOracle} from "../interface/IBotGasOracle.sol";

/// @dev 测试桩：忽略入参，返回 setQuote 设定的固定值，便于断言确定的 botCostUsdt
contract MockBotGasOracle is IBotGasOracle {
    uint256 public quoteValue;

    function setQuote(uint256 quoteValue_) external {
        quoteValue = quoteValue_;
    }

    function quoteWithWindow(
        address, // baseToken
        address, // quoteToken
        uint128, // baseAmount
        uint32   // twapWindow
    ) external view returns (uint256) {
        return quoteValue;
    }
}
