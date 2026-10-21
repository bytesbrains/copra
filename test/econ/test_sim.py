# Run with: python3 -m unittest discover -s test/econ
# econ/sim.py (#96): the COPRA-001 mechanism on synthetic prices whose answers are
# known by hand. Floats throughout; consensus arithmetic is #97's problem.
import os
import sys
import unittest

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
sys.path.insert(0, os.path.join(ROOT, "econ"))
import sim  # noqa: E402


def state(**kw):
    p = sim.Params(**kw)
    return sim.State(p)


class Liquidation(unittest.TestCase):
    def test_fully_covered_position_liquidates_with_bonus(self):
        st = state(lr=1.75, liq_bonus=0.05, gas_usd=2.0, min_debt=1.0)
        sim.add_position(st, 150.0, 100.0)
        r = sim.liquidate(st, 1.0)
        self.assertEqual(r["count"], 1)
        self.assertAlmostEqual(r["repaid"], 100.0)
        self.assertAlmostEqual(r["seized"], 105.0)
        self.assertAlmostEqual(st.positions[0].c, 45.0)
        self.assertAlmostEqual(st.positions[0].d, 0.0)

    def test_safe_position_is_left_alone(self):
        st = state(lr=1.75)
        sim.add_position(st, 200.0, 100.0)
        r = sim.liquidate(st, 1.0)
        self.assertEqual(r["count"], 0)
        self.assertAlmostEqual(st.positions[0].c, 200.0)

    def test_bad_debt_redistributes_in_proportion_to_collateral(self):
        st = state(lr=1.75, liq_bonus=0.05, gas_usd=0.0, min_debt=1.0)
        sim.add_position(st, 90.0, 100.0)    # bad debt at P=1
        sim.add_position(st, 300.0, 100.0)   # healthy, three times the collateral...
        sim.add_position(st, 100.0, 50.0)    # ...of this one
        r = sim.liquidate(st, 1.0)
        x = 90.0 / 1.05
        self.assertAlmostEqual(r["repaid"], x)
        self.assertAlmostEqual(r["seized"], 90.0)
        bad = 100.0 - x
        self.assertAlmostEqual(r["redistributed"], bad)
        # 300:100 collateral split of the bad debt.
        self.assertAlmostEqual(st.positions[1].d, 100.0 + bad * 0.75)
        self.assertAlmostEqual(st.positions[2].d, 50.0 + bad * 0.25)
        self.assertAlmostEqual(st.positions[0].c, 0.0)
        # The redistributed debt leaves the husk: no debt is created.
        self.assertAlmostEqual(st.positions[0].d, 0.0)
        c, d = sim.totals(st)
        self.assertAlmostEqual(d, 250.0 - x)

    def test_dust_the_bonus_cannot_pay_for_is_not_liquidated(self):
        st = state(lr=1.75, liq_bonus=0.05, gas_usd=2.0, min_debt=1.0)
        sim.add_position(st, 15.0, 10.0)  # bonus $0.50 against $2 gas
        r = sim.liquidate(st, 1.0)
        self.assertEqual(r["count"], 0)
        self.assertAlmostEqual(st.positions[0].d, 10.0)
        self.assertEqual(r["unliq_count"], 1)

    def test_dust_does_not_block_a_profitable_liquidation_behind_it(self):
        st = state(lr=1.75, liq_bonus=0.05, gas_usd=2.0, min_debt=1.0)
        sim.add_position(st, 15.0, 10.0)  # dust first
        sim.add_position(st, 150.0, 100.0)
        r = sim.liquidate(st, 1.0)
        self.assertEqual(r["count"], 1)
        self.assertEqual(r["unliq_count"], 1)
        self.assertAlmostEqual(st.positions[1].d, 0.0)


