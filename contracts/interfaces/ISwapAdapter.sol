// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Pluggable liquidity leg of the loop: MUSD <-> native BTC.
/// Wave 1 ships MezoPoolsAdapter (Mezo Pools router). A mock adapter is used
/// for local tests; future adapters (aggregators, OTC) can be swapped in
/// without touching the vault.
interface ISwapAdapter {
    /// @notice Pull musdIn MUSD from msg.sender, send native BTC to `to`.
    function swapMusdForBtc(
        uint256 musdIn,
        uint256 minBtcOut,
        address payable to
    ) external returns (uint256 btcOut);

    /// @notice Take msg.value BTC, send MUSD to `to`.
    function swapBtcForMusd(
        uint256 minMusdOut,
        address to
    ) external payable returns (uint256 musdOut);

    /// @notice Expected BTC out for musdIn at current liquidity (informational).
    function quoteMusdToBtc(uint256 musdIn) external view returns (uint256);

    /// @notice Expected MUSD out for btcIn at current liquidity (informational).
    function quoteBtcToMusd(uint256 btcIn) external view returns (uint256);
}
