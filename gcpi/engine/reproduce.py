#!/usr/bin/env python3
"""
GCPI Phase 3 (#91): runs the reference engine on the Phase 2 backtest inputs.

1. Rebuilds the backtest's headline (ICC Philippines and Indonesia, chain-linked at production weights)
   with backtest.py's own functions, and checks the cache against the committed results.json.
2. Runs both engines on the same inputs under the Phase 2 methodology (backtest weights, no coverage
   floor, no bands), and checks that they agree byte for byte and that they reproduce the backtest:
   the same periods, the same statistics, and levels equal to the float series within float error.
3. Runs the engine under the v1 draft methodology and prints what v1 would have published.

Prints statistics only: ICC's data is all rights reserved, so no level series is written.

Usage: reproduce.py <cache dir>   (the cache built by gcpi/backtest/fetch.py)
"""

import collections
import fractions
import decimal
import hashlib
import json
import math
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "backtest"))
import backtest as bt  # noqa: E402
import engine  # noqa: E402
from load import load_fao, load_icc, load_wb  # noqa: E402

RESULTS = os.path.join(HERE, "..", "backtest", "data", "results.json")

# World Bank coconut oil delivery basis by period (gcpi/SOURCES.md §1): each change is a break (§7.5).
COCONUT_OIL_BASIS = [("1999-01", "cif-nw-europe"), ("2021-01", "crude-cif-rotterdam"), ("2025-01", "cfr-europe")]


def decimal_parts(v):
    """A float as (mantissa, exponent) of its shortest decimal form, at most 18 places."""
    d = decimal.Decimal(repr(v))
    if -d.as_tuple().exponent > engine.MAX_EXP:
        d = d.quantize(decimal.Decimal(1).scaleb(-engine.MAX_EXP), rounding=decimal.ROUND_HALF_UP)
    sign, digits, exp = d.normalize().as_tuple()
    assert sign == 0
    mantissa = int("".join(map(str, digits))) * 10 ** max(exp, 0)
    return str(mantissa), str(max(-exp, 0))


def observation(market, ym, value, unit, source, basis=""):
    price, price_exp = decimal_parts(value)
    return {"market": market, "period": ym, "source": source, "price": price, "price_exp": price_exp,
            "currency": "USD", "unit": unit, "fx": "", "fx_exp": "", "fx_source": "",
            "published": str(engine.period_start(engine.ym_index(ym) + 1)),
            # No attested source record exists for the backtest inputs: this stands in for one.
            "record": hashlib.sha256(f"{source}:{market}:{ym}".encode()).hexdigest(), "basis": basis}


def basis_of(ym):
    out = "cif-rotterdam"
    for start, name in COCONUT_OIL_BASIS:
        if ym >= start:
            out = name
    return out


