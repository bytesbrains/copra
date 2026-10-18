#!/usr/bin/env python3
"""
GCPI Phase 1 (#87): what the World Bank's monthly commodity file (the Pink Sheet history) holds for
copra and coconut oil.

Reads CMO-Historical-Data-Monthly.xlsx with the stdlib only (an .xlsx is a zip of XML) and prints every
column whose header mentions copra or coconut, with its first and last month, plus the file's own
"Updated as of" note and the coconut oil series' basis history.

Usage: worldbank_cmo.py <path to CMO-Historical-Data-Monthly.xlsx>
The file is linked from https://www.worldbank.org/en/research/commodity-markets ("Monthly prices").
"""

import re
import sys
import xml.etree.ElementTree as ET
import zipfile

NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
REL = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"
PKG = "{http://schemas.openxmlformats.org/package/2006/relationships}"
SHEET = "Monthly Prices"


def sheet_path(z, name):
    """The worksheet part for a sheet name, resolved through the workbook's relationships: the Nth sheet
    is not necessarily stored as sheetN.xml."""
    sheets = ET.fromstring(z.read("xl/workbook.xml")).find(NS + "sheets")
    by_name = {s.get("name"): s.get(REL + "id") for s in sheets}
    if name not in by_name:
        raise SystemExit(f"no '{name}' sheet; the file has: {', '.join(by_name)}")
    rels = {r.get("Id"): r.get("Target") for r in ET.fromstring(z.read("xl/_rels/workbook.xml.rels")).iter(PKG + "Relationship")}
    target = rels[by_name[name]]
    return target.lstrip("/") if target.startswith("/") else "xl/" + target


def is_number(v):
    """The file marks a missing month with "..", "…" or blank; only a number is an observation. The copra
    column keeps ".." from 2015-01 until it was dropped in 2021, so counting non-blank cells overstates it."""
    try:
        float(v)
        return True
    except (TypeError, ValueError):
        return False


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    z = zipfile.ZipFile(argv[1])
    strings = ["".join(t.text or "" for t in si.iter(NS + "t"))
               for si in ET.fromstring(z.read("xl/sharedStrings.xml")).findall(NS + "si")]

    rows = []
    for r in ET.fromstring(z.read(sheet_path(z, SHEET))).iter(NS + "row"):
        row = {}
        for c in r.findall(NS + "c"):
            v = c.find(NS + "v")
            if v is not None:
                col = re.match(r"[A-Z]+", c.get("r")).group()
                row[col] = strings[int(v.text)] if c.get("t") == "s" else v.text
        rows.append(row)

    header = next(r for r in rows[:10] if any("coconut" in str(v).lower() for v in r.values()))
    wanted = {col: name for col, name in header.items() if re.search(r"copra|coconut", str(name), re.I)}
    data = [r for r in rows if re.fullmatch(r"\d{4}M\d\d", str(r.get("A", "")))]
    for col, name in wanted.items():
        months = [r["A"] for r in data if is_number(r.get(col))]
        print(f"{name}: {months[0]} .. {months[-1]} ({len(months)} months)")
    if not any("copra" in n.lower() for n in wanted.values()):
        print("No copra column.")
    for s in strings:
        if s.startswith("Updated as of") or s.lower().startswith("coconut oil,"):
            print(s.strip())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
