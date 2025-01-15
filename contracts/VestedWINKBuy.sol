// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { USDW } from "./USDW.sol";
import { VestedUSDW } from "./VestedUSDW.sol";
import { VestedWINK } from "./VestedWINK.sol";

contract VestedWINKBuy is Ownable, ReentrancyGuard {

    ERC20 public usdt;
    USDW public usdw;
    VestedUSDW public vusdw;
    VestedWINK public vwink;
    address public reserve;

    uint256 public conversionRate;
    uint256 public base = 10**27;

    bool public enabled;

    event Swap(address indexed seller, uint256 amount);

    error AmountMustBeGreaterThanZero();
    error InvalidToken(address token);
    error ContractDisabled();

    constructor(address _initialOwner, ERC20 _usdt, USDW _usdw, VestedUSDW _vusdw, VestedWINK _vwink, address _reserve, uint256 _conversionRate) Ownable(_initialOwner) {
        usdt = _usdt;
        usdw = _usdw;
        vusdw = _vusdw;
        vwink = _vwink;
        reserve = _reserve;
        conversionRate = _conversionRate;
        enabled = true;
    }

    function setConversionRate(uint256 _conversionRate) external onlyOwner {
        conversionRate = _conversionRate;
    }

    function setReserve(address _reserve) external onlyOwner {
        reserve = _reserve;
    }

    function disable() external onlyOwner {
        enabled = false;
    }

    function swap(uint256 amount, address token) external nonReentrant {
        if (!enabled)
            revert ContractDisabled();

        if (amount <= 0)
            revert AmountMustBeGreaterThanZero();

        if (token != address(vusdw) && token != address(usdw) && token != address(usdt))
            revert InvalidToken(token);

        uint256 toConvertAmount;

        if (token == address(usdt)) {
            toConvertAmount = amount * (10 ** (usdw.decimals() - usdt.decimals()));
            usdt.transferFrom(msg.sender, reserve, amount);
        } else {
            toConvertAmount = amount;
            ERC20Burnable(token).transferFrom(msg.sender, address(this), amount);
            ERC20Burnable(token).burn(amount);
        }

        vwink.mint(msg.sender, toConvertAmount * conversionRate / base);

        emit Swap(msg.sender, amount);
    }
}