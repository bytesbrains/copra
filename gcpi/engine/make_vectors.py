#!/usr/bin/env python3
"""
GCPI Phase 3 (#91): writes the published test vectors in vectors/.

Each vector is an engine input and the canonical output engine.py produces for it. engine.cjs must
produce the same bytes (test/gcpi/engine.test.cjs), and test/gcpi/test_engine.py checks each vector's
intended outcome independently of the stored bytes, so a vector cannot silently pin a wrong answer.

Usage: make_vectors.py   (rewrites vectors/*.json)
"""

import copy
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import engine  # noqa: E402

OUT = os.path.join(HERE, "vectors")
V1 = json.load(open(os.path.join(HERE, "methodology", "gcpi-001-v1-draft.json")))
MONTHS = [f"2020-{m:02d}" for m in range(1, 13)]


def obs(market, ym, price, price_exp="2", currency="USD", unit="kg", fx="", fx_exp="", published=None,
        basis="", source="test-source", record=None):
    t = engine.ym_index(ym)
    return {"market": market, "period": ym, "source": source, "price": str(price), "price_exp": str(price_exp),
            "currency": currency, "unit": unit, "fx": fx, "fx_exp": fx_exp, "fx_source": "test-fx" if fx else "",
            "published": str(engine.period_start(t + 1) + 86400 if published is None else published),
            "record": record or hashlib.sha256(f"{market}:{ym}:{price}:{source}".encode()).hexdigest(), "basis": basis}


def series(market, cents, months=MONTHS, **kw):
    """Observations for consecutive months from a list of USD/kg prices in cents; None skips a month."""
    return [obs(market, ym, c, **kw) for ym, c in zip(months, cents) if c is not None]


def methodology(**over):
    m = copy.deepcopy(V1)
    m["id"] = "GCPI-test"
    m["base_period"] = "2020-02"
    m.update(over)
    return m


def vector(name, description, m, observations, first="2020-01", last=None):
    last = last or max(o["period"] for o in observations)
    return name, description, {"methodology": m, "first": first, "last": last, "observations": observations}


OIL = lambda cents, **kw: series("COCONUT_OIL", cents, unit="t", basis=kw.pop("basis", "cfr-europe"), **kw)

