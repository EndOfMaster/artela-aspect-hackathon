# AAH Vote Escrow Token Boost Aspect
## Use Case Summary
The AAH protocol enables users to earn rewards through staking in either a flexible (sAAH) or fixed-term (veAAH) manner.

- sAAH: Flexible staking with no lock-in period, allowing for free transferability and staking rewards, but excludes voting rights.
- veAAH: Achieved through staking sAAH with varying lock-in durations, where the length of the term determines both voting weight and interest rate, but these tokens are non-transferable.

Due to the inability of smart contracts to execute timed operations, a settling period is required when fixed-term stakes expire to cease distributing rewards to users. However, in Solidity, executing loops consumes significant gas and excessive iterations can exceed limits. Hence, performing this in the Aspect not only speeds up the process but also reduces costs. Therefore, a part of the Curve boost function contract rewritten in Solidity has been re-implemented in Aspect for efficiency.
## Team Members and Roles
Team Member 1: [EndOfMaster - Core Developer]

## Problem Addressed
This addresses the issue of high gas consumption and the limitations on the number of iterations when executing loops in Solidity.

## Project Design

### AAH Vote Escrow Token Boost Aspect Overview

#### 1. Deposit AAH into the standard Stake protocol to earn sAAH
- Earn rewards based on the reward rate.
- Tradable tokens.
- No voting rights.

#### 2. Use sAAH for fixed-term staking to earn veAAH
- Earn rewards from sAAH along with additional benefits from fixed-term staking.
- Time-weighted voting rights.
- Non-tradable.

#### 3. Introduction of boost node settlement to address the inability to perform timed operations for extending lock-in periods
Calculations for RewardPerTokenSettled at each time node, which previously required user intervention, are now executed within the Aspect join point.

All parameters related to reward settlement have been shifted from Solidity to Aspect execution.

## Value to the Artela Ecosystem
This provides a new implementation method for complex DeFi functionalities that are challenging or risky to implement in the original Solidity, aiding in the transition of DeFi to Aspect for enhanced total value locked (TVL).
