# Run with: python3 -m unittest discover -s test/gcpi
# GCPI-001's v1 decisions (#90): every relative link and anchor in the spec and the GCPI reports
# resolves, and the decided values match the backtest results they cite.
import json
import os
import re
import unittest

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))
SPEC = os.path.join(ROOT, "docs", "specs", "GCPI-001.md")
DOCS = [SPEC, os.path.join(ROOT, "docs", "specs", "COPRA-001.md"), os.path.join(ROOT, "gcpi", "rfcs", "0000-template.md")] + [
    os.path.join(ROOT, "gcpi", f) for f in ("SOURCES.md", "BACKTEST.md", "AUTHENTICATION.md", "ENGINE.md", "CONTRACTS.md")] + [
    os.path.join(ROOT, "econ", "ECONOMICS.md")]
RESULTS = os.path.join(ROOT, "gcpi", "backtest", "data", "results.json")

LINK = re.compile(r"\]\(([^)\s]+)\)")


def slug(heading):
    """GitHub's heading anchor: lower case, punctuation dropped, spaces to hyphens."""
    return re.sub(r"[^\w\- ]", "", heading.strip().lower()).replace(" ", "-")


def anchors(path):
    with open(path) as f:
        return {slug(line.lstrip("#")) for line in f if line.startswith("#")}


def read(path):
    with open(path) as f:
        return f.read()


class Links(unittest.TestCase):
    def test_slug_matches_github(self):
        self.assertEqual(slug("Ratios implied by §13.2"), "ratios-implied-by-132")
        self.assertEqual(slug("Answers to the issue's questions"), "answers-to-the-issues-questions")
        self.assertEqual(slug("1. Correlations and spreads"), "1-correlations-and-spreads")

    def test_every_relative_link_and_anchor_resolves(self):
        for doc in DOCS:
            for target in LINK.findall(read(doc)):
                if re.match(r"[a-z]+:", target):
                    continue
                path, _, anchor = target.partition("#")
                full = os.path.normpath(os.path.join(os.path.dirname(doc), path)) if path else doc
                with self.subTest(doc=os.path.relpath(doc, ROOT), link=target):
                    self.assertTrue(os.path.exists(full), "missing file")
                    if anchor and full.endswith(".md"):
                        self.assertIn(anchor, anchors(full), "missing anchor")


class Decisions(unittest.TestCase):
    """The values GCPI-001 decides in #90 are the ones the backtest measured."""

    @classmethod
    def setUpClass(cls):
        cls.spec = read(SPEC)
        with open(RESULTS) as f:
            cls.results = json.load(f)

    def test_production_weights_round_from_faostat(self):
        share = self.results["weights"]["production_share"]
        ph = share["PH"] / (share["PH"] + share["ID"])
        self.assertEqual((round(ph, 2), round(1 - ph, 2)), (0.65, 0.35))
        self.assertIn("Philippines 0.65, Indonesia 0.35", self.spec)

    def test_monthly_band_factor_is_root_weeks_per_period(self):
        self.assertEqual(round((52 / 12) ** 0.5), 2)
        self.assertIn("| Above 40%      |", self.spec)

    def test_the_disclosure_is_the_same_everywhere(self):
        quote = self.spec.split("carry this statement:\n\n")[1].split("\n\n")[0]
        self.assertTrue(quote.startswith("> copra.dev builds $COPRA"))
        self.assertIn(quote, read(os.path.join(ROOT, "gcpi", "rfcs", "0000-template.md")))

    def test_every_open_question_has_a_status(self):
        status = self.spec.split("Status after #90.")[1].split("# 20.")[0]
        for q in range(1, 11):
            self.assertRegex(status, rf"\n\| {q}\. ")


if __name__ == "__main__":
    unittest.main()
