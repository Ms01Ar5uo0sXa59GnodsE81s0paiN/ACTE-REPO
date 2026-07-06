// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../interface/IERC20BurnMint.sol";

contract MockERC20BurnMint is ERC20, IERC20BurnMint {
    uint8 private immutable decimals_;

    constructor(string memory name_, string memory symbol_, uint8 decimalsValue_) ERC20(name_, symbol_) {
        decimals_ = decimalsValue_;
    }

    function decimals() public view override returns (uint8) {
        return decimals_;
    }

    function mint(address account, uint256 amount) external override {
        _mint(account, amount);
    }

    function burnFrom(address account, uint256 amount) external override {
        _burn(account, amount);
    }
}
