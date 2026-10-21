// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CopraV2Base.sol";

/**
 * @notice COPRA-001 v2 edge-case tests: event correctness, risk reduction in
 *         shortfall, dust bounds at 18-decimal collateral, cross-call settlement
 *         equality, and scan-cap safety. Split from CopraV2.t.sol: one contract
 *         cannot hold the whole suite under legacy codegen (solc tag space).
 */
contract CopraV2EdgeTest is CopraV2Base {
    function test_CloseEmitsOwnerNotZero() public {
        // The owner is read before the position is deleted, not after.
        _fund(ALICE, 10_000e6);
        _finalize(PRICE, Status.VALID);
        uint256 id = _mintPosition(ALICE, 1000e18, 5000e6);
        vm.recordLogs();
        vm.prank(ALICE);
        manager.close(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("PositionClosed(uint256,address)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                found = true;
                assertEq(logs[i].topics.length, 3, "both params indexed");
                assertEq(address(uint160(uint256(logs[i].topics[2]))), ALICE, "owner not zero");
            }
        }
        assertTrue(found, "PositionClosed emitted");
    }

    function test_RiskReducingActionsWorkInShortfall() public {
        // Invariant 8 in SHORTFALL: deposit, repay, close and debt-free withdraw
        // never block (§12).
        CopraManagerV2 thin = _thinManager();
        collateral.mint(ALICE, 100_000e6);
        collateral.mint(BOB, 100_000e6);
        vm.prank(ALICE);
        collateral.approve(address(thin), type(uint256).max);
        vm.prank(BOB);
        collateral.approve(address(thin), type(uint256).max);
        _finalize(PRICE, Status.VALID);
        vm.startPrank(ALICE);
        uint256 a = thin.open();
        thin.deposit(a, 2000e6);
        thin.mint(a, 1000e18);
        vm.stopPrank();
        vm.startPrank(BOB);
        uint256 b = thin.open();
        thin.deposit(b, 2000e6);
        thin.mint(b, 1000e18);
        vm.stopPrank();
        _finalize(2 * PRICE, Status.VALID);
        assertEq(uint256(thin.protocolState()), uint256(CopraManagerV2.ProtocolState.SHORTFALL));
        // Debt-free withdraw on a fresh deposit-only position.
        vm.startPrank(ALICE);
        uint256 c = thin.open();
        thin.deposit(c, 500e6);
        thin.withdraw(c, 500e6);
        vm.stopPrank();
        // Deposit, partial repay, and close while still in shortfall.
        assertEq(uint256(thin.protocolState()), uint256(CopraManagerV2.ProtocolState.SHORTFALL));
        vm.prank(ALICE);
        thin.deposit(a, 100e6);
        assertEq(uint256(thin.protocolState()), uint256(CopraManagerV2.ProtocolState.SHORTFALL));
        vm.prank(ALICE);
        thin.repay(a, 100e18);
        assertEq(uint256(thin.protocolState()), uint256(CopraManagerV2.ProtocolState.SHORTFALL));
        vm.prank(BOB);
        thin.close(b);
        _assertConservedOn(thin);
    }

    function test_BadDebt18DecimalsSumsWithinTotals() public {
        // 18-decimal collateral with shrunken scales (a settle first): realized
        // sums still track the totals after bad-debt redistribution (spec §3).
        MockCollateral coll18 = new MockCollateral(18);
        MockGCPI g = new MockGCPI(1, 30 days, address(this));
        CopraManagerV2 m = new CopraManagerV2(
            address(coll18),
            18,
            address(g),
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
        CopraTokenV2 tok = m.copraToken();
        coll18.mint(ALICE, 10_000e18);
        coll18.mint(BOB, 2_000_000e18);
        vm.prank(ALICE);
        coll18.approve(address(m), type(uint256).max);
        vm.prank(BOB);
        coll18.approve(address(m), type(uint256).max);
        vm.prank(ALICE);
        tok.approve(address(m), type(uint256).max);
        vm.warp(1 + 30 days);
        g.finalize(PRICE, Status.VALID); // id 0
        vm.startPrank(ALICE);
        uint256 weak = m.open();
        m.deposit(weak, 4000e18);
        m.mint(weak, 1000e18);
        uint256 req = m.requestRedeem(500e18); // k = 1
        vm.stopPrank();
        vm.startPrank(BOB);
        uint256 strong = m.open();
        m.deposit(strong, 1_000_000e18);
        m.mint(strong, 1000e18);
        vm.stopPrank();
        vm.warp(1 + 2 * 30 days);
        g.finalize(PRICE, Status.VALID); // id 1
        vm.warp(1 + 3 * 30 days);
        g.finalize(PRICE, Status.VALID); // id 2 = s
        uint256[] memory one = new uint256[](1);
        one[0] = req;
        m.settle(one); // shrinks the scales below SCALE
        vm.warp(1 + 4 * 30 days);
        g.finalize(57 * PRICE, Status.VALID); // weak deeply underwater
        vm.prank(ALICE);
        tok.transfer(KEEPER, 500e18);
        vm.prank(KEEPER);
        tok.approve(address(m), type(uint256).max);
        vm.prank(KEEPER);
        m.liquidate(weak, type(uint256).max);
        (address wOwner, uint256 wColl, uint256 wDebt) = m.positionOf(weak);
        (, uint256 sColl, uint256 sDebt) = m.positionOf(strong);
        uint256 sumD = sDebt + (wOwner == address(0) ? 0 : wDebt);
        uint256 sumC = sColl + (wOwner == address(0) ? 0 : wColl);
        assertLe(sumD, m.totalDebt(), "debt sums within total");
        assertLe(sumC, m.totalColl(), "coll sums within total");
        assertEq(tok.totalSupply(), m.totalDebt(), "inv2: supply == debt");
        assertEq(
            coll18.balanceOf(address(m)), m.totalColl() + m.protocolFees() + m.settleReserve(), "inv3: pool == pockets"
        );
    }

    function test_SequentialShortfallSettlesEqualPerUnit() public {
        // Invariant 7 across calls: two requests settling at the same s in separate
        // settle() calls receive the same per-unit rate (the period's haircut).
        CopraManagerV2 thin = _thinManager();
        CopraTokenV2 thinToken = thin.copraToken();
        collateral.mint(ALICE, 100_000e6);
        collateral.mint(BOB, 100_000e6);
        vm.prank(ALICE);
        collateral.approve(address(thin), type(uint256).max);
        vm.prank(BOB);
        collateral.approve(address(thin), type(uint256).max);
        _finalize(PRICE, Status.VALID);
        vm.startPrank(ALICE);
        uint256 a = thin.open();
        thin.deposit(a, 2000e6);
        thin.mint(a, 1000e18);
        vm.stopPrank();
        vm.startPrank(BOB);
        uint256 b = thin.open();
        thin.deposit(b, 2000e6);
        thin.mint(b, 1000e18);
        vm.stopPrank();
        _finalize(2 * PRICE, Status.VALID);
        assertEq(uint256(thin.protocolState()), uint256(CopraManagerV2.ProtocolState.SHORTFALL));
        _enterPeriod(2);
        vm.prank(ALICE);
        thinToken.approve(address(thin), type(uint256).max);
        vm.prank(ALICE);
        uint256 r1 = thin.requestRedeem(100e18);
        vm.prank(BOB);
        thinToken.approve(address(thin), type(uint256).max);
        vm.prank(BOB);
        uint256 r2 = thin.requestRedeem(300e18);
        _finalize(2 * PRICE, Status.VALID); // period 2
        _finalize(2 * PRICE, Status.VALID); // period 3 = s
        uint256[] memory one = new uint256[](1);
        uint256 aBefore = collateral.balanceOf(ALICE);
        one[0] = r1;
        thin.settle(one);
        uint256 p1 = collateral.balanceOf(ALICE) - aBefore;
        uint256 bBefore = collateral.balanceOf(BOB);
        one[0] = r2;
        thin.settle(one);
        uint256 p2 = collateral.balanceOf(BOB) - bBefore;
        // Same pro-rata haircut across the two calls, within flooring dust.
        assertApproxEqAbs((p1 * 1e18) / 100e18, (p2 * 1e18) / 300e18, 100, "equal per unit across settles");
        assertLt(p1, 100e18 * 3 / 1e12, "haircut below full value");
        _assertConservedOn(thin);
    }

    function test_CancelPastScanCapRevertsRatherThanCancels() public {
        // Past SCAN_CAP finalized periods without a VALID record (a dead index: 256
        // months is 21 years of outage), cancel reverts instead of wrongly
        // returning escrow against a settlement price that may still exist.
        (,, uint256 req) = _redemptionSetup(); // k = 1
        (,,, uint256 reqAt,) = manager.requestOf(req);
        vm.warp(reqAt + EXPIRY + 1);
        for (uint256 i = 0; i < 258; ++i) {
            _finalize(0, Status.STALE);
        }
        vm.prank(ALICE);
        vm.expectRevert(IGCPI.ScanTooLong.selector);
        manager.cancel(req);
    }
}
