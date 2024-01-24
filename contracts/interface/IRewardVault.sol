// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IRewardVault {
    function setMiner(address _miner) external;

    function transferReward(address _recipient, uint256 _rewardAmount) external;
}
