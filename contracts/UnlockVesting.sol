// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { ERC20BurnableUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract UnlockVesting is Ownable {
    // Token contracts
    ERC20BurnableUpgradeable public inputToken;
    IERC20 public outputToken;

    // Vesting parameters
    uint256 public startTime;
    uint256 public vestingDays;

    // Fund for output token
    address public unlockFund;

    struct VestingInfo {
        uint256 totalOutput;
        uint256 claimedAmount;
    }

    // Mapping to track vesting info per user
    mapping(address => VestingInfo) public vestingData;

    event TokensDeposited(address indexed user, uint256 inputAmount);
    event TokensClaimed(address indexed user, uint256 claimedAmount);

    constructor(
        address _initialOwner,
        address _inputToken,
        address _outputToken,
        uint256 _startTime,
        uint256 _vestingDays,
        address _unlockFund
    ) Ownable(_initialOwner) {
        require(_vestingDays > 0, "Vesting days must be greater than 0");

        inputToken = ERC20BurnableUpgradeable(_inputToken);
        outputToken = IERC20(_outputToken);
        startTime = _startTime;
        vestingDays = _vestingDays;
        unlockFund = _unlockFund;
    }

    function setUnlockFund(address _unlockFund) external onlyOwner {
        unlockFund = _unlockFund;
    }

    function deposit(uint256 inputAmount) external {
        require(inputAmount > 0, "Input amount must be greater than 0");

        // Burn the input tokens
        inputToken.burnFrom(msg.sender, inputAmount);

        // Record the vesting information
        vestingData[msg.sender].totalOutput += inputAmount;

        emit TokensDeposited(msg.sender, inputAmount);
    }

    function claim() external {
        VestingInfo storage info = vestingData[msg.sender];
        require(info.totalOutput > 0, "No tokens to claim");
        require(block.timestamp >= startTime, "Vesting has not started yet");

        uint256 elapsedTime = block.timestamp - startTime;
        uint256 totalVestingTime = vestingDays * 1 days;
        uint256 claimableAmount;

        if (elapsedTime >= totalVestingTime) {
            // All tokens are claimable
            claimableAmount = info.totalOutput - info.claimedAmount;
        } else {
            // Linear vesting calculation
            uint256 vestedAmount = (info.totalOutput * elapsedTime) / totalVestingTime;
            claimableAmount = vestedAmount - info.claimedAmount;
        }

        require(claimableAmount > 0, "No claimable tokens available");

        // Update claimed amount
        info.claimedAmount += claimableAmount;

        // Transfer the output tokens
        require(outputToken.transferFrom(unlockFund, msg.sender, claimableAmount), "Token transfer failed");

        emit TokensClaimed(msg.sender, claimableAmount);
    }

    // Utility function to check claimable amount
    function getClaimableAmount(address user) external view returns (uint256) {
        VestingInfo memory info = vestingData[user];
        if (block.timestamp < startTime || info.totalOutput == 0) {
            return 0;
        }

        uint256 elapsedTime = block.timestamp - startTime;
        uint256 totalVestingTime = vestingDays * 1 days;
        uint256 vestedAmount;

        if (elapsedTime >= totalVestingTime) {
            vestedAmount = info.totalOutput;
        } else {
            vestedAmount = (info.totalOutput * elapsedTime) / totalVestingTime;
        }

        return vestedAmount - info.claimedAmount;
    }
}