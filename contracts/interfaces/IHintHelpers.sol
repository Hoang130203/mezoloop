// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Subset of MUSD's HintHelpers (verified against mezo-org/musd).
/// Troves live in a sorted linked list; every mutating BorrowerOperations
/// call needs (upperHint, lowerHint) neighbor addresses. The canonical
/// Liquity pattern is to pass getApproxHint(...) for BOTH hints and let
/// SortedTroves find the exact insertion position.
interface IHintHelpers {
    function getApproxHint(
        uint256 _CR,
        uint256 _numTrials,
        uint256 _inputRandomSeed
    )
        external
        view
        returns (address hintAddress, uint256 diff, uint256 latestRandomSeed);

    function computeNominalCR(
        uint256 _coll,
        uint256 _debt
    ) external pure returns (uint256);

    function computeCR(
        uint256 _coll,
        uint256 _debt,
        uint256 _price
    ) external pure returns (uint256);
}
