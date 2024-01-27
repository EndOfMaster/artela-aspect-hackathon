// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../library/SafeRatioMath.sol";
import "../library/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract StakedAAH is OwnableUpgradeable, ReentrancyGuardUpgradeable, ERC20Upgradeable, ERC20Permit {
    using SafeRatioMath for uint256;
    using SafeERC20 for IERC20;

    uint256 internal constant MAX_REWARD_RATE = 4122 * 10 ** 18;
    uint256 internal constant BASE = 10 ** 18;
    IERC20 public AAH;
    address public rewardDistributor;
    uint256 public rewardRate;
    // The block that started to distribute token reward.
    uint256 public startBlock;
    // The settled total distributed reward from the very beginning to current startBlock.
    uint256 public totalDistributedAmount;
    // The sum of the reward executed from RewardVault.
    uint256 public totalExecutedAmount;
    uint256 public blockPerYear;

    event Stake(address spender, address recipient, uint256 underlyingAmount, uint256 tokenAmount);
    event Unstake(address from, address recipient, uint256 underlyingAmount, uint256 tokenAmount);
    event NewRewardRate(uint256 startBlock, uint256 oldRewardRate, uint256 newRewardRate);
    event NewRewardDistributor(address oldVault, address newVault);
    event RewardExecuted(uint256 rewardExecutedAmount);

    /**
     * @notice Only for the implementation contract, as for the proxy pattern,
     *            should call `initialize()` separately.
     */
    constructor(address _rewardDistributor, IERC20 _AAH, uint256 _blockPerYear) {
        initialize(_rewardDistributor, _AAH, _blockPerYear);
    }

    /**
     * @dev Initialize contract to set some configs.
     * @param _rewardDistributor Reward vault contract that stores the reward token.
     * @param _AAH Underlying token to deposit. The default is AAH token.
     */
    function initialize(address _rewardDistributor, IERC20 _AAH, uint256 _blockPerYear) public initializer {
        require(_rewardDistributor != address(0), "sAAH: Invalid reward contract address!");
        require(address(_AAH) != address(0), "sAAH: Invalid AAH contract address!");

        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __ERC20_init("Staked AAH", "sAAH");

        rewardDistributor = _rewardDistributor;
        AAH = _AAH;
        blockPerYear = _blockPerYear;
        startBlock = block.number + 1;
        totalDistributedAmount = 0;
        totalExecutedAmount = 0;

        emit NewRewardDistributor(address(0), _rewardDistributor);
    }

    modifier onlyRewardDistributor() {
        require(rewardDistributor == msg.sender, "sAAH: caller is not the rewardDistributor");
        _;
    }

    /*********************************/
    /******** Security Check *********/
    /*********************************/

    /**
     * @notice Ensure this is a sAAH contract.
     */
    function issAAH() external pure returns (bool) {
        return true;
    }

    /**
     * @dev Calculate current exchange rate between AAH and sAAH.
     *      If total supply of sAAH token is not equal to 0:
     *        1). True => `exchangeRate = total available AAH amount / sAAH total supply`
     *        2). False => `exchangeRate = 1e18`;
     */
    function _calculateExchange() internal view returns (uint256 _exchangeRate) {
        uint256 _totalSupply = totalSupply();
        if (_totalSupply != 0) {
            uint256 _availableAAHAmount = getCurrentUnderlyingAndRewards();
            _exchangeRate = _availableAAHAmount.rdiv(_totalSupply);
        } else {
            _exchangeRate = BASE;
        }
    }

    /**
     * @dev Get current exchange rate between AAH and sAAH.
     */
    function getCurrentExchangeRate() public view returns (uint256 _exchangeRate) {
        _exchangeRate = _calculateExchange();
    }

    /**
     * @dev Set new reward rate.
     */
    function setRewardRate(uint256 _newRawRewardRate) external onlyRewardDistributor {
        require(_newRawRewardRate <= MAX_REWARD_RATE, "setRewardRate: New reward rate too large to set!");
        uint256 _oldRewardRate = rewardRate;
        // This will never revert.
        require(_newRawRewardRate != _oldRewardRate, "setRewardRate: Can not set the same reward rate!");
        rewardRate = _newRawRewardRate;

        // Accrued distributed rewards with the old reward rate.
        if (block.number > startBlock) {
            uint256 _blockDelta = block.number - startBlock;
            uint256 _accruedRewards = _blockDelta * _oldRewardRate;
            totalDistributedAmount = totalDistributedAmount + _accruedRewards;
            // Update block number.
            startBlock = block.number;
        }

        emit NewRewardRate(startBlock, _oldRewardRate, _newRawRewardRate);
    }

    /**
     * @dev Set new reward vault contract.
     */
    function setNewVault(address _newVault) external onlyOwner {
        address _oldVault = rewardDistributor;
        require(_newVault != address(0), "setNewVault: Vault contract can not be zero address!");
        require(_newVault != _oldVault, "setNewVault: Same reward vault contract address!");

        rewardDistributor = _newVault;

        emit NewRewardDistributor(_oldVault, _newVault);
    }

    /**
     * @dev Stake AAH token to get sAAH to participate in governance.
     */
    function stake(address _recipient, uint256 _rawUnderlyingAmount) external nonReentrant returns (uint256 _tokenAmount) {
        require(_recipient != address(0), "stake: Mint to the zero address!");
        require(_rawUnderlyingAmount != 0, "stake: Stake amount can not be zero!");

        uint256 _exchangeRate = _calculateExchange();
        _tokenAmount = _rawUnderlyingAmount.rdiv(_exchangeRate);

        _mint(_recipient, _tokenAmount);
        AAH.safeTransferFrom(msg.sender, address(this), _rawUnderlyingAmount);

        emit Stake(msg.sender, _recipient, _rawUnderlyingAmount, _tokenAmount);
    }

    /**
     * @dev When user withdraws AAH token, if current contract does not have enough AAH token,
     *        should get extra reward token from the reward vault contract. And should record
     *        the AAH amount that transfers from the reward vault.
     */
    function getTokenFromVault(uint256 _toWithdrawAmount) internal {
        uint256 _currentUnderlyingBalance = _getUnderlyingTotalAmount();
        if (_toWithdrawAmount > _currentUnderlyingBalance) {
            uint256 _insufficientAmount = _toWithdrawAmount - _currentUnderlyingBalance;
            AAH.safeTransferFrom(rewardDistributor, address(this), _insufficientAmount);
            totalExecutedAmount = totalExecutedAmount + _insufficientAmount;

            emit RewardExecuted(_insufficientAmount);
        }
    }

    function _approveERC20(address _owner, address _spender, uint256 _amount) internal override {
        _approve(_owner, _spender, _amount);
    }

    /**
     * @dev Destroys `_amount` tokens from `_account`, deducting from the caller's
     * allowance if caller is not the `_account`.
     *
     * See {ERC20-_burn} and {ERC20-allowance}.
     *
     * Requirements:
     *
     * - the caller other than `msg.sender` must have allowance for `accounts`'s tokens of at least
     * `_amount`.
     */
    function _burnFrom(address _from, address _caller, uint256 _amount) internal {
        if (_caller != _from) {
            uint256 _spenderAllowance = allowance(_from, _caller);

            require(_amount <= _spenderAllowance, "_burnFrom: Burn amount exceeds spender allowance!");
            uint256 _newAllowance = _spenderAllowance - _amount;
            _approve(_from, _caller, _newAllowance);
        }

        _burn(_from, _amount);
    }

    /**
     * @dev Unstake exact sAAH to exit governance and get back AAH token.
     */
    function unstake(address _from, uint256 _rawTokenAmount) external nonReentrant returns (uint256 _underlyingAmount) {
        require(_rawTokenAmount != 0, "unstake: Unstake amount can not be zero!");

        uint256 _exchangeRate = _calculateExchange();
        _underlyingAmount = _rawTokenAmount.rmul(_exchangeRate);

        address _caller = msg.sender;

        _burnFrom(_from, _caller, _rawTokenAmount);

        getTokenFromVault(_underlyingAmount);
        AAH.safeTransfer(_caller, _underlyingAmount);

        emit Unstake(_from, _caller, _underlyingAmount, _rawTokenAmount);
    }

    /**
     * @dev Unstake sAAH to exit governance and get back exact AAH token.
     */
    function unstakeUnderlying(address _from, uint256 _underlyingAmount) external nonReentrant {
        require(_underlyingAmount != 0, "unstakeUnderlying: Unstake underlying amount can not be zero!");

        uint256 _exchangeRate = _calculateExchange();
        uint256 _tokenAmount = _underlyingAmount.rdivup(_exchangeRate);

        address _caller = msg.sender;

        _burnFrom(_from, _caller, _tokenAmount);

        getTokenFromVault(_underlyingAmount);
        AAH.safeTransfer(_caller, _underlyingAmount);

        emit Unstake(_from, _caller, _underlyingAmount, _tokenAmount);
    }

    /**
     * @dev Get AAH amount that stores in this contract.
     */
    function _getUnderlyingTotalAmount() internal view returns (uint256) {
        return AAH.balanceOf(address(this));
    }

    /**
     * @dev Get total available AAH amount =
     *    _underlyingToken + totalDistributedAmount + _periodRewards - totalExecutedAmount;
     *        1) `_underlyingToken`, staked by users that stored in the contract directly(including ecosystem profits);
     *        2) `totalDistributedAmount`, the settled total distributed reward from the very beginning to current startBlock;
     *        3) `_periodRewards`, after settlement, all accrued reward token with current rate;
     *        4) `totalExecutedAmount`, the token has transferred from the reward vault.
     */
    function getCurrentUnderlyingAndRewards() public view returns (uint256) {
        uint256 _periodRewards;
        uint256 _underlyingTokenAmount = _getUnderlyingTotalAmount();
        uint256 _currentBlock = block.number;
        if (_currentBlock < startBlock) {
            _periodRewards = 0;
        } else {
            uint256 _blockDelta = _currentBlock - startBlock;
            _periodRewards = _blockDelta * rewardRate;
        }

        return _underlyingTokenAmount + totalDistributedAmount + _periodRewards - totalExecutedAmount;
    }

    function getAnnualInterestRate() external view returns (uint256) {
        if (totalSupply() == 0) return 0;
        return (rewardRate * blockPerYear).rdiv(totalSupply()).rdiv(_calculateExchange());
    }
}
