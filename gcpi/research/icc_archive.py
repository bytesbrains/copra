#!/usr/bin/env python3
"""
GCPI Phase 1 (#87): the International Coconut Community's weekly copra prices, 2016 onwards.

Downloads ICC's monthly "Prices of Coconut Products" PDFs (one weekly column per Friday or Saturday),
extracts every copra row with pdftotext, and reports per-series coverage, cross-market correlation of
monthly changes and recent price levels. The PDFs are "All Rights Reserved" by ICC, so they are cached
locally and never committed; this script is how the numbers in gcpi/SOURCES.md are reproduced.

Usage: icc_archive.py <cache dir> [first YYYY-MM] [last YYYY-MM]
Needs: pdftotext (poppler). Stdlib only otherwise.
"""

import collections
import json
import math
import os
import re
import statistics as st
import subprocess
import sys
import time
import urllib.request

URL = "https://coconutcommunity.org/storage/files/document/wpu{ym}.pdf"
UA = {"User-Agent": "GCPI-research (https://github.com/bytesbrains/copra)"}
DATE = re.compile(r"\d{2}/\d{2}/\d{4}")
ROW = re.compile(r"^\s*Copra\s{2,}(.+?)\s{2,}((?:[\d,.]+|n\.q\.|-)(?:\s+(?:[\d,.]+|n\.q\.|-))*)\s*$")


def months(first, last):
    y, m = map(int, first.split("-"))
    while f"{y:04d}-{m:02d}" <= last:
        yield f"{y:04d}-{m:02d}"
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)


def next_month(ym):
    y, m = map(int, ym.split("-"))
    return f"{y + m // 12:04d}-{m % 12 + 1:02d}"


def fetch(cache, ym):
    """Returns the cached PDF's path, downloading it first if needed, or None if ICC has no PDF."""
    pdf = os.path.join(cache, f"wpu{ym}.pdf")
    if not os.path.exists(pdf):
        try:
            with urllib.request.urlopen(urllib.request.Request(URL.format(ym=ym), headers=UA), timeout=60) as r:
                body = r.read()
        except Exception as e:
            print(f"missing {ym}: {e}", file=sys.stderr)
            return None
        if not body.startswith(b"%PDF"):
            print(f"missing {ym}: not a PDF", file=sys.stderr)
            return None
        with open(pdf, "wb") as f:
            f.write(body)
        time.sleep(0.3)
    return pdf


def text_of(pdf):
    return subprocess.run(["pdftotext", "-layout", pdf, "-"], capture_output=True, text=True, check=True).stdout


def iso_date(ym, d):
    """A header date as YYYY-MM-DD. ICC writes DD/MM/YYYY, except 2016-10..2017-02, which used
    MM/DD/YYYY. Each report covers one month, so the reading whose month is the report's wins; a date
    that fits neither reading is an error, never a guess."""
    a, b, y = d.split("/")
    month = ym[5:]
    readings = {f"{y}-{b}-{a}", f"{y}-{a}-{b}"}  # DD/MM, then MM/DD
    fits = [r for r in readings if r[5:7] == month and r[:4] == ym[:4]]
    if len(fits) != 1:
        raise ValueError(f"{ym}: header date {d} is not in the report's month")
    return fits[0]


MONTH_NAMES = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
               "October", "November", "December"]


class Misfiled(Exception):
    """The file for one month holds another month's report (ICC's wpu2026-01.pdf is August 2026)."""


def report_month(ym, lines):
    """The month a report covers, from its own title line ("October 2026"), which must match the file."""
    for line in lines[:6]:
        # Full names, or the three-letter forms some reports use ("Jun 2022"), with an optional "Sept".
        m = re.search(r"\b(" + "|".join(n[:3] for n in MONTH_NAMES) + r")[a-z]*\.?\s+(\d{4})\b", line)
        if m:
            month = [n[:3] for n in MONTH_NAMES].index(m.group(1))
            title = f"{m.group(2)}-{month + 1:02d}"
            if title != ym:
                raise Misfiled(f"{ym}: file holds the {MONTH_NAMES[month]} {m.group(2)} report")
            return title
    raise ValueError(f"{ym}: no month title")


