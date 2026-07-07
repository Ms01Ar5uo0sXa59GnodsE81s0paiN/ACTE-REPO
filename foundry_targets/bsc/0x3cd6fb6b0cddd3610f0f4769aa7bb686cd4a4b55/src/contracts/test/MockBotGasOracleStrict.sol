// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IBotGasOracle} from "../interface/IBotGasOracle.sol";

/// @dev 严格桩：只有当 quoteWithWindow 收到预期的 (baseToken, quoteToken, baseAmount, twapWindow)
/// 时才返回设定值，否则 revert —— 用于锁定 BotBridge 传参顺序，防 base/quote 互换或窗口传错。
contract MockBotGasOracleStrict is IBotGasOracle {
    uint256 public quoteValue;
    address public expBase;
    address public expQuote;
    uint128 public expAmount;
    uint32 public expWindow;

    function setExpectation(
        address base_,
        address quote_,
        uint128 amount_,
        uint32 window_,
        uint256 quoteValue_
    ) external {
        expBase = base_;
        expQuote = quote_;
        expAmount = amount_;
        expWindow = window_;
        quoteValue = quoteValue_;
    }

    function quoteWithWindow(
        address baseToken,
        address quoteToken,
        uint128 baseAmount,
        uint32 twapWindow
    ) external view returns (uint256) {
        require(baseToken == expBase, "bad base");
        require(quoteToken == expQuote, "bad quote");
        require(baseAmount == expAmount, "bad amount");
        require(twapWindow == expWindow, "bad window");
        return quoteValue;
    }
}
