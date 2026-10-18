#!/usr/bin/env python3
"""
GCPI source authentication (#89): what each source's HTTPS endpoint offers a TLS attestation.

For every endpoint a collector would read, records what decides whether a zkTLS / TLSNotary-style
attestation of it is practical: whether TLS 1.2 is still accepted (TLSNotary's MPC-TLS is TLS 1.2 only),
the TLS 1.3 fallback, the certificate issuer, a bot challenge, the response's size and format, and
whether two fetches return the same bytes (if not, independent collectors cannot agree on one
commitment). Also records the publication-time signals the server gives (Last-Modified, ETag).

Usage: tls_probe.py [out.json]
Stdlib only. Makes two GETs (or POSTs) per endpoint, a second apart.
"""

import difflib
import hashlib
import http.client
import json
import os
import socket
import ssl
import sys
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import psa_copra  # noqa: E402

UA = "GCPI-research (https://github.com/bytesbrains/copra)"

# (registry id, what is read, method, url, body). A body is the request the research scripts send; a
# callable body is built from the live source first (PSA's value codes come from its metadata).
ENDPOINTS = [
    ("psa-farmgate-copra", "PXWeb table metadata", "GET", psa_copra.TABLE, None),
    ("psa-farmgate-copra", "PXWeb query: national, both grades, all months", "POST", psa_copra.TABLE,
     lambda: psa_copra.query(psa_copra.get(psa_copra.TABLE))),
    ("cdb-market-price", "price report form (results need two ASP.NET postbacks)", "GET",
     "https://coconutboard.in/priceweb/Reports.aspx", None),
    ("cda-daily-bulletin", "bulletin page that links the daily PDFs", "GET",
     "https://cda.gov.lk/web/index.php?option=com_content&view=article&id=16&Itemid=240&lang=en", None),
    ("icc-weekly-price-update", "monthly price PDF", "GET",
     "https://coconutcommunity.org/storage/files/document/wpu2026-09.pdf", None),
    ("agmarknet", "data.gov.in API, no key", "GET",
     "https://api.data.gov.in/resource/9ef84268-d588-465a-a308-a864a43d0070?format=json&limit=1", None),
    ("pca-price-monitoring", "home page", "GET", "https://pca.gov.ph/", None),
    ("worldbank-cmo-monthly", "monthly workbook", "GET",
     "https://thedocs.worldbank.org/en/doc/74e8be41ceb20fa0da750cda2f6b9e4e-0050012026/related/CMO-Historical-Data-Monthly.xlsx", None),
    ("ecb-fx", "daily euro reference rates (GCPI-001 §6.2 FX)", "GET",
     "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml", None),
]

STRUCTURED = ("json", "xml", "csv")


def handshake(host, version):
    """Negotiates exactly one TLS version. Returns (version, cipher) or the error as a string."""
    ctx = ssl.create_default_context()
    ctx.minimum_version = ctx.maximum_version = version
    try:
        with socket.create_connection((host, 443), timeout=20) as s, ctx.wrap_socket(s, server_hostname=host) as t:
            return t.version(), t.cipher()[0]
    except (ssl.SSLError, OSError) as e:
        return None, f"{type(e).__name__}: {e}"[:120]


def issuer(host):
    ctx = ssl.create_default_context()
    try:
        with socket.create_connection((host, 443), timeout=20) as s, ctx.wrap_socket(s, server_hostname=host) as t:
            cert = t.getpeercert()
    except (ssl.SSLError, OSError) as e:
        return f"{type(e).__name__}"
    return dict(x[0] for x in cert["issuer"]).get("organizationName")


def fetch(method, url, body):
    """One request with no compression (an attested transcript is the raw bytes). Follows no
    redirects: an attestation proves one response from one host."""
    u = urllib.parse.urlsplit(url)
    data = json.dumps(body).encode() if body else None
    headers = {"User-Agent": UA, "Accept-Encoding": "identity", "Connection": "close"}
    if data:
        headers["Content-Type"] = "application/json"
    conn = http.client.HTTPSConnection(u.netloc, timeout=120)
    try:
        conn.request(method, u.path + (f"?{u.query}" if u.query else ""), body=data, headers=headers)
        r = conn.getresponse()
        payload = r.read()
        return r.status, {k.lower(): v for k, v in r.getheaders()}, payload
    finally:
        conn.close()


