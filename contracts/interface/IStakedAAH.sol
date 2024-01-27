// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IStakedAAH is IERC20 {
    function stake(address _recipient, uint256 _rawUnderlyingAmount)
        external
        returns (uint256 _tokenAmount);

    function unstake(address _recipient, uint256 _rawTokenAmount)
        external
        returns (uint256 _tokenAmount);

    function getCurrentExchangeRate()
        external
        view
        returns (uint256 _exchangeRate);

    function AAH() external view returns (address);
}
