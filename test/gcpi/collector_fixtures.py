# Fixtures for the GCPI collector tests (#92): the CDB postback form and the ECB history, served from memory.
# The CDB form behaves as the live one does for the requests sources.Cdb makes: it hands out fresh view state
# on every page, so two retrievals of one value never see the same page.
import io
import itertools
import os
import sys
import zipfile

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
sys.path.insert(0, os.path.join(ROOT, "gcpi", "collector"))
import sources  # noqa: E402
from fetch import SourceError  # noqa: E402

FORM = "ctl00$contentBody$"
_state = itertools.count()


def _page(body):
    return (f'<html><form><input type="hidden" name="__VIEWSTATE" value="state{next(_state)}" />'
            f'<input type="hidden" name="__EVENTVALIDATION" value="ev" />{body}</form>'
            '<script>var cells = "|Milling Copra|September|1|";</script></html>').encode()


def ecb_days(period, inr_usd, n=21):
    """n reference days in `period`, as (date, USD per EUR, INR per EUR) strings, newest first like the ECB."""
    days = []
    for d in range(n, 0, -1):
        usd = f"1.{1000 + d * 7:04d}"
        days.append((f"{period}-{d:02d}", usd, inr_usd(d, usd)))
    return days


def ecb_zip(days, na=()):
    out = io.StringIO()
    out.write("Date,USD,JPY,INR,\n")
    for date, usd, inr in days:
        out.write(f"{date},{usd},160.10,{'N/A' if date in na else inr},\n")
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("eurofxref-hist.csv", out.getvalue())
    return buf.getvalue()


class FakeSources:
    """sources.Cdb's transport: values by (CDB market, year, month), and an ECB history zip."""

    def __init__(self, values, ecb):
        self.values, self.ecb, self.requests = dict(values), ecb, []

    def get(self, url):
        self.requests.append(("GET", url))
        if url == sources.CDB_URL:
            return _page("<select></select>")
        if url == sources.ECB_URL:
            return self.ecb
        raise SourceError(f"{url}: not served")

    def post(self, url, pairs):
        d = dict(pairs)
        self.requests.append(("POST", url, d))
        if url != sources.CDB_URL or not d.get("__VIEWSTATE", "").startswith("state"):
            raise SourceError("postback without view state")
        if d.get("__EVENTTARGET") == FORM + "ddlSelectTime":
            return _page("<select name='ddlYear'></select>")
        if d.get(FORM + "btnLoad") != "Load" or d.get(FORM + "ddlProduct") != "2" or d.get(FORM + "ddlSelectTime") != "3":
            raise SourceError("unexpected form")
        key = (d[FORM + "ddlMarket"], int(d[FORM + "ddlYear"]), int(d[FORM + "lstMonth"]))
        rows = "".join(f"<tr><td>Milling Copra</td><td>{sources.MONTHS[key[2] - 1]}</td><td>{v}</td></tr>"
                       for v in self.values.get(key, []))
        return _page(f"<table><tr><th>Product</th><th>Month</th><th>Price</th></tr>{rows}</table>")