VECTORS = [
    vector("normal", "Two markets with small moves every month: every period VALID and comparable.",
           methodology(), series("PH", [100, 100, 102, 101, 104, 103]) + series("ID", [80, 81, 80, 83, 84, 84])),

    vector("missing_market", "Indonesia absent in one month: below 70% of weight, so INSUFFICIENT_COVERAGE; "
           "the next month links from the last VALID period and is not comparable.",
           methodology(), series("PH", [100, 100, 102, 103, 104]) + series("ID", [80, 81, None, 83, 84])),

    vector("missing_all", "No observation at all in one month: UNAVAILABLE.",
           methodology(), series("PH", [100, 100, None, 103]) + series("ID", [80, 81, None, 83])),

    vector("no_renormalization_jump", "Three markets, one at a persistent premium, 50% coverage floor. All prices "
           "flat; the premium market drops out and returns. The level must not move.",
           methodology(markets={"A": "40", "B": "35", "C": "25"}, signals=[], corroborators={}, min_coverage_bp="5000"),
           series("A", [100] * 6) + series("B", [100] * 6) + series("C", [300, 300, None, None, 300, 300])),

    vector("genuine_shock", "Both markets and coconut oil rise about 50% in one month and stay there: quarantined "
           "(above 40%), then confirmed by the next month's publications. The shock month is VALID, decided "
           "one month late.",
           methodology(), series("PH", [100, 100, 150, 152, 151]) + series("ID", [80, 80, 121, 122, 122])
           + OIL([100000, 100000, 155000, 156000, 156000])),

    vector("spike_rejected", "The Philippines spikes 60% for one month and returns: the spike is rejected when "
           "the next month passes against the old reference, and its month is INVALID_INPUT.",
           methodology(), series("PH", [100, 100, 160, 101, 102]) + series("ID", [80, 80, 81, 81, 82])
           + OIL([100000] * 5)),

    vector("corroborate_band", "The Philippines +15% (10-20% band). Corroborated in month 3 by Indonesia moving "
           "the same way; not corroborated in month 5 (Indonesia and oil fall), so pending until month 6 "
           "confirms it.",
           methodology(), series("PH", [100, 100, 115, 115, 132, 133]) + series("ID", [80, 80, 82, 82, 81, 81])
           + OIL([100000, 100000, 100000, 100000, 99000, 99000])),

    vector("confirm_band", "The Philippines +30% (20-40% band) twice. Month 3: coconut oil +12% is a strong "
           "corroboration, so accepted. Month 5: Indonesia +5% moves the same way but within the normal "
           "band, which is not strong enough, so pending until month 6.",
           methodology(), series("PH", [100, 100, 130, 130, 169, 170]) + series("ID", [80, 80, 82, 82, 86, 86])
           + OIL([100000, 100000, 112000, 112000, 112000, 112000])),

    vector("oil_basis_break", "A 15% Philippine move whose only same-direction corroborator is coconut oil across "
           "a change of delivery basis: a break, not a move, so the observation waits for the next month.",
           methodology(), series("PH", [100, 100, 115, 116]) + series("ID", [80, 80, 79, 79])
           + OIL([100000, 100000], months=MONTHS[:2], basis="crude-cif-rotterdam")
           + OIL([120000, 120000], months=MONTHS[2:4], basis="cfr-europe")),

    vector("unresolved_pending", "A quarantined move with no later publication: the period stays "
           "PENDING_CONFIRMATION with no decision, and every later period waits for it.",
           methodology(), series("PH", [100, 100, 150, None, None]) + series("ID", [80, 80, 81, 81, 82])),

    vector("fx_conversion", "Local-currency quotations: Philippine pesos per kg and Indian rupees per quintal, "
           "each with its own FX rate (local per USD), and USD per tonne.",
           methodology(markets={"PH": "50", "IN": "30", "WB": "20"}, signals=[], corroborators={}),
           [obs("PH", ym, p, "2", "PHP", "kg", fx, "4") for ym, p, fx in
            (("2020-01", 3000, "506123"), ("2020-02", 3050, "507000"), ("2020-03", 3100, "512345"))]
           + [obs("IN", ym, p, "0", "INR", "quintal", fx, "2") for ym, p, fx in
              (("2020-01", 9000, "7120"), ("2020-02", 9100, "7150"), ("2020-03", 9050, "7255"))]
           + [obs("WB", ym, p, "0", "USD", "t") for ym, p in (("2020-01", 1000), ("2020-02", 1010), ("2020-03", 990))]),

    vector("fx_invalid", "A peso quotation without an FX rate, and a USD quotation with one: both INVALID, so "
           "the period is INVALID_INPUT.",
           methodology(), series("PH", [100, 100]) + series("ID", [80, 80])
           + [obs("PH", "2020-03", 3000, "2", "PHP", "kg"), obs("ID", "2020-03", 81, fx="1", fx_exp="0")]),

    vector("rounding", "Rounding edges. February's Philippine price normalizes to exactly n + 1/2 wei (rounds "
           "up), and so does the base level. In March Indonesia moves exactly 10%: normal, since bounds are "
           "inclusive. In April it moves 10% plus one wei: not normal, and with no corroborator it waits.",
           methodology(signals=[], corroborators={}),
           [obs("PH", "2020-01", 2000000000000000001, "18", fx="2", fx_exp="0", currency="PHP"),
            obs("PH", "2020-02", 2000000000000000001, "18", fx="2", fx_exp="0", currency="PHP"),
            obs("PH", "2020-03", 1100000000000000001, "18"),
            obs("PH", "2020-04", 1210000000000000001, "18")]
           + [obs("ID", "2020-01", 1, "0"), obs("ID", "2020-02", 1, "0"), obs("ID", "2020-03", 11, "1"),
              obs("ID", "2020-04", 1210000000000000001, "18")]),

    vector("stale", "An observation published after the 90-day freshness window: STALE.",
           methodology(), series("PH", [100, 100]) + series("ID", [80, 80])
           + [obs("PH", "2020-03", 101, published=engine.period_start(engine.ym_index("2020-04")) + 91 * 86400),
              obs("ID", "2020-03", 81)]),

    vector("published_early", "An observation published before its period began: INVALID.",
           methodology(), series("PH", [100, 100]) + series("ID", [80, 80])
           + [obs("PH", "2020-03", 101, published=engine.period_start(engine.ym_index("2020-03")) - 1), obs("ID", "2020-03", 81)]),

    vector("disputed_and_duplicate", "Two attested observations of Indonesia in March with different values: "
           "DISPUTED, so INVALID_INPUT. In April the same observation submitted twice counts once.",
           methodology(), series("PH", [100, 100, 101, 102]) + series("ID", [80, 80])
           + [obs("ID", "2020-03", 81), obs("ID", "2020-03", 82, source="test-source-2"),
              obs("ID", "2020-04", 82), obs("ID", "2020-04", 82)]),

    vector("circuit_breaker", "A research methodology with a 15% index circuit breaker. Month 3 moves the index "
           "+18% and is held; month 4 confirms it. Month 6 moves +18% again and month 7 returns, so month 6 "
           "is rejected.",
           methodology(signals=[], corroborators={"PH": ["ID"], "ID": ["PH"]}, circuit_breaker_bp="1500", bands_bp=["2000", "3000", "5000"]),
           series("PH", [100, 100, 118, 119, 119, 140, 120]) + series("ID", [80, 80, 94, 95, 95, 112, 96])),

    vector("no_base", "The base period lacks a market: the index has no base level, and later periods are "
           "UNAVAILABLE even when both markets publish.",
           methodology(), series("PH", [100, 100, 101]) + series("ID", [80, None, 81])),
]

