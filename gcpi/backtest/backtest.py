#!/usr/bin/env python3
"""
GCPI Phase 2 (#88): the methodology backtest.

Reads the cache built by fetch.py, assembles monthly copra prices in USD/kg per market, and tests the
GCPI-001 choices #88 lists: correlations and spreads, delays and missing data, weighting, missing-market
handling, anomaly thresholds, coverage, cadence, and the outputs COPRA-001 needs (R(h), finalization
delays, long-run real return). Writes results.json and the derived index series to an output directory,
and prints a summary. gcpi/BACKTEST.md reports the results.

Usage: backtest.py <cache dir> <out dir>
"""

import collections
import csv
import datetime
import io
import json
import math
import os
import re
import statistics as st
import sys
import xml.etree.ElementTree as ET
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "research"))
import worldbank_cmo  # noqa: E402

MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
          "October", "November", "December"]
NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"

# GCPI-001 §7.3 bands, as upper bounds of |relative change| per period.
BANDS = [(0.05, "normal"), (0.10, "corroborate"), (0.20, "confirm"), (math.inf, "quarantine")]

# Episodes #88 asks to include: coconut oil roughly halved (2017-2019) and roughly doubled (2024-2025).
EPISODES = {"2017-2019 fall": ("2017-01", "2019-12"), "2024-2025 rise": ("2024-01", "2025-12")}

# PSA's copra series stops tracking the market from January 2024 (R["psa_break"]); months from here on
# are not used as market evidence.
PSA_BREAK = "2024-01"


# ------------------------------------------------------------------------------------------------
# Month arithmetic and series helpers. A series is a dict {"YYYY-MM": value}.

def ym_add(ym, n):
    y, m = map(int, ym.split("-"))
    m += n
    y, m = y + (m - 1) // 12, (m - 1) % 12 + 1
    return f"{y:04d}-{m:02d}"


def ym_range(first, last):
    out, ym = [], first
    while ym <= last:
        out.append(ym)
        ym = ym_add(ym, 1)
    return out


def log_changes(series):
    """Log change between consecutive months, only where both months are present."""
    return {ym: math.log(series[ym] / series[ym_add(ym, -1)])
            for ym in series if ym_add(ym, -1) in series}


def correlation(a, b):
    keys = sorted(set(a) & set(b))
    if len(keys) < 12:
        return None, len(keys)
    return st.correlation([a[k] for k in keys], [b[k] for k in keys]), len(keys)


def longest_gap(series, first, last):
    """Longest run of consecutive missing months inside [first, last]."""
    best = run = 0
    for ym in ym_range(first, last):
        run = 0 if ym in series else run + 1
        best = max(best, run)
    return best


# ------------------------------------------------------------------------------------------------
# Aggregation. panel: {market: series}; weights: {market: w}.

def renormalized(panel, weights, months):
    """GCPI-001 §8.1: weighted arithmetic mean of the markets present, weights renormalized."""
    out = {}
    for ym in months:
        live = [m for m in weights if weights[m] > 0 and ym in panel.get(m, {})]
        if live:
            out[ym] = sum(weights[m] * panel[m][ym] for m in live) / sum(weights[m] for m in live)
    return out


def chain_linked(panel, weights, months):
    """Matched-market chain link: each period moves from the last period with a value by the weighted
    mean log change of the markets present in both. Anchored on the renormalized level of the first
    period, so the two methods start equal. A period with no matched market has no value."""
    out, last = {}, None
    for ym in months:
        if last is None:
            first = renormalized(panel, weights, [ym])
            if first:
                out[ym], last = first[ym], ym
            continue
        matched = [m for m in weights if weights[m] > 0 and ym in panel.get(m, {}) and last in panel.get(m, {})]
        if not matched:
            continue
        change = sum(weights[m] * math.log(panel[m][ym] / panel[m][last]) for m in matched)
        out[ym] = out[last] * math.exp(change / sum(weights[m] for m in matched))
        last = ym
    return out


