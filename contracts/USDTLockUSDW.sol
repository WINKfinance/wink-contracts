// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { USDW } from "./USDW.sol";
import { LockUSDW } from "./LockUSDW.sol";
import { SUsdw } from "./SUsdw.sol";
import { USDWBuyAndSell } from "./USDWBuyAndSell.sol";

contract USDTLockUSDW {

    USDW public usdw;
    ERC20 public usdt;
    LockUSDW public lockusdw;
    SUsdw public susdw;
    USDWBuyAndSell public usdwbas;

    constructor(address _usdw, address _susdw, address _usdt, address _lockusdw, address _usdwbas) {
        usdw = USDW(_usdw);
        susdw = SUsdw(_susdw);
        usdt = ERC20(_usdt);
        lockusdw = LockUSDW(_lockusdw);
        usdwbas = USDWBuyAndSell(_usdwbas);
    }

    function swapToUSDW(uint256 _amount) internal returns(uint256 usdwAmount) {
        usdt.transferFrom(msg.sender, address(this), _amount);
        usdt.approve(address(usdwbas), _amount);
        usdwAmount = usdwbas.buyUSDW(_amount);
    }

    function lockUSDW(uint256 _amount, LockUSDW.LockPeriod _lockPeriod, bool _disableEarlyUnlock) external {
        uint256 usdwAmount = swapToUSDW(_amount);
        usdw.approve(address(lockusdw), usdwAmount);
        lockusdw.safeMint(usdwAmount, _lockPeriod, _disableEarlyUnlock, msg.sender);
    }

    function savingsUSDW(uint256 _amount) external {
        uint256 usdwAmount = swapToUSDW(_amount);
        usdw.approve(address(susdw), usdwAmount);
        susdw.deposit(usdwAmount, msg.sender);
    }
}