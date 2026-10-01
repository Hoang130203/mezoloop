// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Subset of MUSD's SortedTroves.
interface ISortedTroves {
    function findInsertPosition(
        uint256 _NICR,
        address _prevId,
        address _nextId
    ) external view returns (address prevId, address nextId);

    function getSize() external view returns (uint256);
}