def kind(content_type, payload):
    ct = (content_type or "").lower()
    if payload[:4] == b"%PDF" or "pdf" in ct:
        return "pdf"
    if payload[:2] == b"PK" or "spreadsheet" in ct:
        return "xlsx"
    for k in STRUCTURED:
        if k in ct:
            return k
    if "html" in ct:
        return "html"
    return ct.split(";")[0] or "unknown"


def challenged(status, headers, payload):
    """A bot challenge instead of the content: Cloudflare's, or a 403 to a plain client."""
    return (headers.get("cf-mitigated") == "challenge" or b"challenge-platform" in payload[:20000]
            or (status == 403 and "cloudflare" in headers.get("server", "").lower()))


def needs_key(status, payload):
    return status in (400, 401) and (b"Authorization" in payload or b"api-key" in payload.lower())


def changed_lines(a, b):
    """Lines that differ between two fetches: a session token changes one, a live page many."""
    a, b = a.decode("utf-8", "replace").splitlines(), b.decode("utf-8", "replace").splitlines()
    return sum(1 for l in difflib.unified_diff(a, b, n=0, lineterm="") if l[:1] in "+-" and l[:3] not in ("+++", "---")) // 2


def verdict(p):
    """How a TLS attestation of this endpoint would work, from the probe's facts (see AUTHENTICATION.md)."""
    if p["status"] is None:
        return "unreachable: no attestation possible"
    if p["challenged"]:
        return "bot challenge: neither a collector nor an attestation can read it"
    if p.get("needs_key"):
        return "needs an API key: attestable only with the key redacted; content not measured"
    if p["status"] >= 400:
        return f"HTTP {p['status']}: no attestation possible"
    if not p["tls12"]:
        return "TLS 1.3 only: no MPC-TLS today (TLSNotary is TLS 1.2 only); proxy-mode attestation only"
    if not p["same_bytes"]:
        return (f"attestable, but {p['changed_lines']} line(s) change between fetches: collectors must commit to "
                "the value's bytes, not the whole response")
    if p["kind"] in STRUCTURED:
        return "attestable: structured response, value selectable in-proof"
    if p["kind"] == "html":
        return "attestable: HTML, value located by byte range"
    return f"transcript attestable, value not: {p['kind']} must be parsed outside the proof"


def probe(source, what, method, url, body):
    host = urllib.parse.urlsplit(url).hostname
    v12, c12 = handshake(host, ssl.TLSVersion.TLSv1_2)
    v13, c13 = handshake(host, ssl.TLSVersion.TLSv1_3)
    p = {"source": source, "what": what, "method": method, "url": url, "host": host,
         "tls12": v12 is not None, "tls12_cipher": c12, "tls13": v13 is not None, "issuer": issuer(host)}
    payloads = []
    try:
        body = body() if callable(body) else body
        for i in range(2):
            status, headers, payload = fetch(method, url, body)
            payloads.append(payload)
            if i == 0:
                time.sleep(1)
    except (OSError, http.client.HTTPException) as e:
        p.update(status=None, error=f"{type(e).__name__}: {e}"[:160], challenged=False, needs_key=False,
                 same_bytes=None, kind=None, bytes=None)
        p["verdict"] = verdict(p)
        return p
    p.update(status=status, bytes=len(payload), kind=kind(headers.get("content-type"), payload),
             content_encoding=headers.get("content-encoding"), transfer_encoding=headers.get("transfer-encoding"),
             server=headers.get("server"), last_modified=headers.get("last-modified"), etag=headers.get("etag"),
             date=headers.get("date"), challenged=challenged(status, headers, payload),
             needs_key=needs_key(status, payload), same_bytes=payloads[0] == payloads[1],
             changed_lines=changed_lines(*payloads), sha256=hashlib.sha256(payload).hexdigest())
    p["verdict"] = verdict(p)
    return p


def main(argv):
    results = []
    for e in ENDPOINTS:
        p = probe(*e)
        results.append(p)
        size = f"{p['bytes']:,} B" if p.get("bytes") is not None else "-"
        print(f"{p['source']:24s} {p['what'][:44]:44s} TLS1.2={'yes' if p['tls12'] else 'no ':3s} "
              f"TLS1.3={'yes' if p['tls13'] else 'no ':3s} {p.get('status')} {p.get('kind')} {size} "
              f"same={p.get('same_bytes')} LM={p.get('last_modified') or '-'}")
        print(f"{'':24s} -> {p['verdict']}")
    if len(argv) > 1:
        with open(argv[1], "w") as f:
            json.dump({"checked": time.strftime("%Y-%m-%d"), "endpoints": results}, f, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
