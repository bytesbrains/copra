#!/usr/bin/env python3
"""
GCPI Phase 1 (#87): Philippine Statistics Authority monthly farmgate copra prices, through OpenSTAT.

Queries the PXWeb API for the national "Copra Resecada" and "Copra Corriente" series (PHP/kg) and
reports coverage, the latest month, and months where Corriente (the wetter, cheaper grade) is priced
above Resecada, which flags a sampling or definition change.

Usage: psa_copra.py [out.json]
"""

import json
import sys
import urllib.request

TABLE = "https://openstat.psa.gov.ph/PXWeb/api/v1/en/DB/2M/NFG/0032M4AFN08.px"
UA = {"User-Agent": "GCPI-research (https://github.com/bytesbrains/copra)"}
GRADES = ("Copra Resecada", "Copra Corriente")


def get(url, body=None):
    headers = dict(UA, **({"Content-Type": "application/json"} if body else {}))
    req = urllib.request.Request(url, data=json.dumps(body).encode() if body else None, headers=headers)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def main(argv):
    meta = get(TABLE)
    var = {v["code"]: v for v in meta["variables"]}
    code = lambda c, t: var[c]["values"][var[c]["valueTexts"].index(t)]
    text = lambda c, v: var[c]["valueTexts"][var[c]["values"].index(v)] if c in var else v
    query = {"query": [
        {"code": "Geolocation", "selection": {"filter": "item", "values": [code("Geolocation", "PHILIPPINES")]}},
        {"code": "Commodity", "selection": {"filter": "item", "values": [code("Commodity", g) for g in GRADES]}},
    ], "response": {"format": "json"}}
    res = get(TABLE, query)
    cols = [c["code"] for c in res["columns"]]
    rows = []
    for d in res["data"]:
        rec = {c: text(c, k) for c, k in zip(cols, d["key"])}
        v = d["values"][0]
        rec["php_kg"] = None if v in ("..", "...", "-", "") else float(v)
        if rec["Period"] != "Annual":
            rows.append(rec)

    print(f"Table: {meta['title']}")
    for g in GRADES:
        have = [r for r in rows if r["Commodity"] == g and r["php_kg"] is not None]
        listed = [r for r in rows if r["Commodity"] == g]
        print(f"  {g}: {len(have)} of {len(listed)} months, {have[0]['Year']} {have[0]['Period']} .. "
              f"{have[-1]['Year']} {have[-1]['Period']} (latest {have[-1]['php_kg']} PHP/kg)")

    val = {(r["Year"], r["Period"], r["Commodity"]): r["php_kg"] for r in rows}
    inverted = [(y, p) for (y, p, c), v in val.items()
                if c == GRADES[0] and v is not None and (val.get((y, p, GRADES[1])) or 0) > v]
    years = sorted({y for y, _ in inverted})
    print(f"  Corriente above Resecada: {len(inverted)} months, in years {', '.join(years) or 'none'}")

    if len(argv) > 1:
        with open(argv[1], "w") as f:
            json.dump(rows, f)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