def parse(ym, text):
    """One record per (series, weekly date). A month whose copra rows do not all parse is an error."""
    lines = text.splitlines()
    report_month(ym, lines)
    header = next((l for l in lines if len(DATE.findall(l)) >= 2), None)
    if header is None:
        raise ValueError(f"{ym}: no date header")
    dates = [iso_date(ym, d) for d in DATE.findall(header)]
    raw = [l for l in lines if re.match(r"^\s*copra\b", l, re.I) and "meal" not in l.lower()]
    out = []
    for line in raw:
        m = ROW.match(line)
        if not m:
            raise ValueError(f"{ym}: unparsed copra row: {line.strip()}")
        series = re.sub(r"\s+", " ", m.group(1)).strip()
        # No ICC copra label contains a digit; one that does has swallowed a price column.
        if re.search(r"\d", series):
            raise ValueError(f"{ym}: unparsed copra row: {line.strip()}")
        for d, v in zip(dates, m.group(2).split()):
            out.append({"date": d, "series": series,
                        "usd_t": None if v in ("n.q.", "-") else float(v.replace(",", ""))})
    return out


def report(rows):
    print("## Coverage by series (weekly observations)")
    cov = collections.defaultdict(lambda: [0, 0, None, None])
    for r in rows:
        c = cov[r["series"]]
        c[0] += 1
        if r["usd_t"] is not None:
            c[1] += 1
            c[2] = min(c[2] or r["date"], r["date"])
            c[3] = max(c[3] or r["date"], r["date"])
    for s, (n, q, a, b) in sorted(cov.items(), key=lambda x: x[1][2] or ""):
        print(f"  {s:42s} quoted {q:4d} of {n:4d} weeks listed, {a} .. {b}")

    country = lambda s: s.split(" (")[0]
    monthly = collections.defaultdict(list)
    for r in rows:
        if r["usd_t"] is not None:
            monthly[(country(r["series"]), r["date"][:7])].append(r["usd_t"])
    mean = {k: st.mean(v) for k, v in monthly.items()}
    countries = sorted({c for c, _ in mean})
    yms = sorted({ym for _, ym in mean})
    # Calendar-adjacent months only: a missing month must not turn a two-month move into a one-month one.
    change = {c: {b: math.log(mean[(c, b)] / mean[(c, a)]) for a, b in zip(yms, yms[1:])
                  if b == next_month(a) and (c, a) in mean and (c, b) in mean} for c in countries}

    print("\n## Correlation of monthly log changes (US$ terms, series renames merged per country)")
    for i, a in enumerate(countries):
        for b in countries[i + 1:]:
            k = sorted(set(change[a]) & set(change[b]))
            r = st.correlation([change[a][x] for x in k], [change[b][x] for x in k])
            print(f"  {a:12s} {b:12s} r = {r:+.2f}  (n = {len(k)} months)")

    last12 = yms[-13:]
    print(f"\n## Mean level, US$/t, {last12[0]} .. {last12[-1]}")
    for c in countries:
        v = [mean[(c, ym)] for ym in last12 if (c, ym) in mean]
        print(f"  {c:12s} {st.mean(v):6.0f}  ({len(v)} months)")


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cache = argv[1]
    os.makedirs(cache, exist_ok=True)
    first = argv[2] if len(argv) > 2 else "2016-01"
    last = argv[3] if len(argv) > 3 else time.strftime("%Y-%m")
    rows, have, failed, misfiled = [], 0, [], []
    for ym in months(first, last):
        pdf = fetch(cache, ym)
        if pdf is None:
            continue
        have += 1
        # A month that does not parse is reported and the run continues, but the run fails: skipping it
        # silently would understate coverage. A cached PDF that is truncated fails the same way every time,
        # so the message names the file to delete.
        try:
            rows += parse(ym, text_of(pdf))
        except Misfiled as e:
            # A publisher error, not a parse failure: the month is missing from ICC's archive.
            misfiled.append(ym)
            print(f"misfiled {e}; {ym} counted as missing", file=sys.stderr)
        except (ValueError, subprocess.CalledProcessError) as e:
            failed.append(ym)
            print(f"unparsed {ym}: {e} (cached file: {pdf})", file=sys.stderr)
    print(f"ICC monthly price PDFs found: {have} ({first} .. {last}), unparsed: {', '.join(failed) or 'none'}, "
          f"misfiled: {', '.join(misfiled) or 'none'}\n")
    report(rows)
    with open(os.path.join(cache, "icc_copra.json"), "w") as f:
        json.dump(rows, f)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
