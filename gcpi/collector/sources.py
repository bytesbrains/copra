"""
GCPI collectors (#92): source adapters. An adapter retrieves one market's value for a period and turns it
into an observation (gcpi/ENGINE.md §1) and the source record its `record` field commits to. A collector
runs it to propose an observation; each notary runs the same code on its own retrieval to check it. So an
adapter is a pinned parser: deterministic, exact on the publisher's bytes, and refusing whatever it does
not recognise rather than guessing (GCPI-001 §5.2).

The record covers the value's bytes and their position in the response, not the whole response (§5.2):
the CDB form carries ASP.NET view state, so two retrievals agree on the value but not on the page.
"""

import csv
import decimal
import hashlib
import html
import io
import os
import re
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "engine"))
import engine  # noqa: E402
from fetch import SourceError  # noqa: E402

MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
          "October", "November", "December"]
DECIMAL = re.compile(r"^(0|[1-9][0-9]*)(\.[0-9]+)?\Z")
RECORD_SCHEMA = "gcpi-record-1"


def decimal_parts(text):
    """The publisher's decimal string as engine integers, exactly: "3525.00" -> ("352500", "2")."""
    if not DECIMAL.match(text):
        raise SourceError(f"{text!r} is not a plain decimal")
    whole, _, frac = text.partition(".")
    mantissa, exp = int(whole + frac), len(frac)
    if mantissa == 0 or mantissa >= engine.MAX_MANTISSA or exp > engine.MAX_EXP:
        raise SourceError(f"{text!r} is outside the engine's bounds")
    return str(mantissa), str(exp)


def record_hash(record):
    return hashlib.sha256(engine.canonical(record).encode()).hexdigest()


def ended(period, now):
    """A monthly value is final only once its month is over: before that a "monthly average" is partial."""
    return now >= engine.period_start(engine.ym_index(period) + 1)


# ------------------------------------------------------------------------------------------------
# FX: ecb-monthly-mean. Provisional input to GCPI-001 §6.2, which does not yet fix an FX rule.

ECB_HOST = "www.ecb.europa.eu"
ECB_URL = f"https://{ECB_HOST}/stats/eurofxref/eurofxref-hist.zip"
FX_SOURCE = "ecb-monthly-mean"
FX_EXP = 4
MIN_FX_DAYS = 10


def ecb_monthly_mean(transport, currency, period):
    """Local currency per USD for a month: the mean, over the ECB's reference days in that month, of
    (currency per EUR) / (USD per EUR), computed exactly and rounded half up to FX_EXP decimals. This is
    the backtest's FX (gcpi/backtest/load.py load_fx), made exact. Returns (fx, fx_exp, days)."""
    try:
        z = zipfile.ZipFile(io.BytesIO(transport.get(ECB_URL)))
        rows = list(csv.reader(io.TextIOWrapper(z.open(z.namelist()[0]), encoding="ascii")))
    except (zipfile.BadZipFile, IndexError, UnicodeDecodeError, csv.Error) as e:
        raise SourceError(f"ECB history: {e}") from e
    head = [h.strip() for h in rows[0]] if rows else []
    if "Date" not in head or "USD" not in head or currency not in head:
        raise SourceError(f"ECB history has no Date, USD or {currency} column")
    at = {h: i for i, h in enumerate(head)}
    days = []
    for r in rows[1:]:
        r = [v.strip() for v in r]
        if len(r) < len(head) or not r[at["Date"]].startswith(period + "-"):
            continue
        usd, cur = r[at["USD"]], r[at[currency]]
        if DECIMAL.match(usd) and DECIMAL.match(cur):  # "N/A" on days a rate was not set
            days.append([r[at["Date"]], cur, usd])
    days.sort()
    if len(days) < MIN_FX_DAYS:
        raise SourceError(f"ECB has {len(days)} reference days for {currency} in {period}, fewer than {MIN_FX_DAYS}")
    with decimal.localcontext(decimal.Context(prec=60)):
        mean = sum(decimal.Decimal(c) / decimal.Decimal(u) for _, c, u in days) / len(days)
        fx = int(mean.scaleb(FX_EXP).quantize(decimal.Decimal(1), rounding=decimal.ROUND_HALF_UP))
    return str(fx), str(FX_EXP), days