class Redemption(unittest.TestCase):
    def test_proportional_split_and_fee(self):
        st = state(redeem_fee=0.01)
        sim.add_position(st, 300.0, 100.0)
        sim.add_position(st, 300.0, 100.0)
        pay = sim.settle_request(st, sim.Request(40.0, 0), 2.0)
        # Gross 80, fee 0.80, payout 79.20; each position loses 20 debt, 39.60.
        self.assertAlmostEqual(pay, 79.20)
        for pos in st.positions:
            self.assertAlmostEqual(pos.d, 80.0)
            self.assertAlmostEqual(pos.c, 300.0 - 39.60)
            self.assertAlmostEqual(pos.fee_kept, 0.40)

    def test_proportional_redemption_raises_ratios(self):
        st = state(redeem_fee=0.01)
        a = sim.add_position(st, 300.0, 100.0)
        before = sim.cr(a, 2.0)
        sim.settle_request(st, sim.Request(40.0, 0), 2.0)
        self.assertGreater(sim.cr(a, 2.0), before)

    def test_lowest_first_redeems_the_riskiest_position_first(self):
        st = state(redeem_fee=0.0, allocation="lowest_first")
        sim.add_position(st, 150.0, 100.0)  # CR 1.5 at P=1
        sim.add_position(st, 300.0, 100.0)  # CR 3.0
        sim.settle_request(st, sim.Request(100.0, 0), 1.0)
        risky, safe = st.positions
        self.assertAlmostEqual(risky.d, 0.0)
        self.assertAlmostEqual(risky.c, 50.0)
        self.assertAlmostEqual(safe.d, 100.0)
        self.assertAlmostEqual(safe.c, 300.0)

    def test_proportional_cover_failure_redistributes_the_remainder(self):
        st = state(redeem_fee=0.0, min_debt=1.0)
        sim.add_position(st, 1000.0, 100.0)
        sim.add_position(st, 5.0, 100.0)  # underwater dust settlement found
        st.bad_debt_usd = 0.0
        sim.settle_request(st, sim.Request(100.0, 0), 1.0)
        self.assertEqual(len(st.positions), 1)
        healthy = st.positions[0]
        # Dust covered 5 of its 50 share; 45 plus its 50 leftover redistribute.
        self.assertAlmostEqual(healthy.d, 50.0 + 95.0)
        self.assertAlmostEqual(healthy.c, 950.0)
        self.assertAlmostEqual(st.bad_debt_usd, 95.0)

    def test_collateral_prop_takes_debt_by_debt_and_collateral_by_collateral(self):
        st = state(redeem_fee=0.0, allocation="collateral_prop", min_debt=1.0)
        sim.add_position(st, 300.0, 100.0)
        sim.add_position(st, 100.0, 100.0)
        sim.settle_request(st, sim.Request(100.0, 0), 1.0)
        safe, weak = st.positions
        self.assertAlmostEqual(safe.d, 50.0)
        self.assertAlmostEqual(safe.c, 225.0)
        self.assertAlmostEqual(weak.d, 50.0)
        self.assertAlmostEqual(weak.c, 75.0)

    def test_collateral_prop_covers_every_position_in_shortfall(self):
        st = state(redeem_fee=0.0, allocation="collateral_prop", min_debt=1.0)
        sim.add_position(st, 60.0, 100.0)
        sim.add_position(st, 60.0, 100.0)  # TCR 0.6 at P=1
        pay = sim.settle_request(st, sim.Request(100.0, 0), 1.0)
        self.assertAlmostEqual(pay, 60.0)
        self.assertAlmostEqual(st.bad_debt_usd, 0.0)
        for pos in st.positions:
            self.assertAlmostEqual(pos.d, 50.0)
            self.assertAlmostEqual(pos.c, 30.0)
            self.assertGreaterEqual(pos.c, 0.0)

    def test_shortfall_pays_pro_rata_and_equal_per_unit(self):
        st = state(redeem_fee=0.0)
        sim.add_position(st, 150.0, 100.0)
        sim.add_position(st, 150.0, 100.0)  # TCR 0.75 at P=2
        p1 = sim.settle_request(st, sim.Request(10.0, 0), 2.0)
        p2 = sim.settle_request(st, sim.Request(30.0, 0), 2.0)
        self.assertAlmostEqual(p1 / 10.0, p2 / 30.0)
        self.assertAlmostEqual(p1, 10.0 * 2.0 * 0.75)

    def test_settlement_uses_the_first_valid_period_at_or_after_k_plus_1(self):
        st = state(lag=1)
        st.finalized = {4: 1.0, 5: None, 6: 1.5}  # month 5 non-valid
        self.assertEqual(sim.settlement_period(st, sim.Request(1.0, 4), 99), 6)
        self.assertEqual(sim.settlement_period(st, sim.Request(1.0, 3), 99), 4)
        self.assertIsNone(sim.settlement_period(st, sim.Request(1.0, 6), 99))

    def test_request_in_k_never_settles_at_k(self):
        st = state(lag=1)
        st.finalized = {4: 1.0}
        self.assertIsNone(sim.settlement_period(st, sim.Request(1.0, 4), 99))

    def test_partial_fill_pays_only_the_debt_actually_settled(self):
        st = state(redeem_fee=0.0, min_debt=1.0)
        sim.add_position(st, 1000.0, 100.0)
        pay = sim.settle_request(st, sim.Request(1000.0, 0), 1.0)
        # Only 100 of debt exists: the payout is on the 100 settled, not scaled
        # up to the 1000 requested, and the position is emptied.
        self.assertAlmostEqual(pay, 100.0)
        self.assertAlmostEqual(sim.totals(st)[1], 0.0)
        self.assertAlmostEqual(sim.totals(st)[0], 900.0)

    def test_step_records_settled_debt_not_requested_debt(self):
        st = state(lag=2, min_debt=1.0)
        sim.add_position(st, 1000.0, 100.0)
        st.finalized = {1: 2.0}
        st.pending.append(sim.Request(1000.0, 0))  # settles at month 1
        rec = sim.step(st, 3, None, True, lambda w, p, s: 0.0)
        self.assertEqual(rec["settled_n"], 1)
        self.assertAlmostEqual(rec["settled_amt"], 100.0)
        # Gross 200, fee 1.00, payout 199.00 — on the 100 settled.
        self.assertAlmostEqual(rec["settled_pay"], 199.0)

    def test_proportional_cover_does_not_depend_on_position_order(self):
        def run(order):
            st = state(redeem_fee=0.0, min_debt=1.0)
            for c, d in order:
                sim.add_position(st, c, d)
            pay = sim.settle_request(st, sim.Request(100.0, 0), 1.0)
            return pay, sorted((p.c, p.d) for p in st.positions), st.bad_debt_usd
        dust_first = run([(5.0, 100.0), (1000.0, 100.0)])
        dust_last = run([(1000.0, 100.0), (5.0, 100.0)])
        self.assertEqual(dust_first, dust_last)
        pay, ((c, d),), bad = dust_first
        # Pins the covered outcome: dust covers 5 of its 50 share; the rest
        # (45 uncovered + 50 leftover) redistributes onto the healthy position.
        self.assertAlmostEqual(pay, 100.0)
        self.assertAlmostEqual(c, 950.0)
        self.assertAlmostEqual(d, 145.0)
        self.assertAlmostEqual(bad, 95.0)


