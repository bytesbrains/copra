#!/usr/bin/env python3
"""
COPRA-001 economics (#96): run the mechanism over history, write results.json.

Experiments:
  A  ratio grid: shortfall and losses over (mcr, lr) x profile x behavior x path
  A2 steady mint: the same grid with replacement minting, export path only
  B  allocation: proportional vs lowest-first under a redemption surge
  C  liquidator float: per-period $COPRA needed, and MIN_DEBT from gas
  D  forward edge: what the redeemer gains from the forward price (sizes REDEEM_FEE)
  E  outage stress: a 3- and 6-month outage as the steepest rise begins
  F  minter returns: genesis-cohort multiples and their decomposition

Usage: experiments.py
Reads econ/data/paths.csv, writes econ/data/results.json. Stdlib only.
"""

import datetime
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sim  # noqa: E402

PATHS = os.path.join(HERE, "data", "paths.csv")
DEBT0, NPOS = 1_000_000.0, 100


def demand_none(wall, price, st):
    return 0.0


def demand_trickle(rate):
    def fn(wall, price, st):
        return rate * sim.totals(st)[1]
    return fn


def demand_surge(base, windows, surge_rate):
    def fn(wall, price, st):
        in_window = any(a <= wall <= b for a, b in windows)
        return (surge_rate if in_window else base) * sim.totals(st)[1]
    return fn


def run(months, prices, params, profile, demand, outages=frozenset()):
    """Step wall 0..T+tail; open genesis at the first usable price."""
    st = sim.State(params)
    genesis_done = False
    t = len(prices)
    tail = params.lag + params.redeem_expiry + 2
    records = []
    for wall in range(t + tail):
        fin = wall - params.lag
        ref = prices[fin] if 0 <= fin < t else None
        valid = fin not in outages
        if not genesis_done:
            px = sim.usable_price(st, wall)
            if px is not None:
                genesis_profile(st, profile, px)
                genesis_done = True
        records.append(sim.step(st, wall, ref, valid, demand))
    return st, records


def genesis_profile(st, profile, price):
    if profile == "adversarial":
        sim.genesis(st, DEBT0, NPOS, st.params.mcr, st.params.mcr, price)
    elif profile == "mixed":
        sim.genesis(st, DEBT0, NPOS, st.params.mcr, 2 * st.params.mcr, price)
    elif profile == "terciles":
        lo, hi = st.params.mcr, 2 * st.params.mcr
        cuts = [lo, lo + (hi - lo) / 3, lo + 2 * (hi - lo) / 3, hi]
        per = NPOS // 3
        for ch in range(3):
            n = per + (1 if ch < NPOS % 3 else 0)
            for i in range(n):
                r = cuts[ch] + (cuts[ch + 1] - cuts[ch]) * (i + 0.5) / n
                sim.add_position(st, sim.value(DEBT0 / NPOS, price) * r,
                                 DEBT0 / NPOS, cohort=ch, price=price)
    else:
        raise ValueError(profile)


def summarize(st, records, months):
    tcrs = [(r["wall"], r["tcr"]) for r in records if r["tcr"] is not None]
    short = [w for w, t in tcrs if t < 1.0]
    min_wall, min_tcr = min(tcrs, key=lambda x: x[1])
    liq_months = [r for r in records if r["liq_count"] > 0]
    float_ratios = [r["liq_repaid"] / r["supply_before"] for r in records
                    if r["liq_repaid"] > 0 and r["supply_before"] > 0]
    delays = st.settle_delays
    last_px = next(r["price"] for r in reversed(records) if r["price"] is not None)
    cohorts = sim.cohort_returns(st, last_px)
    return {
        "shortfall_months": len(short),
        "shortfall_first": months[short[0]] if short and short[0] < len(months) else None,
        "min_tcr": round(min_tcr, 4),
        "min_tcr_at": months[min_wall] if min_wall < len(months) else f"tail+{min_wall - len(months)}",
        "liq_months": len(liq_months),
        "liq_count": sum(r["liq_count"] for r in records),
        "liq_repaid": round(sum(r["liq_repaid"] for r in records), 1),
        "bad_debt_months": sum(1 for r in records if r["redistributed"] > 0),
        "bad_debt_usd": round(st.bad_debt_usd, 1),
        "haircut_usd": round(st.shortfall_haircut_usd, 1),
        "max_liq_float": round(max(float_ratios), 4) if float_ratios else 0.0,
        "max_unliq_debt": round(max([r["unliq_debt"] for r in records] or [0.0]), 1),
        "settled": round(sum(r["settled_amt"] for r in records), 1),
        "settle_delay_max": max(delays) if delays else 0,
        "settle_delay_mean": round(sum(delays) / len(delays), 2) if delays else 0,
        "cancelled": st.cancelled,
        "final_supply": round(records[-1]["debt"], 1),
        "cohorts": {str(k): {kk: (round(vv, 4) if isinstance(vv, float) else vv)
                              for kk, vv in v.items()} for k, v in cohorts.items()},
    }