def outage_effect(panel, weights, months, market, length):
    """Simulates `market` missing for `length` months at every possible start inside `months` and
    returns, per method, the largest |log| gap to the same method without the outage: during the outage
    (a jump) and 12 months after it ends (a lasting drift)."""
    full = {"renormalized": renormalized(panel, weights, months), "chain_linked": chain_linked(panel, weights, months)}
    worst = {k: {"during": 0.0, "after_12m": 0.0} for k in full}
    for i in range(1, len(months) - length - 12):
        gap = set(months[i:i + length])
        cut = dict(panel)
        cut[market] = {k: v for k, v in panel[market].items() if k not in gap}
        for name, fn in (("renormalized", renormalized), ("chain_linked", chain_linked)):
            idx = fn(cut, weights, months)
            during = [abs(math.log(idx[k] / full[name][k])) for k in gap if k in idx and k in full[name]]
            after = months[i + length + 11]
            # A gap month where every market is missing has no value to compare.
            worst[name]["during"] = max([worst[name]["during"]] + during)
            if after in idx and after in full[name]:
                worst[name]["after_12m"] = max(worst[name]["after_12m"], abs(math.log(idx[after] / full[name][after])))
    return worst


# ------------------------------------------------------------------------------------------------
# Risk statistics.

def quantile(values, q):
    s = sorted(values)
    if not s:
        return None
    pos = q * (len(s) - 1)
    lo, hi = math.floor(pos), math.ceil(pos)
    return s[lo] + (s[hi] - s[lo]) * (pos - lo)


def rises(series, h):
    """Relative rise over h consecutive months, for every start where both ends exist."""
    return [series[ym_add(ym, h)] / series[ym] - 1 for ym in series if ym_add(ym, h) in series]


def r_of_h(series, horizons=(1, 2, 3, 4, 6)):
    """COPRA-001 §13.2 R(h): the rise over h periods at a tolerance, and the historical maximum."""
    out = {}
    for h in horizons:
        r = rises(series, h)
        if len(r) < 24:
            continue
        out[h] = {"n": len(r), "p95": quantile(r, 0.95), "p99": quantile(r, 0.99), "max": max(r),
                  "max_at": max((ym for ym in series if ym_add(ym, h) in series),
                                key=lambda ym: series[ym_add(ym, h)] / series[ym])}
    return out


def band(change):
    for bound, name in BANDS:
        if abs(change) <= bound:
            return name
    return BANDS[-1][1]


def band_counts(series):
    """§7.3 band of each period's relative change."""
    counts = collections.Counter(band(series[ym] / series[ym_add(ym, -1)] - 1)
                                 for ym in series if ym_add(ym, -1) in series)
    return {name: counts.get(name, 0) for _, name in BANDS}


def episode_moves(series, first, last):
    window = {k: v for k, v in series.items() if first <= k <= last}
    if len(window) < 2:
        return None
    lo = min(window, key=window.get)
    hi = max(window, key=window.get)
    changes = [window[k] / window[ym_add(k, -1)] - 1 for k in window if ym_add(k, -1) in window]
    return {"start": window[min(window)], "end": window[max(window)], "low": [lo, window[lo]],
            "high": [hi, window[hi]], "largest_monthly_rise": max(changes), "largest_monthly_fall": min(changes),
            "bands": band_counts(window)}


def coverage(panel, weights, months, min_markets=3, min_weight=0.70):
    """§8.3: share of months meeting both the market-count and weight-share thresholds."""
    total = sum(weights.values())
    met, rows = 0, []
    for ym in months:
        live = [m for m in weights if ym in panel.get(m, {})]
        share = sum(weights[m] for m in live) / total
        ok = len(live) >= min_markets and share >= min_weight
        met += ok
        rows.append((ym, len(live), share))
    return {"months": len(months), "met": met, "share_met": met / len(months) if months else None,
            "min_markets_seen": min(r[1] for r in rows), "min_weight_seen": min(r[2] for r in rows)}


