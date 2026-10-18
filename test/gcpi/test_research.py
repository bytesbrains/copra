# Run with: python3 -m unittest discover -s test/gcpi
# The parsers behind gcpi/SOURCES.md's numbers (#87). The data itself cannot be committed (ICC's PDFs are
# all rights reserved), so these pin the parsing on synthetic inputs shaped like the real ones.
import io
import os
import sys
import unittest
import zipfile

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
sys.path.insert(0, os.path.join(ROOT, "gcpi", "research"))
import icc_archive  # noqa: E402
import psa_copra  # noqa: E402
import worldbank_cmo  # noqa: E402

# pdftotext -layout output of an ICC monthly report, trimmed to the rows that matter.
ICC_MONTH = """\
                                     Prices of Coconut Products (US$/MT)
                                                 October 2026
Products              Country                                03/10/2026   10/10/2026   17/10/2026
Coconut Oil           Indonesia (CIF Rotterdam, Sellers)          2,027        2,031
Copra                 Philippines (Domestic, Quezon)                881          812
Copra                 Sri Lanka (Domestic)                         n.q.        1,435
Copra Meal            Philippines (Domestic)                        234          239
Source: UCAP, PCA, CDA of Sri Lanka, CDB of India, ICC Survey
"""


class IccParse(unittest.TestCase):
    def test_copra_rows_one_record_per_weekly_column(self):
        rows = icc_archive.parse("2026-10", ICC_MONTH)
        self.assertEqual(rows, [
            {"date": "2026-10-03", "series": "Philippines (Domestic, Quezon)", "usd_t": 881.0},
            {"date": "2026-10-10", "series": "Philippines (Domestic, Quezon)", "usd_t": 812.0},
            {"date": "2026-10-03", "series": "Sri Lanka (Domestic)", "usd_t": None},
            {"date": "2026-10-10", "series": "Sri Lanka (Domestic)", "usd_t": 1435.0},
        ])

    def test_copra_meal_and_other_products_are_not_copra(self):
        series = {r["series"] for r in icc_archive.parse("2026-10", ICC_MONTH)}
        self.assertNotIn("Philippines (Domestic)", series)
        self.assertFalse(any("Rotterdam" in s for s in series))

    def test_an_unparseable_copra_row_is_an_error_not_a_skip(self):
        # Skipping it would understate coverage; main() reports the month and fails the run instead.
        broken = ICC_MONTH.replace("881          812", "881  ~~  812")
        with self.assertRaisesRegex(ValueError, "2026-10: unparsed copra row"):
            icc_archive.parse("2026-10", broken)

    def test_a_month_without_a_date_header_is_an_error(self):
        with self.assertRaisesRegex(ValueError, "no date header"):
            icc_archive.parse("2026-10", "Prices of Coconut Products\nOctober 2026\n"
                                         "Copra    Philippines (Domestic, Quezon)    881\n")

    def test_month_first_headers_are_read_by_the_reports_own_month(self):
        # ICC wrote MM/DD/YYYY from 2016-10 to 2017-02. Read day-first, "10/07/2016" would be 10 July and
        # land in the wrong month silently (#88 found this; it had skewed #87's correlations).
        oct2016 = ICC_MONTH.replace("October 2026", "October 2016").replace(
            "03/10/2026   10/10/2026   17/10/2026", "10/07/2016   10/14/2016   10/21/2016")
        dates = sorted({r["date"] for r in icc_archive.parse("2016-10", oct2016)})
        self.assertEqual(dates, ["2016-10-07", "2016-10-14"])

    def test_a_header_date_outside_the_reports_month_is_an_error(self):
        bad = ICC_MONTH.replace("03/10/2026", "08/08/2026")
        with self.assertRaisesRegex(ValueError, "not in the report's month"):
            icc_archive.parse("2026-10", bad)

    def test_a_file_holding_another_months_report_is_misfiled(self):
        # ICC's wpu2026-01.pdf holds the August 2026 report.
        with self.assertRaisesRegex(icc_archive.Misfiled, "2026-01: file holds the October 2026 report"):
            icc_archive.parse("2026-01", ICC_MONTH)

    def test_abbreviated_month_titles(self):
        self.assertEqual(len(icc_archive.parse("2026-10", ICC_MONTH.replace("October 2026", "Oct 2026"))), 4)

    def test_next_month(self):
        self.assertEqual([icc_archive.next_month(m) for m in ("2025-12", "2026-01")], ["2026-01", "2026-02"])

    def test_month_range(self):
        self.assertEqual(list(icc_archive.months("2025-11", "2026-02")), ["2025-11", "2025-12", "2026-01", "2026-02"])


def xlsx(sheets):
    """A minimal workbook whose sheets are stored in reverse order: sheet 1 lives in sheet<N>.xml."""
    names = list(sheets)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("xl/workbook.xml",
                   '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
                   'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'
                   + "".join(f'<sheet name="{n}" sheetId="{i + 1}" r:id="rId{i + 1}"/>' for i, n in enumerate(names))
                   + "</sheets></workbook>")
        z.writestr("xl/_rels/workbook.xml.rels",
                   '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                   + "".join(f'<Relationship Id="rId{i + 1}" Target="worksheets/sheet{len(names) - i}.xml"/>'
                             for i in range(len(names)))
                   + "</Relationships>")
        for i, n in enumerate(names):
            z.writestr(f"xl/worksheets/sheet{len(names) - i}.xml", sheets[n])
    buf.seek(0)
    return zipfile.ZipFile(buf)


class WorldBankSheet(unittest.TestCase):
    def test_sheet_is_found_through_relationships_not_position(self):
        z = xlsx({"AFOSHEET": "<a/>", "Monthly Prices": "<monthly/>", "Description": "<d/>"})
        path = worldbank_cmo.sheet_path(z, "Monthly Prices")
        self.assertEqual(path, "xl/worksheets/sheet2.xml")
        self.assertEqual(z.read(path), b"<monthly/>")
        # Positional lookup would have read sheet2 for the *first* sheet here; check the trap is real.
        self.assertEqual(worldbank_cmo.sheet_path(z, "AFOSHEET"), "xl/worksheets/sheet3.xml")

    def test_only_numbers_are_observations(self):
        # The 2020 edition keeps a copra column of ".." from 2015 on; counting it overstated coverage (#88).
        for v in ("..", "…", "", None):
            self.assertFalse(worldbank_cmo.is_number(v), repr(v))
        for v in ("758.66", "1e3", 408):
            self.assertTrue(worldbank_cmo.is_number(v), repr(v))

    def test_a_renamed_sheet_fails_loudly_naming_what_exists(self):
        z = xlsx({"Prices": "<p/>"})
        with self.assertRaises(SystemExit) as ctx:
            worldbank_cmo.sheet_path(z, "Monthly Prices")
        self.assertIn("the file has: Prices", str(ctx.exception))


class PsaQuery(unittest.TestCase):
    # PXWeb metadata maps each value's code to its text; the query must use the codes.
    META = {"variables": [
        {"code": "Geolocation", "values": ["0", "1"], "valueTexts": ["PHILIPPINES", "NCR"]},
        {"code": "Commodity", "values": ["7", "8", "9"], "valueTexts": ["Abaca", "Copra Resecada", "Copra Corriente"]},
    ]}

    def test_national_series_of_both_grades_by_code(self):
        q = psa_copra.query(self.META)
        sel = {v["code"]: v["selection"]["values"] for v in q["query"]}
        self.assertEqual(sel, {"Geolocation": ["0"], "Commodity": ["8", "9"]})
        self.assertEqual(q["response"], {"format": "json"})


if __name__ == "__main__":
    unittest.main()
