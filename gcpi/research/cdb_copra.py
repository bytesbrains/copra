#!/usr/bin/env python3
"""
GCPI Phase 1 (#87): India's Coconut Development Board milling copra prices (Rs/quintal), by market.

Drives the CDB price report form (an ASP.NET postback page; there is no API). Reports, per market, how
many months of each year have a monthly average, and for one recent window how many daily values are
reported and how many of them repeat the previous day's value: CDB fills every calendar day, including
Sundays, so a daily value does not show whether a trade or quote happened that day.

Usage: cdb_copra.py [first year] [last year] [daily window DD/MM/YYYY-DD/MM/YYYY]
The daily window is sampled for Kochi only (DAILY_MARKET), the market the report quotes.
"""

import html
import http.cookiejar
import re
import sys
import time
import urllib.parse
import urllib.request

URL = "https://coconutboard.in/priceweb/Reports.aspx"
MILLING_COPRA = "2"
MARKETS = {"1": "Kochi", "2": "Alappuzha", "3": "Kozhikode", "4": "Kangayam"}
MONTHLY, DAILY = "3", "1"
DAILY_MARKET = "1"  # Kochi

opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
opener.addheaders = [("User-Agent", "GCPI-research (https://github.com/bytesbrains/copra)")]


def hidden(page):
    return dict(re.findall(r'<input[^>]*type="hidden"[^>]*name="([^"]+)"[^>]*value="([^"]*)"', page))


def post(pairs):
    data = urllib.parse.urlencode(pairs).encode()
    return opener.open(URL, data, timeout=90).read().decode("utf-8", "replace")


def cells(page):
    page = re.sub(r"(?s)<(script|style).*?</\1>", "", page)
    return [c.strip() for c in html.unescape(re.sub(r"<[^>]+>", "|", page)).split("|") if c.strip()]


def report_form(market, period):
    page = opener.open(URL, timeout=90).read().decode("utf-8", "replace")
    base = {"ctl00$contentBody$ddlProduct": MILLING_COPRA, "ctl00$contentBody$ddlMarket": market,
            "ctl00$contentBody$ddlSelectTime": period}
    page = post(list({**hidden(page), **base, "__EVENTTARGET": "ctl00$contentBody$ddlSelectTime"}.items()))
    return page, base


def monthly(market, year):
    page, base = report_form(market, MONTHLY)
    pairs = list({**hidden(page), **base, "ctl00$contentBody$ddlYear": str(year),
                  "ctl00$contentBody$btnLoad": "Load"}.items())
    pairs += [("ctl00$contentBody$lstMonth", str(m)) for m in range(1, 13)]
    c = cells(post(pairs))
    return [(c[i + 1], float(c[i + 2])) for i in range(len(c) - 2)
            if c[i] == "Milling Copra" and re.fullmatch(r"\d+(\.\d+)?", c[i + 2])]


def daily(market, start, end):
    page, base = report_form(market, DAILY)
    c = cells(post(list({**hidden(page), **base, "ctl00$contentBody$txtStartDate": start,
                         "ctl00$contentBody$txtEndDate": end, "ctl00$contentBody$btnLoad": "Load"}.items())))
    return [(c[i + 1], float(c[i + 2])) for i in range(len(c) - 2)
            if c[i] == "Milling Copra" and re.fullmatch(r"\d\d-\d\d-\d{4}", c[i + 1])]


def main(argv):
    first = int(argv[1]) if len(argv) > 1 else 2006
    last = int(argv[2]) if len(argv) > 2 else int(time.strftime("%Y"))
    window = argv[3] if len(argv) > 3 else None
    for mid, name in MARKETS.items():
        counts = {}
        for y in range(first, last + 1):
            counts[y] = len(monthly(mid, y))
            time.sleep(0.3)
        have = [y for y, n in counts.items() if n]
        gaps = {y: n for y, n in counts.items() if y >= (have[0] if have else last) and n < 12}
        print(f"{name:10s} monthly averages from {have[0] if have else '-'}; years short of 12 months: {gaps}")
    if window:
        start, end = window.split("-")
        days = daily(DAILY_MARKET, start, end)
        repeats = sum(1 for a, b in zip(days, days[1:]) if a[1] == b[1])
        print(f"{MARKETS[DAILY_MARKET]} daily {start}..{end}: {len(days)} values, {repeats} equal to the previous day")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