# ------------------------------------------------------------------------------------------------
# India: CDB milling copra, monthly average, Rs/quintal (gcpi/SOURCES.md, sources.json cdb-market-price).

CDB_HOST = "coconutboard.in"
CDB_URL = f"https://{CDB_HOST}/priceweb/Reports.aspx"
CDB_FIELD = "ctl00$contentBody$"


def _hidden(page):
    return dict(re.findall(r'<input[^>]*type="hidden"[^>]*name="([^"]+)"[^>]*value="([^"]*)"', page))


def _cells(page):
    page = re.sub(r"(?s)<(script|style).*?</\1>", "", page)
    return [c.strip() for c in html.unescape(re.sub(r"<[^>]+>", "|", page)).split("|") if c.strip()]


class Cdb:
    """One CDB market's monthly average for milling copra, as one GCPI market. The form is driven as
    gcpi/research/cdb_copra.py drives it, asking for the one month wanted."""

    source = "cdb-market-price"
    hosts = (CDB_HOST, ECB_HOST)
    PRODUCT = ("2", "Milling Copra")
    MARKETS = {"1": "Kochi", "2": "Alappuzha", "3": "Kozhikode", "4": "Kangayam"}
    MONTHLY = "3"

    def __init__(self, market="IN", cdb_market="1", basis="kochi"):
        if cdb_market not in self.MARKETS:
            raise ValueError(f"unknown CDB market {cdb_market}")
        self.market, self.cdb_market, self.basis = market, cdb_market, basis

    def _value(self, transport, year, month):
        decode = lambda b: b.decode("utf-8", "replace")
        base = {CDB_FIELD + "ddlProduct": self.PRODUCT[0], CDB_FIELD + "ddlMarket": self.cdb_market,
                CDB_FIELD + "ddlSelectTime": self.MONTHLY}
        page = decode(transport.get(CDB_URL))
        page = decode(transport.post(CDB_URL, list(
            {**_hidden(page), **base, "__EVENTTARGET": CDB_FIELD + "ddlSelectTime"}.items())))
        page = decode(transport.post(CDB_URL, list(
            {**_hidden(page), **base, CDB_FIELD + "ddlYear": str(year), CDB_FIELD + "lstMonth": str(month),
             CDB_FIELD + "btnLoad": "Load"}.items())))
        c = _cells(page)
        found = [c[i + 2] for i in range(len(c) - 2) if c[i] == self.PRODUCT[1] and c[i + 1] == MONTHS[month - 1]]
        if len(found) != 1:
            raise SourceError(f"CDB {self.MARKETS[self.cdb_market]} {year}-{month:02d}: "
                              f"{len(found)} values for {self.PRODUCT[1]}, expected 1")
        return found[0]

    def observe(self, transport, period):
        """The observation for `period` without `published`, which only a retrieval's time can give,
        and the source record its `record` field commits to."""
        year, month = int(period[:4]), int(period[5:])
        text = self._value(transport, year, month)
        price, price_exp = decimal_parts(text)
        fx, fx_exp, days = ecb_monthly_mean(transport, "INR", period)
        record = {
            "schema": RECORD_SCHEMA,
            "source": {"id": self.source, "location": CDB_URL,
                       "query": {"product": self.PRODUCT[1], "market": self.MARKETS[self.cdb_market],
                                 "report": "monthly", "year": str(year), "month": MONTHS[month - 1]},
                       "row": self.PRODUCT[1], "column": MONTHS[month - 1], "bytes": text},
            "fx": {"id": FX_SOURCE, "location": ECB_URL, "currency": "INR", "per": "USD", "days": days},
        }
        obs = {"market": self.market, "period": period, "source": self.source, "price": price,
               "price_exp": price_exp, "currency": "INR", "unit": "quintal", "fx": fx, "fx_exp": fx_exp,
               "fx_source": FX_SOURCE, "record": record_hash(record), "basis": self.basis}
        return obs, record


def adapters(specs=("cdb-market-price:IN",)):
    """Adapters by (source, market), from "source:market" specs. Only CDB exists so far."""
    out = {}
    for spec in specs:
        source, _, market = spec.partition(":")
        if source != Cdb.source or not engine.ID.match(market or ""):
            raise ValueError(f"no adapter for {spec!r}")
        out[(source, market)] = Cdb(market=market)
    return out
