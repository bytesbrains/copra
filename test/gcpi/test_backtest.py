# Run with: python3 -m unittest discover -s test/gcpi
# gcpi/backtest/backtest.py (#88): the aggregation, risk and data-quality functions the report's
# numbers come from, on synthetic series whose answers are known.
import math
import os
import sys
import unittest

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
sys.path.insert(0, os.path.join(ROOT, "gcpi", "backtest"))
import backtest as bt  # noqa: E402

MONTHS = bt.ym_range("2020-01", "2020-12")


def flat(level, months=MONTHS):
    return {m: level for m in months}


class Months(unittest.TestCase):
    def test_month_arithmetic(self):
        self.assertEqual(bt.ym_add("2025-12", 1), "2026-01")
        self.assertEqual(bt.ym_add("2026-01", -1), "2025-12")
        self.assertEqual(bt.ym_add("2026-03", -15), "2024-12")
        self.assertEqual(len(bt.ym_range("2024-11", "2025-02")), 4)

    def test_log_changes_only_between_adjacent_months(self):
        s = {"2020-01": 1.0, "2020-02": 2.0, "2020-04": 4.0}
        self.assertEqual(bt.log_changes(s), {"2020-02": math.log(2)})

    def test_longest_gap(self):
        s = {m: 1.0 for m in MONTHS if m not in ("2020-03", "2020-04", "2020-08")}
        self.assertEqual(bt.longest_gap(s, "2020-01", "2020-12"), 2)


class Aggregation(unittest.TestCase):
    # A cheap market at 1.0 and a dear one at 3.0, neither moving. The cheap one is missing in June.
    panel = {"cheap": {m: 1.0 for m in MONTHS if m != "2020-06"}, "dear": flat(3.0)}
    weights = {"cheap": 0.5, "dear": 0.5}

    def test_renormalization_jumps_when_a_market_with_a_spread_drops_out(self):
        # GCPI-001 §8.4's warning: no price moved, yet the index rises 50% for one month.
        idx = bt.renormalized(self.panel, self.weights, MONTHS)
        self.assertAlmostEqual(idx["2020-05"], 2.0)
        self.assertAlmostEqual(idx["2020-06"], 3.0)
        self.assertAlmostEqual(idx["2020-07"], 2.0)

    def test_chain_linking_does_not(self):
        idx = bt.chain_linked(self.panel, self.weights, MONTHS)
        for m in MONTHS:
            self.assertAlmostEqual(idx[m], 2.0, msg=m)

    def test_chain_links_across_a_month_with_no_market(self):
        panel = {"a": {"2020-01": 1.0, "2020-02": 1.1, "2020-04": 1.21}}
        idx = bt.chain_linked(panel, {"a": 1.0}, bt.ym_range("2020-01", "2020-04"))
        self.assertNotIn("2020-03", idx)
        self.assertAlmostEqual(idx["2020-04"], 1.21)

    def test_zero_weight_markets_are_ignored(self):
        panel = {"a": {"2020-01": 1.0, "2020-02": 1.0}, "b": {"2020-01": 5.0, "2020-02": 50.0}}
        idx = bt.chain_linked(panel, {"a": 1.0, "b": 0.0}, ["2020-01", "2020-02"])
        self.assertAlmostEqual(idx["2020-02"], 1.0)
        self.assertEqual(bt.renormalized(panel, {"a": 1.0, "b": 0.0}, ["2020-02"])["2020-02"], 1.0)

    def test_chain_link_moves_by_the_weighted_log_change(self):
        panel = {"a": {"2020-01": 1.0, "2020-02": 2.0}, "b": {"2020-01": 1.0, "2020-02": 1.0}}
        idx = bt.chain_linked(panel, {"a": 0.5, "b": 0.5}, ["2020-01", "2020-02"])
        self.assertAlmostEqual(idx["2020-02"], math.sqrt(2))

    def test_outage_effect_separates_jump_from_drift(self):
        months = bt.ym_range("2018-01", "2021-12")
        panel = {"cheap": flat(1.0, months), "dear": flat(3.0, months)}
        out = bt.outage_effect(panel, {"cheap": 0.5, "dear": 0.5}, months, "cheap", 2)
        self.assertAlmostEqual(out["renormalized"]["during"], math.log(1.5))
        self.assertAlmostEqual(out["renormalized"]["after_12m"], 0.0)
        self.assertAlmostEqual(out["chain_linked"]["during"], 0.0)


class Risk(unittest.TestCase):
    def test_quantile(self):
        self.assertEqual(bt.quantile([1, 2, 3, 4, 5], 0.5), 3)
        self.assertAlmostEqual(bt.quantile([0, 10], 0.95), 9.5)

    def test_r_of_h(self):
        s = {m: 1.0 for m in bt.ym_range("2018-01", "2020-12")}
        s["2020-06"] = 1.5  # one 50% spike
        r = bt.r_of_h(s, (1, 2))
        self.assertAlmostEqual(r[1]["max"], 0.5)
        self.assertEqual(r[1]["max_at"], "2020-05")
        self.assertAlmostEqual(r[2]["max"], 0.5)
        self.assertEqual(r[1]["n"], 35)

    def test_bands_follow_gcpi_001_7_3(self):
        self.assertEqual(bt.band(0.05), "normal")
        self.assertEqual(bt.band(-0.07), "corroborate")
        self.assertEqual(bt.band(0.20), "confirm")
        self.assertEqual(bt.band(0.2001), "quarantine")

    def test_coverage(self):
        panel = {"a": flat(1.0), "b": {m: 1.0 for m in MONTHS[:6]}, "c": flat(1.0)}
        c = bt.coverage(panel, {"a": 0.4, "b": 0.4, "c": 0.2}, MONTHS)
        self.assertEqual(c["met"], 6)  # without b: two markets and 60% of weight
        self.assertEqual(c["min_markets_seen"], 2)

    def test_staleness_counts_carried_values(self):
        daily = [("01-06-2020", 10.0), ("02-06-2020", 10.0), ("03-06-2020", 11.0), ("04-06-2020", 11.0)]
        s = bt.staleness(daily)
        self.assertEqual(s["by_year"]["2020"]["same_as_previous"], 2)
        self.assertEqual(s["by_year"]["2020"]["days"], 3)

    def test_real_return(self):
        months = bt.ym_range("2000-01", "2010-01")
        price = {m: 1.10 ** (i / 12) for i, m in enumerate(months)}
        cpi = {m: 1.02 ** (i / 12) for i, m in enumerate(months)}
        r = bt.real_return(price, cpi)
        self.assertAlmostEqual(r["nominal_pa"], 0.10, places=6)
        self.assertAlmostEqual(r["real_pa"], 1.10 / 1.02 - 1, places=6)


if __name__ == "__main__":
    unittest.main()
