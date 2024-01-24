// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @dev Wrappers over Solidity's arithmetic operations with added overflow
 * checks.
 *
 * Arithmetic operations in Solidity wrap on overflow. This can easily result
 * in bugs, because programmers usually assume that an overflow raises an
 * error, which is the standard behavior in high level programming languages.
 * `SafeMath` restores this intuition by reverting the transaction when an
 * operation overflows.
 *
 * Using this library instead of the unchecked operations eliminates an entire
 * class of bugs, so it's recommended to use it always.
 */
library SafeRatioMath {
    uint256 private constant BASE = 10 ** 18;

    function rdiv(uint256 a, uint256 b) internal pure returns (uint256 c) {
        c = (a * BASE) / b;
    }

    function rmul(uint256 a, uint256 b) internal pure returns (uint256 c) {
        c = (a * b) / BASE;
    }

    function rdivup(uint256 a, uint256 b) internal pure returns (uint256 c) {
        c = ((a * BASE) + (b - 1)) / b;
    }
}