def steepest_start(prices, window=12, start_margin=12, end_margin=12):
    return max(range(start_margin, len(prices) - window - end_margin),
               key=lambda i: prices[i + window] / prices[i])


def quantile(xs, q):
    xs = sorted(xs)
    pos = q * (len(xs) - 1)
    lo, hi = int(pos // 1), int(-(-pos // 1))
    return xs[lo] + (xs[hi] - xs[lo]) * (pos - lo)


PAIRS = [(2.0, 1.4), (2.0, 1.55), (2.5, 1.55), (2.5, 1.75), (3.0, 1.75), (3.0, 2.0),
         (1.8, 1.4)]

# Maintainers defend mcr from below (top up within a month) and take profit above
# 1.3*mcr; the band between avoids churn.
MAINT = {"topup_trigger": 1.1, "topup_delay": 1, "withdraw_buffer": 1.3}


WINDOW_START_STEP, WINDOW_HORIZON = 12, 36


def experiment_a(paths):
    """Rolling cohorts: fresh genesis every 12 months, run for 36. A single genesis
    over the whole path collapses supply early and then measures nothing; rolling
    windows measure what sizing needs — how a cohort minted at (mcr, lr) fares."""
    out = []
    for name, (months, prices) in paths.items():
        starts = list(range(0, len(prices) - WINDOW_HORIZON - 6, WINDOW_START_STEP))
        for mcr, lr in PAIRS:
            for profile in ("adversarial", "mixed"):
                for behavior, kw in (("passive", {}),
                                     ("maintainer", MAINT)):
                    wins = []
                    for s0 in starts:
                        ms = months[s0:s0 + WINDOW_HORIZON]
                        ps = prices[s0:s0 + WINDOW_HORIZON]
                        p = sim.Params(mcr=mcr, lr=lr, **kw)
                        st, recs = run(ms, ps, p, profile, demand_trickle(0.005))
                        w = summarize(st, recs, ms)
                        w["start"] = ms[0]
                        wins.append(w)
                    out.append(aggregate(name, mcr, lr, profile, behavior, wins))
    return out


def aggregate(path, mcr, lr, profile, behavior, wins):
    short = [w for w in wins if w["shortfall_months"] > 0]
    liqw = [w for w in wins if w["liq_count"] > 0]
    worst = min(wins, key=lambda w: w["min_tcr"])
    mults = [w["cohorts"]["0"]["multiple"] for w in wins
             if w["cohorts"]["0"]["multiple"] is not None]
    c0 = [w["cohorts"]["0"] for w in wins]
    return {
        "path": path, "mcr": mcr, "lr": lr, "profile": profile, "behavior": behavior,
        "windows": len(wins),
        "short_windows": len(short),
        "short_starts": [w["start"] for w in short][:12],
        "short_months_total": sum(w["shortfall_months"] for w in short),
        "worst_min_tcr": worst["min_tcr"],
        "worst_window": worst["start"],
        "liq_windows": len(liqw),
        "liq_count_total": sum(w["liq_count"] for w in wins),
        "bad_usd_total": round(sum(w["bad_debt_usd"] for w in wins), 1),
        "bad_usd_max": max([w["bad_debt_usd"] for w in wins] or [0.0]),
        "haircut_usd_total": round(sum(w["haircut_usd"] for w in wins), 1),
        "max_float": max([w["max_liq_float"] for w in wins] or [0.0]),
        "min_multiple": round(min(mults), 4) if mults else None,
        "mean_multiple": round(sum(mults) / len(mults), 4) if mults else None,
        "mult_ge_1": sum(1 for m in mults if m >= 1.0),
        "mult_lt_09": sum(1 for m in mults if m < 0.9),
        "liq_paid_total": round(sum(c.get("liq_paid", 0) for c in c0), 1),
        "fees_total": round(sum(c.get("fees_kept", 0) for c in c0), 1),
        "deposits_total": round(sum(c.get("deposits", 0) for c in c0), 1),
        "mean_final_supply": round(sum(w["final_supply"] for w in wins) / len(wins), 1),
        "worst_windows": sorted(wins, key=lambda w: w["min_tcr"])[:3],
    }


def experiment_a2(paths):
    """Rolling windows with replacement minting (steady supply), export path only."""
    out = []
    months, prices = paths["export_copra_usd_kg"]
    starts = list(range(0, len(prices) - WINDOW_HORIZON - 6, WINDOW_START_STEP))
    for mcr, lr in PAIRS:
        wins = []
        for s0 in starts:
            ms = months[s0:s0 + WINDOW_HORIZON]
            ps = prices[s0:s0 + WINDOW_HORIZON]
            p = sim.Params(mcr=mcr, lr=lr, steady_mint=True, **MAINT)
            st, recs = run(ms, ps, p, "mixed", demand_trickle(0.005))
            w = summarize(st, recs, ms)
            w["start"] = ms[0]
            wins.append(w)
        c = aggregate("export_copra_usd_kg", mcr, lr, "mixed", "maintainer+steady", wins)
        out.append(c)
    return out


B_CELLS = ((2.5, 1.75, "maintainer", MAINT), (2.0, 1.55, "passive", {}))


def experiment_b(paths):
    """Rolling 3-way allocation comparison. In each 36-month window a 5%/mo surge
    runs months 12-23; tercile cohorts show who pays under each rule."""
    out = []
    for name, (months, prices) in paths.items():
        starts = list(range(0, len(prices) - WINDOW_HORIZON - 6, WINDOW_START_STEP))
        for mcr, lr, behavior, kw in B_CELLS:
            rules = {}
            for alloc in ("proportional", "lowest_first", "collateral_prop"):
                wins = []
                for s0 in starts:
                    ms = months[s0:s0 + WINDOW_HORIZON]
                    ps = prices[s0:s0 + WINDOW_HORIZON]
                    p = sim.Params(mcr=mcr, lr=lr, allocation=alloc, **kw)
                    st, recs = run(ms, ps, p, "terciles",
                                   demand_surge(0.005, [(12, 23)], 0.05))
                    w = summarize(st, recs, ms)
                    w["start"] = ms[0]
                    w["fees"] = {str(ch): st.fees_paid.get(ch, 0.0) for ch in (0, 1, 2)}
                    wins.append(w)
                short = [w for w in wins if w["shortfall_months"] > 0]
                worst = min(wins, key=lambda w: w["min_tcr"])
                rules[alloc] = {
                    "windows": len(wins),
                    "short_windows": len(short),
                    "worst_min_tcr": worst["min_tcr"],
                    "worst_window": worst["start"],
                    "liq_count_total": sum(w["liq_count"] for w in wins),
                    "bad_usd_total": round(sum(w["bad_debt_usd"] for w in wins), 1),
                    "mean_fees": {ch: round(sum(w["fees"][ch] for w in wins) / len(wins), 1)
                                  for ch in ("0", "1", "2")},
                    "mean_multiple": {
                        ch: round(sum(w["cohorts"][ch]["multiple"] for w in wins
                                      if w["cohorts"][ch]["multiple"] is not None) / len(wins), 4)
                        for ch in ("0", "1", "2")},
                }
            out.append({"path": name, "mcr": mcr, "lr": lr, "behavior": behavior,
                        "rules": rules})
    return out


def experiment_d(paths, lag=2):
    """Forward edge per request month k: P[k+1]/P[k-lag] - 1 (realized) and
    P[k+1]/P[k] - 1 (one period). No outages: first valid s is k+1."""
    out = {}
    for name, (months, prices) in paths.items():
        realized, one = [], []
        cond = {"up": [], "flat": [], "down": []}  # by trailing 3m move at request time
        for k in range(max(lag, 3), len(prices) - 1):
            realized.append(prices[k + 1] / prices[k - lag] - 1)
            one.append(prices[k + 1] / prices[k] - 1)
            # A source-watching redeemer sees published sources through ~k, ahead
            # of the usable price. Condition on what they see, not on the lag.
            trail = prices[k] / prices[k - 3] - 1
            cond["up" if trail > 0.10 else "down" if trail < -0.10 else "flat"].append(
                prices[k + 1] / prices[k - lag] - 1)
        out[name] = {
            "n": len(realized),
            "realized_mean": round(sum(realized) / len(realized), 4),
            "realized_p95": round(quantile(realized, 0.95), 4),
            "realized_max": round(max(realized), 4),
            "realized_max_at": months[realized.index(max(realized)) + max(lag, 3)],
            "one_mean": round(sum(one) / len(one), 4),
            "one_p95": round(quantile(one, 0.95), 4),
            "one_max": round(max(one), 4),
            "cond_mean": {k: round(sum(v) / len(v), 4) if v else None
                          for k, v in cond.items()},
            "cond_n": {k: len(v) for k, v in cond.items()},
        }
    return out


def experiment_e(paths):
    out = []
    for name, (months, prices) in paths.items():
        w = steepest_start(prices)
        for length in (0, 3, 6):
            p = sim.Params(mcr=2.5, lr=1.75, **MAINT)
            st, recs = run(months, prices, p, "mixed", demand_trickle(0.005),
                           outages=frozenset(range(w, w + length)))
            dark = sum(1 for r in recs if r["price"] is None)
            s = summarize(st, recs, months)
            s.update({"path": name, "outage_months": length,
                      "outage_at": months[w], "dark_months": dark})
            out.append(s)
    return out


def experiment_e2(paths):
    """Outage stress where it can bite: genesis six months before the steepest
    12-month rise, outage as the rise begins. Thin (2.0/1.55, passive) and the
    recommended (2.5/1.6, maintainer) calibrations."""
    out = []
    for name in ("export_copra_usd_kg", "cdb_kochi_usd_kg"):
        months, prices = paths[name]
        w = steepest_start(prices)
        ms, ps = months[w - 6:w + 24], prices[w - 6:w + 24]
        for mcr, lr, kw in ((2.0, 1.55, {}), (2.5, 1.6, MAINT)):
            for length in (0, 3, 6):
                p = sim.Params(mcr=mcr, lr=lr, **kw)
                st, recs = run(ms, ps, p, "mixed", demand_trickle(0.005),
                               outages=frozenset(range(6, 6 + length)))
                dark = sum(1 for r in recs if r["price"] is None)
                s = summarize(st, recs, ms)
                s.update({"path": name, "mcr": mcr, "lr": lr, "outage_months": length,
                          "rise_at": months[w], "dark_months": dark})
                out.append(s)
    return out


def main(argv):
    raw = sim.load_paths(PATHS)
    paths = {k: ([m for m, _ in v], [p for _, p in v]) for k, v in raw.items()}
    res = {
        "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"),
        "paths": {k: {"months": len(v[0]), "first": v[0][0], "last": v[0][-1]}
                  for k, v in paths.items()},
        "A_ratio_grid": experiment_a(paths),
        "A2_steady_mint": experiment_a2(paths),
        "B_allocation": experiment_b(paths),
        "D_forward_edge": experiment_d(paths),
        "E_outage": experiment_e(paths),
        "E2_outage_thin": experiment_e2(paths),
    }
    if len(argv) != 1:
        sys.exit("usage: experiments.py")
    out = os.path.join(HERE, "data", "results.json")
    with open(out, "w") as f:
        json.dump(res, f, indent=1)
    print(f"wrote {out}")
    print_table_a(res)
    print_table_b(res)
    print_table_d(res)
    print_table_e(res)
    print("\nE2: outage at the steepest rise, thin vs recommended ratios:")
    for s in res["E2_outage_thin"]:
        print(f"  {s['path'][:12]:12s} mcr={s['mcr']} lr={s['lr']} outage={s['outage_months']}: "
              f"dark={s['dark_months']} short={s['shortfall_months']} min_tcr={s['min_tcr']:.3f} "
              f"bad=${s['bad_debt_usd']:,.0f} liq={s['liq_count']} "
              f"delay_max={s['settle_delay_max']} cancelled={s['cancelled']}")


