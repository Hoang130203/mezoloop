// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "../interfaces/IERC20.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {IPriceFeed} from "../interfaces/IPriceFeed.sol";

/**
 * @notice Oracle-priced swap adapter for local tests and dry-run demos.
 * Holds a BTC float (fund it) and an MUSD float; quotes at the oracle price
 * minus a configurable feeBps, standing in for Mezo Pools liquidity when
 * none exists locally.
 */
contract MockSwapAdapter is ISwapAdapter {
    IERC20 public immutable musd;
    IPriceFeed public immutable priceFeed;
    uint256 public feeBps = 30; // 0.30% mimics volatile-pool fee

    constructor(address _musd, address _priceFeed) {
        musd = IERC20(_musd);
        priceFeed = IPriceFeed(_priceFeed);
    }

    receive() external payable {}

    /// @notice Fund the BTC side of the swap float.
    function fundBtc() external payable {}

    function swapMusdForBtc(
        uint256 musdIn,
        uint256 minBtcOut,
        address payable to
    ) external returns (uint256 btcOut) {
        require(
            musd.transferFrom(msg.sender, address(this), musdIn),
            "musd pull failed"
        );
        btcOut =
            (musdIn * 1e18 * (10_000 - feeBps)) /
            (priceFeed.fetchPrice() * 10_000);
        require(btcOut >= minBtcOut, "slippage");
        require(address(this).balance >= btcOut, "float exhausted");
        (bool ok, ) = to.call{value: btcOut}("");
        require(ok, "send failed");
    }

    function swapBtcForMusd(
        uint256 minMusdOut,
        address to
    ) external payable returns (uint256 musdOut) {
        musdOut =
            (msg.value * priceFeed.fetchPrice() * (10_000 - feeBps)) /
            (1e18 * 10_000);
        require(musdOut >= minMusdOut, "slippage");
        require(musd.transfer(to, musdOut), "musd send failed");
    }

    function quoteMusdToBtc(uint256 musdIn) external view returns (uint256) {
        return
            (musdIn * 1e18 * (10_000 - feeBps)) / (priceFeed.fetchPrice() * 10_000);
    }

    function quoteBtcToMusd(uint256 btcIn) external view returns (uint256) {
        return
            (btcIn * priceFeed.fetchPrice() * (10_000 - feeBps)) /
            (1e18 * 10_000);
    }
}
