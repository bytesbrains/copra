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
            icc_archive.parse("2026-10", "Copra    Philippines (Domestic, Quezon)    881\n")

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

    def test_a_renamed_sheet_fails_loudly_naming_what_exists(self):
        z = xlsx({"Prices": "<p/>"})
        with self.assertRaises(SystemExit) as ctx:
            worldbank_cmo.sheet_path(z, "Monthly Prices")
        self.assertIn("the file has: Prices", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
