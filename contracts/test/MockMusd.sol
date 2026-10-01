// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Testnet-free MUSD stand-in for local tests. Permissionless mint
/// (local chain only) and a burnFrom honoring allowance — mirroring the two
/// plausible MUSD repayment pull patterns.
contract MockMusd is ERC20 {
    constructor() ERC20("Mock MUSD", "MUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function burnFrom(address account, uint256 amount) external {
        uint256 allowed = allowance(account, msg.sender);
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "insufficient allowance");
            _approve(account, msg.sender, allowed - amount);
        }
        _burn(account, amount);
    }
}
