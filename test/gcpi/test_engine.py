# Run with: python3 -m unittest discover -s test/gcpi
# gcpi/engine (#91): the reference engine's arithmetic against high-precision decimals, every published
# vector's bytes and intended outcome, determinism under reordering, and the Phase 2 numbers it must
# reproduce from the committed open dataset. engine.test.cjs checks the JavaScript engine on the same vectors.
import copy
import csv
import datetime
import decimal
import fractions
import json
import math
import os
import random
import sys
import unittest

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
sys.path.insert(0, os.path.join(ROOT, "gcpi", "engine"))
sys.path.insert(0, os.path.join(ROOT, "gcpi", "backtest"))
import backtest as bt  # noqa: E402
import engine  # noqa: E402

VECTORS = os.path.join(ROOT, "gcpi", "engine", "vectors")
DATA = os.path.join(ROOT, "gcpi", "backtest", "data")
D = decimal.Context(prec=90)


def vector(name):
    with open(os.path.join(VECTORS, f"{name}.json")) as f:
        return json.load(f)


def periods(name):
    return {r["period"]: r for r in vector(name)["expected"]["periods"]}


def dec(n, scale=engine.S):
    return D.divide(decimal.Decimal(n), decimal.Decimal(scale))


class Arithmetic(unittest.TestCase):
    def test_ln2_is_ln_2_truncated(self):
        self.assertEqual(engine.LN2, int(D.multiply(D.ln(decimal.Decimal(2)), engine.S)))

    def test_ln_matches_decimal(self):
        for x in [1, 7, 10 ** 12, engine.S // 3, engine.S - 1, engine.S, engine.S + 1, 2 * engine.S - 1,
                  2 * engine.S, 10 ** 40, 10 ** 60, 123456789 * 10 ** 30]:
            want = D.multiply(D.ln(dec(x)), engine.S)
            self.assertLess(abs(want - engine.ln(x)), 10 ** 3, x)

    def test_exp_matches_decimal(self):
        for m in [0, 1, -1, engine.LN2, -engine.LN2, engine.S // 7, -engine.S // 7, 3 * engine.S, -3 * engine.S,
                  27 * engine.S, -27 * engine.S]:
            want = D.multiply(D.exp(dec(m)), engine.S)
            self.assertLess(abs(want - engine.exp(m)), max(10 ** 3, want / 10 ** 33), m)

    def test_exp_undoes_ln_to_the_output_scale(self):
        for x in [engine.S // 2, engine.S, 3 * engine.S, 10 ** 30, 10 ** 42]:
            self.assertEqual(engine.hdiv(engine.exp(engine.ln(x)), 10 ** 18), engine.hdiv(x, 10 ** 18))

    def test_division_rounding(self):
        self.assertEqual([engine.tdiv(7, 2), engine.tdiv(-7, 2), engine.tdiv(7, -2), engine.tdiv(-7, -2)], [3, -3, -3, 3])
        self.assertEqual([engine.hdiv(5, 2), engine.hdiv(4, 3), engine.hdiv(5, 3), engine.hdiv(0, 9)], [3, 1, 2, 0])

    def test_period_start_is_utc_midnight(self):
        for ym in ["1970-01", "2000-02", "2000-03", "2024-02", "2024-03", "2100-03"]:
            want = datetime.datetime.fromisoformat(f"{ym}-01T00:00:00+00:00").timestamp()
            self.assertEqual(engine.period_start(engine.ym_index(ym)), int(want))

    def test_bands_are_exact_and_inclusive(self):
        self.assertTrue(engine.within(10 ** 18, 11 * 10 ** 17, 1000, 1))
        self.assertFalse(engine.within(10 ** 18, 11 * 10 ** 17 + 1, 1000, 1))
        # √k scaling: 10% × √4 = 20% over four periods.
        self.assertTrue(engine.within(10 ** 18, 12 * 10 ** 17, 1000, 4))
        self.assertFalse(engine.within(10 ** 18, 12 * 10 ** 17 + 1, 1000, 4))

    def test_arithmetic_vector_is_what_the_engine_computes(self):
        v = vector("arithmetic")
        self.assertEqual([[x, str(engine.ln(int(x)))] for x, _ in v["ln"]], v["ln"])
        self.assertEqual([[m, str(engine.exp(int(m)))] for m, _ in v["exp"]], v["exp"])


class Vectors(unittest.TestCase):
    def test_every_vector_reproduces_byte_for_byte(self):
        import hashlib
        names = sorted(f[:-5] for f in os.listdir(VECTORS) if f.endswith(".json") and f != "arithmetic.json")
        self.assertGreaterEqual(len(names), 20)
        for name in names:
            v = vector(name)
            try:
                out = engine.run(copy.deepcopy(v["input"]))
            except engine.EngineError as e:
                out = {"error": e.code}
            text = engine.canonical(out)
            self.assertEqual(text, engine.canonical(v["expected"]), name)
            self.assertEqual(hashlib.sha256(text.encode()).hexdigest(), v["expected_sha256"], name)

    def test_intended_outcomes(self):
        """Each vector's description, as statuses and reasons. Independent of the stored bytes."""
        want = {
            "normal": {p: ("VALID", "linked") for p in ("2020-03", "2020-04", "2020-05", "2020-06")},
            "missing_market": {"2020-03": ("INSUFFICIENT_COVERAGE", "coverage"), "2020-04": ("VALID", "linked")},
            "missing_all": {"2020-03": ("UNAVAILABLE", "no_observations")},
            "genuine_shock": {"2020-03": ("VALID", "confirmed"), "2020-04": ("VALID", "linked")},
            "spike_rejected": {"2020-03": ("INVALID_INPUT", "market_rejected"), "2020-04": ("VALID", "linked")},
            "corroborate_band": {"2020-03": ("VALID", "linked"), "2020-05": ("VALID", "linked")},
            "unresolved_pending": {"2020-03": ("PENDING_CONFIRMATION", "market_pending"),
                                   "2020-04": ("PENDING_CONFIRMATION", "earlier_period_pending")},
            "fx_invalid": {"2020-03": ("INVALID_INPUT", "market_invalid")},
            "rounding": {"2020-03": ("VALID", "linked"), "2020-04": ("PENDING_CONFIRMATION", "market_pending")},
            "stale": {"2020-03": ("STALE", "market_stale")},
            "published_early": {"2020-03": ("INVALID_INPUT", "market_invalid")},
            "disputed_and_duplicate": {"2020-03": ("INVALID_INPUT", "market_disputed"), "2020-04": ("VALID", "linked")},
            "circuit_breaker": {"2020-03": ("VALID", "confirmed"), "2020-04": ("VALID", "linked"),
                                "2020-06": ("INVALID_INPUT", "circuit_breaker_rejected"), "2020-07": ("VALID", "linked")},
            "no_base": {"2020-02": ("INSUFFICIENT_COVERAGE", "base_coverage"), "2020-03": ("UNAVAILABLE", "no_base")},
            "bands_disabled": {p: ("VALID", "linked") for p in ("2020-03", "2020-04", "2020-05")},
            "closer_tie": {"2020-03": ("INVALID_INPUT", "market_rejected"), "2020-04": ("VALID", "linked")},
            "long_pending": {"2020-03": ("VALID", "linked"), "2022-09": ("INSUFFICIENT_COVERAGE", "coverage"),
                             "2022-10": ("VALID", "linked")},
        }
        for name, expect in want.items():
            got = periods(name)
            for p, (status, reason) in expect.items():
                self.assertEqual((got[p]["status"], got[p]["reason"]), (status, reason), f"{name} {p}")
                self.assertEqual(got[p]["level"] is not None, status == "VALID", f"{name} {p}")
        self.assertEqual(periods("genuine_shock")["2020-03"]["decided_at"], "2020-04")
        spike = periods("bands_disabled")["2020-03"]
        self.assertEqual((spike["markets"]["PH"]["decision"], spike["markets"]["PH"]["band"]), ("ACCEPTED", None))
        self.assertEqual(periods("missing_market")["2020-04"]["linked_from"], "2020-02")
        self.assertFalse(periods("missing_market")["2020-04"]["comparable"])
        self.assertTrue(periods("missing_market")["2020-05"]["comparable"])
        self.assertIsNone(periods("unresolved_pending")["2020-03"]["decided_at"])
        cb = periods("circuit_breaker")
        self.assertEqual((cb["2020-03"]["decided_at"], cb["2020-06"]["decided_at"]), ("2020-04", "2020-07"))
        for name, period, band in (("corroborate_band", "2020-03", "corroborate"), ("confirm_band", "2020-03", "confirm"),
                                   ("genuine_shock", "2020-03", "quarantine")):
            self.assertEqual(periods(name)[period]["markets"]["PH"]["band"], band, name)
        for name, period in (("corroborate_band", "2020-05"), ("confirm_band", "2020-05"), ("oil_basis_break", "2020-03")):
            self.assertEqual(periods(name)[period]["decided_at"], bt.ym_add(period, 1), name)
        errors = {"error_noncanonical_integer": "observation_integer", "error_unknown_field": "observation_fields",
                  "error_bad_period": "observation_period", "error_zero_weight": "market_weight",
                  "error_number_not_string": "observation_types", "error_observation_out_of_range": "observation_out_of_range"}
        for name, code in errors.items():
            self.assertEqual(vector(name)["expected"], {"error": code}, name)

    def test_levels_match_the_chain_link_formula_in_decimal(self):
        out = periods("normal")
        prices = {p: {k: decimal.Decimal(r["markets"][k]["price"]) for k in ("PH", "ID")} for p, r in out.items()}
        w = {"PH": decimal.Decimal(65), "ID": decimal.Decimal(35)}
        level = D.divide(sum(w[k] * prices["2020-02"][k] for k in w), 100)
        self.assertEqual(int(out["2020-02"]["level"]), int(level.to_integral_value(decimal.ROUND_HALF_UP)))
        for prev, cur in zip(sorted(out), sorted(out)[1:]):
            mean = D.divide(sum(w[k] * D.ln(D.divide(prices[cur][k], prices[prev][k])) for k in w), 100)
            level = D.multiply(decimal.Decimal(out[prev]["level"]), D.exp(mean))
            self.assertLessEqual(abs(level - int(out[cur]["level"])), 1, cur)

    def test_fx_and_unit_normalization(self):
        out = periods("fx_conversion")["2020-02"]["markets"]
        self.assertEqual(int(out["PH"]["price"]), engine.hdiv(3050 * 10 ** 18 * 10 ** 4, 10 ** 2 * 507000))   # 30.50 PHP/kg at 50.70
        self.assertEqual(int(out["IN"]["price"]), engine.hdiv(9100 * 10 ** 18 * 10 ** 2, 100 * 7150))         # 9100 INR/quintal at 71.50
        self.assertEqual(int(out["WB"]["price"]), 101 * 10 ** 16)                                            # 1010 USD/t

    def test_half_wei_rounds_up(self):
        r = periods("rounding")["2020-02"]
        self.assertEqual(r["markets"]["PH"]["price"], "1000000000000000001")
        self.assertEqual(r["level"], "1000000000000000001")   # (65 × (1e18 + 1) + 35 × 1e18) / 100 = 1e18 + 0.65

    def test_a_dropped_market_at_a_premium_does_not_move_the_level(self):
        levels = {r["level"] for r in periods("no_renormalization_jump").values()}
        self.assertEqual(levels, {"1500000000000000000"})

    def test_a_duplicate_submission_counts_once(self):
        self.assertEqual(len(periods("disputed_and_duplicate")["2020-04"]["markets"]["ID"]["observations"]), 1)
        self.assertEqual(len(periods("disputed_and_duplicate")["2020-03"]["markets"]["ID"]["observations"]), 2)


class Determinism(unittest.TestCase):
    def test_observation_order_does_not_matter(self):
        rng = random.Random(91)
        for name in ("genuine_shock", "corroborate_band", "circuit_breaker", "disputed_and_duplicate", "fx_conversion"):
            inp = vector(name)["input"]
            want = engine.canonical(engine.run(copy.deepcopy(inp)))
            for _ in range(5):
                shuffled = copy.deepcopy(inp)
                rng.shuffle(shuffled["observations"])
                self.assertEqual(engine.canonical(engine.run(shuffled)), want, name)

    def test_unconfigured_markets_are_ignored(self):
        inp = vector("normal")["input"]
        noisy = copy.deepcopy(inp)
        extra = dict(noisy["observations"][0], market="XX")
        noisy["observations"].append(extra)
        self.assertEqual(engine.canonical(engine.run(noisy)), engine.canonical(engine.run(copy.deepcopy(inp))))

    def test_a_trailing_newline_is_not_canonical(self):
        # Python's `$` also matches before a final newline; JavaScript's does not. The anchors must agree.
        for code, mutate in [("observation_id", lambda i: i["observations"][0].update(market="PH\n")),
                             ("observation_period", lambda i: i["observations"][0].update(period="2020-01\n")),
                             ("observation_integer", lambda i: i["observations"][0].update(price="100\n")),
                             ("methodology_id", lambda i: i["methodology"].update(id="GCPI-test\n"))]:
            inp = copy.deepcopy(vector("normal")["input"])
            mutate(inp)
            with self.assertRaises(engine.EngineError) as e:
                engine.run(inp)
            self.assertEqual(e.exception.code, code)

    def test_every_commitment_field_matters(self):
        o = vector("normal")["input"]["observations"][0]
        base = engine.commitment(o)
        seen = {base}
        for f in engine.OBS_FIELDS:
            changed = dict(o)
            changed[f] = {"price": "101", "price_exp": "3", "published": "1", "fx": "1", "fx_exp": "1",
                          "record": "0" * 64, "period": "2021-01"}.get(f, o[f] + "x" if o[f] else "x")
            seen.add(engine.commitment(changed))
        self.assertEqual(len(seen), len(engine.OBS_FIELDS) + 1)

    def test_canonical_rejects_floats_and_non_printable(self):
        for bad in (1.5, 3, "café", "tab\there"):
            with self.assertRaises(engine.EngineError):
                engine.canonical({"x": bad})


class Phase2OnOpenData(unittest.TestCase):
    """The Phase 2 numbers that the committed open dataset alone determines (ICC's are checked by
    gcpi/engine/reproduce.py against a local cache, since ICC's data cannot be committed)."""

    @classmethod
    def setUpClass(cls):
        with open(os.path.join(DATA, "results.json")) as f:
            cls.R = json.load(f)
        with open(os.path.join(DATA, "dataset.csv")) as f:
            cls.rows = list(csv.DictReader(f))

    def wad_series(self, col, before=None):
        out = {}
        for r in self.rows:
            if r[col] and (before is None or r["month"] < before):
                whole, frac = r[col].split(".")
                out[r["month"]] = engine.hdiv(int(whole + frac) * engine.WAD, 10 ** len(frac))
        return out

    def test_band_counts_match_results_json(self):
        bands = [500, 1000, 2000]   # §7.3 as written, the bands Phase 2 counted
        for col, key, before in (("cdb_kochi_milling_usd_kg", "IN", None), ("psa_resecada_usd_kg", "PSA_2010_2023", bt.PSA_BREAK)):
            s = self.wad_series(col, before)
            counts = {name: 0 for name in engine.BANDS}
            for ym in s:
                if bt.ym_add(ym, -1) in s:
                    counts[engine.band(s[bt.ym_add(ym, -1)], s[ym], bands, 1)] += 1
            self.assertEqual(counts, self.R["bands_monthly"][key], key)

    def test_chain_link_matches_the_backtest_function(self):
        """backtest.chain_linked on two open series against the engine under the same rules."""
        cols = {"PH": "psa_resecada_usd_kg", "IN": "cdb_kochi_milling_usd_kg"}
        panel = {k: {ym: float(v) / engine.WAD for ym, v in self.wad_series(c, bt.PSA_BREAK).items()} for k, c in cols.items()}
        months = bt.ym_range("2010-01", "2023-12")
        w = 0.6875   # dyadic, so the engine's integer weights are exactly the float ones
        f = fractions.Fraction(w)
        floats = bt.chain_linked(panel, {"PH": w, "IN": 1 - w}, months)
        obs = []
        for k, c in cols.items():
            for ym, v in self.wad_series(c, bt.PSA_BREAK).items():
                obs.append({"market": k, "period": ym, "source": "dataset-csv", "price": str(v), "price_exp": "18",
                            "currency": "USD", "unit": "kg", "fx": "", "fx_exp": "", "fx_source": "",
                            "published": str(engine.period_start(engine.ym_index(ym) + 1)), "record": "0" * 64, "basis": ""})
        obs = [o for o in obs if months[0] <= o["period"] <= months[-1]]
        m = {"id": "phase2-open", "markets": {"PH": str(f.numerator), "IN": str(f.denominator - f.numerator)},
             "signals": [], "corroborators": {}, "min_coverage_bp": "0", "max_publication_lag_days": "36500",
             "bands_bp": None, "circuit_breaker_bp": None, "base_period": months[0]}
        out = engine.run({"methodology": m, "first": months[0], "last": months[-1], "observations": obs})["periods"]
        levels = {r["period"]: int(r["level"]) / engine.WAD for r in out if r["status"] == "VALID"}
        self.assertEqual(set(levels), set(floats))
        self.assertLess(max(abs(math.log(levels[k] / floats[k])) for k in floats), 1e-12)


if __name__ == "__main__":
    unittest.main()
