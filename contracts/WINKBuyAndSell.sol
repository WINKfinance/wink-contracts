// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IUniswapV3Factory } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { OracleLibrary } from "./OracleLibrary.sol";
import { WINK } from "./WINK.sol";
import { USDW } from "./USDW.sol";

contract WINKBuyAndSell is Ownable {
    using SafeERC20 for ERC20;

    USDW public usdw;
    WINK public wink;
    ERC20 public usdt;

    int32 public secondsAgo;

    address public reserve;
    address public massivePurchaseReserve;

    address public poolWinkUsdw;

    uint32 public fee;              // [0%, 100%] = [0, 100000]
    uint256 public base = 100000;   // 100% = 100000

    event WINKSold(address indexed seller, uint256 amount, uint256 amountOut, address token);
    event WINKPurchased(address indexed buyer, uint256 amount, uint256 amountOut, address token);
    error TransferFailed();
    error AmountMustBeGreaterThanZero();
    error InsufficientReserveBalance(address token);
    error InvalidToken(address token);

    constructor(
        address _initialOwner,
        address _poolWinkUsdw,
        WINK _wink,
        USDW _usdw,
        ERC20 _usdt,
        int32 _secondsAgo,
        uint32 _fee,
        address _reserve,
        address _massivePurchaseReserve
    ) Ownable(_initialOwner) {
        usdw = _usdw;
        wink = _wink;
        usdt = _usdt;

        secondsAgo = _secondsAgo;

        fee = _fee;
        
        reserve = _reserve;
        massivePurchaseReserve = _massivePurchaseReserve;


        poolWinkUsdw = _poolWinkUsdw;
    }

    function setFee(uint32 _fee) external onlyOwner {
        fee = _fee;
    }

    function setSecondsAgo(int32 _secondsAgo) external onlyOwner {
        secondsAgo = _secondsAgo;
    }

    function setReserve(address _reserve) external onlyOwner {
        reserve = _reserve;
    }

    function setMassivePurchaseReserve(address _massivePurchaseReserve) external onlyOwner {
        massivePurchaseReserve = _massivePurchaseReserve;
    }

    function setPoolWinkUsdw(address _poolWinkUsdw) external onlyOwner {
        poolWinkUsdw = _poolWinkUsdw;
    }




    function estimateAmountOut(
        address tokenIn,
        address tokenOut,
        uint128 amountIn
    ) public view returns (uint amountOut) {

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = uint32(secondsAgo);
        secondsAgos[1] = 0;

        // int56 since tick * time = int24 * uint32
        // 56 = 24 + 32
        (int56[] memory tickCumulatives, ) = IUniswapV3Pool(poolWinkUsdw).observe(
            secondsAgos
        );

        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];

        // int56 / uint32 = int24
        int24 tick = int24(tickCumulativesDelta / secondsAgo);
        // Always round to negative infinity
        if (
            tickCumulativesDelta < 0 && (tickCumulativesDelta % secondsAgo != 0)
        ) {
            tick--;
        }

        amountOut = OracleLibrary.getQuoteAtTick(
            tick,
            amountIn,
            tokenIn,
            tokenOut
        );
    }

    function sellWINK(uint256 amountIn, address tokenOut) external returns (uint256 amountOut) {
        if (amountIn <= 0)
            revert AmountMustBeGreaterThanZero();

        if (tokenOut != address(usdt) && tokenOut != address(usdw)) {
            revert InvalidToken(tokenOut);
        }

        amountOut = estimateAmountOut(address(wink), address(usdw), uint128(amountIn));
        amountOut = amountOut * (base - fee) / base;

        if (tokenOut == address(usdt)) {
            amountOut = amountOut / (10 ** (usdw.decimals() - usdt.decimals()));

            if (usdt.balanceOf(reserve) < amountOut)
                revert InsufficientReserveBalance(tokenOut);
        }

        // takes the WINK from the user
        wink.transferFrom(msg.sender, reserve, amountIn);

        // gives the amountOut to the user:
        //  if token is USDT, transfer USDT from the reserve to user
        //  if token is USDW, mint USDW to the user
        if(tokenOut == address(usdt)) {
            usdt.safeTransferFrom(reserve, msg.sender, amountOut);
        } else if(tokenOut == address(usdw)) {
            usdw.mint(msg.sender, amountOut);
        }

        emit WINKSold(msg.sender, amountIn, amountOut, tokenOut);
    }

    function buyWINK(uint256 amountIn, address tokenIn) external returns (uint256 amountOut) {
        if (amountIn <= 0)
            revert AmountMustBeGreaterThanZero();

        if (tokenIn != address(usdt) && tokenIn != address(usdw)) {
            revert InvalidToken(tokenIn);
        }

        uint256 usdwAmount = amountIn * (
            tokenIn == address(usdt)
            ? (10 ** (usdw.decimals() - usdt.decimals()))
            : 1
        );

        amountOut = estimateAmountOut(address(usdw), address(wink), uint128(usdwAmount));
        amountOut = amountOut * (base - fee) / base;

        if (wink.balanceOf(reserve) < amountOut && wink.balanceOf(massivePurchaseReserve) < amountOut)
            revert InsufficientReserveBalance(tokenIn);

        // takes the amount from the user:
        //  if tokenIn is USDT, transfer USDT from the user to the reserve
        //  if tokenIn is USDW, transfer USDW from the user to this contract then burn them
        if(tokenIn == address(usdw)) {
            usdw.transferFrom(msg.sender, address(this), amountIn);
            usdw.burn(amountIn);
        } else if(tokenIn == address(usdt)) {
            usdt.safeTransferFrom(msg.sender, reserve, amountIn);
        }

        // gives amountOut WINK to the user
        if(wink.balanceOf(reserve) >= amountOut) {
            wink.transferFrom(reserve, msg.sender, amountOut);
        } else {
            wink.transferFrom(massivePurchaseReserve, msg.sender, amountOut);
        }

        emit WINKPurchased(msg.sender, amountIn, amountOut, tokenIn);
    }
}