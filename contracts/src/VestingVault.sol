// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title VestingVault — Token vesting with cliff and linear release
/// @notice Create vesting schedules for beneficiaries. Supports cliff, linear vesting,
///         revocable schedules, and multiple beneficiaries per token.
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract VestingVault {
    struct Schedule {
        address beneficiary;
        address token;
        uint256 totalAmount;
        uint256 released;
        uint256 start;
        uint256 cliff;       // cliff duration in seconds
        uint256 duration;    // total vesting duration in seconds
        bool revocable;
        bool revoked;
    }

    address public owner;
    uint256 public scheduleCount;
    mapping(uint256 => Schedule) public schedules;
    mapping(address => uint256[]) public beneficiarySchedules;

    event ScheduleCreated(uint256 indexed id, address indexed beneficiary, address token, uint256 amount);
    event TokensReleased(uint256 indexed id, address indexed beneficiary, uint256 amount);
    event ScheduleRevoked(uint256 indexed id, uint256 refunded);
    event OwnerTransferred(address indexed oldOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function createSchedule(
        address _beneficiary,
        address _token,
        uint256 _totalAmount,
        uint256 _start,
        uint256 _cliff,
        uint256 _duration,
        bool _revocable
    ) external onlyOwner returns (uint256 id) {
        require(_beneficiary != address(0), "zero beneficiary");
        require(_token != address(0), "zero token");
        require(_totalAmount > 0, "zero amount");
        require(_duration > 0, "zero duration");
        require(_cliff <= _duration, "cliff > duration");

        id = scheduleCount++;
        schedules[id] = Schedule({
            beneficiary: _beneficiary,
            token: _token,
            totalAmount: _totalAmount,
            released: 0,
            start: _start,
            cliff: _cliff,
            duration: _duration,
            revocable: _revocable,
            revoked: false
        });

        beneficiarySchedules[_beneficiary].push(id);

        require(IERC20(_token).transferFrom(msg.sender, address(this), _totalAmount), "transfer failed");
        emit ScheduleCreated(id, _beneficiary, _token, _totalAmount);
    }

    function release(uint256 _id) external returns (uint256 amount) {
        Schedule storage s = schedules[_id];
        require(s.beneficiary != address(0), "invalid schedule");
        require(msg.sender == s.beneficiary, "not beneficiary");

        amount = releasable(_id);
        require(amount > 0, "nothing to release");

        s.released += amount;
        require(IERC20(s.token).transfer(s.beneficiary, amount), "transfer failed");
        emit TokensReleased(_id, s.beneficiary, amount);
    }

    function revoke(uint256 _id) external onlyOwner {
        Schedule storage s = schedules[_id];
        require(s.beneficiary != address(0), "invalid schedule");
        require(s.revocable, "not revocable");
        require(!s.revoked, "already revoked");

        uint256 vested = vestedAmount(_id);
        uint256 unreleased = vested - s.released;
        uint256 refund = s.totalAmount - vested;

        s.revoked = true;

        // Release any vested but unclaimed tokens to beneficiary
        if (unreleased > 0) {
            s.released += unreleased;
            require(IERC20(s.token).transfer(s.beneficiary, unreleased), "transfer failed");
            emit TokensReleased(_id, s.beneficiary, unreleased);
        }

        // Refund unvested tokens to owner
        if (refund > 0) {
            require(IERC20(s.token).transfer(owner, refund), "refund failed");
        }

        emit ScheduleRevoked(_id, refund);
    }

    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "zero address");
        emit OwnerTransferred(owner, _newOwner);
        owner = _newOwner;
    }

    // ─── View Functions ──────────────────────────────────────────────

    function vestedAmount(uint256 _id) public view returns (uint256) {
        Schedule storage s = schedules[_id];
        if (s.revoked) return s.released;
        if (block.timestamp < s.start + s.cliff) return 0;
        if (block.timestamp >= s.start + s.duration) return s.totalAmount;
        return (s.totalAmount * (block.timestamp - s.start)) / s.duration;
    }

    function releasable(uint256 _id) public view returns (uint256) {
        return vestedAmount(_id) - schedules[_id].released;
    }

    function getScheduleIds(address _beneficiary) external view returns (uint256[] memory) {
        return beneficiarySchedules[_beneficiary];
    }

    function getScheduleInfo(uint256 _id) external view returns (
        address beneficiary,
        address token,
        uint256 totalAmount,
        uint256 released,
        uint256 vested,
        uint256 available,
        bool revoked
    ) {
        Schedule storage s = schedules[_id];
        return (s.beneficiary, s.token, s.totalAmount, s.released, vestedAmount(_id), releasable(_id), s.revoked);
    }
}
