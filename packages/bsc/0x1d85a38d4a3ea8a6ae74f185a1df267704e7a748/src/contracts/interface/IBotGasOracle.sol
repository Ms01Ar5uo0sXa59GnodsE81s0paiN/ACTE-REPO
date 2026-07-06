// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IBotGasOracle {
    /// @notice 按 TWAP 窗口把 baseAmount 数量的 baseToken 折算成 quoteToken 数量
    /// @dev 对接 botchain TWAP Oracle 代理（如 0x00f1BD8e…）的 quoteWithWindow(selector 0xf862b304)
    /// @param baseToken 计价基础币（BOT 的包装地址）
    /// @param quoteToken 报价币（USDT）
    /// @param baseAmount baseToken 数量（1e18 = 1 BOT）
    /// @param twapWindow TWAP 时间窗口（秒）
    /// @return quoteAmount 折算出的 quoteToken 数量（USDT 6 位精度）
    function quoteWithWindow(
        address baseToken,
        address quoteToken,
        uint128 baseAmount,
        uint32 twapWindow
    ) external view returns (uint256 quoteAmount);
}
