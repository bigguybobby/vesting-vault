// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/VestingVault.sol";

contract MockERC20 {
    string public name;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    constructor(string memory _n) { name = _n; }
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; totalSupply += amt; }
    function approve(address s, uint256 amt) external returns (bool) { allowance[msg.sender][s] = amt; return true; }
    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt); balanceOf[msg.sender] -= amt; balanceOf[to] += amt; return true;
    }
    function transferFrom(address f, address t, uint256 amt) external returns (bool) {
        require(balanceOf[f] >= amt && allowance[f][msg.sender] >= amt);
        allowance[f][msg.sender] -= amt; balanceOf[f] -= amt; balanceOf[t] += amt; return true;
    }
}

contract VestingVaultTest is Test {
    VestingVault vault;
    MockERC20 token;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 START;
    uint256 CLIFF = 30 days;
    uint256 DURATION = 365 days;
    uint256 AMOUNT = 1000e18;

    function setUp() public {
        vault = new VestingVault();
        token = new MockERC20("VEST");
        token.mint(address(this), 100_000e18);
        token.approve(address(vault), type(uint256).max);
        START = block.timestamp;
    }

    function _create(address ben, bool revocable) internal returns (uint256) {
        return vault.createSchedule(ben, address(token), AMOUNT, START, CLIFF, DURATION, revocable);
    }

    // ─── Constructor ─────────────────────────────────────────────────

    function test_constructor() public view {
        assertEq(vault.owner(), address(this));
        assertEq(vault.scheduleCount(), 0);
    }

    // ─── Create Schedule ─────────────────────────────────────────────

    function test_createSchedule() public {
        uint256 id = _create(alice, true);
        assertEq(id, 0);
        assertEq(vault.scheduleCount(), 1);
        assertEq(token.balanceOf(address(vault)), AMOUNT);
    }

    function test_createSchedule_multiple() public {
        _create(alice, true);
        _create(bob, false);
        assertEq(vault.scheduleCount(), 2);

        uint256[] memory ids = vault.getScheduleIds(alice);
        assertEq(ids.length, 1);
        assertEq(ids[0], 0);
    }

    function test_createSchedule_zeroBeneficiary() public {
        vm.expectRevert("zero beneficiary");
        vault.createSchedule(address(0), address(token), AMOUNT, START, CLIFF, DURATION, true);
    }

    function test_createSchedule_zeroToken() public {
        vm.expectRevert("zero token");
        vault.createSchedule(alice, address(0), AMOUNT, START, CLIFF, DURATION, true);
    }

    function test_createSchedule_zeroAmount() public {
        vm.expectRevert("zero amount");
        vault.createSchedule(alice, address(token), 0, START, CLIFF, DURATION, true);
    }

    function test_createSchedule_zeroDuration() public {
        vm.expectRevert("zero duration");
        vault.createSchedule(alice, address(token), AMOUNT, START, CLIFF, 0, true);
    }

    function test_createSchedule_cliffTooLong() public {
        vm.expectRevert("cliff > duration");
        vault.createSchedule(alice, address(token), AMOUNT, START, DURATION + 1, DURATION, true);
    }

    function test_createSchedule_notOwner() public {
        vm.prank(alice);
        vm.expectRevert("not owner");
        vault.createSchedule(alice, address(token), AMOUNT, START, CLIFF, DURATION, true);
    }

    // ─── Vesting ─────────────────────────────────────────────────────

    function test_vestedAmount_beforeCliff() public {
        _create(alice, true);
        vm.warp(START + CLIFF - 1);
        assertEq(vault.vestedAmount(0), 0);
    }

    function test_vestedAmount_atCliff() public {
        _create(alice, true);
        vm.warp(START + CLIFF);
        uint256 expected = (AMOUNT * CLIFF) / DURATION;
        assertEq(vault.vestedAmount(0), expected);
    }

    function test_vestedAmount_halfway() public {
        _create(alice, true);
        vm.warp(START + DURATION / 2);
        assertEq(vault.vestedAmount(0), AMOUNT / 2);
    }

    function test_vestedAmount_fullyVested() public {
        _create(alice, true);
        vm.warp(START + DURATION);
        assertEq(vault.vestedAmount(0), AMOUNT);
    }

    function test_vestedAmount_afterDuration() public {
        _create(alice, true);
        vm.warp(START + DURATION + 100 days);
        assertEq(vault.vestedAmount(0), AMOUNT);
    }

    // ─── Release ─────────────────────────────────────────────────────

    function test_release() public {
        _create(alice, true);
        vm.warp(START + DURATION / 2);

        vm.prank(alice);
        uint256 released = vault.release(0);

        assertEq(released, AMOUNT / 2);
        assertEq(token.balanceOf(alice), AMOUNT / 2);
    }

    function test_release_incremental() public {
        _create(alice, true);

        vm.warp(START + DURATION / 4);
        vm.prank(alice);
        vault.release(0);
        assertEq(token.balanceOf(alice), AMOUNT / 4);

        vm.warp(START + DURATION / 2);
        vm.prank(alice);
        vault.release(0);
        assertEq(token.balanceOf(alice), AMOUNT / 2);
    }

    function test_release_full() public {
        _create(alice, true);
        vm.warp(START + DURATION);

        vm.prank(alice);
        vault.release(0);
        assertEq(token.balanceOf(alice), AMOUNT);
    }

    function test_release_notBeneficiary() public {
        _create(alice, true);
        vm.warp(START + DURATION);

        vm.prank(bob);
        vm.expectRevert("not beneficiary");
        vault.release(0);
    }

    function test_release_nothingToRelease() public {
        _create(alice, true);
        // Before cliff — 0 vested

        vm.prank(alice);
        vm.expectRevert("nothing to release");
        vault.release(0);
    }

    function test_release_invalidSchedule() public {
        vm.prank(alice);
        vm.expectRevert("invalid schedule");
        vault.release(99);
    }

    // ─── Revoke ──────────────────────────────────────────────────────

    function test_revoke_beforeCliff() public {
        _create(alice, true);
        vm.warp(START + CLIFF - 1);

        uint256 ownerBefore = token.balanceOf(address(this));
        vault.revoke(0);

        // Nothing vested, full refund
        assertEq(token.balanceOf(address(this)), ownerBefore + AMOUNT);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_revoke_halfway() public {
        _create(alice, true);
        vm.warp(START + DURATION / 2);

        uint256 ownerBefore = token.balanceOf(address(this));
        vault.revoke(0);

        // Alice gets vested portion, owner gets unvested
        assertEq(token.balanceOf(alice), AMOUNT / 2);
        assertEq(token.balanceOf(address(this)), ownerBefore + AMOUNT / 2);
    }

    function test_revoke_afterRelease() public {
        _create(alice, true);
        vm.warp(START + DURATION / 4);

        vm.prank(alice);
        vault.release(0); // Release 25%

        vm.warp(START + DURATION / 2);
        vault.revoke(0); // Revoke at 50%

        // Alice had 25% released + gets 25% unreleased vested
        assertEq(token.balanceOf(alice), AMOUNT / 2);
    }

    function test_revoke_notRevocable() public {
        _create(alice, false);

        vm.expectRevert("not revocable");
        vault.revoke(0);
    }

    function test_revoke_alreadyRevoked() public {
        _create(alice, true);
        vault.revoke(0);

        vm.expectRevert("already revoked");
        vault.revoke(0);
    }

    function test_revoke_notOwner() public {
        _create(alice, true);

        vm.prank(alice);
        vm.expectRevert("not owner");
        vault.revoke(0);
    }

    function test_revoke_invalidSchedule() public {
        vm.expectRevert("invalid schedule");
        vault.revoke(99);
    }

    function test_vestedAmount_afterRevoke() public {
        _create(alice, true);
        vm.warp(START + DURATION / 2);

        vm.prank(alice);
        vault.release(0); // Release 50%

        vault.revoke(0);

        // After revoke, vestedAmount returns released amount
        assertEq(vault.vestedAmount(0), AMOUNT / 2);
        assertEq(vault.releasable(0), 0);
    }

    // ─── No cliff ────────────────────────────────────────────────────

    function test_noCliff() public {
        vault.createSchedule(alice, address(token), AMOUNT, START, 0, DURATION, false);
        vm.warp(START + 1);
        assertGt(vault.vestedAmount(0), 0);
    }

    // ─── View Functions ──────────────────────────────────────────────

    function test_getScheduleInfo() public {
        _create(alice, true);
        vm.warp(START + DURATION / 2);

        (address ben, address tok, uint256 total, uint256 rel, uint256 vested, uint256 avail, bool revoked) = vault.getScheduleInfo(0);
        assertEq(ben, alice);
        assertEq(tok, address(token));
        assertEq(total, AMOUNT);
        assertEq(rel, 0);
        assertEq(vested, AMOUNT / 2);
        assertEq(avail, AMOUNT / 2);
        assertFalse(revoked);
    }

    function test_getScheduleIds() public {
        _create(alice, true);
        _create(alice, false);
        uint256[] memory ids = vault.getScheduleIds(alice);
        assertEq(ids.length, 2);
    }

    // ─── Admin ───────────────────────────────────────────────────────

    function test_transferOwnership() public {
        vault.transferOwnership(alice);
        assertEq(vault.owner(), alice);
    }

    function test_transferOwnership_notOwner() public {
        vm.prank(alice);
        vm.expectRevert("not owner");
        vault.transferOwnership(bob);
    }

    function test_transferOwnership_zero() public {
        vm.expectRevert("zero address");
        vault.transferOwnership(address(0));
    }

    // ─── Revoke fully vested ─────────────────────────────────────────

    function test_revoke_fullyVested() public {
        _create(alice, true);
        vm.warp(START + DURATION);

        uint256 ownerBefore = token.balanceOf(address(this));
        vault.revoke(0);

        // All vested → alice gets everything, owner gets nothing
        assertEq(token.balanceOf(alice), AMOUNT);
        assertEq(token.balanceOf(address(this)), ownerBefore);
    }
}
