// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IERC20} from "../interfaces/IERC20.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {IMezoRouter, IMezoPool} from "../interfaces/IMezoPools.sol";

/**
 * @title MezoPoolsAdapter
 * @notice Routes the vault's MUSD<->BTC leg through Mezo Pools' basic router
 * (Aerodrome-style `Route[]` calldata — verified on testnet).
 *
 * BTC leg = the native-BTC ERC20 precompile at
 * 0x7b7C000000000000000000000000000000000000. It mirrors native balances
 * (balanceOf(x) == eth_getBalance(x)), so no wrap/unwrap exists: router
 * payouts land as native BTC and are forwarded with a plain call, and when
 * spending BTC the router pulls it via the precompile's transferFrom using
 * the allowance granted in the constructor.
 *
 * The BTC-leg address is auto-discovered from the pool's token0/token1
 * rather than hardcoded — whichever side is not MUSD is BTC.
 */
contract MezoPoolsAdapter is ISwapAdapter, Ownable {
    address public constant BTC_PRECOMPILE =
        0x7b7C000000000000000000000000000000000000;

    IERC20 public immutable musd;
    IERC20 public immutable btcToken; // the BTC precompile
    IMezoRouter public immutable router;
    address public immutable factory;
    bool public immutable poolStable;
    uint256 public swapDeadlineSeconds = 300;

    constructor(
        address _router,
        address _pool, // MUSD/BTC basic pool
        address _musd
    ) Ownable(msg.sender) {
        musd = IERC20(_musd);
        router = IMezoRouter(_router);
        factory = IMezoRouter(_router).defaultFactory();

        address t0 = IMezoPool(_pool).token0();
        address t1 = IMezoPool(_pool).token1();
        require(t0 == _musd || t1 == _musd, "pool has no MUSD leg");
        address btcLeg = t0 == _musd ? t1 : t0;
        btcToken = IERC20(btcLeg);
        poolStable = IMezoPool(_pool).stable();
        require(btcLeg == BTC_PRECOMPILE, "unexpected BTC leg");

        musd.approve(_router, type(uint256).max);
        btcToken.approve(_router, type(uint256).max);
    }

    receive() external payable {}

    /// @inheritdoc ISwapAdapter
    /// @dev Router pays the BTC precompile -> lands as native BTC here -> forward.
    function swapMusdForBtc(
        uint256 musdIn,
        uint256 minBtcOut,
        address payable to
    ) external returns (uint256 btcOut) {
        require(
            musd.transferFrom(msg.sender, address(this), musdIn),
            "musd pull failed"
        );
        IMezoRouter.Route[] memory routes = _route(address(musd), btcLeg());
        uint256[] memory amounts = router.swapExactTokensForTokens(
            musdIn,
            minBtcOut,
            routes,
            address(this),
            block.timestamp + swapDeadlineSeconds
        );
        btcOut = amounts[amounts.length - 1];
        (bool ok, ) = to.call{value: btcOut}("");
        require(ok, "BTC send failed");
    }

    /// @inheritdoc ISwapAdapter
    /// @dev Native BTC in -> precompile transferFrom pulls it (allowance preset).
    function swapBtcForMusd(
        uint256 minMusdOut,
        address to
    ) external payable returns (uint256 musdOut) {
        IMezoRouter.Route[] memory routes = _route(btcLeg(), address(musd));
        uint256[] memory amounts = router.swapExactTokensForTokens(
            msg.value,
            minMusdOut,
            routes,
            to,
            block.timestamp + swapDeadlineSeconds
        );
        musdOut = amounts[amounts.length - 1];
    }

    /// @inheritdoc ISwapAdapter
    function quoteMusdToBtc(uint256 musdIn) external view returns (uint256) {
        IMezoRouter.Route[] memory routes = _route(address(musd), btcLeg());
        uint256[] memory amounts = router.getAmountsOut(musdIn, routes);
        return amounts[amounts.length - 1];
    }

    /// @inheritdoc ISwapAdapter
    function quoteBtcToMusd(uint256 btcIn) external view returns (uint256) {
        IMezoRouter.Route[] memory routes = _route(btcLeg(), address(musd));
        uint256[] memory amounts = router.getAmountsOut(btcIn, routes);
        return amounts[amounts.length - 1];
    }

    function setSwapDeadlineSeconds(uint256 s) external onlyOwner {
        swapDeadlineSeconds = s;
    }

    /// @notice Recover stuck tokens/native (only dust or failed-swap leftovers).
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).transfer(to, amount);
    }

    function rescueNative(address to, uint256 amount) external onlyOwner {
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "send failed");
    }

    function btcLeg() internal view returns (address) {
        return address(btcToken);
    }

    function _route(
        address from,
        address to
    ) internal view returns (IMezoRouter.Route[] memory routes) {
        routes = new IMezoRouter.Route[](1);
        routes[0] = IMezoRouter.Route({
            from: from,
            to: to,
            stable: poolStable,
            factory: factory
        });
    }
}
