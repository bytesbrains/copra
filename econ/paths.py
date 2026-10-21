#!/usr/bin/env python3
"""
COPRA-001 economics (#96): build the replay paths the simulation runs on.

The GCPI headline has no open input yet (BACKTEST.md: PSA broke in 2024, ICC is all
rights reserved), so there is no true "historical GCPI" to replay. These four paths are
the closest open copra-price history, each a different regime:

- export_copra: World Bank export copra, CIF N.W. Europe, 1960-01..2014-12. The only
  path with a 1973-scale shock. Pinned to the 2020 edition vintage (BACKTEST.md data
  quality finding 3).
- coconut_oil: World Bank coconut oil, 1960-01..2026-09, current edition. Correlated
  commodity, longest coverage; a robustness check, not a copra price.
- cdb_kochi: CDB Kochi milling copra in USD, 2009-01..2026-10, from dataset.csv.
  Recent-regime domestic path.
- psa_resecada: PSA Resecada farmgate in USD, 2010-01..2023-12, from dataset.csv,
  pre-break months only. Recent-regime Philippine path.

World Bank data: CC BY-4.0, https://www.worldbank.org/en/about/legal/terms-of-use.
CDB/PSA columns repeat the derived monthly facts already published in dataset.csv.

Usage: paths.py <wb cache dir>
The cache dir holds wb_2020.xlsx and wb_current.xlsx (see gcpi/backtest/fetch.py FILES).
Always writes econ/data/paths.csv next to this script. Stdlib only.
"""

import csv
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "gcpi", "backtest"))
import load  # noqa: E402

DATASET = os.path.join(HERE, "..", "gcpi", "backtest", "data", "dataset.csv")


def build(cache):
    wb20 = load.load_wb(os.path.join(cache, "wb_2020.xlsx"))
    wbcur = load.load_wb(os.path.join(cache, "wb_current.xlsx"))
    export = wb20["Copra"]
    oil = wbcur["Coconut oil"]
    cdb, psa = {}, {}
    with open(DATASET, newline="") as f:
        for r in csv.DictReader(f):
            if r["cdb_kochi_milling_usd_kg"]:
                cdb[r["month"]] = float(r["cdb_kochi_milling_usd_kg"])
            if r["psa_resecada_usd_kg"] and r["psa_after_break"] == "0":
                psa[r["month"]] = float(r["psa_resecada_usd_kg"])
    months = sorted(set(export) | set(oil) | set(cdb) | set(psa))
    return months, {"export_copra": export, "coconut_oil": oil,
                    "cdb_kochi": cdb, "psa_resecada": psa}


def write(months, paths, out):
    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["month", "export_copra_usd_kg", "coconut_oil_usd_kg",
                    "cdb_kochi_usd_kg", "psa_resecada_usd_kg"])
        for m in months:
            row = [m]
            for k in ("export_copra", "coconut_oil", "cdb_kochi", "psa_resecada"):
                v = paths[k].get(m)
                row.append("" if v is None else f"{v:.6f}")
            w.writerow(row)


def main(argv):
    if len(argv) != 2:
        sys.exit("usage: paths.py <wb cache dir>")
    cache = argv[1]
    out = os.path.join(HERE, "data", "paths.csv")
    months, paths = build(cache)
    write(months, paths, out)
    for k, v in paths.items():
        ks = sorted(v)
        print(f"{k}: {len(ks)} months {ks[0]} -> {ks[-1]}")
    print(f"wrote {out}")


if __name__ == "__main__":
    main(sys.argv)
