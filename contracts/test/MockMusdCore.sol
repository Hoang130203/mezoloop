// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MockMusd} from "./MockMusd.sol";
import {MockPriceFeed} from "./MockPriceFeed.sol";
import {IBorrowerOperations} from "../interfaces/IBorrowerOperations.sol";
import {ITroveManager} from "../interfaces/ITroveManager.sol";
import {IHintHelpers} from "../interfaces/IHintHelpers.sol";

/**
 * @notice Faithful-in-the-small MUSD core for local testing: implements the
 * BorrowerOperations entry points, TroveManager read surface, and
 * HintHelpers that MezoLoopVault touches, with the real protocol rules:
 *   - openTrove requires debt >= minNetDebt and post-fee ICR >= MCR (110%)
 *   - withdrawMUSD adds a 0.1% borrowing fee on top of principal
 *   - any state change that would drop ICR below MCR reverts
 *   - closeTrove requires zero debt and returns all collateral
 * Hints are accepted but ignored (single-borrower local world).
 */
contract MockMusdCore is IBorrowerOperations, ITroveManager, IHintHelpers {
    uint256 public constant MCR = 1.1e18;
    uint256 private constant P = 1e18;

    MockMusd public immutable musdToken;
    MockPriceFeed public immutable priceFeedContract;

    uint256 public minNetDebt = 1800e18;
    uint256 public borrowingRate = 1e15; // 0.1% in 1e18 precision

    struct TroveData {
        uint256 coll;
        uint256 debt;
        Status status;
    }
    mapping(address => TroveData) public troves;

    constructor(address _musd, address _priceFeed) {
        musdToken = MockMusd(_musd);
        priceFeedContract = MockPriceFeed(_priceFeed);
    }

    // ---------------- BorrowerOperations ----------------

    function openTrove(
        uint256 _debtAmount,
        address,
        address
    ) external payable override {
        TroveData storage t = troves[msg.sender];
        require(t.status != Status.active, "trove active");
        require(_debtAmount >= minNetDebt, "below minNetDebt");
        uint256 fee = (_debtAmount * borrowingRate) / P;
        t.coll = msg.value;
        t.debt = _debtAmount + fee;
        t.status = Status.active;
        require(_icr(t.coll, t.debt) >= MCR, "ICR < MCR");
        musdToken.mint(msg.sender, _debtAmount);
    }

    function addColl(address, address) external payable override {
        TroveData storage t = troves[msg.sender];
        require(t.status == Status.active, "no trove");
        t.coll += msg.value;
    }

    function withdrawColl(uint256 _amount, address, address) external override {
        TroveData storage t = troves[msg.sender];
        require(t.status == Status.active, "no trove");
        require(t.coll >= _amount, "coll exceeded");
        uint256 newColl = t.coll - _amount;
        require(
            t.debt == 0 ? true : _icr(newColl, t.debt) >= MCR,
            "ICR < MCR"
        );
        t.coll = newColl;
        (bool ok, ) = msg.sender.call{value: _amount}("");
        require(ok, "send failed");
    }

    function withdrawMUSD(uint256 _amount, address, address) external override {
        TroveData storage t = troves[msg.sender];
        require(t.status == Status.active, "no trove");
        uint256 fee = (_amount * borrowingRate) / P;
        uint256 newDebt = t.debt + _amount + fee;
        require(_icr(t.coll, newDebt) >= MCR, "ICR < MCR");
        t.debt = newDebt;
        musdToken.mint(msg.sender, _amount);
    }

    function repayMUSD(uint256 _amount, address, address) external override {
        TroveData storage t = troves[msg.sender];
        require(t.status == Status.active, "no trove");
        uint256 pay = _amount > t.debt ? t.debt : _amount;
        musdToken.burnFrom(msg.sender, pay);
        t.debt -= pay;
    }

    function adjustTrove(
        uint256 _collWithdrawal,
        uint256 _debtChange,
        bool _isDebtIncrease,
        address,
        address
    ) external payable override {
        TroveData storage t = troves[msg.sender];
        require(t.status == Status.active, "no trove");
        require(
            !(msg.value > 0 && _collWithdrawal > 0),
            "coll in and out"
        );
        uint256 newColl = t.coll + msg.value - _collWithdrawal;
        uint256 newDebt = t.debt;
        if (_debtChange > 0) {
            if (_isDebtIncrease) {
                newDebt += _debtChange + (_debtChange * borrowingRate) / P;
            } else {
                uint256 pay = _debtChange > newDebt ? newDebt : _debtChange;
                musdToken.burnFrom(msg.sender, pay);
                newDebt -= pay;
            }
        }
        require(
            newDebt == 0 ? newColl >= 0 : _icr(newColl, newDebt) >= MCR,
            "ICR < MCR"
        );
        t.coll = newColl;
        t.debt = newDebt;
        if (_isDebtIncrease && _debtChange > 0)
            musdToken.mint(msg.sender, _debtChange);
        if (_collWithdrawal > 0) {
            (bool ok, ) = msg.sender.call{value: _collWithdrawal}("");
            require(ok, "send failed");
        }
    }

    function closeTrove() external override {
        TroveData storage t = troves[msg.sender];
        require(t.status == Status.active, "no trove");
        require(t.debt == 0, "debt outstanding");
        uint256 refund = t.coll;
        t.coll = 0;
        t.status = Status.closedByOwner;
        (bool ok, ) = msg.sender.call{value: refund}("");
        require(ok, "send failed");
    }

    function refinance(address, address) external override {}

    function claimCollateral() external override {}

    // ---------------- TroveManager reads ----------------

    function getEntireDebtAndColl(
        address _borrower
    )
        external
        view
        override
        returns (
            uint256 coll,
            uint256 principal,
            uint256 interest,
            uint256 pendingCollateral,
            uint256 pendingPrincipal,
            uint256 pendingInterest
        )
    {
        TroveData storage t = troves[_borrower];
        return (t.coll, t.debt, 0, 0, 0, 0);
    }

    function getTroveDebt(address b) external view override returns (uint256) {
        return troves[b].debt;
    }

    function getTroveColl(address b) external view override returns (uint256) {
        return troves[b].coll;
    }

    function getTroveStatus(address b) external view override returns (Status) {
        return troves[b].status;
    }

    function getNominalICR(address b) external view override returns (uint256) {
        TroveData storage t = troves[b];
        if (t.debt == 0) return type(uint256).max;
        return (t.coll * 1e20) / t.debt; // NICR convention (coll/debt * 100)
    }

    function getCurrentICR(
        address b,
        uint256 _price
    ) external view override returns (uint256) {
        TroveData storage t = troves[b];
        if (t.debt == 0) return type(uint256).max;
        return (t.coll * _price) / t.debt;
    }

    function getTCR(uint256) external pure override returns (uint256) {
        return type(uint256).max; // single-borrower local world: always healthy
    }

    function checkRecoveryMode(uint256) external pure override returns (bool) {
        return false;
    }

    // ---------------- HintHelpers ----------------

    function getApproxHint(
        uint256,
        uint256,
        uint256
    ) external view override returns (address, uint256, uint256) {
        return (address(this), 0, 0);
    }

    function computeNominalCR(
        uint256 _coll,
        uint256 _debt
    ) external pure override returns (uint256) {
        if (_debt == 0) return type(uint256).max;
        return (_coll * 1e20) / _debt;
    }

    function computeCR(
        uint256 _coll,
        uint256 _debt,
        uint256 _price
    ) external pure override returns (uint256) {
        if (_debt == 0) return type(uint256).max;
        return (_coll * _price) / _debt;
    }

    // ---------------- internals ----------------

    function _icr(uint256 coll, uint256 debt) internal view returns (uint256) {
        if (debt == 0) return type(uint256).max;
        return (coll * priceFeedContract.fetchPrice()) / debt;
    }
}
