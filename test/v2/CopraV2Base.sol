// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/v2/CopraManagerV2.sol";
import "../../src/v2/CopraTokenV2.sol";
import "../../src/v2/CopraRegistryV2.sol";
import "../../src/v2/MockGCPI.sol";
import "../../src/v2/IGCPI.sol";
import "../../src/gcpi/GCPITypes.sol";
import "../mocks/MockCollateral.sol";

/**
 * @notice Shared Forge fixture for the COPRA-001 v2 suites: a 6-decimal collateral token,
 *         a monthly MockGCPI, and a manager at the v0.2 parameters, plus time-travel helpers
 *         that finalize periods in order. Funds and approvals are per-test (actors differ).
 */
contract CopraV2Base is Test {
    uint256 internal constant PRICE = 150_000_000; // $1.50/kg at 8 decimals
    uint256 internal constant PERIOD = 30 days;
    uint8 internal constant COLL_DECIMALS = 6;

    // COPRA-001 v0.2 §13.
    uint256 internal constant MCR = 25000;
    uint256 internal constant LR = 16000;
    uint256 internal constant BONUS = 500;
    uint256 internal constant MIN_DEBT = 100e18;
    uint256 internal constant MAX_AGE = 45 days;
    uint256 internal constant EXPIRY = 183 days;
    uint256 internal constant MINT_FEE = 50;
    uint256 internal constant FEE_SHARE = 5000;
    uint256 internal constant REDEEM_FEE = 100;
    uint256 internal constant SETTLE_CAP = 10e6;

    MockCollateral internal collateral;
    MockGCPI internal gcpi;
    CopraManagerV2 internal manager;
    CopraTokenV2 internal token;
    uint256 internal genesis;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant KEEPER = address(0xEEEE);
    address internal constant RECIPIENT = address(0xEC1);

    function setUp() public virtual {
        genesis = block.timestamp;
        collateral = new MockCollateral(COLL_DECIMALS);
        gcpi = new MockGCPI(genesis, PERIOD, address(this));
        manager = new CopraManagerV2(
            address(collateral),
            COLL_DECIMALS,
            address(gcpi),
            RECIPIENT,
            MCR,
            LR,
            BONUS,
            MIN_DEBT,
            MAX_AGE,
            EXPIRY,
            MINT_FEE,
            FEE_SHARE,
            REDEEM_FEE,
            SETTLE_CAP
        );
        token = manager.copraToken();
    }

    /// @dev A second manager sharing collateral and GCPI, for adversarial calibrations.
    function _thinManager() internal returns (CopraManagerV2 thin) {
        thin = new CopraManagerV2(
            address(collateral),
            COLL_DECIMALS,
            address(gcpi),
            RECIPIENT,
            12000,
            10500,
            BONUS,
            MIN_DEBT,
            MAX_AGE,
            EXPIRY,
            MINT_FEE,
            FEE_SHARE,
            REDEEM_FEE,
            SETTLE_CAP
        );
    }

    function _fund(address who, uint256 collAmount) internal {
        collateral.mint(who, collAmount);
        vm.startPrank(who);
        collateral.approve(address(manager), type(uint256).max);
        token.approve(address(manager), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Ends the next unfinalized period and finalizes it, returning its id.
    function _finalize(uint256 price, Status status) internal returns (uint256 id) {
        id = gcpi.count();
        uint256 end = genesis + (id + 1) * PERIOD;
        if (block.timestamp < end) vm.warp(end);
        gcpi.finalize(price, status);
    }

    /// @dev Warps into period `k` (just after its first second) without finalizing anything.
    function _enterPeriod(uint256 k) internal {
        uint256 t = genesis + k * PERIOD + 1;
        if (block.timestamp < t) vm.warp(t);
    }

    /// @dev Opens, deposits and mints a position for `who`; returns its id.
    function _mintPosition(address who, uint256 debt, uint256 coll) internal returns (uint256 id) {
        vm.startPrank(who);
        id = manager.open();
        manager.deposit(id, coll);
        manager.mint(id, debt);
        vm.stopPrank();
    }

    /// @dev Alice and Bob mint 1000 each; Alice requests 400 in the current period.
    function _redemptionSetup() internal returns (uint256 alicePos, uint256 bobPos, uint256 req) {
        _fund(ALICE, 100_000e6);
        _fund(BOB, 100_000e6);
        _finalize(PRICE, Status.VALID); // period 0
        alicePos = _mintPosition(ALICE, 1000e18, 5000e6);
        bobPos = _mintPosition(BOB, 1000e18, 8000e6);
        _enterPeriod(1);
        vm.prank(ALICE);
        req = manager.requestRedeem(400e18);
    }

    /// @dev Invariant 2 (exact) and Invariant 3 (exact) on the main manager.
    function _assertConserved() internal view {
        assertEq(token.totalSupply(), manager.totalDebt(), "inv2: supply == debt");
        assertEq(
            collateral.balanceOf(address(manager)),
            manager.totalColl() + manager.protocolFees() + manager.settleReserve(),
            "inv3: pool == pockets"
        );
    }

    function _assertConservedOn(CopraManagerV2 m) internal view {
        assertEq(CopraTokenV2(m.copraToken()).totalSupply(), m.totalDebt(), "inv2");
        assertEq(collateral.balanceOf(address(m)), m.totalColl() + m.protocolFees() + m.settleReserve(), "inv3");
    }
}
