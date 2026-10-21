// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CopraV2Base.sol";

/**
 * @notice COPRA-001 v2 unit tests: positions (§5), liquidation (§9, §11.1), forward-priced
 *         redemption (§8), states (§12), epochs, the registry, the mock and the token.
 *         Property and fuzz coverage lives in CopraV2Fuzz.t.sol.
 */
contract CopraV2Test is CopraV2Base {
    // ------------------------------------------------------------------------
    // Positions (§5)
    // ------------------------------------------------------------------------

    function test_MintHappyPathSplitsFeeAndConserves() public {
        _fund(ALICE, 10_000e6);
        _finalize(PRICE, Status.VALID);
        uint256 id = _mintPosition(ALICE, 1000e18, 3800e6);
        // Fee: 0.5% of the $1500 minted value = $7.50, half to each pocket.
        assertEq(manager.protocolFees(), 3_750_000, "protocol fee");
        assertEq(manager.settleReserve(), 3_750_000, "reserve");
        (address owner, uint256 coll, uint256 debt) = manager.positionOf(id);
        assertEq(owner, ALICE);
        assertEq(debt, 1000e18);
        assertEq(coll, 3800e6 - 7_500_000, "collateral net of fee");
        assertEq(token.balanceOf(ALICE), 1000e18, "minter holds tokens");
        _assertConserved();
    }

    function test_MintAtExactMCRPassesOneWeiOverFails() public {
        _fund(ALICE, 10_000e6);
        _finalize(PRICE, Status.VALID);
        // Debt value $1500; fee $7.50 needs collateral 2.5 * 1500 + 7.50 = $3757.50 exactly.
        uint256 id = _mintPosition(ALICE, 1000e18, 3_757_500_000);
        (,, uint256 debt) = manager.positionOf(id);
        assertEq(debt, 1000e18);
        // One wei less collateral fails the MCR check.
        vm.startPrank(ALICE);
        uint256 id2 = manager.open();
        manager.deposit(id2, 3_757_500_000 - 1);
        vm.expectRevert(CopraManagerV2.BelowMCR.selector);
        manager.mint(id2, 1000e18);
        vm.stopPrank();
    }

    function test_MintBelowMinDebtReverts() public {
        _fund(ALICE, 10_000e6);
        _finalize(PRICE, Status.VALID);
        vm.startPrank(ALICE);
        uint256 id = manager.open();
        manager.deposit(id, 10_000e6);
        vm.expectRevert(CopraManagerV2.BelowMinDebt.selector);
        manager.mint(id, MIN_DEBT - 1);
        vm.stopPrank();
    }

    function test_MintNeedsUsablePrice() public {
        _fund(ALICE, 10_000e6);
        vm.startPrank(ALICE);
        uint256 id = manager.open();
        manager.deposit(id, 10_000e6);
        vm.expectRevert(CopraManagerV2.NoUsablePrice.selector);
        manager.mint(id, 1000e18);
        vm.stopPrank();
    }

    function test_RepayWithdrawClose() public {
        _fund(ALICE, 10_000e6);
        _finalize(PRICE, Status.VALID);
        uint256 id = _mintPosition(ALICE, 1000e18, 5000e6);
        vm.startPrank(ALICE);
        manager.repay(id, 400e18);
        (,, uint256 debt) = manager.positionOf(id);
        assertEq(debt, 600e18, "partial repay");
        // Debt value now $900; MCR needs $2250 + 0 fee on withdraw. Withdraw to the edge.
        (, uint256 coll,) = manager.positionOf(id);
        uint256 maxOut = coll - 2250e6;
        manager.withdraw(id, maxOut);
        vm.expectRevert(CopraManagerV2.BelowMCR.selector);
        manager.withdraw(id, 1);
        // Over-repayment reverts rather than silently capping.
        vm.expectRevert(abi.encodeWithSelector(CopraManagerV2.OverRepayment.selector, 601e18, 600e18));
        manager.repay(id, 601e18);
        manager.close(id);
        vm.stopPrank();
        (address owner,,) = manager.positionOf(id);
        assertEq(owner, address(0), "closed position deleted");
        assertEq(token.totalSupply(), 0, "all burned");
        _assertConserved();
    }

    function test_DepositRepayCloseNeedNoPrice() public {
        _fund(ALICE, 10_000e6);
        _finalize(PRICE, Status.VALID);
        uint256 id = _mintPosition(ALICE, 1000e18, 5000e6);
        // Kill the price: warp past MAX_PRICE_AGE with nothing new finalized.
        vm.warp(block.timestamp + MAX_AGE + 1);
        assertEq(uint256(manager.protocolState()), uint256(CopraManagerV2.ProtocolState.PRICE_UNAVAILABLE));
        vm.startPrank(ALICE);
        manager.deposit(id, 100e6);
        manager.repay(id, 100e18);
        vm.expectRevert(CopraManagerV2.NoUsablePrice.selector);
        manager.mint(id, 100e18);
        vm.expectRevert(CopraManagerV2.NoUsablePrice.selector);
        manager.withdraw(id, 1);
        manager.close(id);
        vm.stopPrank();
        _assertConserved();
    }

    function test_OnlyOwnerForMintWithdrawClose() public {
        _fund(ALICE, 10_000e6);
        _fund(BOB, 10_000e6);
        _finalize(PRICE, Status.VALID);
        uint256 id = _mintPosition(ALICE, 1000e18, 5000e6);
        vm.startPrank(BOB);
        vm.expectRevert(CopraManagerV2.NotOwner.selector);
        manager.mint(id, 100e18);
        vm.expectRevert(CopraManagerV2.NotOwner.selector);
        manager.withdraw(id, 1);
        vm.expectRevert(CopraManagerV2.NotOwner.selector);
        manager.close(id);
        // Anyone may deposit into and repay any position.
        manager.deposit(id, 100e6);
        token.approve(address(manager), type(uint256).max);
        vm.stopPrank();
        vm.prank(ALICE);
        token.transfer(BOB, 100e18);
        vm.prank(BOB);
        manager.repay(id, 100e18);
        (,, uint256 debt) = manager.positionOf(id);
        assertEq(debt, 900e18);
    }

    // ------------------------------------------------------------------------
    // Liquidation (§9, §11.1)
    // ------------------------------------------------------------------------

    /// @dev Alice at CR 2.5, price doubles: CR 1.25 < LR 1.6, covered with the bonus.
    function _liquidatable() internal returns (uint256 id) {
        _fund(ALICE, 100_000e6);
        _finalize(PRICE, Status.VALID);
        id = _mintPosition(ALICE, 1000e18, 4000e6);
        _finalize(2 * PRICE, Status.VALID);
    }

    function test_LiquidateFullCoveredTakesBonus() public {
        uint256 id = _liquidatable();
        _fund(BOB, 100_000e6);
        vm.prank(ALICE);
        token.transfer(BOB, 1000e18);
        (uint256 x, uint256 seized, uint256 bad) = manager.quoteLiquidate(id, type(uint256).max);
        assertEq(x, 1000e18);
        assertEq(seized, 3000e6 * 105 / 100, "debt value $3000 + 5%");
        assertEq(bad, 0);
        uint256 bobBefore = collateral.balanceOf(BOB);
        vm.prank(BOB);
        manager.liquidate(id, type(uint256).max);
        assertEq(collateral.balanceOf(BOB) - bobBefore, seized, "liquidator paid");
        (,, uint256 debt) = manager.positionOf(id);
        assertEq(debt, 0);
        // Leftover $850 ($4000 - $7.50 fee - $3150 seized... plus dust) withdraws freely.
        (, uint256 coll,) = manager.positionOf(id);
        assertGt(coll, 840e6);
        vm.prank(ALICE);
        manager.withdraw(id, coll);
        _assertConserved();
    }

    function test_LiquidatePartialRespectsMinDebtAndRatio() public {
        uint256 id = _liquidatable();
        _fund(BOB, 100_000e6);
        vm.prank(ALICE);
        token.transfer(BOB, 1000e18);
        // Repaying 950 leaves 50 < MIN_DEBT 100: reverts.
        vm.prank(BOB);
        vm.expectRevert(CopraManagerV2.BelowMinDebt.selector);
        manager.liquidate(id, 950e18);
        // CR 1.33; repaying 500 leaves CR (3992.5 - 1575) / 1500 = 1.61: allowed.
        vm.prank(BOB);
        manager.liquidate(id, 500e18);
        (, uint256 coll, uint256 debt) = manager.positionOf(id);
        assertEq(debt, 500e18);
        assertGt(coll * 1000 / 1500e6, 1600, "ratio improved");
        _assertConserved();
    }

    function test_LiquidatePartialBelow105WorsensAndReverts() public {
        // CR 1.03 < 105%: the bonus eats collateral faster than debt falls, so a partial
        // liquidation lowers the ratio and must revert; full liquidation covers the debt.
        _fund(ALICE, 100_000e6);
        _finalize(PRICE, Status.VALID);
        uint256 id = _mintPosition(ALICE, 1000e18, 4000e6);
        _finalize((PRICE * 2584) / 1000, Status.VALID); // CR ~1.03, LR 1.6
        _fund(BOB, 100_000e6);
        vm.prank(ALICE);
        token.transfer(BOB, 1000e18);
        vm.prank(BOB);
        vm.expectRevert(CopraManagerV2.WorsensRatio.selector);
        manager.liquidate(id, 500e18);
        (uint256 x, uint256 seized, uint256 bad) = manager.quoteLiquidate(id, type(uint256).max);
        assertEq(x, 1000e18, "full repay");
        assertEq(bad, 0, "collateral covers the debt itself");
        vm.prank(BOB);
        manager.liquidate(id, type(uint256).max);
        assertEq(seized, 4000e6 - 7_500_000, "all collateral taken");
        _assertConserved();
    }

    function test_LiquidateBadDebtRedistributesOverCollateral() public {
        _fund(ALICE, 100_000e6);
        _fund(BOB, 100_000e6);
        _finalize(PRICE, Status.VALID);
        uint256 weak = _mintPosition(ALICE, 1000e18, 4000e6);
        uint256 strong = _mintPosition(BOB, 1000e18, 10_000e6);
        // 3x price: weak CR 0.83 underwater, strong CR ~2.2 safe.
        _finalize(3 * PRICE, Status.VALID);
        _fund(KEEPER, 100_000e6);
        vm.prank(ALICE);
        token.transfer(KEEPER, 1000e18);
        (uint256 x, uint256 seized, uint256 bad) = manager.quoteLiquidate(weak, type(uint256).max);
        assertLt(x, 1000e18, "only covered debt repaid");
        assertGt(bad, 0, "underwater means bad debt");
        assertEq(seized, 4000e6 - 7_500_000, "all collateral seized");
        (, uint256 strongDebtBefore) = _debtOf(strong);
        vm.prank(KEEPER);
        manager.liquidate(weak, type(uint256).max);
        // The husk is deleted; the strong position absorbed all bad debt (sole survivor).
        (address owner,,) = manager.positionOf(weak);
        assertEq(owner, address(0), "husk deleted");
        (, uint256 strongDebtAfter) = _debtOf(strong);
        assertApproxEqAbs(strongDebtAfter, strongDebtBefore + bad, 10, "redistributed to survivor");
        _assertConserved();
        assertEq(manager.totalDebt(), token.totalSupply(), "supply exact through bad debt");
    }

    function _debtOf(uint256 id) internal view returns (uint256 coll, uint256 debt) {
        (, coll, debt) = manager.positionOf(id);
    }

    function test_LiquidateLastCollateralKeepsHuskExact() public {
        // One position, wiped past zero collateral value: with no base to redistribute over,
        // the husk keeps its debt and Invariant 2 stays exact.
        _fund(ALICE, 100_000e6);
        _finalize(PRICE, Status.VALID);
        uint256 id = _mintPosition(ALICE, 1000e18, 4000e6);
        _finalize(10 * PRICE, Status.VALID); // debt value $15k on ~$4k collateral
        _fund(KEEPER, 100_000e6);
        vm.prank(ALICE);
        token.transfer(KEEPER, 1000e18);
        vm.prank(KEEPER);
        manager.liquidate(id, type(uint256).max);
        (address owner, uint256 coll, uint256 debt) = manager.positionOf(id);
        assertEq(owner, ALICE, "husk kept, nothing to redistribute over");
        assertEq(coll, 0);
        assertGt(debt, 0);
        assertEq(manager.totalDebt(), token.totalSupply(), "supply exact");
        assertEq(manager.totalColl(), 0);
        // Collateral returns via a new position; liquidating the husk now redistributes.
        _fund(BOB, 100_000e6);
        vm.startPrank(BOB);
        uint256 id2 = manager.open();
        manager.deposit(id2, 100_000e6);
        vm.stopPrank();
        vm.prank(KEEPER);
        manager.liquidate(id, type(uint256).max);
        (owner,,) = manager.positionOf(id);
        assertEq(owner, address(0), "husk resolved once collateral exists");
        _assertConserved();
    }

    function test_LiquidateHealthyRevertsAndNeedsPrice() public {
        _fund(ALICE, 100_000e6);
        _finalize(PRICE, Status.VALID);
        uint256 id = _mintPosition(ALICE, 1000e18, 5000e6);
        vm.expectRevert(CopraManagerV2.NotLiquidatable.selector);
        manager.liquidate(id, type(uint256).max);
        vm.warp(block.timestamp + MAX_AGE + 1);
        vm.expectRevert(CopraManagerV2.NoUsablePrice.selector);
        manager.liquidate(id, type(uint256).max);
    }

    // ------------------------------------------------------------------------
    // Redemption (§8)
    // ------------------------------------------------------------------------

    function test_RequestSettleHappyPath() public {
        (uint256 alicePos, uint256 bobPos, uint256 req) = _redemptionSetup();
        (,,,, bool pending) = manager.requestOf(req);
        assertTrue(pending, "request pending");
        assertEq(token.balanceOf(address(manager)), 400e18, "escrowed");
        // k = 1 (requested in period 1). Period 1 finalizing changes nothing: s >= 2.
        _finalize(2 * PRICE, Status.VALID); // period 1
        (bool ok,,) = manager.settleable(req);
        assertFalse(ok, "k+1 not finalized");
        _finalize(2 * PRICE, Status.VALID); // period 2
        uint256 s;
        (ok, s,) = manager.settleable(req);
        assertTrue(ok);
        assertEq(s, 2, "first VALID at or after k+1");
        (, uint256 aliceCollBefore,) = manager.positionOf(alicePos);
        (, uint256 bobCollBefore,) = manager.positionOf(bobPos);
        uint256 aliceBefore = collateral.balanceOf(ALICE);
        uint256[] memory ids = new uint256[](1);
        ids[0] = req;
        vm.prank(KEEPER);
        manager.settle(ids);
        // Gross 400 * $3 = $1200; fee 1% = $12; payout $1188.
        assertEq(collateral.balanceOf(ALICE) - aliceBefore, 1188e6, "payout net of fee");
        assertEq(token.totalSupply(), 1600e18, "escrow burned");
        // Collateral-proportional takes: both positions lose the same haircut rate.
        (, uint256 aliceCollAfter,) = manager.positionOf(alicePos);
        (, uint256 bobCollAfter,) = manager.positionOf(bobPos);
        // Debt-proportional takes would differ by ~4e16 here; floor dust is ~1e8.
        assertApproxEqAbs(
            aliceCollAfter * 1e18 / aliceCollBefore, bobCollAfter * 1e18 / bobCollBefore, 1e12, "uniform haircut"
        );
        // Debt falls 400/2000 = 20% on both.
        (,, uint256 aliceDebt) = manager.positionOf(alicePos);
        (,, uint256 bobDebt) = manager.positionOf(bobPos);
        assertApproxEqAbs(aliceDebt, 800e18, 5, "alice debt -20%");
        assertApproxEqAbs(bobDebt, 800e18, 5, "bob debt -20%");
        _assertConserved();
    }

    function test_SettleSkipsNonValidAndNeverSettlesAtK() public {
        (,, uint256 req) = _redemptionSetup(); // k = 1
        // Period 1 itself finalizes VALID later: still not settleable (s >= k+1 = 2).
        _finalize(PRICE, Status.VALID); // period 1
        (bool ok,,) = manager.settleable(req);
        assertFalse(ok, "k itself never settles");
        // k+1 = 2 finalizes non-VALID: skipped. k+2 = 3 VALID: settles there.
        _finalize(0, Status.INSUFFICIENT_COVERAGE); // period 2
        (ok,,) = manager.settleable(req);
        assertFalse(ok, "non-VALID skipped");
        _finalize(3 * PRICE, Status.VALID); // period 3
        uint256 s;
        uint256 price;
        (ok, s, price) = manager.settleable(req);
        assertTrue(ok);
        assertEq(s, 3);
        assertEq(price, 3 * PRICE);
        uint256[] memory ids = new uint256[](1);
        ids[0] = req;
        uint256 aliceBefore = collateral.balanceOf(ALICE);
        manager.settle(ids);
        assertEq(collateral.balanceOf(ALICE) - aliceBefore, 1782e6, "pays P_3 ($4.50) net of fee");
        _assertConserved();
    }

    function test_SettleBatchRules() public {
        _fund(ALICE, 100_000e6);
        _fund(BOB, 100_000e6);
        _finalize(PRICE, Status.VALID);
        _mintPosition(ALICE, 1000e18, 5000e6);
        _mintPosition(BOB, 1000e18, 8000e6);
        _enterPeriod(1);
        vm.prank(ALICE);
        uint256 r1 = manager.requestRedeem(100e18); // k = 1 -> s = 2
        _enterPeriod(2);
        vm.prank(BOB);
        uint256 r2 = manager.requestRedeem(100e18); // k = 2 -> s = 3
        _finalize(PRICE, Status.VALID); // period 1
        _finalize(PRICE, Status.VALID); // period 2
        _finalize(PRICE, Status.VALID); // period 3
        // Mixed periods in one batch revert.
        uint256[] memory both = new uint256[](2);
        both[0] = r1;
        both[1] = r2;
        vm.expectRevert(CopraManagerV2.MixedPeriods.selector);
        manager.settle(both);
        // Duplicate ids revert (second sighting already spent).
        uint256[] memory dup = new uint256[](2);
        dup[0] = r1;
        dup[1] = r1;
        vm.expectRevert(CopraManagerV2.NotSettleable.selector);
        manager.settle(dup);
        // Empty and oversized batches revert.
        vm.expectRevert(CopraManagerV2.TooManyIds.selector);
        manager.settle(new uint256[](0));
        vm.expectRevert(CopraManagerV2.TooManyIds.selector);
        manager.settle(new uint256[](101));
        // Each settles alone at its own period.
        uint256[] memory one = new uint256[](1);
        one[0] = r1;
        manager.settle(one);
        one[0] = r2;
        manager.settle(one);
        _assertConserved();
    }

    function test_SettlerRefundCappedAndOptional() public {
        (,, uint256 req) = _redemptionSetup();
        _finalize(PRICE, Status.VALID); // period 1
        _finalize(PRICE, Status.VALID); // period 2
        // Reserve holds $7.50 (two $7.50 mint fees at 50%); cap is $10.
        assertEq(manager.settleReserve(), 7_500_000, "two mints funded the reserve");
        uint256[] memory ids = new uint256[](1);
        ids[0] = req;
        vm.prank(KEEPER);
        manager.settle(ids);
        assertEq(collateral.balanceOf(KEEPER), 7_500_000, "refund capped by reserve");
        assertEq(manager.settleReserve(), 0);
        _assertConserved();
    }

    function test_ShortfallHaircutEqualPerUnit() public {
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
        thin.mint(a, 1000e18); // CR 1.33 at $1.50, MCR 1.2
        vm.stopPrank();
        vm.startPrank(BOB);
        uint256 b = thin.open();
        thin.deposit(b, 2000e6);
        thin.mint(b, 1000e18);
        vm.stopPrank();
        // 2x price: TCR = 3992.5 / 6000 = 0.665. Shortfall, but no liquidation yet run.
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
        _finalize(2 * PRICE, Status.VALID); // period 2... wait, k = 2, need s = 3
        _finalize(2 * PRICE, Status.VALID); // period 3
        uint256 aBefore = collateral.balanceOf(ALICE);
        uint256 bBefore = collateral.balanceOf(BOB);
        uint256[] memory ids = new uint256[](2);
        ids[0] = r1;
        ids[1] = r2;
        thin.settle(ids);
        uint256 p1 = collateral.balanceOf(ALICE) - aBefore;
        uint256 p2 = collateral.balanceOf(BOB) - bBefore;
        // Same pro-rata haircut: payouts proportional to amounts within rounding.
        assertApproxEqAbs(p1 * 300e18, p2 * 100e18, 400e18, "equal per unit");
        assertLt(p1, 100e18 * 3 / 1e12, "haircut below full value");
        _assertConservedOn(thin);
    }

    function test_CancelRules() public {
        (,, uint256 req) = _redemptionSetup(); // k = 1
        // Before expiry with no s: too early.
        vm.prank(ALICE);
        vm.expectRevert(CopraManagerV2.NotExpired.selector);
        manager.cancel(req);
        // Strangers cannot cancel.
        vm.prank(BOB);
        vm.expectRevert(CopraManagerV2.NotOwner.selector);
        manager.cancel(req);
        // Past expiry with a settlement price in existence: must settle instead.
        _finalize(PRICE, Status.VALID); // period 1
        _finalize(PRICE, Status.VALID); // period 2
        vm.warp(block.timestamp + EXPIRY + 1);
        vm.prank(ALICE);
        vm.expectRevert(CopraManagerV2.MustSettle.selector);
        manager.cancel(req);
        // Past expiry with no VALID s at or after k+1: escrow returns. Non-VALID
        // periods at the candidate slots do not block cancellation.
        vm.prank(BOB);
        uint256 req2 = manager.requestRedeem(100e18);
        (,, uint256 k2,,) = manager.requestOf(req2);
        while (gcpi.count() <= k2 + 1) _finalize(0, Status.STALE);
        (,,, uint256 reqAt,) = manager.requestOf(req2);
        vm.warp(reqAt + EXPIRY + 1);
        uint256 bobBefore = token.balanceOf(BOB);
        vm.prank(BOB);
        manager.cancel(req2);
        assertEq(token.balanceOf(BOB) - bobBefore, 100e18, "escrow returned");
        (,,,, bool pending) = manager.requestOf(req2);
        assertFalse(pending);
        _assertConserved();
    }

    function test_SettleNeedsNoUsablePrice() public {
        // s finalized long ago and stale: settlement still works at P_s (§12).
        (,, uint256 req) = _redemptionSetup(); // k = 1
        _finalize(PRICE, Status.VALID); // period 1
        _finalize(2 * PRICE, Status.VALID); // period 2
        vm.warp(block.timestamp + MAX_AGE + 1);
        assertEq(uint256(manager.protocolState()), uint256(CopraManagerV2.ProtocolState.PRICE_UNAVAILABLE));
        uint256[] memory ids = new uint256[](1);
        ids[0] = req;
        uint256 aliceBefore = collateral.balanceOf(ALICE);
        manager.settle(ids);
        assertEq(collateral.balanceOf(ALICE) - aliceBefore, 1188e6, "settles at P_2 without usable");
        _assertConserved();
    }

    function test_RequestWorksInEveryState() public {
        _fund(ALICE, 100_000e6);
        _finalize(PRICE, Status.VALID);
        _mintPosition(ALICE, 1000e18, 5000e6);
        vm.warp(block.timestamp + MAX_AGE + 1); // PRICE_UNAVAILABLE
        vm.prank(ALICE);
        manager.requestRedeem(100e18); // no revert
        _assertConserved();
    }

    // ------------------------------------------------------------------------
    // Epochs (full-supply redemption)
    // ------------------------------------------------------------------------

    function test_FullSupplyRedemptionOpensEpochAndSyncs() public {
        _fund(ALICE, 100_000e6);
        _fund(BOB, 100_000e6);
        _finalize(PRICE, Status.VALID);
        uint256 id = _mintPosition(ALICE, 1000e18, 5000e6);
        // Bob deposits but never mints: a debt-free survivor through two epochs.
        vm.startPrank(BOB);
        uint256 bob = manager.open();
        manager.deposit(bob, 3000e6);
        vm.stopPrank();
        _enterPeriod(1);
        vm.prank(ALICE);
        uint256 req = manager.requestRedeem(1000e18); // the entire supply
        _finalize(2 * PRICE, Status.VALID); // period 1
        _finalize(2 * PRICE, Status.VALID); // period 2 = s
        uint256 pre1 = manager.totalColl();
        uint256[] memory ids = new uint256[](1);
        ids[0] = req;
        manager.settle(ids);
        uint256 post1 = manager.totalColl();
        assertEq(manager.epoch(), 1, "full redemption opens an epoch");
        assertEq(manager.totalDebt(), 0);
        assertEq(token.totalSupply(), 0);
        // The old position's touch reverts until synced; syncing is permissionless.
        assertEq(manager.epochsBehind(id), 1);
        vm.prank(ALICE);
        vm.expectRevert(CopraManagerV2.NeedsSync.selector);
        manager.deposit(id, 1);
        // Leave both survivors unsynced through a second full-supply epoch.
        _finalize(2 * PRICE, Status.VALID); // period 3
        _mintPosition(ALICE, 100e18, 1000e6);
        vm.prank(ALICE);
        uint256 req2 = manager.requestRedeem(100e18); // the entire new supply
        _finalize(2 * PRICE, Status.VALID); // period 4
        uint256 pre2 = manager.totalColl();
        _finalize(2 * PRICE, Status.VALID); // period 5 = s
        ids[0] = req2;
        manager.settle(ids);
        uint256 post2 = manager.totalColl();
        assertEq(manager.epoch(), 2, "second full redemption opens another epoch");
        // One permissionless sync hops both epochs for each survivor.
        assertEq(manager.epochsBehind(id), 2);
        assertEq(manager.epochsBehind(bob), 2);
        vm.prank(KEEPER);
        manager.syncPosition(id);
        vm.prank(KEEPER);
        manager.syncPosition(bob);
        assertEq(manager.epochsBehind(id), 0);
        assertEq(manager.epochsBehind(bob), 0);
        (, uint256 aliceColl, uint256 aliceDebt) = manager.positionOf(id);
        (, uint256 bobColl, uint256 bobDebt) = manager.positionOf(bob);
        assertEq(aliceDebt, 0, "all debt redeemed");
        assertEq(bobDebt, 0, "never had debt");
        // Bob's collateral took both haircuts and nothing else.
        uint256 want = (3000e6 * post1) / pre1;
        want = (want * post2) / pre2;
        assertApproxEqAbs(bobColl, want, 5, "debt-free survivor haircut twice");
        assertGt(aliceColl, 1000e6, "collateral net of payouts");
        vm.prank(ALICE);
        manager.deposit(id, 100e6); // acts again
        // And the system mints on after the epochs: scales reset, not broken.
        _mintPosition(ALICE, 100e18, 1000e6);
        _assertConserved();
    }

    // ------------------------------------------------------------------------
    // Mock GCPI, registry, token
    // ------------------------------------------------------------------------

    function test_MockFinalizeRules() public {
        // Cannot finalize the current period: its window has not ended.
        vm.expectRevert(abi.encodeWithSelector(MockGCPI.PeriodNotOver.selector, 0, genesis + PERIOD));
        gcpi.finalize(PRICE, Status.VALID);
        // NONE and PENDING_CONFIRMATION are not final.
        vm.warp(genesis + PERIOD);
        vm.expectRevert(abi.encodeWithSelector(MockGCPI.NotFinalStatus.selector, Status.NONE));
        gcpi.finalize(PRICE, Status.NONE);
        // VALID needs a price; non-VALID must not carry one.
        vm.expectRevert(MockGCPI.ZeroPriceForValid.selector);
        gcpi.finalize(0, Status.VALID);
        vm.expectRevert(MockGCPI.NonzeroPriceForNonValid.selector);
        gcpi.finalize(PRICE, Status.STALE);
        // The happy path assigns sequential ids.
        uint256 id = gcpi.finalize(PRICE, Status.VALID);
        assertEq(id, 0);
        (uint256 p, Status s, uint256 f) = gcpi.record(0);
        assertEq(p, PRICE);
        assertEq(uint256(s), uint256(Status.VALID));
        assertEq(f, block.timestamp);
        (p, s, f) = gcpi.record(1);
        assertEq(uint256(s), uint256(Status.NONE), "unfinalized reads NONE");
    }

    function test_MockFinalizeOnlyUpdater() public {
        // Finalized prices move funds in the manager; strangers cannot finalize.
        vm.warp(genesis + PERIOD);
        vm.prank(BOB);
        vm.expectRevert(MockGCPI.OnlyUpdater.selector);
        gcpi.finalize(PRICE, Status.VALID);
    }

    function test_RegistryPointsAtConsistentSet() public {
        CopraRegistryV2 registry = new CopraRegistryV2(address(this));
        vm.expectRevert(CopraRegistryV2.ZeroAddress.selector);
        registry.setDeployment(address(0), address(gcpi), address(manager), address(token));
        // A token from another manager fails the wiring check.
        CopraManagerV2 other = _thinManager();
        // Hoisted: a call in argument position would itself consume the expectRevert.
        address otherToken = address(other.copraToken());
        vm.expectRevert(CopraRegistryV2.InconsistentDeployment.selector);
        registry.setDeployment(address(collateral), address(gcpi), address(manager), otherToken);
        registry.setDeployment(address(collateral), address(gcpi), address(manager), address(token));
        (address c, address g, address m, address t, uint256 v,) = registry.getDeployment();
        assertEq(c, address(collateral));
        assertEq(g, address(gcpi));
        assertEq(m, address(manager));
        assertEq(t, address(token));
        assertEq(v, 1);
        vm.prank(BOB);
        vm.expectRevert();
        registry.setDeployment(address(collateral), address(gcpi), address(manager), address(token));
    }

    function test_TokenOnlyManagerAndNeverBlocked() public {
        vm.expectRevert(CopraTokenV2.OnlyManager.selector);
        token.mint(ALICE, 1);
        vm.expectRevert(CopraTokenV2.OnlyManager.selector);
        token.burnFromManager(ALICE, 1);
        // Transfers are never blocked, even in shortfall (Invariant 8).
        CopraManagerV2 thin = _thinManager();
        collateral.mint(ALICE, 10_000e6);
        vm.prank(ALICE);
        collateral.approve(address(thin), type(uint256).max);
        _finalize(PRICE, Status.VALID);
        vm.startPrank(ALICE);
        uint256 a = thin.open();
        thin.deposit(a, 2000e6);
        thin.mint(a, 1000e18);
        vm.stopPrank();
        _finalize(3 * PRICE, Status.VALID);
        assertEq(uint256(thin.protocolState()), uint256(CopraManagerV2.ProtocolState.SHORTFALL));
        CopraTokenV2 thinToken = thin.copraToken();
        vm.prank(ALICE);
        thinToken.transfer(BOB, 100e18); // no revert
        assertEq(thinToken.balanceOf(BOB), 100e18);
    }

    function test_ClaimFees() public {
        _fund(ALICE, 100_000e6);
        _finalize(PRICE, Status.VALID);
        _mintPosition(ALICE, 1000e18, 5000e6);
        // Anyone may trigger; the immutable recipient is paid.
        vm.prank(BOB);
        manager.claimFees();
        assertEq(collateral.balanceOf(RECIPIENT), 3_750_000, "protocol share paid out");
        assertEq(manager.protocolFees(), 0);
        vm.expectRevert(CopraManagerV2.NothingToClaim.selector);
        manager.claimFees();
        _assertConserved();
    }

    // ------------------------------------------------------------------------
    // No privileged role (Invariant 9): every state-changing function, from the ABIs.
    // ------------------------------------------------------------------------

    function _mutators(string memory artifact) private view returns (string[] memory names) {
        string memory json = vm.readFile(artifact);
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".abi[", vm.toString(n), "]"))) n++;
        names = new string[](n);
        uint256 m;
        for (uint256 i = 0; i < n; i++) {
            string memory p = string.concat(".abi[", vm.toString(i), "]");
            if (keccak256(bytes(vm.parseJsonString(json, string.concat(p, ".type")))) != keccak256("function")) {
                continue;
            }
            bytes32 mut = keccak256(bytes(vm.parseJsonString(json, string.concat(p, ".stateMutability"))));
            if (mut == keccak256("view") || mut == keccak256("pure")) continue;
            names[m++] = vm.parseJsonString(json, string.concat(p, ".name"));
        }
        assembly {
            mstore(names, m)
        }
    }

    function _assertMutators(string memory artifact, string memory want) private view {
        string[] memory got = _mutators(artifact);
        string memory joined;
        for (uint256 i = 0; i < got.length; i++) {
            joined = string.concat(joined, i > 0 ? "," : "", got[i]);
        }
        assertEq(joined, want, artifact);
    }

    function test_TrustAssumption_NoPositionManagerPrivilege() public view {
        // None sets a price, a ratio, a fee, a recipient or a threshold, and none upgrades,
        // pauses or bypasses anything. claimFees pays the immutable recipient; syncPosition
        // only rebases accounting.
        _assertMutators(
            "out/CopraManagerV2.sol/CopraManagerV2.json",
            "cancel,claimFees,close,deposit,liquidate,mint,open,repay,requestRedeem,settle,syncPosition,withdraw"
        );
    }

    function test_TrustAssumption_TokenAndMock() public view {
        // approve/transfer/transferFrom are the unblockable ERC20 surface (Invariant 8);
        // only mint/burnFromManager are manager-gated.
        _assertMutators("out/CopraTokenV2.sol/CopraTokenV2.json", "approve,burnFromManager,mint,transfer,transferFrom");
        _assertMutators("out/MockGCPI.sol/MockGCPI.json", "finalize"); // updater-gated; the mock has no other mutator
    }
}
