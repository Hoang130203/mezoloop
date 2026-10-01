// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "../interfaces/IERC20.sol";
import {IBorrowerOperations} from "../interfaces/IBorrowerOperations.sol";
import {ITroveManager} from "../interfaces/ITroveManager.sol";
import {IPriceFeed} from "../interfaces/IPriceFeed.sol";
import {IHintHelpers} from "../interfaces/IHintHelpers.sol";
import {ISortedTroves} from "../interfaces/ISortedTroves.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";

/// @notice Faithful replica of MezoLoopVault.enter()'s loop, with each step a
/// try/catchable external self-call so a live failure can be bisected.
/// flag bits: 1=openTrove 2=swap1 4=iter-troveRead 8=iter-hints 16=iter-refi
///            32=iter-borrow 64=iter-swap 128=loopGuard
contract VaultDiag {
    uint256 private constant PRECISION = 1e18;
    uint256 private constant BPS = 10_000;
    uint256 private constant GAS_COMP = 200e18;
    uint8 private constant MAX_REFIS = 6;
    uint256 public constant MIN_LOOP_BORROW = 1e18;

    IERC20 public immutable musd;
    IBorrowerOperations public immutable borrowerOperations;
    ITroveManager public immutable troveManager;
    IPriceFeed public immutable priceFeed;
    IHintHelpers public immutable hintHelpers;
    ISortedTroves public immutable sortedTroves;
    ISwapAdapter public immutable swapAdapter;

    uint256 public targetICR = 1.5e18;
    uint256 public unwindFloorICR = 1.15e18;
    uint16 public maxSlippageBps = 500;
    uint8 public hintTrials = 10;

    constructor(address _musd, address _bo, address _tm, address _pf, address _hh, address _st, address _adapter) {
        musd = IERC20(_musd);
        borrowerOperations = IBorrowerOperations(_bo);
        troveManager = ITroveManager(_tm);
        priceFeed = IPriceFeed(_pf);
        hintHelpers = IHintHelpers(_hh);
        sortedTroves = ISortedTroves(_st);
        swapAdapter = ISwapAdapter(_adapter);
        musd.approve(_adapter, type(uint256).max);
    }

    receive() external payable {}

    // ----- external step wrappers (self-called for try/catch) -----

    function sTrove() external view returns (uint256, uint256, uint256, uint8) {
        uint256 coll = troveManager.getTroveColl(address(this));
        uint256 debt = troveManager.getTroveDebt(address(this));
        uint8 status = uint8(troveManager.getTroveStatus(address(this)));
        uint256 icr = debt == 0 ? type(uint256).max : troveManager.getCurrentICR(address(this), _price());
        return (coll, debt, icr, status);
    }

    /// @dev Canonical Liquity hint pattern: approxHint then findInsertPosition.
    function sHintsNicr(uint256 nicr) external view returns (address, address) {
        if (nicr == 0) nicr = type(uint256).max;
        (address hint, , ) = hintHelpers.getApproxHint(
            nicr,
            hintTrials,
            uint256(uint160(address(this))) ^ block.number
        );
        return sortedTroves.findInsertPosition(nicr, hint, hint);
    }

    function sOpen(uint256 coll, uint256 debt) external {
        uint256 comp = (debt * (PRECISION + borrowerOperations.borrowingRate())) / PRECISION + GAS_COMP;
        uint256 nicr = hintHelpers.computeNominalCR(coll, comp);
        (address up, address lo) = this.sHintsNicr(nicr);
        borrowerOperations.openTrove{value: coll}(debt, up, lo);
    }

    function sSwapTopUp(uint256 musdAmount) external {
        uint256 minOut = (swapAdapter.quoteMusdToBtc(musdAmount) * (BPS - maxSlippageBps)) / BPS;
        uint256 btcOut = swapAdapter.swapMusdForBtc(musdAmount, minOut, payable(address(this)));
        uint256 coll = troveManager.getTroveColl(address(this)) + btcOut;
        uint256 debt = troveManager.getTroveDebt(address(this));
        uint256 nicr = hintHelpers.computeNominalCR(coll, debt);
        (address up, address lo) = this.sHintsNicr(nicr);
        borrowerOperations.addColl{value: btcOut}(up, lo);
    }

    function sRefi() external {
        uint256 coll = troveManager.getTroveColl(address(this));
        uint256 debt = troveManager.getTroveDebt(address(this));
        uint256 nicr = hintHelpers.computeNominalCR(coll, debt);
        (address up, address lo) = this.sHintsNicr(nicr);
        borrowerOperations.refinance(up, lo);
    }

    function sBorrow(uint256 d) external {
        uint256 coll = troveManager.getTroveColl(address(this));
        uint256 debt = troveManager.getTroveDebt(address(this));
        uint256 post = debt + (d * (PRECISION + borrowerOperations.borrowingRate())) / PRECISION;
        uint256 nicr = hintHelpers.computeNominalCR(coll, post);
        (address up, address lo) = this.sHintsNicr(nicr);
        borrowerOperations.withdrawMUSD(d, up, lo);
    }

    function sBorrowRaw(uint256 d, address up, address lo) external {
        borrowerOperations.withdrawMUSD(d, up, lo);
    }

    function sCap() external view returns (uint256) {
        return troveManager.getTroveMaxBorrowingCapacity(address(this));
    }

    function sPrice() external view returns (uint256) {
        return _price();
    }

    // ----- the instrumented enter() -----

    /// @dev Vault-identical enter + loop, flagging the failing stage.
    function diagEnter(
        uint256 initialDebt,
        uint8 maxIters
    )
        external
        returns (
            uint256 flags, uint256 lastD, uint256 gBefore, uint256 gAfter
        )
    {
        uint256 free = address(this).balance;
        if (initialDebt == 0) initialDebt = (free * _price()) / 1.3e18;

        try this.sOpen(free, initialDebt) {} catch { return (1,0,0,0); }
        try this.sSwapTopUp(initialDebt) {} catch { return (2,0,0,0); }

        uint256 feeRate = borrowerOperations.borrowingRate();
        uint8 refis;
        for (uint8 i; i < maxIters; ++i) {
            uint256 coll; uint256 debt; uint256 icr; uint8 status;
            try this.sTrove() returns (uint256 c, uint256 d2, uint256 ic, uint8 s) {
                coll = c; debt = d2; icr = ic; status = s;
            } catch { return (flags | (4 << (i * 8)), lastD, 0, 0); }
            if (status != 1 || icr <= targetICR) break;

            (uint256 d, uint256 maxCap, uint256 dProto) = _plan(coll, debt, feeRate);
            if (dProto < d && refis < MAX_REFIS) {
                try this.sRefi() { ++refis; flags |= 0; continue; }
                catch { flags |= 16 << (i * 8); }
            }
            if (d > dProto) d = dProto;
            if (d < MIN_LOOP_BORROW) break;
            lastD = d;
            gBefore = gasleft();
            try this.sBorrow(d) {} catch { gAfter = gasleft(); return (flags | (32 << (i * 8)), lastD, gBefore, gAfter); }
            try this.sSwapTopUp(d) {} catch { return (flags | (64 << (i * 8)), lastD, gasleft(), 0); }
        }
        return (flags, lastD, 0, 0);
    }

    function _plan(
        uint256 coll,
        uint256 debt,
        uint256 feeRate
    ) internal view returns (uint256 d, uint256 maxCap, uint256 dProto) {
        uint256 collUsd = (coll * _price()) / PRECISION;
        uint256 dTarget = _borrowToReachTarget(collUsd, debt);
        uint256 dCap = _borrowHeadroom(collUsd, debt, feeRate);
        d = dTarget < dCap ? dTarget : dCap;
        maxCap = troveManager.getTroveMaxBorrowingCapacity(address(this));
        dProto = maxCap > debt
            ? ((maxCap - debt) * PRECISION) / (PRECISION + feeRate)
            : 0;
    }

    function _price() internal view returns (uint256) {
        return priceFeed.fetchPrice();
    }

    function _borrowToReachTarget(uint256 collUsd, uint256 debt) internal view returns (uint256 d) {
        uint256 targetDebtUsd = (targetICR * debt) / PRECISION;
        if (collUsd <= targetDebtUsd) return 0;
        d = ((collUsd - targetDebtUsd) * PRECISION) / (targetICR - PRECISION);
    }

    function _borrowHeadroom(uint256 collUsd, uint256 debt, uint256 feeRate) internal view returns (uint256) {
        uint256 floorUsd = (unwindFloorICR * debt) / PRECISION;
        if (collUsd <= floorUsd) return 0;
        return ((collUsd - floorUsd) * PRECISION * PRECISION) / (unwindFloorICR * (PRECISION + feeRate));
    }
}
