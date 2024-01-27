// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./GovernanceToken.sol";
import "../library/ERC20Permit.sol";
import "../library/SafeRatioMath.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

contract veAAH is OwnableUpgradeable, ReentrancyGuardUpgradeable, GovernanceToken, ERC20Permit {
    using SafeRatioMath for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev Calc the base value
    uint256 internal constant BASE = 1e18;
    /// @dev Calc the double of the base value
    // uint256 internal constant DOUBLE_BASE = 1e36;

    /// @dev Min lock step (seconds of a week).
    uint256 internal constant MIN_STEP = 1 weeks;

    /// @dev Max lock step (seconds of 208 week).
    uint256 internal constant MAX_STEP = 4 * 52 weeks;

    /// @dev StakedAAH address.
    IERC20 internal stakedAAH;

    /// @dev veAAH total amount.
    uint96 public totalSupply;

    /// @dev Information of the locker
    struct Locker {
        uint32 dueTime;
        uint32 duration;
        uint96 amount;
    }

    /// @dev veAAH holder's lock information
    mapping(address => Locker) internal lockers;

    /// @dev EnumerableSet of minters
    EnumerableSet.AddressSet internal minters;

    /// @dev Emitted when `lockers` is changed.
    event Lock(address caller, address recipient, uint256 underlyingAmount, uint96 tokenAmount, uint32 dueTime, uint32 duration);

    /// @dev Emitted when `lockers` is removed.
    event UnLock(address caller, address from, uint256 underlyingAmount, uint96 tokenAmount);

    /// @dev Emitted when `minter` is added as `minter`.
    event MinterAdded(address minter);

    /// @dev Emitted when `minter` is removed from `minters`.
    event MinterRemoved(address minter);

    /**
     * @notice Only for the implementation contract, as for the proxy pattern,
     *            should call `initialize()` separately.
     * @param _stakedAAH Staked AAH token address.
     */
    constructor(IERC20 _stakedAAH) {
        initialize(_stakedAAH);
    }

    /**
     * @dev Initialize contract to set some configs.
     * @param _stakedAAH Staked AAH token address.
     */
    function initialize(IERC20 _stakedAAH) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();

        stakedAAH = _stakedAAH;
    }

    /**
     * @dev Duration should be 1. within the range of (0, max_step]
     *                          2. integral multiple of min_step
     * @param _dur Lock duration,in seconds.
     */
    modifier isDurationValid(uint256 _dur) {
        require(_dur > 0 && _dur <= MAX_STEP, "duration is not valid.");
        _;
    }

    /**
     * @dev Check if the due time is valid.
     * @param _due Due greenwich timestamp.
     */
    modifier isDueTimeValid(uint256 _due) {
        require(_due > block.timestamp, "due time is not valid.");
        _;
    }

    /*********************************/
    /******** Owner functions ********/
    /*********************************/

    /**
     * @dev Throws if called by any account other than the minters.
     */
    modifier onlyMinter() {
        require(minters.contains(msg.sender), "caller is not minter.");
        _;
    }

    /**
     * @notice Add `minter` into minters.
     * If `minter` have not been a minter, emits a `MinterAdded` event.
     *
     * @param _minter The minter to add
     *
     * Requirements:
     * - the caller must be `owner`.
     */
    function _addMinter(address _minter) external onlyOwner {
        require(_minter != address(0), "_minter not accepted zero address.");
        if (minters.add(_minter)) {
            emit MinterAdded(_minter);
        }
    }

    /**
     * @notice Remove `minter` from minters.
     * If `minter` is a minter, emits a `MinterRemoved` event.
     *
     * @param _minter The minter to remove
     *
     * Requirements:
     * - the caller must be `owner`.
     */
    function _removeMinter(address _minter) external onlyOwner {
        require(_minter != address(0), "invalid minter address.");
        if (minters.remove(_minter)) {
            emit MinterRemoved(_minter);
        }
    }

    /*********************************/
    /******** Security Check *********/
    /*********************************/

    /**
     * @notice Ensure this is the veAAH contract.
     * @return The return value is always true.
     */
    function isvAAH() external pure returns (bool) {
        return true;
    }

    /*********************************/
    /****** Internal functions *******/
    /*********************************/

    /** @dev Mint balance in `_amount` to `_account`
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements:
     *
     * @param _account Account address, cannot be zero address.
     * @param _amount veAAH amount, cannot be zero.
     */
    function _mint(address _account, uint96 _amount) internal {
        require(_account != address(0), "not allowed to mint to zero address.");

        totalSupply = add96(totalSupply, _amount, "total supply overflows.");
        balances[_account] = add96(balances[_account], _amount, "amount overflows.");
        emit Transfer(address(0), _account, _amount);

        _moveDelegates(delegates[address(0)], delegates[_account], _amount);
    }

    /**
     * @dev Burn balance in `_amount` from `_account`
     *
     * Emits a {Transfer} event with `to` set to zero address.
     *
     * Requirements
     *
     * @param _account Account address, cannot be zero address.
     * @param _amount veAAH amount, must have at least balance in `_amount`.
     */
    function _burn(address _account, uint96 _amount) internal {
        require(_account != address(0), "_burn: Burn from the zero address!");

        balances[_account] = sub96(balances[_account], _amount, "burn amount exceeds balance.");
        totalSupply = sub96(totalSupply, _amount, "total supply underflows.");
        emit Transfer(_account, address(0), _amount);

        _moveDelegates(delegates[_account], delegates[address(0)], _amount);
    }

    /**
     * @dev Burn balance in `_amount` on behalf of `from` account
     *
     * See {ERC20-_burn} and {ERC20-allowance}.
     *
     * Requirements:
     *
     * @param _from Account address.
     * @param _caller Caller address, the caller must be allowed at least balance in `_amount` from `from` account.
     * @param _amount veAAH amount, must have at least balance in `_amount`.
     */
    function _burnFrom(address _from, address _caller, uint96 _amount) internal {
        if (_caller != _from) {
            uint96 _spenderAllowance = allowances[_from][_caller];

            if (_spenderAllowance != type(uint96).max) {
                uint96 _newAllowance = sub96(_spenderAllowance, _amount, "burn amount exceeds spender's allowance.");
                allowances[_from][_caller] = _newAllowance;

                emit Approval(_from, _caller, _newAllowance);
            }
        }

        _burn(_from, _amount);
    }

    function _approveERC20(address _owner, address _spender, uint256 _rawAmount) internal override {
        uint96 _amount;
        if (_rawAmount == type(uint256).max) {
            _amount = type(uint96).max;
        } else {
            _amount = safe96(_rawAmount, "veAAH::approve: amount exceeds 96 bits");
        }

        allowances[_owner][_spender] = _amount;

        emit Approval(_owner, _spender, _amount);
    }

    /**
     * @dev Calculate weight rate on duration.
     * @param _d Duration, in seconds.
     * @param _multipier weight rate.
     */
    function _weightedRate(uint256 _d) internal pure returns (uint256 _multipier) {
        // Linear_rate = _d / MAX_STEP
        // curve_rate = (1 + Linear_rate) ^ 2 * Linear_rate
        // uint256 _l = (_d * BASE) / MAX_STEP;
        // _multipier = (((BASE + _l)**2) * _l) / DOUBLE_BASE;
        _multipier = (_d * BASE) / MAX_STEP;
    }

    /**
     * @dev Calculate weight rate on duration.
     * @param _amount Staked AAH token amount.
     * @param _duration Duration, in seconds.
     * @return veAAH amount.
     */
    function _weightedExchange(uint256 _amount, uint256 _duration) internal pure returns (uint96) {
        return safe96(_amount.rmul(_weightedRate(_duration)), "weighted rate overflow.");
    }

    /**
     * @notice Lock Staked AAH and harvest veAAH.
     * @dev Create lock-up information and mint veAAH on lock-up amount and duration.
     * @param _caller Caller address.
     * @param _recipient veAAH recipient address.
     * @param _amount Staked AAH token amount.
     * @param _duration Duration, in seconds.
     * @param _minted The amount of veAAH minted.
     */
    function _lock(address _caller, address _recipient, uint256 _amount, uint256 _duration) internal isDurationValid(_duration) returns (uint96 _minted) {
        require(_amount > 0, "not allowed zero amount.");

        Locker storage _locker = lockers[_recipient];
        require(_locker.dueTime == 0, "due time refuses to create a new lock.");

        _minted = _weightedExchange(_amount, _duration);

        _locker.dueTime = safe32(block.timestamp + _duration, "due time overflow.");
        _locker.duration = safe32(_duration, "duration overflow.");
        _locker.amount = safe96(_amount, "locked amount overflow.");

        emit Lock(_caller, _recipient, _amount, _minted, _locker.dueTime, _locker.duration);

        _mint(_recipient, _minted);
    }

    /**
     * @notice Unlock Staked AAH and burn veAAH.
     * @dev Burn veAAH and clear lock information.
     * @param _caller Caller address.
     * @param _from veAAH holder's address.
     * @return The amount of veAAH burned.
     */
    function _unLock(address _caller, address _from) internal returns (uint96) {
        require(uint256(lockers[_from].dueTime) < block.timestamp, "due time not meeted.");

        return _clean(_caller, _from);
    }

    /**
     * @notice Unlock Staked AAH and burn veAAH.
     * @dev Burn veAAH and clear lock information.
     * @param _caller Caller address.
     * @param _from veAAH holder's address.
     * @param _burned The amount of veAAH burned.
     */
    function _clean(address _caller, address _from) internal returns (uint96 _burned) {
        Locker storage _locker = lockers[_from];
        _burned = balances[_from];
        _burnFrom(_from, _caller, _burned);

        delete lockers[_from];

        emit UnLock(_caller, _from, uint256(_locker.amount), _burned);
    }

    /*********************************/
    /******* Users functions *********/
    /*********************************/

    /**
     * @notice Lock Staked AAH and harvest veAAH.
     * @dev Create lock-up information and mint veAAH on lock-up amount and duration.
     * @param _recipient veAAH recipient address.
     * @param _amount Staked AAH token amount.
     * @param _duration Duration, in seconds.
     * @return The amount of veAAH minted.
     */
    function create(address _recipient, uint256 _amount, uint256 _duration) external onlyMinter nonReentrant returns (uint96) {
        stakedAAH.safeTransferFrom(msg.sender, address(this), _amount);
        return _lock(msg.sender, _recipient, _amount, _duration);
    }

    /**
     * @notice Increased locked staked AAH and harvest veAAH.
     * @dev According to the expiration time in the lock information, the minted veAAH.
     * @param _recipient veAAH recipient address.
     * @param _amount Staked AAH token amount.
     * @param _refilled The amount of veAAH minted.
     */
    function refill(address _recipient, uint256 _amount) external onlyMinter nonReentrant isDueTimeValid(lockers[_recipient].dueTime) returns (uint96 _refilled) {
        require(_amount > 0, "not allowed to add zero amount in lock-up");

        stakedAAH.safeTransferFrom(msg.sender, address(this), _amount);

        Locker storage _locker = lockers[_recipient];
        _refilled = _weightedExchange(_amount, uint256(_locker.dueTime) - block.timestamp);
        _locker.amount = safe96(uint256(_locker.amount) + _amount, "refilled amount overflow.");
        emit Lock(msg.sender, _recipient, _amount, _refilled, _locker.dueTime, _locker.duration);

        _mint(_recipient, _refilled);
    }

    /**
     * @notice Increase the lock duration and harvest veAAH.
     * @dev According to the amount of locked staked AAH and expansion time, the minted veAAH.
     * @param _recipient veAAH recipient address.
     * @param _duration Duration, in seconds.
     * @param _extended The amount of veAAH minted.
     */
    function extend(
        address _recipient,
        uint256 _duration
    ) external onlyMinter nonReentrant isDueTimeValid(lockers[_recipient].dueTime) isDurationValid(uint256(lockers[_recipient].duration) - _duration) returns (uint96 _extended) {
        Locker storage _locker = lockers[_recipient];
        _extended = _weightedExchange(uint256(_locker.amount), _duration);
        _locker.dueTime = safe32(uint256(_locker.dueTime) + _duration, "extended due time overflow.");
        _locker.duration = safe32(uint256(_locker.duration) + _duration, "extended duration overflow.");
        emit Lock(msg.sender, _recipient, 0, _extended, _locker.dueTime, _locker.duration);

        _mint(_recipient, _extended);
    }

    /**
     * @notice Unlock Staked AAH and burn veAAH.(transfer to msg.sender)
     * @dev Burn veAAH and clear lock information.
     * @param _from veAAH holder's address.
     * @param _unlocked The amount of veAAH burned.
     */
    function withdraw(address _from) external onlyMinter nonReentrant returns (uint96 _unlocked) {
        uint256 _amount = lockers[_from].amount;
        _unlocked = _unLock(msg.sender, _from);
        stakedAAH.safeTransfer(msg.sender, _amount);
    }

    /**
     * @notice Unlock Staked AAH and burn veAAH.(transfer to _from)
     * @dev Burn veAAH and clear lock information.
     * @param _from veAAH holder's address.
     * @param _unlocked The amount of veAAH burned.
     */
    function withdraw2(address _from) external onlyMinter nonReentrant returns (uint96 _unlocked) {
        uint256 _amount = lockers[_from].amount;
        _unlocked = _unLock(msg.sender, _from);
        stakedAAH.safeTransfer(_from, _amount);
    }

    /**
     * @notice Lock Staked AAH and and update veAAH balance.(transfer to msg.sender)
     * @dev Update the lockup information and veAAH balance, return the excess sAAH to the user or receive transfer increased amount.
     * @param _recipient veAAH recipient address.
     * @param _amount Staked AAH token new amount.
     * @param _duration New duration, in seconds.
     * @param _refreshed veAAH new balance.
     */
    function refresh(address _recipient, uint256 _amount, uint256 _duration) external onlyMinter nonReentrant returns (uint96 _refreshed, uint256 _refund) {
        uint256 outstanding = uint256(lockers[_recipient].amount);
        if (_amount > outstanding) {
            stakedAAH.safeTransferFrom(msg.sender, address(this), _amount - outstanding);
        }

        _unLock(msg.sender, _recipient);
        _refreshed = _lock(msg.sender, _recipient, _amount, _duration);

        if (_amount < outstanding) {
            _refund = outstanding - _amount;
            stakedAAH.safeTransfer(msg.sender, _refund);
        }
    }

    /**
     * @notice Lock Staked AAH and and update veAAH balance.(transfer to _recipient)
     * @dev Update the lockup information and veAAH balance, return the excess sAAH to the user or receive transfer increased amount.
     * @param _recipient veAAH recipient address.
     * @param _amount Staked AAH token new amount.
     * @param _duration New duration, in seconds.
     * @param _refreshed veAAH new balance.
     */
    function refresh2(address _recipient, uint256 _amount, uint256 _duration) external onlyMinter nonReentrant returns (uint96 _refreshed) {
        uint256 outstanding = uint256(lockers[_recipient].amount);
        if (_amount > outstanding) {
            stakedAAH.safeTransferFrom(msg.sender, address(this), _amount - outstanding);
        }

        _unLock(msg.sender, _recipient);
        _refreshed = _lock(msg.sender, _recipient, _amount, _duration);

        if (_amount < outstanding) stakedAAH.safeTransfer(_recipient, outstanding - _amount);
    }

    /**
     * @notice If not expired, relock Staked AAH and update veAAH balance.(transfer to _recipient)
     * @dev Update the lockup information and veAAH balance.
     * @param _recipient veAAH recipient address.
     * @param _amount Staked AAH token new amount.
     * @param _duration New duration, in seconds.
     * @param _minted veAAH new balance.
     */
    function proExtend(address _recipient, uint256 _amount, uint256 _duration) external onlyMinter nonReentrant isDueTimeValid(lockers[_recipient].dueTime) returns (uint96 _minted) {
        if (_amount > 0) {
            stakedAAH.safeTransferFrom(msg.sender, address(this), _amount);
        }

        Locker memory _locker = lockers[_recipient];
        _clean(msg.sender, _recipient);
        _minted = _lock(msg.sender, _recipient, _amount + _locker.amount, _duration);
        require(_locker.dueTime <= lockers[_recipient].dueTime, "due time refuses to pro extend.");
    }

    /*********************************/
    /******** Query function *********/
    /*********************************/

    /**
     * @notice Return max lock-up duration
     * @return max lock-up duration
     */
    function maxDuration() external pure returns (uint256) {
        return MAX_STEP;
    }

    /**
     * @notice Return all minters
     * @return _minters The list of minter addresses
     */
    function getMinters() external view returns (address[] memory _minters) {
        uint256 _len = minters.length();
        _minters = new address[](_len);
        for (uint256 i = 0; i < _len; i++) {
            _minters[i] = minters.at(i);
        }
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
        Locker storage _locker = lockers[_lockerAddress];
        return (_locker.dueTime, _locker.duration, _locker.amount);
    }

    /**
     * @dev Calculate the expected amount of users.
     * @param _lockerAddress veAAH locker address.
     * @param _amount Staked AAH token amount.
     * @param _duration Duration, in seconds.
     * @return veAAH amount.
     */
    function calcBalanceReceived(address _lockerAddress, uint256 _amount, uint256 _duration) external view returns (uint256) {
        Locker storage _locker = lockers[_lockerAddress];
        if (_locker.dueTime < block.timestamp) return _amount.rmul(_weightedRate(_duration));

        uint256 _receiveAmount = uint256(_locker.amount).rmul(_weightedRate(_duration));
        return _receiveAmount + (_amount.rmul(_weightedRate(uint256(_locker.dueTime) + _duration - block.timestamp)));
    }
}