def staleness(daily):
    """Daily (date 'DD-MM-YYYY', value) pairs: per year, the share of days equal to the previous day."""
    by_year = collections.defaultdict(lambda: [0, 0, 0])
    for (_, a), (d, b) in zip(daily, daily[1:]):
        y = d[-4:]
        by_year[y][0] += 1
        by_year[y][1] += a == b
    weekly = collections.defaultdict(list)
    for d, v in daily:
        dt = datetime.datetime.strptime(d, "%d-%m-%Y").date()
        weekly[dt.isocalendar()[:2]].append(v)
    weeks = sorted(weekly)
    unchanged_weeks = sum(1 for a, b in zip(weeks, weeks[1:]) if weekly[a][-1] == weekly[b][-1])
    return {"by_year": {y: {"days": n, "same_as_previous": s, "share": s / n} for y, (n, s, _) in sorted(by_year.items())},
            "weeks": len(weeks) - 1, "weeks_unchanged": unchanged_weeks,
            "share_weeks_unchanged": unchanged_weeks / (len(weeks) - 1) if len(weeks) > 1 else None}


def real_return(series, cpi, first=None, last=None):
    """Annualized real (CPI-deflated) and nominal log return between the first and last months."""
    keys = sorted(k for k in series if k in cpi and (first is None or k >= first) and (last is None or k <= last))
    if len(keys) < 24:
        return None
    a, b = keys[0], keys[-1]
    years = (int(b[:4]) * 12 + int(b[5:]) - int(a[:4]) * 12 - int(a[5:])) / 12
    nominal = math.log(series[b] / series[a]) / years
    real = nominal - math.log(cpi[b] / cpi[a]) / years
    return {"from": a, "to": b, "years": round(years, 1), "nominal_pa": math.expm1(nominal), "real_pa": math.expm1(real)}


def rolling_real(series, cpi, years=10):
    """Annualized real return over every `years`-year window: how often it was positive."""
    out = []
    for a in sorted(series):
        b = ym_add(a, years * 12)
        if b in series and a in cpi and b in cpi:
            out.append(math.expm1((math.log(series[b] / series[a]) - math.log(cpi[b] / cpi[a])) / years))
    if not out:
        return None
    return {"windows": len(out), "share_positive": sum(r > 0 for r in out) / len(out),
            "median": st.median(out), "min": min(out), "max": max(out)}


# ------------------------------------------------------------------------------------------------
# Loading the cache.

def load_psa(cache):
    d = json.load(open(os.path.join(cache, "psa.json")))
    out = collections.defaultdict(dict)
    for r in d["rows"]:
        if r["php_kg"] is not None:
            out[r["Commodity"]][f"{r['Year']}-{MONTHS.index(r['Period']) + 1:02d}"] = r["php_kg"]
    return d, out


def load_cdb(cache):
    d = json.load(open(os.path.join(cache, "cdb.json")))
    monthly = {}
    for market, years in d["monthly"].items():
        s = {}
        for y, rows in years.items():
            for period, v in rows:
                s[f"{y}-{MONTHS.index(period) + 1:02d}"] = v
        monthly[market] = s
    return monthly, [tuple(x) for x in d["daily_kochi"]]


def load_icc(cache):
    rows = json.load(open(os.path.join(cache, "icc.json")))
    country = lambda s: s.split(" (")[0]
    weekly = collections.defaultdict(dict)
    for r in rows:
        if r["usd_t"] is not None:
            weekly[country(r["series"])].setdefault(r["date"], []).append(r["usd_t"])
    weekly = {c: {d: st.mean(v) for d, v in s.items()} for c, s in weekly.items()}
    monthly = {c: {} for c in weekly}
    for c, s in weekly.items():
        by = collections.defaultdict(list)
        for d, v in s.items():
            by[d[:7]].append(v)
        monthly[c] = {ym: st.mean(v) / 1000 for ym, v in by.items()}
    return weekly, monthly


def load_wb(path):
    z = zipfile.ZipFile(path)
    strings = ["".join(t.text or "" for t in si.iter(NS + "t"))
               for si in ET.fromstring(z.read("xl/sharedStrings.xml")).findall(NS + "si")]
    rows = []
    for r in ET.fromstring(z.read(worldbank_cmo.sheet_path(z, worldbank_cmo.SHEET))).iter(NS + "row"):
        row = {}
        for c in r.findall(NS + "c"):
            v = c.find(NS + "v")
            if v is not None:
                row[re.match(r"[A-Z]+", c.get("r")).group()] = strings[int(v.text)] if c.get("t") == "s" else v.text
        rows.append(row)
    header = next(r for r in rows[:10] if any(str(v).strip() == "Coconut oil" for v in r.values()))
    out = {}
    for col, name in header.items():
        if str(name).strip() in ("Copra", "Coconut oil"):
            s = {}
            for r in rows:
                m = re.fullmatch(r"(\d{4})M(\d\d)", str(r.get("A", "")))
                try:
                    if m and r.get(col) not in (None, ""):
                        s[f"{m.group(1)}-{m.group(2)}"] = float(r[col]) / 1000
                except ValueError:
                    pass
            out[str(name).strip()] = s
    return out