def run_js(inp):
    p = subprocess.run(["node", os.path.join(HERE, "engine.cjs"), "/dev/stdin"], input=json.dumps(inp),
                       capture_output=True, text=True, check=True)
    return p.stdout.strip()


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    cache = argv[1]
    committed = json.load(open(RESULTS))
    _, icc = load_icc(cache)
    wd = load_fao(cache)
    coconut_oil = {**load_wb(os.path.join(cache, "wb_2020.xlsx"))["Coconut oil"],
                   **load_wb(os.path.join(cache, "wb_current.xlsx"))["Coconut oil"]}
    panel = {"PH": icc["Philippines"], "ID": icc["Indonesia"]}

    # 1. The backtest's headline, exactly as backtest.py builds it.
    head_months = bt.ym_range("2016-02", min(max(panel["PH"]), max(panel["ID"])))
    shares = wd["production_share"]
    w_ph = shares["PH"] / (shares["PH"] + shares["ID"])
    head_w = {"PH": w_ph, "ID": 1 - w_ph}
    headline = bt.chain_linked(panel, head_w, head_months)
    checks = {
        "bands_monthly.headline": (bt.band_counts(headline), committed["bands_monthly"]["headline"]),
        "coverage_headline_two_markets": (bt.coverage(panel, head_w, head_months, 2, 0.70),
                                          committed["coverage_headline_two_markets"]),
        "R_of_h.headline": (json.loads(json.dumps(bt.r_of_h(headline), default=str)),
                            committed["R_of_h"]["headline_PH_ID_chain_linked_2016_2026"]),
    }
    for name, (got, want) in checks.items():
        if got != want:
            print(f"cache does not reproduce results.json at {name}: rerun fetch.py, or the sources changed")
            return 1
    print(f"1. cache reproduces results.json: headline {head_months[0]}..{head_months[-1]}, {len(headline)} months with a value")

    # 2. The engine under the Phase 2 methodology. The backtest's float weights are dyadic rationals and
    # 1 - w is exact in binary floating point, so these integers are the backtest's weights exactly.
    f = fractions.Fraction(w_ph)
    phase2 = {"id": "GCPI-001-phase2-backtest", "markets": {"PH": str(f.numerator), "ID": str(f.denominator - f.numerator)},
              "signals": [], "corroborators": {}, "min_coverage_bp": "0", "max_publication_lag_days": "36500",
              "bands_bp": None, "circuit_breaker_bp": None, "base_period": head_months[0]}
    obs = [observation(k, ym, v, "kg", "icc-weekly-monthly-mean") for k, s in panel.items() for ym, v in sorted(s.items())
           if head_months[0] <= ym <= head_months[-1]]
    inp = {"methodology": phase2, "first": head_months[0], "last": head_months[-1], "observations": obs}
    py = engine.canonical(engine.run(inp))
    js = run_js(inp)
    if py != js:
        print("2. FAIL: the Python and JavaScript engines disagree")
        return 1
    out = json.loads(py)["periods"]
    level = {r["period"]: int(r["level"]) / engine.WAD for r in out if r["status"] == "VALID"}
    if set(level) != set(headline):
        print(f"2. FAIL: periods differ: {sorted(set(level) ^ set(headline))}")
        return 1
    worst = max(abs(level[k] / headline[k] - 1) for k in headline)
    same_stats = bt.band_counts(level) == committed["bands_monthly"]["headline"]
    r_engine = json.loads(json.dumps(bt.r_of_h(level), default=str))
    r_close = all(abs(r_engine[h][q] - committed["R_of_h"]["headline_PH_ID_chain_linked_2016_2026"][h][q]) < 1e-12
                  for h in r_engine for q in ("p95", "p99", "max"))
    r_same_at = all(r_engine[h]["max_at"] == committed["R_of_h"]["headline_PH_ID_chain_linked_2016_2026"][h]["max_at"]
                    for h in r_engine)
    print(f"2. Phase 2 methodology: Python and JavaScript byte-identical ({hashlib.sha256(py.encode()).hexdigest()[:16]}…); "
          f"{len(level)} periods, the same as the backtest; largest relative level difference {worst:.1e}; "
          f"band counts {'equal' if same_stats else 'DIFFERENT'}; R(h) {'within 1e-12' if r_close else 'DIFFERENT'}, "
          f"maxima at the same months: {r_same_at}")
    if not (worst < 1e-12 and same_stats and r_close and r_same_at):
        return 1

    # 3. The v1 draft methodology on the same inputs, with world coconut oil as the corroborator.
    v1 = json.load(open(os.path.join(HERE, "methodology", "gcpi-001-v1-draft.json")))
    first = bt.ym_add(head_months[0], -1)
    obs = [observation(k, ym, v, "kg", "icc-weekly-monthly-mean") for k, s in panel.items() for ym, v in sorted(s.items())
           if first <= ym <= head_months[-1]]
    obs += [observation("COCONUT_OIL", ym, v, "t", "wb-cmo-monthly", basis_of(ym)) for ym, v in sorted(coconut_oil.items())
            if first <= ym <= head_months[-1]]
    inp = {"methodology": v1, "first": first, "last": head_months[-1], "observations": obs}
    py = engine.canonical(engine.run(inp))
    if py != run_js(inp):
        print("3. FAIL: the Python and JavaScript engines disagree")
        return 1
    out = json.loads(py)["periods"]
    statuses = collections.Counter(r["status"] for r in out)
    reasons = collections.Counter((r["status"], r["reason"]) for r in out if r["reason"] != "linked")
    decisions = collections.Counter((k, r["markets"][k]["decision"], r["markets"][k]["band"]) for r in out for k in r["markets"])
    late = [(r["period"], r["decided_at"]) for r in out if r["decided_at"] not in (None, r["period"])]
    nonvalid = [r["period"] for r in out if r["status"] != "VALID"]
    v1_level = {r["period"]: int(r["level"]) / engine.WAD for r in out if r["status"] == "VALID"}
    common = sorted(set(v1_level) & set(headline))
    print(f"3. v1 draft methodology: Python and JavaScript byte-identical; {len(out)} periods: {dict(statuses)}")
    print(f"   non-valid: {nonvalid}")
    print(f"   reasons: { {f'{s}/{r}': n for (s, r), n in sorted(reasons.items())} }")
    print(f"   market decisions: { {f'{k} {d} {b}': n for (k, d, b), n in sorted(decisions.items(), key=str)} }")
    print(f"   decided after their own period: {late}")
    print(f"   largest relative gap to the Phase 2 headline over {len(common)} common periods: "
          f"{max(abs(math.log(v1_level[k] / headline[k])) for k in common):.4f} (log)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
