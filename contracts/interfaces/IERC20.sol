// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal ERC20 interface (MUSD is a standard ERC20, 18 decimals).
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