ERRORS = [
    ("error_noncanonical_integer", "A price with a leading zero is not a canonical integer.",
     lambda i: i["observations"][0].update(price="0100")),
    ("error_unknown_field", "An observation with a field the encoding does not define.",
     lambda i: i["observations"][0].update(note="x")),
    ("error_bad_period", "A period that is not YYYY-MM.",
     lambda i: i["observations"][0].update(period="2020-13")),
    ("error_zero_weight", "A market weight of zero.",
     lambda i: i["methodology"]["markets"].update(PH="0")),
    ("error_number_not_string", "A JSON number where the encoding requires a decimal string.",
     lambda i: i["observations"][0].update(price=100)),
    ("error_observation_out_of_range", "An observation outside [first, last].",
     lambda i: i["observations"][0].update(period="2019-12")),
]


def main():
    os.makedirs(OUT, exist_ok=True)
    for f in os.listdir(OUT):
        if f.endswith(".json"):
            os.remove(os.path.join(OUT, f))
    base = VECTORS[0][2]
    items = list(VECTORS)
    for name, description, mutate in ERRORS:
        inp = copy.deepcopy(base)
        mutate(inp)
        items.append((name, description, inp))
    for name, description, inp in items:
        try:
            out = engine.run(copy.deepcopy(inp))
        except engine.EngineError as e:
            out = {"error": e.code}
        text = engine.canonical(out)
        with open(os.path.join(OUT, f"{name}.json"), "w") as f:
            json.dump({"name": name, "description": description, "input": inp, "expected": out,
                       "expected_sha256": hashlib.sha256(text.encode()).hexdigest()}, f, indent=1, sort_keys=True)
            f.write("\n")

    # ln and exp on their own: the consensus-critical functions, at points across their range.
    xs = [1, 2, 3, 10 ** 12, 10 ** 35, engine.S - 1, engine.S, engine.S + 1, 15 * engine.S // 10, 2 * engine.S - 1,
          2 * engine.S, 3 * engine.S, 7 * engine.S // 3, 10 ** 48, 10 ** 47 + 12345, 10 ** 24 * engine.S]
    ms = [0, 1, -1, engine.LN2, -engine.LN2, engine.LN2 - 1, engine.S // 2, -engine.S // 2, engine.S, -engine.S,
          5 * engine.S, -5 * engine.S, 27 * engine.S, -27 * engine.S, 123456789 * 10 ** 27, -987654321 * 10 ** 26]
    arith = {"ln": [[str(x), str(engine.ln(x))] for x in xs], "exp": [[str(m), str(engine.exp(m))] for m in ms]}
    with open(os.path.join(OUT, "arithmetic.json"), "w") as f:
        json.dump({"name": "arithmetic", "description": "ln and exp at scale 1e36: [input, output] pairs.", **arith},
                  f, indent=1, sort_keys=True)
        f.write("\n")
    print(f"wrote {len(items) + 1} vectors to {OUT}")


if __name__ == "__main__":
    main()