class Maintainer(unittest.TestCase):
    def test_tops_up_to_mcr_after_the_delay(self):
        st = state(mcr=2.0, lr=1.5, lag=1, topup_trigger=1.1, topup_delay=1,
                   min_debt=1.0)
        sim.add_position(st, 200.0, 100.0)
        st.finalized = {0: 1.0}
        rec = sim.step(st, 2, 1.2, True, lambda w, p, s: 0.0)
        # CR 1.667 < 2.2 at the usable price 1.2: topped to 2.0.
        self.assertAlmostEqual(rec["topups"], 40.0)
        self.assertAlmostEqual(st.positions[0].c, 240.0)

    def test_takes_profit_above_the_buffer(self):
        st = state(mcr=2.0, lr=1.5, lag=1, withdraw_buffer=1.3, min_debt=1.0)
        sim.add_position(st, 300.0, 100.0)
        st.finalized = {0: 1.0}
        rec = sim.step(st, 2, 1.0, True, lambda w, p, s: 0.0)
        # CR 3.0 > 2.6: withdrawn down to 2.6.
        self.assertAlmostEqual(rec["profit_taken"], 40.0)
        self.assertAlmostEqual(st.positions[0].c, 260.0)

    def test_no_profit_taking_in_shortfall(self):
        st = state(mcr=2.0, lr=1.5, lag=1, withdraw_buffer=1.3, min_debt=1.0)
        sim.add_position(st, 300.0, 100.0)
        sim.add_position(st, 10.0, 100.0)
        sim.add_position(st, 10.0, 200.0)  # TCR = 320/400 = 0.8: shortfall
        st.finalized = {0: 1.0}
        rec = sim.step(st, 2, 1.0, True, lambda w, p, s: 0.0)
        self.assertTrue(rec["shortfall"])
        self.assertAlmostEqual(rec["profit_taken"], 0.0)

    def test_liquidation_float_is_measured_against_start_of_step_supply(self):
        st = state(mcr=2.0, lr=1.75, lag=1, gas_usd=0.0, min_debt=1.0)
        sim.add_position(st, 150.0, 100.0)
        sim.add_position(st, 150.0, 100.0)
        st.finalized = {0: 1.0}
        rec = sim.step(st, 2, 1.0, True, lambda w, p, s: 0.0)
        self.assertEqual(rec["liq_count"], 2)
        self.assertAlmostEqual(rec["supply_before"], 200.0)
        self.assertAlmostEqual(rec["liq_repaid"] / rec["supply_before"], 1.0)


