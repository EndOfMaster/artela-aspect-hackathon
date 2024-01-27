//SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../interface/IveAAH.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LPTokenWrapper {

    IveAAH public veAAH;

    uint256 public totalSupply;

    mapping(address => uint256) internal balances;

    function balanceOf(address account) public view returns (uint256) {
        return balances[account];
    }
}
