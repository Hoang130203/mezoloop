// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "../interfaces/IERC20.sol";
import {IBorrowerOperations} from "../interfaces/IBorrowerOperations.sol";
import {ITroveManager} from "../interfaces/ITroveManager.sol";
import {IHintHelpers} from "../interfaces/IHintHelpers.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";

/// @notice Bisects the vault's loop steps on live testnet in ONE call.
/// Self external-calls let try/catch flag which stage fails.
/// flag bits: 1=borrow1, 2=refi, 4=borrow2, 8=swap+topup
contract TroveDiag {
    IBorrowerOperations public immutable bo;
    ITroveManager public immutable tm;
    IHintHelpers public immutable hh;
    ISwapAdapter public immutable adapter;
    IERC20 public immutable musd;

    constructor(address _bo, address _tm, address _hh, address _adapter, address _musd) {
        bo = IBorrowerOperations(_bo);
        tm = ITroveManager(_tm);
        hh = IHintHelpers(_hh);
        adapter = ISwapAdapter(_adapter);
        musd = IERC20(_musd);
        musd.approve(_adapter, type(uint256).max);
    }

    receive() external payable {}

    function hints() external view returns (address up, address lo) {
        uint256 nicr = tm.getNominalICR(address(this));
        if (nicr == 0) nicr = type(uint256).max;
        (address h, , ) = hh.getApproxHint(nicr, 10, uint256(uint160(address(this))) ^ block.number);
        return (h, h);
    }

    function openStep(uint256 coll, uint256 debt, address h) external {
        bo.openTrove{value: coll}(debt, h, h);
    }

    function borrowStep(uint256 amt, address h) external {
        bo.withdrawMUSD(amt, h, h);
    }

    function refiStep(address h) external {
        bo.refinance(h, h);
    }

    function swapStep(uint256 musdAmt, uint256 minOut, address h) external {
        uint256 btcOut = adapter.swapMusdForBtc(musdAmt, minOut, payable(address(this)));
        bo.addColl{value: btcOut}(h, h);
    }

    /// @dev Runs open -> borrow1 -> refi -> borrow2 -> swap+topup, reporting
    /// which stages reverted via the returned bitmask.
    function diag(
        uint256 coll,
        uint256 debt,
        uint256 b1,
        uint256 b2,
        uint256 minOut
    ) external returns (uint256 flags) {
        (address h, ) = this.hints();
        this.openStep(coll, debt, h); // open must succeed or everything reverts
        try this.borrowStep(b1, this.hintNow()) {} catch { flags |= 1; }
        try this.refiStep(this.hintNow()) {} catch { flags |= 2; }
        try this.borrowStep(b2, this.hintNow()) {} catch { flags |= 4; }
        try this.swapStep(b2, minOut, this.hintNow()) {} catch { flags |= 8; }
    }

    /// @dev Vault-faithful sequence: open -> swapTopup(debt) -> refi ->
    /// borrow(b2) -> swapTopup(b2). bits: 1=swap1, 2=refi, 4=borrow, 8=swap2
    function diag2(
        uint256 coll,
        uint256 debt,
        uint256 b2,
        uint256 minOut
    ) external returns (uint256 flags) {
        this.openStep(coll, debt, this.hintNow());
        try this.swapStep(debt, minOut, this.hintNow()) {} catch { flags |= 1; }
        try this.refiStep(this.hintNow()) {} catch { flags |= 2; }
        try this.borrowStep(b2, this.hintNow()) {} catch { flags |= 4; }
        try this.swapStep(b2, minOut, this.hintNow()) {} catch { flags |= 8; }
    }

    /// @dev Same as diag2 but the final borrow is UNWRAPPED — its raw revert
    /// reason propagates to the caller.
    function diag3(
        uint256 coll,
        uint256 debt,
        uint256 b2,
        uint256 minOut
    ) external {
        this.openStep(coll, debt, this.hintNow());
        this.swapStep(debt, minOut, this.hintNow());
        this.refiStep(this.hintNow());
        this.borrowStep(b2, this.hintNow());
    }

    /// @dev Like diag3 but computes hints internally right before borrow,
    /// mirroring the vault's sBorrow (hints-after-refi ordering).
    function diag4(uint256 coll, uint256 debt, uint256 b2, uint256 minOut) external {
        this.openStep(coll, debt, this.hintNow());
        this.swapStep(debt, minOut, this.hintNow());
        this.refiStep(this.hintNow());
        // mimic vault: view reads (trove state + cap) BETWEEN refi and borrow
        this.state();
        (address h, ) = this.hints();
        this.borrowStep(b2, h);
    }

    function hintNow() external view returns (address h) {
        (h, ) = this.hints();
    }

    function state() external view returns (uint256 coll, uint256 debt, uint256 cap) {
        coll = tm.getTroveColl(address(this));
        debt = tm.getTroveDebt(address(this));
        cap = tm.getTroveMaxBorrowingCapacity(address(this));
    }
}
