// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { USDW } from "./USDW.sol";
import { LockUSDW } from "./LockUSDW.sol";
import { SUsdw } from "./SUsdw.sol";

contract SUSDWLockUSDW {

    USDW public usdw;
    LockUSDW public lockusdw;
    SUsdw public susdw;

    constructor(address _usdw, address _susdw, address _lockusdw) {
        usdw = USDW(_usdw);
        susdw = SUsdw(_susdw);
        lockusdw = LockUSDW(_lockusdw);
    }

    function lockUSDWwithAssets(uint256 _amount, LockUSDW.LockPeriod _lockPeriod, bool _disableEarlyUnlock) external {
        susdw.withdraw(_amount, address(this), msg.sender);
        usdw.approve(address(lockusdw), _amount);
        lockusdw.safeMint(_amount, _lockPeriod, _disableEarlyUnlock, msg.sender);
    }

    function lockUSDWwithShares(uint256 _shares, LockUSDW.LockPeriod _lockPeriod, bool _disableEarlyUnlock) external {
        uint256 _amount = susdw.redeem(_shares, address(this), msg.sender);
        usdw.approve(address(lockusdw), _amount);
        lockusdw.safeMint(_amount, _lockPeriod, _disableEarlyUnlock, msg.sender);
    }
}