#!/usr/bin/env python3
"""
Copra Protocol - oracle feeder price source (#85)

Fetches one copra observation from a declared source for scripts/oracle-feeder.sh and prints its
provenance record, one JSON object, on stdout. It never invents a price: an undeclared host, a network
or parse error, a value outside bounds, or an observation older than its source allows exits non-zero,
and the feeder broadcasts nothing (GCPI-001 Invariants 5 and 10).

Usage: oracle_feeder.py <https url>
"""

import datetime
import hashlib
import json
import re
import sys
import urllib.parse
import urllib.request
from decimal import Decimal, ROUND_HALF_UP

# Absolute sanity bounds for copra in USD / kg; the feeder and CopraOracle use 8 decimals.
MIN_PRICE = Decimal("0.50")
MAX_PRICE = Decimal("5.00")
DECIMALS = 8
MAX_BYTES = 1_000_000

# Each unit is a fixed conversion to USD / kg, declared per source (GCPI-001 §6.1); nothing is guessed.
UNITS = {"USD/kg": Decimal(1), "USD/t": Decimal(1) / Decimal(1000)}

# Declared sources, by host. Each names the JSON fields holding the price and its publication date, the
# unit of that price, and how old an observation may be. No source is declared yet: which ones qualify is
# the Phase 1 research in #87. Until one is, the feeder posts only explicit manual overrides.
#
#   "example.org": {"name": "...", "unit": "USD/t", "price_field": "price", "date_field": "date", "max_age_days": 35},
SOURCES = {}

DECIMAL_RE = re.compile(r"^[0-9]+(\.[0-9]+)?$")


class SourceError(Exception):
    pass


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    # A redirect could leave the declared host, so it is a failure, not something to follow.
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise SourceError(f"source redirected ({code}) to {newurl}; redirects are not followed")


def fetch(url):
    opener = urllib.request.build_opener(_NoRedirect)
    req = urllib.request.Request(url, headers={"User-Agent": "CopraProtocol/1.0"})
    with opener.open(req, timeout=10) as resp:
        body = resp.read(MAX_BYTES + 1)
    if len(body) > MAX_BYTES:
        raise SourceError(f"response larger than {MAX_BYTES} bytes")
    return body


def resolve(url, sources=None, get=fetch, now=None):
    """Returns the provenance record of the observation at url, or raises SourceError."""
    sources = SOURCES if sources is None else sources
    now = now or datetime.datetime.now(datetime.timezone.utc)

    parsed = urllib.parse.urlparse(url)
    host = (parsed.hostname or "").lower()
    if parsed.scheme != "https":
        raise SourceError(f"source URL must be https, got '{parsed.scheme}'")
    if host not in sources:
        raise SourceError(f"host '{host}' is not a declared source")
    src = sources[host]
    if src["unit"] not in UNITS:
        raise SourceError(f"source '{src['name']}' declares unknown unit '{src['unit']}'")

    try:
        body = get(url)
    except SourceError:
        raise
    except Exception as e:
        raise SourceError(f"fetch failed: {e}") from e
    try:
        data = json.loads(body.decode("utf-8"))
    except Exception as e:
        raise SourceError(f"response is not JSON: {e}") from e
    if not isinstance(data, dict):
        raise SourceError("response is not a JSON object")

    raw = data.get(src["price_field"])
    # bool is an int in Python; a JSON true is not a price.
    if isinstance(raw, bool) or not isinstance(raw, (int, float, str)):
        raise SourceError(f"field '{src['price_field']}' is missing or not a number")
    raw_text = str(raw).strip()
    if not DECIMAL_RE.match(raw_text):
        raise SourceError(f"field '{src['price_field']}' is not a plain decimal: '{raw_text}'")
    usd_per_kg = Decimal(raw_text) * UNITS[src["unit"]]
    if not MIN_PRICE <= usd_per_kg <= MAX_PRICE:
        raise SourceError(f"{usd_per_kg} USD/kg is outside [{MIN_PRICE}, {MAX_PRICE}]")

    published_text = data.get(src["date_field"])
    try:
        published = datetime.date.fromisoformat(str(published_text)[:10])
    except ValueError as e:
        raise SourceError(f"field '{src['date_field']}' is not an ISO date: '{published_text}'") from e
    age_days = (now.date() - published).days
    if age_days < -1:
        raise SourceError(f"publication date {published} is in the future")
    if age_days > src["max_age_days"]:
        raise SourceError(f"observation published {published} is {age_days} days old; '{src['name']}' allows {src['max_age_days']}")

    price_e8 = int((usd_per_kg * 10**DECIMALS).to_integral_value(rounding=ROUND_HALF_UP))
    return {
        "source": src["name"],
        "url": url,
        "published": published.isoformat(),
        "raw_value": raw_text,
        "unit": src["unit"],
        "price_e8": price_e8,
        "sha256": hashlib.sha256(body).hexdigest(),
        "retrieved_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: oracle_feeder.py <https url>\n")
        return 2
    try:
        record = resolve(argv[1].strip())
    except SourceError as e:
        sys.stderr.write(f"{e}\n")
        return 1
    print(json.dumps(record, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