class MinterReturns(unittest.TestCase):
    def test_mint_records_sale_proceeds_and_the_multiple_counts_them(self):
        st = state(min_debt=1.0)
        sim.genesis(st, 100.0, 1, 2.0, 2.0, 1.0)
        self.assertAlmostEqual(st.proceeds[0], 100.0)
        got = sim.cohort_returns(st, 1.0)[0]
        # Flat price, no flows: deposits 200, equity 100, proceeds 100.
        self.assertAlmostEqual(got["multiple"], 1.0)

    def test_short_gains_when_the_price_falls(self):
        st = state(min_debt=1.0)
        sim.genesis(st, 100.0, 1, 2.0, 2.0, 1.0)
        got = sim.cohort_returns(st, 0.5)[0]
        # Equity 200 - 50 = 150, proceeds 100, deposits 200.
        self.assertAlmostEqual(got["multiple"], 1.25)


class States(unittest.TestCase):
    def test_no_liquidation_without_a_usable_price(self):
        st = state(lr=1.75, lag=2, max_price_age=1)
        sim.add_position(st, 150.0, 100.0)
        st.finalized = {0: 1.0, 1: None, 2: None}  # outage since month 1
        # Latest VALID is month 0, finalized at wall 2; at wall 4 its age is 2 > 1.
        self.assertIsNone(sim.usable_price(st, 4))
        rec = sim.step(st, 4, None, False, lambda w, p, s: 0.0)
        self.assertIsNone(rec["price"])
        self.assertEqual(rec["liq_count"], 0)

    def test_priceless_request_cancels_at_expiry(self):
        st = state(lag=1, max_price_age=10, redeem_expiry=3)
        sim.add_position(st, 1000.0, 100.0)
        st.pending.append(sim.Request(10.0, 0))
        rec = sim.step(st, 3, None, False, lambda w, p, s: 0.0)
        self.assertEqual(len(st.pending), 0)
        self.assertEqual(rec["settled_n"], 0)


class Accounting(unittest.TestCase):
    def test_usd_and_copra_are_conserved_over_a_scripted_run(self):
        st = state(mcr=2.0, lr=1.5, liq_bonus=0.05, redeem_fee=0.01, lag=1,
                   gas_usd=0.0)
        sim.genesis(st, 1000.0, 4, 2.0, 3.0, 1.0)
        prices = [1.0, 1.3, 1.6, 1.2, 0.9, 1.1]
        pay_out, seized, repaid, settled = 0.0, 0.0, 0.0, 0.0
        for wall in range(len(prices) + 1):
            fin = wall - 1
            ref = prices[fin] if 0 <= fin < len(prices) else None
            rec = sim.step(st, wall, ref, True,
                           lambda w, p, s: 5.0 if w in (1, 2) else 0.0)
            pay_out += rec["settled_pay"]
            seized += rec["liq_seized"]
            repaid += rec["liq_repaid"]
            settled += rec["settled_amt"]
        c, d = sim.totals(st)
        dep = sum(st.deposits.values())
        wd = sum(st.withdrawals.values())
        # Every deposited dollar is in positions, paid to redeemers or liquidators,
        # or withdrawn by owners.
        self.assertAlmostEqual(dep, c + pay_out + seized + wd, places=6)
        # Every minted $COPRA is debt, settled, or liquidated.
        self.assertAlmostEqual(1000.0, d + settled + repaid, places=6)

    def test_zero_debt_leftover_is_withdrawn_not_stranded(self):
        st = state(mcr=2.0, lr=1.5, redeem_fee=0.0, lag=1, gas_usd=0.0)
        sim.add_position(st, 150.0, 100.0)
        st.finalized = {0: 1.0}
        st.pending.append(sim.Request(100.0, -1))  # settles at month 0
        rec = sim.step(st, 2, None, False, lambda w, p, s: 0.0)
        self.assertEqual(rec["settled_n"], 1)
        self.assertAlmostEqual(rec["withdrawn"], 50.0)
        self.assertEqual(len(st.positions), 0)


if __name__ == "__main__":
    unittest.main()
