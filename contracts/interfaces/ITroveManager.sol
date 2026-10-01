// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Subset of MUSD's ITroveManager (verified against mezo-org/musd).
interface ITroveManager {
    enum Status {
        nonExistent,
        active,
        closedByOwner,
        closedByLiquidation,
        closedByRedemption
    }

    /// @notice Full trove accounting in one call.
    function getEntireDebtAndColl(
        address _borrower
    )
        external
        view
        returns (
            uint256 coll,
            uint256 principal,
            uint256 interest,
            uint256 pendingCollateral,
            uint256 pendingPrincipal,
            uint256 pendingInterest
        );

    function getTroveDebt(address _borrower) external view returns (uint256);
    function getTroveColl(address _borrower) external view returns (uint256);
    function getTroveStatus(address _borrower) external view returns (Status);
    function getNominalICR(address _borrower) external view returns (uint256);
    function getCurrentICR(
        address _borrower,
        uint256 _price
    ) external view returns (uint256);
    function getTCR(uint256 _price) external view returns (uint256);
    function checkRecoveryMode(uint256 _price) external view returns (bool);
}
