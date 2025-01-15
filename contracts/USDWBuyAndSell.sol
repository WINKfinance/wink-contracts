// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { USDW } from "./USDW.sol";

contract USDWBuyAndSell is Ownable {
    using SafeERC20 for ERC20;

    USDW public usdw;
    ERC20 public usdt;
    address public reserve;

    event USDWSold(address indexed seller, uint256 amount);
    event USDWPurchased(address indexed buyer, uint256 amount);
    error TransferFailed();
    error AmountMustBeGreaterThanZero();
    error InsufficientReserveBalance();

    constructor(address _initialOwner, USDW _usdw, address _reserve,  ERC20 _usdt) Ownable(_initialOwner) {
        usdw = _usdw;
        reserve = _reserve;
        usdt = _usdt;
    }

    function setReserve(address _reserve) external onlyOwner {
        reserve = _reserve;
    }

    function sellUSDW(uint256 usdwAmount) external returns (uint256 usdtAmount) {
        if (usdwAmount <= 0)
            revert AmountMustBeGreaterThanZero();

        usdtAmount = usdwAmount / (10 ** (usdw.decimals() - usdt.decimals()));

        if (usdt.balanceOf(reserve) < usdtAmount)
            revert InsufficientReserveBalance();


        usdw.transferFrom(msg.sender, address(this), usdwAmount);
        usdw.burn(usdwAmount);
        usdt.safeTransferFrom(reserve, msg.sender, usdtAmount);
q
        emit USDWSold(msg.sender, usdwAmount);
    }

    function buyUSDW(uint256 usdtAmount) external returns (uint256 usdwAmount) {
        if (usdtAmount <= 0)
            revert AmountMustBeGreaterThanZero();

        usdwAmount = usdtAmount * (10 ** (usdw.decimals() - usdt.decimals()));

        usdt.safeTransferFrom(msg.sender, reserve, usdtAmount);
        usdw.mint(msg.sender, usdwAmount);

        emit USDWPurchased(msg.sender, usdwAmount);
    }
}