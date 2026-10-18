#!/usr/bin/env python3
"""
GCPI Phase 2 (#88): reads the cache fetch.py builds. Each loader returns plain series, {"YYYY-MM": value},
or the raw records backtest.py needs; no statistics here.
"""

import collections
import csv
import io
import json
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
    header = next((r for r in rows[:10] if any(str(v).strip() == "Coconut oil" for v in r.values())), None)
    if header is None:
        raise ValueError(f"{path}: no 'Coconut oil' header in the first 10 rows of {worldbank_cmo.SHEET}")
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
