# Run with: python3 -m unittest discover -s test/feeder
# scripts/oracle_feeder.py, the feeder's price source (#85): a declared source yields a price and its
# provenance; everything else fails closed with a reason, and no default price exists to fall back to.
import datetime
import hashlib
import json
import os
import subprocess
import sys
import unittest

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import oracle_feeder as feeder  # noqa: E402

NOW = datetime.datetime(2026, 10, 18, 12, 0, tzinfo=datetime.timezone.utc)
URL = "https://prices.example/copra.json"
SOURCES = {
    "prices.example": {"name": "Example board", "unit": "USD/t", "price_field": "price", "date_field": "date", "max_age_days": 35},
    "kg.example": {"name": "Per-kg board", "unit": "USD/kg", "price_field": "usd_kg", "date_field": "as_of", "max_age_days": 10},
}


def body(**fields):
    return json.dumps(fields).encode()


def resolve(url=URL, payload=None, get=None):
    payload = body(price=1420, date="2026-10-10") if payload is None else payload
    return feeder.resolve(url, SOURCES, get or (lambda _: payload), NOW)


class Resolve(unittest.TestCase):
    def fails(self, reason, **kw):
        with self.assertRaises(feeder.SourceError) as ctx:
            resolve(**kw)
        self.assertIn(reason, str(ctx.exception))

    def test_declared_source_gives_price_and_provenance(self):
        payload = body(price=1420, date="2026-10-10")
        self.assertEqual(resolve(payload=payload), {
            "source": "Example board",
            "url": URL,
            "published": "2026-10-10",
            "raw_value": "1420",
            "unit": "USD/t",
            "price_e8": 142000000,
            "sha256": hashlib.sha256(payload).hexdigest(),
            "retrieved_at": "2026-10-18T12:00:00Z",
        })

    def test_unit_is_declared_per_source_never_guessed(self):
        # 1.42 from a USD/t source is $0.00142/kg: refused, not read as USD/kg.
        self.fails("outside", payload=body(price=1.42, date="2026-10-10"))
        # And 1420 from a USD/kg source is refused, not divided by 1000.
        self.fails("outside", url="https://kg.example/p", payload=body(usd_kg=1420, as_of="2026-10-17"))
        rec = resolve(url="https://kg.example/p", payload=body(usd_kg="1.455", as_of="2026-10-17"))
        self.assertEqual(rec["price_e8"], 145500000)

    def test_no_default_price_exists(self):
        self.assertFalse(hasattr(feeder, "DEFAULT_BENCHMARK"))
        self.assertFalse(hasattr(feeder, "INDICATIVE_BENCHMARKS"))

    def test_redirects_are_refused_not_followed(self):
        # A declared host redirecting elsewhere would otherwise bypass the source registry.
        with self.assertRaises(feeder.SourceError):
            feeder._NoRedirect().redirect_request(None, None, 302, "Found", {}, "https://evil.example/")

    def test_undeclared_host_and_non_https_fail(self):
        self.fails("not a declared source", url="https://evil.example/price")
        self.fails("must be https", url="http://prices.example/copra.json")

    def test_fetch_errors_fail(self):
        def boom(_):
            raise OSError("connection refused")
        self.fails("fetch failed: connection refused", get=boom)

    def test_bad_payloads_fail(self):
        self.fails("not JSON", payload=b"<html>")
        self.fails("not a JSON object", payload=b"[1420]")
        self.fails("missing or not a number", payload=body(copra=1420, date="2026-10-10"))
        self.fails("missing or not a number", payload=body(price=True, date="2026-10-10"))
        self.fails("not a plain decimal", payload=body(price="1,420", date="2026-10-10"))
        self.fails("not a plain decimal", payload=body(price=-1420, date="2026-10-10"))
        self.fails("outside", payload=body(price=6000, date="2026-10-10"))

    def test_publication_date_is_required_and_bounded(self):
        self.fails("not an ISO date", payload=body(price=1420))
        self.fails("not an ISO date", payload=body(price=1420, date="last week"))
        self.fails("36 days old", payload=body(price=1420, date="2026-09-12"))
        self.fails("in the future", payload=body(price=1420, date="2026-10-21"))
        self.assertEqual(resolve(payload=body(price=1420, date="2026-09-13"))["published"], "2026-09-13")


class Cli(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "oracle_feeder.py"), *args],
                              capture_output=True, text=True)

    def test_undeclared_host_exits_nonzero_with_no_price(self):
        r = self.run_cli("https://api.worldbank.org/anything")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(r.stdout, "")
        self.assertIn("not a declared source", r.stderr)

    def test_usage(self):
        self.assertEqual(self.run_cli().returncode, 2)


if __name__ == "__main__":
    unittest.main()