def load_fx(cache):
    """Monthly mean local currency per USD, from ECB EUR cross rates."""
    z = zipfile.ZipFile(os.path.join(cache, "ecb.zip"))
    rows = list(csv.DictReader(io.TextIOWrapper(z.open(z.namelist()[0]))))
    by = collections.defaultdict(lambda: collections.defaultdict(list))
    for r in rows:
        try:
            usd = float(r["USD"])
        except ValueError:
            continue
        for cur in ("PHP", "INR", "IDR"):
            try:
                rate = float(r[cur]) / usd
            except (ValueError, KeyError):
                continue
            by[cur][r["Date"][:7]].append(rate)
    return {cur: {ym: st.mean(v) for ym, v in s.items()} for cur, s in by.items()}


def load_cpi(cache):
    out = {}
    for r in csv.DictReader(open(os.path.join(cache, "us_cpi.csv"))):
        try:
            out[r["observation_date"][:7]] = float(r["CPIAUCSL"])
        except (ValueError, KeyError):
            pass
    return out


FAO_AREAS = {"Philippines": "PH", "Indonesia": "ID", "India": "IN", "Sri Lanka": "LK"}


def load_fao(cache, years=("2021", "2022", "2023")):
    """Weights: coconut oil production (tonnes) and copra + coconut oil export value (1000 USD),
    averaged over `years`."""
    prod = collections.defaultdict(list)
    with zipfile.ZipFile(os.path.join(cache, "fao_production.zip")) as z:
        name = next(n for n in z.namelist() if n.endswith("(Normalized).csv"))
        for r in csv.DictReader(io.TextIOWrapper(z.open(name), encoding="latin-1")):
            if r["Area"] in FAO_AREAS and r["Item"] == "Coconut oil" and r["Element"] == "Production" and r["Year"] in years:
                prod[FAO_AREAS[r["Area"]]].append(float(r["Value"] or 0))
    exports = collections.defaultdict(lambda: collections.defaultdict(float))
    items = set()
    with zipfile.ZipFile(os.path.join(cache, "fao_trade.zip")) as z:
        name = next(n for n in z.namelist() if n.endswith("(Normalized).csv"))
        for r in csv.DictReader(io.TextIOWrapper(z.open(name), encoding="latin-1")):
            if r["Area"] in FAO_AREAS and r["Year"] in years and r["Element"] == "Export value" \
                    and (r["Item"] == "Copra" or r["Item"] == "Coconut oil"):
                items.add(r["Item"])
                exports[FAO_AREAS[r["Area"]]][r["Year"]] += float(r["Value"] or 0)
    production = {k: st.mean(v) for k, v in prod.items()}
    export_value = {k: st.mean(v.values()) for k, v in exports.items()}
    share = lambda d: {k: v / sum(d.values()) for k, v in d.items()}
    return {"years": list(years), "items_found": sorted(items),
            "production_t": production, "production_share": share(production),
            "export_value_kusd": export_value, "export_share": share(export_value)}


# ------------------------------------------------------------------------------------------------

