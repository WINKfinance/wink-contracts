// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract SeedWink is ERC20 {
    uint8 private _decimals = 10;
    constructor (address _icoAddress) ERC20("SeedWink", "SWINK") {
        _mint(_icoAddress, 10000000 * (10 ** uint256(decimals())));
    }

    function decimals() public override view returns (uint8) {
        return _decimals;
    }
}
