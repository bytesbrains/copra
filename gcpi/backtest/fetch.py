#!/usr/bin/env python3
"""
GCPI Phase 2 (#88): downloads every input of the backtest into a local cache directory.

The raw source data is not committed: Phase 1 (gcpi/SOURCES.md) found no stated republication terms for
PSA, CDB or the World Bank file, and ICC's reports are all rights reserved. This script rebuilds it from
the publishers in one run; backtest.py then reads only the cache.

Usage: fetch.py <cache dir> [--refresh]
Needs: pdftotext (poppler) for ICC. Stdlib only otherwise. Files already in the cache are reused unless
--refresh is given; ICC PDFs are always reused.
"""

import json
import os
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "research"))
import cdb_copra  # noqa: E402
import icc_archive  # noqa: E402
import psa_copra  # noqa: E402

UA = {"User-Agent": "GCPI-research (https://github.com/bytesbrains/copra)"}

# Plain downloads: cache name -> URL.
FILES = {
    # World Bank monthly commodity file, current edition: coconut oil to date, no copra.
    "wb_current.xlsx": "https://thedocs.worldbank.org/en/doc/74e8be41ceb20fa0da750cda2f6b9e4e-0050012026/related/CMO-Historical-Data-Monthly.xlsx",
    # The same file as archived on 2020-05-28, the last edition with copra (CIF N.W. Europe, 1960-01..2020-04).
    "wb_2020.xlsx": "https://web.archive.org/web/20200528064917id_/http://pubdocs.worldbank.org/en/561011486076393416/CMO-Historical-Data-Monthly.xlsx",
    # ECB euro reference rates, daily since 1999: USD, PHP, INR, IDR cross through EUR.
    "ecb.zip": "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-hist.zip",
    # US CPI-U, monthly, for real returns in USD.
    "us_cpi.csv": "https://fred.stlouisfed.org/graph/fredgraph.csv?id=CPIAUCSL",
    # FAOSTAT production and trade, for weights.
    "fao_production.zip": "https://bulks-faostat.fao.org/production/Production_Crops_Livestock_E_All_Data_(Normalized).zip",
    "fao_trade.zip": "https://bulks-faostat.fao.org/production/Trade_CropsLivestock_E_All_Data_(Normalized).zip",
}

CDB_MARKETS = ("1", "2", "3")  # Kochi, Alappuzha, Kozhikode
FIRST_YEAR = 2008


def download(url, path):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=1200) as r, open(path + ".part", "wb") as f:
        while chunk := r.read(1 << 20):
            f.write(chunk)
    os.replace(path + ".part", path)


def cached(cache, name, refresh):
    path = os.path.join(cache, name)
    return path if os.path.exists(path) and not refresh else None


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cache, refresh = argv[1], "--refresh" in argv
    os.makedirs(cache, exist_ok=True)
    this_year = int(time.strftime("%Y"))

    for name, url in FILES.items():
        if not cached(cache, name, refresh):
            print(f"downloading {name}")
            download(url, os.path.join(cache, name))

    if not cached(cache, "psa.json", refresh):
        print("PSA copra farmgate prices")
        title, rows = psa_copra.series()
        listing = psa_copra.get(psa_copra.TABLE.rsplit("/", 1)[0])
        updated = next(t["updated"] for t in listing if psa_copra.TABLE.endswith(t["id"]))
        json.dump({"title": title, "table_updated": updated, "fetched": time.strftime("%Y-%m-%d"), "rows": rows},
                  open(os.path.join(cache, "psa.json"), "w"))

    if not cached(cache, "cdb.json", refresh):
        print("CDB milling copra: monthly by market, daily for Kochi")
        out = {"monthly": {}, "daily_kochi": []}
        for m in CDB_MARKETS:
            out["monthly"][cdb_copra.MARKETS[m]] = {
                str(y): cdb_copra.monthly(m, y) for y in range(FIRST_YEAR, this_year + 1)}
        for y in range(FIRST_YEAR, this_year + 1):
            out["daily_kochi"] += cdb_copra.daily("1", f"01/01/{y}", f"31/12/{y}")
            time.sleep(0.3)
        json.dump(out, open(os.path.join(cache, "cdb.json"), "w"))

    print("ICC weekly price reports")
    icc_dir = os.path.join(cache, "icc")
    os.makedirs(icc_dir, exist_ok=True)
    rows = []
    for ym in icc_archive.months("2016-01", time.strftime("%Y-%m")):
        pdf = icc_archive.fetch(icc_dir, ym)
        if pdf:
            try:
                rows += icc_archive.parse(ym, icc_archive.text_of(pdf))
            except icc_archive.Misfiled as e:
                print(f"  misfiled {e}; counted as missing")
    json.dump(rows, open(os.path.join(cache, "icc.json"), "w"))

    print(f"cache ready: {cache}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
