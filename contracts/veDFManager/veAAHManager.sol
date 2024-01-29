//SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./LPTokenWrapper.sol";
import "../interface/IStakedAAH.sol";
import "../library/SafeRatioMath.sol";
import "../interface/IRewardDistributor.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/**
 * @notice Minter of veAAH
 * @dev The contract does not store parameters such as the number of SAAHs
 */
contract veAAHCore is OwnableUpgradeable, ReentrancyGuardUpgradeable, LPTokenWrapper {
    using SafeRatioMath for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IStakedAAH;

    ///@dev Min lock step (seconds of a week).
    uint256 internal constant MIN_STEP = 1 weeks;

    ///@dev Token of reward
    IERC20 public rewardToken;
    IStakedAAH public sAAH;
    address public rewardDistributor;

    uint256 public rewardRate = 0;

    ///@dev The timestamp that started to distribute token reward.
    uint256 public startTime;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    uint256 public lastRateUpdateTime;
    uint256 public rewardDistributedStored;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    ///@dev Due time of settlement to node
    uint256 public lastSettledTime;
    ///@dev Total overdue balance settled
    uint256 public accSettledBalance;

    struct SettleLocalVars {
        uint256 lastUpdateTime;
        uint256 lastSettledTime;
        uint256 accSettledBalance;
        uint256 rewardPerToken;
        uint256 rewardRate;
        uint256 totalSupply;
    }

    struct Node {
        uint256 rewardPerTokenSettled;
        uint256 balance;
    }

    ///@dev due time timestamp => data
    mapping(uint256 => Node) internal nodes;

    event RewardRateUpdated(uint256 oldRewardRate, uint256 newRewardRate);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);

    ///@dev Emitted when `create` is called.
    ///@param recipient Address of receiving veAAH
    ///@param sAAHLocked Number of locked sAAH
    ///@param duration Lock duration
    ///@param veAAHReceived Number of veAAH received
    event Create(address recipient, uint256 sAAHLocked, uint256 duration, uint256 veAAHReceived);

    ///@dev Emitted when `refill` is called.
    ///@param recipient Address of receiving veAAH
    ///@param sAAHRefilled Increased number of sAAH
    ///@param veAAHReceived Number of veAAH received
    event Refill(address recipient, uint256 sAAHRefilled, uint256 veAAHReceived);

    ///@dev Emitted when `extend` is called.
    ///@param recipient Address of receiving veAAH
    ///@param preDueTime Old expiration time
    ///@param newDueTime New expiration time
    ///@param duration Lock duration
    ///@param veAAHReceived Number of veAAH received
    event Extend(address recipient, uint256 preDueTime, uint256 newDueTime, uint256 duration, uint256 veAAHReceived);

    event ProExtend(address recipient, uint256 preDueTime, uint256 newDueTime, uint256 duration, uint256 veAAHOldBalance, uint256 veAAHBalance);

    ///@dev Emitted when `refresh` is called.
    ///@param recipient Address of receiving veAAH
    ///@param presAAHLocked Old number of locked sAAH
    ///@param newsAAHLocked New number of locked sAAH
    ///@param duration Lock duration
    ///@param preveAAHBalance Original veAAH balance
    ///@param newveAAHBalance New of veAAH balance
    event Refresh(address recipient, uint256 presAAHLocked, uint256 newsAAHLocked, uint256 duration, uint256 preveAAHBalance, uint256 newveAAHBalance);

    ///@dev Emitted when `withdraw` is called.
    ///@param recipient Address of receiving veAAH
    ///@param veAAHBurned Amount of veAAH burned
    ///@param sAAHRefunded Number of sAAH returned
    event Withdraw(address recipient, uint256 veAAHBurned, uint256 sAAHRefunded);

    function initialize(IveAAH _veAAH, IStakedAAH _sAAH, IERC20 _rewardToken, uint256 _startTime, address _rewardDistributor) public virtual initializer {
        require(_startTime > block.timestamp, "veAAHManager: Start time must be greater than the block timestamp");

        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();

        veAAH = _veAAH;
        sAAH = _sAAH;
        rewardToken = _rewardToken;
        startTime = _startTime;
        lastSettledTime = _startTime;
        lastUpdateTime = _startTime;
        rewardDistributor = _rewardDistributor;

        sAAH.forceApprove(address(veAAH), type(uint256).max);
    }

    ///@notice Update distribution of historical nodes and users
    ///@dev Basically all operations will be called
    modifier updateReward(address _account) {
        if (startTime <= block.timestamp) {
            // _settleNode(block.timestamp);
            if (_account != address(0)) {
                // _updateUserReward(_account);
            }
        }
        _;
    }

    modifier updateRewardDistributed() {
        rewardDistributedStored = rewardDistributed();
        lastRateUpdateTime = block.timestamp;
        _;
    }

    modifier sanityCheck(uint256 _amount) {
        require(_amount != 0, "veAAHManager: Stake amount can not be zero!");
        _;
    }

    ///@dev Check duetime rules
    modifier isDueTimeValid(uint256 _dueTime) {
        require(_dueTime > block.timestamp, "veAAHManager: Due time must be greater than the current time");
        require((_dueTime - startTime) % MIN_STEP == 0, "veAAHManager: The minimum step size must be `MIN_STEP`");
        _;
    }

    modifier onlyRewardDistributor() {
        require(rewardDistributor == msg.sender, "veAAHManager: caller is not the rewardDistributor");
        _;
    }

    /*********************************/
    /******** Owner functions ********/
    /*********************************/

    ///@notice Set a new reward rate
    function setRewardRate(uint256 _rewardRate) external onlyRewardDistributor updateRewardDistributed updateReward(address(0)) {
        uint256 _oldRewardRate = rewardRate;
        rewardRate = _rewardRate;

        emit RewardRateUpdated(_oldRewardRate, _rewardRate);
    }

    // This function allows governance to take unsupported tokens out of the
    // contract, since this one exists longer than the other pools.
    // This is in an effort to make someone whole, should they seriously
    // mess up. There is no guarantee governance will vote to return these.
    // It also allows for removal of airdropped tokens.
    function rescueTokens(IERC20 _token, uint256 _amount, address _to) external onlyRewardDistributor {
        _token.safeTransfer(_to, _amount);
    }

    /*********************************/
    /******* Users functions *********/
    /*********************************/

    /**
     * @notice Lock StakedAAH and harvest veAAH.
     * @dev Create lock-up information and mint veAAH on lock-up amount and duration.
     * @param _amount StakedAAH token amount.
     * @param _dueTime Due time timestamp, in seconds.
     */
    function create(uint256 _amount, uint256 _dueTime) public sanityCheck(_amount) isDueTimeValid(_dueTime) updateReward(msg.sender) {
        uint256 _duration = _dueTime - block.timestamp;
        sAAH.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 _veAAHAmount = veAAH.create(msg.sender, _amount, _duration);

        string memory _context = string(abi.encodePacked(_dueTime, ",", _veAAHAmount));
        (bool success, ) = address(0x66).call(abi.encode(string("context"), _context));
        require(success, "veAAHManager: send aspect contect error");

        emit Create(msg.sender, _amount, _duration, _veAAHAmount);
    }

    //TODO 到这了
    /**
     * @notice Increased locked staked sAAH and harvest veAAH.
     * @dev According to the expiration time in the lock information, the minted veAAH.
     * @param _amount StakedAAH token amount.
     */
    function refill(uint256 _amount) external sanityCheck(_amount) updateReward(msg.sender) {
        sAAH.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 _veAAHAmount = veAAH.refill(msg.sender, _amount);

        (uint32 _dueTime, , ) = veAAH.getLocker(msg.sender);

        totalSupply = totalSupply + _veAAHAmount;
        balances[msg.sender] = balances[msg.sender] + _veAAHAmount;
        nodes[_dueTime].balance = nodes[_dueTime].balance + _veAAHAmount;

        emit Refill(msg.sender, _amount, _veAAHAmount);
    }

    /**
     * @notice Increase the lock duration and harvest veAAH.
     * @dev According to the amount of locked StakedAAH and expansion time, the minted veAAH.
     * @param _dueTime new Due time timestamp, in seconds.
     */
    function extend(uint256 _dueTime) external isDueTimeValid(_dueTime) updateReward(msg.sender) {
        (uint32 _oldDueTime, , ) = veAAH.getLocker(msg.sender);
        uint256 _oldBalance = balances[msg.sender];

        //Subtract the user balance of the original node
        nodes[_oldDueTime].balance = nodes[_oldDueTime].balance - _oldBalance;

        uint256 _duration = _dueTime - _oldDueTime;
        uint256 _veAAHAmount = veAAH.extend(msg.sender, _duration);

        totalSupply = totalSupply + _veAAHAmount;
        balances[msg.sender] = balances[msg.sender] + _veAAHAmount;

        //Add the user balance of the original node to the new node
        nodes[_dueTime].balance = nodes[_dueTime].balance + _veAAHAmount + _oldBalance;

        emit Extend(msg.sender, _oldDueTime, _dueTime, _duration, _veAAHAmount);
    }

    /**
     * @notice Increase the lock duration and harvest veAAH, Let the total lock up time exceed 4 years
     * @dev According to the amount of locked StakedAAH and expansion time, the minted veAAH.
     */
    function proExtend(uint256 _amount) external updateReward(msg.sender) {
        if (_amount > 0) sAAH.safeTransferFrom(msg.sender, address(this), _amount);

        (uint32 _oldDueTime, , ) = veAAH.getLocker(msg.sender);
        uint256 _oldBalance = balances[msg.sender];

        //Subtract the user balance of the original node
        nodes[_oldDueTime].balance = nodes[_oldDueTime].balance - _oldBalance;

        uint256 _duration = veAAH.maxDuration() - ((block.timestamp - startTime) % MIN_STEP);
        uint256 _dueTime = block.timestamp + _duration;
        uint256 _veAAHAmount = veAAH.proExtend(msg.sender, _amount, _duration);

        totalSupply = totalSupply + _veAAHAmount - _oldBalance;
        balances[msg.sender] = _veAAHAmount;

        //Add the user balance of the original node to the new node
        nodes[_dueTime].balance = nodes[_dueTime].balance + _veAAHAmount;

        emit ProExtend(msg.sender, _oldDueTime, _dueTime, _duration, _oldBalance, _veAAHAmount);
    }

    /**
     * @notice Lock Staked sAAH and and update veAAH balance.
     * @dev Update the lockup information and veAAH balance, return the excess sAAH to the user or receive transfer increased amount.
     * @param _amount StakedAAH token new amount.
     * @param _dueTime Due time timestamp, in seconds.
     */
    function refresh(uint256 _amount, uint256 _dueTime) external sanityCheck(_amount) isDueTimeValid(_dueTime) nonReentrant updateReward(msg.sender) {
        (, , uint256 _lockedSAAH) = veAAH.getLocker(msg.sender);
        //If the new amount is greater than the original lock volume, the difference needs to be supplemented
        if (_amount > _lockedSAAH) {
            sAAH.safeTransferFrom(msg.sender, address(this), _amount - _lockedSAAH);
        }

        uint256 _duration = _dueTime - block.timestamp;
        uint256 _oldVEAAHAmount = balances[msg.sender];
        uint256 _newVEAAHAmount = veAAH.refresh2(msg.sender, _amount, _duration);

        balances[msg.sender] = _newVEAAHAmount;
        userRewardPerTokenPaid[msg.sender] = rewardPerTokenStored;

        totalSupply = totalSupply + _newVEAAHAmount - _oldVEAAHAmount;
        nodes[_dueTime].balance = nodes[_dueTime].balance + _newVEAAHAmount;
        accSettledBalance = accSettledBalance - _oldVEAAHAmount;

        emit Refresh(msg.sender, _lockedSAAH, _amount, _duration, _oldVEAAHAmount, _newVEAAHAmount);
    }

    /**
     * @notice Unlock Staked sAAH and burn veAAH.
     * @dev Burn veAAH and clear lock information.
     */
    function _withdraw2() internal {
        uint256 _burnVEAAH = veAAH.withdraw2(msg.sender);
        uint256 _oldBalance = balances[msg.sender];

        totalSupply = totalSupply - _oldBalance;
        balances[msg.sender] = balances[msg.sender] - _oldBalance;

        //Since totalsupply is reduced and the operation must be performed after the lock expires,
        //accsettledbalance should be reduced at the same time
        accSettledBalance = accSettledBalance - _oldBalance;

        emit Withdraw(msg.sender, _burnVEAAH, _oldBalance);
    }

    ///@notice Extract reward
    function getReward() public virtual updateReward(msg.sender) {
        uint256 _reward = rewards[msg.sender];
        if (_reward > 0) {
            rewards[msg.sender] = 0;
            rewardToken.safeTransferFrom(rewardDistributor, msg.sender, _reward);
            emit RewardPaid(msg.sender, _reward);
        }
    }

    function exit() external {
        getReward();
        _withdraw2();
    }

    /*********************************/
    /******** Query function *********/
    /*********************************/

    function rewardPerToken() external updateReward(address(0)) returns (uint256) {
        return rewardPerTokenStored;
    }

    function rewardDistributed() public view returns (uint256) {
        // Have not started yet
        if (block.timestamp < startTime) {
            return rewardDistributedStored;
        }

        return rewardDistributedStored + ((block.timestamp - Math.max(startTime, lastRateUpdateTime)) * rewardRate);
    }

    function earned(address _account) public updateReward(_account) returns (uint256) {
        return rewards[_account];
    }

    /**
     * @dev Used to query the information of the locker.
     * @param _lockerAddress veAAH locker address.
     * @return Information of the locker.
     *         due time;
     *         Lock up duration;
     *         Lock up sAAH amount;
     */
    function getLocker(address _lockerAddress) external view returns (uint32, uint32, uint96) {
        return veAAH.getLocker(_lockerAddress);
    }

    /**
     * @dev Used to query the information of the locker.
     * @param _lockerAddress veAAH locker address.
     * @param _startTime Start time.
     * @param _dueTime Due time.
     * @param _duration Lock up duration.
     * @param _sAAHAmount Lock up sAAH amount.
     * @param _veAAHAmount veAAH amount.
     * @param _rewardAmount Reward amount.
     * @param _lockedStatus Locked status, 0: no lockup; 1: locked; 2: Lock expired.
     */
    function getLockerInfo(
        address _lockerAddress
    ) external returns (uint32 _startTime, uint32 _dueTime, uint32 _duration, uint96 _sAAHAmount, uint256 _veAAHAmount, uint256 _stakedveAAH, uint256 _rewardAmount, uint256 _lockedStatus) {
        (_dueTime, _duration, _sAAHAmount) = veAAH.getLocker(_lockerAddress);
        _startTime = _dueTime > _duration ? _dueTime - _duration : 0;

        _veAAHAmount = veAAH.balanceOf(_lockerAddress);

        _rewardAmount = earned(_lockerAddress);

        _lockedStatus = 2;
        if (_dueTime > block.timestamp) {
            _lockedStatus = 1;
            _stakedveAAH = _veAAHAmount;
        }
        if (_dueTime == 0) _lockedStatus = 0;
    }

    /**
     * @dev Calculate the expected amount of users.
     * @param _lockerAddress veAAH locker address.
     * @param _amount StakedAAH token amount.
     * @param _duration Duration, in seconds.
     * @return veAAH amount.
     */
    function calcBalanceReceived(address _lockerAddress, uint256 _amount, uint256 _duration) external view returns (uint256) {
        return veAAH.calcBalanceReceived(_lockerAddress, _amount, _duration);
    }

    /**
     * @dev Calculate the expected annual interest rate of users.
     * @param _lockerAddress veAAH locker address.
     * @return annual interest.
     */
    function estimateLockerAPY(address _lockerAddress) external updateReward(_lockerAddress) returns (uint256) {
        uint256 _totalSupply = totalSupply - accSettledBalance;
        if (_totalSupply == 0) return 0;

        (uint256 _dueTime, , uint96 _sAAHAmount) = veAAH.getLocker(_lockerAddress);
        uint256 _principal = uint256(_sAAHAmount);
        if (_dueTime <= block.timestamp || _principal == 0) return 0;

        uint256 _annualInterest = (rewardRate * balances[_lockerAddress] * 365 days) / _totalSupply;

        return _annualInterest.rdiv(_principal);
    }

    /**
     * @dev Query veAAH lock information.
     * @return veAAH total supply.
     *         Total locked sAAH
     *         Total settlement due
     *         Reward rate per second
     */
    function getLockersInfo() external updateReward(address(0)) returns (uint256, uint256, uint256, uint256) {
        return (veAAH.totalSupply(), sAAH.balanceOf(address(veAAH)), accSettledBalance, rewardRate);
    }
}
