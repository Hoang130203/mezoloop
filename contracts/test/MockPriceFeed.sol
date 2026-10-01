// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Settable BTC/USD price feed (1e18-scaled) for local tests.
contract MockPriceFeed {
    uint256 public price;

    constructor(uint256 _price) {
        price = _price;
    }

    function fetchPrice() external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 _price) external {
        price = _price;
    }
}
