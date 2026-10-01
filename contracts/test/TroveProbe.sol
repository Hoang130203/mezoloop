// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "../interfaces/IERC20.sol";
import {IBorrowerOperations} from "../interfaces/IBorrowerOperations.sol";
import {ITroveManager} from "../interfaces/ITroveManager.sol";
import {IPriceFeed} from "../interfaces/IPriceFeed.sol";
import {IHintHelpers} from "../interfaces/IHintHelpers.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";

/// @notice Dev-only probe mirroring MezoLoopVault.enter() step by step so a
/// failing live call can be bisected. Never meant for production.
contract TroveProbe {
    IBorrowerOperations public immutable bo;
    ITroveManager public immutable tm;
    IPriceFeed public immutable pf;
    IHintHelpers public immutable hh;
    ISwapAdapter public adapter;

    constructor(address _bo, address _tm, address _pf, address _hh, address _adapter) {
        bo = IBorrowerOperations(_bo);
        tm = ITroveManager(_tm);
        pf = IPriceFeed(_pf);
        hh = IHintHelpers(_hh);
        adapter = ISwapAdapter(_adapter);
    }

    receive() external payable {}

    function hints() external view returns (address up, address lo) {
        uint256 nicr = tm.getNominalICR(address(this));
        if (nicr == 0) nicr = type(uint256).max;
        (address hint, , ) = hh.getApproxHint(
            nicr,
            10,
            uint256(uint160(address(this))) ^ block.number
        );
        return (hint, hint);
    }

    function open(uint256 debt, address up, address lo) external payable {
        bo.openTrove{value: msg.value}(debt, up, lo);
    }

    /// @dev Opens a trove spending the probe's own BTC balance.
    function openSelf(uint256 coll, uint256 debt, address up, address lo) external {
        bo.openTrove{value: coll}(debt, up, lo);
    }

    /// @dev Sweep the probe's free BTC back to the caller.
    function sweep() external {
        (bool ok, ) = msg.sender.call{value: address(this).balance}("");
        require(ok, "sweep failed");
    }

    function borrow(uint256 amt, address up, address lo) external {
        bo.withdrawMUSD(amt, up, lo);
    }

    function topUp(address up, address lo) external payable {
        bo.addColl{value: msg.value}(up, lo);
    }

    function refi(address up, address lo) external {
        bo.refinance(up, lo);
    }

    function setAdapter(address _a, address _musd) external {
        adapter = ISwapAdapter(_a);
        IERC20(_musd).approve(_a, type(uint256).max);
    }

    function quote(uint256 musdAmt) external view returns (uint256) {
        return adapter.quoteMusdToBtc(musdAmt);
    }

    function swap(uint256 musdAmt, uint256 minOut) external returns (uint256) {
        return adapter.swapMusdForBtc(musdAmt, minOut, payable(address(this)));
    }

    function state()
        external
        view
        returns (uint256 coll, uint256 debt, uint256 cap, uint256 nicr)
    {
        coll = tm.getTroveColl(address(this));
        debt = tm.getTroveDebt(address(this));
        cap = tm.getTroveMaxBorrowingCapacity(address(this));
        nicr = tm.getNominalICR(address(this));
    }
}
