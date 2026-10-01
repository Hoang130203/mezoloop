// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Subset of MUSD's BorrowerOperations used by MezoLoop.
/// Source verified against github.com/mezo-org/musd
/// (solidity/contracts/BorrowerOperations.sol).
/// Collateral is NATIVE BTC on Mezo, so open/add/adjust are payable.
interface IBorrowerOperations {
    /// @notice Open a trove: msg.value becomes collateral, mints _debtAmount MUSD.
    /// MUSD enforces minNetDebt (1800e18 at launch) and a borrowing fee on top.
    function openTrove(
        uint256 _debtAmount,
        address _upperHint,
        address _lowerHint
    ) external payable;

    /// @notice Top up collateral. msg.value is native BTC.
    function addColl(address _upperHint, address _lowerHint) external payable;

    /// @notice Withdraw BTC collateral from the trove.
    function withdrawColl(
        uint256 _amount,
        address _upperHint,
        address _lowerHint
    ) external;

    /// @notice Mint _amount MUSD against the trove (debt increases by amount+fee).
    function withdrawMUSD(
        uint256 _amount,
        address _upperHint,
        address _lowerHint
    ) external;

    /// @notice Burn _amount MUSD to reduce trove debt.
    /// Implementations either burn(msg.sender, amount) or burnFrom -> we keep
    /// an MUSD allowance to BorrowerOperations so both variants work.
    function repayMUSD(
        uint256 _amount,
        address _upperHint,
        address _lowerHint
    ) external;

    /// @notice Combined collateral withdrawal + debt change in one tx.
    /// Expects either msg.value > 0 (coll top-up) or _collWithdrawal > 0, not both.
    function adjustTrove(
        uint256 _collWithdrawal,
        uint256 _debtChange,
        bool _isDebtIncrease,
        address _upperHint,
        address _lowerHint
    ) external payable;

    /// @notice Close trove. Requires zero debt; returns all collateral to owner.
    function closeTrove() external;

    /// @notice Refinance the trove's interest rate (MUSD supports market rates).
    function refinance(address _upperHint, address _lowerHint) external;

    /// @notice Claim leftover collateral after redemption/liquidation surplus.
    function claimCollateral() external;

    // --- Views (governable variables) ---
    function minNetDebt() external view returns (uint256);
    function borrowingRate() external view returns (uint256);
}
