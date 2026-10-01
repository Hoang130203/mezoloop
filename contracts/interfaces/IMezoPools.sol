// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Mezo Pools basic router — Aerodrome/Velodrome-style.
/// Verified live on Mezo testnet (chain 31611): defaultFactory() returns the
/// PoolFactory and getAmountsOut(uint256,Route[]) quotes successfully.
/// Docs describe the swap flow as `swapExactTokensForTokens` — the Aerodrome
/// selector 0xcac88ea9, NOT the UniV2 path-array variant.
interface IMezoRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(
        uint256 amountIn,
        Route[] memory routes
    ) external view returns (uint256[] memory amounts);

    function defaultFactory() external view returns (address);
}

/// @notice Pair pool — used to auto-discover which token is the BTC leg.
/// On Mezo the MUSD/BTC pool's BTC token is the precompile
/// 0x7b7C000000000000000000000000000000000000, an ERC20 facade over native
/// BTC (balanceOf == eth_getBalance; verified on testnet).
interface IMezoPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function stable() external view returns (bool);
}
