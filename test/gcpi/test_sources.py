# Run with: python3 -m unittest discover -s test/gcpi
# gcpi/sources.json, the Phase 1 source registry (#87): every candidate GCPI-001 §3.1 and #87 name is
# present, every entry carries the fields the issue asks for, and every rejection says why.
import json
import os
import re
import unittest

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
REGISTRY = json.load(open(os.path.join(ROOT, "gcpi", "sources.json")))
SOURCES = REGISTRY["sources"]

ROLES = {"headline-candidate", "sub-index-candidate", "corroboration", "weights", "history-only", "rejected"}
ACCESS = {"api", "html", "html-form", "pdf", "xlsx", "none-found"}
REDISTRIBUTION = {"open", "unclear", "restricted"}
REQUIRED = ["id", "publisher", "market", "series", "url", "access", "access_detail", "cadence", "typical_delay",
            "history", "commodity", "grade", "basis", "currency", "unit", "licence", "authentication",
            "outages_and_changes", "role", "reason", "evidence"]

# The candidates #87 lists (from GCPI-001 §3.1), each of which must have an entry, accepted or not.
CANDIDATES = {
    "Philippine Coconut Authority": "pca-price-monitoring",
    "ICC": "icc-weekly-price-update",
    "Indonesian commodity reports": "indonesia-primary",
    "Coconut Development Board": "cdb-market-price",
    "AGMARKNET": "agmarknet",
    "Sri Lanka Coconut Development Authority": "cda-daily-bulletin",
    "Papua New Guinea": "png-kik-market-report",
    "Solomon Islands": "solomon-cema-cbsi",
    "Vanuatu": "vanuatu-vbos-qsi",
    "World Bank Commodity Price Data": "worldbank-cmo-monthly",
    "FAOSTAT": "faostat-production",
}


class Registry(unittest.TestCase):
    def test_header(self):
        self.assertEqual(REGISTRY["schema"], "gcpi-source-registry/1")
        self.assertRegex(REGISTRY["checked"], r"^\d{4}-\d{2}-\d{2}$")
        self.assertTrue(os.path.exists(os.path.join(ROOT, "gcpi", REGISTRY["report"])))

    def test_every_candidate_from_the_issue_is_covered(self):
        ids = {s["id"] for s in SOURCES}
        for name, sid in CANDIDATES.items():
            self.assertIn(sid, ids, f"{name} has no registry entry")

    def test_ids_are_unique_slugs(self):
        ids = [s["id"] for s in SOURCES]
        self.assertEqual(len(ids), len(set(ids)))
        for i in ids:
            self.assertRegex(i, r"^[a-z0-9]+(-[a-z0-9]+)*$")

    def test_every_entry_has_every_field(self):
        for s in SOURCES:
            for f in REQUIRED:
                self.assertIn(f, s, f"{s.get('id')}: missing {f}")
                self.assertNotIn(s[f], ("", None, [], {}) if f not in ("outages_and_changes",) else ("", None),
                                 f"{s['id']}: empty {f}")
            for f in ("start", "end", "gaps"):
                self.assertTrue(s["history"].get(f), f"{s['id']}: history.{f}")

    def test_enums(self):
        for s in SOURCES:
            self.assertIn(s["role"], ROLES, s["id"])
            self.assertIn(s["access"], ACCESS, s["id"])
            self.assertIn(s["licence"]["redistribution"], REDISTRIBUTION, s["id"])
            self.assertTrue(s["licence"]["terms"], s["id"])

    def test_urls_are_https(self):
        for s in SOURCES:
            self.assertRegex(s["url"], r"^https://", s["id"])
            if "url" in s["licence"]:
                self.assertRegex(s["licence"]["url"], r"^https://", s["id"])

    def test_rejections_and_recommendations_say_why(self):
        for s in SOURCES:
            self.assertGreater(len(s["reason"]), 40, f"{s['id']}: reason too thin to audit")

    def test_no_restricted_source_is_an_index_input(self):
        # GCPI-001 §12.3: a source that cannot be redistributed cannot be reproduced by third parties.
        for s in SOURCES:
            if s["licence"]["redistribution"] == "restricted":
                self.assertNotIn(s["role"], {"headline-candidate", "sub-index-candidate"}, s["id"])

    def test_evidence_scripts_exist(self):
        for s in SOURCES:
            for path in re.findall(r"gcpi/research/[\w.]+\.py", s["evidence"]):
                self.assertTrue(os.path.exists(os.path.join(ROOT, path)), f"{s['id']}: {path}")


if __name__ == "__main__":
    unittest.main()