def print_table_a(res):
    print("\nA: rolling 36m windows — shortfall windows, worst TCR, minter multiples:")
    for s in res["A_ratio_grid"]:
        if s["profile"] == "mixed" and s["behavior"] == "maintainer":
            print(f"  {s['path'][:12]:12s} mcr={s['mcr']} lr={s['lr']}: "
                  f"short={s['short_windows']}/{s['windows']} worst={s['worst_min_tcr']:.3f}"
                  f"@{s['worst_window']} liqw={s['liq_windows']} bad=${s['bad_usd_total']:,.0f} "
                  f"mult~{s['mean_multiple']} min{s['min_multiple']} float={s['max_float']:.2f}")
    print("  adversarial/passive:")
    for s in res["A_ratio_grid"]:
        if s["profile"] == "adversarial" and s["behavior"] == "passive":
            print(f"  {s['path'][:12]:12s} mcr={s['mcr']} lr={s['lr']}: "
                  f"short={s['short_windows']}/{s['windows']} worst={s['worst_min_tcr']:.3f}"
                  f"@{s['worst_window']} bad=${s['bad_usd_total']:,.0f}")
    print("  A2 steady-mint, export, mixed/maintainer:")
    for s in res["A2_steady_mint"]:
        print(f"  mcr={s['mcr']} lr={s['lr']}: short={s['short_windows']}/{s['windows']} "
              f"worst={s['worst_min_tcr']:.3f}@{s['worst_window']} bad=${s['bad_usd_total']:,.0f}")


