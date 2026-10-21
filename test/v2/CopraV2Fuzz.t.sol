// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CopraV2Base.sol";

/**
 * @notice Fuzz suite for the COPRA-001 v2 contracts: the mint gate (Invariant 1),
 *         conservation under operations, redemptions and liquidations (Invariants 2/3),
 *         forward pricing (Invariant 6) and equal treatment / order independence
 *         (Invariant 7). Bounds keep every run in realistic ranges; revert selectors
 *         are allowlisted so unexpected failures (including panics) fail the run.
 */
contract CopraV2FuzzTest is CopraV2Base {
    /// @dev §3 debt value rounded up, in collateral units (6 decimals).
    function _valueUp(uint256 debt, uint256 price) internal pure returns (uint256) {
        uint256 usd18 = (debt * price + 1e8 - 1) / 1e8;
        return (usd18 + 1e12 - 1) / 1e12;
    }

    /// @dev System ratio at `price` from state vars, 1e18. Caller ensures debt > 0.
    function _tcr(CopraManagerV2 m, uint256 price) internal view returns (uint256) {
        return (m.totalColl() * 1e18) / _valueUp(m.totalDebt(), price);
    }

    /// @dev A twin manager with identical v0.2 parameters (fresh token, shared pool assets).
    function _twinManager() internal returns (CopraManagerV2 twin) {
        twin = new CopraManagerV2(
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
    }

    function _approveTwin(address who, CopraManagerV2 twin) internal {
        vm.startPrank(who);
        collateral.approve(address(twin), type(uint256).max);
        CopraTokenV2(twin.copraToken()).approve(address(twin), type(uint256).max);
        vm.stopPrank();
    }

    function _mintPositionOn(CopraManagerV2 m, address who, uint256 debt, uint256 coll) internal returns (uint256 id) {
        vm.startPrank(who);
        id = m.open();
        m.deposit(id, coll);
        m.mint(id, debt);
        vm.stopPrank();
    }

    /// @dev Sums realized (coll, debt) over positions [0, n), skipping deleted ones.
    function _sums(CopraManagerV2 m, uint256 n) internal view returns (uint256 c, uint256 d, uint256 open) {
        for (uint256 i; i < n; ++i) {
            (address owner, uint256 coll, uint256 debt) = m.positionOf(i);
            if (owner == address(0)) continue;
            c += coll;
            d += debt;
            ++open;
        }
    }

    /// @dev Invariants 2/3 at the position level. Debt scale accounting rounds down
    ///      (§3), so realized sums never exceed the totals — the direction that keeps
    ///      every position repayable. The debt gap is bounded by the pre-shrink debt
    ///      over 1e18 (one scale unit over the outstanding bases) plus count dust;
    ///      with virgin scales and no redistribution both sums are exact.
    function _assertSums(CopraManagerV2 m, uint256 n, uint256 debtCap) internal view {
        (uint256 c, uint256 d, uint256 open) = _sums(m, n);
        assertLe(d, m.totalDebt(), "sum debt exceeds total");
        assertLe(c, m.totalColl(), "sum coll exceeds total");
        if (m.debtScale() == 1e18 && m.collScale() == 1e18 && m.redist() == 0) {
            assertEq(d, m.totalDebt(), "virgin debt exact");
            assertEq(c, m.totalColl(), "virgin coll exact");
        }
        assertLe(m.totalDebt() - d, debtCap / 1e18 + 3 * (open + 1) + 1, "sum debt gap");
        assertLe(m.totalColl() - c, 2 * (open + 1) + 1, "sum coll gap");
    }

    function _sel(bytes memory err) internal pure returns (bytes4 sel) {
        if (err.length < 4) return 0xffffffff;
        assembly {
            sel := mload(add(err, 32))
        }
    }

    // ------------------------------------------------------------------------
    // Invariant 1: the mint gate admits exactly positions at MCR after the fee.
    // ------------------------------------------------------------------------

    /// @dev Fuzzes collateral and debt across a wide range and a boundary band around
    ///      the estimated maximum: success must imply MCR-after, and every revert must
    ///      be the gate the inputs deserve.
    function testFuzz_MintGate_AdmitsIffMCR(uint256 collSeed, uint256 debtSeed, uint8 mode) public {
        _finalize(PRICE, Status.VALID);
        (bool ok, uint256 price,) = manager.usablePrice();
        assertTrue(ok);
        uint256 coll = bound(collSeed, 1e6, 1e12); // $1 to $1M
        _fund(ALICE, coll);
        vm.prank(ALICE);
        uint256 id = manager.open();
        vm.prank(ALICE);
        manager.deposit(id, coll);

        // Floor estimate of the maximum mint (fee ignored): the boundary band straddles it.
        uint256 est = (coll * 10_000 * 1e8 * 1e12) / (uint256(MCR) * price);
        uint256 debt = mode % 2 == 0
            ? bound(debtSeed, 1, 3 * est + MIN_DEBT)
            : bound(debtSeed, (est * 95) / 100, (est * 105) / 100 + 10);

        uint256 fee = (_valueUp(debt, price) * MINT_FEE + 9_999) / 10_000;
        bytes4 want;
        if (debt < MIN_DEBT) {
            want = CopraManagerV2.BelowMinDebt.selector;
        } else if (fee > coll) {
            want = CopraManagerV2.InsufficientCollateral.selector;
        } else if ((coll - fee) * 10_000 < uint256(MCR) * _valueUp(debt, price)) {
            want = CopraManagerV2.BelowMCR.selector;
        }

        vm.prank(ALICE);
        try manager.mint(id, debt) {
            assertEq(want, bytes4(0), "gate admitted a mint it should reject");
            (, uint256 collAfter, uint256 debtAfter) = manager.positionOf(id);
            assertGe(collAfter * 10_000, uint256(MCR) * _valueUp(debtAfter, price), "inv1");
        } catch (bytes memory err) {
            assertEq(_sel(err), want, "wrong gate");
            assertTrue(want != bytes4(0), "gate rejected a mint it should admit");
        }
        _assertConserved();
        _assertSums(manager, 1, manager.totalDebt());
    }

    // ------------------------------------------------------------------------
    // Invariants 2/3: conservation under deposit/mint/repay/withdraw/close.
    // ------------------------------------------------------------------------

    function testFuzz_Ops_ConservationExact(
        uint256 c1Seed,
        uint256 d1Seed,
        uint256 c2Seed,
        uint256 d2Seed,
        uint256 rSeed,
        uint256 wSeed
    ) public {
        _finalize(PRICE, Status.VALID);
        // $500 floors: est >= MIN_DEBT there, so the debt bounds are well-formed.
        uint256 c1 = bound(c1Seed, 500e6, 100_000e6);
        uint256 c2 = bound(c2Seed, 500e6, 100_000e6);
        uint256 est1 = (c1 * 10_000 * 1e8 * 1e12) / (uint256(MCR) * PRICE);
        uint256 est2 = (c2 * 10_000 * 1e8 * 1e12) / (uint256(MCR) * PRICE);
        uint256 d1 = bound(d1Seed, MIN_DEBT, (est1 * 12) / 10);
        uint256 d2 = bound(d2Seed, MIN_DEBT, (est2 * 12) / 10);
        _fund(ALICE, c1);
        _fund(BOB, c2);

        vm.prank(ALICE);
        uint256 a = manager.open();
        vm.prank(ALICE);
        manager.deposit(a, c1);
        vm.prank(ALICE);
        try manager.mint(a, d1) {}
        catch (bytes memory err) {
            assertEq(_sel(err), CopraManagerV2.BelowMCR.selector, "alice mint gate");
        }
        vm.prank(BOB);
        uint256 b = manager.open();
        vm.prank(BOB);
        manager.deposit(b, c2);
        vm.prank(BOB);
        try manager.mint(b, d2) {}
        catch (bytes memory err) {
            assertEq(_sel(err), CopraManagerV2.BelowMCR.selector, "bob mint gate");
        }
        _assertConserved();
        _assertSums(manager, 2, manager.totalDebt());

        (,, uint256 debtA) = manager.positionOf(a);
        if (debtA > 0) {
            uint256 r = bound(rSeed, 1, debtA * 2);
            vm.prank(ALICE);
            try manager.repay(a, r) {}
            catch (bytes memory err) {
                assertEq(_sel(err), CopraManagerV2.OverRepayment.selector, "repay gate");
            }
            _assertConserved();
            _assertSums(manager, 2, manager.totalDebt());
        }
        (, uint256 collB,) = manager.positionOf(b);
        if (collB > 0) {
            uint256 w = bound(wSeed, 1, collB * 2);
            vm.prank(BOB);
            try manager.withdraw(b, w) {}
            catch (bytes memory err) {
                bytes4 sel = _sel(err);
                assertTrue(
                    sel == CopraManagerV2.InsufficientCollateral.selector || sel == CopraManagerV2.BelowMCR.selector,
                    "withdraw gate"
                );
            }
            _assertConserved();
            _assertSums(manager, 2, manager.totalDebt());
        }

        // Each owner holds exactly their position's debt, so both closes succeed.
        vm.prank(ALICE);
        manager.close(a);
        vm.prank(BOB);
        manager.close(b);
        _assertConserved();
        _assertSums(manager, 2, manager.totalDebt());
    }

    // ------------------------------------------------------------------------
    // Invariant 7: equal treatment within one settlement, at any price.
    // ------------------------------------------------------------------------

    /// @dev Two requests settle together from deep discount to full pay: per-unit
    ///      payouts match within flooring, conservation stays exact, and the system
    ///      ratio never drops by more than one unit.
    function testFuzz_Redemption_ProRata(uint256 debtSeed, uint256 reqSeed, uint256 priceSeed) public {
        _finalize(PRICE, Status.VALID);
        uint256 coll = 5_000e6;
        uint256 est = (coll * 10_000 * 1e8 * 1e12) / (uint256(MCR) * PRICE);
        uint256 debt = bound(debtSeed, MIN_DEBT, (est * 9) / 10);
        _fund(ALICE, coll);
        _fund(BOB, coll);
        _mintPosition(ALICE, debt, coll);
        _mintPosition(BOB, debt, coll);

        uint256 r1 = bound(reqSeed, 1, debt - 50e18);
        uint256 r2 = bound(uint256(keccak256(abi.encode(reqSeed))), 1, debt - 50e18);
        vm.prank(ALICE);
        uint256 q1 = manager.requestRedeem(r1);
        vm.prank(BOB);
        uint256 q2 = manager.requestRedeem(r2);
        uint256 p1 = bound(priceSeed, 1e7, 1e9); // $0.10 to $10: full pay into haircut
        _finalize(PRICE, Status.VALID); // id 1: before k+1, never the settle period
        _finalize(p1, Status.VALID); // id 2: the settle period
        uint256 tcrBefore = _tcr(manager, p1);

        uint256 balA = collateral.balanceOf(ALICE);
        uint256 balB = collateral.balanceOf(BOB);
        uint256[] memory ids = new uint256[](2);
        ids[0] = q1;
        ids[1] = q2;
        uint256 debtCap = manager.totalDebt();
        manager.settle(ids);
        uint256 s1 = collateral.balanceOf(ALICE) - balA;
        uint256 s2 = collateral.balanceOf(BOB) - balB;

        // share_i = floor(r_i * payout / (r1+r2)): cross-multiplied within r1+r2.
        uint256 cross = s1 > 0 && r2 > 0 ? s1 * r2 : 0;
        uint256 cross2 = s2 > 0 && r1 > 0 ? s2 * r1 : 0;
        assertLe(cross > cross2 ? cross - cross2 : cross2 - cross, r1 + r2, "inv7");
        _assertConserved();
        _assertSums(manager, 2, debtCap);
        assertGe(_tcr(manager, p1) + 1, tcrBefore, "tcr non-decreasing");
    }

    // ------------------------------------------------------------------------
    // Invariant 6: no redemption settles at a pre-request price.
    // ------------------------------------------------------------------------

    /// @dev Requests in various periods settle only after uncovered (skipped) periods
    ///      at the first VALID price, which must equal the fuzzed input price.
    function testFuzz_ForwardPrice_SettlesAfterRequest(
        uint256 kSeed,
        uint256 skipSeed,
        uint256 reqSeed,
        uint256 priceSeed
    ) public {
        _finalize(PRICE, Status.VALID);
        _fund(ALICE, 5_000e6);
        uint256 id = _mintPosition(ALICE, 1000e18, 5_000e6);

        uint256 k = bound(kSeed, 1, 3);
        _enterPeriod(k);
        uint256 req = bound(reqSeed, 100e18, 900e18);
        vm.prank(ALICE);
        uint256 q = manager.requestRedeem(req);

        // k uncovered periods align the settle id past k, plus fuzzed extra skips.
        uint256 skips = bound(skipSeed, 0, 2);
        for (uint256 i; i < k + skips; ++i) {
            _finalize(0, Status.INSUFFICIENT_COVERAGE);
        }
        uint256 p1 = bound(priceSeed, 1e7, 1e9);
        uint256 settleId = _finalize(p1, Status.VALID);

        (bool found, uint256 s, uint256 p) = gcpi.firstValidAtOrAfter(k + 1, 10);
        assertTrue(found);
        assertEq(s, settleId, "first VALID after the gaps");
        assertGe(s, k + 1, "inv6");
        assertEq(p, p1, "settle price is the input price");
        (bool ok, uint256 s2, uint256 p2) = manager.settleable(q);
        assertTrue(ok);
        assertEq(s2, s);
        assertEq(p2, p1);

        uint256[] memory ids = new uint256[](1);
        ids[0] = q;
        uint256 debtCap = manager.totalDebt();
        manager.settle(ids);
        (,,,, bool pending) = manager.requestOf(q);
        assertFalse(pending);
        _assertConserved();
        _assertSums(manager, id + 1, debtCap);
    }

    // ------------------------------------------------------------------------
    // Invariant 7 across rigs: settlement is independent of input order.
    // ------------------------------------------------------------------------

    /// @dev The same two requests settle as [0,1] on the main rig and [1,0] on an
    ///      identical twin: per-user payouts and all end state must match exactly,
    ///      including across a full-supply epoch (both rigs open one together).
    function testFuzz_Settle_OrderIndependent(uint256 reqSeed, uint256 priceSeed) public {
        CopraManagerV2 twin = _twinManager();
        _finalize(PRICE, Status.VALID);
        _fund(ALICE, 10_000e6);
        _fund(BOB, 6_000e6);
        _approveTwin(ALICE, twin);
        _approveTwin(BOB, twin);
        _mintPosition(ALICE, 300e18, 5_000e6);
        _mintPosition(BOB, 200e18, 3_000e6);
        _mintPositionOn(twin, ALICE, 300e18, 5_000e6);
        _mintPositionOn(twin, BOB, 200e18, 3_000e6);

        uint256 r1 = bound(reqSeed, 1, 300e18);
        uint256 r2 = bound(uint256(keccak256(abi.encode(reqSeed))), 1, 200e18);
        vm.prank(ALICE);
        manager.requestRedeem(r1);
        vm.prank(BOB);
        manager.requestRedeem(r2);
        vm.prank(ALICE);
        twin.requestRedeem(r1);
        vm.prank(BOB);
        twin.requestRedeem(r2);
        _finalize(PRICE, Status.VALID); // id 1: before k+1, never the settle period
        _finalize(bound(priceSeed, 1e7, 1e9), Status.VALID); // id 2: the settle period

        uint256[] memory fwd = new uint256[](2);
        fwd[0] = 0;
        fwd[1] = 1;
        uint256[] memory rev = new uint256[](2);
        rev[0] = 1;
        rev[1] = 0;
        uint256 balA = collateral.balanceOf(ALICE);
        uint256 balB = collateral.balanceOf(BOB);
        manager.settle(fwd);
        uint256 payA = collateral.balanceOf(ALICE) - balA;
        uint256 payB = collateral.balanceOf(BOB) - balB;
        balA = collateral.balanceOf(ALICE);
        balB = collateral.balanceOf(BOB);
        twin.settle(rev);
        assertEq(collateral.balanceOf(ALICE) - balA, payA, "alice order-independent");
        assertEq(collateral.balanceOf(BOB) - balB, payB, "bob order-independent");

        assertEq(twin.totalDebt(), manager.totalDebt(), "debt");
        assertEq(twin.totalColl(), manager.totalColl(), "coll");
        assertEq(twin.protocolFees(), manager.protocolFees(), "fees");
        assertEq(twin.settleReserve(), manager.settleReserve(), "reserve");
        assertEq(twin.debtScale(), manager.debtScale(), "debt scale");
        assertEq(twin.collScale(), manager.collScale(), "coll scale");
        assertEq(twin.redist(), manager.redist(), "redist");
        assertEq(twin.epoch(), manager.epoch(), "epoch");
        _assertConserved();
        _assertConservedOn(twin);
    }

    // ------------------------------------------------------------------------
    // Adversarial bad debt: liquidation conserves, survivors only gain debt.
    // ------------------------------------------------------------------------

    /// @dev A price spike pushes a tightly-collateralized position under LR (or not);
    ///      full liquidation must conserve exactly (Invariants 2/3), keep position sums
    ///      within dust, and never reduce the survivor's debt. With one position the
    ///      husk keeps the bad debt instead.
    function testFuzz_BadDebt_Adversarial(uint256 nSeed, uint256 priceSeed) public {
        _finalize(PRICE, Status.VALID);
        uint256 bobColl = 10_000e6;
        uint256 est = (bobColl * 10_000 * 1e8 * 1e12) / (uint256(MCR) * PRICE);
        uint256 bobDebt = (est * 95) / 100;
        _fund(ALICE, 1_000_000e6);
        _fund(BOB, bobColl);
        uint256 nPos = bound(nSeed, 1, 2);
        uint256 aliceDebt = bobDebt * 2;
        uint256 aliceId;
        if (nPos == 2) aliceId = _mintPosition(ALICE, aliceDebt, 1_000_000e6);
        uint256 bobId = _mintPosition(BOB, bobDebt, bobColl);

        uint256 p1 = bound(priceSeed, 15e7, 3e9); // $1.50 (safe) to $30 (deep water)
        _finalize(p1, Status.VALID);
        (,, uint256 aliceBefore) = nPos == 2 ? manager.positionOf(aliceId) : (address(0), 0, 0);

        vm.prank(BOB);
        try manager.liquidate(bobId, type(uint256).max) {
            _assertConserved();
            _assertSums(manager, bobId + 1, manager.totalDebt());
            if (nPos == 2) {
                (,, uint256 aliceAfter) = manager.positionOf(aliceId);
                assertGe(aliceAfter, aliceBefore, "survivor debt monotonic");
            } else {
                // Sole position: the husk keeps the bad debt with no collateral.
                (, uint256 huskColl, uint256 huskDebt) = manager.positionOf(bobId);
                if (huskDebt > 0) assertEq(huskColl, 0, "husk has no collateral");
            }
        } catch (bytes memory err) {
            assertEq(_sel(err), CopraManagerV2.NotLiquidatable.selector, "liq gate");
            _assertConserved();
            _assertSums(manager, bobId + 1, manager.totalDebt());
        }
    }
}