def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 2
    cache, out_dir = argv[1], argv[2]
    os.makedirs(out_dir, exist_ok=True)
    R = {"generated": datetime.date.today().isoformat()}

    psa_meta, psa = load_psa(cache)
    cdb, kochi_daily = load_cdb(cache)
    icc_weekly, icc = load_icc(cache)
    wb_now, wb_2020 = load_wb(os.path.join(cache, "wb_current.xlsx")), load_wb(os.path.join(cache, "wb_2020.xlsx"))
    fx, cpi = load_fx(cache), load_cpi(cache)

    # Monthly USD/kg. The four markets come from one publisher each where possible: the Philippines and
    # Indonesia from ICC (the only consistent pair, 2016-), India from CDB, Sri Lanka from ICC. PSA is
    # tested separately: its copra series breaks in 2024 (R["psa_break"]).
    usd = lambda local, cur: {ym: v / fx[cur][ym] for ym, v in local.items() if ym in fx[cur]}
    psa_usd = {g: usd(psa[g], "PHP") for g in ("Copra Resecada", "Copra Corriente")}
    cdb_usd = {m: usd({ym: v / 100 for ym, v in s.items()}, "INR") for m, s in cdb.items()}
    panel = {"PH": icc["Philippines"], "ID": icc["Indonesia"], "IN": cdb_usd["Kochi"], "LK": icc["Sri Lanka"]}
    psa_clean = {ym: v for ym, v in psa_usd["Copra Resecada"].items() if ym < PSA_BREAK}
    export_copra = wb_2020["Copra"]
    coconut_oil = {**wb_2020["Coconut oil"], **wb_now["Coconut oil"]}
    R["series"] = {m: {"first": min(s), "last": max(s), "months": len(s)} for m, s in
                   {**panel, "PSA_resecada": psa_usd["Copra Resecada"], "export_copra_cif_nw_europe": export_copra,
                    "coconut_oil": coconut_oil}.items()}

    # 1. Correlations and spreads.
    names = ["PH", "ID", "IN", "LK"]
    ch = {m: log_changes(s) for m, s in panel.items()}
    R["correlation_usd"] = {f"{a}-{b}": dict(zip(("r", "n"), correlation(ch[a], ch[b])))
                            for i, a in enumerate(names) for b in names[i + 1:]}
    R["correlation_local_PSA_CDB"] = dict(zip(("r", "n"), correlation(
        log_changes({k: v for k, v in psa["Copra Resecada"].items() if k < PSA_BREAK}), log_changes(cdb["Kochi"]))))
    lagged = {}
    for m, s in {**panel, "PSA_2010_2023": psa_clean}.items():
        for ref_name, ref in (("export_copra", export_copra), ("coconut_oil", coconut_oil)):
            for lag in (0, 1, 2):
                shifted = {ym_add(k, lag): v for k, v in log_changes(ref).items()}
                lagged[f"{m}_vs_{ref_name}_lag{lag}"] = dict(zip(("r", "n"), correlation(log_changes(s), shifted)))
    R["correlation_vs_export"] = lagged
    spreads = {}
    for m in ("ID", "IN", "LK"):
        ratios = {ym: panel[m][ym] / panel["PH"][ym] for ym in panel[m] if ym in panel["PH"]}
        by_year = collections.defaultdict(list)
        for ym, v in ratios.items():
            by_year[ym[:4]].append(v)
        spreads[m] = {"mean_ratio_to_PH": st.mean(ratios.values()), "min": min(ratios.values()),
                      "max": max(ratios.values()), "by_year": {y: st.mean(v) for y, v in sorted(by_year.items())}}
    R["spread_vs_PH"] = spreads

    # PSA against ICC's Philippine series, before and after the break.
    variants = {"resecada": psa["Copra Resecada"], "corriente": psa["Copra Corriente"],
                "mean": {k: (v + psa["Copra Corriente"][k]) / 2 for k, v in psa["Copra Resecada"].items() if k in psa["Copra Corriente"]}}
    R["psa_break"] = {}
    for lo, hi in (("2010-01", ym_add(PSA_BREAK, -1)), (PSA_BREAK, "2099-12")):
        ref = {k: v for k, v in panel["PH"].items() if lo <= k <= hi}
        R["psa_break"][f"{lo}..{hi[:7] if hi < '2099' else 'latest'}"] = {
            n: {"r_vs_icc": correlation(log_changes(usd({k: v for k, v in s.items() if lo <= k <= hi}, "PHP")), log_changes(ref))[0],
                "quarantine_months": band_counts(usd({k: v for k, v in s.items() if lo <= k <= hi}, "PHP"))["quarantine"]}
            for n, s in variants.items()}
    R["psa_break"]["grade_inversions_by_year"] = dict(collections.Counter(
        k[:4] for k, v in psa["Copra Resecada"].items() if psa["Copra Corriente"].get(k, 0) > v))

    # 2. Delays and missing data.
    last_month = max(psa["Copra Resecada"])
    month_end = datetime.date.fromisoformat(ym_add(last_month, 1) + "-01") - datetime.timedelta(days=1)
    updated = datetime.date.fromisoformat(psa_meta["table_updated"][:10])
    R["delays"] = {"psa_table_updated": psa_meta["table_updated"], "psa_last_month": last_month,
                   "psa_days_after_month_end": (updated - month_end).days,
                   "psa_note": "one snapshot: OpenSTAT keeps no release history, so the lag's variation is unmeasured"}
    R["missing"] = {
        "PSA": {"longest_gap_months": longest_gap(psa["Copra Resecada"], "2010-01", last_month)},
        "export_copra": {"longest_gap_months": longest_gap(export_copra, min(export_copra), max(export_copra))},
    }
    for m, s in cdb.items():
        R["missing"][f"CDB_{m}"] = {"first": min(s), "longest_gap_months": longest_gap(s, min(s), max(s)),
                                   "months_missing": sum(ym not in s for ym in ym_range(min(s), max(s)))}
    for c, s in icc_weekly.items():
        dates = sorted(s)
        gaps = [(datetime.date.fromisoformat(b) - datetime.date.fromisoformat(a)).days for a, b in zip(dates, dates[1:])]
        R["missing"][f"ICC_{c}_weekly"] = {"weeks_quoted": len(dates), "longest_gap_days": max(gaps),
                                          "gaps_over_14_days": sum(g > 14 for g in gaps)}

    # 3. Weights: production vs exports, and how much the choice moves the headline.
    wd = load_fao(cache)
    R["weights"] = wd
    head_months = ym_range("2016-02", min(max(panel["PH"]), max(panel["ID"])))
    pair = lambda shares: shares["PH"] / (shares["PH"] + shares["ID"])
    head_w = {"PH": pair(wd["production_share"]), "ID": 1 - pair(wd["production_share"])}
    headline = chain_linked(panel, head_w, head_months)
    sens = {}
    for label, w_ph in (("production", head_w["PH"]), ("exports", pair(wd["export_share"])), ("equal", 0.5), ("PH_only", 1.0)):
        idx = chain_linked(panel, {"PH": w_ph, "ID": 1 - w_ph}, head_months)
        sens[label] = {"w_PH": w_ph, "max_abs_log_diff_vs_production": max(abs(math.log(idx[k] / headline[k])) for k in idx if k in headline),
                       "R": r_of_h(idx, (1, 3))}
    R["weight_sensitivity_headline"] = sens
    four_months = ym_range("2016-02", min(max(s) for s in panel.values()))
    for label, shares in (("production", wd["production_share"]), ("exports", wd["export_share"])):
        w = {m: shares[m] for m in names}
        R.setdefault("weight_sensitivity_four_markets", {})[label] = {
            "weights": w, "max_abs_log_diff_vs_production": None}
    four_p = {m: wd["production_share"][m] for m in names}
    four_e = {m: wd["export_share"][m] for m in names}
    cp, ce = chain_linked(panel, four_p, four_months), chain_linked(panel, four_e, four_months)
    R["weight_sensitivity_four_markets"]["exports"]["max_abs_log_diff_vs_production"] = max(
        abs(math.log(ce[k] / cp[k])) for k in ce if k in cp)

    # 4. Missing-market handling.
    R["missing_market_handling"] = {f"four markets, {m} missing {k}m": outage_effect(panel, four_p, four_months, m, k)
                                    for m in names for k in (1, 3)}
    for m in ("PH", "ID"):
        R["missing_market_handling"][f"headline, {m} missing 1m"] = outage_effect(panel, head_w, head_months, m, 1)

    # 5. Anomaly thresholds.
    monthly_sets = {**panel, "headline": headline, "PSA_2010_2023": psa_clean, "export_copra": export_copra}
    R["bands_monthly"] = {m: band_counts(s) for m, s in monthly_sets.items()}
    R["bands_weekly_icc"] = {}
    for c, s in icc_weekly.items():
        dates = sorted(s)
        counts = collections.Counter(band(s[b] / s[a] - 1) for a, b in zip(dates, dates[1:])
                                     if (datetime.date.fromisoformat(b) - datetime.date.fromisoformat(a)).days <= 8)
        R["bands_weekly_icc"][c] = {name: counts.get(name, 0) for _, name in BANDS}
    R["episodes"] = {e: {m: episode_moves(s, *span) for m, s in {**panel, "headline": headline, "coconut_oil": coconut_oil}.items()}
                     for e, span in EPISODES.items()}

    # 6. Coverage (§8.3): three markets and 70% of weight, on the four-market basket.
    R["coverage_four_markets"] = coverage(panel, four_p, four_months)
    R["coverage_headline_two_markets"] = coverage(panel, head_w, head_months, min_markets=2, min_weight=0.70)

    # 7. Cadence.
    R["cdb_daily_staleness"] = staleness(kochi_daily)

    # 8. COPRA-001 outputs.
    ph_weekly = icc_weekly["Philippines"]
    wk = sorted(ph_weekly)
    weekly = {h: [ph_weekly[wk[i + h]] / ph_weekly[wk[i]] - 1 for i in range(len(wk) - h)
                  if (datetime.date.fromisoformat(wk[i + h]) - datetime.date.fromisoformat(wk[i])).days <= 7 * h + 3]
              for h in (1, 2, 3, 4, 8)}
    R["R_of_h"] = {
        "headline_PH_ID_chain_linked_2016_2026": r_of_h(headline),
        "PSA_resecada_2010_2023": r_of_h(psa_clean),
        "export_copra_cif_1960_2014": r_of_h(export_copra),
        "four_markets_renormalized_2016_2026": r_of_h(renormalized(panel, four_p, four_months)),
        "PH_weekly_icc_2016_2026": {h: {"n": len(r), "p95": quantile(r, 0.95), "p99": quantile(r, 0.99), "max": max(r)}
                                    for h, r in weekly.items()},
    }
    R["real_return"] = {
        "export_copra_1960_2014": real_return(export_copra, cpi),
        "export_copra_1990_2014": real_return(export_copra, cpi, "1990-01"),
        "coconut_oil_1960_2026": real_return(coconut_oil, cpi),
        "coconut_oil_2000_2026": real_return(coconut_oil, cpi, "2000-01"),
        "PSA_resecada_usd_2010_2023": real_return(psa_clean, cpi),
        "export_copra_rolling_10y": rolling_real(export_copra, cpi, 10),
        "export_copra_rolling_20y": rolling_real(export_copra, cpi, 20),
        "coconut_oil_rolling_10y": rolling_real(coconut_oil, cpi, 10),
    }

    with open(os.path.join(out_dir, "results.json"), "w") as f:
        json.dump(R, f, indent=1, sort_keys=True, default=str)

    # The dataset: PSA and CDB monthly prices in local currency and USD, with the ECB rate used. ICC's
    # series are not included (all rights reserved); its data enters only through the statistics above.
    months = ym_range("2008-01", max(max(psa["Copra Resecada"]), max(cdb["Kochi"])))
    cols = [("psa_resecada_php_kg", psa["Copra Resecada"]), ("psa_corriente_php_kg", psa["Copra Corriente"]),
            ("cdb_kochi_milling_inr_quintal", cdb["Kochi"]), ("cdb_alappuzha_milling_inr_quintal", cdb["Alappuzha"]),
            ("cdb_kozhikode_milling_inr_quintal", cdb["Kozhikode"]),
            ("php_per_usd_ecb", fx["PHP"]), ("inr_per_usd_ecb", fx["INR"]),
            ("psa_resecada_usd_kg", psa_usd["Copra Resecada"]), ("cdb_kochi_milling_usd_kg", cdb_usd["Kochi"])]
    with open(os.path.join(out_dir, "dataset.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["month"] + [c for c, _ in cols] + ["psa_after_break"])
        for ym in months:
            if not any(ym in s for c, s in cols[:5]):
                continue
            w.writerow([ym] + [(f"{s[ym]:.4f}" if ym in s else "") for _, s in cols] + [int(ym >= PSA_BREAK)])
    print(json.dumps({k: R[k] for k in ("series", "correlation_usd", "psa_break")}, indent=1, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