def print_table_b(res):
    print("\nB: rolling 3-way allocation under a 5%/mo 12-month surge:")
    for s in res["B_allocation"]:
        print(f"  {s['path'][:12]:12s} mcr={s['mcr']} {s['behavior']}:")
        for alloc, r in s["rules"].items():
            print(f"    {alloc:14s}: short={r['short_windows']}/{r['windows']} "
              f"worst={r['worst_min_tcr']:.3f}@{r['worst_window']} liq={r['liq_count_total']} "
              f"bad=${r['bad_usd_total']:,.0f}")
            print(f"    {'':14s}  tercile multiples={r['mean_multiple']} fees={r['mean_fees']}")


def print_table_d(res):
    print("\nD: forward edge (redeemer gain, settlement vs request-time usable):")
    for k, v in res["D_forward_edge"].items():
        print(f"  {k[:12]:12s}: realized mean={v['realized_mean']:.3f} "
              f"p95={v['realized_p95']:.3f} max={v['realized_max']:.3f} @{v['realized_max_at']}; "
              f"one-period mean={v['one_mean']:.3f} p95={v['one_p95']:.3f} max={v['one_max']:.3f}")
        print(f"  {'':12s}  conditional on trailing 3m: {v['cond_mean']} n={v['cond_n']}")


def print_table_e(res):
    print("\nE: outage at the steepest rise:")
    for s in res["E_outage"]:
        print(f"  {s['path'][:12]:12s} outage={s['outage_months']}: dark={s['dark_months']} "
              f"short={s['shortfall_months']} min_tcr={s['min_tcr']:.3f} "
              f"bad=${s['bad_debt_usd']:,.0f} liq={s['liq_count']} "
              f"delay_max={s['settle_delay_max']} cancelled={s['cancelled']}")


if __name__ == "__main__":
    main(sys.argv)
