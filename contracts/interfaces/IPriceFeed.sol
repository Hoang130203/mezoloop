// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice MUSD PriceFeed (verified against mezo-org/musd IPriceFeed.sol).
/// Returns the BTC/USD price scaled to 1e18.
interface IPriceFeed {
    function fetchPrice() external view returns (uint256);
}
