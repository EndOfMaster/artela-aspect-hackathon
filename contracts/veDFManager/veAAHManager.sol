//SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./LPTokenWrapper.sol";
import "../interface/IStakedAAH.sol";
import "../library/SafeRatioMath.sol";
import "../library/BytesLib.sol";
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
    using BytesLib for bytes;

    ///@dev Min lock step (seconds of a week).
    uint256 internal constant MIN_STEP = 1 weeks;

    address public aspect;
    uint256 public startTime;

    ///@dev Token of reward
    IERC20 public rewardToken;
    IStakedAAH public sAAH;

    //TODO 纯aspect
    // uint256 public rewardDistribu1tedStored;

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

    function initialize(IveAAH _veAAH, IStakedAAH _sAAH, IERC20 _rewardToken, uint256 _startTime, address _aspect) public virtual initializer {
        require(_startTime > block.timestamp, "veAAHManager: Start time must be greater than the block timestamp");

        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();

        veAAH = _veAAH;
        sAAH = _sAAH;
        rewardToken = _rewardToken;
        aspect = _aspect;
        startTime = _startTime;

        sAAH.forceApprove(address(veAAH), type(uint256).max);
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

    /*********************************/
    /******* Users functions *********/
    /*********************************/

    /**
     * @notice Lock StakedAAH and harvest veAAH.
     * @dev Create lock-up information and mint veAAH on lock-up amount and duration.
     * @param _amount StakedAAH token amount.
     * @param _dueTime Due time timestamp, in seconds.
     */
    function create(uint256 _amount, uint256 _dueTime) public sanityCheck(_amount) isDueTimeValid(_dueTime) {
        uint256 _duration = _dueTime - block.timestamp;
        sAAH.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 _veAAHAmount = veAAH.create(msg.sender, _amount, _duration);

        string memory _context = string(abi.encodePacked(_dueTime, ",", _veAAHAmount));
        (bool success, ) = address(0x66).call(abi.encode(string("context"), _context));
        require(success, "veAAHManager: send aspect contect error");

        emit Create(msg.sender, _amount, _duration, _veAAHAmount);
    }

    /**
     * @notice Increased locked staked sAAH and harvest veAAH.
     * @dev According to the expiration time in the lock information, the minted veAAH.
     * @param _amount StakedAAH token amount.
     */
    function refill(uint256 _amount) external sanityCheck(_amount) {
        sAAH.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 _veAAHAmount = veAAH.refill(msg.sender, _amount);

        (uint32 _dueTime, , ) = veAAH.getLocker(msg.sender);

        string memory _context = string(abi.encodePacked(_dueTime, ",", _veAAHAmount));
        (bool success, ) = address(0x66).call(abi.encode(string("context"), _context));
        require(success, "veAAHManager: send aspect contect error");

        emit Refill(msg.sender, _amount, _veAAHAmount);
    }

    /**
     * @notice Increase the lock duration and harvest veAAH.
     * @dev According to the amount of locked StakedAAH and expansion time, the minted veAAH.
     * @param _dueTime new Due time timestamp, in seconds.
     */
    function extend(uint256 _dueTime) external isDueTimeValid(_dueTime) {
        (uint32 _oldDueTime, , ) = veAAH.getLocker(msg.sender);

        uint256 _duration = _dueTime - _oldDueTime;
        uint256 _veAAHAmount = veAAH.extend(msg.sender, _duration);

        string memory _context = string(abi.encodePacked(_dueTime, ",", _veAAHAmount, ",", _oldDueTime));
        (bool success, ) = address(0x66).call(abi.encode(string("context"), _context));
        require(success, "veAAHManager: send aspect contect error");

        emit Extend(msg.sender, _oldDueTime, _dueTime, _duration, _veAAHAmount);
    }

    /**
     * @notice Lock Staked sAAH and and update veAAH balance.
     * @dev Update the lockup information and veAAH balance, return the excess sAAH to the user or receive transfer increased amount.
     * @param _amount StakedAAH token new amount.
     * @param _dueTime Due time timestamp, in seconds.
     */
    function refresh(uint256 _amount, uint256 _dueTime) external sanityCheck(_amount) isDueTimeValid(_dueTime) nonReentrant {
        (, , uint256 _lockedSAAH) = veAAH.getLocker(msg.sender);
        //If the new amount is greater than the original lock volume, the difference needs to be supplemented
        if (_amount > _lockedSAAH) {
            sAAH.safeTransferFrom(msg.sender, address(this), _amount - _lockedSAAH);
        }

        uint256 _duration = _dueTime - block.timestamp;
        uint256 _oldVEAAHAmount = balances[msg.sender];
        uint256 _newVEAAHAmount = veAAH.refresh2(msg.sender, _amount, _duration);

        string memory _context = string(abi.encodePacked(_dueTime, ",", _newVEAAHAmount));
        (bool success, ) = address(0x66).call(abi.encode(string("context"), _context));
        require(success, "veAAHManager: send aspect contect error");

        emit Refresh(msg.sender, _lockedSAAH, _amount, _duration, _oldVEAAHAmount, _newVEAAHAmount);
    }

    ///@notice Extract reward
    function getReward() public virtual {
        (bool _success, bytes memory _returnData) = address(0x64).call(abi.encodePacked(aspect, string("reward")));
        require(_success, "veAAHManager: get aspect contect error");
        uint256 _reward = _returnData.toUint256(1);

        if (_reward > 0) {
            rewardToken.safeTransferFrom(owner(), msg.sender, _reward);
            emit RewardPaid(msg.sender, _reward);
        }
    }

    /**
     * @notice Claim reward and Unlock Staked sAAH and burn veAAH.
     * @dev Burn veAAH and clear lock information.
     */
    function exit() external {
        getReward();

        uint256 _burnVEAAH = veAAH.withdraw2(msg.sender);
        uint256 _oldBalance = balances[msg.sender];

        emit Withdraw(msg.sender, _burnVEAAH, _oldBalance);
    }

    /*********************************/
    /******** Query function *********/
    /*********************************/

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
     * @return annual interest.updateReward
     */

    function estimateLockerAPY(address _lockerAddress) external returns (uint256) {
        (bool _success0, bytes memory _returnData0) = address(0x64).call(abi.encodePacked(aspect, string("accSettledBalance")));
        require(_success0, "veAAHManager: get aspect contect error");
        uint256 _accSettledBalance = _returnData0.toUint256(1);

        (bool _success1, bytes memory _returnData1) = address(0x64).call(abi.encodePacked(aspect, string("rewardRate")));
        require(_success1, "veAAHManager: get aspect contect error");
        uint256 _rewardRate = _returnData1.toUint256(1);

        uint256 _totalSupply = totalSupply - _accSettledBalance;
        if (_totalSupply == 0) return 0;

        (uint256 _dueTime, , uint96 _sAAHAmount) = veAAH.getLocker(_lockerAddress);
        uint256 _principal = uint256(_sAAHAmount);
        if (_dueTime <= block.timestamp || _principal == 0) return 0;

        uint256 _annualInterest = (_rewardRate * balances[_lockerAddress] * 365 days) / _totalSupply;

        return _annualInterest.rdiv(_principal);
    }

    /**
     * @dev Query veAAH lock information.
     * @return veAAH total supply.
     *         Total locked sAAH
     *         Total settlement due
     *         Reward rate per secondupdateReward(address(0))
     */
    function getLockersInfo() external returns (uint256, uint256, uint256, uint256) {
        (bool _success0, bytes memory _returnData0) = address(0x64).call(abi.encodePacked(aspect, string("accSettledBalance")));
        require(_success0, "veAAHManager: get aspect contect error");
        uint256 _accSettledBalance = _returnData0.toUint256(1);

        (bool _success1, bytes memory _returnData1) = address(0x64).call(abi.encodePacked(aspect, string("rewardRate")));
        require(_success1, "veAAHManager: get aspect contect error");
        uint256 _rewardRate = _returnData1.toUint256(1);

        return (veAAH.totalSupply(), sAAH.balanceOf(address(veAAH)), _accSettledBalance, _rewardRate);
    }

    function isOwner(address _user) external view returns (bool result) {
        return _user == owner();
    }
}
